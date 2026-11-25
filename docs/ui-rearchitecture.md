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
- **Workspace is grouping only.** A workspace is a set of projects with no OS path; it never executes. Execution resolves to an explicit, changeable member, and the UI says which one.

## Area responsibilities (one primary job each)

| Area | Its ONE job | What it must not do |
|---|---|---|
| Left sidebar | switch scope + reach the main destinations | enumerate open views or duplicate a task/conversation list |
| Top tab rail | return to a concrete thing you had open | become the task list; lossy close that kills a task/session/draft |
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
- Every destination preserves the viewed node (`?node=` / `&node=`) and the current scope (`?project=`).

## Surface and elevation model

Three layers, expressed as tokens in `apps/evo_dash/assets/css/surfaces.css`:

| Layer | Surfaces | Treatment |
|---|---|---|
| 0 chrome/shell | sidebar, tab strip background, right dock | recessed: rail fill, hairline separators, no shadow |
| 1 content canvas | page canvas, ACTIVE tab, lists | continuous flat surface, no shadow |
| 2 overlay | menus, command palette, modals, popovers | the ONLY shadowed surfaces (`--elev-1/2/3`) |

Rules that keep it coherent:

- Lists are flat rows with a compact status chip and a hairline separator. A card (`data-variant="raised"`) is an opt-in for content read or decided as ONE unit (a review repo block, a submit confirm).
- Hover, selected and focus are three DIFFERENT treatments; the accent color belongs to primary actions and the current object only.
- `assets/css/density.css` remains the single size source (type ladder with a 12 px floor, control/row heights, card padding, gutters); `surfaces.css` carries color/border/shadow/radius only so the density assertions stay true.
- New work reads `docs/ui-density.md` + `assets/css/CONTEXT.md` first; never hand-roll a shadow, size or animation.

## Tab rail semantics

The tab rail is the ONE open-view list (the sidebar never enumerates open views).

- A tab is an identity `{node, projectPath, kind, id}` over one concrete object: a task, a review, a conversation, a project draft, or the Git diff.
- ONE reused **preview** tab per project, replaced in place by the next preview; middle-click (or the kept-open affordance) PINS it. `draft`, `project`, `assistant` and `diff` tabs are always pinned, so a preview can never overwrite unsaved input.
- Closing a tab closes the VIEW only — never a session, a task, or pinned draft input; focus falls back to the neighbouring tab.
- The rail-end `#workbench-tabs-overflow` menu appears only while the strip really scrolls; `Alt+Left`/`Alt+Right` cycle tabs only while the keydown is inside the rail.
- Tab state is client-side (`sessionStorage`, pure DOM-free store in `assets/js/hooks/workbench_tabs.js`); the server renders an empty rail shell. Cross-page navigation is an ordinary LiveView navigation — do not promise zero-remount joins.

## What is shipped

- Project history rows route by lifecycle state; the sidebar is live-tasks-only with a separate, compact "Needs review" nudge; the per-project open-view list is gone.
- A project OVERVIEW states the scope (name/path/point/node/HEAD, workspace member) and offers the two entry points; the manual composer is an explicit step (`wb_task=1`) and every deep link/resume URL still lands in it.
- `/tasks` carries the full lifecycle filter set (incl. `finalizing` and `needs_review`), URL-addressed filters that survive a node switch, honest counts and empty states, and unified pause/resume/cancel/force-kill entry.
- Review renders an outcome banner and per-repo truth for completed/failed/cancelled/no-report/unrecoverable-branch, with "Prepare follow-up task" disambiguated from "Resume".
- One surface/elevation system, an integrated native tab strip, flat list rows with opt-in cards, and a docked (not floating) right panel.

## Deferred deliberately

- Split view (the first candidate would be Assistant + a run/review pair) — prove single-view round-trips and state retention first.
- Restoring tabs across a desktop restart (the backend port can change; browser storage is not a reliable cross-restart identity).
- Workspace-aggregated history (needs one merged ordering/pagination across member repos, not concatenated pages).
- Measured navigation budgets: record click → visible feedback, click → interactive, click → data-ready p50/p95 locally and over SSH before optimising remounts, serial RPCs or hidden-panel prefetch.
- Rendered-screenshot verification in light/dark and narrow widths; current guarantees are source contracts plus token reasoning.

## Known boundaries

- The needs-review store predicate requires a live branch, so a completed task that produced no branch does not enter triage (it is still reviewable from Tasks/history).
- `assets/js/hooks/workbench.js` sits at ~1076 lines (baseline ~1000); the tab store was extracted to keep it from growing, and its comments are load-bearing.
