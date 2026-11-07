# CLI Setup Tests

## Intent
This directory tests pure `EvoGit.CLI.Setup` helpers for model-profile configuration and provider authentication choices.

## API Surface
`setup_test.exs` defines `EvoGit.CLI.SetupTest` with `async: true`.
Its describe blocks cover `resolve_auth_choice/2` for dual-mode, OAuth-only and API-key-only providers, `apply_auth_mode/2`, `add_model_profile/3` OAuth/API-key branches, `do_add_model_profile/2`, vendor login probing and `do_prepare_config/3` with real string-keyed TOML maps.
Profile assertions pin the `default` profile ID, preservation of existing concurrency and unrelated profiles, stale auth-mode removal, schema validation and TOML round-trips.

## Constraints
Tests use explicit temporary `home:` and `codex_home:` options rather than environment or global configuration mutations.
These are helper tests rather than interactive wizard end-to-end coverage.
Run from the umbrella root with `mix test apps/evo_git/test/evo_git/cli/setup_test.exs`.

## Routing Table
There are no child subdirectories.
