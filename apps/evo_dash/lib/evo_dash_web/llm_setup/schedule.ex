defmodule EvoDashWeb.LLMSetup.Schedule do
  @moduledoc """
  Provider SCHEDULE presets and holiday calendars for a `[[llm.providers]]`
  account draft.

  A provider account may declare peak/off-peak scheduling. Vendors publish
  those windows in prose, so the core ships machine-readable presets
  (`EvoGit.Config.ProviderPresets`) and a statutory holiday calendar
  (`EvoGit.PeakHours.Holidays`); this module is the dashboard's thin, PURE
  adapter over both:

    * `presets_for_provider/1` / `preset/1` — the preset inventory;
    * `snapshot/1`, `apply/2`, `undo/2`, `changed?/2` — the apply/undo cycle a
      "Recommended schedule applied" strip needs, over a STRING-KEYED account
      draft;
    * `holiday_*` — the off-peak holiday-calendar vocabulary.

  ## Only schedule keys are ever touched

  `apply/2` writes exactly `schedule_keys/0` — never identity (`id`, `name`),
  authentication (`api_key_env_var`, `auth_mode`, `oauth_file`) or model keys.
  An account's credentials can therefore never be clobbered by clicking a
  preset, and `undo/2` restores the pre-preset values (or removes the keys the
  preset introduced) while leaving every unrelated key untouched.

  ## Totality

  Pure: no disk, no clock, no catalog. Every function accepts `nil` / a
  wrongly-shaped value and degrades to `[]`, `%{}` or the input unchanged.
  """

  use Gettext, backend: EvoDashWeb.Gettext

  alias EvoGit.Config.ProviderPresets
  alias EvoGit.PeakHours.Holidays

  # The account keys a preset may touch, in display order. Identity,
  # authentication and model keys are deliberately absent.
  @schedule_keys ~w(concurrency peak_concurrency peak_hours timezone off_peak_days off_peak_holidays)

  # Static string → atom table for draft lookup: caller input never interns an
  # atom.
  @window_atoms %{"start" => :start, "end" => :end, "days" => :days}

  @key_atoms %{
    "concurrency" => :concurrency,
    "peak_concurrency" => :peak_concurrency,
    "peak_hours" => :peak_hours,
    "timezone" => :timezone,
    "off_peak_days" => :off_peak_days,
    "off_peak_holidays" => :off_peak_holidays
  }

  @doc """
  The account keys a preset may touch: `concurrency`, `peak_concurrency`,
  `peak_hours`, `timezone`, `off_peak_days`, `off_peak_holidays`.
  """
  @spec schedule_keys() :: [String.t()]
  def schedule_keys, do: @schedule_keys

  @doc """
  Every preset for a provider (atom, catalog id or provider string), in
  display order — `[]` when the vendor publishes no peak/off-peak policy.
  """
  @spec presets_for_provider(term()) :: [map()]
  def presets_for_provider(provider) do
    provider
    |> ProviderPresets.for_provider()
    |> Enum.filter(&is_map/1)
  end

  @doc """
  One preset by its stable id; `nil` when unknown or not a binary.
  """
  @spec preset(term()) :: map() | nil
  def preset(id), do: ProviderPresets.get(id)

  @doc """
  The schedule SUBSET of a string-keyed account draft (only the keys that are
  actually present), for undo snapshots and change detection.

  Non-map input → `%{}`.
  """
  @spec snapshot(term()) :: map()
  def snapshot(draft) when is_map(draft) do
    Enum.reduce(@schedule_keys, %{}, fn key, acc ->
      case fetch_schedule_key(draft, key) do
        {:ok, value} -> Map.put(acc, key, normalize_value(value))
        :error -> acc
      end
    end)
  end

  def snapshot(_draft), do: %{}

  @doc """
  Applies a preset's schedule to an account draft.

  Returns `{draft, snapshot}`: the merged STRING-KEYED draft (peak-hour rows
  are string-keyed maps) and the PRE-APPLY schedule snapshot for `undo/2`.

  `preset` may be a preset envelope, a preset id, or `nil`/an unknown id — in
  which case the draft comes back normalized but unchanged and the snapshot is
  still valid. Only `schedule_keys/0` are written.
  """
  @spec apply(term(), term()) :: {map(), map()}
  def apply(preset, draft) do
    draft = string_keyed_draft(draft)
    before = snapshot(draft)

    case resolve_preset(preset) do
      %{} = resolved ->
        {merge_schedule(draft, Map.get(resolved, :schedule) || Map.get(resolved, "schedule")),
         before}

      _ ->
        {draft, before}
    end
  end

  @doc """
  Restores a pre-preset schedule snapshot.

  Every schedule key PRESENT in the snapshot is written back verbatim; every
  schedule key ABSENT from the snapshot is removed (those are the keys the
  preset introduced). Non-schedule keys are never touched.
  """
  @spec undo(term(), term()) :: map()
  def undo(draft, snapshot) do
    draft = string_keyed_draft(draft)
    before = snapshot(snapshot)

    Enum.reduce(@schedule_keys, draft, fn key, acc ->
      case Map.fetch(before, key) do
        {:ok, value} -> Map.put(acc, key, value)
        :error -> Map.delete(acc, key)
      end
    end)
  end

  @doc """
  `true` when the draft's schedule subset differs from a snapshot — i.e. when
  there is something to undo (or the preset's effect is no longer intact).

  Clears to `false` after `undo/2` restored that same snapshot.
  """
  @spec changed?(term(), term()) :: boolean()
  def changed?(draft, snapshot) do
    snapshot(draft) != snapshot(snapshot)
  end

  @doc """
  A render-ready summary of the draft's schedule, as `{label, value}` rows in
  display order; `[]` when the draft declares no schedule at all.

  Used by the wizard's schedule block and its done summary so both read the
  same formatting.
  """
  @spec summary_rows(term()) :: [{String.t(), String.t()}]
  def summary_rows(draft) do
    rows =
      for key <- @schedule_keys,
          {:ok, value} <- [fetch_schedule_key(draft, key)],
          value not in [nil, "", []],
          row = summary_row(key, value),
          row != nil do
        row
      end

    rows
  end

  # ── holiday calendars ──────────────────────────────────────────────────────

  @doc """
  The holiday calendars the core understands, e.g. `["CN"]`.
  """
  @spec holiday_calendars() :: [String.t()]
  def holiday_calendars, do: Holidays.calendars()

  @doc """
  The gettext label for a holiday calendar: `"CN"` → "China (CN)".

  Blank/nil → "No public-holiday calendar"; an unknown calendar id is shown
  as-is rather than hidden.
  """
  @spec holiday_label(term()) :: String.t()
  def holiday_label(calendar) do
    case normalize_calendar(calendar) do
      "" -> gettext("No public-holiday calendar")
      # zh_CN: China (CN) → "中国 (CN)" — the mainland statutory holiday calendar.
      "CN" -> gettext("China (CN)")
      other -> other
    end
  end

  @doc """
  `{value, label}` pairs for a holiday-calendar select (REAL calendars only —
  the "none" option belongs to the caller, see `holiday_label/1`).
  """
  @spec holiday_options() :: [{String.t(), String.t()}]
  def holiday_options do
    Enum.map(holiday_calendars(), fn calendar -> {calendar, holiday_label(calendar)} end)
  end

  @doc """
  The supported year range of the holiday calendar as `{first, last}`.

  The core's table always publishes at least one year (its `supported_years/0`
  contract is a non-empty ascending list), so this is total in practice.
  """
  @spec holidays_supported_year_range() :: {integer(), integer()}
  def holidays_supported_year_range do
    Holidays.supported_years() |> Enum.min_max()
  end

  @doc """
  One localized sentence explaining what selecting a holiday calendar means —
  its statutory public holidays (plus weekends) count as off-peak, and the
  configured calendar explains up to which year that holds.
  """
  @spec holiday_help() :: String.t()
  def holiday_help do
    case holidays_supported_year_range() do
      {first, last} ->
        gettext(
          "Public holidays of the selected calendar count as off-peak, on top of weekends. The calendar is published through %{last} (from %{first}).",
          first: to_string(first),
          last: to_string(last)
        )

      nil ->
        gettext("Public holidays of the selected calendar count as off-peak, on top of weekends.")
    end
  end

  # ── private ────────────────────────────────────────────────────────────────

  defp resolve_preset(%{} = preset) do
    if Map.has_key?(preset, :schedule) or Map.has_key?(preset, "schedule") do
      preset
    else
      preset
      |> then(&(Map.get(&1, :id) || Map.get(&1, "id")))
      |> resolve_preset()
    end
  end

  defp resolve_preset(id), do: ProviderPresets.get(id)

  defp merge_schedule(draft, schedule) when is_map(schedule) do
    Enum.reduce(@schedule_keys, draft, fn key, acc ->
      case fetch_raw(schedule, key) do
        {:ok, value} -> Map.put(acc, key, normalize_value(value))
        :error -> acc
      end
    end)
  end

  defp merge_schedule(draft, _schedule), do: draft

  defp string_keyed_draft(draft) when is_map(draft) do
    Map.new(draft, fn
      {key, value} when is_atom(key) -> {Atom.to_string(key), value}
      {key, value} when is_binary(key) -> {key, value}
      {key, value} -> {to_string(key), value}
    end)
  end

  defp string_keyed_draft(_draft), do: %{}

  defp fetch_schedule_key(draft, key) when is_map(draft) do
    case Map.fetch(draft, key) do
      {:ok, value} -> {:ok, value}
      :error -> fetch_raw(draft, key)
    end
  end

  defp fetch_schedule_key(_draft, _key), do: :error

  defp fetch_raw(map, key) when is_map(map) do
    case Map.fetch(map, key) do
      {:ok, value} ->
        {:ok, value}

      :error ->
        case Map.fetch(map, Map.fetch!(@key_atoms, key)) do
          {:ok, value} -> {:ok, value}
          :error -> :error
        end
    end
  end

  # Deep string-keying: peak-hour rows arrive as maps whose keys may be atoms.
  defp normalize_value(%{} = value) do
    Map.new(value, fn {key, inner} -> {key_to_string(key), normalize_value(inner)} end)
  end

  defp normalize_value(value) when is_list(value), do: Enum.map(value, &normalize_value/1)
  defp normalize_value(value), do: value

  defp key_to_string(key) when is_binary(key), do: key
  defp key_to_string(key) when is_atom(key), do: Atom.to_string(key)
  defp key_to_string(key), do: to_string(key)

  defp normalize_calendar(value) when is_binary(value),
    do: value |> String.trim() |> String.upcase()

  defp normalize_calendar(value) when is_atom(value) and value not in [nil, true, false],
    do: value |> Atom.to_string() |> String.upcase()

  defp normalize_calendar(_value), do: ""

  defp summary_row("concurrency", value),
    # zh_CN: Concurrency → "并发"
    do: {gettext("Concurrency"), to_string(value)}

  defp summary_row("peak_concurrency", value),
    # zh_CN: Peak concurrency → "高峰并发"
    do: {gettext("Peak concurrency"), to_string(value)}

  defp summary_row("peak_hours", value), do: {gettext("Peak hours"), format_windows(value)}

  defp summary_row("timezone", value), do: {gettext("Timezone"), to_string(value)}

  defp summary_row("off_peak_days", value),
    do: {gettext("Off-peak days"), value |> List.wrap() |> Enum.join(", ")}

  defp summary_row("off_peak_holidays", value),
    do: {gettext("Off-peak public holidays"), holiday_label(value)}

  defp summary_row(_key, _value), do: nil

  defp format_windows(windows) when is_list(windows) do
    windows
    |> Enum.map(&format_window/1)
    |> Enum.reject(&(&1 == ""))
    |> Enum.join(" · ")
  end

  defp format_windows(value), do: to_string(value)

  defp format_window(%{} = window) do
    start_time = window |> get_in_window("start") |> to_string_value()
    end_time = window |> get_in_window("end") |> to_string_value()
    days = window |> get_in_window("days") |> List.wrap() |> Enum.join(", ")

    case {start_time, end_time, days} do
      {"", "", _} -> ""
      {start_time, end_time, ""} -> "#{start_time}–#{end_time}"
      {start_time, end_time, days} -> "#{start_time}–#{end_time} (#{days})"
    end
  end

  defp format_window(_window), do: ""

  defp get_in_window(window, key) do
    case Map.fetch(window, key) do
      {:ok, value} ->
        value

      :error ->
        case Map.fetch(@window_atoms, key) do
          {:ok, atom} -> Map.get(window, atom)
          :error -> nil
        end
    end
  end

  defp to_string_value(value) when is_binary(value), do: value
  defp to_string_value(nil), do: ""
  defp to_string_value(value) when is_atom(value), do: Atom.to_string(value)
  defp to_string_value(value), do: to_string(value)
end
