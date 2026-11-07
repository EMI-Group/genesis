# ProjectsLive Support-Module Tests

## Intent

This directory contains three async ExUnit suites for ProjectsLive support-module behavior without mounting a page.
The mounted ProjectsLive integration suite lives in the parent directory's `projects_live_test.exs`.

## API Surface

- `project_test.exs` covers `Project.load_model_profiles/0,1` and the injected-config seam `Project.load_model_profiles_from_config/2`.
- `project_flow_test.exs` covers local/remote path normalization, node-aware foreign-repo construction/restoration, and recent-path suggestions.
- `state_persistence_test.exs` covers `StatePersistence.maybe_restore_foreign_repos/2` and `serialize_foreign_repos/1` on minimal LiveView sockets.

## Constraints

All three modules use `async: true` and require no LiveView mounts or database fixtures.
`ProjectTest` isolates configuration per process with `EvoDash.Test.ConfigDir.isolate!/1` and can inject local resolved configuration through `Process.put(:memo_config_resolve, config)`.
Fake remote nodes exercise RPC degradation only, not successful remote configuration loading.
`ProjectFlowTest` snapshot-restores the global `:evo_dash, :remote_path_expand_runner` seam for tilde expansion.
Minimal sockets for StatePersistence tests include `assigns.__changed__: nil`, `remote?: false`, and `current_node: node()` before overrides.

## Coverage Boundaries

Project profile-selection assertions expect the first configured profile id without a selection script, the empty-string Auto sentinel with a script, `{[], nil}` for no profiles without a script, and `{[], ""}` for no profiles with a script.
Remote profile loading must ignore a local `:memo_config_resolve` and degrade to `{[], nil}` on an unreachable node.
State-persistence coverage here exercises foreign repositories only, not selected provider/model persistence.
No test in this directory exercises LaunchOptions, explicit `model_spec` task locks, normal versus GitHub submit wiring, or asynchronous node/sequence stale guards.
Source API contracts and mounted submit/stale-message tests belong to the source ProjectsLive node and the parent test node respectively.

## Routing Table

This directory has no child subdirectories.
