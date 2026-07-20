# `rel/` — Mix Release Overlays

## Intent

Release configuration overlays for the Mix release system. These files are copied into each release at build time via the `:overlays` key in `mix.exs`. Two release variants are supported: the full `genesis` release and the headless `genesis_remote` daemon.

## API Surface

### Top-Level Files

| File | Purpose |
|------|---------|
| `vm.args.eex` | VM arguments template for the `genesis` release. Desktop-optimized: disables scheduler busy-waiting (`+sbwt none`), shrinks pre-allocated table limits (`+P 40000`, `+t 80000`), disables EPMD (`-start_epmd false`). |
| `remote.vm.args.eex` | VM arguments template for the `genesis_remote` release. Minimal config — supports EPMD-less distribution on a pinned port (configured via `RELEASE_DISTRIBUTION`/`RELEASE_NODE` env vars). |
| `env.sh.eex` | Shell environment template (shared by both releases). Commented-out examples for heart mode, interactive code loading, and distributed node naming. |
| `env.bat.eex` | Windows batch environment template. |

### `./genesis/` — Full Release Overlays
Contains per-release copies of `vm.args.eex`, `env.sh.eex`, `env.bat.eex` used specifically by the `genesis` release.

### `./remote/` — Remote Daemon Overlays
Contains per-release copies of `vm.args.eex`, `env.sh.eex`, `env.bat.eex` used specifically by the `genesis_remote` release. The remote release bakes `config: [evo_git: [remote_release: true]]` at build time so the runtime detects remote-daemon mode and enables EPMD-less distribution.

## Constraints

- These are EEx templates — `@release.name` and other release variables are available.
- The top-level `.eex` files are fallbacks; per-release directories (`genesis/`, `remote/`) take precedence.
- VM args templates: do NOT set `-mode`, `-name`, `-sname`, or `-setcookie` — these are configured via env vars.
- Shell env templates: use `export` for variables consumed by the VM/release boot scripts.

## Routing Table

- `./genesis/` → Per-release overlay copies for the `genesis` release (vm.args, env.sh, env.bat)
- `./remote/` → Per-release overlay copies for the `genesis_remote` headless daemon (vm.args, env.sh, env.bat)
