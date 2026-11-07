# EvoGit CLI Layer — `lib/evo_git/cli/`

## Intent
Argument parsing and the interactive setup wizard for `EvoGit.CLI` live here, while the parent `../cli.ex` owns dispatch and task enqueue.
Parsing stays pure and setup persists only through `EvoGit.Config` and imports subscription credentials through `EvoGit.Auth`.

## API Surface
- `Parser.parse_args/1` returns `{opts, argv}` and discards invalid flags, while `parse_args_full/1` also returns OptionParser's invalid list.
- Switches include `help`, `version`, `file`, `path`, `model`, `provider_profile`, `reasoning_effort`, `mode`, repeatable `foreign_repo`, `agent`, `node`, `starting_commit`, `archive`, and `build_system`, with the existing short aliases unchanged.
- `Parser.parse_model_selection/1` returns `{:ok, :auto}` for no selection, `{:ok, {:legacy, value}}` for existing `-m` syntax, or `{:ok, spec}` for `--provider-profile <id> --model <model> [--reasoning-effort <effort>]`.
- Explicit specs have string keys `provider_profile_id`, `model`, and optional `reasoning_effort`, and preserve model names containing colons without legacy splitting.
- Incomplete explicit selections and blank values return `{:error, message}`, and effort without an explicit provider profile is rejected.
- The parent dispatch must validate selections with the schema and enqueue an explicit selection as `model_spec: spec, model_id_locked: true`, while Auto omits both keys.
- `Parser.parse_model_flag/1` preserves legacy `id:provider:model` splitting for the parent's legacy-ID resolver.
- `Parser.parse_foreign_repos/1` builds read-only `%EvoGit.Core.ForeignRepo{}` values from repeatable `-R`, and Windows drive-letter absolute paths are never split as IDs.
- `Parser.maybe_put/3` leaves a keyword list unchanged for nil values.
- `Setup.run/0` guides provider, model, endpoint variant and API-key or subscription authentication selection.
- Setup saves canonical `[llm].default_provider_profile` and `[[llm.providers]]`, without a legacy `llm.model` mirror or top-level `llm.models` list.
- `Schema.provider_profiles/1` is the migration boundary for existing flat/model-profile configurations; setup consumes its list of canonical profiles instead of duplicating migration logic.
- A setup run updates the configured default account when it belongs to the selected provider, preserving concurrency, peak settings, effort/generation defaults, account settings and nested model overrides.
- With no explicit default-provider ID, setup follows Schema's first-account default rather than privileging an account named `default`, and an unresolved explicit ID never falls back to overwriting an unrelated account.
- The chosen model must appear in the provider's ordered `models` inventory: setup appends it only when absent, preserves an existing model entry verbatim, and sets `default_model` to that model.
- New profiles carry an empty `reasoning_efforts` list matching Schema normalization so repeated setup does not add normalization-only fields or duplicate inventory entries.
- A different provider gets a new unique profile ID, preserving existing accounts and making the new profile the default; an empty configuration starts with ID `default` and concurrency 3.
- The chosen model becomes the provider profile's `default_model`, with `provider` stored as a string and catalog endpoint options copied onto that provider profile.
- Real TOML string-keyed maps recurse through lists as well as maps before profile lookup, preventing duplicate profiles on repeated setup.
- OAuth imports and diagnostics honor the selected profile's existing `oauth_file`, never prompt for an API key and never write OAuth tokens to credentials.toml.
- Switching back to API-key mode clears the selected profile's stale `auth_mode`, and unrelated configuration and other profiles are retained.
- `Setup.do_add_model_profile/2,3`, `do_prepare_config/3`, `apply_auth_mode/2`, `resolve_auth_choice/2`, `find_vendor_login/2`, and `oauth_available?/2` are existing public test seams.

## Constraints
- No CLI dispatch changes belong here; `../cli.ex` integrates selection parsing, schema resolution, task opts and help text.
- Parsing performs no IO, filesystem access, configuration reads or application-state mutation.
- Provider/model/effort validation belongs to `Schema`, not parser-local catalog or window logic.
- Modes remain strings end-to-end, and CLI foreign repos remain read-only.
- API-key prompts and writes resolve the prepared config's selected account `api_key_env_var` when nonempty, falling back to the catalog credential key (or the custom provider's derived key) only when absent.
- API-key writes go through `Config.save_credentials/1` with that exact string key, preserving other same-provider account credentials and unrelated credential entries.
- Runtime `Schema.LLM.profile_generation_params/1` currently resolves `api_key_env_var` only from the process environment, so consuming custom keys saved in credentials.toml requires the parent-owned Config/schema integration fix.
- No sibling test files are owned by this node.

## Required Regression Coverage
- Parser tests must cover explicit provider/model/effort flags, omitted effort, colon-containing model names, Auto, unchanged legacy flags/IDs, and blank/incomplete selections.
- Dispatch tests must assert schema-validated string-keyed `model_spec` plus lock for explicit selections, no selection keys for Auto, retained legacy-ID resolution, and no enqueue on invalid provider/model/effort.
- Setup tests must use real string-keyed canonical and legacy input, verify canonical-only output, rerun idempotence, selected-default account updates, unique new-provider IDs, and preservation of unrelated settings, shared limits, efforts/defaults and nested overrides.
- OAuth tests must retain subscription/API-key choice behavior, verify a configured custom OAuth path reaches credential import and diagnostics, ensure no API-key write on OAuth, and clear stale OAuth mode on an API-key rerun.
- Setup persistence tests must validate and TOML-round-trip canonical output through the shared schema rather than asserting legacy `llm.models` writes.
- API-key wizard tests must cover a selected custom `api_key_env_var` in two same-provider accounts, exact prompt/save key agreement on named and custom-provider routes, unchanged catalog fallback when absent, and preservation of existing keys on blank input.

## Known Issues
- `Setup.prompt_input/1` and the parent's input helpers still pass `:eof` or `{:error, reason}` from `IO.gets/1` into `String.trim/1`, so redirected stdin can crash instead of selecting a default.
- The parent's `stdin_tty?/0` probes stdout console width rather than stdin readiness.
- Parent help text uses POSIX shell quoting and redirects, which are not portable to Windows cmd.exe or PowerShell 5.1 UTF-16 output.
- Core TOML loading rejects UTF-16 files, and prompt-file loading retains a leading UTF-8 BOM.
- `-R C:relative` is not recognized as a drive-relative Windows path and is split as an ID plus path.

## Routing Table
There are no child directories.
