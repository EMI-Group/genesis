# EvoDash Domain Logic

## Intent

Domain layer for the EvoDash Phoenix application. After the domain persistence/registry modules (`Store`, `Store.Codec`, `TaskInfo`, `RecentProject`, `TaskRegistry` and the `task_registry/` helper submodules) were **migrated to the `:evo_git` app**, this directory retains only two modules: the OTP `Application` supervisor and the `NodeContext` SSH remote-development thin client.

The migrated modules now live in `:evo_git` as `EvoGit.Store`, `EvoGit.TaskInfo`, `EvoGit.RecentProject`, `EvoGit.TaskRegistry` (and friends). EvoDash no longer owns any persistence or registry code.

## Routing Table

None — leaf directory (two modules: `application.ex`, `node_context.ex`).

## API Surface

### `EvoDash.Application` (`application.ex`)

- OTP Application callback module.
- **Supervision tree children** (strategy: `one_for_one`, `max_restarts: 10`):
  1. `EvoDashWeb.Telemetry`
  2. `Phoenix.PubSub` (registered as `EvoDash.PubSub`)
  3. `Task.Supervisor` (registered as `EvoDash.TaskSupervisor` — used by `SettingsLive` to spawn the async LLM "Test Connection" task)
  4. `EvoDashWeb.Endpoint`
- Note: `EvoGit.Store`, the task-registry `Registry`, and `EvoGit.TaskRegistry` are NO LONGER children here — they live in `EvoGit.Application`'s supervision tree now.
- Configures Floki to use the html5ever Rust NIF parser for robust HTML parsing of Lumis syntax-highlighter output.

### `EvoDash.NodeContext` (`node_context.ex`)

- Thin client for the dashboard's SSH remote-development feature. Wraps three `:evo_git` layers, presenting a single coherent API to the dashboard LiveViews:
  1. **`EvoGit.RemoteConnections`** — connection-target *persistence* (TOML file store of pure functions). Delegated to directly for `list_targets/0`, `get_target/1`, `save_target/1`, `delete_target/1`.
  2. **`EvoGit.RemoteConnection`** — connection *lifecycle* (GenServer managing the live SSH tunnel + Erlang distribution). May not be compiled/started yet (ships as parallel Phase 2 work). All lifecycle calls (`connect/1`, `disconnect/1`, `bootstrap/1`, `connection_status/0,1`, `connected?/1`) degrade gracefully via the private `with_remote_connection/4` guard (`Code.ensure_loaded?/1` + `catch :exit`), returning safe fallbacks (`{:error, :remote_connection_unavailable}`, `%{}`, `:disconnected`, `false`).
  3. **`EvoGit.RemoteNode`** — cross-node RPC helpers. `call_remote/4`, `list_agents/1`, `get_agent_history/2`, `get_agent_state/2`, `get_remote_config/1` (→ `EvoGit.RemoteNode.get_config/1`), `get_remote_config_status/1` (→ `EvoGit.RemoteNode.get_config_status/1`), `paused?/1` are now one-line delegations to `EvoGit.RemoteNode`. Public signatures are unchanged so the six web files that use `NodeContext` need no changes.

## Constraints

- `EvoDash.Application` starts NO persistence/registry children — those belong to `EvoGit.Application`.
- `EvoDash.TaskSupervisor` IS still started and IS used (by `SettingsLive`'s async LLM test). Do NOT remove it.
- `NodeContext` keeps its public API stable; web-layer callers should never touch `EvoGit.RemoteNode`/`EvoGit.RemoteConnection`/`EvoGit.RemoteConnections` directly.
- Depends on `evo_git` application at compile and runtime.
