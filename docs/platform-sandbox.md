# Platform Sandbox (Windows + macOS) — design record & implementation plan

## Intent

Genesis isolates LLM-generated shell commands with a per-platform sandbox.
On Linux it does so (`systemd-run` hardening, or `bwrap`); on macOS it does so weakly (`sandbox-exec` with an allow-most profile); on Windows it does nothing at all.
This record fixes the target design and a phased plan, using OpenAI Codex (`/home/bill/Source/codex`) as the implementation reference — verified against its source, not its marketing.

Deliberate scope choice: we do **not** target Codex's compatibility breadth.
We support only the newest, cleanest platform stack (Windows MXC; Apple's `sandbox-exec`), accept a hard "unsupported → no sandbox + visible warning" fallback on old hosts, and keep the code modular enough to ship as a small Rust helper binary beside the Elixir app.

## Verified reference facts (Codex)

### Windows — MXC (the modern backend)

- **Mechanism**: `mxc-sdk` (Rust, MIT, consumed as a **git dependency** pinned by rev — not published on crates.io) linking the Windows **PSEC** (process security environment) API-set. No service, driver, MSIX, MSI, sandbox user, DACL editing, or elevation. Codex never uses MXC's AppContainer dispatcher or DACL fallback.
- **Availability probe**: create-and-close a PSEC environment with no filesystem/network/UI grants and no process launch; cached in a `OnceLock`. API-set presence alone is explicitly insufficient, and `platform_support()` is not trusted. Minimum documented host: Windows 11 24H2 build **26100.9278** (25H2 26200.9278).
- **How it is applied**: **self re-exec** — Codex replaces the command with `codex.exe --__codex-windows-mxc` and ships the whole request as chunked environment variables (`CODEX_SANDBOX_LAUNCH_*`, 16 KiB chunks, 16 MiB cap, env scrubbed before spawn). The wrapper inherits stdio, waits, and exits with the workload's exit code, so PTY/pipes/exit-status need no custom code.
- **Request shape** (`ExecutionRequest.policy`): `readwrite_paths`, `readonly_paths`, `denied_paths`, `network_egress` + `network_ingress` (+ `host_loopback`), `capabilities: ["registryRead"]`, `fallback.allow_dacl_mutation: false`, `ui.disable: false` (PowerShell needs Win32k), `base_process_ui.isolation: "desktop"`, plus `working_directory`, `env`, and either `script_code` (cmd.exe line) or an argv.
- **Process lifecycle**: MXC creates the child **suspended**, assigns a kill-on-close Job Object, then resumes; descendants are terminated when the foreground process exits or the launch is cancelled.
- **No memory quota**: the only job flags set anywhere are `KILL_ON_JOB_CLOSE | BREAKAWAY_OK`; `JOB_OBJECT_LIMIT_JOB_MEMORY`/`PROCESS_MEMORY` stay 0, and the MXC policy has no resource field. MXC is a containment/authz product, not a resource governor.
- **Documented edge cases**: hard links are permissioned per name; volume-root aliases can widen a grant; writable *volume roots* do not recurse to later-created children; deny globs are snapshot-expanded at launch; unrelated network shares are not readable; non-Unicode paths/env fail closed; empty env restores SDK defaults; descendants die with the foreground process.
- **Portability**: `native.rs`/`availability.rs` are liftable nearly verbatim; `policy.rs` is Codex-coupled (protocol permission model, `PathUri`, deny-glob resolver), but the essential mapping to `ExecutionRequest` is ~45 lines if the helper accepts its **own** simple spec (rw/ro/deny paths + network) and skips `:root`/volume/UNC/glob machinery.

### macOS — Seatbelt

- **Mechanism**: `exec /usr/bin/sandbox-exec -p <profile> -DKEY=VALUE … -- <cmd>`. Full SBPL inline in `-p` (no temp profile file), paths passed as **attached** `-D` parameters referenced via `(param "…")` — never string-interpolated. No `sandbox_init` FFI anywhere in production.
- **Policy composition** (order is security-relevant, grants first, mandatory denies last): `seatbelt_base_policy.sbpl` (`(version 1)`, `(deny default)`, process/signal/pty/sysctl/mach/ipc baseline) → read section → write section → network section → preferences section (only when reads are unrestricted) → platform defaults (read-only macOS runtime minimums) → `/Applications` → daemon-socket protection → `(deny mach-lookup (xpc-service-name-prefix ""))` → deny-read globs → protected-ancestor `deny file-write-unlink` → `(deny system-fcntl (fcntl-command 80 110))` → `(deny file-ioctl <TIOCSTI>)` for the inherited-terminal profile.
- **Anti-bypass rules worth copying**:
  - every writable root gets `(deny file-write-unlink … (vnode-type DIRECTORY))` so `rm -rf $PWD && ln -s /outside $PWD` cannot rebind the authority boundary;
  - every read-only carveout *inside* a writable root protects **all its ancestors** (logical and resolved spellings) against rename/unlink;
  - carveouts emit **both** `require-not literal` and `require-not subpath` (subpath alone leaves a gap for first-time `mkdir .codex`);
  - protected metadata names (`.git`, `.agents`, `.codex`, `.aws`) become root-anchored regexes, so they are protected before they exist and survive case variants;
  - deny globs compile to anchored SBPL regexes with ancestor unlink denies;
  - `fcntl` 80/110 (`F_MAKECOMPRESSED`/`F_TRANSFEREXTENTS`) mutate file contents through a **read-only** fd, so they must be denied separately.
- **Path handling**: read roots are `canonicalize`d (lexical fallback when missing); writable roots fail closed when they contain a **nested** symlink component (depth ≥ 2), while top-level aliases (`/tmp` → `/private/tmp`, `/var` → `/private/var`) are normalized; carveouts and ancestors carry both logical and resolved spellings; relative paths are rejected.
- **No nested-sandbox guard**: `CODEX_SANDBOX=seatbelt` / `CODEX_SANDBOX_NETWORK_DISABLED` are informational; re-wrapping is allowed to fail.
- **Denials surface as the child's exit status plus `Operation not permitted` on stderr**; Codex classifies violations by stderr keywords and best-effort extracts the path.
- **License**: Apache-2.0 (`codex-rs`); the base `.sbpl` fragments themselves derive from Chromium's `common.sb`/`renderer.sb` (BSD-3-Clause) — keep attribution when vendoring.

## Where we stand

- Contract: `EvoGit.Sandbox.Behaviour` — `enabled?/0`, `ensure_initialized/0`, `run/4` (untimed), `run_with_partial/6`, optional `run_with_partial/7` (`:execution_id` for `ProcessManager`). Detached execution is `EvoGit.Sandbox.spawn_detached/kill_detached/detached_status` (`sandbox/background.ex`), not a callback.
- Backends and per-call selection: `EvoGit.Sandbox.backend/0` reads `[:sandbox, :backend]` (`:auto|:systemd|:bwrap`) from the **file** config, then `Platform.sandbox_backend/0` → `Linux` (systemd-run), `Bwrap`, `MacOS`, `None`; `backend_reason/0` reports which one is in effect (see the backend matrix).
- `MacOS.generate_profile/3`: `(deny default)`; reads are effectively **allow-all** (`(allow file-read* (subpath "/"))`) minus a home/credential/system deny list; writes are deny-by-default with cwd, tmp dirs, task tmpdir, `.git` metadata, Genesis config/data dirs and the 13 cache dirs; network `allow network*`; `mach-lookup` allow-all; `(limit number 200)`; paths are still single-line string interpolation (the `-D` rework is open).
- Windows: `EvoGit.Sandbox.None` — `enabled?/0` is hardcoded `false`, so `mode: "enabled"` means "run directly"; commands are `System.cmd` argv arrays (PowerShell `-EncodedCommand`), timeout is an **idle** timeout, kill is `taskkill /T /F`. No isolation of any kind, and no Windows backend is planned while the project has no Windows build or test host (P1 deferred).
- The unisolated state is no longer SILENT: `EvoGit.Sandbox.backend_reason/0` names it (including the unsupported-platform `:auto` fallback and "NO OS-LEVEL ISOLATION on <platform>" with the `[sandbox] backend` / `[sandbox] mode` fix), and `EvoGit.Sandbox.warn_if_unisolated/0` logs one latched warning per BEAM when isolation was demanded and no backend is usable.
- Bypass surface (not sandboxed today): `lsp` tool spawn, `elixir_eval` sudo tier, custom tools, Windows skill scripts, the repo `genesis.toml [worktree]` init script.
- No test ever executes a real backend (`@mix_env == :test` short-circuits Linux/bwrap/macOS), so backend tests are argv/profile-string assertions only.
- Packaging: `EvoGit.Executable.resolve/1` = PATH first, then `priv/vendor/<platform>/`; releases copy `priv/` automatically; CI has **no** cargo build step outside `tauri build`; `sign-macos-nested.sh` signs every Mach-O under the copied release tree; Windows has no signing at all.

## Target architecture

One Elixir **policy spec** + one renderer per platform. The spec is the only place that knows Genesis semantics (which roots are writable, which are denied, git metadata, tmp dirs); renderers only know how to express it.

### `EvoGit.Sandbox.Spec` (implemented — P0)

ONE struct carries everything a renderer needs, and `EvoGit.Sandbox.Spec.build(:macos | :linux | :bwrap, opts)` is the only builder:

```
%Spec{
  backend,                                       # :macos | :linux | :bwrap — which renderer consumes it
  cwd, repo_root, home,                          # working dir; repo boundary for git metadata; home anchor
  read_roots, write_roots, read_only_subpaths,   # grants: readable / writable / carveouts under a write root
  deny_paths, deny_write_paths,                  # deny-read and deny-write locations
  credential_paths, credential_deny_paths,       # the ONE canonical credential list, projected per rule kind
  cache_write_paths, tmp_paths, nix_paths,       # package-manager caches, tmp dirs, nix store/var
  git_metadata_dir, task_tmpdir,                 # git metadata (per call site), managed per-task tmpdir
  config_dir, data_dir, host_tmpdir,             # Genesis config/data dirs, macOS host $TMPDIR read source
  git_binary_dir,                                # read rule for a vendored git (macOS, PATH miss only)
  network, env,                                  # :allow | :deny; env already shaped for the renderer
  max_processes, resources                       # process-count limit; per-backend resource limits
}
```

`build/2` is TOTAL and `cwd:` is its ONLY required input; every other value is a default-inert injection seam (`repo_root`, `home`, `tmp_paths`, `task_tmpdir`, `write_paths`, `nix_enabled?`, `config_dir`, `data_dir`, `host_tmpdir`, `network`, `max_processes`, `git_metadata`).
An ABSENT option means "resolve it live, exactly as production does", so a test pins one value without touching app env, `:persistent_term` or user config; a nil repo root, an absent per-task tmpdir, a missing cache dir and `write_paths: nil | [] | [...]` are all valid.
Each call site pins its historical git-metadata input through `git_metadata:` (systemd foreground passes `<repo_root>/.git`, systemd detached passes `git_metadata_dir(cwd, nil)`), so that asymmetry cannot silently unify.
Companions: `credential_paths/0` (the canonical ordered home-relative list), `default_cache_dirs/0` (the canonical 13 cache dirs), `backends/0`, and the macOS spelling pair `aliases/1` + `resolve_alias/2` (ONE-hop first-component symlink resolution; a NESTING resolution answers `nil`).

Credential parity: ONE canonical 12-dir list (`.ssh`, `.gnupg`, `.aws`, `.kube`, `.config/sops`, `.git-credentials`, `.netrc`, `.password-store`, `.npmrc`, `.pypirc`, `.docker`, `.gem`) feeds systemd `InaccessiblePaths`, the bwrap deny `--tmpfs` overlays, and the macOS deny-read AND deny-write groups; `Library/Keychains` is macOS-only and appended by the macOS renderer to the deny-READ group, immediately after `.password-store`.
Linux `InaccessiblePaths`, the bwrap deny overlays and the macOS deny-write group all cover the full canonical 12; every other SBPL rule and argv element is byte-identical to the pre-extraction output, and deny groups are emitted in canonical order (semantically irrelevant).
`deny_globs` does NOT exist in the shipped struct: glob patterns remain unimplemented (macOS P2; never on Windows), and no renderer accepts a pattern list today.

### Backend matrix

| Host | Backend | Mechanism | Status |
|---|---|---|---|
| Linux + systemd | `Sandbox.Linux` | transient user unit, hardening props, slice `MemoryMax` | exists, spec renderer |
| Linux, no systemd | `Sandbox.Bwrap` | filesystem namespace, `--ro-bind /` | exists, spec renderer |
| macOS | `Sandbox.MacOS` | `sandbox-exec` + SBPL | exists, spec renderer; P2 remainder open |
| Windows 11 24H2+ (PSEC) | `Sandbox.WindowsMxc` | `genesis-sandbox.exe` → MXC PSEC | deferred (no Windows build or test host) |
| anything else | `Sandbox.None` | direct | exists, and *reported* |

`[:sandbox, :backend]` would gain `:windows_mxc` with P1; `:auto` would prefer it on Windows when the helper probe passes.
The no-sandbox state is no longer silent: `EvoGit.Sandbox.backend_reason/0` returns an operator-facing string naming the active backend (`systemd-run` / `bwrap` / `sandbox-exec`) or plainly stating that commands run UNISOLATED (deliberately disabled, the `:auto` fallback, or "NO OS-LEVEL ISOLATION on `<platform>`" naming the `[sandbox] backend` / `[sandbox] mode` fix), and `EvoGit.Sandbox.warn_if_unisolated/0` logs EXACTLY ONE `Logger.warning` per BEAM (a `:persistent_term` latch) when the configuration DEMANDS isolation while no backend is usable — never when sandboxing is on, and never when it was deliberately disabled.
The dashboard surface for that string remains open (P4).

### Windows helper: `genesis-sandbox.exe` (Rust, new crate — deferred with P1)

Location `apps/evo_git/native/genesis-sandbox/` (standalone crate + `Cargo.lock`; not a workspace member — the repo has no root Cargo workspace).

CLI (stable contract, mirrored by the Elixir backend):

```
genesis-sandbox probe                       # exit 0 = PSEC usable, 1 = not
genesis-sandbox version
genesis-sandbox run --spec <path-to-json> -- <cmd> [args…]
```

- **Spec transport**: JSON **file** (path in argv), not env chunking — we control the helper, so we do not need Codex's re-exec self-transport, and stdin must stay available for the child.
- **Mapping to MXC**: `write_roots → readwrite_paths`, `read_roots + read_only_subpaths → readonly_paths`, `deny_* → denied_paths`, `network → egress/ingress defaults (+ loopback allow when enabled)`, `capabilities: ["registryRead"]`, `ui.disable: false`, `fallback.allow_dacl_mutation: false`, `working_directory`/`env` from the spec; argv passed as `WindowsCreateProcess` quoting (not re-encoded through `cmd.exe`).
- **Exit convention** (fixes Codex's ambiguity): workload exit codes pass through; launcher failures exit **125** with a `genesis-sandbox: …` stderr line. Elixir maps 125 → `{:error, launch_reason}`.
- **Lifecycle**: spawn the workload, wait, exit with its code — the helper *is* the execution owner, which is what `Sandbox.Background` already keeps (a `Port` per job). Killing the job kills the helper → MXC's kill-on-close job takes the tree down. Never use a "run, detach, exit" shape: MXC terminates descendants when the foreground process exits.
- **Probe**: PSEC create/close exactly as Codex does (also report whether `PSE_SUPPORT_FS_DENY` is present, so `denied_paths` can be dropped rather than failing the launch).
- Skip in volume-root/UNC/deny-glob machinery: pass absolute literal paths only, and make the Elixir side guarantee them (`deny_globs` unsupported on Windows in P1 — documented, not silently dropped).

### macOS policy upgrade (stay in Elixir)

No second binary on macOS — the policy is string generation, and a helper would add signing/notarization surface for zero benefit.

Shipped (the cheap subset of P2):

- resolved-spelling alias rules: `/tmp` + `/private/tmp`, `/var/tmp` + `/private/var/tmp`, and — for cwd, cache dirs, the task tmpdir, the config/data dirs, the git-metadata dir, the credential denies, the system denies and the host `$TMPDIR` read rule — one rule per spelling, logical first, because Seatbelt matches RESOLVED vnodes and a logical spelling alone silently misses;
- credential `literal` + `subpath` in ONE rule (`(deny file-read* (literal "<p>") (subpath "<p>"))`), read and write groups alike: `subpath` alone leaves a first-time `mkdir` gap, and SBPL OR-combines a rule's filters;
- exactly one `(deny system-fcntl (fcntl-command 80 110))` (`F_MAKECOMPRESSED` / `F_TRANSFEREXTENTS` mutate file contents through an already-open read-only fd), emitted after the deny-write group and stripped together with the `(limit …)` line by the strip-and-retry fail-safe;
- an env-free renderer: `MacOS.generate_profile/3` takes the `:alias_fun` / `:host_tmpdir` seams, `spec.host_tmpdir` drives the host-tmpdir rule, and the renderer reads no env or config itself.

Still open (P2 remainder):

- `-DKEY=VALUE` parameter rendering (`READABLE_ROOT_i`, `WRITABLE_ROOT_i`, `WRITABLE_ROOT_i_EXCLUDED_j[_RESOLVED]`, `PROTECTED_ANCESTOR_i`) instead of string interpolation of paths;
- protected-ancestor machinery: every read-only carveout inside a writable root protects ALL its ancestors (logical and resolved) against rename/unlink;
- deny-glob → anchored SBPL regex compilation;
- the symlink-fail-closed rework (a writable root containing a nested symlink fails closed; only top-level aliases normalize);
- extracting the SBPL fragments to `apps/evo_git/priv/sandbox/*.sbpl` (`seatbelt_base`, `read_only_platform_defaults`, `network`), loaded with `Application.app_dir/2`, with Chromium/Codex attribution headers.

Kept as is: `(limit number N)`, the strip-and-retry fallback, and network default-allow (Genesis tools need network).

## Phased plan

| Phase | Deliverable | Exit criteria | Status |
|---|---|---|---|
| **P0** | `EvoGit.Sandbox.Spec` + `Spec.build/2`; macOS/Linux/bwrap renderers consume it; shared root/deny/cache/credential lists extracted | profile/argv tests green; only the credential-parity delta changed | **implemented** |
| **P1** | Rust helper crate + `Sandbox.WindowsMxc` backend + `Background` clause + config enum + probe caching (`:persistent_term`) + test seams | `cargo test` green on CI windows runner; Elixir tests pass against a fixture helper binary on POSIX; `probe` gated skip on hosts without PSEC | **deferred** — no Windows build or test host in the project |
| **P2** | macOS hardening: fragments + `-D` rendering + protected ancestors + deny-glob compilation + symlink fail-closed | new profile assertions pin each anti-bypass rule; real `sandbox-exec` tests skip when nested denial is unavailable | cheap subset **implemented**, remainder open |
| **P3** | Resource governance (separate workstream; see below) | memory budget enforced or explicitly documented as best-effort per backend | open |
| **P4** | Packaging & ops: CI cargo build before `mix release` in `build-windows-x64`, `.gitignore`, dev build task (`mix sandbox.build_helper`, shells to cargo; the first such task in the repo), Settings/System status surface via `backend_reason/0`, `docs/` + CONTEXT.md updates | `genesis_desktop` Windows bundle contains `priv/vendor/windows-x64/genesis-sandbox.exe`; `EvoGit.Executable.resolve/1` finds it | blocked on P1 |

Order: P0 → (P1 ∥ P2) → P3 → P4; P4's Windows half ships with P1, so the whole Windows half waits for a build host.

### P1 detail (the risky one)

1. **Spike first (half day, on a real Windows host)**: `cargo run -- probe` against `mxc-sdk` at the pinned rev; confirm toolchain (`flatbuffers`, `tracelogging = "=1.2.3"`, `advapi32` link), MSVC build, and that a denied write really fails. If `mxc-sdk`'s git dep is unbuildable in our environment, the fallback is a thin `windows-sys` binding to the PSEC API-set (more work, same contract) — decide here, before writing the backend.
2. Elixir backend `EvoGit.Sandbox.WindowsMxc`: `enabled?/0` = mode + helper present + cached probe; `run/4`/`run_with_partial/7` build the spec, write the JSON to a 0600 temp file beside the task tmpdir, launch the helper via `Helpers.run_tracked_command/7` (so `ProcessManager` attaches and `kill_process_tree/1` works); map exit 125 to `{:error, …}`; never wrap twice (`Sandbox.ENV_INNER` marker — we implement the guard Codex lacks).
3. `Background.do_spawn/2` new clause: helper as the port-owning shell replacement, `{:cd, cwd}`, tmpdir env; kill path unchanged (`kill_process_tree`), status unchanged (`Port.info/1`).
4. Config: `[:sandbox, :backend]` enum + `[:sandbox, :windows, :network]` (`:allow` default, `:deny` opt-in); `[:sandbox, :windows, :memory_max]` reserved for P3.
5. Tests: spec→JSON unit tests; argv/exit-code mapping via a fixture "helper" script on POSIX (`Application.get_env(:evo_git, :windows_sandbox_helper)` seam); `probe`/availability seams (`:sandbox_probe_fun`), mirroring `Bwrap.capability/0`.

## Resource governance (OOM) — a separate workstream, not part of the sandbox

MXC gives containment, not accounting: no job memory quota exists in the reference implementation, and Seatbelt has no memory limit (only `(limit number)` for process count).
Options, in order of preference:

1. **Windows**: the helper creates its **own** Job Object with `JOB_OBJECT_LIMIT_JOB_MEMORY` (+ `KILL_ON_JOB_CLOSE`) and puts itself in it *before* spawning, so MXC's child inherits the outer job (Windows 8+ nested jobs). Validate in the P1 spike; if MXC's internal job refuses nesting, fall back to (3).
2. **bwrap**: no kernel memory cap today either — same watchdog as macOS.
3. **Portable watchdog** (macOS, bwrap, Windows fallback): `EvoGit.ProcessManager` already samples `memory_bytes` per execution; add a per-execution RSS budget that kills the tree on breach, with the budget from `[:sandbox, :process, :memory_max]`. Best-effort by construction — document it as such.

Do not present sandboxing as an OOM fix in user-facing copy.

## Non-goals

- Legacy Windows backends: restricted token / sandbox user / AppContainer + ACL provisioning, elevated runner IPC (Codex's `windows-sandbox-rs` legacy path). Unsupported hosts fall back to no sandbox with a warning.
- WSL2 wrapping, HIP (hardware-isolated) / VM boundaries on any platform.
- Codex's managed network proxy (`NetworkProxy`, proxy-port-only Seatbelt rules, `CODEX_SANDBOX_LAUNCH_*` env transport).
- Deny-glob support on Windows in P1 (macOS gets it in P2), volume-root expansion, UNC handling.
- PTY support for sandboxed commands (unchanged: buffered output today).
- Protecting `.git` or `.genesis/` under writable roots: Genesis agents legitimately write `.git` (worktree pointer, commits through the `git` tool), and every agent worktree lives UNDER `<repo>/.genesis/workers/…` (foreign read views under `<repo>/.genesis/foreign_repos/…`), so a read-only or deny carveout there would block every agent's own cwd — both stay writable, and a `.genesis/` carveout is deliberately NOT implemented (do not re-attempt it without moving worktrees out of `.genesis/` first). Revisit if the shell tool stops being used for git.

## Risks & gotchas

- **No Windows dev host in the loop**: enforcement can only be validated by Rust unit tests on CI plus a manual checklist. Keep the Elixir seam injectable so the backend is testable on Linux CI with a fixture helper.
- **Host coverage**: PSEC needs Windows 11 24H2 build ≥ 26100.9278. Many users will get "no sandbox"; the dashboard must say so rather than silently degrade.
- **`mxc-sdk` is a pre-1.0 git dependency** pinned by rev: vendor or patch it if the rev disappears; expect API churn on bumps.
- **Codex's exit-code ambiguity** (launcher error also exits 1) — our 125 convention exists to avoid inheriting it.
- **Helper as process owner** is load-bearing: a `run-and-exit` helper would silently orphan detached jobs because MXC kills descendants on foreground exit.
- **macOS `-p` inline profile** is ARG_MAX-bound; our root set is small, but keep specs absolute and short rather than dumping arbitrary user path lists.
- **`-D` values must be the resolved spellings** (`/private/tmp`, `/private/var`) or the grant silently misses.
- **macOS `subpath`-only carveouts leave a creation gap** — always pair with `literal`.
- **`cargo` in CI**: the Windows job currently has no cargo step before `mix release`, and `build-linux-server` has no Rust toolchain at all; only the Windows desktop job needs it for P1.
- **Windows signing**: none exists, so a new `.exe` inherits that status (SmartScreen may warn); macOS needs nothing new because we add no macOS binary.
- **`priv/vendor` is git-ignored per-file only** (`vendor/*/git`, `vendor/*/rg`) — the new binary needs its own `.gitignore` entry, and dev machines without it must degrade to `None`, not crash.

## Test strategy

- **Rust**: pure unit tests for spec→`ExecutionRequest` mapping (paths, precedence deny > ro > rw, network on/off, exit mapping); a `probe`-gated integration test spawning `cmd.exe` to assert an allowed write succeeds and a denied write fails (skips when PSEC is unavailable, mirroring Codex's nested-Seatbelt skip guards).
- **Elixir spec tests**: `Spec.build/2` from config permutations.
- **macOS policy tests** (string assertions, ported from Codex's list): `-D` parameter names/ordering; writable-root anchor present; carveout emits both `literal` and `subpath`; ancestor denies appear after the last `(allow file-write*`; metadata regex blocks first-time creation; symlinked writable root fails closed; `/tmp` renders as `/private/tmp`; fcntl deny present; preferences fragment only with unrestricted reads.
- **Windows backend tests**: probe/availability seams, spec-file writing (0600, cleaned up), exit-code mapping, timeout → tree kill, background spawn clause, `mode: "enabled"` unavailable → explicit reason.
- **Regression pin**: keep the existing "no test executes a real backend" convention for CI determinism; real-backend checks live behind `@tag :sandbox_integration` and run manually.

## Reference pointers

- Codex source: `/home/bill/Source/codex` — `codex-rs/mxc-sandbox/` (transport, policy translation, availability), `codex-rs/utils/pty/src/win/job.rs` (job flags), `codex-rs/sandboxing/src/seatbelt.rs` + `seatbelt_*.sbpl` + `*_tests.rs`, `codex-rs/windows-sandbox-rs/` (legacy, for edge-case lore only).
- Genesis current code: `apps/evo_git/lib/evo_git/sandbox/` (`behaviour.ex`, `macos.ex`, `linux.ex`, `bwrap.ex`, `none.ex`, `background.ex`, `helpers.ex`), `apps/evo_git/lib/evo_git/executable.ex`, `apps/evo_git/lib/evo_git/config/schema/definitions.ex`, `.github/workflows/build-desktop.yml`, `genesis.nix`, `desktop/scripts/sign-macos-nested.sh`.
