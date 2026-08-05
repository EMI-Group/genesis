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
| `EvoDashWeb.ProjectComponents` | `project_components.ex` | **Command Palette** project control (`project_omnibox/1` — trigger button showing active project → centered modal overlay with search-filtered recent-projects list + "Open Project by Path" + "Create New Project"; keyboard-first via server-side `palette_keydown`; `filter_projects/2` public helper for search filtering), sub-components `palette_menu/1`, `palette_open_path/1` (with PathAutocomplete hook), `palette_new_project/1`. Project settings panel and dropdown tab (`project_settings_panel/1`, `project_settings_tab/1`, shared `project_settings_body/1`: genesis.toml status, worktree script, dev commands, foreign repos) |
| `EvoDashWeb.TaskFormComponents` | `task_form_components.ex` | Single-card, two-layout objective editor (`task_form/1` — ONE `.input-card` containing the prompt textarea (`phx-hook="AdaptiveInput"` + `phx-update="ignore"` + `phx-change="task_prompt_change"` + `phx-debounce="200"`) AND the `.input-controls` row as its last element; `data-layout` is **server-driven** via `layout_for/1` — see "Task Form — Single-Card Two-Layout Design" below), `task_options_tab/1` (Configure-dropdown Task Options; inputs carry `form="task-form"`), legacy `advanced_options/1` |
| `EvoDashWeb.TaskCardComponents` | `task_card_components.ex` | Task cards with accent bar, relative timestamps, expandable details, result/options rendering helpers (`render_result_full/1`) |
| `EvoDashWeb.ArchiveComponents` | `archive_components.ex` | Per-agent archive records, nested agent hierarchy tree, recursive node renderer (uses `EvoDashWeb.ArchiveHelpers`) |
| `EvoDashWeb.SettingsComponents` | `settings_components.ex` | Settings page components with VS Code-inspired sidebar+content layout: `setting_card/1` (schema-driven config key card with input widget, description, default hint, validation error display), `category_section/1` (right content area for a category with grouped settings and save button), `settings_sidebar/1` (category sidebar with icons, key counts, and search filter) |
| `EvoDashWeb.AgentsComponents` | `agents_components.ex` | Agent tree visualization: recursive `agent_tree/1` with connector lines and status indicator helpers (color/background/border/icon) for pending/running/waiting states |
| `EvoDashWeb.ReviewComponents` | `review_components.ex` | Review page components: `review_header/1` (PR title, status badge), `agent_summary/1`, `diff_stats_bar/1`, `action_buttons/1` (Merge, Reject, Continue, Create PR, Extract Skills, Ignore — Ignore is always available as the escape hatch for orphaned/deleted branches), `extract_skills_modal/1`, `commits_list/1` (clickable — navigates to commit inspection), `commit_detail_header/1`, `file_tree_sidebar/1`, `diff_viewer/1` (shared diff renderer with expandable context via `diff_expand_bar/1`), `split_diff_layout/1` (file sidebar + diff viewer for review), `commit_diff_layout/1` (file sidebar + diff viewer for single-commit inspection) |
| `EvoDashWeb.Layouts` | `layouts.ex` | Layout function components — `app/1` (the **sidebar-based app shell**: fixed left `<aside id="sidebar">` with branding, node selector, nav links, active-tasks section, language/theme toggles; `phx-hook="SidebarCollapse"` for collapsible mode persisted to `localStorage`; mobile hamburger + overlay present but **not yet wired to JS**), `flash_group/1` (renders `:info`, `:error`, `:warning` flashes), `theme_toggle/1`, `theme_toggle_compact/1`, `language_selector/1`. **Node-aware (SSH Remote Development):** `app/1` accepts optional backward-compatible attrs (`current_node`, `current_node_id`, `current_node_name`, `remote_targets`, `connection_statuses` — all defaulting to safe local values) and renders `<.live_component module={EvoDashWeb.NodeSelectorComponent}>` inside the sidebar (below the brand header). A private `with_node_param/2` helper appends `?node=<id>` to ALL nav links (when a remote node is selected). The `simple_nav` attr (default `false`) hides the nav links, active-tasks section, and bottom bar — leaving just branding + node selector (used by WelcomeLive). NOTE: the old top **navbar was replaced by this sidebar** — no top-bar header remains in the app shell. |

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

- **Threshold**: `@short_objective_threshold 300` — `:expanded` when `String.length(prompt) > 300` graphemes OR the prompt has > 8 explicit lines (`line_count/1`, newline-split); otherwise `:compact`. Non-binary input → `:compact`. Public API: `layout_for/1` (pure, unit-tested).
- **Layout A — `data-layout="compact"`**: unified objective box; controls row is the card's last line, visual order **mode | model | Launch** (Launch bottom-right via CSS `justify-content: space-between`).
- **Layout B — `data-layout="expanded"`**: large objective area (textarea fills); in-flow launch panel below, visual order **mode | Launch | model** (Launch in the middle).
- **Same DOM order, CSS reorder**: both layouts render the controls in DOM order mode | Launch | model; the per-layout visual order is achieved with Tailwind `order-1`/`order-2`/`order-3` classes (mode always `order-1`; Launch `order-3` compact / `order-2` expanded; model `order-2` compact / `order-3` expanded) — asserted via Floki class checks in the component test.
- **`task_prompt_change` event contract**: the textarea carries `phx-change="task_prompt_change"` (payload `%{"prompt" => prompt}`) + `phx-debounce="200"` so the server learns the prompt length while typing and re-renders `data-layout`. `EvoDashWeb.DashboardLive` must implement `handle_event("task_prompt_change", %{"prompt" => prompt}, socket)` (stores the prompt in `@task_prompt`). Because `phx-update="ignore"` is on the textarea, the re-render never clobbers the user's typing.
- **AdaptiveInput JS hook is autogrow-only**: it measures the textarea's content height and sets its height — it NO LONGER toggles `data-layout` and NO LONGER positions any floating panel (the old `--input-layout-center` / `position: fixed` logic was removed; the CSS floating rules and the `[dir="rtl"]` transform rule are gone).
- **CSS**: `.input-layout` / `.input-card` / `.input-prompt` / `.input-controls` class names are unchanged (the hook's `closest(".input-layout")` and the CSS selectors keep working). `.input-controls` now only provides the in-flow row (flex, `space-between`, `border-top`). See `assets/css/app.css` "Adaptive Input Layout" section (sibling node — CSS lives in `./assets/`).
- Existing tests assert `html =~ "Launch Task"` — the button text, `type="submit"`, `disabled={@disabled}`, rocket icon, gettext labels, mode options, and the disabled welcome overlay are all preserved. No new translatable strings were added.

## Known Issues

### Command Palette (`project_omnibox`) is broken client-side — 3 independent root causes (investigated, not yet fixed)

Symptoms: (a) palette overlay renders with a transparent/unreadable background, (b) keyboard (arrows/Enter/Esc) does nothing in menu mode, (c) clicking outside does not close it. The SERVER side is complete and test-covered (`dashboard_live_test.exs` "project palette" describe, lines 453-600, drives events directly with `render_click` so it cannot catch client-side breakage). All three causes are client-side:

1. **(b) `phx-keydown` on the overlay div never fires** — `project_components.ex:93` puts `phx-keydown="palette_keydown"` on `.project-palette-overlay`, but the focused element is the search input (`project_components.ex:137-147`), which has NO `phx-keydown`. In phoenix_live_view 1.2.8 (`deps/phoenix_live_view/priv/static/phoenix_live_view.js`), the keydown handler (`bind()` at ~7149, listener on `window` via `on()` at ~7672) checks `e.target.getAttribute("phx-keydown")` (~7155) — it fires ONLY when the event TARGET itself carries the binding, with NO ancestor walk (unlike clicks, which use `closestPhxBinding` at ~7210). No element has `phx-window-keydown` either, so `palette_keydown` is never pushed. **Only Escape in `:open_path` mode works** (the path input itself carries `phx-keydown` + `phx-key="Escape"`, `project_components.ex:266-267`). Minimal fix: add `phx-keydown="palette_keydown"` to the search input itself (server no-ops non-nav keys via `handle_palette_key/3` catch-all, `dashboard_live.ex:1447`). Do NOT use `phx-window-keydown` — `handle_palette_key(socket, "Enter", :menu)` would activate a project on ANY Enter press page-wide (no `@palette_open` gate server-side).
2. **(a) overlay/backdrop backgrounds are dropped** — `app.css:1369` uses `background: oklch(var(--b1) / 0.98)` and `border: 1px solid oklch(var(--b3))` (also 1292-1293 topbar, 1337, 1372, 1385-1410, plus ~40 more rules at 1040-1560). The vendored DaisyUI 5 (`assets/vendor/daisyui.js` + `daisyui-theme.js`, `themes: false`) defines ONLY `--color-base-100/-200/-300/-content`, `--color-primary`, etc. — the legacy `--b1/--b2/--b3/--bc/--p` namespace **does not exist** (verified: zero matches in both vendor files; zero definitions in lib/assets). Undefined `var()` → declaration "invalid at computed-value time" → dropped → transparent modal box, no border; `oklch(var(--project-accent) / 0.12)` (app.css:1389) is ALSO invalid (resolves to `oklch(oklch(...)/0.12)` — a nested color function is not valid color syntax) so even the selected-item highlight dies. Tailwind utilities like `bg-base-100/95` work fine (they compile to `color-mix(...)`). Fix: rewrite these rules with `color-mix(in oklab, var(--color-base-100) 98%, transparent)` / plain `var(--color-base-100)` or Tailwind classes in the markup.
3. **(c) backdrop click-away only covers the topbar strip** — `.project-palette-backdrop` (`app.css:1346-1354`, `position: fixed; inset: 0; z-index: 60`) and `.project-palette-overlay` (z-70) are DOM descendants of `.dashboard-topbar` (`dashboard_live.ex:315`; `app.css:1286-1301` has `backdrop-filter: blur(12px)` at 1294). Per CSS filter-effects-2, `backdrop-filter` creates a **containing block for fixed-position descendants**, so `inset: 0` covers only the topbar's padding box (~50px strip) — clicks on the rest of the page never hit the backdrop, and the overlay's `top: 15vh` resolves to 15% of the topbar's height (stuck at the very top of the page). Additionally the topbar (z-30; stacking context from backdrop-filter + z-index) traps the palette's z-60/70 below the sidebar `<aside>` z-50 (`layouts.ex:80`, documented contract below). The `phx-click="close_project_palette"` handler itself works (`closestPhxBinding` walks ancestors). `phx-click-away` is NOT used anywhere in the codebase. Minimal fix options: remove `backdrop-filter` from `.dashboard-topbar` (restores viewport-relative fixed positioning; must also fix the broken topbar `background` from cause 2 so it stays readable), and/or move the backdrop+overlay markup out of the topbar subtree; optionally add `phx-click-away` to the overlay as belt-and-braces.
4. **Latent focus bug**: `FocusInput` hook (`assets/js/app.js:482-492`) re-focuses on `updated()` only when the element HAS class `focus-on-update` (`classList.contains(...) !== false` — inverted intent), but no markup ever adds that class (palette search input doesn't). Currently benign (morphdom preserves input focus), but any full element replacement loses focus permanently → keyboard dead. Fix: flip to `!this.el.classList.contains(...)` or add the class to the search input.
- No component test exists for `project_components.ex` markup (only `dashboard_live_test.exs`); no JS-level tests. Palette tests assert `phx-click="close_project_palette"` and `palette_keydown` server handling only.

### Sidebar expanded state must stay `overflow-visible` — SSH node-selector dropdown clipping

The app shell sidebar (`EvoDashWeb.Layouts.app/1`, `layouts.ex`) is a `z-50` stacking context above the main content (`#main-scroll` is `z-0`), so its dropdown menus paint above the main body — **unless** the sidebar clips them. The `<aside id="sidebar">` therefore carries **`overflow-visible!`** (Tailwind v4 important modifier) to pin `overflow: visible`.

Why the `!important`: the `SidebarCollapse` hook (`assets/js/hooks/sidebar_collapse.js`, OUTSIDE this node) re-applies `overflow-hidden` on the aside in the **expanded** state on every `mounted()`/`updated()` (it toggles `overflow-hidden` ↔ `overflow-visible` for expanded/collapsed). That clips the SSH node-selector dropdown (`w-72` = 288px) at the expanded sidebar's edge (`w-60` = 240px), making the main body appear to cover the SSH remote switch. The `!important` utility beats the hook's class toggle so the dropdown is never clipped.

- **History**: commit `6dd71210` ("fix: sidebar dropdowns covered by main content") changed `layouts.ex` to `overflow-visible` + `z-50` and added `z-0` to `#main-scroll`, but did NOT update the hook — so expanded-state clipping returned on the next mount. The proper root-cause fix lives in `sidebar_collapse.js`: remove the `overflow-hidden` add in the `applyCollapsed(false)` else branch (keep `overflow-visible`). That file is outside this node; if it is ever fixed, revert `overflow-visible!` in `layouts.ex` back to plain `overflow-visible`.
- **z-index contract** (do not disturb): sidebar `<aside>` `z-50`; main content `#main-scroll` `z-0` (stacking context, traps page modals below the sidebar); `.dropdown-content { z-index: 50 !important }` (app.css, keeps dropdown panels above sidebar siblings); mobile overlay `z-40`; config warning banner `z-40`; mobile hamburger `z-50`. Lowering the sidebar below `z-50` or raising `#main-scroll` above `z-0` re-breaks the stacking.
- **`simple_nav` mode** (WelcomeLive) renders branding + node selector without the collapse hook; `overflow-visible` is safe there too.
