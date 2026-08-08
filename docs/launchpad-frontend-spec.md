# Launchpad — Frontend Spec (v3, final)

The merged simple-first frontend for v0.9.1. This document is the
as-built spec of the SHIPPED design (v3 wireframe, implemented as
`HomeLive` + `ReviewsLive`). The earlier three-variant exploration
(Flow / Console / Workspaces, v1–v2 of this document) was **rejected by
the user** and is archived OUTSIDE the repo at
`evox/tmp/rejected-variants/` (preserving the original
`apps/evo_dash/...` relative paths: `flow_live.ex`, `console_live.ex`,
`workspaces_live.ex`, `live/launchpad/`, `launchpad_components.ex`,
`launchpad.css`, `console.css`, `workspaces.css`, and their tests). Do
not resurrect them; this file is the only current contract.

## The pad shell is the single global chrome (v3.1)

The original sidebar interface (`Layouts.app` + `DashboardLive`) is
**retired**. EVERY page now renders the same minimal pad top bar
(`PadComponents.pad_top_bar/1`) with page switching fixed in the
**top-right corner**: `Tree` (`/agents`) · `Review N` (`/reviews`,
count badge) · `Settings` (`/settings`) · `System` (`/system`) · theme
toggle. The current page's link renders L1 semibold; all other links
are L3. `current` is one of `:home | :tree | :reviews | :settings |
:system | :tasks | :review | :none`.

Page structure is uniform: `<div class="h-screen flex flex-col">` root
→ `pad_top_bar` → `<main class="flex-1 overflow-y-auto">` wrapping the
page's existing content in a centered column
(`mx-auto max-w-6xl px-4 sm:px-6`) → `Layouts.flash_group`.

Retired/archived (moved OUT of the repo to
`evox/tmp/original-interface/`, preserving `apps/evo_dash/...`
relative paths):

- Routes `/classic` (`DashboardLive :index`) and `/dashboard`
  (`DashboardLive :system_dashboard`) — deleted from the router. The
  Phoenix LiveDashboard stays at `/phoenix/dashboard` (the System page
  card now links there directly with a plain `<a href>` — it runs in
  its own live_session, so `navigate` would raise).
- `live/dashboard_live.ex`, `live/dashboard_live/assigns.ex`,
  `live/dashboard_live/project_flow.ex`,
  `live/dashboard_live/state_persistence.ex`,
  `test/evo_dash_web/live/dashboard_live_test.exs`.
- `Layouts.app` (the sidebar shell) and its private helpers were
  deleted from `components/layouts.ex` (only `flash_group/1`,
  `theme_toggle/1`, `language_selector/1` remain).
- `live/dashboard_live/project.ex` **stays** — `HomeLive` still uses
  `Project.detect_mode/path_suggestions/load_model_profiles/
  load_foreign_repos`.

The top bar's `Review N` badge is fed by `@review_count`, which
`LiveHooks.NodeAware.load_running_and_pending_tasks/1` computes for
EVERY LiveView (count of `completed` + non-empty branch + nil
`review_status` summary maps — the same set ReviewsLive shows as
"Waiting for you") and refreshes on every debounced task reload.

Lost with the sidebar (accepted): the NodeSelector (SSH remote
switch), the language selector, and the "Active Tasks" widget are no
longer in the chrome; the floating config-warning banner is gone from
non-Settings pages (Settings shows the warning inline).

## Hard constraints

- FRONTEND ONLY: never touch `apps/evo_git/`. All backend integration via
  the existing public API listed below.
- Never touch `priv/gettext/**` (no translation file updates). All UI copy
  is written in English inline (English is the source language). Fixed
  labels: mode tabs `New` / `Modify`, the collapsible block `Advanced`,
  the launch button `Start ↵`.
- Styling: Tailwind CSS 4 + daisyUI (existing `dark`/`light` custom themes
  in `assets/css/app.css`). Pad-specific CSS lives in
  `assets/css/pad.css`, imported once from `app.css`.
- Repo constraint: no `try/rescue` around `EvoGit.Config.*` /
  `AgentScheduler.*` calls — let crashes be visible. Never use
  `String.to_atom/1` on client input; use whitelist `Map` lookups.
- Follow `mix format`; keep existing tests green; add tests for new code.
- Update the `CONTEXT.md` of every directory you add files to (repo
  convention), in the established style (Intent / Routing Table / API
  Surface / Constraints).

## Backend integration contract (verified on v0.9.1)

- Start task: `EvoGit.TaskRegistry.start_task(task_type, opts)` →
  `{:ok, %EvoGit.TaskInfo{}} | {:error, reason}`.
  - `task_type`: `:genesis | :evolve` (whitelist map from UI mode strings).
  - opts keys: `:path` (required, absolute project dir), `:mode`
    (`"new" | "existing"` for genesis, `"simple"` for evolve),
    `:prompt` (genesis) / `:objective` (evolve), `:model_id` (profile id
    string), `:build_system` (atom, genesis only), `:node_path` (evolve),
    `:starting_commit` (evolve), `:resume_from` (evolve, prior task id),
    `:archive` (bool).
- Parallelism is native: no per-project mutex; concurrency is governed by
  per-model-profile LLM slot pools + tool slots. The UI may fire many
  tasks across many projects back-to-back.
- Recent projects: `TaskRegistry.list_recent_projects/0` →
  `[%EvoGit.RecentProject{path, name, last_opened_at}]` (max 10);
  `TaskRegistry.add_recent_project(path, name)`.
- Task queries: `TaskRegistry.list_tasks_summary(statuses \\ [], since \\ nil)`
  (light maps: id, status, review_status, result, started_at, finished_at,
  type, project_path, opts, branch_name, model_id, agent_count, base_sha,
  commit_sha, updated_at). Do NOT use `list_tasks/0` full loads.
  `TaskRegistry.cancel_task(id)`, `TaskRegistry.get_task(id)`.
- Model profiles: `DashboardLive.Project.load_model_profiles/0` → list of
  profile maps (`id`, `model`, `concurrency`, generation params). Active
  default = first profile. Per-task override via `:model_id`.
- Mode detection: `DashboardLive.Project.detect_mode(path)` →
  `:genesis_new | :genesis_existing | :evolve_simple`.
  `Project.path_suggestions(input, recent_projects \\ [])` for path
  autocomplete.
- Build systems: `EvoGit.Runtime.WorktreeInitScript.build_systems()`.
- PubSub (`EvoGit.PubSub`): topics `"tasks"` (`{:tasks_updated}`,
  `{:task_status, id, status}`) and `"recent_projects"`
  (`{:recent_projects_updated}`). Subscribe when `connected?(socket)`;
  reload summaries with a ~300ms trailing debounce (pattern:
  `EvoDashWeb.LiveHooks.NodeAware`).
- Review: completed tasks with a non-empty `branch_name` and nil
  `review_status` are awaiting review, linked at `/review/:task_id`
  (existing ReviewLive, unchanged). Decided = `review_status` in
  `merged | rejected | continued | ignored`.
- Scheduler status for a subtle pause indicator:
  `EvoGit.AgentScheduler.paused?/0`; topic `"scheduler_config"`.

## Information architecture

| Route | LiveView | Purpose |
|---|---|---|
| `/` | `HomeLive` | The launchpad home (this spec). |
| `/reviews` | `ReviewsLive` | Review inbox: awaiting + recently decided. |
| `/tasks` `/agents` `/settings` `/system` `/review/*` `/welcome` | existing | Pro depth, re-shelled with the pad top bar (v3.1). |
| `/phoenix/dashboard` | Phoenix.LiveDashboard | System metrics (linked from the System page card). |

## The v3 model — two-pole attention

The page is built around an explicit attention audit with two levels:

- **L1 (full attention)**: the prompt input, the `Start ↵` button, the
  currently-active `New`/`Modify` tab, and the running-status pulse.
  Rendered in solid `base-content`.
- **L3 (ambient awareness)**: the address row and the Advanced block
  (visible but quiet — default expanded, never hidden), the rail squares,
  and the top-bar navigation. Rendered at ~38% `base-content` via
  `color-mix`, hairline `base-300` borders.

Review information is NOT on the home page — Review is its own page
(`/reviews`), surfaced only as a count in the top bar (`Review N`,
shown only when N > 0). Input → launch → the requirement "flies" into
the right-edge rail: that is the entire home-page loop.

## Home page (`/`, `HomeLive`)

Structure (top to bottom, left to right):

- **Top bar** (`PadComponents.pad_top_bar/1` — since v3.1 the global
  chrome on EVERY page): brand `Genesis` (home link), fixed right-side
  nav `Projects` (`/tasks`), `Tree` (`/agents`), `Review N` (`/reviews`,
  only when N > 0; on `/reviews` the tab renders L1 semibold as the
  current page), `Settings`, `System`, plus the theme toggle.
- **Prompt textarea** (`AdaptiveInput` autogrow): grows with content
  with NO internal scrollbar (`overflow-y: hidden`, no max-height) —
  the page scrolls, the box never does.
- **Mode tabs**: `New` / `Modify` (`pad-tab` / `pad-tab-on`). `New`
  covers both genesis modes; `Modify` is evolve-simple.
- **Address row**: project chip (recent projects, one tap) + path input
  (`PathAutocomplete`, mono) + for `New` a radio pair: create directory
  (missing dirs are `File.mkdir_p`'d on submit) vs existing directory.
  `Modify` requires an existing directory.
- **Advanced block** (`Advanced`, default expanded — it is L3 but never
  hidden): `model` (profile `id ×concurrency`), `build_system`
  (whitelist-resolved via `Enum.find` over `build_systems()`),
  `node_path`, `starting_commit`, `resume_from`, `archive`.
- **Start button**: solid accent, label `Start ↵`.
- **Rail** (right edge, `pad-rail`): one 44px square (`pad-sq`) per
  active or recently-finished task (active statuses + completed in the
  last 24h, `finished_at || started_at` desc, cap 20). Square = project
  abbreviation (ASCII: first 2 letters lowercased; non-ASCII: first
  grapheme) + status dot (`pad-sq-run` running pulse / `pad-sq-review`
  awaiting review / `pad-sq-failed`). Click target: awaiting-review →
  `/review/:id`, running → `/agents`, others inert. New arrivals get a
  pop animation. Tooltips carry prompt/path/time via `data-tip-*`
  attributes and are rendered by JS (see PadFly) because the rail is a
  scroll container and would clip in-flow tooltips.

Behavior:

- **Submit** (`PadFly` hook owns Enter-to-submit: Enter submits,
  Shift+Enter newline, `isComposing` guard for IME): whitelist dispatch
  — `New`+create → `:genesis "new"`, `New`+existing →
  `:genesis "existing"`, `Modify` → `:evolve "simple"`. On success:
  `push_event("pad:clear_prompt")` clears ONLY the prompt (params
  persist), `add_recent_project`, rail reload. On failure: inline
  `@submit_error`, nothing is cleared.
- **Optimistic flight**: on submit the PadFly hook clones the prompt
  into a text blob that flies (cubic-bezier, 550ms) to the next free
  slot atop the rail and shrinks away — the requirement visibly "lands"
  before the server confirms. Skipped for empty prompts and
  `prefers-reduced-motion`.
- **Deep links**: `?project=<path>` pre-fills the address;
  `?resume_from=<id>&starting_commit=<sha>` forces `Modify` mode.
- **Live updates**: `"tasks"` + `"recent_projects"` PubSub, routed
  through the NodeAware 300ms trailing debounce
  (`:node_aware_reload_tasks` → `load_rail` + `NodeAware.reload_tasks`).

## Reviews page (`/reviews`, `ReviewsLive`)

Two sections, same top bar (Review tab current):

- **Waiting**: awaiting-review tasks (completed + non-empty branch +
  nil `review_status`), `finished_at` desc. Each row = prompt, FULL
  path (mono), branch, time; the whole row links to `/review/:id`.
- **Decided**: last 20 decided tasks (merged/rejected/continued/
  ignored), status text in L3, inert divs.

Same debounced reload wiring as the home page.

## Aesthetics (less is more)

- Monochrome-first: neutral surface/text tokens from the existing themes,
  ONE accent (theme `primary`) reserved for the launch action + running
  status.
- Paths and SHAs in `font-mono` text-xs.
- Generous whitespace, `rounded-md`/`rounded-lg`, hairline borders
  (`border-base-300`), no gradients, no decorative blur, no emoji.
- Motion: the 550ms PadFly flight, a subtle pulse on running squares,
  a pop on new squares. All gated behind `prefers-reduced-motion`.
- Reference class: Linear / Vercel Geist / Raycast restraint.

## File plan (as built)

- `lib/evo_dash_web/live/home_live.ex` (~640 lines), `reviews_live.ex`
  (~200 lines)
- `lib/evo_dash_web/components/pad_components.ex` — `pad_top_bar/1`,
  `rail_square/1`, pure helpers (`task_prompt/1`, `task_branch/1`,
  `awaiting_review?/1`, `decided_review?/1`, `rail_status/1`,
  `square_link/1`, `project_abbr/1`)
- `assets/css/pad.css` (+ one `@import "./pad.css";` in `app.css`)
- `assets/js/hooks/pad_fly.js` — `PadFly` hook (Enter submit, flight
  animation, `pad:clear_prompt` handler, rail tooltip delegation),
  registered in `app.js`
- Router: `/` → `HomeLive`, `/reviews` → `ReviewsLive` (the rejected
  variants' `/console` and `/workspaces` routes are deleted; v3.1 also
  deleted `/classic` and `/dashboard`)
- Tests: `test/evo_dash_web/live/home_live_test.exs` (15 cases),
  `reviews_live_test.exs` (10 cases) — mount, tab/address switching,
  submit success/error per mode, deep links, rail render + links,
  reviews waiting/decided sections
- CONTEXT.md updates: `lib/evo_dash_web/CONTEXT.md` (routes),
  `lib/evo_dash_web/live/CONTEXT.md`,
  `lib/evo_dash_web/components/CONTEXT.md`,
  `apps/evo_dash/assets/CONTEXT.md`, `assets/js/hooks/CONTEXT.md`
