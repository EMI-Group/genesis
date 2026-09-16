# `evo_git` — Config Test Tree

## Intent
ExUnit suites for `EvoGit.Config`'s schema/metadata layer: the schema contract, the Ecto validation engine, the static LLM catalog, and the version-state file.
These are the per-module suites.
The **whole-app `EvoGit.Config` behaviour** (the `resolve/0` pipeline — `deep_merge` → `atomize_enum_values` → `migrate_llm_models`, TOML loading, credentials, `XDG_CONFIG_HOME` isolation, sandbox-backend atomization) is pinned by `../config_test.exs`, which lives at the PARENT node (`evo_git/`) and is owned by another agent — read it for reference, never edit it from here.

## API Surface
No source files — test-only node.

## Routing Table
- No child directories. The parent `../CONTEXT.md` holds the cross-cutting async-safety policy and the top-level `*.exs` map.

## Files

| File | Module | async | Scope |
|------|--------|-------|-------|
| `schema_test.exs` | `EvoGit.Config.SchemaTest` | `true` | End-to-end contract of `EvoGit.Config.Schema` — `all_schemas/0` (currently 97 entries), `schemas_by_category/0` (exact per-category counts), `defaults/0` (every default value, incl. CPU-thread-derived ones), `validate/1` accept/reject + error shapes, and the `Schema.LLM.*` helpers (model spec / profile parsing, peak-hour fields, generation params, provider detection) |
| `tmp_schema_test.exs` | `EvoGit.Config.TmpSchemaTest` | `true` | The `[tmp]` section — `[:tmp,:mode]` / `[:tmp,:path]` schema shape (type/default/validation/category), `defaults/0` exposure, `validate/1` accept/reject of the mode enum, and string→atom normalization of the mode |
| `ecto_validation_test.exs` | `EvoGit.Config.EctoValidationTest` | `true` | `EvoGit.Config.EctoTypes` + `EvoGit.Config.EctoValidation` — the Ecto layer beneath `Schema.validate/1`: strict no-coercion casting, `nil` ≡ absent, type-then-rule error ordering, byte-exact messages/rules/key_paths, unknown-key survival, integer-indexed profile recursion, crash resilience |
| `llm_catalog_test.exs` | `EvoGit.Config.LLMCatalogTest` | `true` | Static provider/model catalog surface (`EvoGit.Config.LLMCatalog`) — provider entries, model id display names, credential keys, `base_url` / variant rules |
| `version_state_test.exs` | `EvoGit.Config.VersionStateTest` | `false` | `EvoGit.Config.VersionState` — version-state TOML file, cache, upgrade + onboarding detection |

## Constraints
- `async: true` for every file here EXCEPT `version_state_test.exs`.
- Test module names mirror the source module under test (`EvoGit.Config.Schema` → `…SchemaTest`).
- No mocks; all assertions are pure data transformations (no git, no temp repos needed in this directory).
- Never edit files outside this node — `../config_test.exs` and `../CONTEXT.md` belong to the parent node.

## Async-Safety Notes
`version_state_test.exs` is `async: false`: each test mutates two BEAM globals observed by other concurrently running modules — the `XDG_CONFIG_HOME` env var (resolved by `EvoGit.Platform.config_dir/0`, which `VersionState.path/0` reads) and the `{EvoGit.Config.VersionState, :version_state}` `:persistent_term` cache served by `VersionState.get_version/0` (also read by the `:evo_dash` suites `welcome_complete_live_test`, `page_controller_test`, …).
The other four files are `async: true`: everything under test is pure data transformation (`Schema`, `EctoTypes`, `EctoValidation`, the static `LLMCatalog`, the pure `EvoGit.PeakHours` validators) plus the read-only `EvoGit.Platform.cpu_threads/0` — no app env, `:persistent_term`, ETS, process, or application singleton is read or written.

## Notes for Agents
- `schema_test.exs` asserts EXACT counts: `length(Schema.all_schemas()) == 97` and one exact count per category (`grouped[:data] == 3`, `grouped[:sandbox] == 19`, …). Adding or removing a schema in `EvoGit.Config.Schema.Definitions` moves BOTH the total and its category count — update both, and re-run the file (do not guess).
- `EvoGit.Config.__atomize_enum_values__/1` (`lib/evo_git/config/config.ex`, exposed as a `@doc false` test seam) is a hardcoded per-key-path clause list (currently `:sandbox`, `:git`, `:tmp`, `:llm`), NOT derived from `Schema` metadata. A new `type: :atom` schema with `validation: [in: [...]]` needs a matching clause there or its string values never atomize.
- The `[tmp]` mode enum is `[:system, :custom, :per_repo]`; `Schema.validate/1` reports a rejected value as `rule: {:in, [:system, :custom, :per_repo]}` with `key_path: [:tmp, :mode]`.
