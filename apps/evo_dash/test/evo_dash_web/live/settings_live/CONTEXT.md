# SettingsLive Support Tests

## Intent

Focused helper, canonical provider-editor and credential-status page contracts live here.
The five suites declare 108 tests and preserve `async: true`; pure helpers neither mount pages nor start shared services.

## API Surface

- `provider_profiles_contract_test.exs` holds 23 pure contracts for `ProviderProfiles`, `ConfigIO`, `AuthStatus` and detached `ModelProfileEvents` sockets.
- Provider parsing pins string-keyed canonical profiles, numeric ordering of nested models, sparse generation overrides, typed numbers/JSON, blank override clearing back to inheritance and untouched draft round trips.
- Reasoning contracts distinguish inherited inventories/defaults from explicit unrestricted model inventories and reject incompatible inherited defaults.
- CRUD contracts pin append/update/rename/move/delete/default semantics, default identity on rename, boundary no-ops, canonical shadow removal, unrelated-setting preservation and legacy one-account-per-row editing.
- Credential contracts pin canonical `api_key_env_var` precedence and explicit clearing, legacy draft normalization, OAuth secret stripping, OAuth-only authentication, managed-path trimming and secret-free unknown-status adapters.
- `model_profile_helpers_test.exs` holds 41 contracts for canonical Add delegates and the deliberately retained legacy single-model parameter parser, including the comprehensive peak/day/window compatibility matrix.
- Canonical Add writes `llm.providers` with string-keyed profiles and explicit `auth_mode`; nil/empty selections leave config unchanged and new drafts remain detached.
- The legacy `parse_model_profile_params/2` API still returns atom-keyed single-model profiles with its older clean-TOML auth rules; these compatibility assertions must not be confused with canonical provider persistence.
- `config_io_test.exs` holds 10 pure category-conversion contracts for list-of-strings, boolean and float values.
- `auth_status_test.exs` holds 28 credential-status classification/page contracts, including verdict forwarding, node/sequence guards, refresh, canonical auth persistence and editing a legacy OAuth row into `llm.providers` without a shadow `llm.models` table.
- Auth page fixtures deliberately seed legacy `[[llm.models]]` rows to exercise migration; new-profile submissions use canonical `default_model` and detached draft ids, assert the Provider-profile success message and inspect the actual persisted provider table.
- Canonical auth persistence explicitly stores `auth_mode: "api_key"`, drops stale OAuth paths and rejects unsupported OAuth modes while retaining the failed draft without writing it.
- `model_ids_test.exs` holds six retired-id matcher, catalog and mounted-page guards.

## Constraints

Pure suites use the shared test bootstrap, never standalone `ExUnit.start/0` calls, and never patch missing core functions or skip failing integration contracts.
Mounted suites retain per-process `EvoDash.Test.ConfigDir.isolate!/1`, local-only ActiveTasks invalidation and owner-aware async mount settling.
No test may make a real LLM request or rely on shared credentials, scheduler mutation or global ChatHistory.
The larger helper file intentionally keeps the legacy parser with its shared peak/day edge-case matrix, while the canonical contract file keeps parse/draft/CRUD round trips together without additional test modules or shared fixtures.
Production source and core modules are read-only from this node.

## Coverage Boundaries

Multi-model contracts here exercise pure parsing/draft round trips and sparse inheritance, not a mounted multi-model Save → remount/reload cycle.
Auth save contracts assert live canonical providers and `EvoGit.Config.user_config()` persistence with no legacy shadow, but do not remount to prove restored editor state.
The stale-result tests here cover OAuth credential-status node/sequence guards only, not config reload or writer completion generations.
No suite here injects a configuration-writer failure or exercises category reset/reset-all preservation of canonical providers and defaults.
The `:managed_file_unwritable` classification tests concern OAuth credential files, not `config.toml` write failures.
Mounted canonical editor save/reload/reset regressions belong with the parent `settings_live_test.exs`; pure shape and draft regressions belong in `provider_profiles_contract_test.exs`, and config writer atomicity belongs to the core-owned configuration tests.

## Validation and Integration Boundary

Normal `mix test apps/evo_dash/test/evo_dash_web/live/settings_live` and its `--no-start` variant abort before ExUnit because runtime config calls `EvoGit.Config.EctoValidation.type_errors/3` with unsupported `:provider_profiles`.
The core facade also lacks `EvoGit.Config.Schema.provider_profiles/1`, `model_selections/1` and `resolve_model_spec/2`, although the implementation module `Schema.ProviderProfiles` exists.
Standalone execution against compiled test BEAMs runs the three pure files with 63 of 74 tests passing; the remaining 11 fail specifically on the missing public `Schema.provider_profiles/1` facade, so CRUD/legacy integration is not yet validated.
Standalone classification/matcher/catalog selection runs seven tests successfully, with 27 mounted tests explicitly excluded; ConfigIO alone passes all 10 tests.
A standalone pure run uses `elixir -pa '_build/test/lib/*/ebin' -r apps/evo_dash/test/test_helper.exs -r <test-file> -e 'Application.ensure_all_started(:jason)'` after compilation, bypassing runtime configuration without modifying application code.
Mounted-page execution must be rerun after source/core integration; standalone passes do not establish mounted-suite success.
A misplaced duplicate contract test still exists at `apps/evo_dash/lib/evo_dash_web/live/settings_live/provider_profiles_contract_test.exs` and belongs to the source-owning parent, not this node.

## Routing Table

This directory has no child directories.
