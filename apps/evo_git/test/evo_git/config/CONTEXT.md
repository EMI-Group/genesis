# `evo_git` — Config Test Tree

## Intent
ExUnit suites for the config schema/metadata layer, canonical provider-account normalization and model selection, generation-parameter filtering, static LLM catalog and version-state file.
Whole-app config resolution, TOML roundtrips, save/load and legacy migration through `EvoGit.Config.resolve/0` belong to the parent `../config_test.exs`, not this node.
`config_status_test.exs` owns focused disk-backed public `Config.config_status/0` regressions for invalid canonical defaults, initial validation-error snapshots across a successful nested resolve, and fresh healthy status after repair.
The parent `../config_test.exs` retains the broader config-health, OAuth and persistence coverage, while this node also owns the pure `Schema.validate/1` and `Schema.resolve_model_spec/2` selector contracts.

## API Surface
This is a test-only node with no production code.
Tests call the public `EvoGit.Config.Schema` entry points and schema/metadata helpers.

## Routing Table
There are no child directories.
The parent `../CONTEXT.md` and `../../CONTEXT.md` own the cross-cutting async-safety policy.

## Files

| File | Module suffix | async | Scope |
|------|---------------|-------|-------|
| `schema_test.exs` | `SchemaTest` | `true` | Existing end-to-end schema contract, exact 106 descriptors and per-category counts (14 LLM), defaults, validation and legacy LLM helpers |
| `provider_profiles_test.exs` | `ProviderProfilesTest` | `true` | Public `Schema.provider_profiles/1` and `model_selections/1`: canonical-over-legacy precedence, recursive string-key normalization, ordered account/model/effort inventories, same-provider account isolation, legacy string/map/tuple/flat adapters, malformed-input degradation, context inheritance and pure OAuth runtime projections |
| `provider_profile_resolution_test.exs` | `ProviderProfileResolutionTest` | `true` | Public `Schema.resolve_model_spec/2`: account/model/effort default precedence and explicit overrides, atom/string inputs, exact errors, generation/context inheritance, shared scheduling/auth/endpoint authority, ReqLLM-ready string/map model specs, account credentials and OAuth options |
| `provider_profile_validation_test.exs` | `ProviderProfileValidationTest` | `true` | Canonical schema descriptors and raw provider/model validation: indexed error paths, type/range failures, duplicate account/model/effort identities and default membership, shared settings, nested context/generation overrides |
| `config_status_test.exs` | `ConfigStatusTest` | `true` | Public config health: usable canonical account with invalid default, exact selector error with no missing keys, successful nested-resolve snapshot preservation, and healthy subsequent/fresh invocations |
| `context_window_test.exs` | `ContextWindowTest` | `true` | `Schema.LLM` default 200000 context window, atom/string profile keys, invalid fallback and id lookup |
| `tmp_schema_test.exs` | `TmpSchemaTest` | `true` | `[tmp]` schema metadata, defaults, enum validation and string-to-atom normalization |
| `ecto_validation_test.exs` | `EctoValidationTest` | `true` | Strict scalar casting, nil/absent semantics, error ordering/shapes, unknown keys, indexed profile recursion and crash resilience |
| `llm_catalog_test.exs` | `LLMCatalogTest` | `true` | Static catalog providers/models, credential keys, auth modes, endpoints and variants |
| `llm_generation_params_test.exs` | `LLMGenerationParamsTest` | `false` | Provider-aware generation/OAuth options, constraints and metadata seam |
| `version_state_test.exs` | `VersionStateTest` | `true` | Version-state TOML, path-aware cache, upgrade and onboarding detection |

## Constraints
Only `llm_generation_params_test.exs` is synchronous because it mutates the BEAM-global `:llm_model_metadata_fun` and `:auth_home_fun` app-env seams.
All other modules default to `async: true` and must not mutate shared app env, OS env, scheduler state or ReqLLM provider keys.
The resolver suite uses per-process `EvoGit.TestSupport.ConfigDir` isolation and unique custom credential names without the `_API_KEY` suffix, so loading their credentials cannot populate ReqLLM's global key store.
The config-dir seam supplies a parent directory and `Platform.config_dir("genesis")` appends `genesis`, so fixtures obtain the actual credentials directory through `EvoGit.Config.config_dir/0`.
Resolver generation assertions use catalog-absent test model ids rather than a mutable global metadata seam.
OAuth resolver option assembly uses an uncatalogued provider to avoid importing the developer's vendor CLI login, while real OAuth-only provider inheritance is covered through pure normalization/runtime-profile projection.
The config-health suite also uses a custom credential name without an `_API_KEY` suffix so credential loading cannot mutate ReqLLM's global key store.
Its POSIX-only nested-resolve test uses a test-owned credentials FIFO to hold the health check after initial validation, repairs the config before releasing EOF, and proves the later nested resolve cleared the caller-local errors while the returned status retained the initial exact error.
Both writer-side file operations use raw I/O because the shared file server is waiting for the credentials read to finish.
The FIFO rendezvous uses no sleep, timing race, app-env override, global tracing or OS-env mutation and is skipped on Windows; the remaining health tests are cross-platform.
The environment-over-persisted credential test only reads the existing `PATH` value and never writes an OS environment variable.
`version_state_test.exs` is async-safe because the version-state cache stores its path and reclassifies whenever the per-process path changes.
Never edit files outside this node; the parent roundtrip suite and parent context documentation have separate owners.
Keep new focused suites below roughly 1000 lines and express related input families as table-driven cases without dropping assertions.
No mocks or real LLM requests are used here.

## Contract Notes
`llm.providers` and `llm.default_provider_profile` are canonical schema entries alongside legacy `llm.models` and flat `llm.model` adapters.
A nonempty canonical inventory wins over legacy data even when every canonical entry is malformed.
Provider profiles normalize to string-keyed maps; selection and resolved envelopes have atom keys.
Account/model/effort ordering is preserved, one selection is emitted per model rather than per effort, and an effort inventory never invents a default.
Provider defaults apply before nested model context/generation/effort overrides, while auth, endpoint and concurrency settings remain shared account authority.
`resolved.model_spec` is a ReqLLM-ready qualified identifier or endpoint-bearing model map, not the persisted task selection map.
`resolved.generation_params` can contain the selected account's API credential and must not be assumed credential-free.
Canonical validation checks raw input before normalization can discard malformed values or deduplicate inventories.
Duplicate effort errors include the duplicate element's index, context-window validation uses rule `:integer`, and auth-mode validation uses rule `:string` for compatibility with the shared legacy validators.
There is no global `[llm] oauth_file` schema key; OAuth files are per account/profile.
`Schema.all_schemas/0` has exactly 106 entries and its LLM category has exactly 14, so adding/removing descriptors requires updating both count assertions.
`Config.__atomize_enum_values__/1` remains a hardcoded per-key-path normalization list rather than schema-derived behavior.
The `[tmp]` enum is `[:system, :custom, :per_repo]`, with rejected values reported at `[:tmp, :mode]` under the corresponding `{:in, ...}` rule.

## Test Inventory
This node contains 360 tests across eleven modules.
Per-file counts are schema 122, provider normalization/enumeration 14, provider resolution 21, provider validation 12, config health 3, Ecto validation 48, generation parameters 66, catalog 40, version state 15, context window 12 and tmp schema 7.
Run the complete node with `mix test apps/evo_git/test/evo_git/config` from the umbrella root.
