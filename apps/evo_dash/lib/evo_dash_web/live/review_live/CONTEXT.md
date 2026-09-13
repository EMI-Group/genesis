# ReviewLive — Review Page

## Intent

`EvoDashWeb.ReviewLive` (`review_live.ex`, `GET /review/:task_id`) — GitHub-PR-inspired code review page. **Two-page model**: the `:show` route renders a `page_header` + `page_tabs` + one of FIVE tab bodies (`:conversation | :objective | :files_changed | :commits | :archive`); the `:commit` route (`/review/:task_id/commit/:sha`) renders a standalone commit-inspection page (`commit_detail_header` + `commit_diff_layout`, no page tabs, no separate back-button row — the back link lives inside `commit_detail_header`). The objective renders on its own dedicated **`:objective` tab** (a readability column hosting `objective_section`, with the `objective_raw` markdown/raw toggle + copy button) — it no longer lives in the conversation pane. **Multi-repo review**: tasks with writable foreign repos expose repo selection in the Files-changed toolbar + the merge box (NOT a page-level tab bar); merge/reject broadcast across ALL review repos; single-repo (legacy) tasks render with no repo affordances. All page data loads ASYNC (off-process); per-file diffs are LAZY (per-event).

## Routing Table

None — leaf directory (`load_data.ex`, `merge_check.ex`).

## API Surface

| Module | Purpose |
|--------|---------|
| `EvoDashWeb.ReviewLive.LoadData` (`load_data.ex`) | Async review-data load, runs in `EvoDash.TaskSupervisor` children. `load/3` (`node, task_id, opts` with `live_action:`/`inspect_commit_sha:` opts) → `{:review_data_loaded, task_id, node, generation, result}` with `{:ok, assigns_map} \| {:error, reason}` (error strings pre-gettext-wrapped). `build_assigns/3` builds the `@review_repos` list (one entry per reviewable repo, primary first) plus `active_repo_id`; `commit_inspection/3` (the `:commit` route) is PRIMARY-repo-scoped. The load-result map does NOT include `tree_expanded_dirs`/`file_filter` (mount-seeded only) — the tree/filter state survives debounced reloads by construction. `repo_available?/2` and `branch_exists_on_node?/3` take `node` (not a socket). |
| `EvoDashWeb.ReviewLive.MergeCheck` (`merge_check.ex`) | Async non-mutating merge-conflict dry-run (`check_merge/4` → `{:ok, :clean} \| {:ok, {:conflict, files}} \| {:error, reason}}`), started AFTER the load result. **Multi-repo aware**: `maybe_start/1` spawns ONE `check_merge/4` per review repo under the same gates the merge box renders with (branch exists, `merge_targets != []`, target binary, `repo_available?/2`), each tagged with its `repo_id`; results arrive as 6-tuples `{:merge_check_result, task_id, node, repo_id, target, result}`. Also hosts `repo_available?/2` and `handle_auto_resolve/1` (PRIMARY-scoped). |

**Component-contract boundary**: every component `review_live.ex` renders (`page_header`, `page_tabs`, `agent_summary`, `objective_section`, `diff_stats_bar`, `task_summary`, `merge_box`, `extract_skills_modal`, `split_diff_layout`, `commit_diff_layout`, `commits_list`, `commit_detail_header`, `archive_review_section`, `merge_outcomes_panel`) is defined in the SIBLING `components/review_components*` tree — its full attr/event surface is documented in `components/review_components/CONTEXT.md`. This page owns the wiring (attrs + event handlers), that tree owns the markup.

## Page model (`:show`)

`render/1` computes two values inline (no extra assigns): `stats = aggregate_stats(@review_repos)` and `primary = Enum.find(@review_repos, &(&1.repo_id == "primary"))`.

- **`page_header`** — PRIMARY-scoped fields (`repo_path`/`branch_name`/`merge_target` = primary's `default_merge_target`/`commit_sha` from the `"primary"` entry explicitly, never the active-repo projection), `back_url = with_node_param(~p"/projects", @current_node_id)`, full `title`, task/review status + meta, `stats` (aggregate map, see below).
- **`page_tabs`** — underline tab bar with count badges driven by the AGGREGATE stats (`files_count`, `commits_count`), `show_archive` (gates the archive tab), `agents_count` (= `@agent_count`).
- **`:conversation`** — readability column `max-w-4xl mx-auto w-full space-y-4`, in order: `merge_outcomes_panel` (when `@merge_outcomes != []`) → `agent_summary` → `diff_stats_bar` (aggregate) → `task_summary` → **`merge_box` AT THE BOTTOM** → `extract_skills_modal`.
- **`:objective`** — readability column `max-w-4xl mx-auto w-full space-y-4` hosting only `objective_section` (`objective:`, `objective_raw:`). The tab is ALWAYS rendered (no count badge); a nil/`""` objective shows the component's in-card empty state.
- **`:files_changed`** — FULL WIDTH (no max-w): `split_diff_layout` reading the ACTIVE repo's repo-keyed submaps via inline `Map.get` (`expanded_files`/`selected_file`/`file_context_levels`/`tree_expanded_dirs` — same keying as the diff state), plus flat `file_filter`, `repos: @review_repos`, `active_repo_id:`. Repo selection lives in the layout's toolbar. nil `@review_data` → the empty-state icon panel.
- **`:commits`** — `commits_list commits: @commits` (ACTIVE repo's commits — repo switching lives in the files toolbar / merge box).
- **`:archive`** — `archive_review_section` (existing empty state when no metadata).
- Trailing warning block (branch_exists && nil review_data && !loading) kept, restyled `rounded-xl border-warning/30 bg-warning/10`.

**Aggregate stats** — private `aggregate_stats/1` sums EVERY repo's `review_data.changed_files_count/total_additions/total_deletions` (repos with nil review_data contribute 0) plus `length(repo.commits)`; result `%{files_count:, additions:, deletions:, commits_count:}`. Consumed by `page_header` (stat row), `page_tabs` (count badges), and the conversation `diff_stats_bar` — never the active repo alone, so the numbers are stable across repo switches.

## Multi-repo review (writable foreign repos)

The core writes writable-foreign-repo results into the task result's top-level `repos` map (`%{repo_id => %{"commit_sha" => sha, "branch_name" => branch \| nil}}`, STRING keys); the review page turns each such repo into a review entry.

- **Repo list construction** (`load_data.ex` `build_review_repos/7`): `@review_repos` is a list of per-repo maps `%{repo_id:, repo_path:, branch_name:, commit_sha:, base_sha: (String.t()\|nil), branch_exists:, review_data: (map\|nil), commits:, merge_targets:, default_merge_target:, merge_status:}`, **primary FIRST**. Foreign entries come from `task.opts[:foreign_repos]` normalized via `EvoGit.Core.ForeignRepo.normalize/1`; only repos present in `repos` with a non-nil branch_name get an entry. **Legacy tasks (no `repos` key) → exactly one primary entry**. `active_repo_id` defaults `"primary"`.
- **Repo selection is component-owned**: no page-level `repo_tabs`. The Files-changed toolbar (`split_diff_layout`), the merge box (`merge_box`), and the Commits tab (`commits_list` — toolbar above the card) render the selector from `repos:`/`active_repo_id:` attrs, shown only when `length(@repos) > 1`. Each selector is a `<select name="repo_id">` wrapped in its OWN `<form phx-change="switch_repo">` (ids `diff-repo-switch-form`/`repo-switch-form`/`commits-repo-switch-form`) — a form-less `<select phx-change>` NEVER delivers its event (LiveView JS `pushInput` throws "form events require the input to be inside a form"); the form-level change serializes the field by `name` → `%{"repo_id" => id}`. `switch_repo` has TWO clauses — `%{"repo_id" => id}` (form-wrapped selects) and `%{"value" => id}` (defensive legacy form-less shape) — both delegating to one private `switch_repo/2` that whitelist-validates against `@review_repos` ids (never `String.to_atom` on client input), sets the active id, **clears `file_filter`** (shared filter never leaks stale text into the new repo's list), and re-projects the flat assigns via `project_active_repo/1`.
- **Flat projection** (`project_active_repo/1`): the flat assigns (repo_path/branch_name/commit_sha/base_sha/branch_exists/review_data/commits/merge_targets/default_merge_target/merge_status) are projected from the ACTIVE repo; NO-OP on the `:commit` route. The diff/tree state maps are NOT re-projected — the template reads the active submap inline.
- **PRIMARY-scoped operations**: `resume`, `create_pr`, `confirm_extract_skills`, `auto_resolve`, `set_review_metadata`, the `:commit` route, and the `page_header` repo fields all resolve the `"primary"` entry explicitly (documented limitation — never the active-repo projection).
- **Merge broadcast** (`handle_event("merge")`): submits for ALL repos in `@review_repos`, each with its OWN target — the submitting repo comes from the merge form's hidden `repo_id` input (fallback `@active_repo_id`, then `"primary"`; whitelist-validated), its target validated against ITS `merge_targets` with fallback to its `default_merge_target`; every other repo merges into its own `default_merge_target`. Test seam `:review_merge_runner` (app-env, resolved AT CALL TIME). ALL `{:ok,_}` → `set_review_status(:merged)` + success flash + `push_navigate` to /projects (preserving `?node=`) + `invalidate_active_tasks/1`. ANY conflict/error → `@merge_outcomes` + summary error flash, STAYS on page.
- **Reject broadcast symmetric**: `:review_reject_runner` seam, call-time; ALL `:ok` → navigate; partial → `@merge_outcomes` + flash, stays. The `reject` handler consumes NO params (`handle_event("reject", _params, socket)`) — it deletes EVERY review repo's branch, so no repo-scoped reject is possible without changing that clause.
- **Single global merge box**: `merge_box/1` has exactly ONE render site (`:conversation` tab, after `task_summary`) fed the ACTIVE-repo flat projection (`@repo_id`/`@merge_targets`/`@default_merge_target`/`@merge_status`), while `repos: @review_repos` carries every repo's own `merge_targets`/`default_merge_target`/`merge_status`/`branch_exists` — the per-repo data needed for one merge box per repo already exists; only the render site and the `merge`/`reject` broadcast handlers are single/global.
- **MergeCheck per-repo**: one async dry-run per repo tagged `repo_id`; 6-tuple `{:merge_check_result, task_id, node, repo_id, target, result}`; `handle_auto_resolve/1` PRIMARY-scoped.

## Async load contract

- `handle_params/3` dedup guard `tasks_loaded_for == {current_node, live_action, params["commit_sha"]}` → private `start_async_load/2` sets `@loading` and spawns `Task.Supervisor.start_child(EvoDash.TaskSupervisor, ...)`. NO synchronous RPCs in `handle_params/3`.
- Load sequence: `get_task/2` → per repo (primary first): `list_branches/2` + `default_merge_target/2` → `branch_exists?/3` → `load_review_metadata/3` or `load_review_metadata_from_shas/4` (post-merge path, per-repo `base_sha`) → `list_commits/3` or `list_commits_from_shas/4`; fire-and-forget `set_review_metadata/4` (primary-scoped) when SHAs just persisted. The `:commit` route additionally runs primary-scoped commit inspection and adds `inspect_commit_sha`/`commit_header`/`commit_data`.
- Result map: ~30 template assigns + resets `expanded_files: %{}`/`file_context_levels: %{}`/`selected_file: nil`. `tree_expanded_dirs`/`file_filter` are NOT in the map (mount-seeded) → they survive reloads.
- **Stale-guard** (`{:review_data_loaded, task_id, node, generation, result}`): drop unless `task_id == @task_id` and `node == @current_node` and `generation >= @load_generation` (monotonic). On `{:ok, assigns_map}` assign the map, reset `@merge_outcomes` to `[]`, THEN run `MergeCheck.maybe_start/1`; on `{:error, reason}` assign the error state and skip MergeCheck.
- Justified `try/rescue` at the async boundary only (node-boundary RPC to a possibly-dead remote daemon / task deleted mid-load; the alternative is the page wedging at loading forever — mirrors `merge_check.ex`).

## Diffs are LAZY — never eager

`load_review_metadata*`/`load_commit_files` return per-file `%EvoGit.Review.FileInfo{}` with `diff: nil` (numstat metadata only); per-file `load_file_diff/5,/6` (or `load_commit_file_diff/4` on the commit view) runs only on the `select_file`, `toggle_file_expansion`, `load_file_diff`, and `expand_context` (larger `:context` opt) events. Tab switches, tree toggles, and filter typing are pure assigns, no RPC. On SHOW the diff-state maps (`selected_file`/`expanded_files`/`file_context_levels`) AND the tree state (`tree_expanded_dirs`) are repo-keyed; `update_file_diff_in_socket/4` swaps only the file's `diff` field in the ACTIVE repo's entry. The `:commit` route keeps legacy flat path-keyed state — including `tree_expanded_dirs`, read directly as the flat dir-keyed map (no `"commit"` key; same convention as the flat `expanded_files`).

## Files-changed toolbar state (tree + filter)

- **`tree_expanded_dirs`** — `%{dir_path => true}` expansion state. SHOW: repo-keyed outer map (`%{repo_id => %{dir => true}}`), toggled per repo via `toggle_dir` (put/delete in the active repo's submap). `:commit`: flat dir-keyed map. `collapse_all_dirs` sets the acting submap (or flat map) to `%{}`; `expand_all_dirs` merges ALL ancestor directory paths of the acting file list (private `all_dir_paths/1` → `dir_chain/2`: every `Path.dirname` chain segment except `"."`) as true. Read in render via inline `Map.get(@tree_expanded_dirs, @active_repo_id, %{})` on SHOW, `@tree_expanded_dirs` directly on `:commit`.
- **`file_filter`** — shared filter string; `filter_files` assigns `%{"filter" => value || ""}` (debounced on the client by the component's `phx-debounce`); `switch_repo` resets it to `""`.
- Both are mount-seeded and deliberately absent from the load-result map (survive debounced reloads).

## Events handled by ReviewLive

| Event | Route branching | Notes |
|-------|-----------------|-------|
| `switch_tab` (`conversation`/`objective`/`files_changed`/`commits`/`archive` + fallback no-op) | — | Pure assigns. |
| `switch_repo` %{"repo_id"} or %{"value"} | — | Whitelist + set active + reset `file_filter` + re-project; unknown id → no-op. |
| `toggle_dir` %{"dir"} | SHOW repo-keyed / `:commit` flat | put/delete in the tree map. |
| `collapse_all_dirs` | same | acting submap → `%{}`. |
| `expand_all_dirs` | same | merge `all_dir_paths(files)` into the acting submap. |
| `filter_files` %{"filter"} | — | assign `file_filter`. |
| `select_file` %{"path"} | SHOW repo-keyed / `:commit` flat | sets `review_tab: :files_changed` + `push_event("scroll_to_file", %{target_id: "file-section-#{file_path_to_id(path)}"})` + lazy diff load. |
| `toggle_file_expansion` %{"path"} | same | lazy diff load when expanding. |
| `load_file_diff` %{"path"} | same | lazy diff load. |
| `expand_context` %{"path"} | same | re-fetch with wider context; `update_file_diff_in_socket/4`. |
| `inspect_commit` %{"sha"} | — | `push_patch` to the `:commit` route. |
| `merge` (form: hidden `repo_id` + `target_branch`) | — | Per-repo broadcast merge plan (`:review_merge_runner`). |
| `merge_target_change` | — | Delegates to `MergeCheck.handle_target_change/2` + re-project. |
| `auto_resolve` | — | Delegates to `MergeCheck.handle_auto_resolve/1` (PRIMARY-scoped). |
| `reject` | — | Broadcast reject (`:review_reject_runner`). |
| `resume` | — | PRIMARY-scoped; navigates to `/projects?resume_from=…&starting_commit=…&project=…[&node=]` (manual `&node=` — URL already has a query string). |
| `ignore` | — | `set_review_status(:ignored)` + navigate. |
| `create_pr` | — | PRIMARY-scoped; synchronous under `@action_loading`. |
| `extract_skills` / `cancel_extract_skills` / `confirm_extract_skills` | — | Modal flow; confirm is PRIMARY-scoped, starts an `:extract_skills` task. |
| `toggle_summary_view` %{"mode"} | — | `summary_raw` toggle. |
| `toggle_objective_view` %{"mode"} | — | `objective_raw` toggle (Objective tab's Markdown/Raw join). |
| `copied` | — | clipboard flash. |
| `retry_remote_connection` / `switch_to_local` | — | gate actions. |

## Consumed-vs-transferred (payload audit)

- `get_task/2`: consumed = `opts[:path]`/`opts[:prompt]||opts[:objective]`/`opts[:foreign_repos]`, `result` keys (commit_sha/branch_name/result/pr_url/pr_title + top-level `repos` — both `:repos`/`"repos"` key shapes), `review_status`, `status`, `base_sha`, `commit_sha`, `archive_metadata`, `usage`, `agent_count`, `model_id`, `started_at`, `finished_at`. `logs` transferred but never read.
- `load_review_metadata*` (8-key map): consumed = `base_sha`, `changed_files_count`, `total_additions`/`total_deletions` (now read via `aggregate_stats/1` per repo), `files` (per-file `path`/`status`/`additions`/`deletions`/`language`/`diff`). Transferred-but-never-read: top-level `commit_sha`, `diff_stat`, `diff` (nil).
- `list_commits*` (6-field `%CommitInfo{}`): consumed = sha, short_sha, message, author_name, date. `author_email` unused.
- `check_merge/4` → per-repo `merge_status` `%{state:, target:, files:}`; `target` server-side only.
- One-shot event RPCs (synchronous in the LiveView, looped per repo on merge/reject): `merge_branch/3,4` via `:review_merge_runner`, `reject_branch/3` via `:review_reject_runner`, `create_github_pr/5`, `start_task/3` (Extract Skills + auto-resolve), `set_review_status/3`, `set_review_metadata/4` — only ok/error tags and flash-relevant values consumed.
- **Gotcha**: `default_merge_target` actually returns `{:ok, name}` — LoadData matches `{:ok, name}`.

## Test strategy

Tests assert content synchronously after `live()`/`render()` would see the `@loading` spinner — flush the async load first: the file-local `flush_review_load/2` polling helper (polls `render(view)` until the spinner disappears — `render_async/2` does NOT work here, the load runs in a plain `Task.Supervisor` child, not a LiveView async task) + `wait_until/2` for post-send synchronization. Direct `send(view.pid, {:review_data_loaded, task_id, node(), generation, {:ok, assigns}})` injects results (stale-guard cases use wrong task/node/generation). Merge-check assertions additionally need the 6-tuple `{:merge_check_result, task_id, node(), repo_id, target, result}` message (or the loaded result first — `MergeCheck.maybe_start` runs only after the load result). Multi-repo coverage: repo-list construction, per-repo merge/reject broadcast via the runner seams, 6-tuple merge-check injection, foreign-repo carry for auto-resolve/resume. NOTE: the render layer now calls the NEW component surface (`page_header`/`page_tabs`/`merge_box`/etc.) — LiveView render tests must be updated to the new markup in the same change that lands the parallel component rewrite.

## Merge action + conflict path

The merge UI lives in the conversation column's `merge_box` (bottom). `ReviewLive.handle_event("merge", ...)` builds a per-repo merge plan and broadcasts (see Multi-repo above): ALL `{:ok, sha}` → `set_review_status(:merged)` + success flash (mentions the effective target of the submitting repo) + `push_navigate` to `/projects`; ANY `{:conflict, details}`/`{:error, reason}` → `@merge_outcomes` per repo + summary error flash, page STAYS. The `{:conflict, _}` tag originates from the Git adapter's exit-code-1 mapping; `merge_into_current` leaves a repo mid-merge on conflict (no abort helper), `merge_into_other` force-restores the original branch. The conflict path is covered by evo_dash tests via the `:review_merge_runner` seam.

## Auto merge-conflict resolution (async merge check + auto-resolve)

The merge box renders a merge-status block (driven by the ACTIVE repo's projected `@merge_status`). The logic lives in `EvoDashWeb.ReviewLive.MergeCheck`; ReviewLive's `handle_event`/`handle_info` clauses are thin wrappers and the `repo_available?/2` gate is shared (no duplication). After the review-data load result, `maybe_start/1` spawns `EvoGit.RemoteNode.check_merge/4` (non-mutating dry-run) in a supervised Task for EVERY repo under the same gates the merge box renders with, skipping duplicates already `:checking` the same target. Each result arrives as `{:merge_check_result, task_id, node, repo_id, target, result}`; `handle_result/6` maps `{:ok, :clean}` → `%{state: :clean, files: []}`, `{:ok, {:conflict, files}}` → `%{state: :conflict, files:}`, `{:error, _}` → `%{state: :error}` (renders nothing), and drops stale messages. `auto_resolve` (PRIMARY-scoped, guarded on the primary's `:conflict` state, else error flash): `set_review_status(:continued)`, then `start_task(node, :evolve, [path:, mode: "simple", objective: <plain interpolated prompt — NOT gettext>, starting_commit:, merge_from: task_id, merge_target:])` — the backend handles the merge task and carries over foreign repos. Success → flash + `push_navigate` to `/projects` preserving `?node=`; error → flash, stays. `merge_target_change` updates the changed repo's `default_merge_target` (params `repo_id`, blank → `"primary"`) and re-runs that repo's check. The manual Merge button + conflict flash remain the fallback.

## SHAs

The page's base/end commits come from `EvoGit.TaskInfo` fields `base_sha`/`commit_sha` (both nil until review metadata is persisted) and the task result map's `commit_sha`/`branch_name` — all PRIMARY-scoped. `LoadData.build_assigns/3` falls back to `task.commit_sha`, derives `base_sha` from `load_review_metadata` or `task.base_sha`, and persists both via `set_review_metadata` (primary-scoped fire-and-forget) when loading from a live branch. Post-merge/reject the page re-loads diffs/commits from the persisted SHAs — foreign repos use their per-repo `base_sha` (skipped when nil).

## Resume flow

`handle_event("resume", ...)` is PRIMARY-scoped — repo-scoped fields come from the `"primary"` entry explicitly. It sets review_status `:continued` and `push_navigate`s to `/projects?resume_from=<task_id>&starting_commit=<commit_sha>&project=<repo_path>[&node=<id>]` (manual `&node=` suffix — the URL already has a query string). `ProjectsLive.handle_params/3` reads those query params into `@task_starting_commit`/`@task_resume_from` (auto-expanding Advanced Options + `maybe_restore_foreign_repos_from_task/1`), and `do_task_submit/4` threads `:starting_commit`/`:resume_from` into `TaskRegistry.start_task(:evolve, opts)`. Backend: `ResumeContext.apply_resume_context/3` → `Runtime.Evolution.run/2`.

KNOWN GAP (remote-node resume): when the reviewed task belongs to a remote node, the resume URL carries a REMOTE `project` path + `&node=<id>`, but ProjectsLive's remote `handle_params` branch deliberately skips `params["project"]` (no URL-driven remote activation — the only remote activation is the palette-driven async flow), and `maybe_restore_foreign_repos_from_task` queries the LOCAL `TaskRegistry` (nil for a remote task). The landing page therefore shows NO active project (task form disabled) and no restored foreign repos. The daemon-side `ResumeContext.apply_resume_context/3` would still carry repos at task start, but the task can't be launched without an active project. Tests cover only the LOCAL resume redirect (review_live_test.exs:1981-2054); there is no remote-resume test.

## Async patterns available on this page

(1) `EvoDash.TaskSupervisor` + `Task.Supervisor.start_child(fn -> ... send(parent, {:result_tag, value}) end)` + a matching `handle_info` — the canonical load/merge-check pattern. (2) `action_loading` boolean assign around the synchronous `create_pr` call. (3) PubSub: `Phoenix.PubSub.subscribe(EvoGit.PubSub, "tasks")` in mount + `NodeAware.handle_task_info/2` 300ms trailing-edge debounce → `handle_info(:node_aware_reload_tasks)` (broadcast-guarded: only the reviewed task's own broadcasts re-fetch review data). (4) `push_event` client hooks (`scroll_to_file` with `target_id: "file-section-#{file_path_to_id(path)}"`, consumed by the `DiffViewer` JS hook).

**Module sizes (deliberate, per Genesis file-size policy)**: `review_live.ex` is ~1450 lines — a cohesive single-page LiveView (render + all review operations incl. per-repo merge/reject broadcast and the files-toolbar tree/filter state; the multi-repo integration is inlined here by design — do not split; the async merge-check/auto-resolve logic lives in `review_live/MergeCheck`, the load in `review_live/LoadData`). `node_context.ex` ~870 lines. **Remaining known gap**: `handle_info(:node_aware_reload_tasks)` fires on task PubSub broadcasts, which may not cross nodes reliably — the review page itself is loaded once at navigation and doesn't poll remote nodes (acceptable: review data is static after completion).

## Constraints

- The async load is the ONLY way the page fetches data — do not add synchronous RPCs to `handle_params/3`.
- Diffs stay lazy — never fetch full diffs on page load.
- Merge/reject are broadcast over ALL `@review_repos`; PRIMARY-scoped operations (`resume`, `create_pr`, `confirm_extract_skills`, `auto_resolve`, `set_review_metadata`, the `:commit` route, the `page_header` repo fields) must resolve the `"primary"` entry explicitly, never the active-repo-projected flat assigns.
- Repo-keyed state on SHOW (`selected_file`/`expanded_files`/`file_context_levels`/`tree_expanded_dirs`); flat on `:commit` (including `tree_expanded_dirs` — no `"commit"` key convention; the flat map is read directly).
- `?node=` preserved on every navigation (`with_node_param/2`; manual `&node=` when the URL already carries a query string — resume).
- Follows the project-wide `try/rescue` anti-pattern policy; the async-boundary rescue is the accepted exception (justified comment in code).
