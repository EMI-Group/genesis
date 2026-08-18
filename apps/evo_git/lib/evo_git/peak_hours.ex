defmodule EvoGit.PeakHours do
  @moduledoc """
  Pure helpers for per-model-profile peak-hour concurrency windows.

  LLM providers charge more during peak hours. Each `[[llm.models]]` profile
  may declare optional `peak_concurrency` and `peak_hours` fields:

      [[llm.models]]
      id = "glm"
      concurrency = 4        # normal (off-peak) concurrency
      peak_concurrency = 2   # concurrency during peak windows
      peak_hours = [         # daily time windows (local wall-clock)
        { start = "09:00", end = "12:00" },
        { start = "14:00", end = "18:00" }
      ]

  ## Semantics

  - Each window is a map with `start`/`end` `"HH:MM"` 24-hour strings
    (atom-keyed or string-keyed — TOML decoding may produce string keys).
  - Windows are **half-open** `[start, end)`: at `start` the window is
    active, at `end` it is not.
  - `start > end` means an **overnight window** that wraps midnight
    (`22:00`→`06:00` occupies `[22:00, 24:00) ∪ [00:00, 06:00)`).
  - `peak_hours` absent / `[]` / all-invalid → disabled: normal `concurrency`
    applies 24/7.
  - `peak_concurrency` present → effective during peak windows; `peak_hours`
    present but `peak_concurrency` absent → defaults to `concurrency`
    (a legal no-op).

  ## Canonical form

  `validate_windows/1` parses raw window maps into a canonical list of
  `%{start: minute_of_day, end: minute_of_day}` maps (integers 0..1439,
  atom keys; `start > end` ⇒ overnight). `in_peak?/2` and
  `next_transition/2` operate on this canonical form.

  This module is pure — no GenServer, no state, no I/O. It is the single
  source of truth for peak-window parsing/validation: the config schema
  reuses `validate_windows/1` for TOML validation errors, and the peak-hour
  engine (owned separately) uses the runtime helpers.
  """

  @typedoc "Minute of day: 0 (00:00) to 1439 (23:59)."
  @type minute :: 0..1439

  @typedoc """
  Canonical validated window. `start > end` means an overnight window that
  wraps midnight.
  """
  @type window :: %{start: minute(), end: minute()}

  @typedoc "List of canonical validated windows."
  @type windows :: [window()]

  @minutes_per_day 1440

  @doc """
  Parses a strict `"HH:MM"` 24-hour time string into minute-of-day.

  Accepts `"00:00"`..`"23:59"` only. Rejects `"24:00"`, `"9:00"`, `"23:60"`,
  surrounding whitespace, and any non-string input.

      iex> EvoGit.PeakHours.parse_time("09:30")
      {:ok, 570}

      iex> EvoGit.PeakHours.parse_time("24:00")
      :error

  """
  @spec parse_time(term()) :: {:ok, minute()} | :error
  def parse_time(t) when is_binary(t) do
    case Regex.run(~r/\A(\d{2}):(\d{2})\z/, t) do
      [_, hh, mm] ->
        h = String.to_integer(hh)
        m = String.to_integer(mm)

        if h <= 23 and m <= 59 do
          {:ok, h * 60 + m}
        else
          :error
        end

      nil ->
        :error
    end
  end

  def parse_time(_), do: :error

  @doc """
  Parses a single peak-hour window map into canonical form.

  Accepts atom-keyed (`%{start: "09:00", end: "12:00"}`) and string-keyed
  (`%{"start" => "09:00", "end" => "12:00"}`) maps. Returns `{:error, reason}`
  with a descriptive reason:

    * `{:invalid_window, value}` — entry is not a map
    * `{:invalid_format, window}` — missing `start`/`end` key, non-string
      value, or a malformed `"HH:MM"` string
    * `{:zero_length, window}` — `start == end` (zero-length window)
  """
  @spec parse_window(term()) :: {:ok, window()} | {:error, term()}
  def parse_window(w) when is_map(w) do
    with {:ok, s_raw} <- fetch_window_key(w, :start),
         {:ok, e_raw} <- fetch_window_key(w, :end),
         {:ok, s} <- parse_time(s_raw),
         {:ok, e} <- parse_time(e_raw) do
      if s == e do
        {:error, {:zero_length, w}}
      else
        {:ok, %{start: s, end: e}}
      end
    else
      :error -> {:error, {:invalid_format, w}}
    end
  end

  def parse_window(other), do: {:error, {:invalid_window, other}}

  @doc """
  Validates a list of raw peak-hour window maps into canonical form.

  Returns `{:ok, windows}` when every window parses and no two windows
  overlap (half-open, overnight-wrap aware). Empty list → `{:ok, []}`;
  `nil` → `{:ok, []}` (absent/disabled). On the first problem returns
  `{:error, reason}` — reasons as in `parse_window/1`, plus:

    * `{:overlap, w1, w2}` — two windows overlap (the raw maps as written)
    * `{:invalid_windows, value}` — input is not a list
  """
  @spec validate_windows(term()) :: {:ok, windows()} | {:error, term()}
  def validate_windows(nil), do: {:ok, []}

  def validate_windows(hours) when is_list(hours) do
    case parse_all(hours) do
      {:ok, canonical} ->
        pairs = Enum.zip(canonical, hours)

        case find_overlap(pairs) do
          nil -> {:ok, canonical}
          {w1, w2} -> {:error, {:overlap, w1, w2}}
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  def validate_windows(other), do: {:error, {:invalid_windows, other}}

  @doc """
  True when `now` (local wall-clock) falls inside any peak window.

  Half-open: at a window `start` → true, at its `end` → false. Overnight
  windows wrap midnight. `windows` must be the canonical form produced by
  `validate_windows/1`; an empty list → false.
  """
  @spec in_peak?(windows(), NaiveDateTime.t()) :: boolean()
  def in_peak?(windows, %NaiveDateTime{} = now) when is_list(windows) do
    t = minute_of_day(now)
    Enum.any?(windows, fn %{start: s, end: e} -> in_window?(t, s, e) end)
  end

  @doc """
  Returns the next `NaiveDateTime` boundary at which the in-peak state
  flips, or `nil` when `windows` is empty (the calling engine caps its
  sleep at 6h anyway, so `nil` is safe).

  Well-defined in every state: inside a window → that window's `end` (the
  next-day `end` minute for an overnight window); outside → the next window
  `start`. With multiple windows the earliest boundary wins. `windows` must
  be the canonical form produced by `validate_windows/1`.
  """
  @spec next_transition(windows(), NaiveDateTime.t()) :: NaiveDateTime.t() | nil
  def next_transition([], _now), do: nil

  def next_transition(windows, %NaiveDateTime{} = now) when is_list(windows) do
    date = NaiveDateTime.to_date(now)
    t = minute_of_day(now)

    windows
    |> Enum.map(fn %{start: s, end: e} -> next_boundary(date, t, s, e) end)
    |> Enum.min_by(& &1)
  end

  @doc """
  Returns the effective concurrency for a model profile at `now`.

  `profile` is a map with atom keys: `:concurrency` (normal/off-peak),
  optional `:peak_concurrency`, optional `:peak_hours`. Returns
  `peak_concurrency` when in peak and the field is present, else
  `concurrency`. `peak_hours` absent / empty / invalid → always
  `concurrency`. Also accepts already-canonical windows (integer
  `start`/`end`) in `:peak_hours` for callers that validated once.
  Returns `nil` when `:concurrency` is missing.
  """
  @spec effective_concurrency(map(), NaiveDateTime.t()) :: non_neg_integer() | nil
  def effective_concurrency(profile, now) when is_map(profile) do
    case Map.get(profile, :concurrency) do
      nil ->
        nil

      concurrency ->
        case normalize_peak_hours(Map.get(profile, :peak_hours)) do
          {:ok, windows} ->
            if in_peak?(windows, now) do
              case Map.get(profile, :peak_concurrency) do
                nil -> concurrency
                peak -> peak
              end
            else
              concurrency
            end

          {:error, _reason} ->
            concurrency
        end
    end
  end

  # --- Private helpers ---

  # Fetches a window key tolerating both atom and string key styles.
  defp fetch_window_key(w, key) do
    case Map.fetch(w, key) do
      {:ok, v} ->
        {:ok, v}

      :error ->
        case Map.fetch(w, Atom.to_string(key)) do
          {:ok, v} -> {:ok, v}
          :error -> :error
        end
    end
  end

  # Parses every window in order, failing fast on the first invalid one.
  defp parse_all(hours) do
    result =
      Enum.reduce_while(hours, {:ok, []}, fn h, {:ok, acc} ->
        case parse_window(h) do
          {:ok, w} -> {:cont, {:ok, [w | acc]}}
          {:error, reason} -> {:halt, {:error, reason}}
        end
      end)

    case result do
      {:ok, ws} -> {:ok, Enum.reverse(ws)}
      other -> other
    end
  end

  # Pairwise overlap scan over {canonical, raw} pairs; returns the raw
  # maps of the first overlapping pair, or nil when none overlap.
  defp find_overlap(pairs), do: find_overlap(pairs, [])

  defp find_overlap([], _seen), do: nil

  defp find_overlap([{cw, rw} | rest], seen) do
    case Enum.find(seen, fn {c2, _rw2} -> windows_overlap?(cw, c2) end) do
      nil -> find_overlap(rest, [{cw, rw} | seen])
      {_c2, rw2} -> {rw, rw2}
    end
  end

  # A window occupies one or two half-open minute segments on [0, 1440):
  # same-day [s, e); overnight [s, 1440) ∪ [0, e).
  defp windows_overlap?(w1, w2) do
    Enum.any?(segments(w1), fn seg1 ->
      Enum.any?(segments(w2), fn seg2 -> segments_overlap?(seg1, seg2) end)
    end)
  end

  # Two half-open segments [a, b) and [c, d) overlap iff a < d and c < b.
  defp segments_overlap?({a, b}, {c, d}), do: a < d and c < b

  defp segments(%{start: s, end: e}) when s < e, do: [{s, e}]

  defp segments(%{start: s, end: e}) do
    [{s, @minutes_per_day}, {0, e}]
  end

  defp in_window?(t, s, e) when s < e, do: t >= s and t < e
  defp in_window?(t, s, e), do: t >= s or t < e

  # Next state-flip boundary for one window relative to day `date` and
  # minute-of-day `t`.
  defp next_boundary(date, t, s, e) when s < e do
    cond do
      t < s -> at(date, s)
      t < e -> at(date, e)
      true -> at(Date.add(date, 1), s)
    end
  end

  defp next_boundary(date, t, s, e) do
    cond do
      t < e -> at(date, e)
      t < s -> at(date, s)
      true -> at(Date.add(date, 1), e)
    end
  end

  defp at(date, minute) do
    NaiveDateTime.new!(date, Time.new!(div(minute, 60), rem(minute, 60), 0))
  end

  defp minute_of_day(%NaiveDateTime{hour: h, minute: m}), do: h * 60 + m

  # Accepts raw "HH:MM" windows (validated) OR already-canonical integer
  # windows; anything else → {:error, _} so callers fall back to normal
  # concurrency.
  defp normalize_peak_hours(nil), do: {:ok, []}

  defp normalize_peak_hours(hours) when is_list(hours) do
    if canonical_windows?(hours) do
      {:ok, hours}
    else
      validate_windows(hours)
    end
  end

  defp normalize_peak_hours(_), do: {:error, :invalid_windows}

  defp canonical_windows?(hours) do
    Enum.all?(hours, fn
      %{start: s, end: e} when is_integer(s) and is_integer(e) ->
        s in 0..1439 and e in 0..1439 and s != e

      _ ->
        false
    end)
  end
end
