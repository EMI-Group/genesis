# EvoGit.ToolRuntime — managed tool-call runtime

## Intent
Owns the EXECUTION of a batch of standard (non-subagent) agent tool calls: serial/parallel partition, per-call timeouts, tool slots, the spawned tool task, `EvoGit.ProcessManager` tracking and the sanitize pipeline.
The agent no longer owns concurrency logic: `EvoGit.Agent.ToolDispatch.batch_execute_tools/4,5` resolves ONE `%EvoGit.ToolRuntime.Request{}` (owner identity, repo paths, node path, taskdir, role) and delegates.

## API Surface
- `EvoGit.ToolRuntime.execute_batch(indexed_calls, %Request{}) :: [{index, tool_call_id, name, output}]` — the facade; results are SORTED BY INDEX, sanitized but NOT hint-adjusted.
- `EvoGit.ToolRuntime.Request.new(map_or_keyword)` — `%Request{agent_id, task_id, agent_pid, repo_path, repo_root, node_path, taskdir, max_timeout, delegation_level, agent_module, role}`; `role` is `%{repo_less: boolean(), foreign_repos: list(), repo_id: String.t() | nil}`.
- `Request.new/1` defaults: `max_timeout` = `EvoGit.Agent.DelegationHints.max_tool_timeout/0`, `delegation_level` = `:high`, `role` = `%{repo_less: false, foreign_repos: [], repo_id: nil}`; other fields `nil`.
- `EvoGit.ToolRuntime.Output.sanitize(result, name, args)` — wrap → `OutputSanitizer.sanitize_and_truncate/3` → `TruncationFeedback.append_truncation_feedback/3` → re-wrap; an all-text output collapses back to a plain binary.
- `EvoGit.ToolRuntime.Tracking.backend/0` (`:systemd | :bwrap | :sandbox_exec | :none`, resolved ONCE per batch), `tracked_backend(name, sandbox_backend)` (the per-call pick), `track(request, name, args, backend) :: String.t() | nil`, `finish(id, status, opts \\ [])` (`exit_code:`/`reason:`), `kill(id, reason)`.

## Constraints
- Tracking is observability: EVERY call is failure-isolated (debug log + documented fallback) and `nil` ids are tolerated, so a dead/restarting registry can never change a tool result.
- `Tracking.track/4` records `kind: :tool_call` meta: `tool`, `command` (shell calls only, map args only), `label` (`"<name>: <first line>"` truncated to ~80 chars, else the tool name), `agent_id`, `task_id`, `owner_pid` (the AGENT pid), `cwd`, `repo_root`, `backend` (the per-call pick below), `runtime: :foreground`.
- Shell detection is ALIAS-AWARE via `EvoGit.Agent.ToolNames.normalize/1 == shell_tool_name/0`.
- The tool task is spawned on `EvoGit.ToolRuntime.TaskSupervisor` when registered (fallback `Task.async/1`), deliberately LINKED — never `async_nolink` — and keeps the `try/rescue/catch` containment that turns a crashing tool into `{:tool_crashed, …}`.
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
- Per-call settlement lives in the RUNTIME process, not the tool task: `:failed` + `:invalid_arguments` on the malformed-arguments path, `:failed` + `{:crashed, …}` on `{:tool_crashed, _}`/`{:exit, _}`, `:failed` + `{:tool_error, reason}` on `{:error, reason}`, and `kill(:timeout)` followed by `:killed` + `:timeout` on a `Task.yield` timeout.
- `Tracking.kill(id, :timeout)` settles the terminal fact `:timeout`; every other kill reason settles `{:killed_by, :tool_runtime}`, with the human prose kept in the record's `control_log`.
- `finish/3` and `kill/2` are total (a `nil` or non-binary id is a no-op) and never raise into the tool path.

## Routing Table

- `./request.ex` → `%EvoGit.ToolRuntime.Request{}` (the one batch context struct) + `new/1` defaults.
- `./executor.ex` → the execution engine: `execute_batch/2`, serial/parallel partition, per-call timeout resolution, slot acquisition, the spawned tool task and its pd re-installation, per-arm terminal settlement.
- `./tracking.ex` → `EvoGit.ProcessManager` integration (`kind: :tool_call`): batch backend probe, per-call backend pick, `track/4`, `finish/3`, `kill/2`, label/command derivation.
- `./output.ex` → `Output.sanitize/3`, the sanitize/wrap boundary shared with `ToolDispatch.sanitize_tool_result/3`.
- Sandbox execution handles / `:execution_id` → `../sandbox/CONTEXT.md`; the registry itself → `../process_manager.ex`; the timeout + hint policy owned agent-side → `../agent/CONTEXT.md`; per-task tmpdir → `../sandbox/` (`EvoGit.TaskTmpdir`).
