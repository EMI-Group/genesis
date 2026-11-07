# SettingsLive Support Tests

## Intent

Focused regression contracts for SettingsLive support modules and credential-status page wiring live here.

## API Surface

- `provider_profiles_contract_test.exs` exercises the actual `EvoDashWeb.SettingsLive.ProviderProfiles`, `ConfigIO`, `AuthStatus` and `ModelProfileEvents` modules with pure maps and detached LiveView sockets.
- Provider-profile contracts pin canonical string-keyed profiles, absent generation overrides, numerically ordered and typed multiple model overrides, untouched-save round trips, default-only models and defaults outside the override list.
- Config-write contracts pin removal of atom/string legacy model shadows, canonical provider/default keys, unrelated settings preservation, valid existing defaults, idempotence and empty-profile default removal.
- Credential contracts pin canonical `api_key_env_var` precedence and explicit blank clearing, legacy draft normalization, OAuth secret/env stripping, forced OAuth-only authentication, managed-path trimming and secret-free unknown-status adapters.
- Validation and editor contracts pin malformed rows, duplicate models, invalid numbers/JSON, effective reasoning inventories, dedicated-field exclusion from flat-category deletion, explicit row clearing, detached form mutations, cancellation and nested advanced-field disclosure.
- `model_profile_helpers_test.exs` covers profile parsing and serialization helpers.
- `config_io_test.exs` covers category parameter conversion.
- `auth_status_test.exs` covers credential-status classification, page rendering, stale-result guards and authentication persistence.
- `model_ids_test.exs` guards against retired model identifiers.

## Constraints

The provider-profile contract module uses `async: true` and neither mounts a page nor changes process-global application environment, credentials or files.
It relies on the shared test bootstrap rather than calling `ExUnit.start/0` itself.
Keep pure helper contracts independent of provider requests, OAuth import, scheduler processes and shared ChatHistory.
Preserve the parent test context's per-process config-directory isolation and mount-settling rules for page-based suites.

## Routing Table

This directory has no child directories.
