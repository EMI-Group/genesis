defmodule EvoGit.Bench.Report do
  @moduledoc """
  Pure presentation of an `EvoGit.Bench.run/1` result map.

  `to_map/1` projects the result onto its ten top-level keys and makes every
  value JSON-safe; `render_json/1` pretty-encodes that projection, and
  `render_text/1` renders the aligned human report.

  Nothing here performs I/O or prints — the Mix task owns stdout. Both
  renderers are total over the result map: a missing or unexpected phase entry
  renders as zeros instead of raising, so synthetic maps are safe to render.
  """

  alias EvoGit.Bench.Stats

  @top_level_keys [
    :label,
    :dir,
    :kept,
    :settings,
    :system,
    :setup,
    :phases,
    :cycle,
    :overall,
    :throughput
  ]

  @phase_order [
    :worktree_add,
    :file_read,
    :file_write,
    :git_status,
    :git_add,
    :git_commit,
    :worktree_remove,
    :worktree_prune
  ]

  @phase_labels %{
    worktree_add: "worktree add",
    file_read: "file read",
    file_write: "file write",
    git_status: "git status",
    git_add: "git add",
    git_commit: "git commit",
    worktree_remove: "worktree remove",
    worktree_prune: "worktree prune"
  }

  @ram_fs_types ["tmpfs", "ramfs", "none"]

  @label_width 18
  @number_width 9
  @share_width 8

  @note "Note: absolute numbers vary with page cache and machine load; /tmp on tmpfs gives RAM-speed results — pass --dir on the filesystem under test."

  @doc """
  Returns a JSON-ready projection of the result with the same ten top-level
  keys (`label`, `dir`, `kept`, `settings`, `system`, `setup`, `phases`,
  `cycle`, `overall`, `throughput`).

  Values pass through unchanged except for JSON safety: atom values become
  strings, structs become plain maps, tuples become lists and any other term
  becomes its `inspect/1` string. Keys stay atoms when they were atoms (Jason
  encodes them as strings).
  """
  @spec to_map(map()) :: map()
  def to_map(result) when is_map(result) do
    Map.new(@top_level_keys, fn key -> {key, sanitize(Map.get(result, key))} end)
  end

  @doc """
  Pretty-encodes `to_map/1` as JSON.
  """
  @spec render_json(map()) :: String.t()
  def render_json(result) when is_map(result) do
    result
    |> to_map()
    |> Jason.encode!(pretty: true)
  end

  @doc """
  Renders the aligned human report for a result map.

  The layout is a header (label, directory + filesystem, optional RAM-filesystem
  warning, platform, git), the settings line, repo setup, the per-cycle phase
  table, and the overall + throughput totals. All times are milliseconds via
  `EvoGit.Bench.Stats.duration_ms/1`; sizes use binary units.
  """
  @spec render_text(map()) :: String.t()
  def render_text(result) when is_map(result) do
    system = map_at(result, :system)
    settings = map_at(result, :settings)
    setup = map_at(result, :setup)
    overall = map_at(result, :overall)
    throughput = map_at(result, :throughput)
    cycle = map_at(result, :cycle)
    phases = map_at(result, :phases)

    [
      "Genesis I/O Benchmark — #{text(result, :label, "unknown")}",
      directory_line(result, system),
      ram_warning_line(result, system),
      "Platform  : #{platform_line(system)}",
      "Git       : #{text(system, :git_version, "unknown")}",
      "",
      "Settings  : #{settings_line(settings)}",
      "",
      "Repo setup: #{count(setup, :files)} files / #{human_size(field(setup, :bytes))} " <>
        "in #{Stats.format_duration_us(field(setup, :us))}",
      "",
      "Phase breakdown (per cycle, #{sample_count(settings, overall)} samples; times in ms)",
      phase_header(),
      Enum.map(@phase_order, &phase_row(phases, &1)),
      cycle_row(cycle),
      "",
      "Overall: #{count(overall, :cycles)} cycles in " <>
        "#{Stats.format_duration_us(field(overall, :wall_us))} → " <>
        "#{one_decimal(field(overall, :cycles_per_sec))} cycles/s",
      write_line(throughput, phases),
      read_line(throughput, phases),
      "",
      @note
    ]
    |> List.flatten()
    |> Enum.reject(&is_nil/1)
    |> Enum.join("\n")
  end

  # ── Text report sections ──────────────────────────────────────────────────

  defp directory_line(result, system) do
    "Directory : #{text(result, :dir, "unknown")} (#{text(system, :fs_type, "unknown")})"
  end

  defp ram_warning_line(result, system) do
    fs_type = text(system, :fs_type, nil)

    if fs_type in @ram_fs_types do
      mount = text(system, :mountpoint, nil) || text(result, :dir, "this path")

      "Warning   : #{mount} is on #{fs_type} — results measure RAM, not the disk under test."
    end
  end

  defp platform_line(system) do
    "#{text(system, :os, "unknown")} #{text(system, :arch, "unknown")}, " <>
      "#{count(system, :cpus)} logical CPUs · Elixir #{text(system, :elixir, "unknown")} / " <>
      "OTP #{text(system, :otp, "unknown")}"
  end

  defp settings_line(settings) do
    fsync = if Map.get(settings, :fsync) == true, do: "on", else: "off"

    "#{count(settings, :iterations)} cycles (+#{count(settings, :warmup)} warmup) · " <>
      "#{count(settings, :files)} seed files · #{count(settings, :reads)} reads + " <>
      "#{count(settings, :writes)} writes/cycle @ #{human_size(field(settings, :file_size))} · " <>
      "fsync #{fsync} · seed #{count(settings, :seed)}"
  end

  defp sample_count(settings, overall) do
    case Map.get(settings, :iterations) do
      iterations when is_integer(iterations) -> Integer.to_string(iterations)
      _ -> count(overall, :cycles)
    end
  end

  defp phase_header do
    pad("Phase") <>
      column("mean") <>
      column("median") <>
      column("p95") <>
      column("min") <>
      column("max") <>
      share_column("share")
  end

  defp phase_row(phases, key) do
    stats = phase_stats(phases, key)

    pad(phase_label(key)) <>
      column(ms(stats, :mean_us)) <>
      column(ms(stats, :median_us)) <>
      column(ms(stats, :p95_us)) <>
      column(ms(stats, :min_us)) <>
      column(ms(stats, :max_us)) <>
      share_column(one_decimal(field(stats, :share) * 100) <> "%")
  end

  defp cycle_row(cycle) do
    pad("Cycle total") <>
      one_decimal(Stats.duration_ms(field(cycle, :mean_us))) <>
      " ms (mean) / " <>
      one_decimal(Stats.duration_ms(field(cycle, :median_us))) <> " ms (median)"
  end

  defp write_line(throughput, phases) do
    "Write throughput: #{count(throughput, :files_written)} files / " <>
      "#{human_size(field(throughput, :bytes_written))} in " <>
      "#{Stats.format_duration_us(phase_total_us(phases, :file_write))} → " <>
      "#{one_decimal(field(throughput, :write_mib_per_sec))} MiB/s"
  end

  defp read_line(throughput, phases) do
    "Read throughput : #{count(throughput, :files_read)} files / " <>
      "#{human_size(field(throughput, :bytes_read))} in " <>
      "#{Stats.format_duration_us(phase_total_us(phases, :file_read))} → " <>
      "#{one_decimal(field(throughput, :read_mib_per_sec))} MiB/s"
  end

  defp phase_stats(phases, key) do
    case Map.get(phases, key) do
      stats when is_map(stats) -> stats
      _ -> %{}
    end
  end

  defp phase_total_us(phases, key) do
    stats = phase_stats(phases, key)

    case Map.get(stats, :samples_us) do
      samples when is_list(samples) -> Enum.sum(samples)
      _ -> field(stats, :total_us)
    end
  end

  # A total phase-name lookup: a known key uses its human label, and an
  # unexpected key degrades to an underscored lowercase name instead of raising.
  defp phase_label(key) do
    case Map.fetch(@phase_labels, key) do
      {:ok, label} -> label
      :error -> humanize(key)
    end
  end

  defp humanize(key) when is_atom(key), do: key |> Atom.to_string() |> String.replace("_", " ")
  defp humanize(key), do: inspect(key)

  defp pad(label), do: String.pad_trailing(label, @label_width)
  defp column(value), do: String.pad_leading(value, @number_width)
  defp share_column(value), do: String.pad_leading(value, @share_width)

  defp ms(stats, key) do
    stats
    |> field(key)
    |> Stats.duration_ms()
    |> one_decimal()
  end

  # ── Value access (total over malformed/synthetic maps) ────────────────────

  defp map_at(map, key) do
    case Map.get(map, key) do
      value when is_map(value) -> value
      _ -> %{}
    end
  end

  defp text(map, key, default) do
    case Map.get(map, key) do
      value when is_binary(value) and value != "" -> value
      _ -> default
    end
  end

  defp count(map, key) do
    case Map.get(map, key) do
      value when is_integer(value) -> Integer.to_string(value)
      value when is_float(value) -> one_decimal(value)
      _ -> "0"
    end
  end

  defp field(map, key) do
    case Map.get(map, key) do
      value when is_number(value) -> value
      _ -> 0
    end
  end

  defp one_decimal(value) when is_number(value) do
    :erlang.float_to_binary(value * 1.0, decimals: 1)
  end

  # Binary units: bytes as an integer, KiB trimmed of a trailing `.0`, MiB/GiB
  # always one decimal.
  defp human_size(bytes) when is_number(bytes) and bytes >= 0 and bytes < 1024 do
    "#{round(bytes)} B"
  end

  defp human_size(bytes) when is_number(bytes) and bytes >= 0 and bytes < 1_048_576 do
    trim_zero(one_decimal(bytes / 1024)) <> " KiB"
  end

  defp human_size(bytes) when is_number(bytes) and bytes >= 0 and bytes < 1_073_741_824 do
    one_decimal(bytes / 1_048_576) <> " MiB"
  end

  defp human_size(bytes) when is_number(bytes) and bytes >= 0 do
    one_decimal(bytes / 1_073_741_824) <> " GiB"
  end

  defp human_size(_bytes), do: "0 B"

  defp trim_zero(string) do
    case String.split(string, ".", parts: 2) do
      [whole, "0"] -> whole
      _ -> string
    end
  end

  # ── JSON safety ───────────────────────────────────────────────────────────

  defp sanitize(nil), do: nil
  defp sanitize(value) when is_boolean(value), do: value
  defp sanitize(value) when is_atom(value), do: Atom.to_string(value)
  defp sanitize(value) when is_binary(value) or is_number(value), do: value
  defp sanitize(value) when is_list(value), do: Enum.map(value, &sanitize/1)

  defp sanitize(%_{} = struct), do: struct |> Map.from_struct() |> sanitize()

  defp sanitize(value) when is_map(value) do
    Map.new(value, fn {key, item} -> {sanitize_key(key), sanitize(item)} end)
  end

  defp sanitize(value) when is_tuple(value), do: value |> Tuple.to_list() |> sanitize()
  defp sanitize(value), do: inspect(value)

  defp sanitize_key(key) when is_atom(key), do: key
  defp sanitize_key(key) when is_binary(key), do: key
  defp sanitize_key(key), do: inspect(key)
end
