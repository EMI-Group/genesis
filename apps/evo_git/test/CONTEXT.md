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
Inventory at `2ec39de4a`: 131 test modules — 65 `async: true`, 66 serialized (64 `async: false` + 2 untagged-by-default `agent/tools_test.exs` / `evo_git_test.exs`); 14 of the serialized modules use `EvoGit.TaskRegistryCase`.
## Shared Infrastructure
`test_helper.exs` runs after app boot and before any test: it redirects `XDG_DATA_HOME` to a temp dir as a fallback guard against the production DB, sets the one global `:nix_enabled = false` default (nix is only consulted lazily, so setting it here is race-free for every async module; a few `async: false` sandbox modules still set it locally), then calls `ExUnit.start(capture_log: true)`.
The canonical DB guard is `config/test.exs` pinning `:evo_git, :data_dir` to a UNIQUE per-run path (`…/evogit_test_data/genesis-<os-pid>-<unique-integer>`): concurrent `mix test` runs and sibling worker worktrees never share a `tasks.sqlite`, and no rows accumulate across runs.
Each run's `after_suite` hook removes only its own dir (never the shared parent), so any whole-table or global-state failure is a REAL flake rather than test pollution.
`support/fake_gh.ex` — `EvoGit.FakeGh`: puts a fake `gh` on `PATH` (canned JSON, `GH_FAKE_MODE`, argv log); only usable from `async: false` modules, POSIX-gated.
`support/submodule_helper.ex` — the module is `EvoGit.TestSupport.Submodule` (name differs from the filename — grepping `SubmoduleHelper` finds nothing); builds gitlink/submodule entries without cloning.
`support/task_registry_case.ex` — `EvoGit.TaskRegistryCase`: isolated `TaskRegistry` + `Store` on a fresh per-test SQLite DB, used by 14 test modules (all `async: false`).

## Known Issues
**Boot-time distribution warning is unsilenceable test-side**: `EvoGit.Application.start/2` calls `EvoGit.Distribution.maybe_enable/0`, which reads the developer's REAL `~/.config/genesis/config.toml` and logs `Failed to enable distribution: ...` BEFORE `ExUnit.start/1` runs, so `capture_log: true` cannot catch it and no test-side change can silence it (it is not emitted by any test).
**`EvoGit.SystemSampler` interval can only be changed via restart**: the sampler starts before `test_helper.exs`, so setting `:system_sample_interval_ms` there is too late; a test needing a fast tick sets the env and then calls `Supervisor.terminate_child/2` + `Supervisor.restart_child/2` so `init/1` re-reads it (`terminate_child/2` alone does NOT auto-restart a permanent child — it stays `:undefined`).
**No fake-LLM harness**: there is no Mox/Meck and no injectable LLM runner, so running a macro-driven agent to completion is not testable; the only no-real-LLM idioms are error paths (empty the scheduler `model_profiles` so `run_agent` replies `{:error, :llm_not_configured}`, or point a model at an unreachable `base_url`) plus hand-built `%ReqLLM.ToolCall{}` fed to pure functions.
**Parallel-load timing is the historical failure mode**: never assert tight wall-clock bounds; make waits event-driven rather than `Process.sleep`-based.

## Constraints
`@moduletag :tmp_dir` supplies the ExUnit temp-dir fixture.
No mocking libraries — git tests use real `git` on temporary repos.
Test module names mirror the source module path under test.
Each test file is self-contained; inline helper modules (`DummyAgent`, `HintAgent`, …) are defined where needed.
