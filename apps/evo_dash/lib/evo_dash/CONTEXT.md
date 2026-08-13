# EvoDash Domain Logic

## Intent

Domain layer for the EvoDash Phoenix application. Contains the OTP `Application` supervisor, the `NodeContext` SSH remote-development thin client, and the `DirectoryPicker` native dialog picker (with its `Wx` seam). The persistence/registry modules (`Store`, `Store.Codec`, `TaskInfo`, `RecentProject`, `TaskRegistry` and the `task_registry/` helper submodules) live in `:evo_git` as `EvoGit.Store`, `EvoGit.TaskInfo`, `EvoGit.RecentProject`, `EvoGit.TaskRegistry` (and friends). EvoDash owns no persistence or registry code.

## Routing Table

None — leaf directory (four modules: `application.ex`, `node_context.ex`, `directory_picker.ex`, `directory_picker/wx.ex`).

## API Surface

### `EvoDash.Application` (`application.ex`)

- OTP Application callback module.
- **Supervision tree children** (strategy: `one_for_one`, `max_restarts: 10`):
  1. `EvoDashWeb.Telemetry`
  2. `Phoenix.PubSub` (registered as `EvoDash.PubSub`)
  3. `Task.Supervisor` (registered as `EvoDash.TaskSupervisor` — used by `SettingsLive` to spawn the async LLM "Test Connection" task)
  4. `EvoDashWeb.Endpoint`
- Note: `EvoGit.Store`, the task-registry `Registry`, and `EvoGit.TaskRegistry` are children of `EvoGit.Application`'s supervision tree, not of this supervisor.
- Configures Floki to use the html5ever Rust NIF parser for robust HTML parsing of Lumis syntax-highlighter output.

### `EvoDash.NodeContext` (`node_context.ex`)

- Thin client for the dashboard's SSH remote-development feature. Wraps three `:evo_git` layers, presenting a single coherent API to the dashboard LiveViews:
  1. **`EvoGit.RemoteConnections`** — connection-target *persistence* (TOML file store of pure functions). Delegated to directly for `list_targets/0`, `get_target/1`, `save_target/1`, `delete_target/1`.
  2. **`EvoGit.RemoteConnection`** — connection *lifecycle* (GenServer managing the live SSH tunnel + Erlang distribution). May not be compiled/started, so graceful degradation is required. All lifecycle calls (`connect/1`, `disconnect/1`, `bootstrap/1`, `connection_status/0,1`, `connected?/1`) degrade gracefully via the private `with_remote_connection/4` guard (`Code.ensure_loaded?/1` + `catch :exit`), returning safe fallbacks (`{:error, :remote_connection_unavailable}`, `%{}`, `:disconnected`, `false`).
  3. **`EvoGit.RemoteNode`** — cross-node RPC helpers. `call_remote/4`, `list_agents/1`, `get_agent_history/2`, `get_agent_state/2`, `get_remote_config/1` (→ `EvoGit.RemoteNode.get_config/1`), `get_remote_config_status/1` (→ `EvoGit.RemoteNode.get_config_status/1`), `paused?/1`, `list_tasks_summary/2` (optional `statuses` filter: `[]` = all statuses, e.g. `[:running, :pending, :finalizing, :completed]`), and `list_task_ids/2` (minimal id/status/updated_at projection — no heavy JSON decode, same `statuses` filter; used for dirty-tracker baselines and change detection; `[]` fallback on RPC failure) are one-line delegations to `EvoGit.RemoteNode`, as are the task-cancellation pair `cancel_task/2` (GRACEFUL: `:pending` → immediate `:cancelled`; `:running` → `:cancelling`, agents save + exit, then `:cancelled` with result/archive preserved) and `force_kill_task/2` (BRUTAL: kills all agents + wrapper → `:failed`, result nil'd; from `:running`/`:cancelling` = escalation). Web-layer callers use `NodeContext` exclusively — its public API is the single entry point.

### `EvoDash.DirectoryPicker` (`directory_picker.ex`)

GenServer serializing native directory/file-dialog usage (the dashboard's Browse buttons). Uses a **"native first, wx fallback"** model on all platforms:

- **Kinds** (`pick/3`): `:directory` (default; `pick/2` delegates to `pick(reply_to, picker_id, :directory)`) and `:file`. `kind` selects the per-platform native dialog and the wx fallback (`wxDirDialog` vs `wxFileDialog`).
- **Native dialogs per kind**: macOS → osascript `choose folder` ("Select Directory") / `choose file` ("Select File") with a non-zero exit mapped to `:cancelled`; Linux → zenity `--file-selection --directory --title=Select Directory` / `--file-selection --title=Select File` (no `--directory`); Windows → PowerShell `FolderBrowserDialog` (Description "Select Directory") / `OpenFileDialog` (Title "Select File", `Write-Output $dialog.FileName` on OK).
- **wx fallback** (`EvoDash.DirectoryPicker.Wx`): initialized fresh in each pick Task (never cached in GenServer state); `wxDirDialog` with `title:`/`defaultPath:` for `:directory`, `wxFileDialog` with `message:`/`defaultDir:` for `:file` (option names verified from OTP source; `wxFD_DEFAULT_STYLE = wxFD_OPEN` so no explicit `style` is needed). `show_modal`/`get_path`/`destroy` and the `@wx_id_ok` (5100) / `@wx_id_cancel` (5101) result-code handling are shared; `normalize_path/1` handles charlist-vs-binary getter output.
- **Result protocol**: sync `:ok | {:error, :unavailable}` acceptance reply; async `{:directory_picker_result, picker_id, {:ok, path} | :cancelled | :unavailable}` delivered to `reply_to`. **Busy serialization** — one dialog at a time; concurrent picks get `{:error, :unavailable}`. `{:pick_done, ...}` clears the busy flag on EVERY path (a failed pick never wedges the picker). ALL external interaction is wrapped in try/catch/rescue — the module MUST NEVER RAISE (LiveView event-handler call path).
- **Disabled** via `config :evo_dash, :directory_picker, enabled: false` (sync `{:error, :unavailable}`, no result message).
- **Injection seams**: `config :evo_dash, :directory_picker_wx, Module` selects the wx backend (default `EvoDash.DirectoryPicker.Wx`; deterministic fake for tests). The `config :evo_dash, :directory_picker_module` convention mirrors this for picker-level fakes (used by `EvoDash.DirectoryPicker.Fake`).

### `EvoDash.DirectoryPicker.Wx` (`directory_picker/wx.ex`)

Injectable seam around the optional `:wx` / `:wxDirDialog` / `:wxFileDialog` runtime backend (wx ships with OTP but is only loaded in the `genesis`/`genesis_desktop` releases via `wx: :load`; `@compile {:no_warn_undefined, [:wx, :wxDirDialog, :wxFileDialog]}` suppresses the undefined-module warnings). Functions: `available?/0` (`:code.which(:wx) != :non_existing`), `new/0`, `get_env/0`, `set_env/1`, `new_dir_dialog/2` (`:wxDirDialog.new/2`), `new_file_dialog/2` (`:wxFileDialog.new/2`), `show_modal/1` (`:wxDirDialog.showModal/1` — wxFileDialog shares `showModal`), `get_path/1`, `destroy/1`. All plain delegations — failure handling lives in the picker. Tests substitute a fake via `config :evo_dash, :directory_picker_wx` (see `test/support/fake_directory_picker_wx.ex`).

## Constraints

- `EvoDash.Application` starts NO persistence/registry children — those belong to `EvoGit.Application`.
- `EvoDash.TaskSupervisor` IS started and IS used (by `SettingsLive`'s async LLM test). Do NOT remove it.
- `NodeContext` keeps its public API stable; web-layer callers should never touch `EvoGit.RemoteNode`/`EvoGit.RemoteConnection`/`EvoGit.RemoteConnections` directly.
- Depends on `evo_git` application at compile and runtime.
