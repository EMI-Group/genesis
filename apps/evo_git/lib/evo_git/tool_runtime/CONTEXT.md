# EvoGit.ToolRuntime — managed tool-call runtime

## Intent
Owns the EXECUTION of a batch of standard (non-subagent) agent tool calls: serial/parallel partition, per-call timeouts, tool slots, the spawned tool task, `EvoGit.ProcessManager` tracking and the sanitize pipeline.
The agent no longer owns concurrency logic: `EvoGit.Agent.ToolDispatch.batch_execute_tools/5` resolves ONE `%EvoGit.ToolRuntime.Request{}` (owner identity, repo paths, node path, taskdir, role) and delegates.

## API Surface
- `EvoGit.ToolRuntime.execute_batch(indexed_calls, %Request{}) :: [{index, tool_call_id, name, output}]` — the facade; results are SORTED BY INDEX, sanitized but NOT hint-adjusted.
- `EvoGit.ToolRuntime.Request.new(map_or_keyword)` — `%Request{agent_id, task_id, agent_pid, repo_path, repo_root, node_path, taskdir, max_timeout, delegation_level, agent_module, role}`; `role` is `%{repo_less: boolean(), foreign_repos: list(), repo_id: String.t() | nil}`.
- `Request.new/1` defaults: `max_timeout` = `EvoGit.Agent.DelegationHints.max_tool_timeout/0`, `delegation_level` = `:high`, `role` = `%{repo_less: false, foreign_repos: [], repo_id: nil}`; other fields `nil`.
- `EvoGit.ToolRuntime.Output.sanitize(result, name, args)` — wrap → `OutputSanitizer.sanitize_and_truncate/3` → `TruncationFeedback.append_truncation_feedback/3` → re-wrap; an all-text output collapses back to a plain binary.
- `EvoGit.ToolRuntime.Tracking.backend/0` (`:systemd | :bwrap | :sandbox_exec | :none`), `track(request, name, args, backend) :: String.t() | nil`, `finish(id, :completed | :failed | :killed)`, `kill(id, reason)`.

## Constraints
- Tracking is observability: EVERY call is failure-isolated (debug log + documented fallback) and `nil` ids are tolerated, so a dead/restarting registry can never change a tool result.
- `Tracking.track/4` records `kind: :tool_call` meta: `tool`, `command` (shell calls only, map args only), `label` (`"<name>: <first line>"` truncated to ~80 chars, else the tool name), `agent_id`, `task_id`, `owner_pid` (the AGENT pid), `cwd`, `repo_root`, `backend`, `runtime: :foreground`.
- Shell detection is ALIAS-AWARE via `EvoGit.Agent.ToolNames.normalize/1 == shell_tool_name/0`.
- The tool task is spawned on `EvoGit.ToolRuntime.TaskSupervisor` when registered (fallback `Task.async/1`), deliberately LINKED — never `async_nolink` — and keeps the `try/rescue/catch` containment that turns a crashing tool into `{:tool_crashed, …}`.
- A spawned task has an EMPTY process dictionary: the tool task re-installs tmpdir, owner identity, `:repo_path`/`:genesis_repo_root`, the role-guard inputs (`:repo_less`, `:foreign_repos`, `:evogit_repo_id`) and `:evogit_execution_id`.
- Per-call tracking lives in the RUNTIME process, not the tool task: `:completed` on a normal return (including an `Error: …` string or an invalid-arguments error), `:failed` on `{:tool_crashed, _}` / `{:error, _}` / `{:exit, _}`, and `kill(:timeout)` + `finish(:killed)` on a `Task.yield` timeout.
- Delegation hints and the redundant-cd warning stay AGENT-side (`ToolDispatch.apply_tool_output_tracking/3`), applied after the batch in the parent process, in index order.
- Do NOT duplicate timeout or slot logic here and in `agent/tool_dispatch.ex`; this node is the ONLY execution engine.
