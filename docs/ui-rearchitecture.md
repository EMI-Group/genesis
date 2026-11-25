# Dashboard UI Re-architecture — Tasks are the core, Assistant and manual submit are entry points

## Intent

This record fixes the dashboard's product model, its area responsibilities, its surface/elevation rules and its tab semantics so that later UI work extends ONE system instead of adding another overlapping surface.

The problem it answers: the same task could appear in the left sidebar, the top tab rail, the right history panel and the Assistant at once, each with a different meaning on click; selecting a project landed in a giant form; a finished task's history row opened the task LIST instead of its result; and every surface invented its own border, fill and shadow, so the app read as several products stitched together.

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
- **Review is where a delivered result is decided** (merge / reject per repo), and it is the honest destination for EVERY terminal outcome.
- **Workspace is grouping only.** A workspace is a set of projects with no OS path; it never executes. Execution resolves to a changeable member, and the UI says which one.

## Project entry points

The project overview shows the scope (name, path, VCT point, node and HEAD, plus the execution member for a workspace) and offers **Chat with Assistant** and **New task**. Opening, creating or selecting a project uses the ordinary overview route. A confirmed project or a workspace with a resolved member advertises its exact scoped Assistant draft URL via `data-workbench-default-draft`. The browser opens that **unsent** draft only if the rail is empty after restore; opening it does not send a message, start a session or launch a task. Explicit destinations (including compose, resume, starting-commit deep links and history links), browser Back/Forward and a deliberate last-tab close (`wb_home=1`) take precedence over the default. A repo opened by path but not yet registered can still use **New task**; the project picker must register it before scoped chat is offered.

- **Assistant** keeps chat simple: a message field and its own attachment, model and Send/Stop controls. Confirming background work is distinct from sending a message.
- **New task** is an explicit compose step (`wb_task=1`); compose/resume links and restored manual drafts still land there. **Task Options** is visible inline above the composer, before submission. The separate **Project Settings** form is an inline disclosure, collapsed by default; application-level **Settings** still opens in the workbench settings window.
- **Only the layout is shared.** `ComposerComponents.composer/1` wraps the textarea and toolbar in both flows; each flow still owns its form events, launch controls and state. Project-scoped drafts use `{node, token}` (VCT point, or the absolute path for an unmounted project); the token identifies the draft, not the repo path used for execution.

## Area responsibilities (one primary job each)

| Area | Its ONE job | What it must not do |
|---|---|---|
| Left sidebar | switch scope + reach the main destinations | enumerate open views or duplicate a task/conversation list |
| Top tab rail | return to a concrete thing you had open | become the task list or stop a task/session when a view closes |
| Center column | finish the current work (overview, task form, conversation, run, review) | hide the scope the user is acting in |
| Right dock | auxiliary info for the current scope (project history, Git) | become a second global Tasks page |
| `/tasks` | cross-project lifecycle + review triage | be the destination for a delivered result |
| `/agents` | "what is this task's agent tree doing right now" | answer "which tool call is running" |
| `/processes` | "which tool call / background command is running" | double as the agent tree |
| `/review/<id>` | decide a delivered result | host run control |

## Destination rules (the load-bearing ones)

- A FINISHED task (`:completed`, `:failed`, `:cancelled`) opens `/review/<id>` from history, tasks and cards. `:failed` and `:cancelled` are reviewable — the page renders their real status, reason and salvage branch, never a blank review and never the "no changes" wording.
- A LIVE task (`:pending`, `:running`, `:finalizing`, `:cancelling`, `:awaiting_input`, `:pausing`, `:paused`) stays on the monitoring surface (`/tasks?task=<id>` focus, `/agents`).
- The "Needs review" TRIAGE bucket is narrower than the review ROUTE: `:completed` + nil `review_status` + a live branch. A failed task gets a route, not a triage slot.
- A task whose primary repo has no changes still shows its report; a changed writable foreign repo keeps its own Merge/Reject. "No changes in this repository" never generalises to "no changes in the task".
- "Prepare follow-up task" creates a NEW task seeded from an old result; "Resume" restores the SAME paused task. Never label one as the other.
- Destinations preserve the viewed node (`node`) and carry project scope where it applies (`project`, or `wb_project` for a scoped Assistant draft).

## Surface and elevation model

Three layers, expressed as tokens in `apps/evo_dash/assets/css/surfaces.css`:

| Layer | Surfaces | Treatment |
|---|---|---|
| 0 chrome/shell | sidebar, tab strip background, right dock | recessed: muted rail fill, restrained hairlines, no shadow |
| 1 content canvas | page canvas, active tab, lists | inset, rounded canvas with density-derived gutters, subtle tone and a hairline; no elevation shadow |
| 2 overlay | menus, command palette, modals, popovers | the only floating, shadowed layer (`--elev-1/2/3`) |

Rules that keep it coherent:

- The sidebar and docks frame the canvas rather than competing with it. The sidebar uses spacing and hover/selected fills instead of repeated dividers. Right panels have one leading hairline, not a floating card treatment. The canvas frame serves both the page and the Git-diff portal without adding another scroll container.
- Lists are flat rows with a compact status chip and a hairline separator. A card (`data-variant="raised"`) is an opt-in for content read or decided as ONE unit (a review repo block, a submit confirm), not a treatment for the canvas or docks.
- Hover, selected and focus are three DIFFERENT treatments; reserve accent for primary actions, the current object and the separate pending-navigation cue.
- `assets/css/density.css` remains the single size source (type ladder with a 12 px floor, control/row heights, card padding, gutters); `surfaces.css` carries color/border/shadow/radius only so the density assertions stay true.
- New work reads `docs/ui-density.md` + `assets/css/CONTEXT.md` first; never hand-roll a shadow, size or animation.

## Right dock

- **History** is project-first, server-side and paged, with status and kind filters and an option to widen to all projects. The header and filters stay in place; only the rows scroll.
- **Source Control** is one Git dock. Its summary header and **Changes / Branches / Commits** switcher keep their intrinsic height; only the selected view scrolls in the remaining bounded space. Branch search stays at the top of its view. Working-tree and commit diffs open in the central canvas, not in the dock.

## Tab rail semantics

The tab rail is the ONE open-view list (the sidebar never enumerates open views).

- A task has ONE canonical tab key `{node, task_id}` across `/tasks?task=<id>`, `/review/<id>` and `/review/<id>/commit/<sha>`. The key is not a URL: the tab retains its exact destination, including the commit or query parameters that were opened. Other views (project, draft, conversation, working-tree diff) keep their own identities.
- ONE reused **preview** tab per project, replaced in place by the next preview; middle-click PINS it without navigating. `draft`, `project`, `assistant` and `diff` tabs are always pinned, so a preview can never overwrite unsaved input.
- The rail, overflow, close neighbour and keyboard cycling use the same stable group order: **project → task → chat → diff → other**. Closing a tab never stops a task or session; closing an unsent Assistant draft also discards its temporary tab state. Focus falls back to the neighbouring tab; the deliberate last close returns to the workbench home without reopening the default draft.
- The rail-end `#workbench-tabs-overflow` menu appears only while the strip really scrolls. `Alt+Left`/`Alt+Right` cycle tabs only from within the rail or its overflow menu, not from editable fields.
- Navigation intent shows immediately as pending styling and `aria-busy`. The destination becomes current (`aria-current="page"`) only after the exact route is confirmed, even when it has the same canonical tab key.
- The client restores tab state from `sessionStorage` via the DOM-free store in `assets/js/hooks/workbench_tabs.js`; the server renders an empty rail shell. This restores tab metadata, not cached pages: cross-page navigation still uses LiveView and can remount and load data. Immediate feedback does not mean the next page is ready.

## What is shipped

- Project history rows route by lifecycle state. The sidebar's Active Tasks section shows only live tasks, with a separate, compact "Needs review" nudge. Open views belong to the tab rail.
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
