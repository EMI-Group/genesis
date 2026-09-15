# AgentScheduler Test Directory

## Intent

ExUnit tests for the `EvoGit.AgentScheduler` subsystem — scheduling (no worktree init in `run_agent`), slot pools (LLM/tool), lifecycle (crash retry, force-kill, graceful cancel), subagent spatial-contract validation (incl. cross-repo read-write foreign-repo gate), foreign-repo-commit roll-up (`store_sub_result/3`), per-repo WorktreeManager init scoping (foreign vs primary), ETS store, PubSub throttling, and RPC surface.

## Routing Table

- `agent_scheduler_test.exs` → scheduling contract + `get_foreign_repo_commits/1`
- `lifecycle_test.exs` → crash/lifecycle handling, sub-result roll-up, archive records
- `subagents_test.exs` → spatial contract (cross-repo gate, same-repo hierarchy), writable-foreign-repo delegation gates (root-only via `:foreign_repo_write_not_root`, one-at-a-time via `:foreign_repo_write_serialized` in `spawn_validated_subagents/5`, same-repo-within-foreign unrestricted), `store_sub_result/3`
- `worktrees_test.exs` → WorktreeManager create/reclaim, crash-restart, per-repo init scoping
- `worktree_admission_test.exs` → bounded worktree-creation ADMISSION QUEUE (head-of-line FIFO, cap never exceeded, queue drains / every caller replied once, queued-agent death dropped without starting a create, under-cap immediate admission) via the `:max_concurrent_worktree_creation` + `:worktree_create_fun` app-env seams
- `slots_test.exs` → LLM/tool slot pools, hard-pause 0-capacity
- `store_test.exs` / `state_test.exs` / `remote_api_test.exs` / `dispatch_test.exs` / `dispatch_custom_agents_test.exs` / `pubsub_test.exs` / `worktree_retry_test.exs` → ETS store, state/pool config, RPC surface, dispatch, PubSub throttle, retry helpers

## Constraints

- `agent_scheduler_test.exs`, `lifecycle_test.exs`, `worktrees_test.exs`, `worktree_admission_test.exs`, `slots_test.exs`, `store_test.exs`, `remote_api_test.exs`, `pubsub_test.exs` are `async: false` (global ETS / live scheduler / global app-env seams); `subagents_test.exs`, `dispatch_test.exs`, `worktree_retry_test.exs`, `state_test.exs` are `async: true`.
- `state_test.exs` is `async: true` because it only drives the PURE `State`/`Slots` functions on an in-process `%State{}` (no live scheduler GenServer). Its exercised code paths merely READ the app-created `:evogit_agent_state` (model id) and `:evogit_sched_meta` (depth / sched-meta status) tables for the low agent id it uses (3) and never write them — do NOT add ETS seeding or `:ets.delete_all_objects` back (that is exactly the cross-module race that would force it back to `async: false`).
- The admission-queue seams `:max_concurrent_worktree_creation` and `:worktree_create_fun` are GLOBAL app env (read by the manager at admission/create time) — `worktree_admission_test.exs` must stay `async: false` and save/restore both in `on_exit`.
- SchedMeta seeding idiom for sched-meta tests: `:ets.insert(:evogit_sched_meta, {id, %SchedMeta{...}})`; plain maps work where lib only dot-accesses one key (`Store.get_sched_meta` matches `%{}`).
- `WorktreeManager.maybe_init_repo/3` is PRIVATE — per-repo init scoping tests exercise it through the public `create_worktree_for_agent/6` with a spec `repo_id` ("primary" vs foreign id), each test needing a fresh temp repo (persistent per-repo `:evogit_worktree_repos` marker skips the wipe on subsequent inits).
- `EvoGit.Core.ForeignRepo` struct requires `root:` (no default) when building test structs.
- `worktrees_test.exs` — NEVER pass `self()` as the monitored agent pid to `WorktreeManager.create_worktree_for_agent/6`: the resulting `:live` registration can only be drained by the test process exiting, so its `:DOWN` cleanup (inline `git worktree prune` / `git branch -D`, spawned with `cd: repo_root`) fires during `on_exit` teardown and races the setup's `File.rm_rf!(tmp_dir)` — when rm_rf wins, the ERTS port program prints `spawn: Could not cd to /tmp/evogit_worktrees_<int>` to stderr (not a Logger message; `capture_log` cannot hide it). Route every create call through the file's `spawn_agent/6` stand-in process (the production shape — the manager monitors the caller) and drain it with `finish_agent/3` (monitor + `:exit_please` + `assert_receive {:DOWN, ...}` + poll until dir AND branch are gone) BEFORE the test ends. A test may skip the drain only when its registration provably cannot outlive it in the shared named manager: the process under test exits mid-test with its cleanup awaited in-test, or the manager instance owning the registration is terminated in-test (e.g. `restart_manager/0`) with no sched_meta row to re-monitor it.
