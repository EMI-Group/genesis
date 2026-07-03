# UI Components

## Intent
Contains all reusable UI component modules and layout templates for the EvoDash web interface. This is the presentation layer — Phoenix function components rendered via HEEx templates, organized by domain concern.

## Routing Table
- `layouts/` → HTML layout templates (root layout shell with meta tags, CSRF, theme persistence)

## API Surface

### Modules
| Module | File | Purpose |
|--------|------|---------|
| `EvoDashWeb.CoreComponents` | `core_components.ex` | Phoenix 1.8 scaffolded building blocks: `header/1`, `flash/1`, `flash_group/1`, `simple_form/1`, `button/1`, `icon/1`, `input/1`, `table/1`, `theme_toggle/1`, plus JS commands (`show_notification`, `toggle_dropdown`, `focus`, `close_parent`). The `flash/1` component supports three flash kinds: `:info`, `:error`, and `:warning` — each with appropriate styling (`alert-info`, `alert-error`, `alert-warning`) and corresponding Heroicon. |
| `EvoDashWeb.DashboardComponents` | `dashboard_components.ex` | Domain-specific LiveView components: `genesis_form/1`, `evolve_form/1`, `task_card/1`, `project_selector/1`, `project_tabs/1`, `directory_picker_button/1`, `config_status_badge/1` plus helpers for status badges, type icons, descriptions, and datetime formatting |
| `EvoDashWeb.SettingsComponents` | `settings_components.ex` | Settings page components with VS Code-inspired sidebar+content layout: `setting_card/1` (schema-driven config key card with input widget, description, default hint, validation error display), `category_section/1` (right content area for a category with grouped settings and save button), `settings_sidebar/1` (category sidebar with icons, key counts, and search filter) |
| `EvoDashWeb.AgentsComponents` | `agents_components.ex` | Agent tree visualization: recursive `agent_tree/1` with connector lines and status indicator helpers (color/background/border/icon) for pending/running/waiting states |
| `EvoDashWeb.ReviewComponents` | `review_components.ex` | Review page components: `review_header/1` (PR title, status badge), `agent_summary/1`, `diff_stats_bar/1`, `action_buttons/1` (Merge, Reject, Continue, Create PR, Extract Skills, Ignore — Ignore is always available as the escape hatch for orphaned/deleted branches), `extract_skills_modal/1`, `commits_list/1` (clickable — navigates to commit inspection), `commit_detail_header/1`, `file_tree_sidebar/1`, `diff_viewer/1` (shared diff renderer with expandable context via `diff_expand_bar/1`), `split_diff_layout/1` (file sidebar + diff viewer for review), `commit_diff_layout/1` (file sidebar + diff viewer for single-commit inspection) |
| `EvoDashWeb.Layouts` | `layouts.ex` | Layout functions — `app/1` (shared app layout with sticky nav bar and flash group), `flash_group/1` (renders `:info`, `:error`, and `:warning` flashes), `theme_toggle/1` |

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
- **The ONLY justified `try/rescue`** in this subtree is `highlight_line_content/2` in `review_components.ex`, which wraps `Lumis.highlight!/2` for per-line syntax highlighting. It is justified because: (1) the non-bang `Lumis.highlight/2` also raises internally (does not return `{:error, _}`), so `case`/`with` cannot replace it; (2) per-line async (one Task per diff line) is impractical; (3) falling back to raw un-highlighted content is the correct graceful degradation. This rescue **must** carry the inline justification comment — do not remove it.
- If any new `try/rescue` is introduced, it MUST include a clear inline comment explaining why it is justified.
