# ProjectsLive Support-Module Tests

## Intent

This directory contains six async ExUnit suites for ProjectsLive support-module behavior without mounting a page.
The mounted ProjectsLive integration suite lives in the parent directory's `projects_live_test.exs`.

## API Surface

- `project_test.exs` covers legacy `Project.load_model_profiles/0,1` and the injected-config seam `Project.load_model_profiles_from_config/2`.
- `project_flow_test.exs` covers local/remote path normalization, node-aware foreign-repo construction/restoration, and recent-path suggestions.
- `state_persistence_test.exs` covers `StatePersistence.maybe_restore_foreign_repos/2` and `serialize_foreign_repos/1` on minimal LiveView sockets.
- `launch_options_test.exs` covers the shared normal/GitHub launch boundary, explicit canonical `model_spec` locking, Auto stripping carried locks, default selection with rules enabled, reasoning omission without an inventory, custom agent/quality options, owned-ready remote launches, and strict stale/unloaded/pending/unowned/unavailable-selection errors.
- `model_selection_persistence_test.exs` covers canonical-field-only serialization, pending canonical/legacy restore precedence, explicit Auto, invalid input, pending-remote isolation, reconciliation, owned-ready remote persistence and blocked pending/unowned/unavailable bundles, and separate full-state versus node-scoped partial-selection push events.
- `async_load_selection_test.exs` covers `AsyncLoad.handle_result/5` node/path/target/generation guards, the pending-remote `default_batch/6` early return, canonical bundle projection, late user-choice preservation, pending restore reconciliation and same-node stale-provider removal.

## Constraints

All six modules use `async: true` and require no LiveView mounts or database fixtures.
The canonical-selection suites use in-memory config maps and sockets, never app-env runner overrides, task launches, network calls or global state mutations.
Canonical bundle fixtures call the public `Project.load_model_selection_from_config/2` API rather than mocking the core resolver.
`ProjectTest` isolates configuration per process with `EvoDash.Test.ConfigDir.isolate!/1` and can inject local resolved configuration through `Process.put(:memo_config_resolve, config)`.
Fake remote nodes exercise RPC degradation or pure scope checks only, not successful remote configuration loading.
`ProjectFlowTest` snapshot-restores the global `:evo_dash, :remote_path_expand_runner` seam for tilde expansion.
Minimal sockets for foreign-repository StatePersistence tests include `assigns.__changed__: nil`, `remote?: false`, and `current_node: node()` before overrides.
Canonical persistence and async-result sockets also initialize `private.live_temp` so emitted push-event payloads can be asserted directly.
`StatePersistence.maybe_persist_model_selection/1` requires an owned ready canonical bundle, no load error and no pending restore, so a remote positive fixture needs `current_node` different from `node()`, matching `model_selection_scope: {current_node_id, current_node}`, `model_selection: selection()`, `model_selection_ready?: true` and `model_selection_error: nil`.
The partial-persistence positive fixture uses a distinct remote BEAM node and matching owned-ready canonical bundle, and asserts the exact `persist_model_selection` payload contains only canonical picker fields and the target id, never prompt data or credentials.
The same test pins explicit remote Auto and no-op persistence for a pending remote target, absent bundle, missing or stale target/node scope, false readiness, load error, nil selection and pending canonical/legacy restores.
Missing ownership/readiness fields remain compatible only for valid unstamped local bundles; adding a blanket false-readiness default to the socket helper changes the existing loaded-local restore fixtures' meaning.

## Coverage Boundaries

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

## Routing Table

This directory has no child subdirectories.
