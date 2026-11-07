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
- `auth_status_test.exs` holds 28 credential-status classification/page contracts, including verdict forwarding, exact fallback and supplied vendor guidance, node/sequence guards, refresh, canonical auth persistence and editing a legacy OAuth row into `llm.providers` without a shadow `llm.models` table.
- Auth page fixtures deliberately seed legacy `[[llm.models]]` rows to exercise migration, while row assertions select the actual mounted canonical provider article by its Edit control and profile id.
- New-profile submissions use canonical `default_model` and the atom `:new` detached-editor sentinel, assert that override rows remain empty, and require the exact Provider-profile success message plus persisted provider fields.
- Canonical auth persistence explicitly stores `auth_mode: "api_key"`, drops stale OAuth paths and rejects unsupported OAuth modes while retaining the failed draft without writing it.
- `model_ids_test.exs` holds six retired-id matcher, catalog and mounted-page guards.

## Constraints

Pure suites use the shared test bootstrap, never standalone `ExUnit.start/0` calls, and never patch missing core functions or skip failing integration contracts.
Mounted suites retain per-process `EvoDash.Test.ConfigDir.isolate!/1`, local-only ActiveTasks invalidation and owner-aware async mount settling.
Auth config-directory labels include the OS pid so interrupted or concurrent BEAM runs cannot reuse another run's blocker fixture.
The auth mount funnel drains the view before enumerating owned tasks, monitors every node-data/OAuth load chain under a bounded deadline and fails rather than silently timing out.
Credential injection waits for real loaders to finish and sends the mounted node's current `auth_status_seq`; older and unrequested future sequences and foreign nodes must not replace the baseline.
Auth save assertions wait for `config_saving` and `config_save_request` to clear through the authoritative writer receipt, then settle the receipt's OAuth refresh before rendering or reading persistence.
Every login verdict, managed-file path and writable-path remedy stays asserted; full supplied vendor instructions normalize only HTML whitespace, not their wording.
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

Normal `mix test apps/evo_dash/test/evo_dash_web/live/settings_live` boots successfully and runs all 108 tests under seeds 0 and 1, with 104 passing and four default-only provider persistence tests blocked by core validation.
Core rejects `[:llm, :providers, 0, :default_model]` with `default_model must be one of [], got "claude-opus-5-5"` (or `"gpt-5.6-terra"`) when the canonical provider has no model override rows.
The four blocked `EvoDashWeb.SettingsLive.AuthStatusTest` cases share the describe prefix `profile save round-trip (auth_mode / oauth_file persistence)` in `auth_status_test.exs`.
Their test suffixes are `an OAuth anthropic profile persists both keys to config.toml` (line 476), `the API-key default is explicit and drops a stale OAuth path` (line 505), `a blank oauth_file keeps auth_mode and omits only the path` (line 552) and `an OAuth-only provider is self-describing without any auth_mode form value` (line 575).
All four use `save_new_profile/2`, which explicitly asserts empty optional model override rows; the legacy-edit success case instead retains a model override row, and unsupported-OAuth rejection is an independent passing validation contract.
Default-only providers are a valid contract, so these assertions remain active and must not be bypassed by fabricating model rows or expecting the validation failure.
All pure contracts, mounted credential verdict/guidance/path/remedy contracts, stale guards, unsupported-auth rejection and legacy OAuth migration pass in the normal directory run.
The source-owning parent must resolve the default-only core validation blocker, then rerun the entire directory and broader Settings/dashboard suites.

## Routing Table

This directory has no child directories.
