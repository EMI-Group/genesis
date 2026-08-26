# ReviewLive — Review Page

## Intent

`EvoDashWeb.ReviewLive` (`review_live.ex`, `GET /review/:task_id`) — GitHub-style code review page: PR title, agent summary, commit list, client-side highlighted diffs (highlight.js), merge/reject/resume actions, optional GitHub PR creation, and Extract Skills (starts an `:extract_skills` task via `TaskRegistry` that spawns a `SkillExtractor` agent to distill PR knowledge into `.agents/skills/` files). All page data loads ASYNC (off-process); per-file diffs are LAZY (per-event).

## Routing Table

None — leaf directory (`load_data.ex`, `merge_check.ex`).

## API Surface

| Module | Purpose |
|--------|---------|
| `EvoDashWeb.ReviewLive.LoadData` (`load_data.ex`) | Async review-data load, runs in `EvoDash.TaskSupervisor` children. `load/3` (`node, task_id, opts` with `live_action:`/`inspect_commit_sha:` opts) → `{:review_data_loaded, task_id, node, generation, result}` with `{:ok, assigns_map} \| {:error, reason}` (error strings pre-gettext-wrapped: "Task not found. It may have been deleted." / "Failed to load review data."). `repo_available?/2` and `branch_exists_on_node?/3` take `node` (not a socket). |
| `EvoDashWeb.ReviewLive.MergeCheck` (`merge_check.ex`) | Async non-mutating merge-conflict dry-run (`check_merge/4` → `{:ok, :clean} \| {:ok, {:conflict, files}} \| {:error, reason}`), started AFTER the load result. `maybe_start/1` (`merge_check.ex:42-69`) spawns ONE `check_merge/4` in a supervised task, dedup-guarded on `merge_status.state == :checking` for the same target. |

## Async load contract

- `handle_params/3` dedup guard `tasks_loaded_for == {current_node, live_action, params["commit_sha"]}` (the tuple includes the route so the `:commit` push_patch re-loads) → private `start_async_load/2` (`review_live.ex:819`) sets `@loading` and spawns `Task.Supervisor.start_child(EvoDash.TaskSupervisor, ...)`.
- Load sequence: `get_task/2` → `list_branches/2` + `default_merge_target/2` → `branch_exists?/3` (only when branch_name + repo available) → `load_review_metadata/3` (branch path) or `load_review_metadata_from_shas/4` (post-merge/reject path) → `list_commits/3` or `list_commits_from_shas/4`; plus a fire-and-forget `set_review_metadata/4` write when SHAs were just persisted. The `:commit` route (`/review/:id/commit/:sha`) additionally runs commit inspection (header lookup from the just-loaded commits with `%EvoGit.Review.CommitInfo{}` fallback + `NodeContext.load_commit_files` degrade-to-nil) and adds `inspect_commit_sha`/`commit_header`/`commit_data` — the whole navigation load stays off the LiveView process.
- Result map: ~30 template assigns (`loading: false`, `error: nil`, title/task_type/branch_name/commit_sha/base_sha/agent_summary/review_status/branch_exists/can_resume/is_no_changes/has_pr/pr_url/review_data/repo_path/objective/commits/archive_metadata/task_usage/agent_count/task_status/model_id/started_at/finished_at/merge_targets/default_merge_target/merge_status: nil` + resets `expanded_files: %{}`/`file_context_levels: %{}`/`selected_file: nil`).
- **Stale-guard** (`review_live.ex:748`): drop unless `task_id == @task_id` and `node == @current_node` and `generation >= @load_generation` (monotonic, seeded 0 in mount, incremented per `start_async_load`). On `{:ok, assigns_map}` assign the map THEN run `MergeCheck.maybe_start/1` (never from handle_params); on `{:error, reason}` assign the error state and skip MergeCheck.
- Justified `try/rescue` at the async boundary only (node-boundary RPC to a possibly-dead remote daemon / task deleted mid-load; the alternative is the page wedging at loading forever — mirrors `merge_check.ex:211-218`). All RPCs return the verbatim underlying value (only transport failures add `{:error, {kind, reason}}`).

## Diffs are LAZY — never eager

`load_review_metadata*`/`load_commit_files` return per-file `%EvoGit.Review.FileInfo{}` with `diff: nil` (numstat/shortstat metadata only); per-file `load_file_diff/5,/6` (or `load_commit_file_diff/4` on the commit view) runs only on the `select_file` (`review_live.ex:353-365`), `toggle_file_expansion` (`:368-380`), `load_file_diff` (`:383-385`), and `expand_context` (`:393-418`, larger `:context` opt) phx events. `load_review_data/3` (the eager full-diff variant) is NEVER called anywhere in evo_dash — dead path for the dashboard (only a passthrough definition exists at `node_context.ex:703`). Tab switches are pure assigns, no RPC.

## Merge-target branch selector

The merge action merges into a user-selectable branch. The async load sets `merge_targets`/`default_merge_target` (defaults `[]`/`nil` in mount) via `EvoGit.Review.list_branches/1` + `default_merge_target/1` when `repo_path` exists (plain `case` on tuple returns, no try/rescue). The `merge` handler reads `params["target_branch"]` (trimmed; non-member targets fall back to the default when a known list was loaded) and calls `EvoGit.Review.merge_branch/3`, falling back to `merge_branch/2` (default-resolving path) when no target is given. The success flash mentions the effective target branch. UI: `ReviewComponents.Actions.action_buttons/1` (see `components/review_components/CONTEXT.md`).

## Consumed-vs-transferred (payload audit)

- `get_task/2`: consumed = `opts[:path]`/`opts[:prompt]||opts[:objective]`, `result` keys (commit_sha/branch_name/result/pr_url/pr_title), `review_status`, `status`, `base_sha`, `commit_sha`, `archive_metadata`, `usage`, `agent_count`, `model_id`, `started_at`, `finished_at`. `logs` (and ref/lease_expires_at) transferred by the full TaskInfo but never read by this page.
- `load_review_metadata*` (8-key map: commit_sha, base_sha, diff_stat, diff, files, changed_files_count, total_additions, total_deletions): consumed = `base_sha` (drives the persisted-SHAs `set_review_metadata/4` write), `changed_files_count`, `total_additions`/`total_deletions`, `files` (per-file `path`/`status`/`additions`/`deletions`/`language`/`diff` in the components). Transferred-but-never-read: top-level `commit_sha`, the raw `diff_stat` string, `diff` (nil) — the diff-stats bar renders from the counts.
- `list_commits*` (6-field `%CommitInfo{}`): consumed = sha, short_sha, message, author_name, date (`commits_list` + `format_commit_history` `review_live.ex:851-859` + the commit-header lookup in `load_data.ex` `commit_inspection/3`). `author_email` transferred but unused.
- `check_merge/4` → `merge_status` `%{state: :checking|:clean|:conflict|:error, target:, files: []|paths}` (`merge_check.ex:162-192`); components read only `state` (spinner/clean banner/conflict block) and `files` (count + first-4 paths, actions.ex:198-241); `target` is server-side only (staleness + merge call).
- One-shot event RPCs (still synchronous in the LiveView): `merge_branch/3,4` (`review_live.ex:467-469`), `reject_branch/3` (`:531`), `create_github_pr/5` (`:613`), `start_task/3` (`:685`, Extract Skills) + auto-resolve (`merge_check.ex:128`), `set_review_status/3` (`:474,:533,:560,:598`), `set_review_metadata/4` (fire-and-forget, in load_data.ex) — only ok/error tags and flash-relevant values consumed (merged sha never rendered; `start_task`'s returned `%TaskInfo{}` discarded).
- **Gotcha**: `default_merge_target` actually returns `{:ok, name}` — the @specs in RemoteAPI/RemoteNode/NodeContext claiming bare `String.t()` are wrong; LoadData matches `{:ok, name}`. Field-consumption details per component: `components/review_components/CONTEXT.md` → "Field-consumption audit".

## Test strategy

Tests assert content synchronously after `live()`/`render()` would see the `@loading` spinner — flush the async load first: the file-local `flush_review_load/2` polling helper (polls `render(view)` until the spinner disappears — `render_async/2` does NOT work here, the load runs in a plain `Task.Supervisor` child, not a LiveView async task) + `wait_until/2` for post-send synchronization. Direct `send(view.pid, {:review_data_loaded, task_id, node(), generation, {:ok, assigns}})` injects results (stale-guard cases use wrong task/node/generation). Merge-check assertions additionally need the `{:merge_check_result, ...}` message (or the loaded result first — `MergeCheck.maybe_start` runs only after the load result).

## Constraints

- The async load is the ONLY way the page fetches data — do not add synchronous RPCs to `handle_params/3`.
- Diffs stay lazy — never fetch full diffs on page load.
- Follows the project-wide `try/rescue` anti-pattern policy; the async-boundary rescue is the accepted exception (justified comment in code).
