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
| `EvoDashWeb.TaskFormComponents` | `task_form_components.ex` | Single-card, two-layout objective editor (`task_form/1` — ONE `.input-card` containing the prompt textarea (`phx-hook="AdaptiveInput"` + `phx-update="ignore"` + `phx-change="task_prompt_change"` + `phx-debounce="200"`) AND the `.input-controls` row as its last element; `data-layout` is **server-driven** via `layout_for/1` — see "Task Form — Single-Card Two-Layout Design" below), `task_options_tab/1` (Configure-dropdown Task Options; inputs carry `form="task-form"`), legacy `advanced_options/1` |
| `EvoDashWeb.TaskCardComponents` | `task_card_components.ex` | Task cards with accent bar, relative timestamps, expandable details, result/options rendering helpers (`render_result_full/1`) |
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

The dashboard launch panel is ONE card (`.input-card`) containing the objective textarea AND the controls row (`.input-controls`) as its last element — in normal document flow, never `position: fixed`. The layout is **server-driven**: `EvoDashWeb.TaskFormComponents.layout_for/1` computes `data-layout` on `.input-layout` from the `@prompt` attr — the LiveView passes NO new attr and does NOT set `data-layout`.

- **Threshold**: `@short_objective_threshold 600` — `:expanded` when `String.length(prompt) > 600` graphemes OR the prompt has > 16 explicit lines (`line_count/1`, newline-split); otherwise `:compact`. Non-binary input → `:compact`. Public API: `layout_for/1` (pure, unit-tested).
- **Layout A — `data-layout="compact"`**: unified objective box; controls row is the card's last line, visual order **mode | model | Launch** (Launch centered).
- **Layout B — `data-layout="expanded"`**: large objective area (textarea fills); in-flow launch panel below, visual order **mode | model | Launch** (Launch centered) — only the textarea size differs from Layout A.
- **Same DOM order AND visual order in both layouts**: the controls render in DOM order mode | Launch | model with Tailwind `order-1`/`order-2`/`order-3` classes — mode always `order-1`, Launch always `order-2`, model always `order-3`. The Launch button carries **`mx-auto`** (`margin-inline: auto`), so in the flex `.input-controls` row (CSS `justify-content: space-between`) it is **centered in BOTH layouts** — this also fixes the 2-item edge case: when `@model_profiles == []` the model select is absent, and without `mx-auto` `space-between` would push Launch to the right edge. Asserted via Floki class checks in the component test.
- **Launch button `data-mode`**: the submit button carries `data-mode={@mode}`, which drives the per-mode hover ring color via CSS keyed on `.input-controls button[data-mode="..."]:hover` (in `assets/css/app.css`, added in parallel). The existing `task_change` event re-renders the button on mode change, keeping the attribute in sync. The button's classes/order/`mx-auto` are unchanged. Label is `<.icon name="hero-rocket-launch" class="size-4" /> {gettext("Launch")}` (the rocket icon was restored after a brief emoji era starting commit `46f5aafc`; the mode/model selects were bumped to `select-md text-base` and the `.input-controls` row gained `flex-wrap` in that same commit).
- **`task_prompt_change` event contract**: the textarea carries `phx-change="task_prompt_change"` (payload `%{"prompt" => prompt}`) + `phx-debounce="200"` so the server learns the prompt length while typing and re-renders `data-layout`. `EvoDashWeb.DashboardLive` must implement `handle_event("task_prompt_change", %{"prompt" => prompt}, socket)` (stores the prompt in `@task_prompt`). Because `phx-update="ignore"` is on the textarea, the re-render never clobbers the user's typing.
- **AdaptiveInput JS hook is autogrow-only**: it measures the textarea's content height and sets its height — it NO LONGER toggles `data-layout` and NO LONGER positions any floating panel (the old `--input-layout-center` / `position: fixed` logic was removed; the CSS floating rules and the `[dir="rtl"]` transform rule are gone).
- **CSS**: `.input-layout` / `.input-card` / `.input-prompt` / `.input-controls` class names are unchanged (the hook's `closest(".input-layout")` and the CSS selectors keep working). `.input-controls` now only provides the in-flow row (flex, `space-between`, `border-top`). See `assets/css/app.css` "Adaptive Input Layout" section (sibling node — CSS lives in `./assets/`).
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
