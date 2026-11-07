# ProjectsLive — Support Modules & Page Notes

## Intent

Support modules for `EvoDashWeb.ProjectsLive` (`GET /` and `GET /projects`) plus the durable design notes for the Projects page (command palette, top bar, task form threading, foreign repos, node handling).

**The governing rule of this node: no `ProjectsLive` process ever blocks on a task-store or RPC call.**
Every store/registry/`EvoDash.NodeContext` read runs in a supervised `EvoDash.TaskSupervisor` child and lands back as a message with a monotonic seq + node stale guard; every store/registry write that must stay synchronous (a user clicked a button and the test asserts store state right after) is wrapped in `EvoDash.SafeCall.run/1` so a `GenServer.call` exit/`:timeout` becomes a flash instead of a crashed LiveView.

## Routing Table

- `async_load.ex` → the connected-mount / project-change **batch loader** (`maybe_spawn/2`, `handle_result/5`, `load_recent_projects/3`, `load_custom_agents/1`) — the single place node-scoped page data is fetched off-process
- `notifications.ex` → the browser-notification **scan** (`load_terminal_ids/0`, `spawn_scan/4`, `scan_new/1`) — terminal-id projection + per-new-id title/body extraction, all off-process
- `project.ex` → pure project/path helpers + local config & filesystem reads (`load_project_config/1`, `load_model_profiles/1`, `path_suggestions/3`, `task_notification_content/1`)
- `project_flow.ex` → project activation flows (`register_and_open_project/2`, `open_project/2`, `select_project/2`, `close_project/1`, remote activation via `spawn_remote_project_activation/2,3`), foreign-repo struct construction
- `assigns.ex` → deliberately PURE assign helpers (`assign_form_defaults/1`); no store calls, no RPC
- `state_persistence.ex` → per-node form-state persistence, canonical model-spec restoration and legacy-id migration, plus model-only `persist_model_selection` events (assigns + `push_event`, no I/O)
- `launch_options.ex` → pure `LaunchOptions.apply/2`, shared model-spec lock, custom-agent and quality options for normal submissions and GitHub fixes
- `attach_file.ex` → the objective attach-file pipeline (local file reads only)
- `github.ex` → GitHub upstream/issues/fix-issue async flows + the local `start_task` branch
- `remote_view.ex` → pure remote-mode render (top bar + banner), zero RPC
- `../tasks_live/page_load.ex` (sibling node) → the TasksLive analogue of `async_load.ex`; same conventions

## Module API Surface

| Module | Key functions | I/O |
|--------|---------------|-----|
| `EvoDashWeb.ProjectsLive.AsyncLoad` | `maybe_spawn(socket, prev_node_id)` (connected only), `handle_result(socket, node, prev_node_id, path, results)` → `{socket, applied?}`, `load_recent_projects(remote?, node_id, node)`, `load_custom_agents(node)` | one supervised batch: custom agents + canonical picker bundle + recent projects (+ terminal ids + auto-activate flag, local only), with generation/target/node/path freshness guards |
| `EvoDashWeb.ProjectsLive.Notifications` | `load_terminal_ids/0` → `MapSet.t() \| nil`, `spawn_scan(parent, seq, node, known_ids)`, `spawn_scan/4` sends `{:task_notifications, seq, node, result}` where result is `{:ok, {new_ids_list, [{id, title, body}]}} \| {:error, reason}` | terminal-id projection + one lite `TaskRegistry.get_task_lite/1` per NEWLY terminal id |
| `EvoDashWeb.ProjectsLive.LaunchOptions` | `apply(opts, assigns)` → `{:ok, opts}` or `{:error, reason}` | none — shared strict model/agent/quality launch policy |
| `EvoDashWeb.ProjectsLive.Project` | `load_model_selection/0,1,2`, `load_model_selection_from_config/2`, legacy `load_model_profiles/0,1`, `load_project_config/1`, `path_suggestions/3`, `task_notification_content/1`, `project_url/2` | canonical picker config loading is node-aware and remote callers run off-process; other helpers use local TOML/FS reads or remote path RPC |
| `EvoDashWeb.ProjectsLive.ProjectFlow` | `register_and_open_project/2`, `open_project/2`, `select_project/2`, `close_project/1`, `build_foreign_repo/2`, `spawn_remote_project_activation/2,3` | local recent-project writes (small, sync); remote activation async → `{:async_remote_project, node, path, result}` |
| `EvoDashWeb.ProjectsLive.Assigns` | `assign_form_defaults/1` | none — pure |
| `EvoDashWeb.ProjectsLive.StatePersistence` | `maybe_persist_state/1`, `maybe_clear_state_on_node_switch/3`, `maybe_restore_assign/3`, `maybe_restore_quality_level/2`, `maybe_restore_foreign_repos(socket, repos)` (per-node form state round-trip; the page owns restore-event wiring) | assigns + `push_event` only |
| `EvoDashWeb.ProjectsLive.AttachFile` | `pick/3`, `handle_result/3`, `handle_manual/3`, `read_kind/2` | LOCAL file reads (`EvoDash.AttachedFile.read/1`, `File.regular?/1`, `File.read/1`) |
| `EvoDashWeb.ProjectsLive.GitHub` | `maybe_check/1`, `open_issues/3`, `fetch_and_fix/4`, `start_fix_task/3` | `NodeContext.github_upstream/2`, `github_issues/3`, `github_issue_markdown/3` (async runners); local `TaskRegistry.start_task/2` in the fix path |
| `EvoDashWeb.ProjectsLive.RemoteView` | `top_bar/1`, remote banner | none — pure render |

## The Rule — nothing in the LiveView process blocks

- **Reads** (`list_recent_projects`, `list_task_ids`, `get_task_lite`, `list_tasks_paginated`, `get_resolved_config`, `list_custom_agents`, remote RPCs) never run in `mount/3`, `handle_params/3`, `handle_event/3` or `handle_info/2`. They run inside a `Task.Supervisor.start_child(EvoDash.TaskSupervisor, fn -> … end)` body, are `EvoDash.SafeCall.run/1`-wrapped there, and `send/2` their result to the LiveView.
- Store calls can take many seconds (a production task carried a ~108 MB `result`) and a `GenServer.call` can EXIT (`:timeout`, dead server) — which `rescue` cannot catch, hence `SafeCall`.
- **Writes** that are part of a click and whose effect must be observable immediately (`start_task`, `clear_finished_tasks`, `delete_task`, `remove_recent_project`, `add_recent_project`, `cancel_task`) stay synchronous in the LiveView process but are `SafeCall`-wrapped; their follow-up reload/scan work is async.

### Async message inventory (projects_live)

| Message | Producer | Seq assign | Stale guard | Effect on arrival |
|---------|----------|-----------|-------------|-------------------|
| `{:async_project_load, node, prev_node_id, path, results}` | `AsyncLoad.maybe_spawn/2` (connected mount + node/project change) | `projects_load_seq` in internal `load_scope` | seq + target id + node + `active_project_path == path` → else `{socket, false}` | applies agents/canonical picker/recent projects, reconciles selection unless a newer interaction owns it, unions terminal ids and marks notification readiness; preserves the five-tuple message shape |
| `{:task_notifications, seq, node, result}` | `Notifications.spawn_scan/4` (from `:node_aware_reload_tasks`) | `task_notifications_seq` | seq + node + `current_node_id == nil` | `push_event "task_notification"` once per `{id, title, body}`; unions new ids into `notified_task_ids`. `{:error, _}` leaves state alone (next debounced reload retries) |
| `{:task_history_cleared, seq, node, result}` | `clear_task_history` event | `clear_history_seq` | seq + node | success → union the post-clear id set + `notified_task_ids_ready?: true`; error → readiness restored + error flash |
| `{:recent_projects_loaded, seq, node_id, node, result}` | `{:recent_projects_updated}` PubSub handler | `recent_projects_seq` | seq + `current_node_id` + node | replaces `recent_projects`; error keeps the current list |
| `{:recent_projects_removed, seq, node, result}` | `remove_recent_project` event | `recent_projects_seq` | seq + node | success replaces the optimistically-filtered list; error keeps it + error flash (a later broadcast corrects) |
| `{:foreign_repos_restored, task_id, node, result}` | `start_foreign_repos_restore/2` (resume path) | none — keyed by task id | `task_id == task_resume_from` + node | assigns the restored `foreign_repos`, clears `foreign_repos_restoring_from` |
| `{:async_remote_project, node, path, result}` | `ProjectFlow.spawn_remote_project_activation/2,3` | none | node + in-flight remote path | applies the remote project activation result / error flash |
| `{:github_status_result, path, node, result}` | `GitHub.maybe_check/1` | none | project path + node | assigns the upstream status (drives the top-bar GitHub button) |
| `{:github_issues_result, path, node, state, result}` | `GitHub.open_issues/3` | none | path + node + filter state | fills the issues modal |
| `{:github_fix_result, path, node, number, result}` | `GitHub.fetch_and_fix/4` | none | path + node + issue number | starts the `:evolve` fix task or flashes the error |
| `{:directory_picker_result, picker_id, result}` | `EvoDash.DirectoryPicker.pick/3` (via `AttachFile`) | none | `picker_id` (`@attach_picker_id`, image/audio ids, or a project path picker) | routes to `AttachFile.handle_result/3` (local file read) or the project-path form |
| `:load_config_status` | `send(self(), …)` in `mount/3` | none | — | deferred LOCAL `config_status()` read (config.toml + credentials.toml), so the warning banner never delays first paint |
| `:node_aware_reload_tasks` | `NodeAware` 300 ms trailing-edge debounce after a node-matching `{:task_updated, …}`/`{:task_deleted, …}` | — | already node-filtered by NodeAware | refreshes project config when the settings panel is open, spawns the notification scan, reloads the sidebar via `NodeAware.load_running_and_pending_tasks/1`, then `NodeAware.clear_task_reload_pending/1` |

`{:node_selected, id}`, `{:remote_connection_status, _, _}`, `{:remote_connect_result, …}` and `{:node_aware_active_tasks, …}` are handled by `NodeAware` (the page forwards them).

## Mount & handle_params

- **Dead render (`connected?(socket) == false`) makes ZERO task-store calls**: `recent_projects: []`, `notified_task_ids: MapSet.new()`, `notified_task_ids_ready?: false`, `task_notifications_seq: 0`, `recent_projects_seq: 0`, `clear_history_seq: 0`, `foreign_repos_restoring_from: nil`, `auto_activate_candidate?: false`, no PubSub subscriptions. The reported crash lived exactly here (`list_recent_projects` + a ~953-id `list_task_ids` on every mount).
- **Connected mount** subscribes the page topics and sends `:load_config_status`; it still performs only LOCAL, cheap, non-store setup: a memoized `EvoGit.Config.resolve()` (`Process.put(:memo_config_resolve, …)` primes the OS file cache for the deferred read), `Project.load_model_profiles/1`, `AsyncLoad.load_custom_agents/1` and `EvoGit.Runtime.WorktreeInitScript.build_systems()`. At mount the node is always the LOCAL one (NodeAware seeds local; `?node=` resolves later), so these are local file reads, not RPC.
- `handle_params/3` captures `prev_node_id` BEFORE `assign_node/2` so the node-switch reset and the batch loader see the transition, sets `auto_activate_candidate?: is_nil(params["project"]) and is_nil(current_node_id)`, and ends with `AsyncLoad.maybe_spawn(socket, prev_node_id)` (connected only). It never seeds `notified_task_ids` itself.
- Auto-activation of a recent project is a **continuation** of the batch (`maybe_auto_activate_recent_project/1`), not part of mount: it requires `applied? and results[:auto_activate?]`, no remote context, no active project, a `%{path: path}` first entry, and `File.dir?` before `activate_project/2`. Because it lands one frame after `live/2`, tests must `wait_assigns` for `active_project_path`.

## Browser notifications — `notified_task_ids_ready?`

`@notified_task_ids` is a `MapSet` of terminal ids already accounted for; `@notified_task_ids_ready?` says the set has been SEEDED from the store.

- A fresh connected mount starts `ready? == false` with an empty set. Detection is **skipped entirely** while `ready? == false` — diffing against an unseeded empty set would fire a notification for every historical terminal task (~953).
- The seed arrives with the batch (`:terminal_ids`, local context only, only while `ready? == false`) or, after a clear-history, with `{:task_history_cleared, …}`.
- Once ready, each `:node_aware_reload_tasks` spawns ONE `Notifications.spawn_scan/4` with the current known set; ids absent from it are the new ones. Ids whose `get_task_lite` returns nil are marked notified without notifying.
- Notifications are **LOCAL-context only** (`current_node_id == nil`); remote contexts never scan, never seed, never push.
- `clear_task_history` flips `ready?` to false before clearing so the in-flight window cannot notify, then restores it on arrival (error included).

## Guarded mutations

- `clear_task_history`: sets `notified_task_ids_ready?: false`, empties the sidebar lists immediately via `NodeAware.assign_active_tasks/1` (an ETS-hub read, no store call), and spawns a task that runs `SafeCall.run(fn -> TaskRegistry.clear_finished_tasks(); Notifications.load_terminal_ids() end)` → `{:task_history_cleared, seq, node, result}`. The rest of the refresh arrives through the regular node-filtered broadcasts.
- `remove_recent_project`: optimistic list filter + async authoritative reload (`{:recent_projects_removed, …}`).
- `cancel_task` / `delete_task`: `SafeCall.run/1`; an error flashes instead of crashing.
- `start_task` (`do_task_submit/4`): synchronous, but the submit path refuses to launch while a foreign-repo restore for the SAME resume task is still in flight (`foreign_repos_restoring_from == task_resume_from` → "Still loading the previous task's settings. Please try again in a moment."), so the restore can never lose the race against submit.

## Foreign-repo resume restore

`start_foreign_repos_restore/2` replaces the old synchronous `maybe_restore_foreign_repos_from_task/2`: it marks `foreign_repos_restoring_from: task_id` and spawns a `SafeCall.run(TaskRegistry.get_task_lite(task_id))` whose only consumed field is `opts[:foreign_repos]`, arriving as `{:foreign_repos_restored, task_id, node, result}`. The handler drops the message unless the task is still the resume target on the same node.
The lookup is deliberately the LOCAL `TaskRegistry.get_task_lite/1` (same struct as `get_task/1` minus the archive) — the node-aware foreign-repo restore for a remote activation lives in `ProjectFlow.task_foreign_repos_for_resume/2`, inside the supervised remote-activation task.

## RPC / I/O audit (per module)

- `projects_live.ex` — the only store calls left in the LiveView process are the `SafeCall`-wrapped mutations above plus `TaskRegistry.add_recent_project/2` on a palette Enter (small write, immediately followed by `push_patch`). Everything else is spawned.
- `async_load.ex` — all reads live in the spawned task body; `handle_result/5` is pure assignment + the `:resume_foreign_repos_guard` drop for `:foreign_repos`.
- `notifications.ex` — the only place the page reads task rows for notification titles; the read is `get_task_lite/1` (no archive blob).
- `project_flow.ex` — local recent-project writes (`add_recent_project` + `list_recent_projects`) and `File.dir?`/`Path.expand` stay synchronous (cheap, user-initiated); remote activation is async.
- `project.ex` — local TOML/FS reads; `path_suggestions/3` calls `EvoGit.PathSuggestions.suggest/1` locally and `NodeContext.list_path_suggestions/2` for remote nodes.
- `github.ex` — all `gh` work runs through the `:github_runner`/`:github_issues_runner`/`:github_issue_markdown_runner` seams in supervised tasks (resolved at spawn time).
GitHub dispatch and result application require a usable target; a pending/gated remote target never falls back to local RPC or task launch.
The public GitHub message tuples retain their arity, but their result element is an opaque request-scoped envelope carrying target identity and a unique request token; handlers ignore unscoped results and validate target, BEAM node, path and request identity.
Closing/reopening the modal, changing filters or superseding an issue fix invalidates earlier replies, including repeated requests for the same issue, and accepted results are consumed once.
GitHub runners and task dispatch use `SafeCall` so an exit becomes a reported result instead of a wedged loading state.
- `remote_view.ex`, `assigns.ex`, `state_persistence.ex` — pure render / pure assigns; zero RPC.
- `attach_file.ex` — local file reads only (remote reads unsupported: the read runs on the LOCAL node's filesystem, and the node dropdown does not proxy it).

## Model-selection helper contracts

The canonical task-picker assign is `selected_model_spec`, a STRING-keyed map containing only `provider_profile_id`, `model` and optional `reasoning_effort`; `%{}` is explicit Auto, while nil means uninitialized/use the node default.
`Project.load_model_selection/0,1,2` returns a shared `LLMSelection.from_config(config, rules_enabled)` bundle for the executing node, and `load_model_selection_from_config/2` is its pure projection seam.
Local loading honors the process-local `:memo_config_resolve`; remote loading uses the target's resolved config and degrades to an empty-config bundle on transport failure, never borrowing the dashboard's local models.
A pending remote target (`current_node_id != nil` while its BEAM node is local) never reads local custom agents/config through `AsyncLoad.default_batch/6`, never applies batch results and preserves its pending model restore until a remote bundle is available.
Passing the already-loaded rules flag avoids a second remote custom-agent read; `AsyncLoad.default_batch/6` uses this path.
The old `Project.load_model_profiles/0,1` and `load_model_profiles_from_config/2` tuple APIs remain untouched for legacy callers and editing compatibility.

### Shared `EvoDashWeb.LLMSelection` dependency

`from_config(config, rules_enabled)` returns a map with at least `provider_profiles` (canonical string maps) and `model_selections` (ordered core atom-map projections), plus whatever default/legacy-alias metadata the shared helper needs.
The bundle is an in-memory picker value, never persisted into browser storage or sent as task opts.
`reconcile(bundle, candidate)` returns a normalized string-keyed model spec, resolving nil to defaults, recognizing `%{}`/legacy `""` as Auto, migrating legacy ids, and falling back to valid node defaults when a provider/model/effort was removed.
`task_opts(bundle, candidate)` returns `{:ok, keyword_opts}` or `{:error, reason}`; explicit selections resolve all defaults and yield exactly `model_spec: <canonical string map>, model_id_locked: true`, Auto yields `[]`, and stale/invalid explicit choices must error rather than silently launch as Auto.
All model membership, reasoning defaults and legacy normalization belong to that shared helper, backed by `Schema.provider_profiles/1`, `model_selections/1` and `resolve_model_spec/2`; this leaf does not reproduce them.

### Async freshness and restoration

Canonical async batches carry `model_selection`; the handler assigns it plus `provider_profiles` and `model_selections`, then reconciles `selected_model_spec` on same-node refreshes as well as node switches.
The public five-tuple result message remains unchanged, with internal `load_scope` metadata carrying `projects_load_seq`, target id and the captured selection.
Actual spawned batches reject stale generation, target-id, BEAM-node or path results, and do not overwrite a user choice made after spawning.
Unstamped legacy result maps carrying `model_profiles`/`default_selected_model_id` remain accepted for existing callers/tests.
`StatePersistence.maybe_restore_model_selection/2` takes the whole persisted string-keyed state AFTER the parent page's node check; `model_spec` takes precedence over `selected_model_id`, including an explicit empty Auto.
A restore arriving before the picker bundle is stored as `pending_model_selection` and validated when the canonical async bundle lands.
Node switches clear the bundle, picker projections and pending restore before fetching the new node; a carried canonical selection is validated against the new bundle.
`model_selection_state/1` serializes only the three canonical spec keys, never credentials or bundle metadata; legacy-only/pending-legacy callers keep `selected_model_id` until canonical migration completes.
`maybe_persist_model_selection/1` emits the model-only `persist_model_selection` event after canonical reconciliation/restoration, with `%{node: target_id_or_local, model_spec: spec}`; this event requires the browser consumer to merge those fields into the same node's saved state rather than replacing DOM-owned prompt/form data.
Full-form `persist_state` remains a separate replacement event, and an explicit empty model-spec map must survive both event paths.
The parent's provider/model/reasoning change handlers must clear `pending_model_selection` so an earlier restore cannot override a newer interaction.

### Launch and parent-page wiring

Normal submission must replace its inline model-id, agent and quality blocks with `LaunchOptions.apply(opts, socket.assigns)` and flash a returned error before making any task-start call.
`LaunchOptions.apply/2` is pure and preserves unrelated launch fields, removes stale `model_id`/`model_spec`/lock keys before merging validated shared-helper options, emits nonempty custom-agent ids, and omits default balanced quality.
GitHub fixes use this SAME launch helper before either local or remote task submission, so explicit model specs are locked and agent/quality policy matches normal launches.
A missing picker bundle fails launch with `:model_selection_not_loaded`, rather than submitting an unintended default.
The parent page must seed `model_selection: nil`, `provider_profiles: []`, `model_selections: []`, `selected_model_spec: nil` and `pending_model_selection: nil`, or use `Project.load_model_selection/0` for its local cheap mount seed.
Both task-form call sites must receive the canonical projections/spec, and restore-state wiring must call the new model-restoration function rather than `maybe_restore_assign(:selected_model_id, ...)`.
The browser persistence hook must retain the `model_spec` object, including `%{}`, rather than relying on its legacy `selected_model_id` allowlist.
Quality remains the independent `fast`/`balanced`/`high_quality` task policy, not model reasoning effort.

## Payload-vs-consumed gaps

1. `get_resolved_config` transfers the entire resolved config; `Project.load_model_profiles_from_config/2` extracts and returns the full `Schema.model_profiles/1` profile maps unchanged plus the default profile id, so provider/model/generation metadata is available to consumers even though the current selector identifies profiles by id.
2. `list_custom_agents` transfers full definitions + script + script_status; only agent ids and script non-empty-ness are consumed.
3. `list_recent_projects` transfers `%RecentProject{path, name, last_opened_at}`; `last_opened_at` is never read here.
4. `read_project_config` transfers the full parsed genesis.toml; `"worktree"`, `"script"`, `"commands"`, `"foreign_repos"` are consumed.
5. `github_upstream` map's `url` is never read (only `owner`, `repo`, `gh_available`).

## Path autocomplete & Windows handling

`Project.path_suggestions/3` matches typed text against recent-project paths as a case-insensitive SUBSTRING (infix), deduped, recents first; filesystem entries come from `EvoGit.PathSuggestions.suggest/1` (local) or `NodeContext.list_path_suggestions/2` (remote), so `<dir>/` lists that directory and `~` lists home identically on both branches. Backslashes are normalized to `/` before suggestion/dir checks; the expanded path is what gets validated (`NodeContext.dir?/2` remotely, `File.dir?/1` locally) and stored in the URL/recent projects.

## Memory

The page keeps summary maps only — `recent_projects` (paths), `notified_task_ids` (a `MapSet` of ids), plus the sidebar lists owned by `NodeAware`. No full `%TaskInfo{}` row is retained in assigns; notification titles are computed in the spawned scan and discarded after `push_event`.

## Test strategy

- `test/evo_dash_web/live/projects_live_test.exs` drives the real store; because mount/handle_params work is async, assertions on `recent_projects`, `active_project_path` and notifications use `wait_assigns(view, predicate)` (~300 attempts) instead of asserting right after `live/2`.
- The batch loader's message shape (`{:async_project_load, node, prev_node_id, path, results}`) and `AsyncLoad.handle_result/5`'s `{socket, applied?}` return are test-pinned; keep `handle_result/5` tolerant of result maps built without newer keys (`Map.get/3`).
- Notification tests seed `notified_task_ids` + `notified_task_ids_ready?: true` explicitly; a test that leaves `ready?` false asserts NO `task_notification` event.
- Node-switch behaviour (state clearing, `&node=` push_patch, gate states, stale-node restore skip) lives in the same file; `<node>` tests register a fake ConnectionManager in the real `EvoGit.RemoteConnection.Registry`.

## Constraints

- Keep `projects_live.ex` from growing: new loaders go into `async_load.ex` / `notifications.ex` / a new small support module — not the main file (it is already ~3 000 lines and is the page's event surface).
- Every new async message needs: a unique tag, a monotonic seq assign when more than one can be in flight, and a node (+ context, e.g. path/task id) stale guard. Never apply a result keyed only by "latest".
- No polling. All PubSub handling stays node-filtered through `NodeAware.event_from_current_node?/2`; the 300 ms debounce is the only coalescing mechanism.
- No `try/rescue` around store/RPC calls — use `EvoDash.SafeCall`. No `String.to_atom/1`/`to_existing_atom` on client input (whitelist maps only).
- User-facing strings are `gettext`-wrapped; never run gettext extract/merge during feature work.

## Deferred — the `select_tasks_page` round

- The Projects page task cards come from the sidebar summary loader (`NodeAware`), not from a dedicated paged selector; if the page ever needs its own paged list, it must use `EvoGit.TaskRegistry.select_tasks_page` rather than `list_tasks_paginated`.
