# Welcome Onboarding Helpers

## Intent
`Setup` owns catalog-backed onboarding drafts and canonical provider-profile construction for the local-only `WelcomeLive` page.
The page keeps the preset provider/variant grid, supports toggling multiple models, and chooses one default model plus an optional standard reasoning default per model.

## API Surface
`flatten_models/1`, `provider_models/3`, and `filtered_models/2` build and filter trusted catalog entries without converting client strings into atoms.
`flatten_models/1` preserves a model's advertised `reasoning_efforts` inventory in order, falling back to the full standard inventory when none is advertised.
`reasoning_efforts/0` exposes the standard choices, while `reasoning_efforts/1` reads an entry's inventory with the same fallback.
`has_model?/1` recognizes both canonical provider profiles and existing legacy model profiles for the all-set state.
`auth_mode/1` defaults OAuth-only providers to subscription authentication, and `can_save?/1` gates API-key mode on an existing or typed key while OAuth requires none.
`prepare/3` validates the draft and invokes `EvoGit.Config.Schema.validate/1` before returning a new config, canonical string-keyed provider profile, default catalog entry, and trimmed typed key.
Profiles contain `id`, `name`, resolved `provider`, `auth_mode`, `default_model`, and nested `models` whose `model` values are bare catalog model ids.
Each model retains its full `reasoning_efforts` inventory independently of its selected `default_reasoning_effort`, and a blank reasoning choice adds no default override.
A nonblank reasoning default must be a standard choice and belong to any nonempty advertised inventory, matching the core's unrestricted-empty-inventory convention.
`read_config/0` reads the user TOML afresh without resolved defaults or legacy migrations, and returns explicit errors rather than permitting malformed or unreadable files to be overwritten.
`prepare/3` appends a uniquely named provider profile while preserving existing profiles, unrelated config and legacy `llm.models` verbatim, and sets `llm.default_provider_profile` to the new profile id.
No resolved concurrency or context-window defaults are persisted by onboarding, leaving those defaults to the core provider-profile resolver.
`test_request/3` builds the selected default model's request and passes authentication and reasoning through the core `Schema.LLM.profile_generation_params/1` choke point.
`write/1` exposes the exit-safe boundary for local config and credential writes.

## Constraints
Welcome setup is local-only, and page event handlers reject mutations whenever `current_node_id` is non-nil, including disconnected remote targets that temporarily resolve to the local BEAM.
No onboarding path creates or edits legacy `llm.models`, and persistence never writes a resolved config snapshot that could contain migration-generated legacy profiles.
The parent save and connection-test handlers both invoke `prepare/3` before saving credentials, and the save handler writes configuration only after that preflight.
The helper itself performs no credential or configuration writes during draft construction or validation.
The page ignores forged credential and model hidden fields and resolves model selections exclusively within the active provider and variant.
Connection tests use `SafeCall.start/4`, test the same default model/auth/reasoning as the draft, settle supervisor failures immediately, and reject results whose monotonically increasing token predates any draft or node-context change.
The call-time two-arity `:welcome_llm_test_runner` app-env seam defaults to `EvoGit.SystemCheck.llm_test/2` and allows focused tests without real provider requests.
Scoped async test messages use the nested `{{:welcome_llm_test_result, seq}, guarded_result}` SafeCall shape, and legacy unscoped test results are ignored.
All new UI strings are gettext-wrapped, and translation catalogs remain release-time-only work.

## Integration Boundaries
The core's `:provider_profiles` schema descriptor currently has no matching Ecto validation clause, so canonical `prepare/3` validation and normal runtime configuration boot raise before onboarding can complete.
The core schema walks atom-keyed paths only, while `read_config/0` returns string-keyed TOML, so the current schema call cannot guarantee full validation of unrelated raw configuration sections.
Those schema/startup and validation-normalization gaps belong to the core and must be resolved there rather than bypassed with onboarding-specific validators or resolved-config writes.
The parent currently renders and filters the generic reasoning choices with `reasoning_efforts/0`, and should use the entry-aware `reasoning_efforts/1` when exposing catalogs with narrower advertised inventories.
The sibling `test/evo_dash_web/live/welcome_live_test.exs` needs persistent canonical-persistence, full-inventory versus independent-default, multi-model selection, OAuth, pre-write validation and scoped-test-result assertions instead of its previous legacy-model and unscoped-result expectations.
Temporary helper contract checks can trace the real schema-call argument to inspect construction and use `ProviderProfiles.resolve_runtime_profile/2` without importing credentials while core validation remains unavailable.

## Routing Table
This helper directory has no child directories.
