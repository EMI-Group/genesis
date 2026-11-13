# Welcome Onboarding Helpers

## Intent
`Setup` owns catalog-backed onboarding drafts and canonical provider-profile construction for the local-only `WelcomeLive` page.
The parent page owns provider/variant selection, multi-model toggles, authentication UI, write ordering and asynchronous connection-test state.

## API Surface
`flatten_models/1`, `provider_models/3`, and `filtered_models/2` build and filter trusted catalog entries without converting client strings into atoms.
`reasoning_efforts/0` exposes standard choices, while `reasoning_efforts/1` reads atom- or string-keyed inventories, preserves their order and explicit empty lists, and falls back to standard choices only for absent or nil inventories.
`flatten_models/1` uses the same inventory helper, so draft construction and page controls agree.
`has_model?/1` delegates to `EvoGit.Config.Schema.model_selections/1`, respecting the core's canonical precedence and legacy migration, including flat `llm.model` input.
`auth_mode/1` defaults OAuth-only providers to subscription authentication, and `can_save?/1` gates API-key mode on an existing or typed key while OAuth requires none.
`prepare/3` validates selections, default model, supported authentication, required endpoint and reasoning choices before invoking `EvoGit.Config.Schema.validate/1`.
Its success tuple is `{:ok, config, profile, default_entry, trimmed_api_key}` and performs no credential or configuration writes.
Profiles contain `id`, `name`, resolved `provider`, `auth_mode`, `default_model`, optional `base_url`, and nested model rows with bare catalog model ids.
Each row retains its full `reasoning_efforts` inventory independently of `default_reasoning_effort`, and a blank choice adds no default override.
A nonblank reasoning default must be a standard choice and belong to any nonempty advertised inventory, matching the core's unrestricted-empty-inventory convention.
`prepare/3` appends a uniquely named provider profile, sets `llm.default_provider_profile`, and preserves unrelated raw settings, existing provider profiles and legacy `llm.models` verbatim.
Validation failures return schema paths rather than inspected validation records, because those records can contain secret raw configuration values.
`read_config/0` reads raw TOML afresh without resolved defaults or migrations and returns explicit errors for malformed or unreadable files.
`test_request/3` resolves the validated profile and selected entry through `Schema.resolve_model_spec/2`, retaining endpoint overrides, inherited generation options, OAuth settings and independent reasoning defaults.
Its return is `{resolved.model_spec, resolved.generation_params}`, where `model_spec` is the ReqLLM-ready string or endpoint map, never a canonical task-picker selection map.
A nonblank reasoning argument overrides the profile default, while a blank argument leaves the profile default authoritative.
Invalid test drafts raise at this server-side boundary and are reported by the surrounding connection worker's `SafeCall`.
`write/1` exposes the exit-safe boundary for local config and credential writes.

## Constraints
All helpers that construct drafts are pure, and page event handlers own the local-node guard before reading or writing local configuration or credentials.
The parent must reject mutation and connection-test events whenever `current_node_id` is non-nil, including disconnected targets temporarily resolving to the local BEAM.
No onboarding path creates or edits legacy `llm.models`, and persistence must never write a resolved config snapshot with migration-generated profiles or runtime defaults.
Save and connection test both run fresh raw-config preflight before credential writes, and only save persists the resulting config.
`read_config/0` is a direct `File.read/1` of `EvoGit.Config.config_path/0` decoded with `TomlElixir`, deliberately bypassing `EvoGit.Config.user_config/0` (its file cache and any in-RAM snapshot), so the read-modify-write always starts from disk truth.
`write/1` only wraps its argument in `EvoDash.SafeCall.run/1`, returning the value or `{:error, reason}`; the actual disk write is always `EvoGit.Config.save_credentials/1` or `save_user_config/1`.
Credential writes preceding config writes are not transactional and cannot be rolled back by this helper.
Catalog entries are trusted server data, while model selections must remain constrained to the active provider and variant.
Configuration, credentials, resolved profiles and generation parameters are server-only and must never enter browser persistence, push-event payloads or client data attributes.
`test_request/3` belongs inside the supervised `SafeCall` worker, never the LiveView render or event process, because canonical resolution can import OAuth credentials and consult metadata.
The call-time two-arity `:welcome_llm_test_runner` seam defaults to `EvoGit.SystemCheck.llm_test/2`.
Scoped test messages use the nested `{{:welcome_llm_test_result, seq}, guarded_result}` SafeCall shape, and the page invalidates tokens on draft and node changes and ignores legacy unscoped results.
All new UI strings are gettext-wrapped, and translation catalogs remain release-time-only work.

## Parent Wiring and Tests
The parent already uses entry-aware `reasoning_efforts/1`, retains full inventories separately from defaults, guards remote mutation events, and runs `test_request/3` inside a supervised worker.
Its `welcome_defaults_changed` whitelist currently treats an explicit empty inventory as allowing only blank, whereas `prepare/3` and core resolution treat that inventory as unrestricted.
If unrestricted empty inventories are exposed for selection, the page must offer standard reasoning choices for that case without changing the stored empty inventory.
The sibling `test/evo_dash_web/live/welcome_live_test.exs` covers multi-model save, independent defaults and inventories, OAuth modes, local-only mutation, config preservation and scoped test results.
Additional persistent helper regressions belong in that sibling suite: atom/string/nil/empty inventories, core-backed legacy-flat and canonical-precedence all-set detection, endpoint and inherited-generation test-request parity, invalid test selections, and secret-free validation errors.
The page and sibling tests are owned outside this helper node.

## Core-Owned Validation Boundary
`Schema.validate/1` is available and canonical provider preflight runs normally, but its general path accessor still walks atom keys only in this checkout.
`read_config/0` returns raw string-keyed TOML, so unrelated raw sections are preserved but are not fully validated by that schema call.
For example, `Setup.prepare/3` currently accepts an unrelated raw `"scheduler" => %{"max_tool_concurrency" => "invalid"}` section while the atom-keyed equivalent is rejected.
This gap belongs to the core's validation normalization and must not be bypassed with an onboarding-specific validator or resolved-config persistence.

## Config I/O Touch Points (page + helper)
`welcome_live.ex` reads config only via `ConfigIO.load_file_config/0` (= `EvoGit.Config.resolve/0`) in `mount/3` and after a save, and carries `EvoGit.Config.credentials/0` into the `credentials` assign at mount, after save and after a connection test.
`Setup.read_config/0` (`setup.ex:176-194`) is the deliberate raw-TOML read (`File.read(EvoGit.Config.config_path())` + `TomlElixir.decode`) used as the read-modify-write base for save and test, so persisted defaults and migration output never land in the file.
Writes are only `EvoGit.Config.save_credentials/1` (`save_key/3` at `welcome_live.ex:676`) and `EvoGit.Config.save_user_config/1` (`welcome_live.ex:504`), both wrapped by `Setup.write/1` (`EvoDash.SafeCall.run/1`, not transactional together).
After a successful save the page re-reads `load_file_config/0` (`:505`), re-reads `credentials/0` (`:514`) and pushes scheduler options through `ConfigIO.update_runtime_from_file_config/2` (`:519`); it never calls `reload_remote_config/1` or `RemoteAPI.reload_config/0`.
`save_key/3` runs before both the config write and the connection test, so the API key reaches the test through `save_credentials/1`'s file write plus its `ReqLLM.put_key` side effect, not from the `api_key_input` assign.
The page subscribes to no config-change topic: `has_model?`, `credentials` (and the `key_is_set` badge / `can_save?/1`) only refresh on mount or after this page's own writes, so an external config or credentials edit stays invisible until remount.
`file_config` is assigned in `mount/3` and after save but is never rendered or read — a dead assign holding the resolved config map in socket state.

## Routing Table
This helper directory has no child directories.
