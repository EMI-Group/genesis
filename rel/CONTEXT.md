# Rel — Mix Release Overlays

## Intent

Release configuration overlays for the Mix release system. Three release variants are defined in `../mix.exs`: `genesis` (full), `genesis_desktop` (Tauri-bundled), and `genesis_remote` (headless daemon for SSH remote dev).

## Architecture

Mix does NOT automatically use per-release overlay directories (`rel/genesis/`, `rel/genesis_remote/`). The actual files used by ALL releases are the top-level EEx templates. Release-specific behavior is achieved via EEx conditionals on `@release.name` (an atom, e.g., `:genesis_remote`).

## Routing Table

- `./genesis/` → Per-release overlay copies (not automatically used — documentation only)
- `./genesis_remote/` → Per-release overlay copies (not automatically used — documentation only)

## API Surface

### Top-Level Files (actually used by releases)

| File | Purpose |
|------|---------|
| `vm.args.eex` | VM arguments template for ALL releases. Uses EEx conditionals: `genesis_remote` gets EPMD-less distribution (`-dist_listen true`, pinned port 9000); other releases get plain `-start_epmd false`. Also includes desktop optimization flags (`+sbwt none`, `+P 40000`, `+t 80000`). |
| `remote.vm.args.eex` | VM arguments for the `remote` and `rpc` shell commands. Same EEx conditional: EPMD-less for `genesis_remote`, plain EPMD-disable for others. |
| `env.sh.eex` | Shell environment template for ALL releases. EEx conditional: `genesis_remote` exports `RELEASE_DISTRIBUTION=name`, `RELEASE_NODE=genesis_remote@127.0.0.1`, and `RELEASE_COOKIE`; other releases get commented-out examples only. |
| `env.bat.eex` | Windows batch environment template. |

### Per-Release Directories (documentation only — NOT used by Mix)

- `./genesis/` — Intended vm.args/env for the `genesis` release
- `./genesis_remote/` — Intended vm.args/env for the `genesis_remote` release (EPMD-less dist on port 9000, distribution env vars)

These directories exist as documentation of the intended per-release configuration. They are NOT automatically applied by Mix. To wire them up, custom release `:steps` would need to be added to the release definitions in `mix.exs`.

## Constraints

- These are EEx templates — `@release.name` (atom) and other release variables are available.
- VM args templates: do NOT set `-mode`, `-name`, `-sname`, or `-setcookie` — these are configured via env vars.
- Shell env templates: use `export` for variables consumed by the VM/release boot scripts.
- EEx conditionals use string comparison on `@release.name`: `@release.name == :genesis_remote` (atom comparison).

## Design Decisions

- **EEx conditionals instead of per-release overlays**: Mix does not automatically apply `rel/<release_name>/` overlays. The `rel/genesis_remote/` directory was created expecting this to work, but it doesn't. Rather than adding custom `:steps` to each release definition (which would require duplicating the desktop optimization flags), EEx conditionals in the top-level templates achieve the same result more maintainably.
- **`remote.vm.args.eex` recreated**: This file was previously deleted (it was a commented-out placeholder). It is required by Mix for the `remote` and `rpc` commands. Without it, Mix falls back to a cached split from `vm.args.eex` which may not include EEx-processed content correctly.
- **`-erl_epmd_port N` is REQUIRED for true EPMD-less distribution**: Setting `-start_epmd false` alone prevents the VM from launching the external `epmd` daemon, but the `erl_epmd` gen_server (part of kernel) still runs and `register_node` will attempt to connect to EPMD on port 4369. If EPMD isn't running, this fails with `econnrefused`. The `-erl_epmd_port N` flag tells `erl_epmd` that the node is listening on port N directly, which makes both `listen_port_please` (returns `{ok, N}` — bypasses EPMD port allocation) and `register_node` (returns `{ok, -1}` on EPMD connection failure — graceful degradation) work without EPMD. Without this flag, `econnrefused` propagates and distribution fails to start. All three flags must be present for the remote daemon: `-start_epmd false`, `-erl_epmd_port 9000`, `-kernel inet_dist_listen_min 9000 inet_dist_listen_max 9000`.
