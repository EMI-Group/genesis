defmodule EvoDashWeb.ProcessesLive.Format do
  @moduledoc """
  PURE, TOTAL formatting and filtering helpers for the managed-process UI
  (`EvoDashWeb.ProcessesLive` and the `/agents` detail panel's Processes
  section).

  Every function here is total: it accepts an `%EvoGit.ProcessManager.Execution{}`,
  a plain map with the same keys, or garbage, and never raises. Executions cross
  the PubSub/RPC boundary as native terms, but an event payload is always read
  defensively (`Map.get/2`, atom-or-string keys) so a malformed entry from an
  older/foreign node degrades to a placeholder instead of crashing a render.

  Status vocabulary (core contract, `EvoGit.ProcessManager.Execution`):
  `:starting | :running | :paused | :completed | :failed | :killed | :unknown`.
  The page's three tabs are LIVE (`:starting`, `:running`, `:paused`),
  FINISHED (everything else, including `:unknown` and `nil`) and ALL.
  """

  @live_statuses [:starting, :running, :paused]
  @status_tabs ["live", "finished", "all"]

  @doc "Statuses shown by the `live` tab."
  def live_statuses, do: @live_statuses

  @doc "Whether a status belongs to the LIVE tab (a process that may still be controlled)."
  def live?(status), do: status in @live_statuses

  @doc "Whether a status belongs to the FINISHED tab (terminal, or no longer observable)."
  def finished?(status), do: not live?(status)

  @doc "The three tab values, in render order."
  def status_tabs, do: @status_tabs

  @doc "Normalizes a tab param to a known tab value; anything else is `\"live\"`."
  def normalize_status_tab(value) when value in @status_tabs, do: value
  def normalize_status_tab(_value), do: "live"

  @doc "Normalizes a kind param: `\"tool_call\"`, `\"background_job\"` or `\"all\"`."
  def normalize_kind("tool_call"), do: "tool_call"
  def normalize_kind("background_job"), do: "background_job"
  def normalize_kind(_value), do: "all"

  # ---------------------------------------------------------------------------
  # Labels
  # ---------------------------------------------------------------------------

  @doc "Human label for an execution status (gettext-free: callers wrap it)."
  def status_label(:starting), do: "Starting"
  def status_label(:running), do: "Running"
  def status_label(:paused), do: "Paused"
  def status_label(:completed), do: "Completed"
  def status_label(:failed), do: "Failed"
  def status_label(:killed), do: "Killed"
  def status_label(:unknown), do: "Unknown"
  def status_label(_status), do: "Unknown"

  @doc """
  DaisyUI badge classes for a status, following the dashboard's locked status
  scheme: busy = warning family, good = success, bad = error, neutral = gray.
  `:paused` is a distinct informational state.
  """
  def status_badge_class(status) do
    case status do
      :running -> "bg-warning/10 text-warning border-warning/20"
      :starting -> "bg-base-content/10 text-base-content/60 border-base-content/20"
      :paused -> "bg-info/10 text-info border-info/20"
      :completed -> "bg-success/10 text-success border-success/20"
      :failed -> "bg-error/10 text-error border-error/20"
      :killed -> "bg-error/10 text-error border-error/20"
      _other -> "bg-base-content/10 text-base-content/60 border-base-content/20"
    end
  end

  @doc "Solid dot color class for a status (animation is the caller's business)."
  def status_dot_class(status) do
    case status do
      :running -> "bg-warning"
      :starting -> "bg-base-content/40"
      :paused -> "bg-info"
      :completed -> "bg-success"
      :failed -> "bg-error"
      :killed -> "bg-error"
      _other -> "bg-base-content/40"
    end
  end

  @doc "Label for a process kind (`:tool_call` / `:background_job`)."
  def kind_label(:tool_call), do: "Tool call"
  def kind_label(:background_job), do: "Background job"
  def kind_label(_kind), do: "Process"

  @doc "Label for an execution backend atom."
  def backend_label(:systemd), do: "systemd"
  def backend_label(:bwrap), do: "bwrap"
  def backend_label(:sandbox_exec), do: "sandbox-exec"
  def backend_label(:posix), do: "posix"
  def backend_label(:windows), do: "windows"
  def backend_label(:none), do: "—"
  def backend_label(nil), do: "—"
  def backend_label(other) when is_atom(other), do: Atom.to_string(other)
  def backend_label(_other), do: "—"

  @doc "Label for the runtime dimension (`:foreground` / `:detached`)."
  def runtime_label(:foreground), do: "Foreground"
  def runtime_label(:detached), do: "Detached"
  def runtime_label(other) when is_atom(other) and not is_nil(other), do: Atom.to_string(other)
  def runtime_label(_other), do: "—"

  @doc """
  The OS target of an execution: the systemd unit when there is one, else the
  main pid, else the background-job id, else `"—"`.
  """
  def target_label(%{} = execution) do
    cond do
      present?(Map.get(execution, :unit)) -> "unit " <> to_text(Map.get(execution, :unit))
      is_integer(Map.get(execution, :os_pid)) -> "pid " <> Integer.to_string(Map.get(execution, :os_pid))
      present?(Map.get(execution, :job_id)) -> "job " <> to_text(Map.get(execution, :job_id))
      true -> "—"
    end
  end

  def target_label(_other), do: "—"

  @doc """
  The full command text of an execution: `command`, else `label`, else `tool`.
  """
  def command_text(%{} = execution) do
    [:command, :label, :tool]
    |> Enum.map(&Map.get(execution, &1))
    |> Enum.find("", &present?/1)
  end

  def command_text(_other), do: ""

  @doc "The tool name of an execution (or nil)."
  def tool_name(%{} = execution) do
    case Map.get(execution, :tool) do
      tool when is_binary(tool) and tool != "" -> tool
      _other -> nil
    end
  end

  def tool_name(_other), do: nil

  @doc """
  Process exit code label: the integer code, or `"—"` when the execution has
  not reported one.
  """
  def exit_code_label(%{} = execution) do
    case Map.get(execution, :exit_code) do
      code when is_integer(code) -> Integer.to_string(code)
      _other -> "—"
    end
  end

  def exit_code_label(_other), do: "—"

  @doc "Human reason label of an execution (a term — formatted totally)."
  def reason_label(%{} = execution), do: term_text(Map.get(execution, :reason))
  def reason_label(_other), do: "—"

  @doc "Formats an arbitrary term as display text (never raises, never a raw `%{}`)."
  def term_text(nil), do: "—"
  def term_text(value) when is_binary(value), do: value
  def term_text(value) when is_atom(value), do: Atom.to_string(value)
  def term_text(value) when is_integer(value), do: Integer.to_string(value)
  def term_text(value) when is_list(value), do: inspect(value, limit: 20, printable_limit: 200)
  def term_text(value), do: inspect(value, limit: 20, printable_limit: 200)

  # ---------------------------------------------------------------------------
  # Numbers: uptime, bytes, CPU
  # ---------------------------------------------------------------------------

  @doc """
  Elapsed time of an execution: `started_at` (or `inserted_at`) until
  `ended_at` (or `now`). `"—"` when no start time is known.
  """
  def uptime(execution, now \\ DateTime.utc_now())

  def uptime(%{} = execution, now) do
    start = Map.get(execution, :started_at) || Map.get(execution, :inserted_at)
    stop = Map.get(execution, :ended_at) || now

    case {start, stop} do
      {%DateTime{} = started, %DateTime{} = ended} -> duration_label(DateTime.diff(ended, started))
      _other -> "—"
    end
  end

  def uptime(_execution, _now), do: "—"

  @doc "Formats a non-negative second count as `12s`, `3m 05s`, `2h 14m`, `1d 3h`."
  def duration_label(seconds) when is_integer(seconds) and seconds < 0, do: "0s"
  def duration_label(seconds) when is_integer(seconds) and seconds < 60, do: "#{seconds}s"

  def duration_label(seconds) when is_integer(seconds) and seconds < 3_600 do
    "#{div(seconds, 60)}m #{pad2(rem(seconds, 60))}s"
  end

  def duration_label(seconds) when is_integer(seconds) and seconds < 86_400 do
    "#{div(seconds, 3_600)}h #{div(rem(seconds, 3_600), 60)}m"
  end

  def duration_label(seconds) when is_integer(seconds) do
    "#{div(seconds, 86_400)}d #{div(rem(seconds, 86_400), 3_600)}h"
  end

  def duration_label(_other), do: "—"

  @doc """
  Human-readable byte count (`1.2 MB`). `"—"` for nil/negative/non-integer.
  """
  def human_bytes(value) when is_integer(value) and value >= 0 do
    cond do
      value < 1_024 -> "#{value} B"
      value < 1_048_576 -> scaled(value, 1_024) <> " KB"
      value < 1_073_741_824 -> scaled(value, 1_048_576) <> " MB"
      true -> scaled(value, 1_073_741_824) <> " GB"
    end
  end

  def human_bytes(_value), do: "—"

  @doc """
  The memory figure of an execution's stats: prefers a positive `rss_bytes`,
  then a positive `memory_bytes`, else `nil`.
  """
  def memory_bytes(%{} = stats) do
    case stat(stats, :rss_bytes) do
      value when is_integer(value) and value > 0 ->
        value

      _other ->
        case stat(stats, :memory_bytes) do
          value when is_integer(value) and value > 0 -> value
          _other -> nil
        end
    end
  end

  def memory_bytes(_stats), do: nil

  @doc "Human-readable memory of an execution's stats (`rss_bytes` first, then `memory_bytes`)."
  def memory_label(%{} = execution), do: human_bytes(memory_bytes(Map.get(execution, :stats)))
  def memory_label(_execution), do: "—"

  @doc "CPU percentage of an execution's stats, one decimal (`12.3%`)."
  def cpu_label(%{} = execution) do
    case stat(Map.get(execution, :stats), :cpu_percent) do
      value when is_number(value) -> float_text(value) <> "%"
      _other -> "—"
    end
  end

  def cpu_label(_execution), do: "—"

  defp scaled(value, unit), do: :erlang.float_to_binary(value / unit, decimals: 1)

  defp float_text(value) when is_float(value), do: :erlang.float_to_binary(value, decimals: 1)
  defp float_text(value) when is_integer(value), do: :erlang.float_to_binary(value * 1.0, decimals: 1)

  defp pad2(value) when value < 10, do: "0" <> Integer.to_string(value)
  defp pad2(value), do: Integer.to_string(value)

  # Reads a stats key tolerantly (atom key first, then its string form).
  defp stat(%{} = stats, key) do
    case Map.fetch(stats, key) do
      {:ok, value} -> value
      :error -> Map.get(stats, Atom.to_string(key))
    end
  end

  defp stat(_stats, _key), do: nil

  # ---------------------------------------------------------------------------
  # Filtering (render-time; no refetch needed to switch tabs)
  # ---------------------------------------------------------------------------

  @doc """
  Filters `executions` by any subset of:

    * `:status` — a tab value (`"live"`/`"finished"`/`"all"`, unknown = all)
    * `:kind` — `"tool_call"`/`"background_job"` (`"all"`/nil = every kind)
    * `:q` — case-insensitive free text over command/tool/label/agent/task id
    * `:agent_id` — lenient id equality (string form)
    * `:task_id` — lenient id equality (string form)

  Total: a non-list input yields `[]`.
  """
  def filter(executions, filters) when is_list(executions) and is_map(filters) do
    Enum.filter(executions, &matches?(&1, filters))
  end

  def filter(_executions, _filters), do: []

  @doc "Whether one execution passes the given filter map (see `filter/2`)."
  def matches?(execution, filters) when is_map(execution) and is_map(filters) do
    tab_matches?(Map.get(execution, :status), Map.get(filters, :status)) and
      kind_matches?(Map.get(execution, :kind), Map.get(filters, :kind)) and
      text_matches?(execution, Map.get(filters, :q)) and
      id_matches?(Map.get(execution, :agent_id), Map.get(filters, :agent_id)) and
      id_matches?(Map.get(execution, :task_id), Map.get(filters, :task_id))
  end

  def matches?(_execution, _filters), do: false

  defp tab_matches?(_status, tab) when tab in [nil, "", "all"], do: true
  defp tab_matches?(status, "live"), do: live?(status)
  defp tab_matches?(status, "finished"), do: finished?(status)
  defp tab_matches?(_status, _tab), do: true

  defp kind_matches?(_kind, filter) when filter in [nil, "", "all"], do: true
  defp kind_matches?(kind, "tool_call"), do: kind == :tool_call
  defp kind_matches?(kind, "background_job"), do: kind == :background_job
  defp kind_matches?(_kind, _filter), do: true

  defp text_matches?(_execution, query) when query in [nil, ""], do: true

  defp text_matches?(execution, query) when is_binary(query) do
    needle = query |> String.trim() |> String.downcase()

    if needle == "" do
      true
    else
      haystack =
        [
          Map.get(execution, :command),
          Map.get(execution, :label),
          Map.get(execution, :tool),
          id_string(Map.get(execution, :agent_id)),
          id_string(Map.get(execution, :task_id))
        ]
        |> Enum.filter(&is_binary/1)
        |> Enum.join(" ")
        |> String.downcase()

      String.contains?(haystack, needle)
    end
  end

  defp text_matches?(_execution, _query), do: true

  defp id_matches?(_value, filter) when filter in [nil, ""], do: true
  defp id_matches?(value, filter), do: id_string(value) == id_string(filter)

  @doc "The string form of an execution id (`nil` → `\"\"`)."
  def id_string(nil), do: ""
  def id_string(value) when is_binary(value), do: value
  def id_string(value) when is_integer(value), do: Integer.to_string(value)
  def id_string(value) when is_atom(value), do: Atom.to_string(value)
  def id_string(value), do: term_text(value)

  @doc """
  Tab counts over an already kind/text-filtered list:
  `%{live: n, finished: n, all: n}`. Pass the list filtered by every DIMENSION
  EXCEPT status so the tab labels stay stable while switching tabs.
  """
  def counts(executions) when is_list(executions) do
    Enum.reduce(executions, %{live: 0, finished: 0, all: 0}, fn execution, acc ->
      acc = %{acc | all: acc.all + 1}

      if live?(Map.get(execution, :status)) do
        %{acc | live: acc.live + 1}
      else
        %{acc | finished: acc.finished + 1}
      end
    end)
  end

  def counts(_executions), do: %{live: 0, finished: 0, all: 0}

  # ---------------------------------------------------------------------------
  # Control log
  # ---------------------------------------------------------------------------

  @doc """
  The control-log entries of an execution, oldest first (the core's own order),
  read defensively — a non-list degrades to `[]`.
  """
  def control_log(%{} = execution) do
    case Map.get(execution, :control_log) do
      entries when is_list(entries) -> entries
      _other -> []
    end
  end

  def control_log(_execution), do: []

  @doc """
  The `actor` of a control-log entry rendered for humans. The core RPC path
  hardcodes `:remote` (the dashboard is the caller), which the UI shows as
  "Dashboard".
  """
  def actor_label(:remote), do: "Dashboard"
  def actor_label(nil), do: "—"
  def actor_label(actor), do: term_text(actor)

  @doc "Label for a control action atom or `{:signal, sig}` tuple."
  def action_label(:pause), do: "Pause"
  def action_label(:resume), do: "Resume"
  def action_label(:kill), do: "Kill"
  def action_label({:signal, signal}), do: "Signal " <> term_text(signal)
  def action_label(other), do: term_text(other)

  @doc "The `signal` of a control-log entry, formatted (`\"—\"` when absent)."
  def signal_label(entry), do: term_text(entry_get(entry, :signal))

  @doc "The `reason` of a control-log entry, formatted (`\"—\"` when absent)."
  def entry_reason(entry), do: term_text(entry_get(entry, :reason))

  @doc "The `action` of a control-log entry."
  def entry_action(entry), do: entry_get(entry, :action)

  @doc "The `at` timestamp of a control-log entry (nil when absent)."
  def entry_at(entry), do: entry_get(entry, :at)

  @doc "Formats an entry timestamp as a local 24h time (`HH:MM:SS`), `\"—\"` when absent."
  def entry_time(entry) do
    case entry_at(entry) do
      %DateTime{} = at -> Calendar.strftime(at, "%H:%M:%S")
      at when is_binary(at) -> EvoDashWeb.Helpers.format_datetime(at, :time)
      _other -> "—"
    end
  end

  @doc """
  Reads a control-entry key tolerantly: atom key first, then its string form.
  Entries cross the RPC boundary as native terms, but they are read
  defensively so a possibly string-keyed map renders identically.
  """
  def entry_get(entry, key) when is_map(entry) do
    case Map.fetch(entry, key) do
      {:ok, value} -> value
      :error -> Map.get(entry, Atom.to_string(key))
    end
  end

  def entry_get(_entry, _key), do: nil

  defp present?(value) when is_binary(value), do: String.trim(value) != ""
  defp present?(nil), do: false
  defp present?(_value), do: true

  defp to_text(value) when is_binary(value), do: value
  defp to_text(value), do: term_text(value)
end
