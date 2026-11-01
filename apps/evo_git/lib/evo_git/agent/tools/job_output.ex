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
  `EvoGit.BackgroundJobs.job/2` every
  `EvoGit.BackgroundJobs.poll_interval_ms/0` until the job reaches a terminal
  status or the wait budget expires. A timed-out wait leaves the job RUNNING
  and still returns whatever output was produced.

  The wait budget is read (in order) from `timeout_ms`, `timeout` or
  `timeoutMs` — `timeout_ms` is canonical and `timeout` is the generic spelling
  the rest of the tool surface uses. A value may be an integer, a float
  (truncated), or a string holding a number with an optional `ms`/`s`/`m` unit
  (`"60000"`, `"60s"`, `"2m"`). No usable value means the effective default
  `EvoGit.BackgroundJobs.wait_default_ms/0`; every budget is clamped into
  `[0, EvoGit.BackgroundJobs.wait_max_ms/0]`.

  One marker line is then appended AFTER the status line, so a short wait is
  diagnosable instead of looking like a fast success:

      <delta>
      [status: completed, exit code: 0]
      [wait: finished after 142 ms, status: completed]

      (no new output)
      [status: running]
      [wait: 8000 ms budget expired, status: running; pass timeout_ms (or timeout) to wait up to 60000 ms]

  The first marker means the job reached a terminal status during the wait; the
  second means the budget ran out with the job still live (the default-budget
  hint is omitted when the budget was passed explicitly). The marker follows
  the `[status: …]` line byte-identically — the status line itself is unchanged.
  """

  alias EvoGit.Agent.Tools.Failure
  alias EvoGit.Agent.Tools.Shared
  alias EvoGit.BackgroundJobs

  # Statuses a wait keeps polling through.
  @live_statuses [:running, :stopping]

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
            "description" => "Job id returned by the tool that started the background work."
          },
          "wait" => %{
            "type" => "boolean",
            "description" =>
              "Block until the job finishes or the budget expires; the result then reports which of the two happened, and an expired budget leaves the job running. Defaults to false."
          },
          "timeout_ms" => %{
            "type" => "integer",
            "description" =>
              "Max wait in milliseconds with wait: true. `timeout` and `timeoutMs` are accepted aliases for the same budget. Accepts an integer, a float (truncated), or a string with an optional ms/s/m unit (\"60000\", \"60s\", \"2m\"). Defaults to #{BackgroundJobs.wait_default_ms()}, capped at #{BackgroundJobs.wait_max_ms()}."
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
        "required" => ["job_id"]
      },
      callback: fn _ -> {:ok, nil} end
    )
  end

  @doc """
  Executes the job_output tool.

  Reads `job_id` (required) and optionally honours `wait`, the wait budget
  (`timeout_ms` / `timeout` / `timeoutMs`) and `max_bytes`. Never raises: a
  missing/non-string argument returns the shared descriptive error string,
  every registry failure is rendered as an `Error: ...` string, and an
  unexpected raise/exit at the tool boundary is caught too.
  """
  def execute(args, _repo_path, _repo_root) do
    with {:ok, job_id} <- Shared.fetch_string_arg(args, "job_id") do
      read_job(job_id, args)
    else
      {:error, message} -> Failure.error(message)
    end
  rescue
    e -> Failure.error(Exception.message(e))
  catch
    :exit, reason -> Failure.error(inspect(reason))
  end

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

  # Returns `nil` (no wait requested) or the wait OUTCOME facts the renderer
  # turns into the marker line: how long the wait actually took, the CLAMPED
  # budget it used, and whether that budget came from an explicit argument or
  # the default (the default-only hint depends on it).
  defp maybe_wait(job_id, args, owner) do
    if Shared.get_optional_boolean(args, "wait", false) do
      {budget_ms, source} = wait_budget(args)
      started_at = System.monotonic_time(:millisecond)
      :ok = wait_until_terminal(job_id, owner, started_at + budget_ms)

      %{
        elapsed_ms: System.monotonic_time(:millisecond) - started_at,
        budget_ms: budget_ms,
        source: source
      }
    else
      nil
    end
  end

  defp wait_until_terminal(job_id, owner, deadline) do
    if System.monotonic_time(:millisecond) >= deadline do
      :ok
    else
      case BackgroundJobs.job(job_id, owner_opts(owner)) do
        {:ok, job} ->
          if terminal?(job) do
            :ok
          else
            Process.sleep(BackgroundJobs.poll_interval_ms())
            wait_until_terminal(job_id, owner, deadline)
          end

        # Unknown or foreign job: stop waiting. The read that follows renders the
        # real, actionable reason — polling again could only repeat it.
        {:error, _reason} ->
          :ok
      end
    end
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
    # post-wait state, not the last poll.
    line =
      if terminal?(job) do
        "[wait: finished after #{wait.elapsed_ms} ms, status: #{status}]"
      else
        expired_marker(wait, status)
      end

    "\n" <> line
  end

  defp expired_marker(%{budget_ms: budget_ms, source: :explicit}, status),
    do: "[wait: #{budget_ms} ms budget expired, status: #{status}]"

  defp expired_marker(%{budget_ms: budget_ms}, status) do
    "[wait: #{budget_ms} ms budget expired, status: #{status}; " <>
      "pass timeout_ms (or timeout) to wait up to #{BackgroundJobs.wait_max_ms()} ms]"
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
