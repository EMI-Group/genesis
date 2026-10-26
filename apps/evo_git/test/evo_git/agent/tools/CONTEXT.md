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
| `skill_tools_worktree_test.exs` | the 8 skill tools (`SkillAdd`/`SkillEdit`/`SkillRemove`/`SkillList`/`SkillRead`/`SkillWhere`/`SkillEnable`/`SkillDisable`) — worktree (`repo_path`) read/write routing + self-committing writes via `Shared.maybe_commit_result/6` |
| `shell_tool_test.exs` | `EvoGit.Agent.Tools.ShellTool` |
| `job_tools_test.exs` | the background-job tools (`JobOutput`/`JobList`/`JobKill`) + `ShellTool`'s `run_in_background` mode + the classification/guards that mode depends on (`Tools.write_call?/2`, `Tools.background_start?/1`, `Tools.serial_tool?/1`) |
| `complete_task_test.exs` | `EvoGit.Agent.Tools.CompleteTask` (incl. the streaming archive-row write into `task_agent_archives` at agent completion) |
| `web_search_test.exs` | `EvoGit.Agent.Tools.WebSearch` + `WebSearchProviders` |
| `lsp_test.exs` | `EvoGit.Agent.Tools.Lsp` (config-gated `lsp` tool, driven with per-call `opts` overrides against the fake language server) |
| `web_fetch_lsp_registration_test.exs` | the schema-registration / dispatch contract for `web_fetch` and `lsp` |
| `reflect_tools_test.exs` | the self-reflective task-control command handlers |
| `spawn_investigator_probe_test.exs` | `Tools.SpawnInvestigatorProbe.investigate/2` |

## Async-Safety Rationale

Every module carries an `@moduledoc` naming why it is `async: true` / `async: false` — keep it accurate when the forcing state changes.

- `async: false` — `web_search_test.exs` (mutates the `:web_search_http_runner` app-env seam and the shared `:req_llm` API-key store).
- `async: false` — `reflect_tools_test.exs` (`without_model_profiles/1` rewrites the GLOBAL `EvoGit.AgentScheduler` `model_profiles` config via `AgentScheduler.update_config/1`, a BEAM-global read by every other agent/task module).
- `async: false` — `complete_task_test.exs` (the complete/archive tests insert and delete rows in the shared app-owned `:evogit_sched_meta` / `:evogit_agent_state` ETS tables; each test also gets its own isolated `EvoGit.Store` + `EvoGit.TaskRegistry` pair via `EvoGit.TaskRegistryCase`, so the archive assertions read a real producer's `task_agent_archives` rows out of a real dynamic store).
- `async: false` — `job_tools_test.exs` (every test starts its OWN isolated `EvoGit.BackgroundJobs` registry under a unique name, reached through the `:evogit_background_jobs_server` pdict seam with `:evogit_agent_pid` as the job owner, and spawns REAL detached OS children whose `genesis_job_*.log` output files land in the SHARED `EvoGit.Sandbox.resolve_tmpdir/0` scratch dir — an isolated GenServer, real host children and a shared scratch dir all rule out concurrent modules, and its before/after file snapshot cleanup is only sound in the serial phase).
- `async: false` — `web_fetch_lsp_registration_test.exs` (redirects the process-wide `XDG_CONFIG_HOME` at fresh temp config dirs so the `[lsp]` schema gate is pinned both off and on, independent of the developer's real `~/.config/genesis/config.toml`).
- `async: false` — `lsp_test.exs` (real OS child processes — the `elixir` fake language server — and the unconfigured cases read the resolved user config).
- `async: true` — every other file: pure helpers, per-test `:tmp_dir` fixtures, or process-local `Process.put` state only.

## Notes for Agents

- `reflect_tools_test.exs` spawns a live `Process.sleep(:infinity)` "wrapper" process on purpose — it is NOT a wait to reduce.
- `web_fetch_lsp_registration_test.exs` pins the tool-offering contract: `web_fetch` is always in `Tools.schemas/0` and `Tools.read_only_schemas/0`, while `lsp` is appended to both only when `EvoGit.Config.lsp_enabled?/0` is true (`[lsp] enabled = true` plus a non-empty `command`), so a stock config offers `lsp` to no agent.
  Its dispatch assertions are deliberately ungated: `Tools.execute/5` still routes `lsp` into `EvoGit.Agent.Tools.Lsp` on an unconfigured server (the tool answers with its own `Error:`), which is how the routing coverage survives the schema gate.
- `complete_task_test.exs` must stay `async: false` because its complete/archive tests mutate the shared app-owned `:evogit_sched_meta` / `:evogit_agent_state` ETS tables, while each test runs on its own isolated `EvoGit.TaskRegistryCase` store+registry pair so the archive assertions exercise the real producer's writes end to end.
- `skill_tools_worktree_test.exs` builds a real repo + LINKED WORKTREE per test (`git worktree add`) and drives the skill tools' `execute/N` directly; the worktree must live OUTSIDE `repo_root` (both under `System.tmp_dir!()`) because the sandbox grants write access to the command `cwd` (= `repo_path`) plus `<repo_root>/.git` (where a linked worktree's gitdir lives). Skill-file commits therefore only work when the tool is handed the WORKTREE as `repo_path` and the MAIN repo as `repo_root`.
- `skill_tools_worktree_test.exs` exercises BOTH `SkillWhere.execute/3` branches: the non-empty one (renders `Skill '<name>' is enabled at the following nodes:` + one `  - <node>` line per node) and the empty one (`Skill '<name>' is not enabled at any node.`).
- `skill_tools_worktree_test.exs` also pins `SkillRemove` staging a CASE-DIFFERING filename (the `name` argument differs only in case from the on-disk file, e.g. remove `"deploy"` for `Deploy.md`) — resolution goes through `EvoGit.Skills.CRUD.find_skill_file/2` (exact-then-case-insensitive), so the commit carries the real filename's deletion.
- `EvoGit.Skills.where_enabled/2` renders a ROOT-level enablement as `"./."` (`Path.relative_to(base, base) == "."`), pinned by `test/evo_git/skills_hierarchical_test.exs`.
- `job_tools_test.exs` is a CHARACTERISATION suite, not a design: it pins the shipped `job_output`/`job_list`/`job_kill` schemas and result strings (including the `[status: …]` line and the `Error: …` failure shape, plus every `max_bytes`/`timeout_ms`/`wait: true` arm), the shell tool's `run_in_background` contract (`started background job bash-<16 hex>`, the first-line label, "no timeout applies", the main-copy mutation hard block), and the guard surface the mode depends on — `Tools.schemas/0` / `Tools.read_only_schemas/0` membership, `write_call?/2`, `background_start?/1`, `serial_tool?/1`, and the repo-less guard blocking a background start while leaving the `job_*` tools callable.
- A `wait: true` `job_output` call legitimately blocks INSIDE the tool up to `EvoGit.BackgroundJobs.wait_max_ms/0` (60 s, default `wait_default_ms/0` 8 s), which is why the dispatcher's `Tools.default_timeout_ms("job_output")` is 65 s (60 s + read headroom) and the suite's `@job_output_default_timeout_ms` mirrors that as a CEILING for the real block, NOT a latency race; every other wait in the module is an event-driven bounded poll.
- The job tools' extra accepted spellings (`bash_output`/`background_output`/`job_status`, `jobs`/`background_jobs`, `kill_job`/`job_stop`/`stop_job`) are pinned by the `describe "background job aliases"` block in `../tool_names_test.exs` (pure `EvoGit.Agent.ToolNames.normalize/1`, so that module stays `async: true`).
