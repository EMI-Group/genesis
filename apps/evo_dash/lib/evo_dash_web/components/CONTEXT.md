# UI Components

## Intent
Contains all reusable UI component modules and layout templates for the EvoDash web interface. This is the presentation layer — Phoenix function components rendered via HEEx templates, organized by domain concern.

## Routing Table
- `layouts/` → HTML layout templates (root layout shell with meta tags, CSRF, theme persistence)
- `review_components/` → Sub-components extracted from `ReviewComponents`: `DiffViewer`, `Header`, `Actions`, `Stats`
- `settings_components/` → Sub-components extracted from `SettingsComponents`: `CategoryMetadata`, `SettingCard`, `ModelProfilesEditor`, `Sidebar`, `SearchResults`

## API Surface

### Modules
| Module | File | Purpose |
|--------|------|---------|
| `EvoDashWeb.CoreComponents` | `core_components.ex` | Phoenix 1.8 scaffolded building blocks: `header/1`, `flash/1`, `flash_group/1`, `simple_form/1`, `button/1`, `icon/1`, `input/1`, `table/1`, `theme_toggle/1`, plus JS commands (`show_notification`, `toggle_dropdown`, `focus`, `close_parent`). The `flash/1` component supports three flash kinds: `:info`, `:error`, and `:warning` — each with appropriate styling (`alert-info`, `alert-error`, `alert-warning`) and corresponding Heroicon. |
| `EvoDashWeb.ProjectComponents` | `project_components.ex` | **Command Palette** project control (`project_omnibox/1` — trigger button showing active project → centered modal overlay with search-filtered recent-projects list + "Open Project by Path" + "Create New Project"; keyboard-first via server-side `palette_keydown`; trigger typography is enlarged — trigger `px-4 py-2`, project name `text-base font-bold`, path `text-sm`, placeholder `text-base`; `filter_projects/2` public helper for search filtering), sub-components `palette_menu/1`, `palette_open_path/1` (with PathAutocomplete hook), `palette_new_project/1`. Project settings panel and dropdown tab (`project_settings_panel/1`, `project_settings_tab/1`, shared `project_settings_body/1`: genesis.toml status, worktree script, dev commands, foreign repos) |
| `EvoDashWeb.TaskFormComponents` | `task_form_components.ex` | Single-card, two-layout objective editor (`task_form/1` — ONE `.input-card` containing the prompt textarea (`phx-hook="AdaptiveInput"` + `phx-update="ignore"` — NO `phx-change`, no per-keystroke server event) AND the `.input-controls` row as its last element; `data-layout` is **server-seeded** at render via `layout_for/1` and **client-driven** by the AdaptiveInput hook (re-asserts the computed layout while typing AND whenever the server re-seeds `data-layout` from its possibly-stale `@task_prompt` — MutationObserver re-assert, see "Task Form — Single-Card Two-Layout Design" below), `task_options_tab/1` (Configure-dropdown Task Options; inputs carry `form="task-form"`), legacy `advanced_options/1` |
| `EvoDashWeb.TaskCardComponents` | `task_card_components.ex` | Task cards with accent bar, relative timestamps, expandable details, result/options rendering helpers (`render_result_full/1`). **Summary-map safe** — hardened so both full `%TaskInfo{}` structs (TasksLive) and lightweight summary maps render without KeyError (see "Task Cards & the Summary-Map Contract" below). |
| `EvoDashWeb.ArchiveComponents` | `archive_components.ex` | Per-agent archive records, nested agent hierarchy tree, recursive node renderer (uses `EvoDashWeb.ArchiveHelpers`) |
| `EvoDashWeb.SettingsComponents` | `settings_components.ex` | Settings page components with VS Code-inspired sidebar+content layout: `setting_card/1` (schema-driven config key card with input widget, description, default hint, validation error display), `category_section/1` (right content area for a category with grouped settings and save button), `settings_sidebar/1` (category sidebar with icons, key counts, and search filter) |
| `EvoDashWeb.AgentsComponents` | `agents_components.ex` | Agent tree visualization: recursive `agent_tree/1` with connector lines and status indicator helpers (color/background/border/icon) for pending/running/waiting states |
| `EvoDashWeb.ReviewComponents` | `review_components.ex` | Review page components: `review_header/1` (PR title, status badge), `agent_summary/1`, `diff_stats_bar/1`, `action_buttons/1` (Merge, Reject, Continue, Create PR, Extract Skills, Ignore — Ignore is always available as the escape hatch for orphaned/deleted branches), `extract_skills_modal/1`, `commits_list/1` (clickable — navigates to commit inspection), `commit_detail_header/1`, `file_tree_sidebar/1`, `diff_viewer/1` (shared diff renderer with expandable context via `diff_expand_bar/1`), `split_diff_layout/1` (file sidebar + diff viewer for review), `commit_diff_layout/1` (file sidebar + diff viewer for single-commit inspection) |
| `EvoDashWeb.Layouts` | `layouts.ex` | Layout function components — `app/1` (the **sidebar-based app shell**: fixed left `<aside id="sidebar">` with branding, nav links, active-tasks section, and a bottom bar containing the node selector (leftmost) + language/theme toggles + collapse toggle; `phx-hook="SidebarCollapse"` for collapsible mode persisted to `localStorage`; mobile hamburger + overlay present but **not yet wired to JS**), `flash_group/1` (renders `:info`, `:error`, `:warning` flashes), `theme_toggle/1`, `theme_toggle_compact/1`, `language_selector/1`. **Node-aware (SSH Remote Development):** `app/1` accepts optional backward-compatible attrs (`current_node`, `current_node_id`, `current_node_name`, `remote_targets`, `connection_statuses` — all defaulting to safe local values) and renders `<.live_component module={EvoDashWeb.NodeSelectorComponent}>` **inside the sidebar's bottom bar** (leftmost position, wrapped in its own `data-sidebar-bottom-group`; `drop_up={true}` so the dropdown opens upward; language/theme toggles + collapse toggle sit to its right in a second `data-sidebar-bottom-group`). A private `with_node_param/2` helper appends `?node=<id>` to ALL nav links (when a remote node is selected). The `simple_nav` attr (default `false`) hides the nav links, active-tasks section, node selector, and bottom bar — leaving **only branding** (used by WelcomeLive). NOTE: the old top **navbar was replaced by this sidebar** — no top-bar header remains in the app shell. |

### Templates
| Template | Path | Purpose |
|----------|------|---------|
| Root HTML layout | `layouts/root.html.heex` | Base HTML shell — meta tags, CSRF token, LiveView title, CSS/JS asset links, client-side theme persistence script (`phx:theme` localStorage) |

### Usage Pattern
All component modules use `use EvoDashWeb, :html` (which expands to `use Phoenix.Component` + HTML imports). Components are invoked as function components in LiveViews:
```heex
<.button phx-click="save">Save</.button>
<.task_card task={@task} />
<.agent_tree agents={@agents} />
<.flash kind={:warning} flash={@flash} />
```

### Flash Component Kinds
The `flash/1` component in `CoreComponents` supports three kinds:
| Kind | CSS Class | Icon | Use Case |
|------|-----------|------|----------|
| `:info` | `alert-info` | `hero-information-circle` | Success messages, informational notices |
| `:error` | `alert-error` | `hero-exclamation-circle` | Error messages, validation failures |
| `:warning` | `alert-warning` | `hero-exclamation-triangle` | Warnings, missing configuration alerts |

## Constraints
- Every component module **must** use `use EvoDashWeb, :html`.
- Styling is Tailwind CSS + daisyUI — no inline CSS or external stylesheets in components.
- Icons use the Heroicon set via the `icon/1` component (naming convention: `hero-<name>[-style]`).
- Layout templates live under the `layouts/` subdirectory; only the root layout exists currently.
- Components are pure functions — they receive assigns and return HEEx markup; no side effects or direct LiveView process calls.
- Shared helpers from `EvoDashWeb.Helpers` should be used for cross-component utility functions (status badges, formatting, etc.) to avoid duplication between `DashboardComponents` and `AgentsComponents`.

### `try/rescue` Policy

`try/rescue` is normally an anti-pattern in Elixir. Within these component files:

- **Do NOT** wrap `String.to_existing_atom/1` in `try/rescue`. When normalizing potentially untrusted DB-sourced data (e.g., agent archive maps after a Jason.decode round-trip), use an explicit **whitelist map lookup** (`@known_agent_keys` in `normalize_agent_keys/1`) with `Map.get/3` defaulting to the original key. This avoids dynamic atom creation AND avoids try/rescue.
- **The ONLY justified `try/rescue`** in this subtree is `highlight_code_block/2` in `diff_viewer.ex`, which wraps `Lumis.highlight!/2` for syntax highlighting (called once for the full file in file-level mode, or per code block in hunk-level fallback). It is justified because: (1) the non-bang `Lumis.highlight/2` also raises internally (does not return `{:error, _}`), so `case`/`with` cannot replace it; (2) falling back to raw un-highlighted code is the correct graceful degradation for a single file/hunk failure. This rescue **must** carry the inline justification comment — do not remove it.
- If any new `try/rescue` is introduced, it MUST include a clear inline comment explaining why it is justified.

## Design Notes

### Task Form — Single-Card Two-Layout Design (`task_form_components.ex`)

The dashboard launch panel is ONE card (`.input-card`) containing the objective textarea AND the controls row (`.input-controls`) as its last element — in normal document flow, never `position: fixed`. The layout is **server-seeded at render + client-driven**: `EvoDashWeb.TaskFormComponents.layout_for/1` computes the initial `data-layout` on `.input-layout` from the `@prompt` attr — the LiveView passes NO new attr and does NOT set `data-layout`. There is NO per-keystroke server event for the objective textarea (no `phx-change`): the AdaptiveInput JS hook mirrors the same thresholds client-side and flips `data-layout` directly while typing, AND it re-asserts the computed layout whenever the server re-seeds `data-layout` from its possibly-stale `@task_prompt` — a MutationObserver on `.input-layout` (attributeFilter: ['data-layout']) re-runs the computation on any server re-render (e.g. toggling mode/model), so the layout can never snap back to compact while a long prompt remains in the box; the observer converges immediately (the hook only writes the attribute when the computed value differs) with zero network events.

- **Threshold**: `@short_objective_threshold 600` — `:expanded` when `String.length(prompt) > 600` graphemes OR the prompt has > 16 explicit lines (`line_count/1`, newline-split); otherwise `:compact`. Non-binary input → `:compact`. Public API: `layout_for/1` (pure, unit-tested).
- **Layout A — `data-layout="compact"`**: unified objective box; controls row is the card's last line, visual order **mode | model | Launch** (Launch centered).
- **Layout B — `data-layout="expanded"`**: large objective area (textarea fills); in-flow launch panel below, visual order **mode | model | Launch** (Launch centered) — only the textarea size differs from Layout A.
- **Same DOM order AND visual order in both layouts**: the controls render in DOM order mode | Launch | model with Tailwind `order-1`/`order-2`/`order-3` classes — mode always `order-1`, Launch always `order-2`, model always `order-3`. The Launch button carries **`mx-auto`** (`margin-inline: auto`), so in the flex `.input-controls` row (CSS `justify-content: space-between`) it is **centered in BOTH layouts** — this also fixes the 2-item edge case: when `@model_profiles == []` the model select is absent, and without `mx-auto` `space-between` would push Launch to the right edge. Asserted via Floki class checks in the component test.
- **Launch button `data-mode`**: the submit button carries `data-mode={@mode}`, which drives the per-mode hover ring color via CSS keyed on `.input-controls button[data-mode="..."]:hover` (in `assets/css/app.css`, added in parallel). The existing `task_change` event re-renders the button on mode change, keeping the attribute in sync. The button's classes/order/`mx-auto` are unchanged. Label is `<.icon name="hero-rocket-launch" class="size-4" /> {gettext("Launch")}` (the rocket icon was restored after a brief emoji era starting commit `46f5aafc`; the mode/model selects were bumped to `select-md text-base` in that same commit, and the `.input-controls` row later switched from `flex-wrap` to `flex-nowrap` with `min-w-0 truncate` on both selects so the three controls ALWAYS fit on one line — long labels truncate with an ellipsis instead of wrapping).
- **No per-keystroke server event for the objective textarea**: the textarea carries NO `phx-change`/`phx-debounce` — the server never learns the prompt while typing. `data-layout` is server-seeded at render (`layout_for/1` from the `@prompt` attr: SSR first paint + after restore/submit) and switched client-side by the AdaptiveInput hook while typing (mirrors the same thresholds). The hook ALSO re-asserts the layout whenever the server re-seeds `data-layout` from its possibly-stale `@task_prompt` (e.g. toggling mode/model triggers a server re-render that would otherwise snap the layout back to compact while a long prompt remains in the box) — a MutationObserver on `.input-layout` (attributeFilter: ['data-layout']) re-runs the computation on any server re-render, converging immediately (the hook only writes the attribute when the computed value differs) with no loop and zero network events. `@task_prompt` is updated ONLY by `restore_state` and `task_submit` (single, non-keystroke events). Because `phx-update="ignore"` is on the textarea, re-renders never clobber the user's typing. Prompt draft persistence is purely client-side (the StatePersistence input watcher in app.js reads `[name="prompt"]` from the DOM, 300ms debounce).
- **AdaptiveInput JS hook = autogrow + client-side layout switch**: it measures the textarea's content height and sets its height AND mirrors `layout_for/1`'s thresholds (> 600 graphemes OR > 16 lines) to toggle `data-layout` between compact/expanded while typing — no server round trip. It ALSO re-asserts the layout whenever the server re-seeds the attribute: a MutationObserver on `.input-layout` (attributeFilter: ['data-layout']) re-runs the same computation after any server re-render (e.g. toggling mode/model), converging in one step since `applyLayout` only writes the attribute when the computed value differs — no loop, zero network events, and the layout can never snap back to compact while a long prompt remains in the box. It NO LONGER positions any floating panel (the old `--input-layout-center` / `position: fixed` logic was removed; the CSS floating rules and the `[dir="rtl"]` transform rule are gone).
- **CSS**: `.input-layout` / `.input-card` / `.input-prompt` / `.input-controls` class names are unchanged (the hook's `closest(".input-layout")` and the CSS selectors keep working). `.input-controls` now only provides the in-flow row (flex, `space-between`) — the `border-top` separator between the textarea and the controls row was removed (commit `b597fd7e`) so the objective box and the three controls blend into one unified, immersive area. See `assets/css/app.css` "Adaptive Input Layout" section (sibling node — CSS lives in `./assets/`).
- Existing tests assert the rocket icon (`html =~ "hero-rocket-launch"`) + button text "Launch" — the button `type="submit"`, `disabled={@disabled}`, rocket icon, gettext labels, mode options, and the disabled welcome overlay are all preserved. No new translatable strings were added.

## Known Issues

### Command Palette (`project_omnibox`) — client-side wiring RESOLVED

The palette's client-side breakage (keyboard dead, click-outside not closing, transparent overlay) is **fixed**:

- **(Keyboard dead) `phx-keydown="palette_keydown"` now lives on the search input** (`input#palette-search-input` in `palette_menu/1`). Phoenix LiveView's keydown handler fires ONLY when the event TARGET (the focused element) itself carries the binding — it does NOT walk ancestors (verified against phoenix_live_view 1.2.8 source) — so the overlay div's binding never fired. The search input carries both `phx-keydown="palette_keydown"` and `phx-change="palette_search"` (they coexist; the server no-ops printable keys via `handle_palette_key/3` catch-all). The `:open_path` mode path input keeps its own `phx-keydown` + `phx-key="Escape"`. Do NOT add `phx-window-keydown` — `handle_palette_key(socket, "Enter", :menu)` would activate a project on ANY Enter press page-wide (no `@palette_open` gate server-side).
- **(Click-outside) `phx-click-away="close_project_palette"` added to `.project-palette-overlay`** — guarantees clicks anywhere outside the overlay (including the sidebar, which paints above the fixed backdrop) close the palette. The backdrop's `phx-click="close_project_palette"` remains as belt-and-braces.
- **(Transparent overlay) the `--b1/--b2/--b3` DaisyUI legacy variable namespace does not exist** in the vendored DaisyUI 5 themes (only `--color-base-*` etc. are defined) — the `oklch(var(--b1) / 0.98)` background rules in `app.css` were invalid at computed-value time and dropped. Fixed in `assets/css/app.css` (rewritten with `color-mix(...)` / `var(--color-base-*)`).
- **(Backdrop covering only the topbar strip) the `backdrop-filter: blur(12px)` on `.dashboard-topbar`** created a containing block for the fixed-position backdrop/overlay descendants, so `inset: 0` covered only the topbar strip. Removed in `assets/css/app.css` so the fixed-position backdrop/overlay are viewport-relative again.
- **Latent focus bug (still open, benign)**: `FocusInput` hook (`assets/js/app.js`) re-focuses on `updated()` only when the element HAS class `focus-on-update` (inverted intent), but no markup adds that class. Benign while morphdom preserves input focus; if a full element replacement ever loses focus, flip the check or add the class to the search input.
- **Component-level markup tests now exist**: `test/evo_dash_web/components/project_components_test.exs` asserts the search input's `phx-keydown`, the overlay's `phx-click-away="close_project_palette"` (and the backdrop's matching `phx-click`), and trigger rendering/typography.

### Sidebar expanded state must stay `overflow-visible` — SSH node-selector dropdown clipping

The app shell sidebar (`EvoDashWeb.Layouts.app/1`, `layouts.ex`) is a `z-50` stacking context above the main content (`#main-scroll` is `z-0`), so its dropdown menus paint above the main body — **unless** the sidebar clips them. The `<aside id="sidebar">` therefore carries **`overflow-visible!`** (Tailwind v4 important modifier) to pin `overflow: visible`.

Why the `!important`: the `SidebarCollapse` hook (`assets/js/hooks/sidebar_collapse.js`, OUTSIDE this node) re-applies `overflow-hidden` on the aside in the **expanded** state on every `mounted()`/`updated()` (it toggles `overflow-hidden` ↔ `overflow-visible` for expanded/collapsed). That clips the SSH node-selector dropdown (`w-72` = 288px) at the expanded sidebar's edge (`w-60` = 240px), making the main body appear to cover the SSH remote switch. The `!important` utility beats the hook's class toggle so the dropdown is never clipped.

- **History**: commit `6dd71210` ("fix: sidebar dropdowns covered by main content") changed `layouts.ex` to `overflow-visible` + `z-50` and added `z-0` to `#main-scroll`, but did NOT update the hook — so expanded-state clipping returned on the next mount. The proper root-cause fix lives in `sidebar_collapse.js`: remove the `overflow-hidden` add in the `applyCollapsed(false)` else branch (keep `overflow-visible`). That file is outside this node; if it is ever fixed, revert `overflow-visible!` in `layouts.ex` back to plain `overflow-visible`.
- **z-index contract** (do not disturb): sidebar `<aside>` `z-50`; main content `#main-scroll` `z-0` (stacking context, traps page modals below the sidebar); `.dropdown-content { z-index: 50 !important }` (app.css, keeps dropdown panels above sidebar siblings); mobile overlay `z-40`; config warning banner `z-40`; mobile hamburger `z-50`. Lowering the sidebar below `z-50` or raising `#main-scroll` above `z-0` re-breaks the stacking.
- **`simple_nav` mode** (WelcomeLive) renders branding **only** — the node selector lives INSIDE the `if !@simple_nav` block (bottom bar), so it is hidden in simple_nav mode along with the nav links, active-tasks section, and bottom bar; `overflow-visible` is safe there too.

### `phx-click` + JS hook on the same element — double firing (RESOLVED)

`phx-click` + a JS hook (`phx-hook`) on the SAME element sends BOTH the hook's handling AND the `phx-click` event to the server. Don't put both on one element unless a server-side `handle_event/3` clause exists.

The three directory-picker "Browse" buttons in `project_components.ex` (`project-path-browse-button`, `new-project-location-browse-button`, `foreign-repo-path-browse-button`) used to carry both `phx-click="pick_directory"` and `phx-hook="DirectoryPicker"`. The hook (in `assets/js/app.js`) opens the Tauri dialog and fills the adjacent input directly (never calls `pushEvent`), but the leftover `phx-click` also fired a `"pick_directory"` event with no matching `handle_event/3` clause → `FunctionClauseError` → LiveView crash in the desktop app. **Fixed** by removing the `phx-click` attributes; the hook fully owns the click. Regression guard: `test/evo_dash_web/components/project_components_test.exs` asserts the buttons keep the hook and have no `phx-click`.

## Task Cards & the Summary-Map Contract (dashboard optimization)

The dashboard's sidebar "Active Tasks" section in `EvoDashWeb.Layouts.app` is fed by the `@running_tasks` / `@pending_tasks` assigns — lightweight **summary maps** from the statuses-filtered `EvoGit.TaskRegistry.list_tasks_summary([:running, :pending, :finalizing, :completed])` (the `live/` + `live_hooks/` layers switched from `list_tasks/0` + `lightweight_task/1` / `strip_heavy_fields/1`). The former `@tasks` attr is GONE (Tasks A-D removed the dead dashboard main list and its `attr(:tasks, ...)` from `layouts.ex` — only `attr(:running_tasks, ...)` / `attr(:pending_tasks, ...)` remain). Full `%TaskInfo{}` structs (heavy `logs`/`usage`/`archive_metadata` columns) remain only on the Tasks page (TasksLive paginated full loads) and the Review page.

### The summary-map contract

Plain maps with keys: `id, status, review_status, result, started_at, finished_at, type, project_path, opts, branch_name, model_id, agent_count, base_sha, commit_sha, lease_expires_at`. `opts` is a decoded keyword list (same as `TaskInfo.opts` — includes objective/prompt/mode). EXCLUDED: `logs`, `usage`, `archive_metadata` (and all other TaskInfo fields like `ref`).

### Field-access rules for task-card components

- **Dot access (`task.field`) is safe ONLY for contract keys.** On a plain map, a missing key raises `KeyError`; on a struct it returns nil. So any dot access to a non-contract key crashes once a summary map is fed in.
- **`Map.get(task, field)` is safe for any key** (returns nil when absent).
- **Non-contract heavy fields** (`logs`, `usage`, `archive_metadata`) must be guarded: `Map.get(task, :logs) not in [nil, []]`, `Map.get(task, :usage)`, `Map.get(task, :archive_metadata) not in [nil, []]`. Guarded sections simply hide on summary maps (correct — the dashboard never had these fields after the old stripping) and render on full structs.

### Field-usage audit (components/ subtree) — conclusions

| Component / render path | Field | Access | In contract? | Fed by |
|---|---|---|---|---|
| `Layouts.app` sidebar Active Tasks (`layouts.ex:146-178`, `task_label/1`, `task_status_dot_color/1`, `group_tasks_by_project/1`) | `status`, `id`, `started_at`, `finished_at` | dot | ✅ yes | **dashboard** (`running_tasks`/`pending_tasks` only — the `tasks` attr was removed) + every LiveView mount (NodeAware) |
| same | `opts`, `project_path` | `Map.get` | ✅ yes | same |
| `TaskCardComponents.task_card/1` | `type`, `opts` (`[:mode]`/`[:prompt]`/`[:objective]`), `id`, `status`, `started_at`, `finished_at`, `agent_count`, `result`, `model_id` | dot | ✅ yes | TasksLive only (full structs via `list_tasks_paginated`) — **NOT dashboard-rendered**; hardened anyway for contract safety |
| same | `review_status` | `Map.get` | ✅ yes | TasksLive |
| same — "Token & Cost Usage" section (`:222-318`) | `usage` + nested `usage.*` | `Map.get` guard; inner dot access only inside guard | ❌ no | TasksLive only (section hidden on maps) |
| same — "Execution Logs" section (`:343-390`) | `logs` | **was unguarded dot `@task.logs != []` (KeyError on map) — FIXED to `Map.get(@task, :logs) not in [nil, []]`; inner accesses via `Map.get(@task, :logs, [])`** | ❌ no | TasksLive only (section hidden on maps) |
| same — archive section (`:392-397`) | `archive_metadata` | `Map.get` guard (`not in [nil, []]`) | ❌ no | TasksLive only (hidden on maps) |
| `TaskCardComponents.render_result_full/1` (`tasks_live.ex:294` — TasksLive only; the dashboard's full-result modal was removed in Tasks A-D) | input is `Map.get(task, :result)` — the **result VALUE** (runtime tuple), not the task map | — | ✅ (`result`) | TasksLive modal only |
| `Helpers.task_description/1` (called from `task_card` `:93/:95`; lives in `helpers.ex`, outside this node) | `type`, `opts` (map pattern match + keyword access) | pattern | ✅ yes | TasksLive |
| `ArchiveComponents` / `ReviewComponents` / `ProjectComponents` / `TaskFormComponents` / `AgentsComponents` | n/a | n/a | n/a | NOT task-list rendering (archive records, review page, palette/form, agent trees) — out of contract scope |

**Findings:**
1. The ONLY dashboard-rendered task-list markup under `components/` is the sidebar Active Tasks section in `layouts.ex`. It uses only contract keys (status/id/started_at/finished_at via dot; opts/project_path via Map.get) — **already summary-safe, no change needed**.
2. `task_card_components.ex` is rendered ONLY by TasksLive with full structs today. Its single unguarded non-contract dot access (`@task.logs != []`, line 343) was hardened to `Map.get(@task, :logs) not in [nil, []]` — behavior-identical for structs, KeyError-safe for maps. The file was also run through `mix format` (it had drifted from formatter-clean: the HEAD version fails `mix format --check-formatted` under Elixir 1.20.2; the committed version passes).
3. **No heavy field (logs/usage/archive_metadata) is needed by any dashboard-rendered card** — the dashboard card surface is the sidebar only (the dashboard's full-result modal was removed in Tasks A-D), and it needs only contract fields. Nothing to fetch lazily; no blocker to coordinate with the evo_git manager.

### Notes for the live/ + live_hooks/ parallel work (read-only observations)

- `live/modal_helpers.ex` `view_full_result/2` does `Enum.find(socket.assigns.tasks, &(&1.id == task_id))` + `Map.get(task || %{}, :result)` — `id`/`result` are contract keys (summary-safe), but post-Tasks-A-D **only TasksLive uses ModalHelpers**, where `socket.assigns.tasks` is the full TaskInfo page list (not summary maps) — struct-safe either way.
- `live/dashboard_live/assigns.ex:112` comment says "`list_tasks_summary` (which omits opts)" — **appears STALE** relative to the new contract (summary maps INCLUDE `opts`; root CONTEXT.md's SQL-lowering analysis confirms `select_tasks_summary` includes opts). Verify against the new evo_git API when it lands.
