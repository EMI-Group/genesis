# `evo_git` — Config Test Tree

## Intent
ExUnit suites for `EvoGit.Config`'s schema/metadata layer: the schema contract, the Ecto validation engine, the static LLM catalog, the per-model generation-parameter filtering, and the version-state file.
These are the per-module suites.
The **whole-app `EvoGit.Config` behaviour** (the `resolve/0` pipeline — `deep_merge` → `atomize_enum_values` → `migrate_llm_models`, TOML loading, credentials, `XDG_CONFIG_HOME` isolation, sandbox-backend atomization, the `[llm]` compression/pruning keys) is pinned by `../config_test.exs`, which lives at the PARENT node (`evo_git/`).

## API Surface
No source files — test-only node.

## Routing Table
- No child directories. The parent `../CONTEXT.md` holds the cross-cutting async-safety policy and the top-level `*.exs` map.

## Files

| File | Module | async | Scope |
|------|--------|-------|-------|
| `schema_test.exs` | `EvoGit.Config.SchemaTest` | `true` | End-to-end contract of `EvoGit.Config.Schema` — `all_schemas/0` (currently 104 entries), `schemas_by_category/0` (exact per-category counts), `defaults/0` (every default value, incl. CPU-thread-derived ones and the `[llm]` compression/threshold + stage-1 pruning keys), `validate/1` accept/reject + error shapes, and the `Schema.LLM.*` helpers (model spec / profile parsing, peak-hour fields, `llm_generation_params/1`, `provider_from_model/1`; provider options and constraint filtering belong to `llm_generation_params_test.exs`) |
| `context_window_test.exs` | `EvoGit.Config.ContextWindowTest` | `true` | The context-window resolver in `Schema.LLM` — `default_context_window/0` (`200_000`), `context_window/1` (atom-/string-keyed profile, absent/invalid → default + warning, never raises) and `context_window_for/2` (found profile, unknown id, empty/absent/malformed config → default) |
| `tmp_schema_test.exs` | `EvoGit.Config.TmpSchemaTest` | `true` | The `[tmp]` section — `[:tmp,:mode]` / `[:tmp,:path]` schema shape (type/default/validation/category), `defaults/0` exposure, `validate/1` accept/reject of the mode enum, and string→atom normalization of the mode |
| `ecto_validation_test.exs` | `EvoGit.Config.EctoValidationTest` | `true` | `EvoGit.Config.EctoTypes` + `EvoGit.Config.EctoValidation` — the Ecto layer beneath `Schema.validate/1`: strict no-coercion casting, `nil` ≡ absent, type-then-rule error ordering, byte-exact messages/rules/key_paths, unknown-key survival, integer-indexed profile recursion, crash resilience |
| `llm_catalog_test.exs` | `EvoGit.Config.LLMCatalogTest` | `true` | Static provider/model catalog surface (`EvoGit.Config.LLMCatalog`) — provider entries, model id display names, credential keys, `base_url` / variant rules |
| `llm_generation_params_test.exs` | `EvoGit.Config.LLMGenerationParamsTest` | `false` | Per-model/-provider generation-parameter filtering: `Schema.LLM.provider_options_for_model/1` + `default_provider_options/0` (native OpenAI keeps `store: false`, compatible endpoints and extra-bearing endpoints do not), `profile_generation_params/1` (temperature / `max_tokens` / `reasoning_effort` clamping), `model_metadata/1` + `constraints_for/1` over the injected `:llm_model_metadata_fun`, and the `LLMConstraints.filter/3` reject tables |
| `version_state_test.exs` | `EvoGit.Config.VersionStateTest` | `false` | `EvoGit.Config.VersionState` — version-state TOML file, cache, upgrade + onboarding detection |

## Constraints
- `async: true` for every file here EXCEPT `version_state_test.exs` and `llm_generation_params_test.exs`.
- Test module names mirror the source module under test (`EvoGit.Config.Schema` → `…SchemaTest`).
- No mocks; all assertions are pure data transformations (no git, no temp repos needed in this directory).
- Never edit files outside this node — `../config_test.exs` and `../CONTEXT.md` belong to the parent node.

## Async-Safety Notes
`version_state_test.exs` is `async: false`: each test mutates two BEAM globals observed by other concurrently running modules — the `XDG_CONFIG_HOME` env var (resolved by `EvoGit.Platform.config_dir/0`, which `VersionState.path/0` reads) and the `{EvoGit.Config.VersionState, :version_state}` `:persistent_term` cache served by `VersionState.get_version/0` (also read by the `:evo_dash` suites `welcome_complete_live_test`, `page_controller_test`, …).
`llm_generation_params_test.exs` is `async: false`: its metadata-lookup seam is the BEAM-global app-env key `:llm_model_metadata_fun`, which the module writes per test and deletes in `on_exit`.
The other six files are `async: true`: everything under test is pure data transformation (`Schema`, `EctoTypes`, `EctoValidation`, `Schema.LLM`'s context-window resolver, the static `LLMCatalog`, the pure `EvoGit.PeakHours` validators) plus the read-only `EvoGit.Platform.cpu_threads/0` — no app env, `:persistent_term`, ETS, process, or application singleton is read or written.

## Notes for Agents
- Test counts: `../config_test.exs` 76, `schema_test.exs` 119, `ecto_validation_test.exs` 39, `llm_generation_params_test.exs` 47, `llm_catalog_test.exs` 28, `version_state_test.exs` 15, `context_window_test.exs` 12, `tmp_schema_test.exs` 7.
- Ownership boundaries — do NOT re-add a duplicate of a behaviour a sibling already owns: `llm_generation_params_test.exs` owns `provider_options_for_model/1` / `default_provider_options/0` / `profile_generation_params/1` and the `LLMConstraints.filter/3` reject tables; `schema_test.exs`'s `describe "defaults/0"` owns the `Schema.defaults/0` value set (only the scheduler-defaults shape stays in `../config_test.exs`); `ecto_validation_test.exs` owns numeric-string rejection for every integer type.
- Express a per-input family as ONE table-driven test (a list of `{input, expectation}` cases inside a single `test`) instead of N single-assertion tests; every case still runs.
- These suites assert sub-millisecond pure functions, so removing tautologies and duplicates buys no measurable wall clock — duplicate pruning here is about ownership clarity, not speed.
- `schema_test.exs` asserts EXACT counts: `length(Schema.all_schemas()) == 104` and one exact count per category (`grouped[:data] == 3`, `grouped[:sandbox] == 19`, `grouped[:llm] == 12`, …). Adding or removing a schema in `EvoGit.Config.Schema.Definitions` moves BOTH the total and its category count — update both, and re-run the file (do not guess).
- `EvoGit.Config.__atomize_enum_values__/1` (`lib/evo_git/config/config.ex`, exposed as a `@doc false` test seam) is a hardcoded per-key-path clause list (currently `:sandbox`, `:git`, `:tmp`, `:llm`), NOT derived from `Schema` metadata. A new `type: :atom` schema with `validation: [in: [...]]` needs a matching clause there or its string values never atomize.
- The `[tmp]` mode enum is `[:system, :custom, :per_repo]`; `Schema.validate/1` reports a rejected value as `rule: {:in, [:system, :custom, :per_repo]}` with `key_path: [:tmp, :mode]`.
