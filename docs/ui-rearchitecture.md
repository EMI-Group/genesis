# Dashboard UI Re-architecture — Tasks are the core, Assistant and manual submit are entry points

## Intent

The workbench gives each area a distinct job: the sidebar provides shortcuts, the tab rail tracks open views, the canvas holds the current work, and the right dock supplies project context. The same task can appear in several places without becoming a separate task or tab.

## Product model

```
Select Project / Workspace
    ├─ Chat with Assistant → confirm submit ─┐
    └─ Manual new task → configure → submit ─┤
                                             ↓
                                        ONE Task
                     monitor (agents) → manage (tasks) → decide (review)
```

- **Assistant is an interaction entry point, not a parallel task system.** A conversation is a long-lived interactive session; when it prepares background work it shows a confirm card that references the SAME task id.
- **The Task is the execution and audit subject.** It survives closing the conversation, switching project, or closing a tab.
- **Review is where a delivered result is decided** (merge / reject per repo), and it is the destination for terminal workbench tasks, not for Assistant conversations.
- **Workspace is grouping only.** A workspace is a set of projects with no OS path; it never executes. Execution resolves to a changeable member, and the UI says which one.

## Project entry points

The project overview shows the scope (name, path, VCT point, node and HEAD, plus the execution member for a workspace) and offers **Chat with Assistant** and **New task**. Opening, creating or selecting a project uses the ordinary overview route. A confirmed project or a workspace with a resolved member advertises its exact scoped Assistant draft URL via `data-workbench-default-draft`. The browser opens that **unsent** draft only if the rail is empty after restore; opening it does not send a message, start a session or launch a task. Explicit destinations (including compose, resume, starting-commit deep links and history links), browser Back/Forward and a deliberate last-tab close (`wb_home=1`) take precedence over the default. A repo opened by path but not yet registered can still use **New task**; the project picker must register it before scoped chat is offered.

- **Assistant** keeps chat simple: a message field and its own attachment, model and Send/Stop controls. Confirming background work is distinct from sending a message.
- **New task** is an explicit compose step (`wb_task=1`); compose/resume links and restored manual drafts still land there. **Task Options** is a labelled inline section below the editor, with flat toggle rows and aligned fields rather than separate option cards. **Advanced options** is a disclosure where applicable. The separate **Project Settings** form is an inline disclosure, collapsed by default; application-level **Settings** opens in the workbench settings window.
- **The editor and toolbar are shared, not the page state.** `ComposerComponents.composer/1` marks the variant and `composer_surface/1` supplies the resting surface, editor and toolbar slots. Each page owns its form events, attachments, launch controls, scope and draft state. The Assistant keeps its own transcript scrolling; New Task keeps its adaptive editor and a distinct canvas tone beneath the composer.
- **Composer actions are flat at rest.** Mode and model capsule triggers have no resting border; hover, open and keyboard-focus states remain visible, and the capsule still owns its popover. Project-scoped drafts use `{node, token}` (the VCT point, or the absolute path for an unmounted project); the token identifies a draft, not the repo path used for execution.

## Area responsibilities (one primary job each)

| Area | Its ONE job | What it must not do |
|---|---|---|
| Left sidebar | switch scope + reach the main destinations | enumerate open views or duplicate a task/conversation list |
| Top tab rail | return to a concrete thing you had open | become the task list or stop a task/session when a view closes |
| Center column | finish the current work (overview, task form, conversation, run, review) | hide the scope the user is acting in |
| Right dock | auxiliary info for the current scope (project history, Git) | become a second global Tasks page |
| `/tasks` | cross-project lifecycle + review triage | be the destination for a delivered result |
| `/agents` | inspect the agent tree, live activity and commit history for a task or the whole node | answer "which tool call is running" |
| `/processes` | "which tool call / background command is running" | double as the agent tree |
| `/review/<id>` | decide a delivered result | host run control |

## Destination rules (the load-bearing ones)

| Entry | Destination |
|---|---|
| Sidebar **Active Tasks**: `:pending`, `:running`, `:finalizing`, `:cancelling`, `:pausing` | `/agents?task=<id>` scopes the agent tree and commit history to the task. **All agents** returns to the node-wide inspector. |
| Sidebar **Active Tasks**: `:paused` | `/tasks?task=<id>` focuses the task card for Resume. |
| **History**: non-terminal task, including paused | `/tasks?task=<id>` focuses the task card. |
| Terminal task (`:completed`, `:failed`, `:cancelled`) in **History** or a task card; eligible completions in sidebar **Needs review** | `/review/<id>` for reviewable tasks. A failure or cancellation shows the real outcome, reason and any salvaged changes. |
| Assistant conversation, live or ended | `/assistant?session=<id>` from **Conversations** or History. Interactive sessions do not appear in either sidebar task section. |

- The "Needs review" triage bucket is narrower than the Review route: `:completed` + nil `review_status` + a live branch. A failed or cancelled task gets a review route, not a triage slot.
- A task whose primary repo has no changes still shows its report; a changed writable foreign repo keeps its own Merge/Reject. "No changes in this repository" never generalises to "no changes in the task".
- "Prepare follow-up task" creates a NEW task seeded from an old result; "Resume" restores the SAME paused task. Never label one as the other.
- Destinations preserve the viewed node (`node`) and carry project scope where it applies (`project`, or `wb_project` for a scoped Assistant draft).

## Surface and elevation model

Three layers, expressed as tokens in `apps/evo_dash/assets/css/surfaces.css`:

| Layer | Surfaces | Treatment |
|---|---|---|
| 0 chrome/shell | desktop title bar, sidebar, tab strip background, right dock | recessed and unshadowed: Project History shares the sidebar's theme-aware fill without a divider; Source Control keeps its own tint and leading hairline |
| 1 content canvas | page canvas, active tab, lists | inset, rounded canvas with density-derived gutters, subtle tone and a hairline; no elevation shadow |
| 2 overlay | menus, command palette, modals, popovers | the only floating, shadowed layer (`--elev-1/2/3`) |

Rules that keep it coherent:

- **The desktop title bar is desktop-only layer-0 chrome.** `#desktop-titlebar` is the full-width strip above `header.workbench-top`, rendered only in desktop mode (`--shell-titlebar-h` is `0px` in a browser, so browser rendering is unchanged).
It names the app with the shared brand; the rail's leading label still names the page, and the in-shell pages still carry no `h1`.
Dragging is not a markup attribute: the strip's JS hook owns it with one `pointerdown` → `startDragging()` (excluding interactive descendants) and one `dblclick` → `toggleMaximize()`.
Window controls (minimize / maximize / close) exist only in the strip, and only on Windows and Linux — macOS leaves that space to the native traffic lights.
The strip is the window chrome only because the dashboard explicitly asks the shell for frameless chrome (`set_custom_titlebar {active: true}` once the strip exists and its controls are bound); every navigation start and page teardown restores native chrome, so a stale asset bundle that never mounts a working strip leaves a fully usable native title bar rather than an unclosable window.
- The sidebar and right dock frame the canvas rather than competing with it. The sidebar uses spacing and hover/selected fills instead of repeated dividers. The canvas frame serves both the page and the Git-diff portal without adding another scroll container.
- Lists use flat rows. History uses spacing instead of rules; task cards on `/tasks` default to a flat row with a hairline. A card (`data-variant="raised"`) is an opt-in for content read or decided as one unit (a review repo block, a submit confirm), not a treatment for the canvas or docks.
- Hover, selected and focus are three different treatments; reserve accent for primary actions, the current object and the separate pending-navigation cue.
- `assets/css/density.css` owns the type and size tokens; `surfaces.css` owns the surface tones, hairline, radius and elevation tokens. Read `docs/ui-density.md` and `assets/css/CONTEXT.md` before changing the styling.
- **Motion stays local.** Page, tab, project and node navigation do not scale or cross-fade the document; there is no View Transition wrapper around route changes. Pending navigation uses a static cue. The right dock, settings window, disclosures and other local controls use the shared motion tokens and respect reduced-motion preferences.

## Right dock

Project History uses the same theme-aware fill as the left sidebar, with no divider. Source Control retains its distinct tint and leading divider. Both start closed in a fresh tab; the workbench hook owns their open/close state, resize handle and narrow-screen overlay. The active panel's content scrolls, not the dock itself.

Across LiveView route swaps, the workbench keeps the saved desktop sidebar width and restores the open History dock with its desktop geometry. History results and scroll position remain scoped to the destination rather than carrying over from the previous route. Narrow-screen drawers are transient and do not reopen on navigation.

- **History** lists prior work. The **Project** and **Status** filters come before the search field, followed by a **Tasks / Conversations** segmented pill switch. The current project is selected by default; **All projects** widens the search on the viewed node. Task search is server-side and paged. The controls stay in place while the results scroll. Neutral rows use spacing rather than dividers, with a truncated title above a quiet status-and-date line; only conversations have a kind icon.
- **Source Control** shows repository state. Its summary header and **Changes / Branches / Commits** switcher keep their intrinsic height; only the selected view scrolls in the remaining bounded space. Branch search stays at the top of its view. Working-tree and commit diffs open in the central canvas, not in the dock.

## Tab rail semantics

The Chrome-like tab rail is the only open-view list. A compact title for the current route, project or workspace comes before the tab strip. Compact tabs sit along the bottom of the top bar beside the Create, History and Git controls. The confirmed active tab shares the canvas fill and curves outward at its lower corners to join the inset canvas, covering the top hairline where they meet. The strip scrolls horizontally without squeezing the fixed controls; close affordances reserve their space.

- A task has one canonical tab key `{node, task_id}` across `/agents?task=<id>`, `/tasks?task=<id>`, `/review/<id>` and `/review/<id>/commit/<sha>`. The tab keeps the exact destination separately, including the commit or query parameters. Bare `/agents` is a node-wide destination, not a task tab. Project, draft, conversation and working-tree diff views keep their own identities.
- ONE reused **preview** tab per project, replaced in place by the next preview; middle-click PINS it without navigating. `draft`, `project`, `assistant` and `diff` tabs are always pinned, so a preview can never overwrite unsaved input.
- The rail, overflow, close neighbour and keyboard cycling use the same stable group order: **project → task → chat → diff → other**. Closing a tab never stops a task or session; closing an unsent Assistant draft also discards its temporary tab state. Focus falls back to the neighbouring tab; the deliberate last close returns to the workbench home without reopening the default draft.
- The rail-end `#workbench-tabs-overflow` menu appears only while the strip really scrolls. `Alt+Left`/`Alt+Right` cycle tabs only from within the rail or its overflow menu, not from editable fields.
- Navigation intent shows immediately as pending styling and `aria-busy`. The destination becomes current (`aria-current="page"`) only after the exact route is confirmed, even when it has the same canonical tab key.
- The client restores tab state from `sessionStorage` via the DOM-free store in `assets/js/hooks/workbench_tabs.js`; the server renders an empty rail shell. This restores tab metadata, not cached pages: cross-page navigation still uses LiveView and can remount and load data. Immediate feedback does not mean the next page is ready.

## Task management and review

- The sidebar keeps Active Tasks separate from the compact Needs review nudge (up to five rows and a **View all** link to `/tasks?status=needs_review`).
- `/tasks` carries the full lifecycle filter set (incl. `finalizing` and `needs_review`), URL-addressed filters that survive a node switch, honest counts and empty states, and unified pause/resume/cancel/force-kill entry.
- Review renders an outcome banner and per-repo truth for completed/failed/cancelled/no-report/unrecoverable-branch, with "Prepare follow-up task" disambiguated from "Resume".

## Deferred deliberately

- Split view (the first candidate would be Assistant + a run/review pair) — prove single-view round-trips and state retention first.
- Restoring tabs across a desktop restart (the backend port can change; browser storage is not a reliable cross-restart identity).
- Workspace-aggregated history (needs one merged ordering/pagination across member repos, not concatenated pages).
- Measured navigation budgets: record click → visible feedback, click → interactive, click → data-ready p50/p95 locally and over SSH before optimising remounts, serial RPCs or hidden-panel prefetch.
- Rendered-screenshot verification in light/dark and narrow widths; current guarantees are source contracts plus token reasoning.

## Known boundaries

- The needs-review store predicate requires a live branch, so a completed task that produced no branch does not enter triage (it is still reviewable from Tasks/history).
