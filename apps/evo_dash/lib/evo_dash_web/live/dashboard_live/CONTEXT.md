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

## Windows Path Handling (Project Open/Create Flow) — RESOLVED (cwd-join fix)

Background (Windows user report): picking a folder on the D: drive surfaced errors like `Directory does not exist: c:/Users/<user>/AppData/Local/genesis-desktop/Test` — a name-only input (`Test`) was joined to the backend's cwd by `Path.expand/1`. On the Windows desktop app the backend's cwd is the Tauri process's inherited cwd — `desktop/src-tauri/src/sidecar.rs` spawns the launcher with NO `current_dir` → typically the install dir `C:\Users\<user>\AppData\Local\genesis-desktop` (NSIS per-user install). `Path.expand("Test")` there yields `C:/Users/<user>/AppData/Local/genesis-desktop/Test` (FORWARD slashes — Elixir's win32 `do_absname_join` converts `\`→`/`). Elixir's `Path.type/1` is OS-gated (win32 recognizes `X:\`/`X:/`/UNC as `:absolute`; a bare name or `X:` volume-relative input is joined to cwd — verified in Elixir 1.20.2 `lib/elixir/lib/path.ex`). There is NO literal `C:\` hardcoding anywhere in evo_dash/desktop/evo_git code — the `C:` in the report is runtime `File.cwd!()`, not a hardcode.

**Fix — `ProjectFlow.normalize_project_path/1` (public, `@spec normalize_project_path(String.t()) :: {:ok, String.t()} | {:error, :blank} | {:error, :relative}`)**: every server-side project-path entry point in `project_flow.ex` now normalizes input through this helper instead of bare `Path.expand/1`. Semantics: `String.trim/1` first; blank → `{:error, :blank}`; genuine tilde expansion (`~`, `~/...`, and — ONLY on Windows — `~\\...`, decided by the private `expandable_tilde?/1` predicate) → `{:ok, Path.expand(trimmed)}` (tilde expansion is cwd-independent); `EvoGit.Platform.absolute_path?/1` true → `{:ok, Path.expand(trimmed)}` (idempotent for absolute paths); anything else — bare names, volume-relative `D:Test`, root-relative `\Test`, `~foo`, non-Windows `~\x` — → `{:error, :relative}`. **Never-cwd-join rule**: `Path.expand/1` must never see a value that would be cwd-joined. Elixir's tilde handling (verified against stdlib `resolve_home/1`): `~`/`~/...` expand on ALL platforms, `~\...` ONLY on win32 (literal + cwd-joined on Unix), `~foo` NEVER on any platform (literal + cwd-joined) — `expandable_tilde?/1` guarantees `~foo` and off-Windows `~\x` fall through to `{:error, :relative}`.

Applied at `create_project/2`, `open_project/2`, `select_project/2`, `activate_remote_project/2`: `{:error, :blank}` → existing "Invalid project name" gettext flash (unchanged); `{:error, :relative}` → NEW gettext flash `Enter a full path, e.g. D:\Projects\myproject or /home/user/myproject`; `{:ok, expanded}` → existing logic unchanged (create: `validate_project_name(Path.basename(expanded))` → `File.dir?` → `register_and_open_project` / `File.mkdir_p` chain; open/select: dir check + recents + push_patch; activate_remote_project: gate guard first, then `EvoDash.NodeContext.dir?` remote validation + recents + push_patch). The existing "Directory does not exist…" / "…on the remote node…" flashes for absolute-but-missing directories are UNCHANGED.

**Recents filtering**: all four `:recent_projects` fetch sites (`register_and_open_project`, `open_project`, `select_project`, `activate_remote_project`) filter through the private `filter_absolute_recent_projects/1` (`Enum.filter(recent_projects, &EvoGit.Platform.absolute_path?(&1.path))`) — stale cwd-joined entries never render in the palette. `Project.path_suggestions/3` adds the same `EvoGit.Platform.absolute_path?/1` check to its recents filter.

**`Project.filesystem_suggestions/1` absolute/tilde guard**: suggestions are produced ONLY when `ProjectFlow.normalize_project_path(value)` returns `{:ok, expanded}` (absolute or genuinely tilde-expandable input); relative input (`~foo`, non-Windows `~\x`, bare names) → `[]`. The old bare-name branch `true -> {File.cwd!(), expanded}` is REMOVED — `File.cwd!()`-anchored suggestions for relative input can never be produced.

**Parallel work / follow-ups (not this directory)**: the JS DirectoryPicker fallback is being handled in parallel elsewhere (File System Access API browser picks yield only `handle.name`; Tauri native picks return full paths). Regression tests (unit tests for `normalize_project_path/1` + LiveView tests for relative-input rejection) are being added under `test/` by a follow-up task.
