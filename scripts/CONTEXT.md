# Scripts — Repository-level Developer & User Scripts

## Intent

Standalone shell scripts that are run directly by people (or by `curl … | sh`) and are NOT part of the Mix umbrella build.
Today the directory holds one script: `install.sh`, the one-line installer for the headless Genesis server distribution (`genesis_server` — core + Phoenix dashboard, ERTS bundled, no wx).
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

## Constraints

- POSIX `sh` only — `#!/bin/sh`, `set -eu`, no bashisms, no arrays/`[[ ]]`/`local`.
- Piping-safe: the script never reads stdin (every download runs with `</dev/null`); `--help` writes to stdout and exits 0.
- Windows is out of scope in v1 — no artifact and no PowerShell installer; `MINGW*`/`MSYS*`/`CYGWIN*`/`Windows_NT` are detected and pointed at the desktop app.
- The file must stay named `install.sh` and live in this directory — it is published verbatim as the `install.sh` release asset behind `https://genesis.evox.group/dl/install.sh`.
- Asset names, the `genesis_server/` tarball root and the `bin/genesis` launcher must stay in sync with the release workflow that builds them and with `../rel/overlays/bin/genesis`.
- A missing `.sha256` is never fatal (silently skipped); verification uses `sha256sum` or `shasum -a 256`.
- Replacing an existing install is staged (temp sibling dir) and the old tree is deleted only after the new one is in place; an existing `$HOME/.local/bin/genesis` is only ever replaced when it is a symlink.
- External tool dependencies only: `curl` or `wget`, `tar` with `.tar.xz` support, `awk`; no network access during analysis/verification.

## Routing Table

- `./install.sh` → one-line installer for the headless `genesis_server` distribution.
- `../rel/overlays/` → release overlay sources; `../rel/overlays/bin/genesis` is the CLI this installer links.
- `../.github/workflows/` → builds and uploads the `genesis_server_*` tarballs and the `install.sh` asset.
- `../apps/evo_git/lib/evo_git/remote_bootstrap.ex` → Elixir mirror of the same `/dl/` asset-URL pattern (`direct_url/1`).
- The Mix umbrella build (`../apps/`, `../mix.exs`) does not include this directory.
