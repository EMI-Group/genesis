# DashboardLive Support Modules

## Intent

Support modules extracted from `EvoDashWeb.DashboardLive` to keep the main LiveView module focused on lifecycle callbacks and event handlers.

## Routing Table

None — leaf directory (four module files: `state_persistence.ex`, `project.ex`, `project_flow.ex`, `assigns.ex`).

## API Surface

### Modules

| Module | Purpose |
|--------|---------|
| `StatePersistence` | Session persistence helpers (serialize/restore LiveView state to browser localStorage) |
| `Project` | Project-related pure functions (mode detection, path suggestions, config loading, model profiles) |
| `ProjectFlow` | Event handler implementations for project creation/opening (create_project, open_project, select_project) — extracted from DashboardLive (commit `b86ae86e`). The old `toggle_open_project_form`/`toggle_new_project_form` handlers were removed when the address bar was replaced by the command palette. `create_project/2` (reworked in commit `8f652ec7`) accepts a single full path `%{"path" => path}` from the palette's single-input form: blank → "Invalid project name"; `Path.basename` validated via `Project.validate_project_name/1` (rejects root-ish input); existing dir → opened as-is; missing dir → `File.mkdir_p/1` (recursive; **returns plain `:ok`, never `{:ok, _}`** — see test/CONTEXT.md Known Issues) then opened; mkdir failure → error flash. Success path shared via private `register_and_open_project/2`. Local-only (palette hides Create New Project when remote). |
| `Assigns` | Assign-building helpers (task categorization, form defaults) |

## Notes

- **Task-form layout — server-seeded + client-driven**: The task-form layout (compact vs expanded) is seeded server-side at render from prompt length via `TaskFormComponents.layout_for/1` (threshold > 600 graphemes OR > 16 lines) and updated client-side while typing by the AdaptiveInput JS hook (mirrors the same thresholds). The hook also re-asserts the computed layout whenever the server re-seeds `data-layout` from its possibly-stale `@task_prompt` — a MutationObserver on `.input-layout` (attributeFilter: ['data-layout']) re-runs the computation on any server re-render (e.g. toggling mode/model), converging immediately (the hook only writes the attribute when the computed value differs) with zero network events, so the layout never snaps back to compact while a long prompt remains in the box. There is no per-keystroke prompt-change event — the textarea has no `phx-change`, so `@task_prompt` is updated only by `restore_state` and `task_submit` (single, non-keystroke events). Prompt draft persistence is purely client-side (the StatePersistence input watcher in app.js).
- **Post-submit prompt clear**: After a successful `task_submit`, `assign_form_defaults/1` resets `task_prompt: ""` (so the next render seeds `data-layout="compact"`), and the handler pushes a `"clear_prompt"` event (via `push_event/3`). The AdaptiveInput JS hook handles it: it empties the visible textarea (morphdom skips it under `phx-update="ignore"`), re-asserts autogrow + layout (converges — `applyLayout` only writes the attribute when the computed value differs, no MutationObserver loop), and clears the `task_prompt` field in the persisted `dashboard_state` sessionStorage blob so a reload cannot resurrect the submitted prompt. Mode/model selects and all other form state are untouched.

## Constraints

- All modules are pure functions — no I/O, no socket, no process calls (except `StatePersistence` which interacts with assigns/session).
- Follows the project-wide `try/rescue` anti-pattern policy.

## Known Issues — Windows Path Handling (Project Open/Create Flow)

Investigated (Windows user report): picking a folder on the D: drive surfaces errors like `Directory does not exist: c:/Users/<user>/AppData/Local/genesis-desktop/Test` — a name-only input (`Test`) joined to the backend's cwd by `Path.expand/1`.

- **Every project-path entry point expands against `File.cwd!()`**: `ProjectFlow.create_project/2` (`project_flow.ex:33`), `open_project/2` (:98), `select_project/2` (:130), `activate_remote_project/2` (:171), `DashboardLive.handle_params` `?project=` param (:570), palette Enter (:1536), `Project.filesystem_suggestions/1` (`project.ex:109`), and the sibling `EvoGit.PathSuggestions.suggest/1`. Elixir's `Path.type/1` is OS-gated (win32 recognizes `X:\`/`X:/`/UNC as `:absolute`; a bare name or `X:` volume-relative input is joined to cwd — verified in Elixir 1.20.2 `lib/elixir/lib/path.ex`). On the Windows desktop app the backend's cwd is the Tauri process's inherited cwd — `desktop/src-tauri/src/sidecar.rs` spawns the launcher with NO `current_dir` → typically the install dir `C:\Users\<user>\AppData\Local\genesis-desktop` (NSIS per-user install). `Path.expand("Test")` there yields `C:/Users/<user>/AppData/Local/genesis-desktop/Test` (FORWARD slashes — Elixir's win32 `do_absname_join` converts `\`→`/`), exactly the reported bogus path.
- **Name-only values reach the input via the File System Access API branch**: `app.js` DirectoryPicker — `showDirectoryPicker` yields only `handle.name` (`fillInput(handle.name)`, `app.js:171`); browsers/WebView2 never expose full paths. Tauri native picks return full paths (verified `desktop/src-tauri/src/commands.rs:38-50`) and auto-submit; browser picks do NOT auto-submit (`app.js:275-285`). The JS never joins/mangles — the mangling is the server-side expansion of the bare name.
- **Silent wrong-location creation**: `create_project`'s `File.mkdir_p(expanded)` on the (writable) AppData install dir usually SUCCEEDS → the bogus project gets registered in recents (`EvoGit.TaskRegistry.add_recent_project` stores the path as-is) and pushed into the URL; from then on the palette / recents / auto-load-most-recent (`dashboard_live.ex:591-602`) propagate the bogus path, and `select_project`/palette-Enter flash it verbatim (`Directory does not exist: c:/Users/.../Test` — flash shows the raw param). `create_project`'s mkdir-failure flash shows the EXPANDED (joined) path directly. Once a bogus path is stored, the flash shows the full joined path even though `open_project`/`select_project` display the raw input.
- **No platform-aware absoluteness check in the dashboard flow**: `EvoGit.Platform.absolute_path?/1` (`apps/evo_git/lib/evo_git/platform.ex:184-197`, regex `^[A-Za-z]:[\/\\]|^\\\\`) exists and is used by the core runtime (`context_node.ex:68`, `foreign_repo.ex:136`, `agent/tools/shared.ex:282/368`) but NOT by the dashboard project flow — recommended fix anchor (reject or explicitly expand relative input instead of `Path.expand`-against-cwd).
- **No literal `C:\` hardcoding exists** in evo_dash/desktop/evo_git code (only comments/tests citing `C:\foo` as an example Windows absolute path, e.g. `agents_live.ex:772`); the `C:` in the report is runtime `File.cwd!()`, not a hardcode.
- **Test gap**: no Windows-specific path tests anywhere in `apps/evo_dash/test` (all project-flow tests use Unix `tmp_dir` / `/nonexistent/...` paths, which are already absolute — the cwd-join bug is invisible on Linux CI). `EvoGit.Platform.absolute_path?/1` IS unit-tested in `apps/evo_git/test/evo_git/platform_test.exs:12-17`.
