# ProjectsLive Support-Module Tests

## Intent

This directory contains ProjectsLive support-module unit tests and focused mounted workbench tests.
The broader mounted ProjectsLive integration suite lives in the parent directory's `projects_live_test.exs`.

## API Surface

- `project_test.exs` covers legacy `Project.load_model_profiles/0,1` and the injected-config seam `Project.load_model_profiles_from_config/2`.
- `project_flow_test.exs` covers local/remote path normalization, node-aware foreign-repo construction/restoration, and path suggestions over the loaded VCT mounts. Its sync `ProjectFlowVctTest` mounts a real per-test-unique VCT row and pins `mount_point_for/2` plus `AsyncLoad.filter_absolute_projects/1` against actual `%EvoGit.VCT.Mount{}` rows.
- `state_persistence_test.exs` covers `StatePersistence.maybe_restore_foreign_repos/2` and `serialize_foreign_repos/1` on minimal LiveView sockets.
- `launch_options_test.exs` covers the shared normal/GitHub launch boundary, explicit canonical `model_spec` locking, Auto stripping carried locks, default selection with rules enabled, reasoning omission without an inventory, custom agent/quality options, owned-ready remote launches, and strict stale/unloaded/pending/unowned/unavailable-selection errors.
- `model_selection_persistence_test.exs` covers canonical-field-only serialization, pending canonical/legacy restore precedence, explicit Auto, invalid input, pending-remote isolation, reconciliation, owned-ready remote persistence and blocked pending/unowned/unavailable bundles, and separate full-state versus node-scoped partial-selection push events.
- `async_load_selection_test.exs` covers `AsyncLoad.handle_result/5` node/path/target/generation guards, the pending-remote `default_batch/6` early return, canonical bundle projection, late user-choice preservation, pending restore reconciliation and same-node stale-provider removal.
  A dropped/stale result now settles instead of returning silently: a socket holding no usable bundle records `:model_selection_superseded` / `:model_selection_pending_remote` with readiness false (never `ready? == false` with no error), a socket holding an applied, owned valid bundle keeps readiness with no error, and a result map lacking the `:model_selection` key lands its other keys while recording `:model_selection_missing`.

- `inline_settings_test.exs` follows the rendered New task patch, checks mode-specific form controls and persistence, and exercises foreign-repository validation and add/edit/remove through the rendered inline Project Settings forms.
- `shared_composer_test.exs` follows both rendered overview entry points, checks the task composer and its quality-control persistence event, and changes the Assistant form to prove the unsent project draft survives a remount without a session.
  Its Assistant test awaits `#workbench-project-overview a#overview-chat-assistant[href]` (`await_assistant_link/2`, a bounded poll that flunks with the rendered overview state) before clicking, because the overview renders a DISABLED `button#overview-chat-assistant` plus the project-picker hint until the connected mount's async VCT batch (`{:async_project_load, …}`) applies the project's registry row — that link is the settled evidence.

## Constraints

Tests default to `async: true`.
`ProjectFlowVctTest` is synchronous because it writes the shared `EvoGit.VCT` mount table and only forgets its own fixture.
`AssistantComposerTest` is synchronous because its connected Assistant mount writes `EvoDash.ChatHistory` and it seeds a VCT mount for draft scope.
The manual composer and inline settings mounts select projects through the URL without changing VCT or launching a task.
The canonical-selection suites use in-memory config maps and sockets, never app-env runner overrides, task launches, network calls or global state mutations.
Canonical bundle fixtures call the public `Project.load_model_selection_from_config/2` API rather than mocking the core resolver.
`ProjectTest` isolates configuration per process with `EvoDash.Test.ConfigDir.isolate!/1` and can inject local resolved configuration through `Process.put(:memo_config_resolve, config)`.
Fake remote nodes exercise RPC degradation or pure scope checks only, not successful remote configuration loading.
`ProjectFlowTest` installs its `:remote_path_expand_runner` fake with `EvoDash.Test.Seam.put/2`, so it reaches only that test's socket and no concurrently running module.
Minimal sockets for foreign-repository StatePersistence tests include `assigns.__changed__: nil`, `remote?: false`, and `current_node: node()` before overrides.
Canonical persistence and async-result sockets also initialize `private.live_temp` so emitted push-event payloads can be asserted directly.
`StatePersistence.maybe_persist_model_selection/1` requires an owned ready canonical bundle, no load error and no pending restore, so a remote positive fixture needs `current_node` different from `node()`, matching `model_selection_scope: {current_node_id, current_node}`, `model_selection: selection()`, `model_selection_ready?: true` and `model_selection_error: nil`.
The partial-persistence positive fixture uses a distinct remote BEAM node and matching owned-ready canonical bundle, and asserts the exact `persist_model_selection` payload contains only canonical picker fields and the target id, never prompt data or credentials.
The same test pins explicit remote Auto and no-op persistence for a pending remote target, absent bundle, missing or stale target/node scope, false readiness, load error, nil selection and pending canonical/legacy restores.
Missing ownership/readiness fields remain compatible only for valid unstamped local bundles; adding a blanket false-readiness default to the socket helper changes the existing loaded-local restore fixtures' meaning.

## Coverage Boundaries

The mounted tests drive server-rendered events but do not execute the browser's native `<details>` opening or browser storage hooks.
These mounted tests exercise local-node controls; they do not assert remote inline settings behavior.
`workspaces_test.exs` checks that the palette renders the Open Project by Path and Create New Project actions, but it does not submit either regular-project form.
The parent `../projects_live_test.exs` owns the legacy `open_project` and `create_project` success submissions, while `../projects_workbench_test.exs` drives the palette's mounted `ProjectWindow` for both modes and asserts navigation to the registered overview and exact `data-workbench-default-draft` equality to the Chat with Assistant href.
Legacy Project profile-selection assertions expect the first configured profile id without a selection script, the empty-string Auto sentinel with a script, `{[], nil}` for no profiles without a script, and `{[], ""}` for no profiles with a script.
Remote legacy profile loading must ignore a local `:memo_config_resolve` and degrade to `{[], nil}` on an unreachable node.
Canonical launches distinguish nil/uninitialized selection, which locks the configured default even with rules enabled, from explicit empty-map/empty-string Auto, which removes every model lock.
LaunchOptions tests exercise normal/GitHub-shaped option payloads through their shared helper but do not prove the mounted normal-submit or GitHub-fix callsites invoke it.
Pure async-result tests exercise exposed `AsyncLoad` guards directly but do not prove mounted message routing, browser sessionStorage merge behavior or node switching.
A connected-remote batch fixture stamps `results.load_scope` as `%{seq: projects_load_seq, node_id: current_node_id, selection: selected_model_spec_at_spawn}` and passes the matching remote BEAM node, target id and active project path to `AsyncLoad.handle_result/5`.
The pending-remote test deliberately retains a non-nil target id while setting `current_node: node()` and proves that even a correctly stamped batch is rejected unchanged, so a stamp cannot turn a same-node placeholder into a connected remote fixture.
The page owns the node-identity check before `StatePersistence.maybe_restore_model_selection/2`; that precondition requires mounted coverage in the parent test node.
Source API contracts and mounted submit/restore/stale-message tests belong to the source ProjectsLive node and the parent test node respectively.
Canonical `Project.load_model_selection/1` loading is not directly tested here; local memo isolation and unreachable-remote degradation assertions in `project_test.exs` exercise only the legacy profile loader.
The canonical async-result suite does not directly pin failed/unavailable bundle application or recovery after a failed bundle.
`LaunchOptionsTest` pins owned-ready remote explicit/Auto success and exact rejection reasons for pending remote, absent/stale target or BEAM ownership, false readiness, load error and pending canonical/legacy restore across normal/GitHub-shaped payloads and nil/explicit/Auto selections.
Browser restore node validation, actual event routing into helpers, sessionStorage partial-merge preservation of prompt data and normal/GitHub callsite wiring require mounted or JavaScript coverage outside this directory.
`retry_model_selection` (`projects_live.ex:1119` → `AsyncLoad.maybe_spawn(socket, current_node_id)`) is driven from the rendered `#model-selection-loading-retry` while a batch is still running, by a mounted test in `../projects_live_test.exs` ("the loading state offers a retry that re-runs the batch"); its refusal path for a pending remote target / active connection gate stays unproven there.
The picker's LOADING render state is pinned (`#model-selection-loading` + "Loading models…" + the retry affordance) by that same mounted test; the `#model-selection-error` banner (`projects_live.ex:158-177`) is still only asserted through the `model_selection_error` assign.
A mounted test writes the isolated per-test `config.toml` and raises the core's own `{:config_reloaded, node, dir, generation}` broadcast (via `EvoGit.Config.Cache.reload/0`), proving a provider-profile add becomes picker-visible with NO remount; a REAL `EvoGit.Config.save_user_config/1` save path and the reload generation guards are driven through `handle_info/2` on a hand-built socket, not through a mounted Settings save.
The task-form picker never renders an `:openai_codex` (Sign in with ChatGPT) profile in any test; `openai_codex`/`auth_mode` fixtures exist only in the Settings, Welcome and components suites (`chatgpt_stream_test.exs` covers streaming), so provider-model availability is never asserted to be credential-independent in the picker.

## Routing Table

This directory has no child subdirectories.
## Mounted Page Contracts (owned by `../projects_live_test.exs`)
Normal submissions and GitHub issue fixes share canonical `model_spec` selection plus `model_id_locked: true`, and explicit Auto omits all three override keys rather than locking the configured default.
`assert_task_model_selection/2` pins the exact canonical task opts, the explicit lock and the absence of legacy option keys, without assuming the derived persisted `task.model_id` is nil for an explicit selection.
Mounted selection tests pin picker events, reasoning inventories, canonical session-state restore, pending remote contexts and node/path/target/generation stale-result rejection.
The model-only browser persistence event is `persist_model_selection`, separate from prompt/form state persistence.
Unavailable remote bundles retain nil or a saved canonical choice instead of selecting Auto; recovery requires an owned-ready canonical bundle.
The three positive remote URL/resume fixtures use distinct fake BEAM identities with target-owned connection status and canonical batch bundles, never a local fallback.
`install_remote_activation_fixture!/2` installs the arity-2 `:remote_project_load_runner` (`node, path`) and `:remote_resume_task_runner` (`node, task_id`) through `EvoDash.Test.Seam.put_all/1` and proves the real supervised children receive the exact remote identity.
The tilde fixture lives in the async module like the other remote fixtures: its seam override is chain-scoped, so it cannot reach another module's page.
Focused remote validation targets the three named positive URL/resume tests and establishes focused coverage only, never full-suite validation; never bypass the pending-remote guard to make them pass.
Mounted project fixtures are VCT mounts: `Helpers.seed_project/2` asserts `{:ok, %EvoGit.VCT.Mount{}} = EvoGit.VCT.mount(path, name: name)` and forgets that mount in `on_exit`, `clear_projects/0` forgets every row, and page assertions read `%Mount{}` rows (`point`/`path`/`name`) off the `projects` assign.
The async module mounts per-test-unique basenames and asserts only its own rows; whole-registry and global-quiet assertions live in `ProjectsLiveSyncTest`.

### Async mount batch
`:projects_async_load_runner` is a 0-arity fun returning the results map the batch applies: `projects` (the node's VCT mounts), `terminal_ids` (`MapSet` seed or `nil`), `auto_activate?`, `model_selection` + `model_selection_enabled` and `custom_agents`, plus the remote-only extras; every key the apply step does not consume is assigned verbatim.
A LEGACY payload carrying `model_profiles` must also carry `default_selected_model_id`; canonical batches carry `model_selection` instead.
Success message: `{:async_project_load, node, prev_node_id, path, results}`; a runner that exits/raises sends NOTHING, so the page keeps the mount defaults `projects: []` / `notified_task_ids_ready?: false`.
`install_projects_async_load_runner/1` writes the fixture with `EvoDash.Test.Seam.put/2`, so exactly this test's page and its supervised batch resolve it; `EvoDash.Seam.get/2` reads it before app env.
Helpers: `install_projects_async_load_runner/1`, `restore_registry_on_exit/0` (frozen-registry safety net), `wait_for_projects/2`, `wait_notified_ids_ready/1` (both via `wait_assigns/2`) and `await_async_loads/1` (synchronous `assigns/1` drain FIRST, then monitor this view's `EvoDash.TaskSupervisor` children via `$callers`).
A test that seeds projects and then asserts palette contents / path suggestions / auto-activation must settle the mount batch right after `live/3`; notification tests must call `wait_notified_ids_ready/1` BEFORE `send(view.pid, :node_aware_reload_tasks)` and `await_async_loads/1` before `assert_push_event` / `refute_push_event`.
Off-process proof: `:sys.suspend(EvoGit.TaskRegistry)` (+ `restore_registry_on_exit/0`), send `:node_aware_reload_tasks`, and show the synchronous `assigns/1` round-trip returns while the store is frozen (`mount_async_task_pids(view.pid) != []`), then resume; a zero-store mount proof freezes the registry around BOTH the dead render and `live/3`.
A blocked-batch test makes "the project list not present yet" deterministic: the injected fun sends `{:batch_started, self()}`, blocks on `receive`, then returns; assert the mount defaults, send `:proceed`, then wait for the batch.

### Resume restore and repo fixtures
The `?resume_from=` foreign-repo restore is ASYNC: `start_foreign_repos_restore/2` spawns a child that replies `{:foreign_repos_restored, task_id, node, result}`, so reading `assigns(view)[:foreign_repos]` straight after `live/3` is a race — wait on `active_project_path` (or `await_async_loads/1`) first.
An empty assign has two other load-dependent sources: `TaskRegistry.get_task_lite/1`'s offloaded read degrading to `nil` at its 28 s `ReadOffload` deadline, and a `GenServer.call` timeout arriving as `{:error, _}` from `SafeCall`; both leave `[]` untouched (the error arm only adds a flash).
The page suite builds ONE `git init` + empty-commit template in `setup_all` and gives every repo-needing test a `File.cp_r!` copy (~3.5 ms per copy against ~13 ms for a fresh `git init` + commit) — always a plain recursive byte copy, never hard links or `git clone --shared`, with `.git/hooks` sample scripts dropped from the template.
`ProjectFlowTest` installs its `:remote_path_expand_runner` fake with `EvoDash.Test.Seam.put/2` (chain-scoped, no global restore needed).
