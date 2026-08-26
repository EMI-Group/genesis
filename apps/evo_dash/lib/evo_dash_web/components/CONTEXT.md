# UI Components

## Intent

Contains all reusable UI component modules and layout templates for the EvoDash web interface. This is the presentation layer — Phoenix function components rendered via HEEx templates, organized by domain concern.

## Routing Table

- `layouts/` → HTML layout templates (currently only the root layout shell with meta tags, CSRF, theme persistence)
- `review_components/` → Sub-components extracted from `ReviewComponents`: `DiffViewer`, `Header`, `Actions`, `Stats`
- `settings_components/` → Sub-components extracted from `SettingsComponents`: `CategoryMetadata`, `SettingCard`, `ModelProfilesEditor`, `CustomAgentsEditor`, `ModelSelectionEditor`, `Sidebar`, `SearchResults`

## API Surface

### Modules
| Module | File | Purpose |
|--------|------|---------|
| `EvoDashWeb.CoreComponents` | `core_components.ex` | Phoenix 1.8 scaffolded building blocks: `header/1`, `flash/1`, `flash_group/1`, `simple_form/1`, `button/1`, `icon/1`, `input/1`, `table/1`, `theme_toggle/1`, plus JS commands (`show_notification`, `toggle_dropdown`, `focus`, `close_parent`). `flash/1` supports three kinds — see "Flash Component Kinds" below. Also carries the `brand-github` icon used by the Projects top-bar GitHub button. |
| `EvoDashWeb.GitHubComponents` | `github_components.ex` | GitHub issues modal (`issues_modal/1`, root id `github-issues-modal`) for the Projects page: state-filter buttons (`open`/`closed`/`all` via `phx-click="github_filter_state"`), issue rows (number, state badge, label badges, author/date, external GitHub link, per-row `github_fix_issue` Fix button), loading/empty/error states; public `error_message/1` surfaces `gh` CLI errors (`{:gh, _, output}` → output; anything else → generic "install/authenticate gh" message). Pure presentation — no gh/git calls. |
| `EvoDashWeb.ProjectComponents` | `project_components.ex` | **Command Palette** project control (`project_omnibox/1` — trigger button → centered modal overlay with search-filtered recent-projects list + "Open Project by Path" + "Create New Project"; keyboard-first via server-side `palette_keydown`; public `filter_projects/2` helper), sub-components `palette_menu/1`, `palette_open_path/1` (with PathAutocomplete hook), `palette_new_project/1`. Project settings panel + dropdown tab (`project_settings_panel/1`, `project_settings_tab/1`, shared `project_settings_body/1`: genesis.toml status, worktree script, dev commands, foreign repos) |
| `EvoDashWeb.TaskFormComponents` | `task_form_components.ex` | Single-card, two-layout objective editor (`task_form/1` — ONE `.input-card` containing the prompt textarea (`phx-hook="AdaptiveInput"` + `phx-update="ignore"`, NO `phx-change`) AND the `.input-controls` row as its last element; `data-layout` is server-seeded at render via `layout_for/1` and client-driven by the AdaptiveInput hook — see "Task Form — Single-Card Two-Layout Design" below), `task_options_tab/1` (Configure-dropdown Task Options; inputs carry `form="task-form"`), legacy `advanced_options/1` |
| `EvoDashWeb.TaskCardComponents` | `task_card_components.ex` | Task cards with accent bar, relative timestamps, expandable details, result/options rendering helpers (`render_result_full/1`, `render_options_full/1`, `objective_text/1`, `result_copy_text/1`). **Summary-map safe** — hardened so both full `%TaskInfo{}` structs (TasksLive) and lightweight summary maps render without KeyError (see "Task Cards & the Summary-Map Contract" below). |
| `EvoDashWeb.ArchiveComponents` | `archive_components.ex` | Per-agent archive records, nested agent hierarchy tree, recursive node renderer (uses `EvoDashWeb.ArchiveHelpers` — module at `../archive_helpers.ex`, outside this node) |
| `EvoDashWeb.SettingsComponents` | `settings_components.ex` | Settings page components with VS Code-inspired sidebar+content layout: `setting_card/1` (schema-driven config key card with input widget, description, default hint, validation error display), `category_section/1` (right content area for a category with grouped settings and save button), `settings_sidebar/1` (category sidebar with icons, key counts, and search filter). Also hosts the LLM Quick Setup flow (see "Settings Quick Setup" below). |
| `EvoDashWeb.AgentsComponents` | `agents_components.ex` | Agent tree visualization: recursive `agent_tree/1` with connector lines and status indicator helpers (color/background/border/icon) for pending/running/waiting states |
| `EvoDashWeb.ReviewComponents` | `review_components.ex` | Review page components: `review_header/1` (PR title, status badge), `agent_summary/1`, `diff_stats_bar/1`, `action_buttons/1` (Merge, Reject, Continue, Create PR, Extract Skills, Ignore — Ignore is always available as the escape hatch for orphaned/deleted branches), `extract_skills_modal/1`, `commits_list/1` (clickable — navigates to commit inspection), `commit_detail_header/1`, `file_tree_sidebar/1`, `diff_viewer/1` (shared diff renderer with expandable context via `diff_expand_bar/1`), `split_diff_layout/1` (file sidebar + diff viewer for review), `commit_diff_layout/1` (file sidebar + diff viewer for single-commit inspection). Thin delegators over the `review_components/` sub-modules. |
| `EvoDashWeb.RemoteGateComponents` | `remote_gate_components.ex` | Shared SSH-remote connection gate: `remote_connection_gate/1` (spinner + "Connecting to %{name}…" for `:connecting`/`:bootstrapping`/`:disconnecting`; `alert-error` with `last_error` + Retry / Manage Connections / Switch to Local for `:error`/`:disconnected`; nothing when connected/local) + public predicate `gate_active?/1` (nil node → false; node + nil status → true; connecting/bootstrapping/disconnecting/error/disconnected → true; connected → false; unknown shapes → false). ⚠️ Call it fully-qualified with the assigns map (`<%= EvoDashWeb.RemoteGateComponents.remote_connection_gate(assigns) %>`) — do NOT use the declarative `<.remote_connection_gate assigns={assigns}/>` form: it mangles node-name resolution (renders "Local" instead of the target name). |
| `EvoDashWeb.Layouts` | `layouts.ex` | Layout function components — `app/1` (the **sidebar-based app shell**: fixed left `<aside id="sidebar">` with branding, nav links, active-tasks section, and a bottom bar containing the node selector (leftmost) + language/theme toggles + collapse toggle; `phx-hook="SidebarCollapse"` for collapsible mode persisted to `localStorage`; mobile hamburger + overlay present but not yet wired to JS), `flash_group/1` (renders `:info`, `:error`, `:warning` flashes), `theme_toggle/1`, `theme_toggle_compact/1`, `language_selector/1`. **Node-aware (SSH Remote Development):** `app/1` accepts optional backward-compatible attrs (`current_node`, `current_node_id`, `current_node_name`, `remote_targets`, `connection_statuses` — all defaulting to safe local values) and renders `<.live_component module={EvoDashWeb.NodeSelectorComponent}>` inside the sidebar's bottom bar (`drop_up={true}`); a private `with_node_param/2` helper appends `?node=<id>` to ALL nav links when a remote node is selected. The `simple_nav` attr (default `false`) hides nav links, active-tasks section, node selector, and bottom bar — leaving only branding (used by WelcomeLive). The app shell is sidebar-based — no top-bar header exists. |

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
- Shared helpers from `EvoDashWeb.Helpers` should be used for cross-component utility functions (status badges, formatting, etc.) to avoid duplication between the dashboard component modules (`ProjectComponents`, `TaskFormComponents`, `TaskCardComponents`, …) and `AgentsComponents`.
- **Task cancellation UX (graceful + force kill)** (`task_card_components.ex`): the inline Cancel button is GRACEFUL — `phx-click="open_cancel_modal"` (btn-outline neutral/info, NO `phx-confirm` — the modal confirms), visible `[:pending, :running]` only (NOT `:finalizing`/`:cancelling`). The three-dot dropdown adds a `text-error` "Force kill" item (`phx-click="open_force_kill_modal"`, visible `[:running, :cancelling]` = escalation, no `phx-confirm`) with an `<li class="menu-title">` `gettext("Danger zone")` divider above Delete (Delete keeps its `phx-confirm`). The `:cancelling` status renders as IN-PROGRESS (NOT terminal): badge shows a violet pulsing dot + `gettext("Cancelling…")` label via a `cond` clause, `status_accent_color(:cancelling) → "bg-violet-500"`, `task_card_tint(%{status: :cancelling})` → violet tint. `layouts.ex` sidebar: `:cancelling` is included in the `is_running` check, both `Enum.split_with` running lists AND `task_status_dot_color(%{status: :cancelling}) → "bg-violet-500"` so cancelling tasks keep the running presentation (link to /agents, pulse animation, elapsed time). The sidebar has NO cancel button (task links only) and deliberately NO force-kill surface — the Tasks page dropdown is the force-kill surface.

### `try/rescue` Policy

`try/rescue` is normally an anti-pattern in Elixir. Within these component files:

- **Do NOT** wrap `String.to_existing_atom/1` in `try/rescue`. When normalizing potentially untrusted DB-sourced data (e.g., agent archive maps after a Jason.decode round-trip), use an explicit **whitelist map lookup** (`@known_agent_keys` in `normalize_agent_keys/1`) with `Map.get/3` defaulting to the original key. This avoids dynamic atom creation AND avoids try/rescue.
- If any new `try/rescue` is introduced, it MUST include a clear inline comment explaining why it is justified.

## Design Notes

### Settings Quick Setup — credentials gated on model selection (`settings_components.ex` + `settings_live.ex`)
The LLM Quick Setup is a **select-then-save** flow — provider buttons → variant buttons → model buttons (`phx-click="select_llm_model"`, sets `selected_model_string` assign; highlight `btn-primary shadow-md`), and only THEN do the credential inputs render:
- **Save Model form** (`phx-submit="save_quick_setup"`, hidden `provider_id` + `variant_id` + `model_string` + submit button `gettext("Save Model")`) renders ONLY when `@selected_model_string != nil`; its base_url input renders ONLY when `EvoGit.Config.LLMCatalog.requires_base_url?(@selected_provider_id)` is true (catalog function — the `provider[:requires_base_url]` map field is DEAD). The `save_quick_setup` handler (model_profile_events.ex) already defaults missing/empty base_url to `opts = []`.
- **API Key form** (`phx-submit="save_api_key"`) renders when `show_custom_input or @selected_model_string != nil` — custom-model providers (OpenRouter/OpenAI-Compatible) keep it immediately after provider selection (their `save_custom_model` form IS the model-selection step); preset providers get the hint `gettext("Select a model above to configure credentials.")` until a model is picked.
- `select_llm_provider` and `select_llm_variant` RESET `selected_model_string` to nil. The `select_llm_model` handler is whitelist-safe via `llm_model_string_known?/2` (validates the model_string against the selected provider's rendered shortcut buttons — same `resolve_provider_atom/2` resolution). `select_llm_model_shortcut` is a dead-but-harmless handler (no button fires it).

### Task Form — Single-Card Two-Layout Design (`task_form_components.ex`)

The dashboard launch panel is ONE card (`.input-card`) containing the objective textarea AND the controls row (`.input-controls`) as its last element — in normal document flow, never `position: fixed`. The layout is **server-seeded at render + client-driven**: `EvoDashWeb.TaskFormComponents.layout_for/1` computes the initial `data-layout` on `.input-layout` from the `@prompt` attr. There is NO per-keystroke server event for the objective textarea (no `phx-change`/`phx-debounce` — `@task_prompt` is updated ONLY by `restore_state` and `task_submit`; because the textarea carries `phx-update="ignore"`, re-renders never clobber the user's typing; prompt draft persistence is purely client-side via the StatePersistence input watcher in app.js, 300ms debounce). The **AdaptiveInput JS hook** mirrors `layout_for/1`'s thresholds client-side and flips `data-layout` directly while typing (it also autogrows the textarea by measuring content height), AND it re-asserts the computed layout whenever the server re-seeds the attribute: a MutationObserver on `.input-layout` (attributeFilter: ['data-layout']) re-runs the computation after any server re-render (e.g. toggling mode/model), so the layout can never snap back to compact while a long prompt remains in the box; it converges immediately (the hook only writes the attribute when the computed value differs) with zero network events. It does NOT position any floating panel (no `--input-layout-center` / `position: fixed` logic).

- **Threshold**: `@short_objective_threshold 600` — `:expanded` when `String.length(prompt) > 600` graphemes OR the prompt has > 16 explicit lines (`line_count/1`, newline-split); otherwise `:compact`. Non-binary input → `:compact`. Public API: `layout_for/1` (pure, unit-tested).
- **Layout A — `data-layout="compact"`**: unified objective box; the textarea auto-grows up to ~8 lines and flips to expanded the instant content would exceed the cap.
- **Layout B — `data-layout="expanded"`**: the textarea fills the card (`flex: 1`, internal `overflow-y: auto`, NO max-height cap — the card's `overflow: hidden` flex containment bounds it on any viewport height), keeping the in-flow launch panel pinned to the card's bottom regardless of prompt length.
- **Same DOM order AND visual order in both layouts**: the controls render in DOM order mode | Launch | model with Tailwind `order-1`/`order-2`/`order-3` classes — mode always `order-1`, Launch always `order-2`, model always `order-3`. The Launch button carries **`mx-auto`** (`margin-inline: auto`), so in the flex `.input-controls` row (CSS `justify-content: space-between`) it is **centered in BOTH layouts** — this also covers the 2-item edge case when `@model_profiles == []` (without `mx-auto`, `space-between` would push Launch to the right edge). Asserted via Floki class checks in the component test.
- **Launch button `data-mode`**: the submit button carries `data-mode={@mode}`, which drives the per-mode hover ring color via CSS keyed on `.input-controls button[data-mode="..."]:hover` (in `assets/css/app.css`); `task_change` re-renders the button on mode change, keeping the attribute in sync. Label is `<.icon name="hero-rocket-launch" class="size-4" /> {gettext("Launch")}`. The mode/model selects use `select-md text-base`; `.input-controls` is `flex-nowrap` with `min-w-0 truncate` on both selects so the three controls ALWAYS fit on one line (long labels truncate with an ellipsis instead of wrapping).
- **CSS**: the class names are `.input-layout` / `.input-card` / `.input-prompt` / `.input-controls` (used by the hook's `closest(".input-layout")` and the CSS selectors). The accent decorations — accent border-color, layered box-shadow glow, and the `::before` top-edge gradient — are defined on the base `.input-card` rule and apply to BOTH layouts; layout-specific sizing/containment stays in the `[data-layout="compact"]` / `[data-layout="expanded"]` overrides. `.input-controls` provides only the in-flow row (flex, `space-between`) with no `border-top` separator. CSS lives in `assets/css/app.css` "Adaptive Input Layout" section (sibling node — see `./assets/`).
- Tests assert the rocket icon (`html =~ "hero-rocket-launch"`) + button text "Launch" — the button `type="submit"`, `disabled={@disabled}`, gettext labels, mode options, and the disabled welcome overlay are covered. This feature introduces no new translatable strings.

## Known Issues

### Command Palette (`project_omnibox`) — client-side wiring

- **Keyboard**: `phx-keydown="palette_keydown"` lives on the search input (`input#palette-search-input` in `palette_menu/1`). Phoenix LiveView's keydown handler fires ONLY when the event TARGET (the focused element) itself carries the binding — it does NOT walk ancestors — so the binding must be on the search input, not the overlay div. The search input carries both `phx-keydown="palette_keydown"` and `phx-change="palette_search"` (they coexist; the server no-ops printable keys via `handle_palette_key/3` catch-all). The `:open_path` mode path input keeps its own `phx-keydown` + `phx-key="Escape"`. Do NOT add `phx-window-keydown` — `handle_palette_key(socket, "Enter", :menu)` would activate a project on ANY Enter press page-wide (no `@palette_open` gate server-side).
- **Click-outside**: `phx-click-away="close_project_palette"` is on `.project-palette-overlay` — clicks anywhere outside the overlay (including the sidebar, which paints above the fixed backdrop) close the palette. The backdrop's `phx-click="close_project_palette"` remains as belt-and-braces.
- **Overlay backgrounds**: the `--b1/--b2/--b3` DaisyUI legacy variable namespace does not exist in the vendored DaisyUI 5 themes (only `--color-base-*` etc. are defined) — the `.project-palette-overlay` background rules in `app.css` use `color-mix(...)` / `var(--color-base-*)`.
- **Backdrop is viewport-relative**: `.dashboard-topbar` has NO `backdrop-filter` — a `backdrop-filter` would create a containing block that traps the fixed-position backdrop/overlay (descendants) to the topbar strip. Without it, the fixed-position backdrop/overlay are viewport-relative.
- **Latent focus bug (open, benign)**: the `FocusInput` hook (`assets/js/app.js`) re-focuses on `updated()` only when the element HAS class `focus-on-update` (inverted intent), but no markup adds that class. Benign while morphdom preserves input focus; if a full element replacement ever loses focus, flip the check or add the class to the search input.
- **Regression guard**: `test/evo_dash_web/components/project_components_test.exs` asserts the search input's `phx-keydown`, the overlay's `phx-click-away="close_project_palette"` (and the backdrop's matching `phx-click`), and trigger rendering/typography.

### Sidebar expanded state must stay `overflow-visible` — SSH node-selector dropdown clipping

The app shell sidebar (`EvoDashWeb.Layouts.app/1`, `layouts.ex`) is a `z-50` stacking context above the main content (`#main-scroll` is `z-0`), so its dropdown menus paint above the main body — **unless** the sidebar clips them. The `<aside id="sidebar">` therefore carries **`overflow-visible!`** (Tailwind v4 important modifier) to pin `overflow: visible`. Why the `!important`: the `SidebarCollapse` hook (`assets/js/hooks/sidebar_collapse.js`, OUTSIDE this node) re-applies `overflow-hidden` on the aside in the **expanded** state on every `mounted()`/`updated()`, which clips the SSH node-selector dropdown (`w-72` = 288px) at the expanded sidebar's edge (`w-60` = 240px). Root-cause fix location: remove the `overflow-hidden` add in the hook's `applyCollapsed(false)` else branch (keeping `overflow-visible`); until then `overflow-visible!` in `layouts.ex` is required.

- **z-index contract** (do not disturb): sidebar `<aside>` `z-50`; main content `#main-scroll` `z-0` (stacking context, traps page modals below the sidebar); `.dropdown-content { z-index: 50 !important }` (app.css, keeps dropdown panels above sidebar siblings); mobile overlay `z-40`; config warning banner `z-40`; mobile hamburger `z-50`. Lowering the sidebar below `z-50` or raising `#main-scroll` above `z-0` re-breaks the stacking.
- **`simple_nav` mode** (WelcomeLive) renders branding **only** — the node selector lives INSIDE the `if !@simple_nav` block (bottom bar), so it is hidden in simple_nav mode along with the nav links, active-tasks section, and bottom bar; `overflow-visible` is safe there too.

### `phx-click` + JS hook on the same element — double firing

`phx-click` + a JS hook (`phx-hook`) on the SAME element sends BOTH the hook's handling AND the `phx-click` event to the server. Don't put both on one element unless a server-side `handle_event/3` clause exists.

The three directory-picker "Browse" buttons in `project_components.ex` (`project-path-browse-button`, `new-project-location-browse-button`, `foreign-repo-path-browse-button`) carry ONLY `phx-hook="DirectoryPicker"` — the hook fully owns the click: it pushes a `"directory_pick"` event to the server (ProjectsLive runs the picker via `EvoDash.DirectoryPicker` and pushes the result back as `picker_result:<picker_id>`). Do NOT add `phx-click` to these buttons — a `"pick_directory"` event has no matching `handle_event/3` clause → `FunctionClauseError` → LiveView crash. Regression guard: `test/evo_dash_web/components/project_components_test.exs` asserts the buttons keep the hook and have no `phx-click`.

**Remote-node gating**: the same three Browse buttons are ALSO gated on `!@remote` — the render condition is `@tauri_detected and !@remote`, so when the dashboard views a REMOTE node (`?node=` param) the native picker buttons are hidden and the manual path inputs (`project-path-input`, `new-project-path-input`, `foreign-repo-path-input` with PathAutocomplete) remain the fallback. Rationale: the picker runs on the LOCAL dashboard machine, so a remote pick is meaningless (the backend already pushes `picker_result:<id> %{unavailable: true}` for `directory_pick` on remote nodes). The `remote` attr is threaded from `project_omnibox/1` into `palette_open_path`/`palette_new_project` and from `RemoteView.top_bar/1` into `project_settings_tab/1` (via the shared `project_settings_body/1`); `project_settings_panel/1` carries the attr for consistency (no callers).

## Task Cards & the Summary-Map Contract

The dashboard's sidebar "Active Tasks" section in `EvoDashWeb.Layouts.app` is fed by the `@running_tasks` / `@pending_tasks` assigns — lightweight **summary maps** from the statuses-filtered `EvoGit.TaskRegistry.list_tasks_summary([:running, :pending, :finalizing, :completed])`. `layouts.ex` declares only `attr(:running_tasks, ...)` / `attr(:pending_tasks, ...)` — there is NO `@tasks` attr (the dashboard renders no main task list). Full `%TaskInfo{}` structs (heavy `logs`/`usage`/`archive_metadata` columns) are used only on the Tasks page (TasksLive paginated full loads) and the Review page.

### The summary-map contract

Plain maps with keys: `id, status, review_status, result, started_at, finished_at, type, project_path, opts, branch_name, model_id, agent_count, base_sha, commit_sha, lease_expires_at`. `opts` is a decoded keyword list (same as `TaskInfo.opts` — includes objective/prompt/mode). EXCLUDED: `logs`, `usage`, `archive_metadata` (and all other TaskInfo fields like `ref`).

### Field-access rules for task-card components

- **Dot access (`task.field`) is safe ONLY for contract keys.** On a plain map, a missing key raises `KeyError`; on a struct it returns nil. So any dot access to a non-contract key crashes once a summary map is fed in.
- **`Map.get(task, field)` is safe for any key** (returns nil when absent).
- **Non-contract heavy fields** (`logs`, `usage`, `archive_metadata`) must be guarded: `Map.get(task, :logs) not in [nil, []]`, `Map.get(task, :usage)`, `Map.get(task, :archive_metadata) not in [nil, []]`. Guarded sections simply hide on summary maps (correct — the dashboard sidebar never renders these fields) and render on full structs.

### Task detail view — flattened Objective / Agent Message cards (expanded card + zoom modals)

The expanded task card detail view (`@show_details`, TasksLive only) shows **two direct cards** in a 2-column grid (no nested card level):

- **Objective card** (always, when an objective text exists): header `gettext("Objective")` + copy button (`id="task-<id>-objective-copy"`, `phx-hook="ClipboardCopy"`, `data-content={objective_text(@task.opts)}`) + "Full" button (`view_full_options` → Full Objective zoom modal). Body = `render_options(@task.opts)`: FULL objective text (no truncation) in a `max-h-48 overflow-y-auto` scrollable container + mode/path badges.
- **Agent Message card** (guarded `Map.get(@task, :result)`): header `gettext("Agent Message")` + copy button (`id="task-<id>-result-copy"`, `data-content={result_copy_text(@task.result)}`) + "Full" button (`view_full_result` → Full Result zoom modal). Body = `render_result(@task.result)` — full content, scrollable; preserves the commit_sha/branch_name/tag/pr_url badges, the No Changes notice, and the Error/Crashed states (their sub-headers remain inside the body).

Public pure helpers added for this: `objective_text/1` (`(opts[:prompt] || opts[:objective] || "") |> String.trim()` — shared with the collapsed-card preview) and `result_copy_text/1` (success/no-changes binary result → the string; `{:error, _}`/`{:exit, _}` → `inspect(reason, limit: :infinity)`; fallback → pretty inspect). Both are reused by the zoom modals in `tasks_live.ex` (Full Result modal `id="full-result-copy"`, Full Objective modal `id="full-options-copy"`, both in the `<:actions>` slot). The zoomed (`truncate: false`) branches keep `max-h-[70vh] overflow-y-auto`; TasksLive has the `"copied"` → "Copied to clipboard" flash handler (required for the ClipboardCopy hook push).

### Field-usage audit — conclusions

| Component / render path | Fields | Access | Contract-fed by |
|---|---|---|---|
| `Layouts.app` sidebar Active Tasks (`layouts.ex`, `task_label/1`, `task_status_dot_color/1`, `group_tasks_by_project/1`) | `status`, `id`, `started_at`, `finished_at` (dot); `opts`, `project_path` (`Map.get`) | dot on contract keys | dashboard (`running_tasks`/`pending_tasks` only) + every LiveView mount (NodeAware) |
| `TaskCardComponents.task_card/1` | `type`, `opts` (`[:mode]`/`[:prompt]`/`[:objective]`), `id`, `status`, `started_at`, `finished_at`, `agent_count`, `result`, `model_id` (dot); `review_status` (`Map.get`) | dot on contract keys | TasksLive only (full structs via `list_tasks_paginated`) — NOT dashboard-rendered; written contract-safe anyway |
| `TaskCardComponents.task_card/1` — "Token & Cost Usage", "Execution Logs", archive sections | `usage` + nested `usage.*`; `logs`; `archive_metadata` | `Map.get` guard (`not in [nil, []]`); inner accesses via `Map.get(@task, :logs, [])` | TasksLive only (sections hidden on summary maps) |
| `TaskCardComponents.render_result_full/1` (TasksLive only; the dashboard has no full-result modal) | input is `Map.get(task, :result)` — the **result VALUE** (runtime tuple), not the task map | — | TasksLive modal only |
| `Helpers.task_description/1` (lives in `helpers.ex`, outside this node) | `type`, `opts` (map pattern match + keyword access) | pattern | TasksLive |

**Findings:**
1. The ONLY dashboard-rendered task-list markup under `components/` is the sidebar Active Tasks section in `layouts.ex`. It uses only contract keys (status/id/started_at/finished_at via dot; opts/project_path via Map.get) — summary-safe.
2. `task_card_components.ex` is rendered ONLY by TasksLive with full structs; its heavy-field sections are `Map.get`-guarded — behavior-identical for structs, KeyError-safe for maps.
3. **No heavy field (logs/usage/archive_metadata) is needed by any dashboard-rendered card** — the dashboard card surface is the sidebar only (no full-result modal exists on the dashboard), and it needs only contract fields. Nothing is fetched lazily.
