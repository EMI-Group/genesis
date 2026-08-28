# AgentScheduler Test Directory

## Intent

ExUnit tests for the `EvoGit.AgentScheduler` subsystem — scheduling (no worktree init in `run_agent`), slot pools (LLM/tool), lifecycle (crash retry, force-kill, graceful cancel), subagent spatial-contract validation (incl. cross-repo read-write foreign-repo gate), foreign-repo-commit roll-up (`store_sub_result/3`), per-repo WorktreeManager init scoping (foreign vs primary), ETS store, PubSub throttling, and RPC surface.

## Routing Table

- `agent_scheduler_test.exs` → scheduling contract + `get_foreign_repo_commits/1`
- `lifecycle_test.exs` → crash/lifecycle handling, sub-result roll-up, archive records
- `subagents_test.exs` → spatial contract (cross-repo gate, same-repo hierarchy), `store_sub_result/3`
- `worktrees_test.exs` → WorktreeManager create/reclaim, crash-restart, per-repo init scoping
- `slots_test.exs` → LLM/tool slot pools, hard-pause 0-capacity
- `store_test.exs` / `state_test.exs` / `remote_api_test.exs` / `dispatch_test.exs` / `dispatch_custom_agents_test.exs` / `pubsub_test.exs` / `worktree_retry_test.exs` → ETS store, state/pool config, RPC surface, dispatch, PubSub throttle, retry helpers

## Known Issues

- **`AgentScheduler.get_foreign_repo_commits/1` is NOT hardened at HEAD** — `agent_scheduler_test.exs` "returns %{} for an agent with no SchedMeta row" FAILS with `MatchError: {:ok, meta} = :error` at lib `agent_scheduler.ex:254`. The original hardened form (`case :ets.lookup ... _ -> %{} end`, commit f7703da34) was regressed by 7ed94d3a5 ("replace raw ETS calls with Store in public functions"). The test deliberately pins the intended contract; the 2-line lib fix (restore the case/guard form) is outside this node's write scope — delegate to the lib node. When fixed, this test goes green and this entry must be DELETED.

## Constraints

- `agent_scheduler_test.exs`, `lifecycle_test.exs`, `worktrees_test.exs`, `slots_test.exs`, `store_test.exs`, `state_test.exs`, `remote_api_test.exs`, `pubsub_test.exs` are `async: false` (global ETS / live scheduler); `subagents_test.exs`, `dispatch_test.exs`, `worktree_retry_test.exs` are `async: true`.
- SchedMeta seeding idiom for sched-meta tests: `:ets.insert(:evogit_sched_meta, {id, %SchedMeta{...}})`; plain maps work where lib only dot-accesses one key (`Store.get_sched_meta` matches `%{}`).
- `WorktreeManager.maybe_init_repo/3` is PRIVATE — per-repo init scoping tests exercise it through the public `create_worktree_for_agent/6` with a spec `repo_id` ("primary" vs foreign id), each test needing a fresh temp repo (persistent per-repo `:evogit_worktree_repos` marker skips the wipe on subsequent inits).
- `EvoGit.Core.ForeignRepo` struct requires `root:` (no default) when building test structs.
