# `.github/actions/` — Shared Composite Actions

## Intent

Reusable composite actions consumed by the workflows in `../workflows/`, so per-platform jobs share one implementation of the setup, CLI-install and retry logic.
Each action is a directory with an `action.yml` and, where a shell helper is involved, a plain script beside it.

## API Surface

| Action | Purpose |
|--------|---------|
| `setup-mix` | Erlang/OTP + Elixir via `erlef/setup-beam`, then the `deps/`, `_build/` and `rustler_precompiled` NIF-tarball caches, `mix deps.get`, and `mix assets.setup` + `mix assets.deploy`. Takes a per-job `cache-key`. |
| `install-tauri-cli` | Cache, install and verify a pinned `@tauri-apps/cli` (npm, never `cargo install`); the POSIX install targets `$HOME/tauri-cli`, Windows uses the global npm prefix. Takes an exact `version`. |
| `retry` | Bounded exponential-backoff wrapper around one shell command line. Inputs: `command` (required), `attempts` (default 5), `delay` (default 10 s, doubling), `max-delay` (default 60 s). |

## Constraints

- New network-prone steps should use `./.github/actions/retry` instead of a bare `run:` step.
- `retry/retry.sh` is both executable (the action runs `bash "${{ github.action_path }}/retry.sh" bash -ec …`) and sourceable: the macOS notarization step sources it to reuse `retry()` for `xcrun notarytool`/`xcrun stapler`.
- `retry.sh` deliberately sets no top-level `set -e` so sourcing it never changes the caller's shell options, and it stays baseline-bash compatible (macOS bash 3.2, Git Bash on Windows) — no arrays.
- The `retry` action passes the command through the `RETRY_COMMAND` env var and runs it under `bash -ec`, so quoting in the wrapped command is never re-parsed by the outer shell.
