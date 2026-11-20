# EvoGit.ToolRuntime — managed tool-call runtime

## Intent
Owns the EXECUTION of a batch of standard (non-subagent) agent tool calls: serial/parallel partition, per-call timeouts, tool slots, the spawned tool task, `EvoGit.ProcessManager` tracking and the sanitize pipeline.
The agent no longer owns concurrency logic: `EvoGit.Agent.ToolDispatch.batch_execute_tools/4,5` resolves ONE `%EvoGit.ToolRuntime.Request{}` (owner identity, repo paths, node path, taskdir, role) and delegates.

## API Surface
- `EvoGit.ToolRuntime.execute_batch(indexed_calls, %Request{}) :: [result()]` — the facade; results are SORTED BY INDEX, sanitized but NOT hint-adjusted.
- The batch result types are declared ONCE, in `EvoGit.ToolRuntime`: `output() :: String.t() | EvoGit.Agent.ToolOutput.t() | nil` (a plain binary for all-text output, a `%ToolOutput{}` when the tool attached media, `nil` for no output) and `result() :: {non_neg_integer(), String.t(), String.t() | nil, output()}` (`index`, `tool_call_id`, the model-facing `name` — `nil` when the call carried none — and the sanitized `output()`); `EvoGit.ToolRuntime.Executor` references those remote types and declares no local duplicate.
- `EvoGit.ToolRuntime.Request.new(map_or_keyword)` — `%Request{agent_id, task_id, agent_pid, repo_path, repo_root, node_path, taskdir, max_timeout, delegation_level, agent_module, role}`; `role` is `%{repo_less: boolean(), foreign_repos: list(), repo_id: String.t() | nil}`.
- `Request.new/1` defaults: `max_timeout` = `EvoGit.Agent.DelegationHints.max_tool_timeout/0`, `delegation_level` = `:high`, `role` = `%{repo_less: false, foreign_repos: [], repo_id: nil}`; other fields `nil`.
- `EvoGit.ToolRuntime.Output.sanitize(result, name, args)` — wrap → `OutputSanitizer.sanitize_and_truncate/3` → `TruncationFeedback.append_truncation_feedback/3` → re-wrap; an all-text output collapses back to a plain binary.
- `EvoGit.ToolRuntime.Tracking.backend/0` (`:systemd | :bwrap | :sandbox_exec | :none`, resolved ONCE per batch), `tracked_backend(name, sandbox_backend)` (the per-call pick), `track(request, name, args, backend) :: String.t() | nil`, `finish(id, status, opts \\ [])` (`exit_code:`/`reason:`), `kill(id, reason)`.

## Constraints
- Tracking is observability: EVERY call is failure-isolated (debug log + documented fallback) and `nil` ids are tolerated, so a dead/restarting registry can never change a tool result.
- `Tracking.track/4` records `kind: :tool_call` meta: `tool`, `command` (shell calls only, map args only), `label` (`"<name>: <first line>"` truncated to ~80 chars, else the tool name), `agent_id`, `task_id`, `owner_pid` (the AGENT pid), `cwd`, `repo_root`, `backend` (the per-call pick below), `runtime: :foreground`.
- Shell detection is ALIAS-AWARE via `EvoGit.Agent.ToolNames.normalize/1 == shell_tool_name/0`.
- The tool task is spawned on `EvoGit.ToolRuntime.TaskSupervisor` when registered (fallback `Task.async/1`), deliberately LINKED — never `async_nolink` — and keeps the `try/rescue/catch` containment that turns a crashing tool into a RAW failure payload.
- Crash containment carries the failure UNCHANGED: the tool task answers `{:tool_crashed, kind, reason, stacktrace}` (rescue → `{:tool_crashed, :error, exception, __STACKTRACE__}`, catch → `{:tool_crashed, kind, reason, __STACKTRACE__}`) and the runtime formats it exactly ONCE with `Exception.format/3` at the reporting boundary, so the exception CLASS and the stacktrace reach BOTH the tracked terminal fact (`{:crashed, detail}`) and the model-facing text; the only exceptions are the `:normal`/`:shutdown`/`:kill`/`{:shutdown, _}` exit family, re-raised unchanged.
- A spawned task has an EMPTY process dictionary: the tool task re-installs tmpdir, owner identity, `:repo_path`/`:genesis_repo_root`, the role-guard inputs (`:repo_less`, `:foreign_repos`, `:evogit_repo_id`) and `:evogit_execution_id`.
- Delegation hints and the redundant-cd warning stay AGENT-side (`ToolDispatch.apply_tool_output_tracking/3`), applied after the batch in the parent process, in index order.
- Do NOT duplicate timeout or slot logic here and in `agent/tool_dispatch.ex`; this node is the ONLY execution engine.

## Per-call backend & terminal facts
- The batch resolves the sandbox backend once; each record's `backend` is the PER-CALL pick: the resolved sandbox backend for the platform shell tool, `:builtin` for every other tool.
- `:builtin` means the call ran INSIDE the BEAM (a non-shell built-in tool) and has no OS process: it never attaches a handle, is never sampled, and its control answers `{:error, :no_os_process}`.
- ONE terminal-fact vocabulary on the record: `:exit_code` (an integer 0..255 when a real OS process exited, else `nil`) and `:reason` (`nil` while live) — `:exited | :timeout | :invalid_arguments | :owner_died | {:killed_by, actor} | {:crashed, detail} | :no_os_process | {:tool_error, reason}`.
- Status mapping (`Execution.status_for_reason/1`): `:completed` for `:exited` (even a non-zero exit code) and `:no_os_process`; `:failed` for `:invalid_arguments`, `{:crashed, _}`, `:owner_died` and `{:tool_error, _}`; `:killed` for `:timeout` and `{:killed_by, _}`.
- `{:tool_error, reason}` is an additive extension of the core reason vocabulary, carrying the reason a tool answered `{:error, reason}` with.
- Ownership split: the SANDBOX layer settles a shell call `:exited` with its real exit code, while this layer settles the builtin, malformed-arguments, crash, timeout and tool-error outcomes.
- `ProcessManager.finish/3` is idempotent — the FIRST fact wins — so the unconditional `:completed` + `:no_os_process` of the success arm never overwrites a shell call's `:exited` fact (no backend branch is needed).
- Per-call settlement lives in the RUNTIME process, not the tool task: `:failed` + `:invalid_arguments` on the malformed-arguments path, `:failed` + `{:crashed, Exception.format/3 detail}` on `{:tool_crashed, kind, reason, stacktrace}`/`{:exit, _}`, `:failed` + `{:tool_error, reason}` on `{:error, reason}`, and `kill(:timeout)` followed by `:killed` + `:timeout` on a `Task.yield` timeout.
- `Tracking.kill(id, :timeout)` settles the terminal fact `:timeout`; every other kill reason settles `{:killed_by, :tool_runtime}`, with the human prose kept in the record's `control_log`.
- `finish/3` and `kill/2` are total (a `nil` or non-binary id is a no-op) and never raise into the tool path.

## Timeout cleanup ordering
- When `Task.yield/2` expires, the runtime synchronously calls `Tracking.kill/2` BEFORE `Task.shutdown/1`, so runtime-initiated shutdown cannot release the task-owned permit before external containment cleanup is attempted.
- A late result returned by shutdown is discarded: an expired yield always returns the timeout error, with terminal settlement still subject to ProcessManager's first-fact-wins rule.
- Successful background launches keep the existing registry-owned permit handoff; neither the tool task nor the runtime's final release can free a permit owned by the background registry.
- Tracking remains best-effort: unavailable tracking, a missing handle, backend kill failure, or a tool task independently finishing/dying during cleanup cannot provide a strict external-process teardown barrier.

## Routing Table

- `./policy.ex` → pure alias-normalized `Policy.limited?/1`, the single resource-admission classification with conservative unknown/custom fallback.
- `./request.ex` → `%EvoGit.ToolRuntime.Request{}` (the one batch context struct) + `new/1` defaults.
- `./executor.ex` → the execution engine: `execute_batch/2`, serial/parallel partition, per-call timeout resolution, slot acquisition, the spawned tool task and its pd re-installation, per-arm terminal settlement.
- `./tracking.ex` → `EvoGit.ProcessManager` integration (`kind: :tool_call`): batch backend probe, per-call backend pick, `track/4`, `finish/3`, `kill/2`, label/command derivation.
- `./output.ex` → `Output.sanitize/3`, the sanitize/wrap boundary shared with `ToolDispatch.sanitize_tool_result/3`.
- Sandbox execution handles / `:execution_id` → `../sandbox/CONTEXT.md`; the registry itself → `../process_manager.ex`; the timeout + hint policy owned agent-side → `../agent/CONTEXT.md`; per-task tmpdir → `../sandbox/` (`EvoGit.TaskTmpdir`).

## Batch partition, task topology & pd installation

Detail moved here from `../agent/CONTEXT.md` because this node is the ONLY execution engine.
- **SERIAL** (FIRST, in the PARENT agent process, request order) = the file-mutating subset (`create_files`, `write`/`write_file`, `edit`/`edit_file`, `make_dir`, `write_context`, `edit_context`, the five `skill_*` writers, any custom write tool) plus `elixir_eval` at EVERY tier; file mutation is NON-ATOMIC read-modify-write and evaluator serialization prevents overlapping approval/effect sequences.
- **PARALLEL** = everything else (readers + `bash`/`run_git`/`web_search`) via `Task.async_stream` (`max_concurrency` = group size, `ordered: true`, `timeout: :infinity` — the per-tool timeout lives inside `Executor.execute_tool_with_timeout/4`); results are re-sorted by index BEFORE the parent applies hint tracking, and the group may hold several git calls contending on `index.lock`.
- Resource admission is centralized in `Policy.limited?/1`, independent of serial classification, ProcessManager backend and shell background arguments.
- Alias-normalized file/context read/create/edit/write, make_dir, list_dir, glob, job controls/output waits, elixir_eval, the explicitly inventoried Genesis task controls/follow tool and refused legacy run_command bypass permits.
- The explicit local skill metadata/file inventory also bypasses permits: skill_list, skill_read, skill_add, skill_edit, skill_remove, skill_enable, skill_disable and skill_where; these manage skill files/frontmatter rather than executing skill bodies.
- Shell, run_git, external rg, history/context search, network, LSP, skill-body execution, genesis_source and unknown/custom names are limited by default; no prefixes grant exemptions.
- `Executor.execute_tool_with_timeout/4` creates tracking BEFORE `AgentScheduler.acquire_tool_permit(agent_id)`; admission returns `{:ok, permit}` or `{:error, reason}`, and queue waiting remains outside the per-tool timeout.
- A permit is unique per call, initially owned by the acquiring runtime process, then transferred synchronously to the spawned tool task before a reference-tagged start handshake allows its body to run.
- The tool task installs `:evogit_tool_permit` (nil for bypass calls), and releases in after; the runtime also releases in after to cover spawn/transfer failure, relying on idempotent OWNER-ENFORCED release that cannot free a permit transferred elsewhere.
- Scheduler contract: transfer_tool_permit(permit, pid) returns :ok or {:error, reason}, only the current owner may transfer/release, transfer changes the monitored owner atomically, and owner DOWN reclaims permits even on brutal task shutdown.
- Background shell launch acquires exactly once, identically to foreground; BackgroundJobs must synchronously transfer the task-owned PD permit to its registry for the detached lifetime before the launch tool returns, with no second acquisition.
- BackgroundJobs integration owns failed-launch rollback/release and terminal-job release; its public caller-side handoff must execute as the tool task (a registry cannot transfer a token owned by its caller), while unrelated task/runtime after releases must be harmless non-owner rejections.
- Invocation identity (`call.id` and batch index) is used only for result correlation; permit uniqueness is supplied by scheduler acquisition, not by agent_id or invocation reuse.
- `Tracking.track/4` always marks `runtime: :foreground`, and successful launch calls are settled `:no_os_process` by the generic success arm unless a lower layer has already settled that call's record; the detached job's separate record and lifetime belong to `BackgroundJobs`, outside this node.
- **A tool body NEVER runs in the agent process**: `run_tool_call/4` → `execute_tool_with_timeout/4` → `with_tool_slot/2` (blocking grant, `fun.()` in the CALLER) → a spawned task, so `self()` inside `Tools.execute/5` is the TOOL-TASK pid. SERIAL: spawned BY THE AGENT → linked, `$callers` = `[agent_pid, …]`; PARALLEL: spawned by a stream WORKER → `$callers` = `[worker_pid, agent_pid, …]`, workers monitored (not linked) so a worker crash does not kill the agent (the stream's `{:exit, …}` arm re-raises in the agent).
- Tool tasks inherit NO pd: the request is resolved ONCE per batch and `execute_tool_task/4` re-installs the tmpdir, the owner identity (`:evogit_agent_id`, `:evogit_task_id`, `:evogit_agent_pid`), `:repo_path`/`:genesis_repo_root`, the role-guard inputs (`:repo_less`, `:foreign_repos`, `:evogit_repo_id` from `request.role`) and `:evogit_execution_id` per call — so the pd-based role guards DO enforce on both dispatch paths, while direct `Tools.execute/5` tests with role keys in the calling process prove nothing.
- `Request.agent_pid` MUST be the durable AGENT owner, never a short-lived tool task pid and never an exchange WORKER's `self()`: the batch resolves `Process.get(:evogit_agent_pid) || self()` — the SESSION pid when a session drives the exchange — and `BackgroundJobs`/`ProcessManager` bind to that owner. `hd($callers)`/`Enum.at($callers, 1)` is the exchange worker, never the owner.
- `EvoGit.Agent.Tools.serial_tool?/1` is the single classification source of truth; the agent-side pd key/owner table is owned by `../agent/CONTEXT.md`.
