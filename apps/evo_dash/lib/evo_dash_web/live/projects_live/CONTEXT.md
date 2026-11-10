# ProjectsLive — Support Modules & Page Notes

## Intent

Support modules for `EvoDashWeb.ProjectsLive` (`GET /` and `GET /projects`) plus the durable design notes for the Projects page (command palette, top bar, task form threading, foreign repos, node handling).

**The governing rule of this node: no `ProjectsLive` process ever blocks on a task-store or RPC call.**
Every store/registry/`EvoDash.NodeContext` read runs in a supervised `EvoDash.TaskSupervisor` child and lands back as a message with a monotonic seq + node stale guard; every store/registry write that must stay synchronous (a user clicked a button and the test asserts store state right after) is wrapped in `EvoDash.SafeCall.run/1` so a `GenServer.call` exit/`:timeout` becomes a flash instead of a crashed LiveView.

## Routing Table

- `async_load.ex` → the connected-mount / project-change **batch loader** (`maybe_spawn/2`, `handle_result/5`, `load_projects/3`, `load_custom_agents/1`) — the single place node-scoped page data is fetched off-process
- `notifications.ex` → the browser-notification **scan** (`load_terminal_ids/0`, `spawn_scan/4`, `scan_new/1`) — terminal-id projection + per-new-id title/body extraction, all off-process
- `project.ex` → pure project/path helpers + local config & filesystem reads (`load_project_config/1`, `load_model_profiles/1`, `path_suggestions/3`, `task_notification_content/1`)
- `project_flow.ex` → project activation flows (`register_and_open_project/2`, `open_project/2`, `select_project/2`, `close_project/1`, remote activation via `spawn_remote_project_activation/2,3`), VCT mount registration, foreign-repo struct construction
- `assigns.ex` → deliberately PURE assign helpers (`assign_form_defaults/1`); no store calls, no RPC
- `state_persistence.ex` → per-node form-state persistence, canonical model-spec restoration and legacy-id migration, plus model-only `persist_model_selection` events (assigns + `push_event`, no I/O)
- `launch_options.ex` → pure `LaunchOptions.apply/2`, shared scope/readiness/restore gate, model-spec lock, custom-agent and quality options for normal submissions and GitHub fixes
- `model_selection_scope.ex` → server-only picker bundle ownership `{target_id, beam_node}`, readiness/error validation and choice-preserving invalidation
- `attach_file.ex` → the objective attach-file pipeline (local file reads only)
- `github.ex` → GitHub upstream/issues/fix-issue async flows + the local `start_task` branch
- `remote_view.ex` → pure remote-mode render (top bar + banner), zero RPC
- `../tasks_live/page_load.ex` (sibling node) → the TasksLive analogue of `async_load.ex`; same conventions

## Module API Surface

| Module | Key functions | I/O |
|--------|---------------|-----|
| `EvoDashWeb.ProjectsLive.AsyncLoad` | `maybe_spawn(socket, prev_node_id)` (connected only), `handle_result(socket, node, prev_node_id, path, results)` → `{socket, applied?}`, `load_projects(remote?, node_id, node)`, `filter_absolute_projects/1`, `filter_absolute_projects_for_node/2`, `load_custom_agents(node)` | one supervised batch: custom agents + canonical picker bundle + the VCT project set (+ terminal ids + auto-activate flag, local only), with generation/target/node/path freshness guards |
| `EvoDashWeb.ProjectsLive.Notifications` | `load_terminal_ids/0` → `MapSet.t() \| nil`, `spawn_scan(parent, seq, node, known_ids)`, `spawn_scan/4` sends `{:task_notifications, seq, node, result}` where result is `{:ok, {new_ids_list, [{id, title, body}]}} \| {:error, reason}` | terminal-id projection + one lite `TaskRegistry.get_task_lite/1` per NEWLY terminal id |
| `EvoDashWeb.ProjectsLive.LaunchOptions` | `apply(opts, assigns)` → `{:ok, opts}` or `{:error, reason}` | none — shared strict model/agent/quality launch policy |
| `EvoDashWeb.ProjectsLive.ModelSelectionScope` | `current/1`, `pending_remote?/1`, `bundle/1`, `bundle?/1`, `invalidate/2` | none — server-only ownership/readiness checks and choice-preserving assign invalidation |
| `EvoDashWeb.ProjectsLive.Project` | `load_model_selection/0,1,2`, `load_model_selection_from_config/2`, legacy `load_model_profiles/0,1`, `load_project_config/1`, `path_suggestions/3`, `task_notification_content/1`, `project_url/2` | canonical picker config loading is node-aware and remote callers run off-process; other helpers use local TOML/FS reads or remote path RPC |
| `EvoDashWeb.ProjectsLive.ProjectFlow` | `register_and_open_project/2`, `open_project/2`, `select_project/2`, `close_project/1`, `mount_point_for/2`, `build_foreign_repo/2`, `spawn_remote_project_activation/2,3` | local project mounts (`NodeContext.mount_project/3` + `NodeContext.projects/1`, small, sync, `SafeCall`-wrapped); remote activation async → `{:async_remote_project, node, path, result}` |
| `EvoDashWeb.ProjectsLive.Assigns` | `assign_form_defaults/1` | none — pure |
| `EvoDashWeb.ProjectsLive.StatePersistence` | `maybe_persist_state/1`, `maybe_clear_state_on_node_switch/3`, `maybe_restore_assign/3`, `maybe_restore_quality_level/2`, `maybe_restore_foreign_repos(socket, repos)` (per-node form state round-trip; the page owns restore-event wiring) | assigns + `push_event` only |
| `EvoDashWeb.ProjectsLive.AttachFile` | `attach_picker_id/0`, `handle_attach_result/2` (text kinds: append a Markdown block to the prompt), `handle_binary_attach_result/3` (image/audio kinds: stage raw bytes into `@staged_attachments`, caps 4 files / 15 MiB) | LOCAL file reads (`EvoDash.AttachedFile.read/1`, `EvoDash.AttachedFile.read_kind/2`, `File.regular?/1`) |
| `EvoDashWeb.ProjectsLive.GitHub` | `maybe_check/1`, `open_issues/3`, `fetch_and_fix/4`, `start_fix_task/3` | `NodeContext.github_upstream/2`, `github_issues/3`, `github_issue_markdown/3` (async runners); local `TaskRegistry.start_task/2` in the fix path |
| `EvoDashWeb.ProjectsLive.RemoteView` | `top_bar/1`, remote banner | none — pure render |

## The Rule — nothing in the LiveView process blocks

- **Reads** (`NodeContext.projects/1`, `list_task_ids`, `get_task_lite`, `list_tasks_paginated`, `get_resolved_config`, `list_custom_agents`, remote RPCs) never run in `mount/3`, `handle_params/3`, `handle_event/3` or `handle_info/2`. They run inside a `Task.Supervisor.start_child(EvoDash.TaskSupervisor, fn -> … end)` body, are `EvoDash.SafeCall.run/1`-wrapped there, and `send/2` their result to the LiveView.
- Store calls can take many seconds (a production task carried a ~108 MB `result`) and a `GenServer.call` can EXIT (`:timeout`, dead server) — which `rescue` cannot catch, hence `SafeCall`.
- **Writes** that are part of a click and whose effect must be observable immediately (`start_task`, `clear_finished_tasks`, `delete_task`, `cancel_task`, plus the palette/form project mount `NodeContext.mount_project/3`) stay synchronous in the LiveView process but are `SafeCall`-wrapped; their follow-up reload/scan work is async, and `forget_project` is optimistic + fully async.

### Async message inventory (projects_live)

| Message | Producer | Seq assign | Stale guard | Effect on arrival |
|---------|----------|-----------|-------------|-------------------|
| `{:async_project_load, node, prev_node_id, path, results}` | `AsyncLoad.maybe_spawn/2` (connected mount + node/project change) | `projects_load_seq` in internal `load_scope` | seq + target id + node + `active_project_path == path` → else `{socket, false}` | applies agents/canonical picker/`projects`, reconciles selection unless a newer interaction owns it, unions terminal ids and marks notification readiness; preserves the five-tuple message shape |
| `{:task_notifications, seq, node, result}` | `Notifications.spawn_scan/4` (from `:node_aware_reload_tasks`) | `task_notifications_seq` | seq + node + `current_node_id == nil` | `push_event "task_notification"` once per `{id, title, body}`; unions new ids into `notified_task_ids`. `{:error, _}` leaves state alone (next debounced reload retries) |
| `{:task_history_cleared, seq, node, result}` | `clear_task_history` event | `clear_history_seq` | seq + node | success → union the post-clear id set + `notified_task_ids_ready?: true`; error → readiness restored + error flash |
| `{:projects_loaded, seq, node_id, node, result}` | `{:vct_updated, node}` PubSub handler | `projects_seq` | seq + `current_node_id` + node | replaces `projects`; error keeps the current list |
| `{:projects_forgotten, seq, node, result}` | `forget_project` event | `projects_seq` | seq + node | success replaces the optimistically-filtered list with the authoritative filtered reload; error reloads what it can and flashes `"Failed to forget project: %{reason}"` (a later `{:vct_updated, node}` broadcast corrects it) |
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

- **Dead render (`connected?(socket) == false`) makes ZERO task-store calls**: `projects: []`, `notified_task_ids: MapSet.new()`, `notified_task_ids_ready?: false`, `task_notifications_seq: 0`, `projects_seq: 0`, `clear_history_seq: 0`, `foreign_repos_restoring_from: nil`, `auto_activate_candidate?: false`, no PubSub subscriptions. No registry read (the VCT project set, `list_task_ids`) happens on this path.
- **Connected mount** subscribes the page topics and sends `:load_config_status`; it still performs only LOCAL, cheap, non-store setup: a memoized `EvoGit.Config.resolve()` (`Process.put(:memo_config_resolve, …)` primes the OS file cache for the deferred read), `Project.load_model_profiles/1`, `AsyncLoad.load_custom_agents/1` and `EvoGit.Runtime.WorktreeInitScript.build_systems()`. At mount the node is always the LOCAL one (NodeAware seeds local; `?node=` resolves later), so these are local file reads, not RPC.
- `handle_params/3` captures `prev_node_id` BEFORE `assign_node/2` so the node-switch reset and the batch loader see the transition, sets `auto_activate_candidate?: is_nil(params["project"]) and is_nil(current_node_id)`, and ends with `AsyncLoad.maybe_spawn(socket, prev_node_id)` (connected only). It never seeds `notified_task_ids` itself.
- Auto-activation of the newest VCT project is a **continuation** of the batch (`maybe_auto_activate_project/1`), not part of mount: it also requires `auto_activate_candidate?`, `applied? and results[:auto_activate?]`, no remote context, no active project, a `%{path: path}` first entry with a binary `path`, and `File.dir?` before `activate_project/2`. Because it lands one frame after `live/2`, tests must `wait_assigns` for `active_project_path`.

## Browser notifications — `notified_task_ids_ready?`

`@notified_task_ids` is a `MapSet` of terminal ids already accounted for; `@notified_task_ids_ready?` says the set has been SEEDED from the store.

- A fresh connected mount starts `ready? == false` with an empty set. Detection is **skipped entirely** while `ready? == false` — diffing against an unseeded empty set would fire a notification for every historical terminal task (~953).
- The seed arrives with the batch (`:terminal_ids`, local context only, only while `ready? == false`) or, after a clear-history, with `{:task_history_cleared, …}`.
- Once ready, each `:node_aware_reload_tasks` spawns ONE `Notifications.spawn_scan/4` with the current known set; ids absent from it are the new ones. Ids whose `get_task_lite` returns nil are marked notified without notifying.
- Notifications are **LOCAL-context only** (`current_node_id == nil`); remote contexts never scan, never seed, never push.
- `clear_task_history` flips `ready?` to false before clearing so the in-flight window cannot notify, then restores it on arrival (error included).

## Guarded mutations

- `clear_task_history`: sets `notified_task_ids_ready?: false`, empties the sidebar lists immediately via `NodeAware.assign_active_tasks/1` (an ETS-hub read, no store call), and spawns a task that runs `SafeCall.run(fn -> TaskRegistry.clear_finished_tasks(); Notifications.load_terminal_ids() end)` → `{:task_history_cleared, seq, node, result}`. The rest of the refresh arrives through the regular node-filtered broadcasts.
- `forget_project`: bumps `projects_seq`, drops the row optimistically by `point` (`Enum.reject`), resets `palette_selected_index`, and runs the forget + authoritative reload in ONE supervised task → `{:projects_forgotten, seq, node, result}`; the `{:vct_updated, node}` broadcast is the backstop.
- `cancel_task` / `delete_task`: `SafeCall.run/1`; an error flashes instead of crashing.
- `start_task` (`do_task_submit/4`): synchronous, but the submit path refuses to launch while a foreign-repo restore for the SAME resume task is still in flight (`foreign_repos_restoring_from == task_resume_from` → "Still loading the previous task's settings. Please try again in a moment."), so the restore can never lose the race against submit.

## Foreign-repo resume restore

`start_foreign_repos_restore/2` replaces the old synchronous `maybe_restore_foreign_repos_from_task/2`: it marks `foreign_repos_restoring_from: task_id` and spawns a `SafeCall.run(TaskRegistry.get_task_lite(task_id))` whose only consumed field is `opts[:foreign_repos]`, arriving as `{:foreign_repos_restored, task_id, node, result}`. The handler drops the message unless the task is still the resume target on the same node.
The lookup is deliberately the LOCAL `TaskRegistry.get_task_lite/1` (same struct as `get_task/1` minus the archive) — the node-aware foreign-repo restore for a remote activation lives in `ProjectFlow.task_foreign_repos_for_resume/2`, inside the supervised remote-activation task.
Remote activation resolves `Application.get_env(:evo_dash, :remote_project_load_runner, &remote_project_load/2)` at call time INSIDE that supervised task; the two-arity runner receives `(node, path)` and returns the existing `{:ok, results_map}` or error contract unchanged.
For a nonempty resume task id, the same task resolves `Application.get_env(:evo_dash, :remote_resume_task_runner, &NodeContext.get_task_lite/2)` at call time; the two-arity runner receives `(node, task_id)` and returns the lite task with `opts[:foreign_repos]` or nil.
Both seams are inert unless configured and preserve pending-target admission, existing result messages/stale guards and task-repos-win precedence; they do not bypass the existing SafeCall boundaries or change RPC behavior by default.

## RPC / I/O audit (per module)

- `projects_live.ex` — the only calls left in the LiveView process are the `SafeCall`-wrapped mutations above (including `NodeContext.mount_project/3` on a palette Enter, immediately followed by `push_patch`). Everything else is spawned.
- `async_load.ex` — all reads live in the spawned task body; `handle_result/5` is pure assignment + the `:resume_foreign_repos_guard` drop for `:foreign_repos`.
- `notifications.ex` — the only place the page reads task rows for notification titles; the read is `get_task_lite/1` (no archive blob).
- `project_flow.ex` — local project mounts (`NodeContext.mount_project/3` + `NodeContext.projects/1`) and `File.dir?`/`Path.expand` stay synchronous (cheap, user-initiated); remote activation is async; `mount_point_for/2` is pure over the already-loaded `@projects`.
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
Local loading honors the process-local `:memo_config_resolve`; remote loading uses the target's resolved config and returns `{:error, reason}` on transport failure, never a successful empty configuration or the dashboard's local models.
A failed model read or guarded whole-batch failure invalidates the bundle, scope and readiness and records `model_selection_error`, preserving both `selected_model_spec` and `pending_model_selection` without reconciliation or partial persistence.
Every connected batch marks readiness false before spawning and delivers a scoped result even when its runner raises/exits, returns an invalid shape, or its supervisor fails to start the child.
Whole-batch failure returns `{socket, false}` so the parent does not run successful-load continuations.
A pending remote target (`current_node_id != nil` while its BEAM node is local) never reads local custom agents/config through `AsyncLoad.default_batch/6`, never applies batch results and preserves its pending model restore until a remote bundle is available.
Passing the already-loaded rules flag avoids a second remote custom-agent read; `AsyncLoad.default_batch/6` uses this path.
The old `Project.load_model_profiles/0,1` and `load_model_profiles_from_config/2` tuple APIs remain untouched for legacy callers and editing compatibility.

### Shared `EvoDashWeb.LLMSelection` dependency

`from_config(config, rules_enabled)` returns a map with at least `provider_profiles` (canonical string maps) and `model_selections` (ordered core atom-map projections), plus whatever default/legacy-alias metadata the shared helper needs.
The bundle is an in-memory picker value, never persisted into browser storage or sent as task opts.
`reconcile(bundle, candidate)` returns a normalized string-keyed model spec, resolving nil to defaults, recognizing `%{}`/legacy `""` as Auto, migrating legacy ids, and falling back to valid node defaults when a provider/model/effort was removed.
`task_opts(bundle, candidate)` returns `{:ok, keyword_opts}` or `{:error, reason}`; explicit selections resolve all defaults and yield exactly `model_spec: <canonical string map>, model_id_locked: true`, Auto yields `[]`, and stale/invalid explicit choices must error rather than silently launch as Auto.
All model membership, reasoning defaults and legacy normalization belong to that shared helper, backed by `Schema.provider_profiles/1`, `model_selections/1` and `resolve_model_spec/2`; this leaf does not reproduce them.
The shared helper reconstructs the canonical selection from resolved `provider_profile_id`, `model` and advertised/default reasoning fields, not `resolved.model_spec`, which is the ReqLLM-ready identifier rather than a persisted picker map.
`ModelSelectionScope.bundle/1` validates the server-only `model_selection_scope` against `{current_node_id, current_node || node()}`, rejects pending remote targets, failed/not-ready loads and malformed bundles, and deliberately accepts an unstamped bundle only in the local `{nil, node()}` context for mount compatibility.
`LaunchOptions` uses that same ownership boundary and additionally rejects any non-nil `pending_model_selection`, including explicit pending Auto, before resolving task options for normal and GitHub launches.
The async loader assigns ownership only after validating its generation/target/node/path envelope; an unstamped canonical remote result cannot establish ownership.

### Async freshness and restoration

Canonical async batches carry `model_selection`; the handler assigns it plus `provider_profiles` and `model_selections`, then reconciles `selected_model_spec` on same-node refreshes as well as node switches.
The public five-tuple result message remains unchanged, with internal `load_scope` metadata carrying `projects_load_seq`, target id and the captured selection.
Actual spawned batches reject stale generation, target-id, BEAM-node or path results, and do not overwrite a user choice made after spawning.
Unstamped legacy result maps carrying `model_profiles`/`default_selected_model_id` remain accepted for existing callers/tests.
`StatePersistence.maybe_restore_model_selection/2` takes the whole persisted string-keyed state AFTER the parent page's node check; `model_spec` takes precedence over `selected_model_id`, including an explicit empty Auto.
A restore arriving before an owned, ready picker bundle is stored as `pending_model_selection` and validated when that target's canonical async bundle lands; an unowned or mismatched remote bundle never reconciles or consumes it.
Node switches clear projects, the bundle, picker projections, selected canonical/legacy ids, scope, error, readiness and pending restore before fetching the new node; a changed stamped BEAM-node scope also resets state even when the target id is unchanged.
`model_selection_state/1` serializes only the three canonical spec keys, never credentials or bundle metadata; legacy-only/pending-legacy callers keep `selected_model_id` until canonical migration completes.
`maybe_persist_model_selection/1` emits the model-only `persist_model_selection` event only for an owned ready bundle without load error or pending restore, with `%{node: target_id_or_local, model_spec: spec}`; the browser consumer must merge those fields into the same node's saved state rather than replacing DOM-owned prompt/form data.
Full-form `persist_state` remains a separate replacement event, and an explicit empty model-spec map must survive both event paths.
The parent's provider/model/reasoning change handlers must clear `pending_model_selection` so an earlier restore cannot override a newer interaction.

### Launch and parent-page wiring

Normal submission calls `LaunchOptions.apply(opts, socket.assigns)` before either task-start call and routes validation failures through its existing failure flash.
`LaunchOptions.apply/2` is pure and preserves unrelated launch fields, removes stale `model_id`/`model_spec`/lock keys before merging validated shared-helper options, emits nonempty custom-agent ids, and omits default balanced quality.
GitHub fixes use this SAME launch helper before either local or remote task submission, so explicit model specs are locked and agent/quality policy matches normal launches.
A missing picker bundle fails launch with `:model_selection_not_loaded`, rather than submitting an unintended default.
The parent page should explicitly seed `model_selection_scope: nil`, `model_selection_ready?: false` and `model_selection_error: nil` alongside its nil bundle, projections, selected spec and pending restore.
If a local `Project.load_model_selection/0` mount seed is used instead, seed scope `{nil, node()}`, readiness true and error nil; missing ownership/readiness fields remain compatible only for that local context.
The parent selection-change handlers should use `ModelSelectionScope.bundle/1` rather than trusting any map-valued bundle, clear pending restores only after a successful owned transition, and display/retry `model_selection_error` without converting it into Auto.
`AsyncLoad.maybe_spawn/2` already marks readiness false and its result handler owns success/failure updates; the parent should not independently set readiness true or copy a local seed into a remote context.
Both task-form call sites must receive the canonical projections/spec, and restore-state wiring must call the new model-restoration function rather than `maybe_restore_assign(:selected_model_id, ...)`.
The browser persistence hook must retain the `model_spec` object, including `%{}`, rather than relying on its legacy `selected_model_id` allowlist.
Quality remains the independent `fast`/`balanced`/`high_quality` task policy, not model reasoning effort.

## Task-form toolbar layout

The Projects task form keeps a single `.input-controls` toolbar: the attach-kind dropdown and the fused mode+speed capsule form the LEFT cluster, and the model capsule (or custom-agent select, or legacy model select) plus the circular send button form the RIGHT cluster.
The own-row shared `llm_selection` picker is gone; the model capsule now lives inside the toolbar's right cluster.
`ml-auto` now sits on the first right-cluster element: the model capsule when `@use_llm_selection?` is true, else the custom-agent select, else the legacy model select.
Mode, quality (speed) and reasoning remain independent policies, and the existing event payload keys are unchanged: `mode`, `level`, `provider_profile_id`, `model` (plus the legacy `model_id` variant), `reasoning_effort` and `agent`.
## task_submit payload contract
`handle_event("task_submit", %{"prompt" => prompt, "mode" => combined_mode})` matches STRICTLY on both keys — there is deliberately no tolerant fallback clause, so the rendered `#task-form` must always carry `mode`.
The combined UI mode string (`genesis_new` / `genesis_existing` / `evolve_simple` / `custom_agent`) travels in a hidden `<input type="hidden" name="mode" value={@mode}>` inside `#task-form`, rendered from the capsule component's `@mode` (`= @task_mode`); the capsule's Layer-2 buttons are `type="button"` and fire `task_change`, which moves that server-side truth.
`node_path` / `starting_commit` / `resume_from` / `build_system` / `archive` arrive through the Configure dropdown's `form="task-form"` inputs (always in the DOM, class-hidden), while `quality_level` is never a form field — `LaunchOptions.apply/2` reads the `:quality_level` assign.
Quality (speed) and reasoning remain independent policies; `do_task_submit/4` maps the combined mode to `{task_type, core_mode}` and treats every absent payload key as "unset".

## Payload-vs-consumed gaps

1. `get_resolved_config` transfers the entire resolved config; `Project.load_model_profiles_from_config/2` extracts and returns the full `Schema.model_profiles/1` profile maps unchanged plus the default profile id, so provider/model/generation metadata is available to consumers even though the current selector identifies profiles by id.
2. `list_custom_agents` transfers full definitions + script + script_status; only agent ids and script non-empty-ness are consumed.
3. `NodeContext.projects/1` transfers `%EvoGit.VCT.Mount{point, path, name, kind, last_opened_at}` rows, newest first; `last_opened_at` and `kind` are never read here (the VCT owns the ordering), while `point` is consumed only as the display identity of an active project.
4. `read_project_config` transfers the full parsed genesis.toml; `"worktree"`, `"script"`, `"commands"`, `"foreign_repos"` are consumed.
5. `github_upstream` map's `url` is never read (only `owner`, `repo`, `gh_available`).

## Path autocomplete & Windows handling

`Project.path_suggestions/3` matches typed text against the already-loaded project mounts' OS paths as a case-insensitive SUBSTRING (infix), deduped over `ProjectFlow.absolute_path_for_node?/2`, capped at 8 and project paths first; filesystem entries come from `EvoGit.PathSuggestions.suggest/1` (local) or `NodeContext.list_path_suggestions/2` (remote), so `<dir>/` lists that directory and `~` lists home identically on both branches. Backslashes are normalized to `/` before suggestion/dir checks; the expanded path is what gets validated (`NodeContext.dir?/2` remotely, `File.dir?/1` locally), stored in the URL and registered in the VCT.

## Memory

The page keeps summary maps only — `projects` (`%EvoGit.VCT.Mount{}` rows, display-only), `notified_task_ids` (a `MapSet` of ids), plus the sidebar lists owned by `NodeAware`. No full `%TaskInfo{}` row is retained in assigns; notification titles are computed in the spawned scan and discarded after `push_event`.

## Open-project / selection state persistence (where the "current project" lives)

There is exactly ONE active project per page (`active_project` + `active_project_path`): there is no project tab list, no tab bar and no `workspace` concept anywhere in this node.
`active_project` is a display-only `%{path: path, name: name, point: point}` map, where `point` comes from the PURE `ProjectFlow.mount_point_for/2` lookup over the already-loaded `@projects` on a LOCAL activation (never an extra RPC/read); the UI renders `active_project.name` as the visible project identity with `active_project.path` as the secondary line, and the point is kept only as the registry/search/forget identity.
A REMOTE activation takes its point from `ProjectFlow.remote_project_load/2` through the shared private normalizer `mount_project_point/3`, which unwraps the doubly-wrapped `SafeCall.run/1` + `NodeContext.mount_project/3` result and maps every failure shape (outer/inner `{:error, …}`, non-mount payload, non-binary point) to nil.
A nil point is simply not rendered (never a display fallback).
The open project is carried in URL query params — `?project=<absolute path>`, plus `&node=<target id>` in a remote context, hand-built by `project_url/2` (`project_flow.ex`, duplicated in `projects_live.ex`) and never via `Helpers.with_node_param/2` (it appends `?` and would corrupt the existing query).
`handle_params/3` re-derives the project from that param on every navigation: local → `ProjectFlow.normalize_project_path/1` + `File.dir?/1` then `activate_project/2` (relative/blank params are ignored, an existing-but-invalid absolute path clears the project); remote → `ProjectFlow.normalize_remote_project_path/2` + `spawn_remote_project_activation/2,3` (gated on no pending target / no active remote gate).
Browser persistence is `sessionStorage` ONLY under the single key `dashboard_state` (never `localStorage`), owned by the `StatePersistence` JS hook on `#dashboard-root` (`phx-hook="StatePersistence"`; `data-project`, `data-task-mode`, `data-node-id`).
`StatePersistence.maybe_persist_state/1` pushes `persist_state` with keys `project`, `task_mode`, `selected_agent_id`, `quality_level`, `task_prompt`, `task_node_path`, `task_starting_commit`, `task_resume_from`, `show_advanced`, `show_project_settings`, `task_archive`, `foreign_repos` (serialized id/path/description/writable/base_sha), `node`, plus `model_selection_state/1`'s `model_spec` or legacy `selected_model_id`.
Foreign-repo add/edit/remove has NO durable write: `EvoGit.ProjectConfig` exposes only `read/1` plus `write_worktree_script/…` and reads `[foreign_repos]` (`apps/evo_git/lib/evo_git/project_config.ex:152-178`, `:288-299`), so the sessionStorage snapshot is the only copy between launches and a started task freezes it into `opts[:foreign_repos]`.
`:node_path` is the context-tree starting node (`EvoGit.Core.ContextNode.load/3`, default `./`, validated by `Runtime.Helpers.validate_node_path/2`), not a BEAM node — the evolve-only free-text "Starting Node" input is the dashboard's only context-tree addressing surface.
It fires only on server events — mode/agent change, quality level, project-settings toggle, foreign-repo add/edit/remove, successful `task_submit`, and the node-switch clear — so project ACTIVATION pushes no persist event and the saved `project` is refreshed only by a later server persist or by the client watcher (`persistFormState`, 300 ms debounce on `prompt`/`node_path`/`seeds`/`starting_commit` input reading `data-project`).
`maybe_persist_model_selection/1` is the separate merge-only `persist_model_selection` event (`%{node, model_spec}`) that never replaces the prompt.
On mount the hook pushes the saved object back as `restore_state`; the handler gates on `(params["node"] || "local") == (current_node_id || "local")` and restores the project only while `active_project` is nil (URL `starting_commit`/`resume_from` win over the saved ones), activating locally or via `spawn_remote_project_activation/3`.
No server-side record of "the open project" exists: the only core-kept project state is the VCT mount registry persisted in the task store's `vct_mounts` table (`%EvoGit.VCT.Mount{point, path, name, kind, last_opened_at}` — a PROJECT mount lives at `vct:///projects/<basename>`, with `[-N]` suffixes on basename collisions, `path` is its absolute OS path, and no node/workspace column exists; reserved mounts like `vct:///genesis-source` are not project mounts and never appear here), so a fresh mount without `?project=` auto-activates the newest mount via `maybe_auto_activate_project/1` (local context only).
The VCT owns the ordering (`last_opened_at` DESC, nil last) and the cap — `EvoGit.VCT.max_projects/0` (100 by default, app env `:vct_max_projects`), where an over-cap registration evicts the oldest mount — and the palette renders exactly the rows `NodeContext.projects/1` returns.
A mount whose OS path is missing is NORMAL (portability — the mount may belong to another machine/host): it is still listed, never filtered out, and opening it never creates the directory (the directory check decides).
`"vct"` is the project-registry topic: `EvoGit.VCT` broadcasts `{:vct_updated, node}` after every successful mount/forget, and `handle_info({:vct_updated, node}, socket)` skips a node mismatch or a pending remote target, else bumps `projects_seq` and reloads the list off-process.
Projects are node-scoped by each node's own VCT mount table, not by a column: `AsyncLoad.load_projects/3` uses `NodeContext.projects(node)` on a connected remote, `[]` for a pending/failing remote context and the local node's VCT otherwise; every mutation goes through the node-aware RPC (`NodeContext.mount_project/3` inside `ProjectFlow`/palette Enter, `NodeContext.forget_project/2` for local AND remote nodes), and the asset-side paths are the command palette (`ProjectComponents.project_omnibox` + `PaletteList`/`FocusInput`/`PathAutocomplete` hooks) plus `open_project`/`select_project`/`create_project`/`palette_keydown`/`forget_project` events.

## Test strategy

- `test/evo_dash_web/live/projects_live_test.exs` drives the real store; because mount/handle_params work is async, assertions on `projects`, `active_project_path` and notifications use `wait_assigns(view, predicate)` (~300 attempts) instead of asserting right after `live/2`.
- The suite's project fixtures are VCT mounts: `Helpers.seed_project/2` asserts `{:ok, %EvoGit.VCT.Mount{}} = EvoGit.VCT.mount(path, name: name)` and forgets that mount in `on_exit`, `Helpers.clear_projects/0` forgets every registry row, and `Helpers.wait_for_projects/2` polls the page's `projects` assign; palette assertions read `%Mount{}` `point`/`path`/`name`, and forgetting drives the `forget_project` event with `phx-value-point`.
- Canonical task-admission tests must expose the same provider configuration to the singleton `EvoGit.TaskRegistry` as to the test/LiveView; a process-local `ConfigDir.isolate!/1` override propagates through `$callers` to LiveView/loader processes but not to an already-running singleton.
- A picker-visible account absent from the registry's config causes `{:provider_profile_not_found, id}` on both normal and GitHub launches; synchronous launch tests need a restored shared config-directory override rather than weaker model-lock assertions.
- Positive remote URL/resume integration fixtures can inject `:remote_project_load_runner` and `:remote_resume_task_runner` without a live distributed node; restore both app-env keys after each test and serialize tests mutating these shared keys.
- Positive remote persistence fixtures still require a distinct remote BEAM identity, an owned bundle and ready state; target-id plus local BEAM identity represents a pending target and must not persist or consume async batches.
- Unreachable remote tests assert an unavailable bundle, false readiness and a load error, not a successful empty Auto selection; an earlier explicit or pending selection remains preserved on failure.
- The batch loader's message shape (`{:async_project_load, node, prev_node_id, path, results}`) and `AsyncLoad.handle_result/5`'s `{socket, applied?}` return are test-pinned; keep `handle_result/5` tolerant of result maps built without newer keys (`Map.get/3`).
- Notification tests seed `notified_task_ids` + `notified_task_ids_ready?: true` explicitly; a test that leaves `ready?` false asserts NO `task_notification` event.
- Node-switch behaviour (state clearing, `&node=` push_patch, gate states, stale-node restore skip) lives in the same file; `<node>` tests register a fake ConnectionManager in the real `EvoGit.RemoteConnection.Registry`.
- A fixture with a non-nil target id and `current_node == node()` is pending-remote to `ModelSelectionScope` and `AsyncLoad.handle_result/5`, even if a fake connection manager calls it connected, so it cannot assert successful picker loading or resume-guard consumption.
- Positive remote persistence fixtures need a distinct BEAM-node atom, a valid bundle, matching `{target_id, beam_node}` scope, readiness true and no load error; local-as-remote and unowned bundles must produce no model-only persistence event.
- The parent page's `change_model_selection/2` must obtain its bundle through `ModelSelectionScope.bundle/1`; checking only `is_map(model_selection)` bypasses the ownership/readiness boundary used by launch and persistence.
- Canonical-lock page assertions are not evidence that `resolved.model_spec` belongs in task opts: the shared helper already reconstructs canonical picker maps, core admission preserves them, and the Store codec preserves nested string keys.

## Constraints

- Keep `projects_live.ex` from growing: new loaders go into `async_load.ex` / `notifications.ex` / a new small support module — not the main file (it is already ~3 000 lines and is the page's event surface).
- Every new async message needs: a unique tag, a monotonic seq assign when more than one can be in flight, and a node (+ context, e.g. path/task id) stale guard. Never apply a result keyed only by "latest".
- No polling. All PubSub handling stays node-filtered through `NodeAware.event_from_current_node?/2`; the 300 ms debounce is the only coalescing mechanism.
- No `try/rescue` around store/RPC calls — use `EvoDash.SafeCall`. No `String.to_atom/1`/`to_existing_atom` on client input (whitelist maps only).
- User-facing strings are `gettext`-wrapped; never run gettext extract/merge during feature work.

## Deferred — the `select_tasks_page` round

- The Projects page task cards come from the sidebar summary loader (`NodeAware`), not from a dedicated paged selector; if the page ever needs its own paged list, it must use `EvoGit.TaskRegistry.select_tasks_page` rather than `list_tasks_paginated`.
