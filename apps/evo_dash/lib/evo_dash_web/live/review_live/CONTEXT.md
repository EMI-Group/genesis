# ReviewLive — Review Page

## Intent

`EvoDashWeb.ReviewLive` (`review_live.ex`, `GET /review/:task_id`) is the GitHub-PR-inspired code review page.
The page module is a THIN shell: `render/1` delegates to `EvoDashWeb.ReviewLive.Page`, `handle_event/3` is ONE clause delegating to `EvoDashWeb.ReviewLive.Events.dispatch/3`, and the remaining `handle_info/2` clauses own the async result messages.
The page-level summary lives in `apps/evo_dash/CONTEXT.md`; the markup lives in `page.ex` and the presentation components in the SIBLING `components/review_components*` tree (read-only from this node).
**Two-page model**: the `:show` route renders `page_header` + `page_tabs` + one of FIVE tab bodies (`:conversation | :objective | :files_changed | :commits | :archive`).
The `:commit` route (`/review/:task_id/commit/:sha`) renders a standalone `commit_detail_header` + `commit_diff_layout` page with no page tabs; the back link lives inside `commit_detail_header`.
The objective renders on its own `:objective` tab (readability column, raw/markdown toggle + copy button inside the component).
**Multi-repo review**: each writable foreign repo is its own review entry, repo selection lives in the Files-changed/Commits toolbars AND one per-repo card in the conversation pane, and merge/reject act on EXACTLY the repo whose form/button was clicked (never a fan-out).
Single-repo (legacy) tasks render one card with no repo affordances.
A repo with no `branch_name` has no changes, is excluded from every merge/reject action and never blocks aggregate completion; a COMPLETED task with no changes in ANY repo renders the informational notice and is dismissed through "Mark as read" (the `ignore` event).
**Terminal outcomes**: `/review/<id>` is a destination for EVERY finished task — `EvoDashWeb.ReviewLive.Outcome` classifies it (`:completed | :failed | :cancelled | :other`), a `:failed` task offers NO merge/reject (its cards say why), a `:cancelled` task keeps its preserved changes mergeable, and the `task_outcome_banner/1` under the header states the outcome (failure record, missing agent report, diagnostics link) on every tab.
No store / registry / git / `EvoDash.NodeContext` call runs in the LiveView process: the page load, every review action and every lazy diff fetch execute in `EvoDash.TaskSupervisor` children behind `EvoDash.SafeCall`.
The page load is LITE (`EvoDash.NodeContext.get_task_lite/2` — no archive transfer), and the archive is a separate on-demand, PAGED async load started when the Archive tab opens.
Archiving is OPT-IN per task (`opts[:archive]` via `EvoDashWeb.ArchiveHelpers.archive_opt?/1`): a task started without it renders no Archive tab and never issues an archive fetch.

## Routing Table

- `review_live.ex` → `EvoDashWeb.ReviewLive` — thin page module: mount, handle_params, ONE event dispatch, async result clauses, `start_async_load/2`.
- `page.ex` → `EvoDashWeb.ReviewLive.Page` — the whole render template plus its template-only `reload_status/1` and `review_commits_path/3`.
- `outcome.ex` → `EvoDashWeb.ReviewLive.Outcome` — the pure, total terminal-outcome matrix (`classify/1`, `actions_allowed?/1`, `dismissable?/2`, `show_stats?/2`).
- `aggregates.ex` → `EvoDashWeb.ReviewLive.Aggregates` — pure, total derivations over the repo list.
- `state.ex` → `EvoDashWeb.ReviewLive.State` — pure socket/derived-state helpers (no spawning, no flash).
- `runner.ex` → `EvoDashWeb.ReviewLive.Runner` — the async action spawner and its in-progress-state release.
- `action_results.ex` → `EvoDashWeb.ReviewLive.ActionResults` — table-driven application of an action outcome.
- `events.ex` → `EvoDashWeb.ReviewLive.Events` — the table-driven client-event router.
- `tabs.ex` → `EvoDashWeb.ReviewLive.Tabs` — tab, archive and page-chrome events.
- `repo_actions.ex` → `EvoDashWeb.ReviewLive.RepoActions` — per-repo merge/reject/switch/jump events.
- `task_actions.ex` → `EvoDashWeb.ReviewLive.TaskActions` — resume/ignore/PR/Extract-Skills events.
- `file_actions.ex` → `EvoDashWeb.ReviewLive.FileActions` — tree, filter, selection and context events.
- `diffs.ex` → `EvoDashWeb.ReviewLive.Diffs` — the lazy per-file diff subsystem.
- `load_request.ex` → `EvoDashWeb.ReviewLive.LoadRequest` — the async review request lifecycle and its scoped History signal.
- `load_data.ex` → `EvoDashWeb.ReviewLive.LoadData` — the off-process review-data load.
- `archive_load.ex` → `EvoDashWeb.ReviewLive.ArchiveLoad` — the paged archive state machine, per-agent result cache and Archive-tab panel.
- `merge_check.ex` → `EvoDashWeb.ReviewLive.MergeCheck` — the async dry-run merge check and the auto-resolve payload.
No child CONTEXT.md.

## API Surface

| Module | Purpose |
|--------|---------|
| `EvoDashWeb.ReviewLive` (`review_live.ex`) | `render/1` → `Page.render/1`; `mount/3` seeds page assigns (including `page_ready?: false` and the derived defaults `stats: Aggregates.empty_stats()`, `primary_repo: nil`, `completion_status: nil`) and subscribes to the `"tasks"` topic when connected; `handle_params/3` honours `?tab=commits`, computes the load context `{scope, live_action, commit_sha, repo_id}` (repo from `params["repo"] \|\| previous_review_repo/1 \|\| "primary"`), resets the action-earned resolutions/in-flight state/tree/filter on a context change, then delegates to `LoadRequest.start/2`; ONE `handle_event/3` delegating to `Events.dispatch/3`; public `retry_load/2` re-runs the same request; private `review_reload_material?/2` (`:none` ⇒ false, `nil` ⇒ true, else status ≠ loaded status) and `previous_review_repo/1` (carries a commit route's repo back to SHOW). |
| `EvoDashWeb.ReviewLive.Page` (`page.ex`) | The whole `~H` template (`use EvoDashWeb, :html`): the `Layouts.app` shell, the remote gate, `#review-load-error`, the SCOPED-loading branches, the `:commit` page, the SHOW header/tabs/tab cond, and the trailing branch warning. Template-only `reload_status/1` renders `#review-reload-status` (`role="status"`, small spinner, the same `Loading review data...` text); `review_commits_path/3` builds the commit-detail back link with `node` and a non-`primary` `repo` param. |
| `EvoDashWeb.ReviewLive.Aggregates` (`aggregates.ex`) | The ONE pure/total home of derived review data: `stats/1` → `%{files_count:, additions:, deletions:, commits_count:}` summed over ALL repos (a nil `review_data` contributes only its commit count), `primary/1` (the `"primary"` entry or nil), `completion_status/2`, `terminal_resolution?/1`, `empty_stats/0`. No I/O, formatting or raises; a malformed entry contributes nothing. `RepoCards.repo_has_changes?/1` is the single "does this repo have changes?" test. |
| `EvoDashWeb.ReviewLive.State` (`state.ex`) | Pure socket/assign helpers: `put_derived/1` (recomputes `stats`/`primary_repo`/`completion_status` from the CURRENT `review_repos`/`review_status`), `project_active_repo/1` (flat assigns from the active repo; no-op on `:commit`), `switch_repo/2` (whitelist + clear `file_filter` + re-project), `find_review_repo/2`, `repo_actionable?/1` (terminal resolution OR no changes), `resolve_merge_target/2`, `set_repo_resolution/3` (the single resolution funnel: records into `local_repo_resolutions`, updates the entry via `MergeCheck.update_repo/3`, re-projects, `put_derived/1`), `carry_local_resolutions/2` (overlay TERMINAL earned resolutions onto a fresh load for repos whose loaded resolution is nil), `invalidate_active_tasks/1`, `next_action_seq/1`, `dir_paths/1` (every ancestor directory of a file list, for expand-all). |
| `EvoDashWeb.ReviewLive.Runner` (`runner.ex`) | `spawn/4` — runs `fun` in `EvoDash.TaskSupervisor` behind `SafeCall.run/1` and ALWAYS sends `{:review_action_result, task_id, node, action, ref, result}`; a child that cannot start is cleared here plus one error flash. `clear/3` — releases the in-progress state for the action's shape: the `{scope, path}` diff entry only while this result still owns its seq, `:completion` nothing, everything else `review_action` + the repo's `busy_repos` membership (all `repo_ids` for `:merge_all`) + `action_loading` (task-level actions only). |
| `EvoDashWeb.ReviewLive.ActionResults` (`action_results.ex`) | The ONE public entry `apply/4`, TABLE-DRIVEN through the `@handlers` action→handler registry (`merge`, `merge_all`, `reject`, `resume`/`ignore` → `:resume_or_ignore`, `create_pr`, `extract_skills`, `auto_resolve`, `completion`, `diff`, `expand_context`); an unknown action is the no-op handler. Owns the outcome arms and their tails: per-repo settle (`set_repo_resolution/3` + flash + completion), batch settle (one summary flash, no navigation), completion persistence (`maybe_persist_completion/1` reads the CACHED `completion_status`), and every flash text. |
| `EvoDashWeb.ReviewLive.Events` (`events.ex`) | `dispatch/3`, TABLE-DRIVEN through the `@handlers` event-string → `{module, function}` registry; an unknown event is a no-op `{:noreply, socket}` (never an atom conversion). `"retry_load"` deliberately targets the PAGE module, whose `start_async_load/2` is not duplicated. |
| `EvoDashWeb.ReviewLive.Tabs` (`tabs.ex`) | `switch_tab/2`, TABLE-DRIVEN over `%{"conversation" => :conversation, "files_changed" => …, "objective" => …, "commits" => …}`; the `"archive"` opt-in gate assigns the tab and calls `ArchiveLoad.ensure_loaded/1` ONLY when `archive_opt_in?` (otherwise a complete no-op). Also `retry_archive/2`, `load_more_archive/2`, `load_archive_agent_result/2` (matches the `"agent_id"` params key the snake_case `phx-value-agent_id` attribute yields), `toggle_summary_view/2`, `toggle_objective_view/2`, `copied/2`, `retry_remote_connection/2`, `switch_to_local/2`. |
| `EvoDashWeb.ReviewLive.RepoActions` (`repo_actions.ex`) | `switch_repo/2` (both form payload shapes), `merge/2` (one whitelisted, actionable repo named by `repo_id`; no fan-out, no navigation), `merge_all/2` (folds every unresolved CHANGE-BEARING repo into one batch, one summary flash, no navigation), `merge_target_change/2`, `auto_resolve/2` (PRIMARY-scoped payload from `MergeCheck.auto_resolve_payload/1`), `reject/2`, `open_repo_diff/2`. Each action records its in-progress state and spawns through `Runner.spawn/4`. |
| `EvoDashWeb.ReviewLive.TaskActions` (`task_actions.ex`) | `resume/2` (PRIMARY-scoped, navigates on the result), `ignore/2`, `create_pr/2` (PRIMARY-scoped), `extract_skills/2` / `cancel_extract_skills/2` (modal open/close) and `confirm_extract_skills/2` (PRIMARY-scoped `start_task`), plus the private commit-history formatter the PR description uses. |
| `EvoDashWeb.ReviewLive.FileActions` (`file_actions.ex`) | `toggle_dir/2` (repo-keyed on SHOW, flat on `:commit`), `collapse_all_dirs/2`, `expand_all_dirs/2` (`State.dir_paths/1` over the acting file list), `filter_files/2`, `select_file/2` (sets the tab, marks the file selected+expanded, lazy diff, `push_event("scroll_to_file", …)`), `toggle_file_expansion/2` (lazy diff only when expanding), `load_file_diff/2`, `expand_context/2` (grow-only `+20`, `:all` past 30). |
| `EvoDashWeb.ReviewLive.Diffs` (`diffs.ex`) | `maybe_start/2` (fetches only when the current scope's file has a nil diff), `start/4` (no-op while a `{scope, path}` load is in flight; the seq lives in `diff_in_flight`), `apply_result/4` (relevance guards: scope still on screen, file still present, and — for `:diff` — still selected or expanded), `context_level/3`, `update/5` (writes the CAPTURED scope's data source; the SHOW clause also re-projects and calls `State.put_derived/1`), plus the public `diff_scope/1` and `file_present?/3` guards. Failure flashes: "Failed to load diff for …" and "Failed to expand context: …". |
| `EvoDashWeb.ReviewLive.LoadRequest` (`load_request.ex`) | `start/2` advances the generation, respects the remote gate and connected render, and starts the supervised load; its flat `{:review_data_loaded, task_id, node, generation, result}` envelope is unchanged. `scope/1` and `blocked?/1` share the task/serving-target and availability checks with the page. `settle/2` clears the pending marker only after the page accepts the result, and clears metadata ownership on error. The optional 3-arity `:review_load_runner` seam replaces `LoadData.load/3` inside the spawned task. |
| `EvoDashWeb.ReviewLive.LoadData` (`load_data.ex`) | `load/3` returns `{:ok, assigns_map} | {:error, gettext_string}` in the supervised request. `build_assigns/3` builds `@review_repos` (primary first), the flat projection of the primary, `archive_opt_in?`, AND the DERIVED assigns (`stats`, `primary_repo`, `completion_status` via `Aggregates`). `commit_inspection/4` (the `:commit` route) inspects the repo named by the route's `repo_id`. The result map never carries archive keys nor `tree_expanded_dirs`/`file_filter`, so applying a load can never wipe a loaded archive or the tree/filter state. |
| `EvoDashWeb.ReviewLive.ArchiveLoad` (`archive_load.ex`) | Paged, lazy archive state machine + the Archive-tab panel. `ensure_loaded/1` (first page only from `:idle` AND only when `archive_opt_in?`), `load_more/1`, `load_agent_result/2`, `handle_result/6`, `handle_agent_result/6`, `retry/1`, `invalidate_agent_results/1`, `sync_context/1`, `export_available?/1`, `panel/1`, and the LABEL helper `label_total/1` (public for its own consumers; `put_label/1` caches it into `@archive_label_total` on every path that rewrites the records/total assigns). Seams `:review_archive_runner` / `:review_archive_agent_runner`, resolved at CALL time inside the spawned child. |
| `EvoDashWeb.ReviewLive.MergeCheck` (`merge_check.ex`) | Async non-mutating merge dry-run (`check_merge/4`) → `:clean | %{state: :conflict, files: files} | %{state: :error}` per repo. `maybe_start/1` spawns ONE check per review repo under the same gates the cards render with (skipping a repo already checking the same target); results arrive as `{:merge_check_result, task_id, node, repo_id, target, result}`. Also `repo_available?/2`, the public `update_repo/3` (single-entry update shared with `State`), `handle_target_change/2`, `handle_result/6`, and the PURE PRIMARY-scoped `auto_resolve_payload/1`. |
| `EvoDashWeb.ReviewLive.Actions` (`actions.ex`) | Off-process ACTION executors — no socket in or out, each returns a small outcome tuple: `merge/4`, `merge_all/2` (sequential, best-effort), `reject/3`, `set_review_status/3`, `create_pr/5`, `start_task/3`, `auto_resolve/3`, `load_review_diff/6`, `load_commit_diff/4`, `load_commit_diff_with_opts/5`. TOTAL — an unexpected shape becomes `{:error, {:unexpected, other}}`. Seams `:review_merge_runner` / `:review_reject_runner` are resolved at CALL time; a batch resolves the merge seam once. |

**Component-contract boundary**: every component the template renders (`page_header`, `page_tabs`, `agent_summary`, `objective_section`, `diff_stats_bar`, `task_summary`, `repo_cards`, `task_actions`, `extract_skills_modal`, `split_diff_layout`, `commit_diff_layout`, `commits_list`, `commit_detail_header`, `archive_review_section`) is defined in the SIBLING `components/review_components*` tree, whose CONTEXT.md documents its attr/event surface. This page owns the wiring; that tree owns the markup.

## Derived assigns — derive ONCE, never in the render

`stats`, `primary_repo` and `completion_status` are computed once per data mutation and read as plain assigns.
`LoadData.build_assigns/3` computes them at load time; every later mutation funnels through `State.put_derived/1`.
The `put_derived/1` call sites are the load success (AFTER `carry_local_resolutions/2`, so the overlay's resolutions are included), the load-error branch (header assigns cleared), `set_repo_resolution/3`, `maybe_persist_completion/1`, the SHOW clause of `Diffs.update/5`, and the merge-check result path.
`maybe_persist_completion/1` consumes `assigns.completion_status` instead of re-walking the repo list; `set_repo_resolution/3` refreshes the derived assigns BEFORE it, so the ordering is guaranteed.
The render body NEVER computes an aggregate, a primary-repo lookup, a completion status or the archive label: it reads `@stats`, `@primary_repo`, `@completion_status`, `@archive_label_total`.
`ArchiveLoad` maintains `archive_label_total` through `put_label/1` on every path that rewrites `archive_records` / `archive_total` / `archive_server_total`; `label_total/1` stays public for its own consumers.

## Scoped loading and tab motion

The full-page spinner (`role="status"`, `loading-spinner`, `Loading review data...`) renders ONLY while `@loading and not @page_ready?`.
`page_ready?` flips true on the first successfully applied load, so a pushed task-status/terminal broadcast or a debounced reload keeps the whole shell (header, tabs, current tab body) on screen and adds ONE compact `#review-reload-status` strip (`role="status"`, small spinner, the SAME `Loading review data...` text) below the tabs.
That identical marker text is load-bearing: `EvoDashWeb.TestHelpers.flush_loading/4` callers drain reloads by waiting for it.
The `:commit` page places the same strip above its detail.
The `#review-load-error` panel (`@error`) and the `if @branch_exists and is_nil(@review_data) and not @loading` warning block are the unchanged failure affordances.
The SHOW-route tab `cond` block is wrapped in one re-keyed `<div class="wizard-step-enter" id={"review-tab-" <> to_string(@review_tab)} aria-busy={@loading and @page_ready?}>`, so a tab switch replays the existing reduced-motion-safe `.wizard-step-enter` animation from `assets/css/app.css` (the same class the provider wizard uses).
No new CSS, keyframes or hooks; all inner DOM ids/classes are unchanged, and the `:commit` detail and the branch-warning block sit outside the wrapper.

## Workbench metadata

The workbench uses the loaded task's raw PRIMARY repo path (also the Git pane path), objective as the task label, and the route task id; changing the active diff repo or opening a commit does not rescope it.
`LoadRequest` stamps a successful load with `{task_id, target_id, beam_node, blocked?}`; the page keeps its metadata during a same-scope refresh or show/commit/repo change, but withholds it on a mismatch, a load error, an active remote gate, or a remote request resolved to the local BEAM.
`LoadRequest.history_scope_pending?/1` is true only after a connected, ungated, task-scoped request actually started and while its current generation is still resolving workbench metadata; a known project or a successfully resolved repo-less task stays settled during refresh.
The History-only flag is passed to `Layouts.app/1` as `workbench_history_scope_pending?` and does not advertise a project path or enable Git.
Superseding and blocked starts replace or clear the marker, a stale result never clears a newer marker, and an accepted success/error clears it through `LoadRequest.settle/2`.
An unresolved remote request with no target id does not register a local task tab.

## Page model (`:show`)

- **`page_header`** — PRIMARY-scoped fields (`@primary_repo`'s `repo_path`/`branch_name`/`default_merge_target`/`commit_sha`, never the active-repo projection), `back_url = with_node_param(~p"/projects", @current_node_id)`, full title, task/review status + meta, `node_name: @current_node_name`, `show_review_status: @outcome != :failed`, `stats` gated by `Outcome.show_stats?/2`. IMMEDIATELY under it sits `task_outcome_banner` (see the section below), so the outcome is visible on every tab.
- **`page_tabs`** — underline tab bar with count badges from `@stats` (`files_count`, `commits_count`), `show_archive: @archive_opt_in?`, `archive_count: @archive_label_total` (0/unknown renders no badge).
- **`:conversation`** — readability column `max-w-4xl mx-auto w-full space-y-4`, in order: `agent_summary` → `diff_stats_bar` (`@stats`, rendered only when `Outcome.show_stats?(@stats, @outcome)`) → `task_summary` → `repo_cards` AT THE BOTTOM (`repos: @review_repos`, `completion: @completion_status`, `review_action: @review_action`, `busy_repos: @busy_repos`, `back_url`, `actions_allowed: Outcome.actions_allowed?(@outcome)`, `task_outcome: @outcome`) → `task_actions` (PRIMARY/aggregate surface: `can_resume`, `loading: @action_loading`, `branch_exists`, `has_pr`, `pr_url`, `show_export: ArchiveLoad.export_available?(assigns)`, `export_url`, `no_changes: Outcome.dismissable?(@outcome, @is_no_changes)`, `branch_exists: @branch_exists and Outcome.actions_allowed?(@outcome)`) → `extract_skills_modal`.
- **`:objective`** — readability column hosting only `objective_section` (`objective`, `objective_raw`); always rendered, no badge, nil/blank objective shows the component's empty state.
- **`:files_changed`** — FULL WIDTH: `split_diff_layout` reads the ACTIVE repo's repo-keyed submaps via inline `Map.get` (`expanded_files`/`selected_file`/`file_context_levels`/`tree_expanded_dirs`) plus flat `file_filter`, `repos`, `active_repo_id`, `diff_in_flight`; repo selection lives in the layout's toolbar. nil `@review_data` → the empty-state panel.
- **`:commits`** — `commits_list` over the ACTIVE repo's `@commits` (its own repo selector, shown only for multiple repos).
- **`:archive`** — the single `ArchiveLoad.panel/1` call (`state`/`records`/`total` (EFFECTIVE)/`opt_in?`/`dropped`/`exhausted?`/`server_total`/`loading_more?`/`more_error`/`agent_results`/`error`/`task_id`/`node_id`); it owns every state (opt-in notice, spinner, retry-able error, empty state, `archive_review_section`) and forwards the node-aware export href.

## Multi-repo review (writable foreign repos)

The core writes writable-foreign-repo results into the task result's top-level `repos` map (`%{repo_id => %{"commit_sha" => sha, "branch_name" => branch | nil}}`, STRING keys); the review page turns each such repo into a review entry.

- **Repo list** (`LoadData.build_review_repos/6`): `@review_repos` is a list of `%{repo_id:, repo_path:, branch_name:, commit_sha:, base_sha:, branch_exists:, review_data:, commits:, merge_targets:, default_merge_target:, merge_status:, resolution:}`, primary FIRST; foreign entries come from `task.opts[:foreign_repos]` normalized via `EvoGit.Core.ForeignRepo.normalize/1` and only repos present in `repos` with a non-nil `branch_name` get an entry; legacy tasks (no `repos` key) yield exactly one primary entry. `active_repo_id` defaults `"primary"`.
- **`resolution`** — per-repo control state: `nil` (unresolved, actions available when `branch_exists`), `%{state: :merged, target:}` / `%{state: :rejected}` / `%{state: :handled}` (TERMINAL; `:handled` = the branch was already gone at page LOAD), `%{state: :error, detail:}` / `%{state: :conflict, detail:}` (NON-terminal, retryable). Load seeds `%{state: :handled}` for a repo that HAD a non-blank branch which no longer exists; a `branch_name == nil` repo stays `nil`.
- **Self-reload overlay** — the page's own `set_review_status/3` broadcast (`{:task_updated, id, nil, node}`) rides the shared debounce into a fresh load that re-derives resolutions from REPOSITORY state only, so `set_repo_resolution/3` ALSO records `%{repo_id => resolution}` in `local_repo_resolutions` (mount-seeded `%{}`, reset on a load-context change). `carry_local_resolutions/2` overlays only TERMINAL entries, only onto loaded repos whose resolution is nil, and prunes repo ids no longer loaded.
- **Repo selection is component-owned**: each selector is a `<select name="repo_id">` inside its own `<form phx-change="switch_repo">` (a form-less select never delivers its event); both payload shapes are accepted and `State.switch_repo/2` whitelist-validates the id (never `String.to_atom`), clears `file_filter` and re-projects.
- **PRIMARY-scoped operations**: `resume`, `create_pr`, `confirm_extract_skills`, `auto_resolve`, `set_review_metadata` and the `page_header` repo fields all resolve the `"primary"` entry explicitly, never the active-repo projection. The `:commit` route instead inspects the repo named by its `repo_id` (the `?repo=` value, defaulting to `"primary"`).
- **Per-repo merge** — dispatched only by a per-repo merge form (`repo_id`, `target_branch`); an unknown id, a TERMINAL resolution or a no-change repo is a no-op. Target = the trimmed `target_branch`, falling back to `default_merge_target` when blank/absent or not a member of a non-empty `merge_targets`.
- **Merge all** — the batch button renders only for ≥2 repos with ≥2 CHANGE-BEARING repos still unresolved; the handler folds every unresolved change-bearing repo into `%{repo_id, repo_path, branch_name, target}` (`target = default_merge_target || first(merge_targets)`), runs one sequential best-effort batch and puts ONE summary flash. A conflict/error lands on that repo's own card while the rest still merge.
- **Per-repo reject** — same single-repo whitelist/terminal/no-change no-op; `:rejected` → terminal resolution + `branch_exists: false`; any error → `%{state: :error, detail: inspect(reason)}` and STAY.
- **Completion** (`Aggregates.completion_status/2` + settle tails → `maybe_persist_completion/1`): the filter is the CHANGE-BEARING repos only, so a no-change repo never blocks completion. It is `nil` while the actionable list is empty (a fully-no-change task is never reported `:rejected`) or while any actionable repo is non-terminal; when all are TERMINAL it returns the persisted `@review_status` if it is `:merged`/`:rejected`, else `:merged` if any merged, else `:rejected`. A non-nil value is the completion path: assign `review_status`, `invalidate_active_tasks/1`, and the background `:completion` action; the same value drives `repo_cards`' completion banner.
- **No-change repos** — `EvoDashWeb.ReviewComponents.RepoCards.repo_has_changes?/1` (non-blank `branch_name`) is the ONE definition reused by the merge-all gate, the per-repo guards, `completion_status/2` and the load's `is_no_changes`. `review_status` is the persisted value when non-nil, else `:open` — a primary with no branch is NOT forced to `:no_changes`, so a task whose foreign repos did change renders a normal review.
- **MergeCheck per-repo** — one async dry-run per repo tagged `repo_id`; auto-resolve stays PRIMARY-scoped, so a foreign-repo conflict is surfaced on that repo's card and is not auto-resolved.

## Async boundary and the action table

`Runner.spawn/4` is the ONLY action spawner and `ActionResults.apply/4` the ONLY apply entry; the handle_info clause applies BEFORE `Runner.clear/3` (the lazy-diff tail must read the PRE-clear `diff_in_flight` seq) and drops a result for a different task/node entirely.
No `try/rescue` in these files: `EvoDash.SafeCall.run/1` is the single deliberate exit boundary, and the closure always sends its result so no in-progress flag can wedge.

| Action | `action_ref` | In-progress state | Outcome branches (`ActionResults`) |
|---|---|---|---|
| `:merge` | `%{repo_id, target, seq}` | `review_action %{kind: :merge, repo_id:, seq:}` + repo in `busy_repos` | `{:ok, {:merged, target}}` → settle (terminal + success flash + completion); `{:ok, {:conflict, details}}` → `%{state: :conflict}` + error flash; else `%{state: :error}` + error flash. Always STAYS. |
| `:merge_all` | `%{repo_ids, seq}` | `review_action %{kind: :merge_all, seq:}` + every repo id in `busy_repos` | `{:ok, [{repo_id, outcome}]}` → each repo settles on its own card + ONE batch summary flash + completion; unexpected → single error flash. |
| `:reject` | `%{repo_id, seq}` | review_action + repo in `busy_repos` | `{:ok, :rejected}` → terminal + success flash + completion; else `%{state: :error}` + error flash. |
| `:resume` / `:ignore` | `%{to, flash_msg, seq}` | review_action + `action_loading` | `{:ok, :ok}` → invalidate + info flash + navigate; anything else → error flash AND the same navigation (the click expresses intent). |
| `:create_pr` | `%{seq}` | review_action + `action_loading` | `{:ok, {:pr, url, title}}` → `has_pr`/`pr_url` + success flash; `{:ok, :no_pr}` → "gh CLI" error flash; else error flash. |
| `:extract_skills` | `%{seq}` | review_action + `action_loading` | `{:ok, {:ok, task}}` → close the modal + info flash; else error flash (modal stays open). |
| `:auto_resolve` | `%{to, seq}` | review_action + `action_loading` | `{:ok, {:ok, task}}` → invalidate + success flash + navigate; else error flash. |
| `:completion` | `%{status, seq}` | NONE (background bookkeeping write; `clear/3` leaves it alone) | error → error flash only. |
| `:diff` / `:expand_context` | `%{repo_id: scope, path, level, seq}` | `diff_in_flight[{scope, path}] = seq` | see "Diffs are LAZY". |

`action_loading` feeds `task_actions loading` (the aggregate spinner) and is set ONLY by the task-level actions (`resume`, `ignore`, `create_pr`, `extract_skills`, `auto_resolve`).
A node/route context change in `handle_params/3` resets `review_action`/`action_loading`/`busy_repos`/`diff_in_flight`/`review_broadcast_status` (their result messages would be dropped anyway).

## Diffs are LAZY — never eager

`load_review_metadata*` / `load_commit_files` return per-file `%EvoGit.Review.FileInfo{}` with `diff: nil` (numstat only); a per-file diff is fetched only by selection, expansion or `expand_context`.
The scope is the ACTIVE repo id on SHOW and the `:commit` atom on the commit route, captured at spawn time in the action ref, so a result landing after a repo switch is never written into the wrong repo.
Duplicate spawns are suppressed per `{scope, path}`; a result applies only while it is still the latest seq for that key, the scope is still on screen, the file still exists there, and — for `:diff` — the file is still selected or expanded.
`:expand_context` is grow-only (`+20` lines, `:all` past 30 or at `:all`) and `max_context_level/2` never downgrades a written level.
`Diffs.update/5` writes into the CAPTURED scope's data source (`commit_data` on `:commit`, the repo entry's `review_data` on SHOW); the SHOW clause re-projects and re-derives.
Tab switches, tree toggles and filter typing are pure assigns with no RPC.

## Files-changed toolbar state (tree + filter)

- **`tree_expanded_dirs`** — `%{dir_path => true}`; SHOW keys the outer map by `repo_id` (toggle/collapse/expand act on the ACTIVE repo's submap), `:commit` is a flat dir-keyed map. `expand_all_dirs` merges every ancestor directory of the acting file list (`State.dir_paths/1`). The template reads the active submap inline.
- **`file_filter`** — shared filter string; `filter_files` assigns `%{"filter" => value || ""}` (client-debounced); `switch_repo` resets it to `""`.
- Both are mount-seeded and deliberately absent from the load-result map, so they survive debounced reloads.

## Reload policy (task broadcasts, no polling)

- `mount/3` subscribes to `EvoGit.PubSub` `"tasks"` when connected. `{:task_updated, task_id, status, node}` is node-filtered FIRST: only the reviewed task's own broadcast from the viewed node STASHES `status` in `review_broadcast_status` (and drops the per-agent archive result cache); every event is then forwarded to `NodeAware.handle_task_info/2` (returns `{:noreply, socket}` — never re-wrap).
- `handle_info(:node_aware_reload_tasks)` (NodeAware's shared 300ms trailing-edge debounce) ALWAYS refreshes the sidebar via `NodeAware.reload_tasks/1`, then starts a review-data reload only when `review_reload_material?/2` is true; the marker is reset either way.
- Other tasks' broadcasts and foreign-node broadcasts never reload review data; `{:task_deleted, ...}` only feeds the sidebar reload.
- No polling anywhere; remote nodes are served by the same push contract.

## Archive tab — paged load & export decision

The Archive tab renders ONLY for a task that opted into archiving; for every other task the tab is absent, `switch_tab` "archive" is a no-op, and `ArchiveLoad` never fetches (the panel would render the muted "Archive data was not collected for this task." state).
Opening the tab starts the FIRST page (`limit: 100, offset: 0, include_results: false` in a supervised child), cached by `{task_id, node}`: tab round-trips, reloads and merge-check results never refetch it.
The tab badge reads `@archive_label_total` (`label_total/1` = the server total when a page reported one, `max(server_total, effective_total)`, else the effective total).
Loaded pages accumulate behind a RETENTION WINDOW of `EvoDashWeb.ArchiveHelpers.max_retained/0` = 500 entries (5 × the page size): the most RECENT 500 stay in `archive_records` and the evicted count accumulates in `archive_dropped`, so a multi-thousand-agent task stays bounded.
"Load more" appends the next page at `offset = archive_fetched` (cumulative RAW rows received, never the retained count); a retried/overlapping page is deduped by `agent_id`.
The pager predicate is `EvoDashWeb.ArchiveHelpers.more_pages?(retained, dropped, effective_total)` combined with `not archive_exhausted?`.
Exhaustion: a page returning FEWER rows than the limit (empty included) sets `archive_exhausted?` and clamps the EFFECTIVE total to `dropped + retained`; a page without any usable total is accepted as fully loaded (`total: length(entries) + offset`).
An append failure keeps the loaded page and renders an inline error + Retry (the same event); a first-page failure renders the retry-able error state with the counters reset.
No paged entry carries its heavy `result`: "Show result" fetches ONE agent's full entry on demand, caches it by `agent_id` and folds it into the loaded page (`ArchiveHelpers.merge_entry/2`), rendered through the same 8 KB `blob_preview` cap. Rendering NEVER fetches.
A `{:task_updated, task_id, _, node}` broadcast for the reviewed task on the viewed node drops the per-agent result cache (`invalidate_agent_results/1`, which also strips the folded results so they can be refetched) while the loaded pages and total stay.
A task/node change (`sync_context/1`, called at the top of `start_async_load/2`) resets pages, total, the retention/offset counters and per-agent results, and refetches only when the Archive tab is visible AND the new task opted in.
The Export JSON link renders only after a `:loaded`, non-empty archive (`export_available?/1`); its href is node-aware (`?node=<target_id>` on a remote node, the bare path locally).
The archived tree is capped at 300 records per render and records whose `parent_id` is on an unloaded page are promoted to top-level nodes (never dropped).
There is no polling and no automatic retry on this path.

## Auto merge-conflict resolution

Each per-repo card renders a merge-status block driven by that repo's `merge_status`; `MergeCheck` owns the logic and the page's clauses are thin wrappers sharing `repo_available?/2`.
After the load result, `maybe_start/1` spawns one non-mutating `check_merge/4` per repo under the same gates the cards render with, skipping a repo already checking the same target.
`{:ok, :clean}` → `%{state: :clean, files: []}`, `{:ok, {:conflict, files}}` → `%{state: :conflict, files: files}`, `{:error, _}` → `%{state: :error}`; stale messages are dropped.
`auto_resolve` is PRIMARY-scoped: `MergeCheck.auto_resolve_payload/1` (pure, guarded on the primary's `:conflict` with a binary target) yields `%{opts:, to:}` with `[path:, mode: "simple", objective: <plain interpolated prompt, NOT gettext>, starting_commit:, merge_from: task_id, merge_target:]`; the handler runs `Actions.auto_resolve/3` off-process (best-effort `set_review_status(:continued)` then `start_task/3`) and navigates on success.
`merge_target_change` updates the changed repo's `default_merge_target` (blank → `"primary"`) and re-runs that repo's check. The manual per-repo Merge button + conflict flash remain the fallback.

## SHAs and the resume flow

Base/end commits come from `EvoGit.TaskInfo`'s `base_sha`/`commit_sha` (nil until review metadata is persisted) and the task result's `commit_sha`/`branch_name`, all PRIMARY-scoped; `LoadData.build_assigns/3` falls back to `task.commit_sha`, derives `base_sha` from `load_review_metadata` or `task.base_sha`, and fires a primary-scoped `set_review_metadata` when loading from a live branch. Post-merge/reject the page reloads diffs/commits from the persisted SHAs, foreign repos using their per-repo `base_sha` (skipped when nil).
`resume` is PRIMARY-scoped: the action writes review_status `:continued` off-process, then the success branch navigates to `/projects?resume_from=<task_id>&starting_commit=<sha>&project=<repo_path>[&node=<id>]` (manual `&node=` suffix — the URL already has a query string).
`ProjectsLive` reads those params into `@task_starting_commit`/`@task_resume_from`, expands Advanced Options, restores the foreign repos (locally via `maybe_restore_foreign_repos_from_task/2`, remotely inside `ProjectFlow.spawn_remote_project_activation/3`) and threads `:starting_commit`/`:resume_from` into `TaskRegistry.start_task(:evolve, opts)`; backend: `ResumeContext.apply_resume_context/3` → `Runtime.Evolution.run/2`.

## Terminal outcomes & the outcome banner

`LoadData` carries three outcome facts computed from the already-fetched task (no extra RPC): `outcome` (`Outcome.classify(task.status)`), `task_error` (the structured failure record, `nil` unless it is a map) and `has_report` (the agent summary is a non-blank binary).
`mount` seeds `outcome: nil, task_error: nil, has_report: false`, and the `{:review_data_loaded, …}` ERROR branch resets them (plus `is_no_changes: false`) because the error panel replaces the page.
The page passes `node_name={@current_node_name}`, `show_review_status={@outcome != :failed}` and `stats={if Outcome.show_stats?(@stats, @outcome), do: @stats}` to `page_header`, renders `task_outcome_banner` directly under it (with `has_changes={not @is_no_changes}` and `diagnostics_url` = `~p"/tasks?#{params}"` where `params = %{task: task_id} |> maybe node`), gates `diff_stats_bar` on `show_stats?/2`, and threads `actions_allowed={Outcome.actions_allowed?(@outcome)}` + `task_outcome={@outcome}` into `repo_cards` while `task_actions` gets `no_changes={Outcome.dismissable?(@outcome, @is_no_changes)}` and `branch_exists={@branch_exists and Outcome.actions_allowed?(@outcome)}`.
`is_no_changes` stays the RAW fact (no repo produced a branch); the outcome matrix decides what may be said and offered about it.

The matrix and its wording (every row is the page a history row lands on):
- `:completed` WITH changes — unchanged behaviour: report, per-repo changes, one Merge + Reject per change-bearing repo, `merge_check` dry run. No banner.
- `:completed` with NO report (`result` nil or no agent summary) — banner `data-outcome="completed"`: "No agent report recorded" / "This task ended as <Status> without an agent report." plus the diagnostics link. Never worded as a failure or a cancellation.
- `:completed` with no changes in ANY repo — the repo cards say "No code changes in this repository." per repo and `task_actions` promotes "Mark as read"; a writable foreign repo that DID change keeps its own Merge + Reject, so "no changes in this repository" is never generalised to the task.
- `:failed` (force kill included) — banner `data-outcome="failed"` states the status, the failure record ("Kind: …", "Source: …", the message) and "No agent report was recorded for this run." when none exists; the review-status badge is hidden, the diff-stat row is hidden unless diff data actually exists, every repo card renders the outcome note instead of its action row, and `branch_exists` is ANDed false so Create PR / Extract Skills / View PR are withheld. No Merge/Reject anywhere and no "Mark as read".
- `:cancelled` (graceful) — banner `data-outcome="cancelled"` reports the preserved changes as still mergeable ("Its preserved changes can still be reviewed and merged below.") or, with nothing reviewable, points at the agent report and archive; a no-branch repo reads "This repository produced no changes — the task was cancelled.", never "no changes" plain, and never "Mark as read".
- Branch unrecoverable vs diff still readable (`:handled` or a vanished branch) — the wording distinguishes "the branch was deleted, but its changes are still viewable read-only in the diff tabs" from "the branch is gone and its changes are no longer recoverable", and no merge is offered once the branch cannot be resolved.
- Unknown/absent outcome (`nil`, `:running`, an unmapped status) — `Outcome.classify/1` answers `:other`: no banner, no action withholding, the raw status renders as before.

The `resume` EVENT name is historical and unchanged: its button label is "Prepare follow-up task" because the action seeds a NEW task from this task's result and starting commit ([它是以旧结果为基础创建新任务，不是恢复原执行]) — only the `/tasks` Paused-task action resumes the SAME task id. `phx-click="resume"` → review_status `:continued` → `/projects?resume_from=…&starting_commit=…&project=…[&node=…]`.

## Constraints

- Nothing in the LiveView process touches the store / registry / git / `EvoDash.NodeContext` — loads and actions go through `EvoDash.TaskSupervisor` children wrapped in `EvoDash.SafeCall.run/1`; add no synchronous RPC to `handle_params/3` or an event handler.
- Every spawned task must report a result message (a dead child would wedge the in-progress state); a new action needs an `ActionResults` handler (registered in `@handlers`), a `Runner.clear/3` shape, and its `review_action`/`busy_repos`/`action_loading` decision.
- A new client event must be registered in `Events.@handlers` (and a new tab in `Tabs.@tab_params`); an unregistered event stays a no-op, and client input is never atomized.
- Diffs stay lazy — never fetch full diffs on page load.
- Merge/reject act on ONE repo per event, each repo carrying its own `resolution`; completion is the aggregate `completion_status/2` over the change-bearing repos.
- PRIMARY-scoped operations must resolve the `"primary"` entry explicitly, never the active-repo-projected flat assigns.
- Repo-keyed state on SHOW (`selected_file`/`expanded_files`/`file_context_levels`/`tree_expanded_dirs`); flat on `:commit`.
- `?node=` is preserved on every navigation (`with_node_param/2`; manual `&node=` when the URL already carries a query string).

## `:awaiting_input` sessions

The review page carries NO cancel / force-kill gates, so the non-terminal `:awaiting_input` status needs no extra admission here: its violet badge and label come from the shared `Helpers.task_status_badge/1`.
An idle interactive session holds no reviewable `genesis/agent_*` branch until it closes, so it never satisfies the `:completed` review candidacy and no review action is offered while it waits.
Closing a session from its task card (TasksLive) finalizes the task into its normal terminal status, after which the ordinary review flow applies.

<!-- genesis:local -->

## Payload audit (consumed vs transferred)

- `get_task_lite/2`: consumed = `opts[:path]`/`opts[:prompt] || opts[:objective]`/`opts[:foreign_repos]`, the result's `commit_sha`/`branch_name`/`result`/`pr_url`/`pr_title` plus the top-level `repos` map (both key shapes), `review_status`, `status`, `base_sha`, `commit_sha`, `usage`, `agent_count`, `model_id`, `started_at`, `finished_at`. `logs` is transferred but never read; NO archive is transferred.
- `list_task_archives/3` (Archive tab only): pages of `%{entries: [STRING-keyed map], total: non_neg_integer}` with `include_results: false`; `get_agent_archive/3` transfers ONE full entry (including `result`) only for an explicit "Show result".
- `load_review_metadata*` (8-key map): consumed = `base_sha`, `changed_files_count`, `total_additions`, `total_deletions` and per-file `path`/`status`/`additions`/`deletions`/`language`/`diff`. Transferred-but-never-read: top-level `commit_sha`, `diff_stat`, `diff` (nil).
- `list_commits*` (6-field `%CommitInfo{}`): consumed = `sha`, `short_sha`, `message`, `author_name`, `date`; `author_email` unused.
- Action RPCs run inside the spawned task, ONE call per repo acted on (`merge_all` fans out one per unresolved change-bearing repo), and only ok/error tags and flash-relevant values are consumed.
- **Gotcha**: `default_merge_target/2` returns `{:ok, name}`; `LoadData` matches that shape.

## Test strategy

Tests must flush the async load before asserting content: the file-local `flush_review_load/2` drains the mount-time async messages and then delegates to the shared `EvoDashWeb.TestHelpers.flush_loading/4`, polling the `Loading review data...` marker (`render_async/2` does NOT work — the load runs in a plain `Task.Supervisor` child); `settle_debounced_task_reload/1` covers the 300ms reload and `wait_until/2` post-send synchronization.
Direct `send(view.pid, {:review_data_loaded, task_id, node(), generation, {:ok, assigns}})` injects results (stale-guard cases use a wrong task/node/generation). Merge-check assertions inject the 6-tuple (or let the load land first, since `maybe_start/1` runs only after it).
Multi-repo coverage: repo-list construction, per-repo merge/reject through the runner seams (the stubbed runner messages the test with its call args), `merge_all` batch folding (one runner call per unresolved change-bearing repo + one summary flash), 6-tuple merge-check injection, and foreign-repo carry for auto-resolve/resume.
