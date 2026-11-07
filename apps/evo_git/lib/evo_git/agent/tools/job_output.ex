defmodule EvoGit.Agent.Tools.JobOutput do
  @moduledoc """
  Tool for reading a background job's output.

  Returns the output produced SINCE the previous read (the registry keeps a
  per-job cursor, so a capped read never loses data) plus the job's current
  status line.

  ## Result text

      <delta>
      [status: running]

      (no new output)
      [status: completed, exit code: 0]

  The delta is followed by a newline unless it already ends with one; an empty
  delta reads `(no new output)`. The status line is `[status: <status>]`, or
  `[status: <status>, <detail>]` when the job carries a terminal detail
  (`exit code: N`, `killed (<reason>)`, …).

  ## `wait: true`

  A `wait: true` call blocks in THIS tool (never in the registry) by polling
  `EvoGit.BackgroundJobs.job/2` until the job reaches a terminal status, the
  owning agent is gracefully cancelled, or the wait budget expires. A timed-out
  wait leaves the job RUNNING and still returns whatever output was produced.

  The point of a long budget is to make ONE wait instead of re-polling: a
  background job is usually started because it takes minutes, so the default is
  a generous `EvoGit.BackgroundJobs.wait_default_ms/0` (120 000 ms) and the cap
  is `EvoGit.BackgroundJobs.wait_max_ms/0` — the configured scheduler tool
  ceiling (`[:scheduler, :max_tool_timeout]`) minus the dispatcher headroom,
  ~30 min by default. A job expected to take a while should be collected with
  ONE long wait (e.g. `timeout: "30m"`), not a string of short ones.

  The wait budget is read (in order) from `timeout_ms`, `timeout` or
  `timeoutMs` — `timeout_ms` is canonical and `timeout` is the generic spelling
  the rest of the tool surface uses. A value may be an integer, a float
  (truncated), or a string holding a number with an optional `ms`/`s`/`m` unit
  (`"60000"`, `"60s"`, `"2m"`, `"30m"`). No usable value means the effective
  default `EvoGit.BackgroundJobs.wait_default_ms/0`; every budget is clamped
  into `[0, EvoGit.BackgroundJobs.wait_max_ms/0]`.

  Polling backs off (~1.5× per iteration up to 3 s) so a fast job is still
  observed promptly while a long wait does not hammer the registry — every poll
  of a `:unit`-handled job runs a synchronous `systemctl --user show` in the
  single GLOBAL registry.

  One marker line is then appended AFTER the status line, so a short wait is
  diagnosable instead of looking like a fast success:

      <delta>
      [status: completed, exit code: 0]
      [wait: finished after 142 ms, status: completed]

      (no new output)
      [status: running]
      [wait: 120000 ms budget expired, status: running; pass timeout_ms (or timeout) to wait up to 1775000 ms ("29m35s")]

  The first marker means the job reached a terminal status during the wait; the
  second means the budget ran out with the job still live (the default-budget
  hint is omitted when the budget was passed explicitly). A graceful cancel of
  the owning agent aborts the wait early with its own marker:

      (no new output)
      [status: running]
      [wait: aborted after 61 ms — cancellation requested, status: running]

  The marker follows the `[status: …]` line byte-identically — the status line
  itself is unchanged.

  ## Omitting `job_id`

  `job_id` is OPTIONAL. When it is missing, blank or not a string, the tool
  resolves the CALLING agent's own background jobs (the same ownership fence the
  read uses): exactly one job is read as if its id had been passed (the full
  `wait: true` / `timeout_ms` / `max_bytes` behaviour included), zero jobs and
  several jobs both yield an actionable `Error: …` string — the several-jobs one
  names every job id with its status and label, newest first, so the agent can
  simply retry with one of them.
  """

  alias EvoGit.Agent.Tools.Failure
  alias EvoGit.Agent.Tools.Shared
  alias EvoGit.BackgroundJobs

  # Statuses a wait keeps polling through.
  @live_statuses [:running, :stopping]

  # Upper bound on the job ids NAMED by the "multiple jobs" error, so a
  # pathological per-owner list cannot balloon the tool result (the remainder is
  # summarized; `job_list` has the full list).
  @max_named_jobs 10

  # The wait-budget spellings honoured by `wait: true`, in priority order:
  # `timeout_ms` is canonical, `timeout` is the generic convention used by the
  # rest of the tool surface (the one a model reaches for first), `timeoutMs`
  # is tolerated for harness alignment.
  @wait_budget_keys ["timeout_ms", "timeout", "timeoutMs"]

  @doc """
  Returns the tool schema for ReqLLM.
  """
  def schema do
    ReqLLM.tool(
      name: "job_output",
      description:
        "Read a background job: the output produced since the previous read, plus the job's current status.",
      parameter_schema: %{
        "type" => "object",
        "properties" => %{
          "job_id" => %{
            "type" => "string",
            "description" =>
              "Job id returned by the tool that started the background work. May be omitted when this agent has exactly one background job (its output is then read automatically); with several jobs the error lists every id."
          },
          "wait" => %{
            "type" => "boolean",
            "description" =>
              "Block until the job finishes or the budget expires; the result then reports which of the two happened, and an expired budget leaves the job running. Defaults to false."
          },
          "timeout_ms" => %{
            "type" => "integer",
            "description" =>
              "Max wait in milliseconds with wait: true — either milliseconds or a unit string (\"90s\", \"30m\"). `timeout` and `timeoutMs` are accepted aliases for the same budget. Accepts an integer, a float (truncated), or a string with an optional ms/s/m unit (\"120000\", \"120s\", \"30m\"). Defaults to #{BackgroundJobs.wait_default_ms()}, capped at #{BackgroundJobs.wait_max_ms()}. For a job expected to take a while, do ONE long wait (e.g. timeout: \"30m\") instead of re-polling with short budgets."
          },
          "timeout" => %{
            "type" => "integer",
            "description" =>
              "Alias for `timeout_ms` — the same wait budget, for callers using the generic timeout spelling."
          },
          "max_bytes" => %{
            "type" => "integer",
            "description" => Shared.tool_output_limit_description(),
            "default" => 16_384
          }
        },
        "required" => []
      },
      callback: fn _ -> {:ok, nil} end
    )
  end

  @doc """
  Executes the job_output tool.

  Resolves `job_id` (`resolve_job_id/1`): an explicit, non-blank id is used
  as-is; otherwise this agent's OWN jobs are consulted — exactly one is read
  automatically, while zero or several produce an actionable error naming what to
  do next. Optionally honours `wait`, the wait budget (`timeout_ms` / `timeout` /
  `timeoutMs`) and `max_bytes`. Never raises: a non-map `args` returns the
  shared descriptive error string, every registry failure is rendered as an
  `Error: ...` string, and an unexpected raise/exit at the tool boundary is
  caught too.
  """
  def execute(args, _repo_path, _repo_root) do
    with {:ok, job_id} <- resolve_job_id(args) do
      read_job(job_id, args)
    else
      {:error, message} -> Failure.error(message)
    end
  rescue
    e -> Failure.error(Exception.message(e))
  catch
    :exit, reason -> Failure.error(inspect(reason))
  end

  ## Job-id resolution (explicit id, else this agent's only job)

  defp resolve_job_id(args) when not is_map(args),
    do: {:error, "Arguments must be a map/object"}

  defp resolve_job_id(args) do
    case Map.get(args, "job_id") do
      id when is_binary(id) ->
        if String.trim(id) == "", do: resolve_only_job_id(), else: {:ok, id}

      _missing_or_non_string ->
        resolve_only_job_id()
    end
  end

  # The omitted-id path. Ownership is the SAME fence `read/2` applies, and a
  # nil owner is NOT treated as "unscoped" (that would read another agent's job):
  # without an owning agent there is nothing to infer from, so the explicit-id
  # error is kept.
  defp resolve_only_job_id do
    case BackgroundJobs.current_owner_pid() do
      nil ->
        {:error, missing_job_id_error()}

      owner ->
        case BackgroundJobs.list(owner_pid: owner) do
          [%{id: id}] -> {:ok, id}
          [] -> {:error, no_jobs_error()}
          jobs -> {:error, multiple_jobs_error(jobs)}
        end
    end
  end

  defp multiple_jobs_error(jobs) do
    named = jobs |> Enum.take(@max_named_jobs) |> Enum.map_join(", ", &describe_job/1)
    remaining = length(jobs) - @max_named_jobs
    suffix = if remaining > 0, do: ", … and #{remaining} more", else: ""

    "Multiple background jobs exist — pass job_id: #{named}#{suffix}. " <>
      "Call job_list for details."
  end

  defp describe_job(job) do
    status = status_text(job)

    case label_text(job) do
      nil -> "#{job.id} (#{status})"
      label -> "#{job.id} (#{status}, #{inspect(label)})"
    end
  end

  defp label_text(%{label: label}) when is_binary(label) do
    case label |> String.replace(~r/\s+/, " ") |> String.trim() do
      "" -> nil
      text -> String.slice(text, 0, 60)
    end
  end

  defp label_text(_job), do: nil

  @doc false
  # The ONE status-line renderer for background jobs — shared with
  # `EvoGit.Agent.Tools.JobKill`, whose "already finished" result carries the
  # same bracketed line.
  def status_line(job) do
    status = status_text(job)

    case detail_text(job) do
      nil -> "[status: #{status}]"
      detail -> "[status: #{status}, #{detail}]"
    end
  end

  defp read_job(job_id, args) do
    owner = BackgroundJobs.current_owner_pid()

    # Waiting is best-effort: a timed-out (or unusable) wait still falls through
    # to the read below, which reports the real outcome — and the real error
    # when the job is unknown.
    wait = maybe_wait(job_id, args, owner)

    case BackgroundJobs.read(job_id, read_opts(args, owner)) do
      {:ok, %{text: text, job: job}} -> render(text, job, wait)
      {:error, reason} -> Failure.error(error_message(reason, job_id))
    end
  end

  ## Wait loop (caller side — never inside the registry)

  # Upper bound for the exponential poll backoff (ms) — see `next_poll_delay/2`.
  # The wait cap is ~30 min, so a FIXED 100 ms cadence would mean ~18 000 polls
  # (and, for a `:unit`-handled job, ~18 000 SYNCHRONOUS `systemctl --user show`
  # spawns in the single GLOBAL BackgroundJobs registry) per waiting agent.
  # Backing off to at most this keeps the first seconds fast — a short job is
  # still observed promptly — while bounding a long wait to a few hundred probes.
  @poll_backoff_cap_ms 3_000
  # Growth factor of the poll backoff (~1.5× per iteration).
  @poll_backoff_factor 1.5
  # The scheduler-owned ETS table holding per-agent state (its `cancel_requested`
  # flag). Guarded with `:ets.whereis/1` before every probe — see
  # `cancel_requested?/1`.
  @agent_state_table :evogit_agent_state

  # Returns `nil` (no wait requested) or the wait OUTCOME facts the renderer
  # turns into the marker line: how long the wait actually took, the CLAMPED
  # budget it used, whether a cancellation aborted it early, and whether that
  # budget came from an explicit argument or the default (the default-only hint
  # depends on it).
  defp maybe_wait(job_id, args, owner) do
    if Shared.get_optional_boolean(args, "wait", false) do
      {budget_ms, source} = wait_budget(args)
      started_at = System.monotonic_time(:millisecond)
      aborted? = wait_until_terminal(job_id, owner, started_at + budget_ms)

      %{
        elapsed_ms: System.monotonic_time(:millisecond) - started_at,
        budget_ms: budget_ms,
        source: source,
        aborted: aborted?
      }
    else
      nil
    end
  end

  # Returns `true` when the wait was ABORTED by a graceful cancel, `false` when
  # it ended for any other reason (terminal status, foreign/unknown job, or an
  # expired budget).
  defp wait_until_terminal(job_id, owner, deadline) do
    do_wait_until_terminal(job_id, owner, deadline, BackgroundJobs.poll_interval_ms())
  end

  # One probe per iteration: the deadline, then the job's status (a TERMINAL
  # status always wins over a pending cancel, so a job that finished while the
  # cancel was in flight still reports "finished"), then the owning agent's
  # graceful-cancel flag (so a cancelled agent never sits out a 30 minute wait),
  # then a BACKED-OFF sleep.
  defp do_wait_until_terminal(job_id, owner, deadline, poll_ms) do
    if System.monotonic_time(:millisecond) >= deadline do
      false
    else
      case BackgroundJobs.job(job_id, owner_opts(owner)) do
        {:ok, job} ->
          cond do
            terminal?(job) ->
              false

            cancel_requested?() ->
              true

            true ->
              Process.sleep(poll_ms)

              do_wait_until_terminal(
                job_id,
                owner,
                deadline,
                next_poll_delay(poll_ms, @poll_backoff_cap_ms)
              )
          end

        # Unknown or foreign job: stop waiting. The read that follows renders the
        # real, actionable reason — polling again could only repeat it.
        {:error, _reason} ->
          false
      end
    end
  end

  @doc false
  # The pure backoff curve of the wait loop: the NEXT poll delay given the
  # current one, grown by `@poll_backoff_factor` and capped at `cap_ms`. Public
  # (but doc-false) so the curve is unit-testable without waiting it out. A zero
  # base (the `:background_poll_interval_ms` seam allows 0) is floored to 1 ms so
  # the sleep never degenerates into a busy loop.
  def next_poll_delay(current_ms, cap_ms) do
    current_ms
    |> max(1)
    |> Kernel.*(@poll_backoff_factor)
    |> round()
    |> min(cap_ms)
  end

  @doc false
  # True when the OWNING agent has a graceful cancel pending. Read once per wait
  # poll from the job's owning agent id (`:evogit_agent_id`, which `ToolDispatch`
  # re-installs in the tool task's process dictionary) and the scheduler's
  # `cancel_requested` flag.
  #
  # TOTAL by construction, because it runs INSIDE a wait: no agent id (a
  # non-agent caller), a non-integer id, an absent `:evogit_agent_state` table
  # (the app is shutting down) or a raise/exit out of the probe all mean "not
  # cancelled". Crashing here would turn a clean cancel into an `Error: …` string
  # instead of the delta + abort marker, and would fail a wait for a reason that
  # has nothing to do with the job.
  #
  # The table is a PARAMETER (default `:evogit_agent_state`) so a test can probe
  # the absent-table arm without deleting the app-owned singleton table.
  def cancel_requested?(table \\ @agent_state_table) do
    case Process.get(:evogit_agent_id) do
      agent_id when is_integer(agent_id) ->
        :ets.whereis(table) != :undefined and flag_cancel_requested?(agent_id)

      _other ->
        false
    end
  end

  defp flag_cancel_requested?(agent_id) do
    EvoGit.AgentScheduler.Store.cancel_requested?(agent_id) == true
  rescue
    # Justified `try/rescue`: this probe runs inside a long `wait: true` loop and
    # its only failure mode is the app-owned ETS table vanishing between the
    # `whereis/1` guard and the lookup (app shutdown). "Flag unavailable" is the
    # VISIBLE `false` this clause returns — never an agent-facing error, and never
    # an empty catch.
    _ -> false
  catch
    # An exit out of the scheduler store (table gone mid-call) is equally "not
    # cancelled" — it must not abort the wait or crash the tool.
    :exit, _ -> false
  end

  defp terminal?(%{status: status}), do: status not in @live_statuses
  defp terminal?(_job), do: true

  # `{budget_ms, :explicit | :default}` — the budget CLAMPED to
  # `[0, wait_max_ms()]`. The source is derived from whether a key actually
  # yielded a usable duration, so a present-but-unusable value counts as the
  # default (which is what the job actually waited for).
  defp wait_budget(args) do
    max_ms = BackgroundJobs.wait_max_ms()

    case Shared.fetch_duration_ms(args, @wait_budget_keys) do
      {:ok, ms} -> {clamp_ms(ms, max_ms), :explicit}
      :error -> {clamp_ms(BackgroundJobs.wait_default_ms(), max_ms), :default}
    end
  end

  defp clamp_ms(ms, max_ms), do: ms |> min(max_ms) |> max(0)

  ## Read options

  defp read_opts(args, owner), do: [max_bytes: max_bytes(args)] ++ owner_opts(owner)

  defp max_bytes(args) do
    default = EvoGit.Config.resolve([:truncation, :tool_output_default_max_bytes])

    case Shared.get_optional_integer(args, "max_bytes", default) do
      value when is_integer(value) and value > 0 -> value
      _ -> default
    end
  end

  # The ownership fence is passed ONLY when the runner installed an owner pid;
  # otherwise an unscoped lookup is used (fencing on a nil owner would hide every
  # job).
  defp owner_opts(nil), do: []
  defp owner_opts(pid), do: [owner_pid: pid]

  ## Rendering

  defp render(text, job, wait) do
    body =
      case text do
        value when is_binary(value) and value != "" -> value
        _ -> "(no new output)"
      end

    separator = if String.ends_with?(body, "\n"), do: "", else: "\n"

    body <> separator <> status_line(job) <> marker_suffix(wait, job)
  end

  # The wait marker is a SEPARATE line after the status line (never part of it —
  # `status_line/1` is shared with JobKill and must stay byte-identical). A call
  # that did not request `wait: true` renders nothing extra.
  defp marker_suffix(nil, _job), do: ""

  defp marker_suffix(wait, job) do
    status = status_text(job)

    # "Finished" is decided from the job this read returned — the authoritative
    # post-wait state, not the last poll — and WINS over an abort: a job that
    # reached a terminal status in the same iteration the cancel was seen is
    # reported as finished, not aborted.
    line =
      cond do
        terminal?(job) ->
          "[wait: finished after #{wait.elapsed_ms} ms, status: #{status}]"

        wait.aborted ->
          "[wait: aborted after #{wait.elapsed_ms} ms — cancellation requested, status: #{status}]"

        true ->
          expired_marker(wait, status)
      end

    "\n" <> line
  end

  defp expired_marker(%{budget_ms: budget_ms, source: :explicit}, status),
    do: "[wait: #{budget_ms} ms budget expired, status: #{status}]"

  defp expired_marker(%{budget_ms: budget_ms}, status) do
    cap_ms = BackgroundJobs.wait_max_ms()

    "[wait: #{budget_ms} ms budget expired, status: #{status}; " <>
      "pass timeout_ms (or timeout) to wait up to #{cap_ms} ms (\"#{humanize_ms(cap_ms)}\")]"
  end

  # Human form of a budget, rendered from the CAP at call time (never a literal):
  # a whole number of minutes renders as `<n>m`, minutes plus a remainder as
  # `<n>m<n>s`, and anything below one minute as `<n>s` (truncated seconds, so the
  # hint never advertises more than the cap).
  defp humanize_ms(ms) do
    minutes = div(ms, 60_000)
    seconds = rem(div(ms, 1_000), 60)

    cond do
      minutes > 0 and seconds == 0 -> "#{minutes}m"
      minutes > 0 -> "#{minutes}m#{seconds}s"
      true -> "#{seconds}s"
    end
  end

  defp status_text(job) do
    case job do
      %{status: status} -> BackgroundJobs.status_string(status) || "unknown"
      _ -> "unknown"
    end
  end

  defp detail_text(%{detail: detail}) when is_binary(detail) do
    case String.trim(detail) do
      "" -> nil
      text -> text
    end
  end

  defp detail_text(_job), do: nil

  ## Errors

  # Only reachable when `job_id` was omitted AND no owning agent pid is
  # installed, so there is no job list to infer a single job from.
  defp missing_job_id_error do
    "Missing required argument 'job_id'. Please provide a valid value — the id " <>
      "returned by the tool that started the background work (call job_list to see them)."
  end

  defp no_jobs_error do
    "This agent has no background jobs yet, so there is no output to read. " <>
      "Start one with the `bash` tool and `run_in_background: true`, then call " <>
      "job_output again (job_id may be omitted while exactly one job exists)."
  end

  defp error_message(:not_found, job_id) do
    "No background job with id #{inspect(job_id)} is known to this agent. " <>
      "Call job_list to see this agent's background jobs, then retry with a valid id."
  end

  defp error_message(:not_owner, job_id) do
    "Background job #{inspect(job_id)} belongs to another agent, so this agent cannot read it. " <>
      "Call job_list to see this agent's own background jobs."
  end

  defp error_message(message, _job_id) when is_binary(message), do: message
  defp error_message(other, _job_id), do: inspect(other)
end
