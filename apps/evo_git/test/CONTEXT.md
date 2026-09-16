# `:evo_git` Test Suite

## Intent
The ExUnit suite for the `:evo_git` core runtime — real git operations against per-test temp directories, no mocks.
Per-file detail lives in the child CONTEXT.md files below; this file carries only intent, routing, the cross-cutting async-safety policy, shared infrastructure, current known issues, and constraints.
Full per-file history lives in git (`git log -p -- apps/evo_git/test/CONTEXT.md`).

## Routing Table
- `./evo_git/` → the whole `lib/evo_git/`-mirroring subtree (top-level suites + async-safety map) → `./evo_git/CONTEXT.md`
- `./evo_git/agent/` → agent loop, context builder/compression, tool dispatch, subagent processing → `./evo_git/agent/CONTEXT.md`
- `./evo_git/agent/tools/` → per-tool tests → `./evo_git/agent/tools/CONTEXT.md`
- `./evo_git/agent_scheduler/` → scheduler dispatch, slots, lifecycle, worktrees, store, subagents, RemoteAPI → `./evo_git/agent_scheduler/CONTEXT.md`
- `./evo_git/adapters/` → Git / GitHub / CoW-worktree / GitEnv adapters → `./evo_git/adapters/CONTEXT.md`
- `./evo_git/core/` → `ContextNode`, `PhyloGraphNode`, `ForeignRepo` → `./evo_git/core/CONTEXT.md`
- `./evo_git/custom_agents/` → custom-agents store + model-selection script → `./evo_git/custom_agents/CONTEXT.md`
- `./evo_git/runtime/` → Genesis / Evolution / Helpers / Prompts / SelfReflective runtimes → `./evo_git/runtime/CONTEXT.md`
- `./evo_git/sandbox/` → sandbox backends (systemd-run, bwrap, sandbox-exec, none) → `./evo_git/sandbox/CONTEXT.md`
- `./evo_git/skills/` → skills subsystem → `./evo_git/skills/CONTEXT.md`
- `./evo_git/store/` → SQLite store queries / errors → `./evo_git/store/CONTEXT.md`
- `./evo_git/task_registry/` → TaskRegistry lifecycle, runtime-opts, merge/resume context, `:reflect` executor → `./evo_git/task_registry/CONTEXT.md`
- `./support/` → shared test helpers (no own CONTEXT.md — documented under Shared Infrastructure below)
- `./mix/` → standalone `mix`-task suites (`bump.version`, `changelog`), all `async: false`; no own CONTEXT.md yet
- `./evo_git_test.exs` → top-level sandbox/platform suite (`EvoGit.sandbox_args/4`, `sandbox_run/4`, backend capability checks)

## Async-Safety Policy
`async: true` is allowed ONLY for a module whose tests mutate no BEAM-global state another concurrently-running module can observe.
A module MUST be `async: false` when any test redirects a process-wide env var read by production code (`XDG_CONFIG_HOME`, `PATH`, the app-level `:data_dir`), or mutates an app-env key read by other modules, or mutates `:persistent_term` read by others.
A module MUST also be `async: false` when any test touches the global `EvoGit.AgentScheduler`, the global `:evogit_*` ETS tables, the app-level `EvoGit.Store` / `EvoGit.TaskRegistry` singletons, the `EvoGit.RemoteConnection` Registry/DynamicSupervisor, or a shared PubSub topic it asserts on without node/id filtering.
Any module that `use`s `EvoGit.TaskRegistryCase` MUST be `async: false` — that case terminates and restarts the app-level `EvoGit.Store` + `EvoGit.TaskRegistry` singletons (its moduledoc states this).
Every forced-`async: false` module carries an in-file comment/`@moduledoc` naming the exact BEAM-global that forces serialization — keep it accurate when the forcing state changes.
The async setting is **per MODULE, not per file** — two files carry two test modules each: `command_shell_test.exs` = `EvoGit.CommandShellTest` (`EvoGit.TaskRegistryCase`, sync) + `EvoGit.CommandShellParsingTest` (`async: true`), and `command_approval_test.exs` = `EvoGit.CommandApprovalTest` (`EvoGit.TaskRegistryCase`, sync) + `EvoGit.CommandApproval.RequestTest` (`async: false`). A one-`use`-line-per-file scan misclassifies both.
Inventory (census): 131 test modules — 64 `async: true`, 67 `async: false`, 0 untagged; 14 of the serialized modules use `EvoGit.TaskRegistryCase` (which counts as `async: false`, and `command_approval_test.exs` alone carries two of them).
## Sync-Tail Cost Profile (measured)
Suite wall clock = the `async: true` phase + the serial sum of the `async: false` modules (ExUnit drains the entire async cohort before it runs any sync module, then runs those one at a time), and the sync phase is the larger part (~30s of ~40s) — so only work removed from it, or made cheaper, shortens the suite.
Largest sync contributors (per-test sums from a full run; each file's own CONTEXT.md carries the detail): `agent/tool_dispatch_retry_slot_test` (~4.4s standalone, dominated by the one-off `LLMDB.load/1` — see `./evo_git/agent/CONTEXT.md`), `agent_scheduler/worktrees_test` ~3.1s, `remote_connection_test` ~2.4s, `adapters/cow_worktree_test` ~2.2s, `mix/tasks/changelog_test` ~2.1s, `self_reflective_source_test` ~2.0s, `agent/tools/complete_task_test` ~1.8s, `git_env_test` ~0.9s, `agent/tools_test` ~0.8s, `agent_scheduler/agent_scheduler_test` ~0.6s, `adapters/github_test` ~0.6s.
Every one of those is blocked by a hard global (the global `EvoGit.AgentScheduler`, a named `:evogit_*` ETS table, the app-level `Store`/`TaskRegistry` singletons, the `RemoteConnection` Registry/DynamicSupervisor, `:persistent_term`, or a process-wide `XDG_*`/`PATH`/git-identity env var) and each file's `@moduledoc` names its own — none of them can be flipped by a tag change.
**Do NOT split a module into an `async: true` module just to shrink the sync number**: an 11-run interleaved A/B of exactly such a split (69 tests moved to `async: true` + 5 left serialized) reliably moved ~1.1s out of the sync phase but added ~1.0-3.2s to the async phase (the moved git/shell tests inflate under the ~28-way async cohort), for adjacent-pair TOTAL deltas of +0.1s / +0.2s / +0.5s — the split was reverted. TOTAL wall clock, not the sync figure, is the criterion for any sync→async move.
The remaining realizable win needs a PRODUCTION seam, not a test edit: giving `Mix.Tasks.Changelog` / `Mix.Tasks.Bump.Version` a `root` parameter (removes the VM-wide `File.cd!`) plus an injected shell/`yes?` seam (removes the global `Mix.shell(Mix.Shell.Process)`) would unblock `mix/tasks/changelog_test` + `bump_version_test` (~2.7s); if both go `async: true`, their shared `:changelog_summarizer` seams must also move to opts-injection, and `migrate_store_test` is unaffected by an injected shell (it breaks only under a global `Mix.shell/1` swap).
Rejected candidates, with the blocking reason: `cow_worktree_test` keeps a second hard global (`XDG_CONFIG_HOME` is read live by `EvoGit.Config.resolve/1` on the code path that module exercises, and `EvoGit.Config` exposes no seam at all); `github_test` / `remote_node_github_test`'s test mechanism IS process-wide `PATH` (read by every concurrent module's subprocess spawns); `self_reflective_source_test` has only 0-arity production readers (wide blast radius, and an already-`async: true` sibling — `agent_scheduler/dispatch_test.exs` — mutates the same four env knobs) and ~40% of its git fixture work is avoidable test-side without any seam.

## Shared Infrastructure
`test_helper.exs` runs after app boot and before any test: it redirects `XDG_DATA_HOME` to a temp dir as a fallback guard against the production DB, sets the one global `:nix_enabled = false` default (nix is only consulted lazily, so setting it here is race-free for every async module; a few `async: false` sandbox modules still set it locally), then calls `ExUnit.start(capture_log: true)`.
The canonical DB guard is `config/test.exs` pinning `:evo_git, :data_dir` to a UNIQUE per-run path (`…/evogit_test_data/genesis-<os-pid>-<unique-integer>`): concurrent `mix test` runs and sibling worker worktrees never share a `tasks.sqlite`, and no rows accumulate across runs.
Each run's `after_suite` hook removes only its own dir (never the shared parent), so any whole-table or global-state failure is a REAL flake rather than test pollution.
`support/fake_gh.ex` — `EvoGit.FakeGh`: puts a fake `gh` on `PATH` (canned JSON, `GH_FAKE_MODE`, argv log); only usable from `async: false` modules, POSIX-gated.
`support/submodule_helper.ex` — the module is `EvoGit.TestSupport.Submodule` (name differs from the filename — grepping `SubmoduleHelper` finds nothing); builds gitlink/submodule entries without cloning.
`support/task_registry_case.ex` — `EvoGit.TaskRegistryCase`: isolated `TaskRegistry` + `Store` on a fresh per-test SQLite DB, used by 14 test modules (all `async: false`).

## Known Issues
**`EvoGit.SystemSampler` interval can only be changed via restart**: the sampler starts before `test_helper.exs`, so setting `:system_sample_interval_ms` there is too late; a test needing a fast tick sets the env and then calls `Supervisor.terminate_child/2` + `Supervisor.restart_child/2` so `init/1` re-reads it (`terminate_child/2` alone does NOT auto-restart a permanent child — it stays `:undefined`).
**No fake-LLM harness**: there is no Mox/Meck and no injectable LLM runner, so running a macro-driven agent to completion is not testable; the only no-real-LLM idioms are error paths (empty the scheduler `model_profiles` so `run_agent` replies `{:error, :llm_not_configured}`, or point a model at an unreachable `base_url`) plus hand-built `%ReqLLM.ToolCall{}` fed to pure functions.
**Parallel-load timing is the historical failure mode**: never assert tight wall-clock bounds; make waits event-driven rather than `Process.sleep`-based.

## Constraints
`@moduletag :tmp_dir` supplies the ExUnit temp-dir fixture.
No mocking libraries — git tests use real `git` on temporary repos.
Test module names mirror the source module path under test.
Each test file is self-contained; inline helper modules (`DummyAgent`, `HintAgent`, …) are defined where needed.
