# Test — Agent Tools

## Intent

ExUnit suites for the per-tool implementations dispatched through `EvoGit.Agent.Tools.execute/5` (one file per tool / subsystem).
Tests use real git repos and ExUnit `:tmp_dir` fixtures — no mocking libraries.

## Routing Table

- Parent: `../` → the agent test tree (Runner, context building, tool dispatch).

## Contents

| File | Module under test |
|------|-------------------|
| `shared_test.exs` | `EvoGit.Agent.Tools.Shared` (pure arg/path helpers) |
| `file_read_test.exs` | `Tools` `"read_file"` |
| `glob_test.exs` | `Tools` `"glob"` |
| `ripgrep_test.exs` | `Tools` `"rg"` |
| `search_context_test.exs` | `Tools` `"search_context"` |
| `search_history_test.exs` | `Tools` `"search_history"` |
| `make_dir_test.exs` | `EvoGit.Agent.Tools.MakeDir` |
| `shell_tool_test.exs` | `EvoGit.Agent.Tools.ShellTool` |
| `complete_task_test.exs` | `EvoGit.Agent.Tools.CompleteTask` (+ archive records) |
| `web_search_test.exs` | `EvoGit.Agent.Tools.WebSearch` + `WebSearchProviders` |
| `reflect_tools_test.exs` | the self-reflective task-control command handlers |
| `spawn_investigator_probe_test.exs` | `Tools.SpawnInvestigatorProbe.investigate/2` |

## Async-Safety Rationale

Every module carries an `@moduledoc` naming why it is `async: true` / `async: false` — keep it accurate when the forcing state changes.

- `async: false` — `web_search_test.exs` (mutates the `:web_search_http_runner` app-env seam and the shared `:req_llm` API-key store).
- `async: false` — `reflect_tools_test.exs` (`use EvoGit.TaskRegistryCase` terminates/restarts the app-level `EvoGit.Store` + `EvoGit.TaskRegistry`).
- `async: false` — `complete_task_test.exs` (inserts/deletes rows in the shared `:evogit_sched_meta` / `:evogit_agent_state` tables and DELETES + recreates the global `:evogit_archive_records` table).
- `async: true` — every other file: pure helpers, per-test `:tmp_dir` fixtures, or process-local `Process.put` state only.

## Notes for Agents

- `reflect_tools_test.exs` spawns a live `Process.sleep(:infinity)` "wrapper" process on purpose — it is NOT a wait to reduce.
- `complete_task_test.exs` owns the global `:evogit_archive_records` table for its run (it deletes + recreates it), which is why it must stay `async: false`.
