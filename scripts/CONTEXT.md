# Scripts — Repository-level Developer & User Scripts

## Intent

Standalone scripts that are NOT part of the Mix umbrella build.
The release shell scripts are `install.sh`, the one-line installer for the headless Genesis server distribution (`genesis_server` — core + Phoenix dashboard, ERTS bundled, no wx), and `test-genesis-cli.sh`, its self-contained smoke test for the `genesis` CLI shipped in that release (`../rel/overlays/bin/genesis`).
It installs a released tarball, links the `genesis` shell CLI onto the user's PATH, and prints next steps; it performs no compilation and needs no Elixir toolchain.

## API Surface

### `install.sh`

Canonical usage (the script itself is published as a release asset named `install.sh`):

```sh
curl -LsSf https://genesis.evox.group/dl/install.sh | sh
curl -LsSf https://genesis.evox.group/dl/install.sh | sh -s -- --dir ~/genesis

# from a checkout:
sh scripts/install.sh [--dir <path>] [-f|--force] [-h|--help]
```

Flags and environment overrides (`--dir` wins over `GENESIS_INSTALL_DIR`):

| Flag | Env override | Default | Meaning |
|------|--------------|---------|---------|
| `--dir <path>` | `GENESIS_INSTALL_DIR` | `$HOME/.local/share/genesis/server` | Release install directory |
| `-f`, `--force` | — | off | Reinstall an already-present pinned version; overwrite a non-Genesis directory at the install path |
| `-h`, `--help` | — | — | Print usage to stdout and exit 0 |
| — | `GENESIS_VERSION` | `latest` | Release tag to pin |
| — | `GENESIS_DOWNLOAD_BASE` | `https://genesis.evox.group/dl` | Primary download base |
| — | `GENESIS_DOWNLOAD_FALLBACK_BASE` | `https://github.com/EMI-Group/genesis/releases` | Fallback download base |

Pipeline: detect platform → download the asset (primary base, then fallback) → verify `<asset>.sha256` when published → extract to a temp dir → stage beside the install dir and swap → `chmod +x bin/*` → link `$HOME/.local/bin/genesis`.

Published assets (tarball root directory is `genesis_server/`):

| Platform (`uname -s` / `uname -m`) | Asset |
|-----------------------------------|-------|
| `Linux` / `x86_64`, `amd64` | `genesis_server_linux_x64.tar.xz` |
| `Linux` / `aarch64`, `arm64` | `genesis_server_linux_arm64.tar.xz` |
| `Darwin` / `arm64` | `genesis_server_darwin_arm64.tar.xz` |

Download URLs (one builder function each — `proxy_url` and `github_url`):

| Version | Primary | Fallback |
|---------|---------|----------|
| `latest` | `https://genesis.evox.group/dl/<asset>` | `https://github.com/EMI-Group/genesis/releases/latest/download/<asset>` |
| `<tag>` | `https://genesis.evox.group/dl/<tag>/<asset>` | `https://github.com/EMI-Group/genesis/releases/download/<tag>/<asset>` |

Installed layout:

```
${GENESIS_INSTALL_DIR:-$HOME/.local/share/genesis/server}/
├── bin/genesis          # shell CLI: foreground server, start/status/logs/stop
├── bin/genesis_server   # Mix release launcher
├── releases/            # release metadata (start_erl.data carries the version)
└── erts-*/              # bundled ERTS
$HOME/.local/bin/genesis -> <install dir>/bin/genesis
```

Printed next steps: `genesis` (foreground server), `genesis start` (service via systemd-run/launchd), `genesis status`, `genesis logs`, `genesis stop`, then open the dashboard URL printed on boot (default `http://127.0.0.1:9999`).

### `test-genesis-cli.sh`

Self-contained smoke test for `../rel/overlays/bin/genesis`: a temp release with a stub `bin/genesis_server` and PATH-shadowed supervisors, run with `bash scripts/test-genesis-cli.sh` (no release build, no service manager).
It also covers the `genesis start` systemd-linger offer — `GENESIS_LINGER` (`ask`/`yes`/`no`) and `--no-linger`, the non-TTY hint, the enable-success and enable-failure warnings, and the fallback-backend / foreground gating that never probes lingering.
It also covers the `genesis remote …` family against the single-instance contract (distribution is a runtime toggle on the ONE server instance, never a second process): the control request's mode/contents/sequence number, the canonical `running node=… dist_port=…` line as the LAST line, idempotent re-start, `--force`, the stale-answer/`--wait` floor handshake, a daemon-error answer, legacy per-target unit cleanup in its own scope, `status`/`stop`/`logs`, and the fallback-pidfile and launchd backends (contract detail: `../rel/CONTEXT.md`).
Stub `systemd-run`/`systemctl`/`launchctl`/`journalctl`/`loginctl`/`curl`/`uname`/`setsid` binaries stand in for the real ones (the recording `loginctl` shims prove the non-systemd paths never call it), so no real service manager, `loginctl` or network is touched.
The "instance" those stubs launch is a real background `sh` fixture that answers the CLI's SIGHUP by writing its own `dist.env`, so every signal and every accepted answer is observable; stub `sleep` and `curl` keep the CLI's poll budgets and health probe cheap, keeping a whole run in the low seconds.

## Constraints

- POSIX `sh` only — `#!/bin/sh`, `set -eu`, no bashisms, no arrays/`[[ ]]`/`local`.
- Piping-safe: the script never reads stdin (every download runs with `</dev/null`); `--help` writes to stdout and exits 0.
- Windows is out of scope in v1 — no artifact and no PowerShell installer; `MINGW*`/`MSYS*`/`CYGWIN*`/`Windows_NT` are detected and pointed at the desktop app.
- The file must stay named `install.sh` and live in this directory — it is published verbatim as the `install.sh` release asset behind `https://genesis.evox.group/dl/install.sh`.
- Asset names, the `genesis_server/` tarball root and the `bin/genesis` launcher must stay in sync with the release workflow that builds them and with `../rel/overlays/bin/genesis`.
- A missing `.sha256` is never fatal (silently skipped); verification uses `sha256sum` or `shasum -a 256`.
- Replacing an existing install is staged (temp sibling dir) and the old tree is deleted only after the new one is in place; an existing `$HOME/.local/bin/genesis` is only ever replaced when it is a symlink.
- External tool dependencies only: `curl` or `wget`, `tar` with `.tar.xz` support, `awk`; no network access during analysis/verification.
- The smoke test is `bash` (not POSIX `sh`, unlike `install.sh`) and must never invoke a real `systemd-run`/`systemctl`/`journalctl`/`loginctl`/`curl` where a stub applies — the shim dirs precede `PATH`, and recording `loginctl` shims make "never called" provable rather than assumed.

## Routing Table

- `./sync-readme-evidence.py` → Python standard-library generator for the bounded README Evidence block. `--refresh` fetches the website manifest; `--check` validates against the committed snapshot offline. Selection, snapshot and maintenance instructions live in `../docs/readme-evidence*`.
- `./install.sh` → one-line installer for the headless `genesis_server` distribution.
- `./test-genesis-cli.sh` → smoke test for `../rel/overlays/bin/genesis` (temp release + stub `bin/genesis_server`, PATH-shadowed systemd/launchd and stubbed `loginctl`/`curl`/`uname`; run with `bash scripts/test-genesis-cli.sh`, no release build, service manager or network needed) — its CLI surface, linger coverage and shim inventory: `### test-genesis-cli.sh` above.
- `../rel/overlays/` → release overlay sources; `../rel/overlays/bin/genesis` is the CLI this installer links.
- `../.github/workflows/` → builds and uploads the `genesis_server_*` tarballs and the `install.sh` asset.
- `../apps/evo_git/lib/evo_git/remote_bootstrap.ex` → Elixir mirror of the same `/dl/` asset-URL pattern (`direct_url/1`).
- The Mix umbrella build (`../apps/`, `../mix.exs`) does not include this directory.
