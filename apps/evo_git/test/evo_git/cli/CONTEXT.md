# CLI Setup Tests

## Intent
This directory tests `EvoGit.CLI.Setup` account configuration helpers and their real schema, persistence and resolution boundaries.

## API Surface
`setup_test.exs` defines `EvoGit.CLI.SetupTest` with `async: true` and per-test `EvoGit.TestSupport.ConfigDir` isolation.
Authentication-choice and vendor-login cases cover OAuth-only, dual-mode and API-key-only providers with explicit temporary vendor homes.
Canonical setup cases assert `llm.default_provider_profile`, ordered `llm.providers` accounts and nested model maps rather than legacy top-level model profiles.
Account-update assertions preserve shared authentication paths, credential names, generation defaults, concurrency schedules and per-model context-window/effort/generation overrides.
Provider switches append a distinct account, preserve the previous account and allocate collision-free ids rather than overwriting another provider or combining accounts.
Decoded-TOML and legacy migration cases pin account-id preservation, first-account versus explicit default selection, recursive map handling and removal of legacy `llm.model`/`llm.models` fields.
Real save/load cases preserve OAuth account configuration and separate credential-bearing `generation_params` and ReqLLM-ready `resolved.model_spec` from the persisted selection fields `provider_profile_id`, `model` and `reasoning_effort`.

## Constraints
Tests mutate no process-wide environment or application configuration and never drive the global scheduler.
Vendor probing uses explicit `home:` and `codex_home:` paths; OAuth resolution/import and network requests are not exercised.
These are helper and persistence-boundary tests rather than interactive wizard end-to-end coverage.
Run from the umbrella root with `mix test apps/evo_git/test/evo_git/cli/setup_test.exs`.

## Routing Table
There are no child subdirectories.
