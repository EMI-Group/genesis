# EvoDash Domain Logic

## Intent

Domain layer for the EvoDash Phoenix application. Contains the OTP `Application` supervisor, the `NodeContext` SSH remote-development thin client, the `DirectoryPicker` native dialog picker (with its `Wx` seam), the `UpdateStatus` auto-update state hub, the desktop-only `DesktopLifetime` Tauri-shell watcher, and small pure helpers (`AttachedFile`, `MarkdownRender`, `SettingsUtils`). The persistence/registry modules (`Store`, `Store.Codec`, `TaskInfo`, `RecentProject`, `TaskRegistry` and the `task_registry/` helper submodules) live in `:evo_git` as `EvoGit.Store`, `EvoGit.TaskInfo`, `EvoGit.RecentProject`, `EvoGit.TaskRegistry` (and friends). EvoDash owns no persistence or registry code.

## Routing Table

- `./application.ex` → `EvoDash.Application` — OTP supervisor
- `./node_context.ex` → `EvoDash.NodeContext` — SSH remote-development thin client
- `./directory_picker.ex` + `./directory_picker/wx.ex` → `EvoDash.DirectoryPicker` (+ `EvoDash.DirectoryPicker.Wx` seam)
- `./update_status.ex` → `EvoDash.UpdateStatus` — Tauri auto-update state hub
- `./desktop_lifetime.ex` → `EvoDash.DesktopLifetime` — desktop Tauri-shell lifetime watcher (TCP pipe)
- `./attached_file.ex` → `EvoDash.AttachedFile` — attached-objective-file reader (.txt/.md/.docx/.pdf)
- `./markdown_render.ex` → `EvoDash.MarkdownRender` — MDEx markdown → safe HTML
- `./settings_utils.ex` → `EvoDash.SettingsUtils` — config form-value helpers

## API Surface

### `EvoDash.Application` (`application.ex`)

OTP Application callback module. Supervision tree (`:one_for_one`, `max_restarts: 10`, `max_seconds: 60`):

1. `EvoDashWeb.Telemetry`
2. `Phoenix.PubSub` (registered as `EvoDash.PubSub`)
3. `Task.Supervisor` (registered as `EvoDash.TaskSupervisor` — the generic async-runner for dashboard LiveViews: all node-aware data loads and per-click RPCs run as `Task.Supervisor.start_child(EvoDash.TaskSupervisor, ...)` outside the LiveView process)
4. `EvoDash.DirectoryPicker`
5. `EvoDash.UpdateStatus`
6. `EvoDashWeb.Endpoint`
7. `{EvoDash.DesktopLifetime, []}` — appended only when BOTH `EVOGIT_DESKTOP=1` and `EVOGIT_LIFETIME_PORT` are set (only the Tauri sidecar sets both); the module's `init/1` self-disable is belt-and-suspenders.

`EvoGit.Store`, the task-registry `Registry`, and `EvoGit.TaskRegistry` are children of `EvoGit.Application`'s supervision tree, not of this supervisor.

### `EvoDash.NodeContext` (`node_context.ex`)

Thin client for the dashboard's SSH remote-development feature. Wraps three `:evo_git` layers, presenting a single coherent API to the dashboard LiveViews:

1. **`EvoGit.RemoteConnections`** — connection-target persistence (TOML file store of pure functions). Delegated to directly for `list_targets/0`, `get_target/1`, `save_target/1`, `delete_target/1`.
2. **`EvoGit.RemoteConnection`** — connection lifecycle (GenServer managing the live SSH tunnel + Erlang distribution). May not be compiled/started, so all lifecycle calls (`connect/1`, `disconnect/1`, `bootstrap/1`, `connection_status/0,1`, `connected?/1`) degrade gracefully via the private `with_remote_connection/4` guard (`Code.ensure_loaded?/1` + `catch :exit`), returning safe fallbacks (`{:error, :remote_connection_unavailable}`, `%{}`, `:disconnected`, `false`).
3. **`EvoGit.RemoteNode`** — cross-node RPC helpers; one-line delegations: `call_remote/4`, `list_agents/1`, `get_agent_history/2`, `get_agent_state/2`, `get_remote_config/1`, `get_remote_config_status/1`, `get_resolved_config/1`, `paused?/1`, `list_tasks_summary/2` (optional `statuses` filter; `[]` = all), `list_task_ids/2` (minimal id/status/updated_at projection — no heavy JSON decode, same `statuses` filter, `[]` fallback on RPC failure; dashboard consumer: `SystemLive.UpdateCard.active_task_ids/1`, the desktop update card's apply/force-kill gate), and the task-cancellation pair `cancel_task/2` (GRACEFUL: `:pending` → immediate `:cancelled`; `:running` → `:cancelling`, agents save + exit, then `:cancelled` with result/archive preserved) / `force_kill_task/2` (kills all agents + wrapper → `:failed`, result nil'd; escalation from `:cancelling`).

Web-layer callers use `NodeContext` exclusively — its public API is the single entry point and stays stable.

### `EvoDash.DirectoryPicker` (`directory_picker.ex`)

GenServer serializing native directory/file-dialog usage (the dashboard's Browse buttons and the objective editor's attach-file button). "Native first, wx fallback" on all platforms:

- **Kinds** (`pick/3`): `:directory` (default; `pick/2` delegates) and `:file`; the kind selects the per-platform native dialog and the wx fallback (`wxDirDialog` vs `wxFileDialog`).
- **Native dialogs per kind**: macOS → osascript `choose folder` / `choose file` (non-zero exit → `:cancelled`); Linux → zenity `--file-selection` with/without `--directory`; Windows → PowerShell `FolderBrowserDialog` / `OpenFileDialog`.
- **wx fallback** (`EvoDash.DirectoryPicker.Wx`): initialized fresh in each pick Task (never cached in GenServer state).
- **Result protocol**: sync `:ok | {:error, :unavailable}` acceptance reply; async `{:directory_picker_result, picker_id, {:ok, path} | :cancelled | :unavailable}` delivered to `reply_to`. Busy serialization — one dialog at a time; concurrent picks get `{:error, :unavailable}`; a failed pick never wedges the picker. All external interaction is wrapped in try/catch/rescue — the module MUST NEVER RAISE (LiveView event-handler call path).
- **Disabled** via `config :evo_dash, :directory_picker, enabled: false` (sync `{:error, :unavailable}`, no result message).
- **Injection seams**: `config :evo_dash, :directory_picker_wx, Module` selects the wx backend (deterministic fake for tests); `config :evo_dash, :directory_picker_module` mirrors this for picker-level fakes (`EvoDash.DirectoryPicker.Fake`).

### `EvoDash.DirectoryPicker.Wx` (`directory_picker/wx.ex`)

Injectable seam around the optional `:wx` / `:wxDirDialog` / `:wxFileDialog` runtime backend (wx ships with OTP but is only loaded in the `genesis`/`genesis_desktop` releases via `wx: :load`; `@compile {:no_warn_undefined, ...}` suppresses undefined-module warnings). Functions: `available?/0` (`:code.which(:wx) != :non_existing`), `new/0`, `get_env/0`, `set_env/1`, `new_dir_dialog/2`, `new_file_dialog/2`, `show_modal/1`, `get_path/1`, `destroy/1`. All plain delegations — failure handling lives in the picker. Option gotchas: `wxDirDialog` takes `title`/`defaultPath`; `wxFileDialog` takes `message`/`defaultDir` (NOT `title`/`defaultPath`). `show_modal`/`get_path`/`destroy` type-dispatch on the `#wx_ref{}` type field — hardcoding `:wxDirDialog` on a `wxFileDialog` ref raises. Tests substitute a fake via `config :evo_dash, :directory_picker_wx` (`test/support/fake_directory_picker_wx.ex`).

**OTP's `wxe_server` is NOT a permanent singleton** — it stops when the last registered user exits. Every process that calls `:wx.new/0` or `:wx.set_env/1` registers with `wxe_server` as a "user" (`wxe_server.erl` `handle_call(register_me, ...)` monitors the caller), and `handle_info({'DOWN', ...})` STOPS the server when the LAST registered user exits. In the current design, wx is initialized fresh in each fallback pick Task (not cached in GenServer state). Each Task calls `:wx.new/0`, uses the dialog, then exits — the wxe_server stops with it and the next pick creates a brand-new server. This avoids the stale-cached-env failure mode ("Picker unavailable" on every browse after the first). The critical invariant remains: `{:directory_picker_result, ...}` + `{:pick_done, ...}` sends MUST run on EVERY path so a failed pick never wedges the picker.

### `EvoDash.UpdateStatus` (`update_status.ex`)

GenServer holding the single source of truth for the Tauri auto-update UI state (phase, versions, changelog, error, timestamps); broadcasts every transition on the `"updates"` topic of `EvoGit.PubSub` so LiveViews react without polling. Payloads from the JS hook arrive as string-keyed maps; every public function is non-crashing on malformed input (nil/non-map/unknown statuses normalize to `:error`). State machine: `:idle → :checking → :up_to_date | :available | :error`, `:available → :ready → :applying` (reversible via `apply_failed/1`); `reset/0` returns to `:idle`. Never-wedge invariants: every check-result path terminates `:checking`; `:error` is always retryable. Mutating API functions are casts (broadcast inside `handle_cast`); `get/0`, `phase/0`, `request_download?/0` are calls. Platform gating: `desktop?/0` checks `config :evo_dash, :desktop_release` or `EVOGIT_DESKTOP=1`; `visible?/1` hides on remote `genesis_remote` nodes and the dev server; `notify_only?/0` is true for Linux non-AppImage installs (package-manager info only, never self-download). Test seam `:update_notify_only_override`.

### `EvoDash.DesktopLifetime` (`desktop_lifetime.ex`)

Desktop-mode Tauri-shell lifetime watcher (TCP pipe): the Rust shell binds a `TcpListener` on `127.0.0.1:0`, holds one connection per backend instance, and passes the port via `EVOGIT_LIFETIME_PORT`; the shell never writes on the pipe. When the shell dies the OS closes the socket, `:gen_tcp.recv/3` errors, and the watcher logs a warning and stops the VM (`System.stop(0)`), freeing the port. Gated in `EvoDash.Application.start/2` to BOTH `EVOGIT_DESKTOP=1` and `EVOGIT_LIFETIME_PORT`; `init/1` self-disables when the port var is missing/empty/invalid. Lives in the frontend app by design so `genesis_remote` never ships it. Test seams: `:parent_stop_fun` (app env, read at `init/1`), `:connect_retries` / `:connect_retry_delay` (`start_link` opts, defaults 5/200ms).

### `EvoDash.AttachedFile` (`attached_file.ex`)

Reads attached objective files picked from the objective editor's attach-file '+' button (local files on the dashboard node). `read/1` dispatches on extension: plain text (`.txt`/`.md`/any) read verbatim and trimmed; `.docx` extracted to plain text with OTP stdlib only (`:zip` + regexes — only `word/document.xml` is read; headers/footers/footnotes/comments ignored, field codes stripped); `.pdf` extracted to Markdown via the pure-BEAM `ex_pdf` reader (each page → `## Page N`, a conversion note prepended; scanned/image-only PDFs → `{:empty, _}`, password-protected → `{:invalid, ...}`, opened with `recover: true`). Error shapes: bare POSIX atom (file read failure), `{:invalid, reason}` (malformed input), `{:empty, reason}` (valid but no text). `describe_error/2` builds user-ready messages.

### `EvoDash.MarkdownRender` (`markdown_render.ex`)

Markdown → safe HTML for agent summary output using the non-crashing `MDEx.to_html/1`. `render/1` returns `""` for nil; on rendering failure logs a warning and falls back to HTML-escaped text (never crashes, never raw/unescaped markdown).

### `EvoDash.SettingsUtils` (`settings_utils.ex`)

Pure config-form helpers used by the settings LiveView: `deep_put/3`, `deep_merge/2`, `deep_delete/2`, `parse_int/1`, `parse_float/1`, `parse_atom/2` (whitelist derived from schema `[in: [...]]` — never `String.to_atom` on untrusted input), `maybe_add_kw/3`.

## Constraints

- `EvoDash.Application` starts NO persistence/registry children — those belong to `EvoGit.Application`.
- `EvoDash.TaskSupervisor` IS started and IS used (async loads across all LiveViews). Do NOT remove it.
- `NodeContext` keeps its public API stable; web-layer callers should never touch `EvoGit.RemoteNode`/`EvoGit.RemoteConnection`/`EvoGit.RemoteConnections` directly.
- `DesktopLifetime` is desktop-only: gated on `EVOGIT_DESKTOP=1` + `EVOGIT_LIFETIME_PORT` so `genesis_remote` never ships it.
- Depends on `evo_git` application at compile and runtime.
