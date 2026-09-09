# Test Directory — ProjectsLive support-module unit tests

## Intent

Pure ExUnit unit tests for the `EvoDashWeb.ProjectsLive` support modules' helpers: `project_test.exs` (node-aware model-profile resolution `Project.load_model_profiles/0,1` + pure selection `load_model_profiles_from_config/2`), `project_flow_test.exs` (path normalization, node-aware foreign-repo construction, `Project.path_suggestions`, `Project.load_foreign_repos/3`), `state_persistence_test.exs` (`StatePersistence.maybe_restore_foreign_repos/2` + `serialize_foreign_repos/1`).

## API Surface / File map

- `project_test.exs` — `async: false`. Every test isolates `XDG_CONFIG_HOME` via the private `isolate_config_dir/0` helper (temp dir + env swap, restored in on_exit). Uses a fake remote node atom `:"genesis_remote@127.0.0.1"` (`:erpc` to it fails fast — remote RPC success paths are untestable here).
- `project_flow_test.exs` — `async: true`, no config isolation needed. Exercises `ProjectFlow.normalize_project_path/1`, `normalize_remote_project_path/2` (via the `:remote_path_expand_runner` app-env seam, call-time read), `absolute_path_for_node?/2`, `build_foreign_repo/4`, `repos_from_task_data/2`, `Project.load_foreign_repos/3`, `Project.path_suggestions/2,3`.
- `state_persistence_test.exs` — `async: true`. Exercises `maybe_restore_foreign_repos/2` (node-aware raw-root restore vs local `ForeignRepo.new/3` semantics; writable/base_sha round-trips) and `serialize_foreign_repos/1` (exactly five persisted keys: id/path/description/writable/base_sha).

## Constraints

- No LiveView harness; `state_persistence_test.exs` builds a minimal `%Phoenix.LiveView.Socket{}` with `__changed__: nil` so `assign/3` stays on the Map.put path.
- Host-OS independence: remote-node branches use a fake non-local node atom so Linux-CI runs pin Windows-dashboard behavior (no `Path.expand` of remote/Windows roots, UNC prefix survival).

## Known coupling to the :evo_git config subsystem (Ecto refactor blast radius)

Only `project_test.exs` consumes the config subsystem; the other two files have NO config coupling (their `config` variables in `project_flow_test.exs` hold repo-local genesis.toml-shaped maps, not user config).

- `project_test.exs` aliases `EvoGit.Config`; real-path tests seed `config.toml` via `Config.config_path()` (XDG-based) with `[[llm.models]]` where `model = {provider = "anthropic", id = "claude-sonnet-5"}` is an inline-table MAP form + `concurrency = 3`, then call `Project.load_model_profiles()` which runs `Process.get(:memo_config_resolve) || Config.resolve()`.
- Pinned shapes: `Config.resolve/0` must yield an atom-keyed resolved map `%{llm: %{models: [%{id: "profile-a", ...}]}}`; profile id is the only profile field asserted (`:model` content is NOT pinned). `EvoGit.Config.Schema.model_profiles/1` + `default_model_profile/1` (defdelegated to `EvoGit.Config.Schema.LLM`) drive the pure selection — `%{llm: %{models: []}}` and `%{}` must yield `{[], nil}`/`{:error, :not_found}`, never raise.
- `:memo_config_resolve` Process-dict memo must short-circuit `Config.resolve()` on the LOCAL node branch only (never remote).
- Model-selection script coupling: `EvoGit.CustomAgents.save_model_selection_script/1` + `reload/0` (writes agents.toml into the isolated XDG config dir) flipping the selection to the `""` sentinel via `CustomAgents.ModelSelector.enabled?()`.
- Sentinel contract: no script → first profile's id; script enabled → `""`; no profiles → `nil` (no script) / `""` (script).
- Remote degradation pinned: unreachable node → `{[], nil}` via `NodeContext.get_resolved_config/1` returning `{:error, _}`.
- `project_flow_test.exs` references `EvoGit.Platform.absolute_path?/1` once (path predicate — only relevant if Platform is refactored alongside Config).
