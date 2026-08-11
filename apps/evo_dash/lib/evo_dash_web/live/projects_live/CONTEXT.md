# ProjectsLive Support Modules

## Intent

Support modules extracted from `EvoDashWeb.ProjectsLive` to keep the main LiveView module focused on lifecycle callbacks and event handlers.

## Routing Table

None — leaf directory (four module files: `state_persistence.ex`, `project.ex`, `project_flow.ex`, `assigns.ex`).

## API Surface

### Modules

| Module | Purpose |
|--------|---------|
| `StatePersistence` | Session persistence helpers (serialize/restore LiveView state to browser localStorage) |
| `Project` | Project-related pure functions (mode detection, path suggestions, config loading, model profiles) |
| `ProjectFlow` | Event handler implementations for project creation/opening (create_project, open_project, select_project) — extracted from ProjectsLive (commit `b86ae86e`). The old `toggle_open_project_form`/`toggle_new_project_form` handlers were removed when the address bar was replaced by the command palette. `create_project/2` (reworked in commit `8f652ec7`) accepts a single full path `%{"path" => path}` from the palette's single-input form: blank → "Invalid project name"; `Path.basename` validated via `Project.validate_project_name/1` (rejects root-ish input); existing dir → opened as-is; missing dir → `File.mkdir_p/1` (recursive; **returns plain `:ok`, never `{:ok, _}`** — see test/CONTEXT.md Known Issues) then opened; mkdir failure → error flash. Success path shared via private `register_and_open_project/2`. Local-only (palette hides Create New Project when remote). |
| `Assigns` | Assign-building helpers (task categorization, form defaults) |

## Notes

- **Task-form layout — server-seeded + client-driven**: The task-form layout (compact vs expanded) is seeded server-side at render from prompt length via `TaskFormComponents.layout_for/1` (threshold > 600 graphemes OR > 16 lines) and updated client-side while typing by the AdaptiveInput JS hook (mirrors the same thresholds). The hook also re-asserts the computed layout whenever the server re-seeds `data-layout` from its possibly-stale `@task_prompt` — a MutationObserver on `.input-layout` (attributeFilter: ['data-layout']) re-runs the computation on any server re-render (e.g. toggling mode/model), converging immediately (the hook only writes the attribute when the computed value differs) with zero network events, so the layout never snaps back to compact while a long prompt remains in the box. There is no per-keystroke prompt-change event — the textarea has no `phx-change`, so `@task_prompt` is updated only by `restore_state` and `task_submit` (single, non-keystroke events). Prompt draft persistence is purely client-side (the StatePersistence input watcher in app.js).
- **Post-submit prompt clear**: After a successful `task_submit`, `assign_form_defaults/1` resets `task_prompt: ""` (so the next render seeds `data-layout="compact"`), and the handler pushes a `"clear_prompt"` event (via `push_event/3`). The AdaptiveInput JS hook handles it: it empties the visible textarea (morphdom skips it under `phx-update="ignore"`), re-asserts autogrow + layout (converges — `applyLayout` only writes the attribute when the computed value differs, no MutationObserver loop), and clears the `task_prompt` field in the persisted `dashboard_state` sessionStorage blob so a reload cannot resurrect the submitted prompt. Mode/model selects and all other form state are untouched.

## Performance Notes — Blocking I/O in support modules (investigation T1-A3, HEAD)

Durable findings for the "GET / takes 1-2s + ~25MB memory" investigation. All file:line refs verified at HEAD.

### Per-module I/O inventory (ALL synchronous in the LiveView process unless noted)

| Module / fn | I/O | Sync? | Notes |
|---|---|---|---|
| `Assigns.build_notified_task_ids/1` (assigns.ex:21-26) | `TaskRegistry.list_task_ids([:completed,:failed,:cancelled])` (SQLite via GenServer) | YES — `GenServer.call` | Tiny projection id/status/updated_at (`store.ex:182,618-637`; status-filter SQL index-backed `idx_tasks_status` schema.ex:76). Replies INLINE on TaskRegistry GenServer (task_registry.ex:460-465) — no Task offload, but cheap (no JSON decode). |
| `Assigns.assign_running_and_pending_tasks/1` (assigns.ex:36-53) | `TaskRegistry.list_tasks_summary([:running,:pending,:finalizing,:completed])` (SQLite via GenServer) | YES — blocks on `GenServer.call` reply | **Decode is Task-delegated** (task_registry.ex:416-427) but the LiveView blocks and receives the FULL decoded list. 16-col projection INCLUDES `result` and `decode_summary_row` runs `Codec.decode_result` PER ROW (store.ex:58,1053) — rebuilds `{:ok,%{...}}` + `%Usage{}` + archive_records (heaviest blob in DB) for every completed row. NOT project-scoped — scans all projects' rows in those 4 statuses. |
| `Project.detect_mode/1` (project.ex:40-48) | FS: `Path.expand`, `File.exists?` (CONTEXT.md stat), `new_codebase?` → `File.ls` (project.ex:69-77) | YES | Runs on activate_project + assign_form_defaults. Cheap per call. |
| `Project.load_model_profiles/0` (project.ex:23-34) | `Config.resolve()` — persistent_term-cached TOML parse (`config.ex:432-435` `cached_file_read`, revalidates via `File.stat` mtime/size per call) + Schema.validate | YES (pure-ish) | **Process-dict memoized**: `Process.get(:memo_config_resolve)` (project.ex:24); set at projects_live.ex:466 in mount. Survives SPA navigation (same process), re-runs on fresh page loads. |
| `Project.path_suggestions/3` + `filesystem_suggestions/1` (project.ex:117-182) | FS: `File.ls` + per-entry `File.dir?` | YES | Palette open-path events only, NOT navigation. |
| `Project.load_project_config/1` (project.ex:188-191) / `load_foreign_repos/1` (249-252) | `ProjectConfig.read` = `File.exists?` + `File.read` + `TomlElixir.decode` of genesis.toml (project_config.ex:76-83) | YES | Runs in `activate_project` (projects_live.ex:1821-1823) on EVERY navigation with a project (or auto-loaded recent), and in `:node_aware_reload_tasks` (projects_live.ex:1481) whenever project settings panel is open. |
| `ProjectFlow.create_project/open_project/select_project` (project_flow.ex:92-334) | `TaskRegistry.add_recent_project/2` + `list_recent_projects/0` (GenServer calls), `File.dir?`/`File.mkdir_p` | YES | Event-driven only (palette), not on navigation. |
| `StatePersistence.*` (state_persistence.ex) | NONE — pure assigns + `push_event("persist_state")` | — | No DB/FS/ETS. **No server-side cache** — persistence is purely client-side localStorage (JS hook); `maybe_persist_state` pushes a 12-key map on every call (mode toggles etc. — trivial payload). Every navigation re-queries everything server-side. |
| `remote_view.ex` | NONE — pure render components | — | Zero I/O. |

### The per-navigation (GET /) cost — why it's slow

LiveView runs `mount/3` TWICE per full page load (dead HTTP render + WebSocket connect), and `handle_params/3` after each. Per mount cycle:

1. **NodeAware.on_mount** (applied to ALL LiveViews via `evo_dash_web.ex`): `NodeContext.list_targets()` (TOML read) + `connection_status()` (GenServer) + `load_running_and_pending_tasks/1` → **`list_tasks_summary` #1** (node_aware.ex:44,71-93).
2. **ProjectsLive.mount**: `list_recent_projects()` (SQLite) + `Config.resolve()` + `build_systems()` (module attr, pure) + `list_task_ids` #1 + **`Assigns.assign_running_and_pending_tasks/1` → `list_tasks_summary` #2** (projects_live.ex:520, unguarded) + deferred `:load_config_status`.
3. **handle_params**: `assign_node/2`'s summary reload is dedup-guarded by `:tasks_node_loaded` (node_aware.ex:175-183 — kills the mount double-fetch for the NodeAware path) BUT ProjectsLive's own branches are NOT guarded: with no valid project → fallback `Assigns.assign_running_and_pending_tasks` #3 + `list_task_ids` #2 (projects_live.ex:665-678); with a project → `activate_project` (File.dir? + detect_mode FS + **genesis.toml read** + `list_task_ids` + summary #3).
4. **`:load_config_status`** (deferred one frame): `EvoGit.Config.config_status()` — re-reads config.toml + credentials.toml (cached parse + stat) — still blocks a frame in the LiveView process.

⇒ **A single full page load fires `list_tasks_summary` ~4-6 times** (2 mounts × 2-3 calls each), each call blocking the LiveView while the single-connection Store GenServer runs the query and the Task process decodes `result` for every completed row. With many completed tasks carrying large result blobs (archive_records + usage), this dominates the 1-2s load. SPA-style push_patch navigation re-runs only handle_params (1 summary + 1 task_ids + recents + genesis.toml read when a project is active).

### Memory (~25MB/page)

Retained in the LiveView heap per tab (N tabs = N copies): `@running_tasks` + `@pending_tasks` — the statuses-filtered summary maps **with fully decoded `result`** (pending_tasks = every completed-unreviewed-with-branch task, full 16-key map). The sidebar template reads only `result.branch_name` PRESENCE (`Assigns.show_review_button?`, assigns.ex:58-62) and status/started_at — the per-row `Codec.decode_result` is essentially wasted work for the current UI. Small retainers: `@recent_projects`, `@notified_task_ids` (ids only), `@model_profiles`, `@project_config`/`@commands`/`@foreign_repos`, `@config_status`. LiveView processes live until the tab closes (no `live_disconnect_timeout` in LV 1.2.8).

### Wasteful patterns to fix (candidate list)

1. **Duplicate sidebar fetch**: NodeAware.on_mount + ProjectsLive.mount:520 + handle_params fallback = up to 3 `list_tasks_summary` calls per mount cycle; only the NodeAware path is dedup-guarded. The `Assigns.assign_running_and_pending_tasks/1` and `NodeAware.load_running_and_pending_tasks/1` bodies are logic-identical.
2. **`result` decoded per summary row but barely used** — dropping `result` from the summary projection would need `show_review_button?` re-sourced (e.g. a branch_name column) and notification text re-sourced; lib/CONTEXT.md "Result-blob display audit" flags the same.
3. **Summary query not project-scoped** — scans all projects' running/pending/finalizing/completed rows on every navigation.
4. Store queries serialize on the single-connection Store GenServer with runtime writes.
5. `:node_aware_reload_tasks` (300ms after EVERY task broadcast): `list_task_ids` + summary + genesis.toml re-read when project settings shown — the broadcast-driven hotspot (see evo_git/CONTEXT.md:80).

### Stale-documentation note (verified at HEAD)

`apps/evo_dash/lib/CONTEXT.md` "Inline decode on the registry heap" section claims `list_tasks_summary*`/`list_tasks_changed_since` decode INLINE on the TaskRegistry GenServer heap. **STALE**: at HEAD all summary variants delegate to short-lived Tasks (task_registry.ex:416-427, 430-443, 446-457); only `list_task_ids` (460-465) replies inline by design. The GenServer-heap ratcheting concern is resolved — the **LiveView heap retention** is the remaining memory driver.

## Constraints

- All modules are pure functions — no I/O, no socket, no process calls (except `StatePersistence` which interacts with assigns/session).
- Follows the project-wide `try/rescue` anti-pattern policy.

## Windows Path Handling (Project Open/Create Flow) — RESOLVED (cwd-join fix)

Background (Windows user report): picking a folder on the D: drive surfaced errors like `Directory does not exist: c:/Users/<user>/AppData/Local/genesis-desktop/Test` — a name-only input (`Test`) was joined to the backend's cwd by `Path.expand/1`. On the Windows desktop app the backend's cwd is the Tauri process's inherited cwd — `desktop/src-tauri/src/sidecar.rs` spawns the launcher with NO `current_dir` → typically the install dir `C:\Users\<user>\AppData\Local\genesis-desktop` (NSIS per-user install). `Path.expand("Test")` there yields `C:/Users/<user>/AppData/Local/genesis-desktop/Test` (FORWARD slashes — Elixir's win32 `do_absname_join` converts `\`→`/`). Elixir's `Path.type/1` is OS-gated (win32 recognizes `X:\`/`X:/`/UNC as `:absolute`; a bare name or `X:` volume-relative input is joined to cwd — verified in Elixir 1.20.2 `lib/elixir/lib/path.ex`). There is NO literal `C:\` hardcoding anywhere in evo_dash/desktop/evo_git code — the `C:` in the report is runtime `File.cwd!()`, not a hardcode.

**Fix — `ProjectFlow.normalize_project_path/1` (public, `@spec normalize_project_path(String.t()) :: {:ok, String.t()} | {:error, :blank} | {:error, :relative}`)**: every server-side project-path entry point in `project_flow.ex` now normalizes input through this helper instead of bare `Path.expand/1`. Semantics: `String.trim/1` first; blank → `{:error, :blank}`; genuine tilde expansion (`~`, `~/...`, and — ONLY on Windows — `~\\...`, decided by the private `expandable_tilde?/1` predicate) → `{:ok, Path.expand(trimmed)}` (tilde expansion is cwd-independent); `EvoGit.Platform.absolute_path?/1` true → `{:ok, Path.expand(trimmed)}` (idempotent for absolute paths); anything else — bare names, volume-relative `D:Test`, root-relative `\Test`, `~foo`, non-Windows `~\x` — → `{:error, :relative}`. **Never-cwd-join rule**: `Path.expand/1` must never see a value that would be cwd-joined. Elixir's tilde handling (verified against stdlib `resolve_home/1`): `~`/`~/...` expand on ALL platforms, `~\...` ONLY on win32 (literal + cwd-joined on Unix), `~foo` NEVER on any platform (literal + cwd-joined) — `expandable_tilde?/1` guarantees `~foo` and off-Windows `~\x` fall through to `{:error, :relative}`.

Applied at `create_project/2`, `open_project/2`, `select_project/2`, `activate_remote_project/2`: `{:error, :blank}` → existing "Invalid project name" gettext flash (unchanged); `{:error, :relative}` → NEW gettext flash `Enter a full path, e.g. D:\Projects\myproject or /home/user/myproject`; `{:ok, expanded}` → existing logic unchanged (create: `validate_project_name(Path.basename(expanded))` → `File.dir?` → `register_and_open_project` / `File.mkdir_p` chain; open/select: dir check + recents + push_patch; activate_remote_project: gate guard first, then `EvoDash.NodeContext.dir?` remote validation + recents + push_patch). The existing "Directory does not exist…" / "…on the remote node…" flashes for absolute-but-missing directories are UNCHANGED.

**Recents filtering**: all four `:recent_projects` fetch sites (`register_and_open_project`, `open_project`, `select_project`, `activate_remote_project`) filter through the private `filter_absolute_recent_projects/1` (`Enum.filter(recent_projects, &EvoGit.Platform.absolute_path?(&1.path))`) — stale cwd-joined entries never render in the palette. `Project.path_suggestions/3` adds the same `EvoGit.Platform.absolute_path?/1` check to its recents filter.

**`Project.filesystem_suggestions/1` absolute/tilde guard**: suggestions are produced ONLY when `ProjectFlow.normalize_project_path(value)` returns `{:ok, expanded}` (absolute or genuinely tilde-expandable input); relative input (`~foo`, non-Windows `~\x`, bare names) → `[]`. The old bare-name branch `true -> {File.cwd!(), expanded}` is REMOVED — `File.cwd!()`-anchored suggestions for relative input can never be produced.

**Directory picker — server-side wx protocol (DONE)**: `handle_event("directory_pick", %{"picker_id" => id})` (pushed by the JS `DirectoryPicker` hook) branches on the node: local (`socket.assigns.current_node == node()`) → the picker module (`Application.get_env(:evo_dash, :directory_picker_module, EvoDash.DirectoryPicker)`, guarded by `Code.ensure_loaded?/1`) `pick/2`s `self()` — `:ok` returns immediately (async dialog), `{:error, :unavailable}` pushes `picker_result:<id>` with `%{unavailable: true}`; remote/headless node → `%{unavailable: true}` pushed immediately (a wx dialog must never pop on a remote node). The async result arrives as `handle_info({:directory_picker_result, picker_id, result})` and is pushed as `picker_result:<id>` with `%{path: path}` / `%{cancelled: true}` / `%{unavailable: true}`. The old dead `directory_picked` handler was REMOVED. LiveView tests live in `test/evo_dash_web/live/projects_live_test.exs` ("directory picker" block: remote→unavailable, disabled→unavailable, fake-module happy path via `EvoDash.DirectoryPicker.Fake` in `test/support/`). The relative-input rejection tests (`normalize_project_path/1`, commits `d9149aba`/`db5a0d34`) are UNCHANGED.
