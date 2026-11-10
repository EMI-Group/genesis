defmodule EvoGit.ToolRuntime.Executor do
  @moduledoc """
  The engine that executes ONE batch of standard (non-subagent) tool calls.

  Everything the AGENT used to own lives here: batch partition into the SERIAL
  (file-mutating) and PARALLEL groups, per-call timeout resolution, the tool-slot
  gate, `EvoGit.ProcessManager` tracking, the spawned tool task, failure
  containment and the sanitize pipeline. The caller supplies a
  `EvoGit.ToolRuntime.Request` and receives `{index, tool_call_id, name, output}`
  tuples in request order.

  Delegation hints and the redundant-cd warning are NOT applied here: they are
  agent-side, process-dictionary-backed bookkeeping and run in the parent agent
  process (`EvoGit.Agent.ToolDispatch.apply_tool_output_tracking/3`).
  """

  alias EvoGit.Agent.ToolInvocation
  alias EvoGit.AgentScheduler
  alias EvoGit.ToolRuntime.Output
  alias EvoGit.ToolRuntime.Request
  alias EvoGit.ToolRuntime.Tracking

  # Extra per-call headroom (ms) after approval for elixir_eval write/sudo:
  # covers the engine's 5s execution cap plus bounded cleanup/authorization.
  # Also retained for legacy level-2/3 run_command timeout compatibility.
  @approval_execution_buffer 30_000

  @type result :: {non_neg_integer(), String.t(), String.t(), term()}

  @doc """
  Executes `indexed_calls` (`[{ReqLLM.ToolCall.t(), index}]`) for one request.

  Returns the batch SORTED BY INDEX as `{index, tool_call_id, name, output}`
  tuples, where `output` is the sanitized tool output (`String.t()`,
  `%EvoGit.Agent.ToolOutput{}` or `nil`).
  """
  @spec execute_batch([{ReqLLM.ToolCall.t(), non_neg_integer()}], Request.t()) :: [result()]
  def execute_batch(indexed_calls, %Request{} = request) do
    # Resolved ONCE per batch (it reads configuration) and threaded into every
    # call's tracking meta; `Tracking.tracked_backend/2` then picks the SANDBOX
    # backend for a shell call and `:builtin` for every other tool.
    backend = Tracking.backend()

    # Partition the batch: tool calls that read-modify-write files
    # (`EvoGit.Agent.Tools.serial_tool?/1` — the single classification source of
    # truth) must NOT overlap each other, because each reads the ORIGINAL bytes
    # and the last write wins, silently discarding every other same-file edit in
    # the batch. Run them SEQUENTIALLY in this (parent agent) process, one call
    # at a time, in request order. Everything else stays concurrent below.
    #
    # The SERIAL phase runs FIRST, deliberately: a file mutation then always
    # lands BEFORE any read or shell command in the same batch that could
    # observe it, so `[write_file x.ex, run_bash "mix test"]` and
    # `[edit_file x, read_file x]` behave as the model expects. The reverse
    # order would let a same-batch read/exec observe stale bytes.
    {serial_calls, parallel_calls} =
      Enum.split_with(indexed_calls, fn {call, _index} ->
        EvoGit.Agent.Tools.serial_tool?(ReqLLM.ToolCall.name(call))
      end)

    serial_outputs =
      Enum.map(serial_calls, fn {call, index} ->
        run_tool_call(call, index, request, backend)
      end)

    # Execute the remaining standard tool calls CONCURRENTLY, bounded only
    # by the scheduler's tool-slot pool: each parallel task still acquires a
    # tool slot via `AgentScheduler.with_tool_slot/2` inside
    # `execute_tool_with_timeout/4` (respecting `max_tool_concurrency`).
    # `max_concurrency` is set to the batch size so every call starts
    # immediately — Elixir's `max_concurrency` only accepts positive integers
    # (`:infinity` is valid for `timeout` only) — making the scheduler, not a
    # local cap, the binding constraint. `ordered: true` keeps results in index
    # order. `timeout: :infinity` defers timeout enforcement to the per-tool
    # timeout logic inside `execute_tool_with_timeout/4` (an outer stream
    # timeout would wrongly kill legitimate long-running tools).
    concurrency = max(1, length(parallel_calls))

    parallel_outputs =
      parallel_calls
      |> Task.async_stream(
        fn {call, index} -> run_tool_call(call, index, request, backend) end,
        max_concurrency: concurrency,
        ordered: true,
        timeout: :infinity
      )
      |> Enum.map(fn
        {:ok, result} -> result
        {:exit, {%_{} = exception, stacktrace}} -> reraise(exception, stacktrace)
        {:exit, reason} -> exit(reason)
      end)

    # Both phases ran in request-independent order, so re-sort by index: the LLM
    # must receive results in request order.
    (serial_outputs ++ parallel_outputs) |> Enum.sort_by(fn {index, _, _, _} -> index end)
  end

  # Runs a single tool call's execution, returning
  # `{index, tool_call_id, name, output}`, where `output` is
  # `String.t() | %ToolOutput{} | nil` — a plain binary for an all-text result
  # (the legacy shape) and a `%ToolOutput{}` only when the tool attached media.
  # Used by BOTH batch phases: sequentially in the parent process for the serial
  # (file-mutating) group and inside the `Task.async_stream` worker for the
  # parallel group.
  #
  # Arguments go through the tolerant three-stage parse
  # (`EvoGit.Agent.ToolInvocation.arguments/1`): a decoded JSON object is passed
  # to the tool layer, a non-blank but unparseable argument string is passed
  # through RAW (the tool layer answers with a self-correcting error), and when
  # nothing is recoverable the call is answered with a normal
  # `Error: invalid arguments: …` result. This is the fix for the crash path:
  # `ReqLLM.ToolCall.args_map/1` returns nil for undecodable arguments, and a
  # nil reaching `EvoGit.Agent.Tools.execute/5` (whose clauses are `is_map` /
  # `is_binary`) raised `FunctionClauseError` inside the LINKED tool task and
  # killed the whole agent instead of letting the model self-correct.
  defp run_tool_call(call, index, request, backend) do
    name = ReqLLM.ToolCall.name(call)
    tool_call_id = call.id || name || "unknown"

    case ToolInvocation.arguments(call) do
      {:ok, args} ->
        {index, tool_call_id, name, execute_tool_with_timeout(name, args, request, backend)}

      {:error, reason} ->
        # An unusable argument payload still produced a NORMAL tool result (a
        # self-correcting error string), but no tool ever ran: the record is
        # settled `:failed` with the `:invalid_arguments` terminal fact.
        exec_id = Tracking.track(request, name, nil, backend)
        Tracking.finish(exec_id, :failed, reason: :invalid_arguments)

        {index, tool_call_id, name, ToolInvocation.invalid_arguments_result(reason)}
    end
  end

  # Runs a single tool call inside a tool slot with an async task, bounded
  # timeout, process-manager tracking and output sanitization/truncation
  # feedback.
  #
  # The per-call timeout rule lives in `EvoGit.Agent.ToolInvocation.resolve_timeout/4`:
  # an explicit `timeout` argument wins (clamped by `[:scheduler,
  # :max_tool_timeout]`), an OMITTED timeout on the platform shell tool
  # (`bash` / `run_bash` / `run_powershell` / `pwsh` / `shell` / …) gets a
  # generous 120 s default — the shell schema advertises a long timeout, so a
  # long test run that simply omits the argument must not be silently cut at the
  # generic 10 s `[:scheduler, :default_tool_timeout]` — and every other tool
  # keeps that configured default.
  #
  # The ADVERTISED-DEFAULT seam (`EvoGit.Agent.Tools.default_timeout_ms/1`) is
  # then applied on top: a tool that publishes its own default timeout for the
  # "model omitted the argument" case (today the platform shell tool's 120 s)
  # raises the resolved timeout to that value. It is a pure MAX — it can never
  # LOWER the resolved timeout, so `resolve_timeout/4`'s own shell fallback and
  # an explicit `timeout` argument are both unaffected — and it is clamped by
  # the same `max_timeout`. The one exception is a tool whose `timeout` argument
  # is an INTERNAL wait budget (`EvoGit.Agent.Tools.timeout_arg_is_wait_budget?/1`
  # — `job_output`), where the advertised default is a FLOOR even against an
  # explicit argument (see `apply_advertised_tool_timeout/4`).
  #
  # `request.agent_id` is what the tool slot pool is acquired under.
  defp execute_tool_with_timeout(name, args, %Request{} = request, backend) do
    max_timeout = request.max_timeout

    tool_timeout =
      ToolInvocation.resolve_timeout(
        name,
        args,
        EvoGit.Agent.DelegationHints.default_tool_timeout(),
        max_timeout
      )

    tool_timeout = apply_advertised_tool_timeout(tool_timeout, name, args, max_timeout)

    tool_timeout =
      if approval_window_tool_call?(name, args) do
        # Write/sudo elixir_eval waits for exact-code approval before evaluation.
        # Floor even an explicit outer `timeout` to the approval window plus
        # execution/cleanup headroom; `timeout_ms` is ONLY the inner engine cap.
        # The configured scheduler max remains authoritative, even if shorter
        # than the approval window. Read/invalid tiers get no approval floor.
        # Legacy run_command timeout policy is retained despite refused dispatch.
        approval_timeout = EvoGit.CommandApproval.timeout()
        tool_timeout |> max(approval_timeout + @approval_execution_buffer) |> min(max_timeout)
      else
        tool_timeout
      end

    exec_id = Tracking.track(request, name, args, backend)

    AgentScheduler.with_tool_slot(request.agent_id, fn ->
      # The phase's OWN process must expose the exec id for its duration (the
      # shell tool reads it to attach the real OS handle), and must not leak it
      # past this call — the serial phase runs in the long-lived agent process.
      previous_exec_id = Process.get(:evogit_execution_id)
      Process.put(:evogit_execution_id, exec_id)

      try do
        task = start_tool_task(name, args, request, exec_id)

        case Task.yield(task, tool_timeout) || Task.shutdown(task) do
          {:ok, {:tool_crashed, message}} ->
            Tracking.finish(exec_id, :failed, reason: {:crashed, message})
            "Error: Tool execution crashed: #{message}"

          {:ok, {:error, reason}} ->
            Tracking.finish(exec_id, :failed, reason: {:tool_error, reason})
            "Error: #{inspect(reason)}"

          {:ok, result} ->
            # A builtin call has no OS process to exit, so its outcome is
            # `:no_os_process`. For a shell call the SANDBOX layer has already
            # settled the record `:exited` with its real exit code, and
            # `ProcessManager.finish/3` is idempotent — the first fact wins — so
            # this unconditional call never overwrites it.
            Tracking.finish(exec_id, :completed, reason: :no_os_process)
            # Wrap → sanitize → truncation-feedback → re-wrap, all in one place
            # (the wrap boundary — see `Output.sanitize/3`). A plain binary
            # return round-trips BYTE-IDENTICALLY; a media-carrying return keeps
            # its attachments.
            Output.sanitize(result, name, args)

          {:exit, reason} ->
            Tracking.finish(exec_id, :failed, reason: {:crashed, reason})
            "Error: Tool execution crashed: #{inspect(reason)}"

          nil ->
            # The tool task was stopped, but the OS process it started is not
            # necessarily dead: kill the handle first, then settle the record
            # (both calls are total and idempotent). The kill's terminal fact is
            # `:timeout`; a builtin record (no OS handle, so the kill has
            # nothing to stop) is settled by the follow-up finish.
            Tracking.kill(exec_id, :timeout)
            Tracking.finish(exec_id, :killed, reason: :timeout)

            "Error: Tool execution timed out after #{tool_timeout}ms. Some output may have been partially captured by the tool."
        end
      after
        restore_exec_id(previous_exec_id)
      end
    end)
  end

  defp restore_exec_id(nil), do: Process.delete(:evogit_execution_id)
  defp restore_exec_id(previous), do: Process.put(:evogit_execution_id, previous)

  # Starts the tool task on the dedicated `EvoGit.ToolRuntime.TaskSupervisor`
  # when it is running, else as a plain `Task.async/1`. Deliberately still
  # LINKED (`async/2`, never `async_nolink/2`): the containment inside
  # `execute_tool_task/4` is what makes a crashing tool survivable, so the link
  # keeps the historical exit semantics intact.
  defp start_tool_task(name, args, %Request{} = request, exec_id) do
    fun = fn -> execute_tool_task(name, args, request, exec_id) end

    case Process.whereis(EvoGit.ToolRuntime.TaskSupervisor) do
      pid when is_pid(pid) -> Task.Supervisor.async(EvoGit.ToolRuntime.TaskSupervisor, fun)
      _not_running -> Task.async(fun)
    end
  end

  # Applies a tool's OWN advertised default timeout
  # (`EvoGit.Agent.Tools.default_timeout_ms/1`) to the resolved per-call timeout.
  #
  # Pure MAX + `max_timeout` clamp: `min(max(resolved, advertised), max_timeout)`.
  # It can only RAISE the resolved timeout, never lower it, so the platform-shell
  # 120 s fallback in `ToolInvocation.resolve_timeout/4` and a resolved value
  # that is already larger both survive untouched.
  #
  # Two branches:
  #
  #   * `EvoGit.Agent.Tools.timeout_arg_is_wait_budget?/1` (today only
  #     `job_output`, whose `timeout` argument bounds its INTERNAL `wait: true`
  #     loop rather than the whole call): the advertised value is a FLOOR even
  #     when an explicit `timeout` argument is present — an explicit value may
  #     still RAISE the ceiling, but never lower it below the advertised wait
  #     default (the 60 s wait cap plus headroom), so
  #     `{"wait": true, "timeout": "60s"}` cannot be killed by the dispatcher at
  #     exactly 60 s.
  #   * every other tool: an explicit `timeout` argument (any usable duration
  #     shape — see `explicit_timeout_arg?/1`) means the model asked for a
  #     specific budget, so the advertised default does not apply — that is the
  #     same "explicit wins" rule `resolve_timeout/4` implements (pinned for the
  #     platform shell by `test/evo_git/agent/tool_dispatch_test.exs`).
  defp apply_advertised_tool_timeout(resolved, name, args, max_timeout) do
    case EvoGit.Agent.Tools.default_timeout_ms(name) do
      advertised when is_integer(advertised) and advertised > 0 ->
        if explicit_timeout_arg?(args) and
             not EvoGit.Agent.Tools.timeout_arg_is_wait_budget?(name) do
          resolved
        else
          resolved |> max(advertised) |> min(max_timeout)
        end

      _no_advertised_default ->
        resolved
    end
  end

  # True when `args` carries a usable explicit `timeout`: any duration shape the
  # tool surface accepts (an integer, a float, or a numeric string with an
  # optional `ms`/`s`/`m` unit — `"60000"`, `"90s"`, `"30m"`), parsed by the ONE
  # duration helper `EvoGit.Agent.Tools.Shared.fetch_duration_ms/2` and POSITIVE
  # (a zero/negative or unusable value means "absent"). This is the SAME
  # recognition `ToolInvocation.resolve_timeout/4` applies, so the "explicit wins"
  # rule can never disagree with the resolved timeout.
  # TOTAL: the tolerant arguments parse can hand the dispatcher a RAW string, a
  # nil or anything else — only a map can declare a `timeout`.
  defp explicit_timeout_arg?(args) when is_map(args) do
    case EvoGit.Agent.Tools.Shared.fetch_duration_ms(
           %{"timeout" => Map.get(args, "timeout")},
           ["timeout"]
         ) do
      {:ok, timeout} when timeout > 0 -> true
      _absent_or_unusable -> false
    end
  end

  defp explicit_timeout_arg?(_args), do: false

  # The body of one tool-execution task. Runs INSIDE the spawned task and
  # therefore contains the failure containment described below.
  defp execute_tool_task(name, args, %Request{} = request, exec_id) do
    # Spawned tasks do NOT inherit the caller's process dictionary, so
    # re-install the resolved per-task tmpdir unconditionally — every tool
    # that consults `EvoGit.Sandbox.resolve_tmpdir/0` (sandbox TMPDIR
    # injection, commit-message files, skill scripts, partial outputs)
    # must see the correct dir. A nil value is harmless (`current/0`
    # returns nil for a non-binary).
    EvoGit.TaskTmpdir.put_current(request.taskdir)

    # EVERY tool task gets the full owner identity (no `run_command` special
    # case):
    #
    #   * `:evogit_agent_pid` — the AGENT's pid, read by
    #     `EvoGit.BackgroundJobs.current_owner_pid/0` to bind a detached job's
    #     lifetime to its owner. It MUST be the agent pid, never `self()` here:
    #     this tool task is shut down the moment the tool returns
    #     (`Task.yield/2 || Task.shutdown/1`), so a job monitored on it would be
    #     killed instantly — the agent pid is the one lifetime signal covering
    #     agent completion, crash, graceful cancel and force-kill.
    #   * `:evogit_agent_id` / `:evogit_task_id` — read by the command-approval
    #     gate (`EvoGit.CommandShell.request_approval/3`) and by the
    #     task-control/background-job tools that report who acted.
    Process.put(:evogit_agent_id, request.agent_id)
    Process.put(:evogit_task_id, request.task_id)
    Process.put(:evogit_agent_pid, request.agent_pid)

    Process.put(:repo_path, request.repo_path)
    Process.put(:genesis_repo_root, request.repo_root)

    # The ROLE-GUARD inputs `EvoGit.Agent.Tools.execute/5` consults
    # (`maybe_block_repo_less/5`, `maybe_block_read_only_foreign_repo/5`).
    # Re-installed here because a spawned task has an EMPTY process dictionary —
    # without them a repo-less or read-only-foreign-repo agent would silently
    # bypass its write guards inside the task.
    Process.put(:repo_less, request.role.repo_less)
    Process.put(:foreign_repos, request.role.foreign_repos)
    Process.put(:evogit_repo_id, request.role.repo_id)

    # Read by the shell tool to attach the real OS handle to this execution.
    Process.put(:evogit_execution_id, exec_id)

    # Reason for the try/rescue/catch: the tool task is LINKED to the agent
    # process, so a RAISING tool implementation (a wrong-typed argument, an
    # unresolved executable inside a tool, a buggy custom tool) would kill the
    # whole agent before `Task.yield/2` could ever observe it — the caller's
    # `{:exit, reason}` arm is unreachable for raises, because the linked exit
    # signal is delivered directly and the agent does not trap exits. Containing
    # the failure HERE converts it into a normal tool result
    # (`Error: Tool execution crashed: …`) that the model can self-correct from
    # on the next turn. `:kill` (this module's own timeout shutdown) and the
    # `:shutdown`/`:normal` exit family are re-raised unchanged so a legitimate
    # task exit is never swallowed and still reaches the `{:exit, reason}` arm.
    try do
      EvoGit.Agent.Tools.execute(
        name,
        args,
        request.repo_path,
        request.repo_root,
        request.node_path
      )
    rescue
      exception ->
        {:tool_crashed, Exception.format_banner(:error, exception)}
    catch
      :exit, reason when reason in [:normal, :shutdown, :kill] ->
        exit(reason)

      :exit, {:shutdown, _} = reason ->
        exit(reason)

      kind, reason ->
        {:tool_crashed, "#{kind} #{inspect(reason)}"}
    end
  end

  # Only exact valid write/sudo tiers can wait on evaluator approval. Missing
  # tier means read; invalid values fail fast in the tool without this floor.
  defp approval_window_tool_call?("elixir_eval", %{"tier" => tier})
       when tier in ["write", "sudo"],
       do: true

  # Legacy timeout compatibility only: Tools.execute/5 refuses run_command.
  # Command paths at level >= 2 historically waited for interactive approval.
  defp approval_window_tool_call?("run_command", %{"command" => command})
       when is_binary(command) do
    first_token = command |> String.trim() |> String.split(~r/\s+/, parts: 2) |> hd()
    EvoGit.CommandShell.security_level(first_token) >= 2
  end

  defp approval_window_tool_call?(_name, _args), do: false
end
