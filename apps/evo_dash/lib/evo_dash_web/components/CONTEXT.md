# UI Components

## Intent

Reusable UI component modules and layout templates for the EvoDash web interface — the presentation layer, Phoenix function components rendered via HEEx, organized by domain concern.

## Routing Table

- `layouts/` → HTML layout templates (only the root layout shell: meta tags, CSRF, theme persistence).
- `agents_components/` → Agents-page commit-history sub-components (`CommitGraphView` + `agents_components/commit_graph/geometry.ex`) — full detail: `agents_components/CONTEXT.md`.
- `review_components/` → Review-page sub-components: `DiffViewer`, `Header`, `Actions`, `RepoCards`, `Stats` — full detail: `review_components/CONTEXT.md`.
- `settings_components/` → Settings sub-components: `CategoryMetadata`, `SettingCard`, `ModelProfilesEditor`, `CustomAgentsEditor`, `CustomToolsPanel`, `ModelSelectionEditor`, `Sidebar`, `SearchResults`, plus the shared building blocks `SaveBar`, `SectionHeader`, `CardShell`, `FormFooter` — full detail: `settings_components/CONTEXT.md`.
- `task_card_components/` → the card's helper submodules (`ResultRender`, `Options`, `Repos`, `Archive`, `Errors`, re-exported via `EvoDashWeb.TaskCardComponents` delegates) + the card's SUMMARY-map/`detail` contract — full detail: `task_card_components/CONTEXT.md`.

## API Surface

### Modules
| Module | File | Purpose |
|--------|------|---------|
| `EvoDashWeb.CoreComponents` | `core_components.ex` | Phoenix 1.8 scaffolded building blocks: `flash/1` (three kinds — see below), `button/1`, `input/1`, `header/1`, `table/1`, `list/1`, `icon/1` (hero + `brand-*` sets incl. `brand-github`), `tabs/1`, `collapsible_card/1`, `show/1`/`hide/1` JS-command wrappers, `translate_error/1`/`translate_errors/2`. NOT here: `flash_group/1` + both theme toggles (in `layouts.ex`); there are NO `show_notification`/`toggle_dropdown`/`focus`/`close_parent` JS commands anywhere in the codebase — sidebar dropdowns are native `<details>` and any close logic must be JS-side. |
| `EvoDashWeb.GitHubComponents` | `github_components.ex` | GitHub issues modal (`issues_modal/1`, root id `github-issues-modal`): state filters (`open`/`closed`/`all` via `phx-click="github_filter_state"`), issue rows (number, state/label badges, author/date, external link, per-row `github_fix_issue` Fix button), loading/empty/error states, public `error_message/1`. Pure presentation — no gh/git calls. |
| `EvoDashWeb.ProjectComponents` | `project_components.ex` | Command-palette project control (`project_omnibox/1` → centered modal with search-filtered recents + "Open Project by Path" + "Create New Project"; keyboard-first via server-side `palette_keydown`; public `filter_projects/2`) with `palette_menu/1`, `palette_open_path/1` (PathAutocomplete hook), `palette_new_project/1`; plus the project-settings panel/tab (`project_settings_panel/1`, `project_settings_tab/1`, shared `project_settings_body/1` — see "Foreign Repos"). |
| `EvoDashWeb.TaskFormComponents` | `task_form_components.ex` | Single-card, two-layout objective editor (`task_form/1` — ONE `.input-card` with the prompt textarea (`phx-hook="AdaptiveInput"` + `phx-update="ignore"`, NO `phx-change`) and the bottom toolbar `.input-controls` as its last element), `task_options_tab/1` (Configure-dropdown Task Options; inputs carry `form="task-form"`), legacy `advanced_options/1` — see "Task Form" below. |
| `EvoDashWeb.TaskCardComponents` | `task_card_components.ex` | Task cards (accent bar, relative timestamps, expandable details) fed by a 16-key task SUMMARY map plus a lazily-fetched `detail`; owns the `task_card/1` template + attrs, the status/tint/accent mapping, the bounded preview helpers (`text_preview/2`, `log_preview/1`, `copy_payload/1`, `preview_limit_note/1`), `show_review_button?/1`, and `defdelegate`s for every public helper implemented in `task_card_components/` (call sites always use `EvoDashWeb.TaskCardComponents.<fun>`). Summary-map safe — contract: `task_card_components/CONTEXT.md`. |
| `EvoDashWeb.ArchiveComponents` | `archive_components.ex` | `archive_count_line/1` (the ONE shared count/exhaustion line used by BOTH archive render sites) + `archive_details/1` (paged archive envelope: count/range label, "Load more", per-agent lazy result) + recursive `archive_tree/1` / `archive_tree_node/1` for per-agent archive records (tree via `EvoDashWeb.ArchiveHelpers`, at `../archive_helpers.ex`, outside this node); render paths are capped (see the caps section). |
| `EvoDashWeb.SettingsComponents` | `settings_components.ex` | Settings page with the VS Code-inspired sidebar+content layout: `setting_card/1` (schema-driven config-key card with input widget, description, default hint, validation error), `category_section/1` (category content area with grouped settings + save), `settings_sidebar/1` (categories with icons, key counts, search). Hosts the LLM Quick Setup flow (see "Settings Quick Setup"). |
| `EvoDashWeb.SettingsComponents.SaveBar` / `.SectionHeader` / `.CardShell` / `.FormFooter` | `settings_components/{save_bar,section_header,card_shell,form_footer}.ex` | The four shared building blocks consumed by `SettingsComponents`/`SearchResults`/the editors: `save_bar/1` (pinned bottom-right save bar, attrs `:label` + optional `:form` = HTML form-association id), `section_header/1` (sticky section header, attrs `icon`/`title`/`description`), `card_shell/1` (editor card wrapper, attrs `title`/`description`/`class` + `:actions` slot + `:inner_block`), `form_footer/1` (Cancel ghost + primary submit, attrs `cancel_event`/`save_label`). |
| `EvoDashWeb.SettingsComponents.CustomToolsPanel` | `settings_components/custom_tools_panel.ex` | Read-only "Custom Tools" panel (`custom_tools_panel/1` — `:status` required: `%{ok: [...], errors: [...]}` or `{:error, term()}`; `:loading` default `false`) on `card_shell/1`: tool modules from `<config_dir>/tools/` with a read-only/write badge, per-file load errors, empty state, `{:error, reason}` banner, Refresh (`phx-click="reload_custom_tools"`, handler in `SettingsLive`), plus the pure `custom_tool_names/1` helper. All status reads are TOTAL (atom-or-string keys, no `try/rescue`). |
| `EvoDashWeb.AgentsComponents` | `agents_components.ex` | Agent tree visualization: recursive `agent_tree/1` with connector lines and status helpers (color/background/border/icon) for pending/running/waiting. |
| `EvoDashWeb.AgentsComponents.CommitGraphView` | `agents_components/commit_graph_view.ex` + `commit_graph/geometry.ex` | TEMPORAL left-panel view for the Agents page: `commit_graph_view/1` renders pre-assembled repo data (`:repos`/`:selected_id`/`:loading`/`:error`/`:node_key`) as a VERTICAL, per-agent-lane commit graph (one row per commit, one lane per agent in the gutter, rounded cross-lane edges, dashed `:spawn`/`:merge_back` connectors, sticky lane chips, in-panel both-axis scroll, no pan/zoom). Purely presentational; geometry/routing/lane planning live in the pure `Geometry` submodule. Emits the FROZEN DOM markers the `CommitGraph` JS hook targets. Full contract: `agents_components/CONTEXT.md`. |
| `EvoDashWeb.ReviewComponents` | `review_components.ex` | Review page — GitHub-PR-style tab layout, Adwaita-styled. Owns `page_tabs/1` (Conversation / Files changed / Commits / Archive via `switch_tab`; the Archive tab's `archive_count` badge renders ONLY when the count is > 0 — the archive total, not an agent count; 0/unknown renders nothing), `archive_review_section/1` + its `archive_tree_node/1`, and delegates the header/summary/objective/repo-cards/actions/diff/commits helpers to `review_components/` plus the public `conflict_files_summary/1`. Detail: `review_components/CONTEXT.md`. |
| `EvoDashWeb.RemoteGateComponents` | `remote_gate_components.ex` | Shared SSH-remote connection gate: `remote_connection_gate/1` (spinner + "Connecting to %{name}…" for `:connecting`/`:bootstrapping`/`:disconnecting`; `alert-error` with `last_error` + Retry / Manage Connections / Switch to Local for `:error`/`:disconnected`; nothing when connected/local) + public `gate_active?/1` (nil node → false; node + nil status → true; connecting/bootstrapping/disconnecting/error/disconnected → true; connected → false; unknown → false). ⚠️ Call it fully-qualified with the assigns map (`<%= EvoDashWeb.RemoteGateComponents.remote_connection_gate(assigns) %>`) — the declarative `<.remote_connection_gate assigns={assigns}/>` form mangles node-name resolution. |
| `EvoDashWeb.Layouts` | `layouts.ex` | Layout components: `app/1` (sidebar shell — fixed `<aside id="sidebar">` with branding, nav links, active-tasks section, bottom bar holding node selector + language/theme toggles + collapse toggle; `phx-hook="SidebarCollapse"` persisted to `localStorage`; mobile hamburger + overlay), `flash_group/1`, `theme_toggle/1`, `theme_toggle_compact/1`, `language_selector/1`. Node-aware via optional attrs (`current_node`, `current_node_id`, `current_node_name`, `remote_targets`, `connection_statuses`, defaulting to local) rendering `<.live_component module={EvoDashWeb.NodeSelectorComponent}>`; private `with_node_param/2` appends `?node=<id>` to nav links. `simple_nav` hides nav links, active-tasks, node selector and bottom bar, leaving branding only (WelcomeLive). |

### Templates
| Template | Path | Purpose |
|----------|------|---------|
| Root HTML layout | `layouts/root.html.heex` | Base HTML shell — meta tags, CSRF token, LiveView title, asset links, client-side theme persistence script (`phx:theme` localStorage). |

### Usage Pattern
All component modules use `use EvoDashWeb, :html` (`use Phoenix.Component` + HTML imports); components are invoked as function components:
```heex
<.button phx-click="save">Save</.button>
<.task_card task={@task} />
<.agent_tree agents={@agents} />
<.flash kind={:warning} flash={@flash} />
```

### Flash Component Kinds
| Kind | CSS Class | Icon | Use Case |
|------|-----------|------|----------|
| `:info` | `alert-info` | `hero-information-circle` | Success messages, informational notices |
| `:error` | `alert-error` | `hero-exclamation-circle` | Error messages, validation failures |
| `:warning` | `alert-warning` | `hero-exclamation-triangle` | Warnings, missing configuration alerts |

### Theme delivery chain (client-side theme state + server-driven global accent)
- **Theme state is 100% client-side.** `layouts/root.html.heex` embeds an inline script that resolves `localStorage["phx:theme"]` (default `"system"`) via `matchMedia("(prefers-color-scheme: dark)")` and sets `document.documentElement` `data-theme` (resolved `"light"`/`"dark"`) + `data-theme-mode`; it also swaps the favicon and the `theme-color` meta. Cross-tab sync uses the `storage` event; a system-theme change re-resolves only in system mode. Full mechanics: parent `lib/evo_dash_web/CONTEXT.md`.
- **Toggle buttons never touch the server**: `theme_toggle_compact/1` (sidebar bottom bar) and legacy `theme_toggle/1` fire `phx-click={JS.dispatch("phx:set-theme")}` with `data-phx-theme`; the inline script listens for that window event. Tailwind's `dark:` variant is bound to `@custom-variant dark (&:where([data-theme=dark], [data-theme=dark] *))`; DaisyUI loads with `themes: false`, so custom CSS uses `--color-base-*` with `color-mix`.
- **The global accent IS server-driven**: `EvoDashWeb.LiveHooks.Appearance` resolves `EvoGit.Config.resolve([:appearance, :accent_color])` node-aware through `EvoDash.AccentCache` (local → synchronous resolve on the `:handle_params` interceptor; remote → synchronous warm cache read, then a stale-guarded async fetch that writes the cache — never an RPC on the render path) and seeds `@accent_color`. `Layouts.app` declares `attr(:accent_color, :string, default: "blue")` and sets `data-accent-color={@accent_color}` on `#app-layout`, activating the ten `[data-accent-color="<name>"]` rules in `app.css` (see `assets/CONTEXT.md`) under the SAME `<html data-theme=…>` ancestor. Distinct from ProjectsLive's per-project `--project-accent`/`--project-ring-accent` inline style on `#dashboard-root` (parent `lib/evo_dash_web/CONTEXT.md`).
- **Shell chrome is token-based (Adwaita)**: `#app-layout` + sidebar `bg-base-200`, `#main-scroll`/`main#main-content` `bg-base-100`, body `bg-base-200` — no slate/white literals.

## Constraints

- Every component module **must** use `use EvoDashWeb, :html`.
- Styling is Tailwind CSS + daisyUI — no inline CSS or external stylesheets in components.
- Icons use the Heroicon set via `icon/1` (naming convention: `hero-<name>[-style]`).
- Layout templates live under `layouts/`; only the root layout exists.
- Components are pure functions — assigns in, HEEx out; no side effects or direct LiveView process calls.
- Shared cross-component utilities come from `EvoDashWeb.Helpers` (status badges, formatting, `blob_preview/2`/`list_preview/2`, `tip/1`) to avoid duplication between modules.
- **Task cancellation UX (graceful + force kill)** (`task_card_components.ex`): the inline Cancel button is GRACEFUL (`phx-click="open_cancel_modal"`, no `phx-confirm` — the modal confirms), visible `[:pending, :running]` only; the three-dot dropdown adds a `text-error` "Force kill" item (`open_force_kill_modal`, `[:running, :cancelling]`) under a `gettext("Danger zone")` menu-title divider (Delete keeps its `phx-confirm`). `:cancelling` renders as IN-PROGRESS (warning pulsing dot + `gettext("Cancelling…")` through the shared `Helpers.task_status_dot_class/1` / `task_status_tint/1`); `layouts.ex` treats `:cancelling` as running and has NO cancel surface — the Tasks page dropdown is the force-kill surface.

### `try/rescue` Policy

`try/rescue` is an anti-pattern in these component files.

- **Do NOT** wrap `String.to_existing_atom/1` in `try/rescue`: normalize untrusted DB-sourced data (e.g. agent archive maps after a Jason round-trip) with an explicit **whitelist map lookup** (`@known_agent_keys` in `normalize_agent_keys/1`) and `Map.get/3` defaulting to the original key — no dynamic atom creation, no rescue.
- Any new `try/rescue` MUST carry an inline comment explaining why it is justified.

## Blob & Collection Rendering Caps

No component in this subtree may render an unbounded task blob or collection: a task can carry a 100+ MB `result` and every component here re-executes on EVERY LiveView render (nothing memoizes).

- The two `EvoDashWeb.Helpers` functions are the SINGLE source of previews — do not write ad-hoc `String.slice` caps in a component:
  - `blob_preview/2` → `%{text:, truncated?:, total_bytes:}` — a UTF-8-safe prefix of at most `limit` BYTES (default `16_384`); TOTAL (non-binary → empty preview; non-integer/negative limit → the default).
  - `list_preview/2` → `%{items:, total:, truncated?:}` — at most `limit` leading elements; TOTAL (non-list → empty preview).
- A truncation note renders ONLY when `truncated?: true`; a complete payload renders no note and no cap-related `title`.
- Never hand a multi-MB string to `EvoDash.MarkdownRender.render/1` — preview the binary first, then render.
- The ONLY uncapped payload paths are explicit user actions: the Full Result / Full Options modal bodies (`render_result_full/1` / `render_options_full/1`, `truncate: false`), the public `result_copy_text/1` / `objective_text/1`, and the `TaskExportController` JSON export.

| Site | Cap |
|---|---|
| `archive_components.ex` `archive_tree/1` | `300` records via `ArchiveHelpers.build_tree_capped/2` (`@max_agent_records`), computed ONCE per render, + a "Showing %{shown} of %{total} agent records — export JSON for the full archive" line only when truncated. Paging is the real bound (100 per page); the tree cap is the second safety net |
| `archive_components.ex` `archive_tree_node/1` | `result` `8_192` bytes, `objective` `4_096` bytes, each with its own byte note; the `result` block renders only once the user fetched that agent's entry (`result_loaded?/1`), otherwise "Show result" / a spinner / a retry line |
| `review_components.ex` `archive_review_section/1` + its `archive_tree_node/1` | `300` records via `build_review_tree_capped/2` (`@archive_max_records`), + the SAME "Showing %{shown} of %{total} agent records — export JSON for the full archive" line as the task-card tree (here `total` = the loaded count) only when truncated; `result` `8_192` / `objective` `4_096` bytes |
| `review_components/header.ex` `agent_summary/1` / `objective_section/1` | one `16_384`-byte `blob_preview` per render, reused by BOTH the Markdown and Raw branches; copy payload capped at `1_048_576` with a hint title (`copy_button_title/2`) |
| `review_components/diff_viewer.ex` per-file diff | `2_000` rendered lines (`parse_diff_lines_bounded/1`) + ONE `col-span-full` "%{count} more lines not shown" row (`.diff-split-table` is a 4-column grid — a non-spanning row breaks the layout) |
| `review_components/diff_viewer.ex` `file_tree_sidebar/1` (and its filtered matches list) | `500` rendered entries via `list_preview/2` + "Showing %{shown} of %{total} files" |

Task-card-specific cap rows (`@in_card_blob_limit`, `@in_card_log_limit`, `@copy_payload_limit`) live in `task_card_components/CONTEXT.md`.

- `ArchiveHelpers.build_tree_capped(records, max_records \\ 100)` → `%{tree:, total:, shown:, truncated?:}` with `%{agent:, children:}` node maps; `build_review_tree_capped/2` returns the same envelope with `{agent, children}` tuple nodes. Both drop non-map entries, cap the record list BEFORE normalizing/grouping (so per-render cost follows the cap, not the archive size), prefer root records in the slice, keep the cycle-safety visited sets, and count `shown` AFTER building — a record whose `parent_id` is on an unloaded/broken page is PROMOTED to top level as its own root and counts as shown, so the rendered count never loses records.
- `ArchiveComponents.archive_count_line/1` is the ONE count/exhaustion line both archive render sites use (attrs `total` — the LABEL total, i.e. the archive's true size — `first`/`last` — 1-based retained range — `dropped` — rows evicted by the retention window — `more?` — a pager renders — `exhausted?`): `more? or dropped > 0` renders "%{total} agents — showing %{first}–%{last}" (with "(earlier entries omitted; export JSON for the full archive)" when `dropped > 0`), otherwise "%{total} agents", plus a muted "No more archive entries." line when `exhausted?` (that replaces the pager — a short/empty page means the archive is exhausted). It renders ONLY paragraphs; the parents supply layout/spacing.
- `ArchiveComponents.archive_details/1` renders ONE PAGE of the archive plus its own controls: attrs `archive_metadata` (a legacy ATTRIBUTE NAME for the loaded page entries — no `%EvoGit.TaskInfo{}` field or stored blob of that name exists anymore) + `total` (the EFFECTIVE total driving paging, nil → the loaded count) / `server_total` (the true archive size for the label, nil → the effective total) / `dropped` / `exhausted?` / `agent_results` / `loading_more?` / `more_error` / `task_id` / `export_url`; the count line is the shared `<.archive_count_line/>` with bounds from `ArchiveHelpers.retained_page_bounds/3`, "Load more" (`load_more_task_archive`) appears only while `not exhausted? and ArchiveHelpers.more_pages?(loaded, dropped, effective_total)` (NEVER `loaded < total` — that is wrong once rows are evicted), and each agent's heavy `result` is fetched on click (`load_task_archive_agent_result`, `phx-value-agent-id`) — never on render.
- The "Export JSON" link is node-aware: its href is `export_url` when the caller supplies one (a remote node's `/tasks/<task_id>/export?node=<target_id>`) and `/tasks/<task_id>/export` when it is `nil` (the local node), and it renders only while `task_id` is present.
- Only the CAPPED builders exist: every production render path goes through `build_tree_capped/2` (task card) or `build_review_tree_capped/2` (review tab).
- `parse_diff_lines/1` remains public, unbounded and behaviour-identical — the render path must go through `parse_diff_lines_bounded/1` (raw-binary newline slice first, remainder merely counted), never back through the unbounded one.
- `diff_viewer/1` still renders ONE HEADER ROW per file: file CONTENT is bounded, per-file headers are not. Context expansion (`diff_expand_bar/1`, `expand_context`, `:all`) is orthogonal — an expanded diff is capped the same way.
- New msgids shipped for the release-time extraction pass: "Showing %{shown} of %{total} bytes", "Showing the last %{shown} of %{total} log entries", "last %{shown} of %{count}", "Showing %{shown} of %{total} agent records — export JSON for the full archive" (shared by the task-card tree and the review archive section — one msgid, do not split), "%{total} agents — showing %{first}–%{last}" (shared by both archive count lines, keep one msgid), "%{total} agents — showing %{first}–%{last} (earlier entries omitted; export JSON for the full archive)", "%{total} agents", "No more archive entries.", "Load more", "Show result", "Loading result…", "Could not load this agent's result.", "Could not load more archive pages.", "Showing %{shown} of %{total} files", "%{count} more lines not shown", and the copy hint — which exists as TWO distinct msgids ("… open Full for the complete text" in the task card, "… open the Full view for the complete text" in the review header). Do not merge them.

## Design Notes

### Settings Quick Setup — credentials gated on model selection (`settings_components.ex` + `settings_live.ex`)
The LLM Quick Setup is a **select-then-save** flow — provider buttons → variant buttons → model buttons (`phx-click="select_llm_model"`, sets `selected_model_string`; highlight `btn-primary shadow-md`), and only THEN do the credential inputs render:
- **Save Model form** (`phx-submit="save_quick_setup"`, hidden `provider_id` + `variant_id` + `model_string` + `gettext("Save Model")`) renders ONLY when `@selected_model_string != nil`; its base_url input renders ONLY when `EvoGit.Config.LLMCatalog.requires_base_url?/1` is true (the `provider[:requires_base_url]` map field is DEAD). The handler defaults a missing/empty base_url to `opts = []`.
- **API Key form** (`phx-submit="save_api_key"`) renders when `show_custom_input or @selected_model_string != nil` — custom-model providers (OpenRouter/OpenAI-Compatible) keep it right after provider selection (their `save_custom_model` form IS the model-selection step); preset providers show `gettext("Select a model above to configure credentials.")` until a model is picked.
- `select_llm_provider` / `select_llm_variant` RESET `selected_model_string` to nil; `select_llm_model` is whitelist-safe via `llm_model_string_known?/2`. `select_llm_model_shortcut` is a dead-but-harmless handler (no button fires it).

### Settings two-column layout — md+ independent scroll + config-path footer (`settings_live.ex` + `sidebar.ex`)

The Settings page is a bounded-height two-column layout on md+ (`≥ 48rem`); below md it stacks and the whole page scrolls via the shell's `#main-scroll`.

- **Height chain (md+)**: `#main-content` is `flex-1 min-h-0` inside the `h-dvh` app shell, so the `flex flex-col md:h-full` settings root is bounded to viewport-minus-chrome; the warning banners are direct `shrink-0` children above the `md:flex-1 md:min-h-0` two-column row.
- **Columns scroll independently**: the sidebar container is `md:h-full flex flex-col` with a pinned search box + pinned footer and a `flex-1 overflow-y-auto min-h-0` category `<nav>`. Two rules govern the content columns:
  - NEVER `h-full` on a content-column root (percentage against a flex-sized row → content height → page inflation).
  - ⚠️ **every main-axis (column-direction) NON-scroll flex item between the bounded column and the inner scroll container MUST carry `min-h-0`** — flexbox's content-based automatic minimum size includes a nested `overflow-y-auto` body's overflow content, so without it the inner scroll never engages and both panes stay LINKED to `#main-scroll`.
- **Unified pane shape**: root column (`flex-1 flex flex-col min-w-0 min-h-0 bg-base-100`, `id="category-<cat>"`) → pinned `.section_header` → `flex-1 overflow-y-auto px-8 py-8 relative` scroll body → ONE minimal pinned bottom-right `.save_bar` (`shrink-0`) as a NON-scrolling flex sibling. In `category_section/1`'s generic `:else` branch the chain is root → `save_category` form → scroll body → bar, and BOTH mains-axis non-scroll intermediates carry `min-h-0` (root + form). The `:llm` pane follows the same shape, except its flat `settings-form-llm` form + flat cards live INSIDE the scroll body while its save bar sits OUTSIDE the form as a direct child of the root column, submitting via `form="settings-form-llm"` (HTML form association — no nested forms; the five sibling LLM forms stay valid).
- Safe shapes needing no `min-h-0` on the column: (a) the scroll container IS the column (search, `:remote_connections`, `:agents`; the SearchResults save bar's `sticky bottom-0` pins it inside that scroll form), or (b) the scroll container is a DIRECT child of the column (`:llm`).
- **Regression test**: `describe "md+ independent scroll layout contract"` in `settings_live_test.exs` pins `min-h-0` on BOTH the category root and the `save_category` form, refutes `h-full`, and requires the inner `.overflow-y-auto` body.
- **Config-path footer**: the config path lives ONLY in the sidebar footer (after `</nav>`): document icon + `gettext("Configuration file")` + truncating `<code>` + copy button with the test-pinned `id="settings-config-path-copy"` / `phx-hook="ClipboardCopy"` / `data-content={config_path}`, plus `gettext("File does not exist yet")` when missing. The sidebar declares `attr(:config_path, :string, required: true)` + `attr(:config_file_exists, :boolean, required: true)` and renders for EVERY category.
- The md+ height chain means the built CSS must contain `md:h-full` / `md:flex-1` / `md:min-h-0` / `overflow-y-auto` / `min-h-0` (gitignored build — rebuild after utility-class edits).

### Task Form — Single-Card Two-Layout Design (`task_form_components.ex`)

The launch panel is ONE card (`.input-card`) containing the objective textarea AND the bottom toolbar (`.input-controls`) as its last element, in normal flow (never `position: fixed`). The layout is **server-seeded at render + client-driven**: `layout_for/1` computes the initial `data-layout` on `.input-layout` from `@prompt` (public, unit-tested). There is NO per-keystroke server event (no `phx-change`/`phx-debounce`; `@task_prompt` changes only via `restore_state`/`task_submit`, and the `phx-update="ignore"` textarea is never clobbered by re-renders; draft persistence is client-side). The **AdaptiveInput JS hook** mirrors the thresholds, flips `data-layout` while typing, autogrows the textarea, and re-asserts the computed layout via a MutationObserver on `.input-layout` after any server re-render — zero network events.

- **Threshold**: `@short_objective_threshold 1200` — `:expanded` when the prompt exceeds 1200 graphemes OR 32 explicit lines; otherwise `:compact` (also for non-binary input). Compact auto-grows to ~16 lines; expanded fills the card (`flex: 1`, internal scroll, no max-height — the card's `overflow: hidden` bounds it).
- **Bottom toolbar — same DOM and visual order in both layouts**: `.input-controls` holds ONE row — attach-kind dropdown FIRST (bottom-LEFT), speed↔quality control next (also bottom-LEFT), then free space, then a RIGHT-ALIGNED cluster: mode select → (custom-agent select, only when `@custom_agents != []`) → model select (only when `@model_profiles != []`) → circular send button LAST. The row's auto-margin lives on the MODE select's `ml-auto` (no `order-*`, no `mx-auto`, no auto margin on the button); selects use `select-sm text-sm` with `min-w-0 truncate max-w-*`.
- **Speed ↔ quality segmented control (`#quality-level-control`)**: a 3-step DaisyUI `join` group as a DIRECT child of `.input-controls` AFTER `#objective-file-manual` and BEFORE the mode `<select>`; `task_form/1` declares `attr(:quality_level, :string, default: "balanced")`. Steps `#quality-level-fast` (`"fast"`, `hero-bolt`), `#quality-level-balanced` (`"balanced"`, `hero-scale`), `#quality-level-high_quality` (`"high_quality"`, `hero-check-badge`) are `type="button"` (never submit), each `phx-click="select_quality_level"` + `phx-value-level` with a translated `title` + `aria-pressed`; the private `quality_step_class/2` puts `btn-active btn-primary` on the selected step (so the default `"balanced"` highlights the MIDDLE step). The string threads to the `:quality_level` task opt (see `projects_live/CONTEXT.md`).
- **Attach-kind dropdown (FIRST element of `.input-controls`)**: a native `<details class="dropdown dropdown-top" phx-hook="FilePicker">` (`id="objective-file-attach"`) whose `<summary id="objective-file-button">` is the "+" trigger (`btn btn-ghost btn-sm btn-square` + `hero-plus`; `aria-label`/`title` = gettext("Attach file")). Its menu is one `ul.menu.menu-sm.dropdown-content` with exactly three `type="button"` items carrying NO `phx-click`: `text`/`objective_file`, `image`/`objective_file_image`, `audio`/`objective_file_audio` (the last two stage the file server-side). `dropdown-top` opens upward because `.input-card`'s `overflow: hidden` would clip a downward menu; the hook delegates the click over `[data-picker-kind]` and pushes `"file_pick"`. The manual fallback `#objective-file-manual` stays a DIRECT sibling right after the `<details>` (located via `closest(".input-controls")`).
- **Staged media attachments**: picks stage into the declared `attr(:staged_attachments, :list, default: [])` — string-keyed maps `%{"type" => "image"|"audio", "name" => basename, "media_type" => IANA, "data" => raw binary}` read via the private `attachment_attr/2`; both `task_form/1` call sites forward the assign. The chip row (`id="staged-attachments"`) renders ABOVE `.input-controls` in a normal re-render region: kind label (`staged_kind_label/1`) + basename + remove button (`type="button"`, `phx-click="remove_staged_attachment"`, `phx-value-index`). Chips are METADATA ONLY — the `"data"` binary is never rendered nor encoded into any attribute/event.
- **Circular send button**: `button#task-launch-button` (`type="submit"`, stable id) is `btn btn-primary btn-circle btn-sm shrink-0` with `hero-arrow-up`, no visible label, `aria-label`/`title` = `gettext("Launch")`, plus `data-mode={@mode}` (per-mode hover ring keyed on `.input-controls button[data-mode="..."]:hover`) and `data-resume`; it is the cluster's LAST element with no auto margin.
- **CSS**: `.input-layout` / `.input-card` / `.input-prompt` / `.input-controls` are load-bearing (the hook's `closest/1` + CSS selectors). Accent decorations sit on the base `.input-card` rule (both layouts); sizing/containment lives in the `[data-layout=…]` overrides. `.input-controls` is `position: relative` (anchor for the `.file-manual` manual-path popover), `flex-wrap: nowrap` with `gap`, no divider under the textarea. Values live in the `assets/css/app.css` "Adaptive Input Layout" section (sibling node).
- **Tests** (`task_form_components_test.exs`) assert the bottom-toolbar contract: attach dropdown first with its three `[data-picker-kind]` items, the quality control ids/`type`/`phx-value-level`/`btn-active`, mode/agent/model selects in DOM order with compact classes, `ml-auto` on the MODE select, `#task-launch-button` LAST with no auto margin, `disabled={@disabled}`, mode-option values/order, and the disabled welcome overlay.
- **Mobile keyboard-aware heights**: `h-dvh` on `body`/`#app-layout`/`#sidebar`, `interactive-widget=resizes-content` in the viewport meta, and the AdaptiveInput hook syncing `--app-vh` from `window.visualViewport` so the `@media (max-width: 640px)` overrides track the area above the virtual keyboard.

### Foreign Repos — writable + base_sha + edit-in-place (`project_components.ex`)

The project-settings foreign-repo editor implements the multi-repo read-write UI on top of `%EvoGit.Core.ForeignRepo{}` (`{id, root, description, writable: false, base_sha: nil}` — lives in `:evo_git`, do not re-implement).

- **Add form** (`project_settings_body/1`, `phx-submit="add_foreign_repo"`): `repo_id`/`path`/`description` + a `writable` checkbox (`name="writable"` `value="true"`, default unchecked) + an optional `base_sha` input (branch or SHA, blank = HEAD). Tooltips explain that writable repos get their own worktree + `evogit-agent-*` branch, are tracked in the task report and NEVER merged by the task. New strings are gettext-wrapped with zh_CN meaning-anchoring comments.
- **Repo-list rows**: `badge badge-warning badge-sm` "Writable" badge when `repo.writable`; `repo.base_sha` in a `<code>` when non-nil; each non-primary row gains an edit button (`phx-click="edit_foreign_repo"` + `phx-value-repo_id`) beside the remove button in the same `opacity-0 group-hover:opacity-100` wrapper.
- **Edit-in-place**: when `Map.get(assigns, :editing_foreign_repo_id) == repo.id` the row body swaps to an inline `phx-submit="save_foreign_repo"` form — read-only `repo_id` (still submitted), editable `path`/`description`, `writable`, `base_sha`, Save (`btn btn-primary btn-xs`) + Cancel (`phx-click="cancel_edit_foreign_repo"`).
- **Defensive assigns** (seeded by ProjectsLive; component tests build assign maps manually): `new_repo_base_sha` (default ""), `editing_foreign_repo_id` (default nil), `foreign_repo_edit_form` (default nil — `%{description:, writable:, base_sha:}`, may also carry `path`/`repo_id`). ⚠️ **`Map.get(nil, ...)` raises `BadMapError`** — normalize first (`Map.get(assigns, :foreign_repo_edit_form) || %{}`).
- **Event contract** (handled by ProjectsLive): `edit_foreign_repo` / `save_foreign_repo` / `cancel_edit_foreign_repo`; `add_foreign_repo` / `remove_foreign_repo` also receive `writable`/`base_sha`.
- **Do NOT add `phx-click` to `foreign-repo-path-browse-button`** (see the double-fire Known Issue).
- **File-size policy**: `project_components.ex` is deliberately EXTENDED (not split) past the nominal per-file line policy to carry this UI; a split into a `project_components/` subdirectory is the sanctioned refactor. Component tests: `project_components_test.exs` ("foreign repo writable/base_sha UI").

## Known Issues

### Command Palette (`project_omnibox`) — client-side wiring

- **Keyboard**: `phx-keydown="palette_keydown"` lives on the search input (`input#palette-search-input` in `palette_menu/1`) — Phoenix fires keydown only when the event TARGET carries the binding (it does not walk ancestors). The input carries both `phx-keydown` and `phx-change="palette_search"` (coexisting; printable keys are no-ops via `handle_palette_key/3`'s catch-all); the `:open_path` input keeps its own `phx-keydown` + `phx-key="Escape"`. Do NOT add `phx-window-keydown` — Enter would activate a project page-wide.
- **Click-outside**: `phx-click-away="close_project_palette"` is on `.project-palette-overlay`; the backdrop's `phx-click="close_project_palette"` remains as belt-and-braces.
- **Overlay backgrounds**: the legacy `--b1/--b2/--b3` DaisyUI namespace does not exist in the vendored DaisyUI 5 themes — overlay rules in `app.css` use `color-mix(...)` / `var(--color-base-*)`.
- **Backdrop is viewport-relative**: `.dashboard-topbar` has NO `backdrop-filter` (one would create a containing block trapping the fixed backdrop/overlay to the topbar strip).
- **Latent focus bug (open, benign)**: the `FocusInput` hook re-focuses on `updated()` only when the element HAS class `focus-on-update` (inverted intent) and no markup adds it; benign while morphdom preserves focus.
- **Regression guard**: `project_components_test.exs` pins the search input's `phx-keydown`, the overlay's `phx-click-away` (+ the backdrop's `phx-click`), and trigger rendering.

### Sidebar must stay `overflow-visible` — SSH node-selector dropdown clipping

The sidebar (`layouts.ex`) is a `z-50` stacking context above `#main-scroll` (`z-0`), so its overflowing dropdowns paint above the content — but it must never clip them: the `SidebarCollapse` hook adds `overflow-visible` in BOTH branches, and `<aside id="sidebar">` additionally carries `overflow-visible!` as defense-in-depth. Removing either clips the node-selector dropdown (`w-72`) at the sidebar edge (`w-60`/`w-16`). The comment above `<aside id="sidebar">` still claims the hook re-applies `overflow-hidden` on expand — stale; do not act on it.

### Sidebar bottom-bar dropdowns never auto-close (native `<details>`)

All three bottom-bar dropdowns are `<details>`-based: `theme_toggle_compact/1`, `language_selector/1` and `EvoDashWeb.NodeSelectorComponent`. Native semantics: the panel opens/closes ONLY on a `<summary>` click, and `SidebarCollapse.applyCollapsed/1` toggles classes but never removes `open`, so collapsing the sidebar leaves an open dropdown floating over content. Picking a theme also leaves it open (`phx:set-theme` only re-applies the theme); picking a language reloads the page. There is NO reusable outside-click-close infra (no generic `details`-close or click-away handler in `app.js`; the old `toggle_dropdown`/`close_parent` JS commands do not exist). The Projects-page Configure dropdown is a different, page-local server-driven idiom — not applicable here. Closing them is JS-side work owned by `apps/evo_dash/assets/`.

- **z-index contract** (do not disturb): sidebar `<aside>` `z-50`; `#main-scroll` `z-0` (stacking context, traps page modals below the sidebar); `.dropdown-content { z-index: 50 !important }` in `app.css`; mobile overlay + config warning banner `z-40`; hamburger `z-50`.
- **`simple_nav` mode** (WelcomeLive) renders branding only — the node selector lives inside the `if !@simple_nav` block.

### `Layouts.app` content background lives on the scroll container (`#main-scroll`)

The page content background is `bg-base-100` on **`#main-scroll`** — the actual scroll container (`flex-1 overflow-auto` inside the fixed `h-dvh` chain `body` / `#app-layout` `bg-base-200` → `#desktop-quit-hook` `flex-1 min-h-0`). It must stay there: a scroll container's own background paints its visible box at every scroll offset, whereas a background on the non-scrolling inner `main#main-content` only paints the first viewport and would reveal the shell's `base-200` as a bottom seam on page-scrolled pages. `main#main-content` (`flex-1 min-h-0`) keeps a redundant same-color `bg-base-100` and MUST keep `min-h-0` — main being viewport-capped is what makes Projects' expanded task-form pin-to-bottom and Home's internal chat scroll work.

### `phx-click` + JS hook on the same element — double firing

`phx-click` + a `phx-hook` on the SAME element sends BOTH the hook's handling AND the `phx-click` event to the server; don't put both on one element unless a matching `handle_event/3` clause exists.

The three directory-picker "Browse" buttons in `project_components.ex` (`project-path-browse-button`, `new-project-location-browse-button`, `foreign-repo-path-browse-button`) carry ONLY `phx-hook="DirectoryPicker"` — the hook pushes `"directory_pick"`, ProjectsLive runs `EvoDash.DirectoryPicker` and pushes the result back as `picker_result:<picker_id>`. Adding `phx-click` there has no `handle_event/3` clause → `FunctionClauseError` → LiveView crash (pinned by `project_components_test.exs`).

**Remote-node gating**: those buttons render only when `@tauri_detected and !@remote` — the picker runs on the LOCAL dashboard machine, so under a `?node=` context the manual path inputs (`project-path-input`, `new-project-path-input`, `foreign-repo-path-input` with PathAutocomplete) are the fallback. The `remote` attr threads from `project_omnibox/1` into `palette_open_path`/`palette_new_project` and from `RemoteView.top_bar/1` into `project_settings_tab/1` (via the shared `project_settings_body/1`).

## Task Cards & the Summary-Map Contract

The sidebar "Active Tasks" section in `Layouts.app` is fed by `@running_tasks` / `@pending_tasks` — lightweight summary maps from `EvoGit.TaskRegistry.list_tasks_summary/1` (`layouts.ex` declares only those two attrs; there is NO `@tasks` attr and the dashboard renders no main task list). The Tasks page renders `task_card/1` from the same summary maps and fetches the heavy payload per expanded card into a separate `detail`; Review is the only page that still loads full `%TaskInfo{}` structs.
`task_card/1` therefore never fetches anything itself — `detail` (and its `archive` envelope) is loaded by the owning LiveView, which owns the `retry_task_detail` / `load_task_archive` / `load_more_task_archive` / `load_task_archive_agent_result` events. The full contract lives in `task_card_components/CONTEXT.md`: the 16-key summary map, the `detail` envelope, field-access rules, detail/error/archive states, multi-repo `repos` rendering, Review-button candidacy, the field-usage audit and the card-scoped caps.

## Render Cost Map — per card / per pane

Every component here is a pure function component that re-executes on EVERY LiveView render (nothing memoizes), so the sites below repeat their work per render — all bounded by the caps above.

- No `Jason.decode` / base64 / regex-over-a-huge-string work lives in this directory: `result` and the loaded archive page entries arrive already decoded from the Store Codec and are only re-rendered here.
- Everything else (cost/token/cache formatting, `render_options`, `render_result`, `result_copy_text`, `cost_estimate_notice`, logs, archive) sits INSIDE `if @show_details` and is gated on `detail.state == :ok` — a collapsed card and a loading/errored detail both render in O(1) work. There is no cross-card loop inside the component (TasksLive owns `Enum.with_index(@filtered_tasks)` + `animation_delay_class/1`) — no per-card re-sort/re-group/re-parse.
- Diff pane re-parses per render: `parse_diff_lines_bounded/1` (≤2000 lines), `build_diff_segments/1`, `build_split_pairs/1`; `file_tree_sidebar/1` rebuilds + sorts the tree and `String.downcase`-filters every path; `split_diff_layout/1` sums stats twice.
- Commit graph: `commit_list/1` recomputes `Geometry.positions`/`geom`/`lane_chips` per render, each `<.edge_path>` calls `Geometry.edge_geo/3` (a scan of the full edge list — quadratic in edges, bounded by the builder's 100-commit cap), and `lane_header/1` re-filters chips per stagger row.

## Token & Cost Usage Display Sites (targets for any cost caveat/notice)

Token counts are provider-reported (usually accurate) but cost is BEST-EFFORT (peak-hour pricing, stale pricing tables). There is NO shared stat-block component — only the formatters are shared.

**A SHARED best-effort cost notice renders at ALL cost display sites**: `EvoDashWeb.Helpers.cost_estimate_notice/1` renders a small muted `<p>` explaining that token usage is usually accurate while the reported cost is a best-effort estimate (peak-hour pricing, stale pricing data). Each of the 5 sites below renders `<.cost_estimate_notice />` right after its cost rows; the text lives in ONE place.

| # | Rendered by | File | Callers |
|---|---|---|---|
| 1 | `TaskCardComponents.task_card/1` — "Token & Cost Usage" card (token rows, cache rows gated on a non-zero cache, cost rows) | `task_card_components.ex` | TasksLive only — expanded card, rendered once the per-card `detail` load lands (`Map.get(lite, :usage)`) |
| 2 | `ArchiveComponents.archive_tree_node/1` — 4 tiles: Input/Output/Total Tokens + `Cost` (`total_cost` only) | `archive_components.ex` | `archive_details/1` + `archive_tree/1` |
| 3 | `ReviewComponents.Header.task_summary/1` — "Token & Cost Usage" definition list | `review_components/header.ex` | ReviewLive; facade `defdelegate` in `review_components.ex` |
| 4 | `ReviewComponents.archive_tree_node/1` — same 4 tiles, different markup | `review_components.ex` | `archive_review_section/1` (review page Archive tab) |
| 5 | AgentsLive agent-detail usage panel (collapsible, `phx-click="toggle_usage"`) — token, cache + Context rows (no Cache Creation tile), cost rows | `live/agents_live.html.heex` | AgentsLive via `@show_usage` |

- **Labels rendered**: "Token & Cost Usage" (#1, #3), "Token and Cost" (#5), "Input Tokens", "Output Tokens", "Total Tokens", "Cached Tokens", "Cache Creation" (#1, #3 only), "Cache Hit Rate", "Input Cost", "Output Cost", "Total Cost", and plain "Cost" (#2, #4 — `total_cost` only). `Cost` totals use `text-primary-standalone` (#1 header icon `hero-currency-dollar`).
- **Only the formatters are shared** — `Helpers.format_number/1`, `format_cost/1`, `format_cache_hit_rate/1`; every stat block is re-implemented inline, so a single-place notice needs a shared sub-component or a 5-site edit.
- **No other page renders cost/token stats**: ProjectsLive, HomeLive, SettingsLive, SystemLive and `TaskExportController` (which only serializes the raw `usage` field) render none.

### Existing info-notice / tooltip conventions to mirror
- **`EvoDashWeb.Helpers.tip/1`** is the canonical inline info icon: `<.tip text={gettext("…")} position={:top} />` renders `<span class="tooltip tooltip-<position> cursor-help" data-tip={text}>` with a `hero-information-circle` icon (attrs `text` required, `icon`, `class`, `position` `:top|:bottom|:left|:right`); live call sites: `task_form_components.ex`, `project_components.ex`. A plain `title=` attribute is the lighter convention (e.g. `review_components/header.ex`, `task_card_components.ex`).
- The `LegendTooltip` JS hook (`assets/js/hooks/legend_tooltip.js`) exists only for long tips an overflow container would CLIP (agents legend chips) — not needed for a stats block.

### i18n
Every label goes through `gettext/1` on the DEFAULT domain; the only `dgettext` in the app is `core_components.ex` for domain "errors". New strings must be gettext-wrapped; per repo policy do NOT run `gettext.extract`/`merge`/`translate` — add a Chinese `%!-- zh_CN: … --%` comment when the meaning needs anchoring (the files already do, e.g. "Token → 词元").

### Tests covering these displays
- `test/evo_dash_web/helpers_test.exs` — `format_number/1` + `format_cost/1` (nothing for `format_cache_hit_rate/1`).
- `test/evo_dash_web/components/archive_tree_test.exs` — the ONLY render-level assertions on usage tiles ("1,000", "500", "1,500", "0.003000"; refutes "0.000000") for `ArchiveComponents.archive_tree/1` and `ReviewComponents.archive_review_section/1`, plus direct `build_tree_capped/2` normalization pins and the shared paging-helper unit tests (`archive_opt?/1`, `retain_window/2,3`, `retained_page_bounds/3` + `more_pages?/3`).
- `test/evo_dash_web/live/agents_live_test.exs` — clicks `button[phx-click='toggle_usage']` (asserts the compression %, not cost/token text).
- Sites #1 and #3 have NO direct assertions (`task_card_components_test.exs` covers cancel/review/error/archive; `review_components/header.ex` has no component test file).

## Notes for Agents — narrow-width (mobile) layout conventions
- **Branch-name badges** (3 sites: the per-repo badge in `result_repos_badges/1` + the two `render_result/2` top-level branch badges): truncate narrow via the shared `ResultRender.branch_badge_class/0` (`min-w-0 max-w-[10rem] sm:max-w-[14rem] md:max-w-none`) plus an inner `<span class="truncate min-w-0">` — daisyUI `.badge` is `inline-flex` with no wrapping, so the ellipsis must live on a blockified inner span, and flex parents need `min-w-0` to shrink. Reuse the helper for any NEW branch-badge site (keep the class string a literal so the Tailwind v4 scanner picks it up); the full branch name always shows at `md`+.
- **Agent tree** (`agents_components.ex` `path_tree/1`): the per-level agents-row wrapper carries **`pl-7 xl:pl-0`** — below `xl` the row stacks (`flex-col`) and the 28px indent (= folder icon `size-5` + `gap-2`) puts the first agent box and every wrapped line exactly at that level's directory-text left edge, clear of the children trunk (`absolute left-2.5`). Do NOT remove the indent or wrapped boxes overlap the trunk on mobile; `xl:pl-0` keeps the desktop two-column layout byte-identical.

## Design Conventions — Adwaita token grammar (markup)

Rules for writing NEW markup in this subtree (full repo-wide catalog: parent `lib/evo_dash_web/CONTEXT.md`):

- **Alpha floor** (base-content on light is the binding constraint): user-relevant text never below `/50`; labels/meta ≥ `/60`; small/primary content ≥ `/70`; fold `text-[10px]`/`text-[11px]` → `text-xs` where feasible; decorative large icons and "·" separators may keep `/30`–`/40`.
- **Hairlines/dividers on flat `bg-base-100` content surfaces** use `border-base-300` (never `border-base-200` — ≈1.06:1 invisible); tinted wells may keep `border-base-200/80`.
- **Corners**: cards/panels `rounded-xl` max (prefer `rounded-lg`); normal action buttons `rounded-lg`/`rounded-md`; only genuine pill/badge elements keep `rounded-full`.
- **`*-content` color tokens are tuned for solid fills** — never `text-*-content` on translucent tints; on `/10`–`/30` tints use `text-error`/`text-warning`/`text-success`, and `-content` only on solid fills.
- **No raw color literals** (`text-red-500`, `bg-white/10`, `bg-black/10`, `bg-neutral text-neutral-content`, `bg-base-50` — the last is a dead class compiling to no fill) → theme tokens (`text-error`, `bg-error/10`, `bg-base-200`, `bg-base-content/5`, …).
- **Empty/loading states**: exactly ONE dim layer (icon and copy should not both sit at floor alpha).
- **Locked contracts — never restyle helper OUTPUTS**: the `EvoDashWeb.Helpers.task_status_*` / `agent_status_*` / `connection_status_*` class helpers, the task-form bottom-toolbar DOM order (attach-kind dropdown | quality | mode | agent | model | send) + `data-layout`, the `phx-hook`/`phx-click` bindings, and the chart CSS-var strings. Markup class LITERALS may be polished; helper outputs are the single source of truth.
