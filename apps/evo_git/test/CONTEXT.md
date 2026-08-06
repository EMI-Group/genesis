# Test Directory

## Intent
ExUnit test suite for the EvoGit OTP application. Validates core domain logic, git adapter operations, agent tooling, and context node handling using real git operations on temporary filesystem sandboxes — no mocks.

## Routing Table
- `evo_git/` → Test files mirroring source structure (core, adapters, agent tools, project config tests)

## API Surface

### Top-level files
- **`test_helper.exs`** — Minimal bootstrap: calls `ExUnit.start()`.
- **`evo_git_test.exs`** — `EvoGitTest`: validates `EvoGit.sandbox_args/3` output for sandboxed command execution.

### `evo_git/core/`
- **`context_node_test.exs`** — `EvoGit.Core.ContextNodeTest`: tests `ContextNode` — `hierarchy_nodes/2`, `is_ignored/1`, `load/2`, `build_context/1`. Validates hierarchy traversal, `.gitignore` handling, and error cases (absolute paths).
- **`phylo_graph_node_test.exs`** — `EvoGit.Core.PhyloGraphNodeTest`: tests `PhyloGraphNode` — `new/0`, `crossover/2`, `add_and_commit/3`. Exercises phylogenetic graph node creation and merge logic via real git repos.

### `evo_git/adapters/`
- **`git_test.exs`** — `EvoGit.Adapters.GitTest`: tests the Git adapter — `init/1`, `add_worktree/2`, `add/2`, `commit/2`, `merge/2`, `merge_octopus/2`, `status/1`. Full integration tests creating real git repos in temp dirs.

### `evo_git/agent/`
- **`tools_test.exs`** — `EvoGit.Agent.ToolsTest`: validates `Tools` schema definitions.
- **`coder_test.exs`** — `EvoGit.Agent.CoderTest`: tests the `Agent` behaviour via a `DummyAgent` module, focusing on `build_dynamic_context/1` with various CONTEXT.md setups.
- **`coder_2_test.exs`** — `EvoGit.Agent.CoderTest2`: additional edge-case tests for `build_dynamic_context/1` (root node path, nil inputs, `ArgumentError` recovery).

### `evo_git/`
- **`project_config_test.exs`** — `EvoGit.ProjectConfigTest`: tests `ProjectConfig` — `read/1`, `worktree_script/1`, `worktree_script/2` (OS variants), `commands/1`, `write_worktree_script/2` (create new genesis.toml, merge into existing, round-trip, replace OS variants, `'''` edge case). Validates reading/parsing `genesis.toml`, handling missing files, empty content, invalid TOML, OS-specific script resolution, and command shortcuts.
- **`remote_bootstrap_test.exs`** — `EvoGit.RemoteBootstrapTest` (`async: true`, no network): unit tests for the pure platform/asset logic of `EvoGit.RemoteBootstrap` — `parse_uname/2`, `parse_platform/1`, `daemon_os/1`, `asset_name/1`, `asset_matches?/2`, `direct_url/1`, `cache_path/2`. **Does NOT test `download_url/1`** (live GitHub API — flaky/slow).
- **`remote_connections_test.exs`** — `EvoGit.RemoteConnectionsTest` (`async: false`): TOML store tests including the `describe "platform field"` block (platform preserved / nil default / TOML round-trip / invalid stored as-is — no format validation at this layer).
- **`remote_connection_test.exs`** — `EvoGit.RemoteConnectionTest` (`async: false`): lifecycle + bootstrap tests. The `describe "bootstrap/1"` block covers the auto-download behavior (no local_binary_path → probe; set-but-missing → probe fallback; platform override → download; invalid platform / windows → fast deterministic errors; existing local tarball → scp). Bootstrap tests use **real ssh against fake targets** (`testN@example.com` — connection refused, exit 255, fail fast) and the `platform: "linux_x64"` test calls the **live GitHub API** (`download_url/1`) — assertion kept broad (`{:error, {:download_failed, _}}`).

### `evo_git/agent_scheduler/`
- **`dispatch_test.exs`** — `EvoGit.AgentScheduler.DispatchTest`: tests `Dispatch.resolve_agent_repo_root/2` — worktree path stripping and foreign repo root resolution.
- **`subagents_test.exs`** — `EvoGit.AgentScheduler.SubagentsTest`: tests `Subagents` — spatial contract validation (cross-repo read-only, same-repo hierarchy) and `store_sub_result/3` foreign repo commit tracking. Uses global named ETS tables directly.
- **`lifecycle_test.exs`** — `EvoGit.AgentScheduler.LifecycleTest`: tests `Lifecycle.handle_agent_crash/3` — retry path (updates meta, resets agent_state, queues when paused), permanent failure (deletes ETS entries, replies to caller), missing sched_meta/agent_state defensive handling. Also tests `cancel_agent/2` — verifies the stored `%Task{}` struct is killed via `Task.shutdown/2`. Uses `async: false` with global named ETS tables.
- **`slots_test.exs`** — `EvoGit.AgentScheduler.SlotsTest`: tests holder-set slot management — LLM/tool slot request grants when available, blocks when full, release frees + grants pending waiters, and `release_agent_slots/2` releases held slots and purges queues on agent death.

## Known Issues

### ⚠️ RemoteConnection disconnect churn → intermittent `unknown registry` flake (lib bug, test-side mitigation in place)
`EvoGit.RemoteConnection` managers are started via `DynamicSupervisor.start_child(@supervisor, {__MODULE__, target})` (`lib/evo_git/remote_connection.ex:1257`) — the default `use GenServer` child spec is `restart: :permanent`. `disconnect/1` stops the manager with `:normal` (`handle_call(:disconnect)` → `{:stop, :normal, ...}`, `remote_connection.ex:283-284`). Per OTP, `:permanent` children restart on **any** exit including `:normal`, and each restart counts toward the DynamicSupervisor's restart intensity (default 3 in 5s). Several bootstrap tests each start + disconnect a manager → churn exhausts intensity → DynamicSupervisor dies `:shutdown` → cascade can take down the Registry → teardown's `list_connections()` raises `ArgumentError: unknown registry: EvoGit.RemoteConnection.Registry` (~40% flake, only when several disconnect cycles run within 5s).

**Test-side mitigation (already applied):** `remote_connection_test.exs`'s `cleanup_connections/0` and the setup `on_exit` use `DynamicSupervisor.terminate_child(sup, pid)` (guarded on `Process.whereis`) instead of `disconnect/1` — terminate_child removes the child without restarting, so no intensity churn. **Proper lib-side fix (NOT yet applied, out of test scope):** give the manager child spec `restart: :transient` in `remote_connection.ex` (so intentional `:normal` stops don't restart), or implement disconnect as a true `DynamicSupervisor.terminate_child`/`delete_child`. If future tests re-introduce disconnect-churn, expect the flake to return.

### Bootstrap test notes
- The `"platform override skips the probe and fails at download"` test queries the live GitHub API (via `RemoteBootstrap.download_url/1`) — with network it resolves then the remote curl fails at the ssh level; without network Req fails fast and the local curl fallback also fails. Assertion is deliberately broad. This test also emits a `curl: (22) ... 404` line (the release asset doesn't exist yet) — harmless.
- The `connect/1` test emits a `Failed to enable distribution` warning (`:net_kernel` can't start in test env) — pre-existing and harmless; the test only asserts the error is NOT `:local_node_not_distributed`.

## Constraints
- Tests use `@moduletag :tmp_dir` which provides a temporary directory via ExUnit's built-in fixture mechanism.
- No mocking libraries — all git tests use real `git` operations on temporary filesystem repos.
- Test module names mirror the source module path under test (e.g., `EvoGit.Core.ContextNodeTest` tests `EvoGit.Core.ContextNode`).
- Each test file is self-contained; `DummyAgent` modules are defined inline where needed to test the `Agent` behaviour.
