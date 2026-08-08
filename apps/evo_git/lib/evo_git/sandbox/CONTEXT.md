# Sandbox — Multi-Platform Sandbox Backend

## Intent
Provides platform-specific sandboxing for agent-executed commands. Dispatches to the appropriate backend based on `EvoGit.Platform.sandbox_backend/0`.

## Routing Table
None — leaf directory (modules: `sandbox.ex`, `behaviour.ex`, `helpers.ex`, `linux.ex`, `macos.ex`, `none.ex`). Note: `EvoGit.Sandbox` dispatcher itself lives at `lib/evo_git/sandbox.ex` — a SIBLING FILE (outside this node; read-only for agents here). Test suite is at `apps/evo_git/test/evo_git/sandbox/` — also a sibling node (read-only from here; escalate test-file changes to the parent).

## API Surface
| Module | Description |
|---|---|
| `EvoGit.Sandbox` | Dispatch module (sibling file `lib/evo_git/sandbox.ex`) — routes to the active backend. `run/4` + `run_with_partial/6` accept ANY executable name + args list (no allowlist, no restriction) — the skills executor can pass `("bash", [script_path])` unchanged |
| `EvoGit.Sandbox.Behaviour` | Formal `@behaviour` contract that all backends implement (`enabled?/0`, `ensure_initialized/0`, `run/4`, `run_with_partial/6`) |
| `EvoGit.Sandbox.Helpers` | Shared utility functions extracted from the backends and lifecycle modules: `shell_escape/1` (POSIX-safe, security-sensitive), `read_tempfile/2` (temp-file read + delete with optional truncation), `system_cmd/2` (normalized `System.cmd` wrapper) |
| `EvoGit.Sandbox.Linux` | Linux/systemd-run backend (`@behaviour EvoGit.Sandbox.Behaviour`) — full sandboxing (ReadWritePaths/InaccessiblePaths, ProtectHome/System, resource limits, slice). The `ReadWritePaths` cache-dir list is configurable via `[sandbox] write_paths` (see "Configurable Writable Paths" below). Unchanged by the 2026-08 macOS/Windows hardening work |
| `EvoGit.Sandbox.MacOS` | macOS/sandbox-exec backend (`@behaviour EvoGit.Sandbox.Behaviour`) — **deny-by-default SBPL profile with explicit file-read allows, process-count limit (with fail-safe), default-allow network** (see "macOS SBPL Profile" below) |
| `EvoGit.Sandbox.None` | Passthrough backend (`@behaviour EvoGit.Sandbox.Behaviour`) — no OS-level isolation on Windows/unsupported platforms; `run_with_partial` Windows clause kills the WHOLE process tree on timeout via `taskkill /T /F` (see "Windows gap" below) |
| `EvoGit.Nix` | Shared helper for running commands inside a cached Nix dev environment — builds the dev env ONCE via `nix print-dev-env`, caches the bash script to `<data_dir>/nix-dev-env.sh`, and sources it per call via `bash -c "source <path>; exec <cmd>"`. Gate: `active?/0` (enabled + dev-env build not failed); `enabled?/0` is the static capability check |

## macOS SBPL Profile — Hardened Deny-by-Default Policy (commits 3741c66c + f4f3f49c)

`generate_profile/2` (`macos.ex`) previously emitted `(deny default)` followed by a **global `(allow file-read*)`** — sandboxed agents could read ANY file the user could (including `~/.ssh/id_rsa`, `~/.gnupg`, etc.); the sensitive-dir rules were deny-WRITE only. Since 3741c66c the profile is deny-by-default for READS too. Emitted rule groups, in order:

1. `(version 1)` / `(deny default)`
2. **System read paths**: `/System`, `/usr`, `/bin`, `/sbin`, `/Library`, `/etc`, `/private/etc`, `/private/var`, `/dev` (binaries, dyld, system libs, certs, device nodes — bash/toolchain startup needs)
3. **Nix** (only when `Nix.enabled?()`): read + write for `/nix/store`, `/nix/var`
4. **Repo**: read+write on `cwd` (worktree) and `<repo_root>/.git`
5. **Tmp**: read+write on `Platform.tmp_paths()` (`/tmp`, `/var/tmp`)
6. **Genesis dirs**: read+write on `Platform.config_dir()` + `Platform.data_dir()` (macOS: `~/Library/Application Support/genesis` — NOT under /tmp or repo)
7. **Home read allow** `(allow file-read* (subpath home))` — tool configs (`~/.gitconfig`, `~/.npmrc`... wait, `.npmrc` is deny-read now) — then immediately after:
8. **Deny-read sensitive list** (deny takes precedence over allow in SBPL): `.ssh`, `.gnupg`, `.aws`, `.kube`, `.config/sops`, `.git-credentials`, `.netrc`, `.password-store`, `Library/Keychains`, `.npmrc`, `.pypirc`, `.docker`, `.gem` (credential stores; Linux InaccessiblePaths parity)
9. **SSH host-verification literal reads**: `(allow file-read-data (literal "<home>/.ssh/known_hosts"))` + `.ssh/config` — keeps `git fetch/push` over SSH working for public repos while private keys stay blocked; key-auth needs ssh-agent (`SSH_AUTH_SOCK`)
10. **Host `$TMPDIR` read** `(allow file-read* (subpath <expanded $TMPDIR>))` — CRITICAL: macOS per-user tmp is `/var/folders/...`, NOT under `/tmp`; the skills executor and other callers write temp files (skill scripts) via `System.tmp_dir!()` BEFORE the sandbox starts, so they must be readable inside. Skipped when `$TMPDIR` unset
11. `(allow file-read-metadata)` unqualified — stat/ls/glob on arbitrary paths under default-deny
12. **Writes**: build-cache dirs under home (`.cache`, `.local/share`, `.local/state`, `.cargo`, `.rustup`, `.mix`, `.hex`, `.npm`, `.yarn`, `.bun`, `.m2`, `.gradle`, `go`) — documented rationale: package managers/toolchains (`mix deps.get`, `npm install`, `cargo build`) must write caches; plus `/dev/null` + `/dev/dtracehelper` literals. **The cache-dir list is configurable via `[sandbox] write_paths`** — nil (unset) = this default list; set (even `[]`) = the user's list REPLACES it (see "Configurable Writable Paths" below)
13. **Deny-write sensitive list** (defense in depth; original list: `.ssh`, `.gnupg`, `.aws`, `.kube`, `.config/sops`, `.npmrc`, `.git-credentials`, `.netrc`)
14. **Process limit**: `(limit number #{@max_processes})` (`@max_processes 200`, module attribute, tunable) + `(allow process-exec)`, `(allow process-fork)`
15. **Network: `(allow network*)` — KEPT (default-allow), deliberate decision** — agents legitimately run `git fetch/push`, `mix deps.get`, `curl`, web tools; default-deny network breaks core workflows. The primary boundary is the tightened filesystem + process limits. **Future extension point (schema proposal, NOT yet implemented):** a `[sandbox] network_mode = "allow" | "deny"` TOML key belongs in `config/schema/` (outside this node) to gate this rule.
16. mach/sysctl/ipc: `(allow mach-lookup)`, `(allow sysctl-read)`, `(allow process-info*)`, `(allow signal)`, `(allow ipc-posix-sem)`, `(allow ipc-posix-shm)`

### Process-limit fail-safe (f4f3f49c) — do not remove
The exact SBPL `limit` parameter syntax (`(limit number N)` vs `(limit (number N))`) **could not be verified without a macOS host** (CI is Linux; `sandbox-exec` unavailable). A wrong form would make `sandbox-exec` reject the WHOLE profile → every sandboxed command fails on macOS in `:auto` mode (the default). Therefore `run/4` and `run_with_partial/6` (enabled paths) implement a fail-safe: on non-zero exit with no cached decision, retry ONCE with `strip_process_limit(profile)`; on retry success, cache `true` at `:persistent_term` key `{EvoGit.Sandbox.MacOS, :process_limit_rejected}` and warn once; subsequent calls use the stripped profile directly. On healthy macOS: zero overhead (first attempt succeeds). On a rejecting macOS: one extra spawn once, then only the process-count limit is lost. **Keep this machinery even if the syntax is confirmed on real macOS** — it is cheap insurance. `generate_profile/2` still emits the limit; the fallback only catches rejection.

### Real-macOS validation points (unverifiable on Linux CI)
- `sandbox-exec -p` acceptance of the FULL profile (all rules incl. `(limit number 200)`)
- bash/dyld startup reads (covered by system paths; verify on real hardware)
- SSH literal allows vs deny-precedence: if strict deny-precedence shadows `known_hosts`/`config` literals, git-over-SSH host verification fails (then move the literals outside the `.ssh` deny-read subpath)
- `/tmp` → `/private/tmp` symlink aliasing (existing rules use literal `/tmp`/`/var/tmp`)

## Configurable Writable Paths — `[sandbox] write_paths`

Both Linux (`args/4` → `-p ReadWritePaths=-<path>`) and macOS (`generate_profile/2` → `(allow file-write* (subpath "<path>"))`) resolve the writable cache-dir list from `EvoGit.Config.resolve([:sandbox, :write_paths])` (schema key `:list_of_strings`, default `nil`):

- **`nil` (unset)** → the built-in default cache-dir list (`.cache`, `.local/share`, `.local/state`, `.cargo`, `.rustup`, `.mix`, `.hex`, `.npm`, `.yarn`, `.bun`, `.m2`, `.gradle`, `go`, home-relative) — byte-identical to historical output.
- **set (even `[]`)** → the user's list REPLACES the default cache-dir list; `[]` disables the cache-dir write paths entirely.

**Path convention** (per entry): `~`-prefixed → `System.user_home!()` (e.g. `~/cache` → `<home>/cache`, bare `~` → `<home>`); absolute (leading `/`) → used as-is; relative → joined to `System.user_home!()` (the same base the defaults use). `Path.expand` is deliberately NOT used — env substitutions like `$HOME` are NOT expanded (a `$HOME/x` entry is treated as a relative path component).

**Structural paths are ALWAYS appended** after the cache-dir list — they are required for the sandbox to function, NOT part of the user-configurable list: Linux appends `cwd`, `Platform.tmp_paths()`, nix `/nix/store` + `/nix/var` (when `Nix.enabled?()`), and `<repo_root>/.git`; macOS always grants cwd, tmp paths, nix, repo `.git`, and genesis dirs in their own profile groups.

**Deny lists are NEVER affected** — the config replaces only the ALLOW/write list: Linux `InaccessiblePaths` (sensitive-dir deny) and the macOS deny-read/deny-write sensitive lists stay exactly as-is.

Implementation: both backends define a `@default_cache_dirs` module attribute + a private `resolve_write_paths/2` (deliberately duplicated across the two backend files — same ~20-line pure function, kept local to each backend per the edit-scope constraint).

## Windows / None Backend — No-Sandbox Gap (Known Issue)

**Status**: `EvoGit.Sandbox.None` is the fallback backend for Windows and unsupported platforms. It provides **no OS-level isolation** — a known, documented gap, not an oversight. One minimal hardening was added for the timed path (commit `372566a7`); the rest requires Windows APIs unreachable from pure Elixir.

**What Windows execution currently provides:**
- `run/4` — direct `System.cmd(executable, args, cd: cwd, stderr_to_stdout: true, env: git_env)`: **cwd confinement** via `cd: cwd` (raises if dir missing); **no command-injection surface** (args passed as an ARRAY — deliberately NO shell wrapper / `bash -c` string assembly on Windows); **no timeout — by contract** (`run/4` is unbounded; `git add`/`git commit` callers like `EvoGit.sandbox_run/4` rely on it — do NOT add a default timeout); git identity/`LC_ALL`/`GIT_EDITOR` injected via `EvoGit.GitEnv.git_env_list/1`.
- `run_with_partial/6` (Windows clause, since `372566a7`): runs via a directly-owned `Port.open({:spawn_executable, ...})` mirroring `System.cmd`'s exact port options (`:binary, :exit_status, :hide, :stderr_to_stdout`, args/cd/env), so the OS PID is readable via `Port.info(port, :os_pid)`. **On timeout the WHOLE process tree is killed** via `taskkill /PID <pid> /T /F` (previously `Task.shutdown/1` killed only the direct child — cmd.exe/powershell grandchildren were orphaned). **Partial output accumulated up to the timeout is returned** (`{:timeout, partial_output}`, truncated to `max_bytes`) — previously lost on Windows. Graceful degradation: if the OS PID hasn't materialized when the timeout fires (rare), falls back to `Port.close/1` (direct child only). Executable resolution mirrors `System.cmd` (absolute as-is; else `:os.find_executable` PATH/PATHEXT — finds MinGit bash; raises `ErlangError(:enoent)` when missing).

**Residual risks (unchanged — fixing them requires OS APIs):** arbitrary file-system read/write anywhere the user can access (no read-only paths); no CPU/memory/process-count limits; no kill-tree on `run/4` (unbounded by contract); no network isolation; no AppContainer/restricted token (children run with the user's full privileges).

**What a real Windows sandbox would require:** **Job Objects** — `CreateJobObject` + `SetInformationJobObject` with `JobObjectExtendedLimitInformation` (CPU/memory limits) + `JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE` (guaranteed kill-tree, replacing best-effort `taskkill /T`) — via a NIF or Erlang port program (Windows API not reachable from pure Elixir); **AppContainer / restricted token** — also NIF/port; **simpler alternatives**: run agent tool calls inside WSL2 or a Windows Sandbox/container as an external wrapper.

**Windows-only caveats worth preserving (do not "fix"):** MinGit bash used for skills scripts — keep PATH/PATHEXT resolution so it is found; the arg-array form avoids PowerShell's `<` input-redirection parser error (the Unix `bash -c "<cmd> < /dev/null"` wrapping must stay Unix-only).

**Testing note**: the Windows clauses are unreachable in the Linux/macOS test suite (`EvoGit.Platform.windows?/0` is runtime `:os.type()`, not injectable) — the port-based collect loop and `taskkill` path are compile-checked only on Linux. Windows runtime verification is required before further changes.

## Skills Script Execution Through the Sandbox (verification findings, 2026-08)

The skills executor (`lib/evo_git/skills/executor.ex` — outside this node) currently runs skill scripts via raw `System.cmd("bash", [tmp_file], cd: repo_path)`; a parallel change will rewire it to `EvoGit.sandbox_run(repo_path, "bash", [tmp_file], repo_path)`. Verified:
- **Dispatcher needs NO changes** — `run/4`/`run_with_partial/6` accept any executable+args; `Executable.resolve("bash")` returns `"bash"` when on PATH. Return shape `{output, exit_code}` is identical to the current `System.cmd` result.
- **Linux**: script at `System.tmp_dir!()` (`/tmp`) is inside `ReadWritePaths` (`[cwd | Platform.tmp_paths()]`); `InaccessiblePaths` covers only the 8 sensitive home dirs; systemd defaults make everything else readable → works unchanged.
- **macOS**: script at `System.tmp_dir!()` = host `$TMPDIR` (`/var/folders/...`) is NOT under `/tmp` — the hardened profile's **host-`$TMPDIR` read rule (group 10) is what makes it readable**. If that rule is ever removed, skill scripts break inside the sandbox. Recommended: have the skills executor write scripts under `EvoGit.Sandbox.resolve_tmpdir()` (→ `/tmp` on macOS when `$TMPDIR` is `/var/folders`) so `tmp_paths` rules cover it, and optionally use `sandbox_run_with_partial/6` for a timeout (`{:ok, output, code} | {:timeout, partial}` — handle the different return shape).
- **Windows**: works via arg-array (no shell); keep the `System.find_executable("bash")` guard that returns the friendly "Install Git for Windows" error (a bare `sandbox_run` with missing bash raises `ErlangError(:enoent)`).
- `Helpers.shell_escape/1` safely quotes the script path in the assembled `bash -c` string; `Nix.wrap_command/2` accepts any executable name (compatible).

## Constraints
- All backends implement `@behaviour EvoGit.Sandbox.Behaviour` — the dispatch module (`EvoGit.Sandbox`) calls the behaviour callbacks uniformly
- Shared helpers live in `EvoGit.Sandbox.Helpers` — `shell_escape/1`, `read_tempfile/2` (with `read_truncated/3`), and `system_cmd/2`. Backends and `EvoGit.Nix` alias `Helpers` and delegate to these functions instead of duplicating them
- `shell_escape/1` is **security-sensitive** (command injection prevention) — it has exactly one definition in `EvoGit.Sandbox.Helpers`
- `EvoGit.Sandbox.Linux` depends on `EvoGit.SandboxProcessRegistry` (caller-process monitoring) and `EvoGit.SandboxSlice` (systemd slice management) — both started in Application supervision tree on Linux only
- `EvoGit.Sandbox.MacOS` uses inline SBPL profile generation (no external template files). Emitted profile is PURE SBPL — no `#` comments inside (comment support in sandbox-exec not validated; all rationale lives in Elixir source comments)
- `EvoGit.Sandbox.None` is the fallback for Windows and unsupported platforms
- Callers use `EvoGit.sandbox_run/4` (delegates to `EvoGit.Sandbox.run/4`) — tool modules do not need to know about backends
- `EvoGit.Nix` is a standalone helper module (not a sandbox backend) — backends consult it to optionally wrap commands when Nix is enabled. It depends on `EvoGit.Config` (for the `[nix]` table and config dir) and `EvoGit.Platform` (`nix_available?/0`)
- When nix is active, Linux backend forwards all `NIX*` + `SSL_CERT_FILE` env vars via `--setenv` and grants read-write access to `/nix/store` and `/nix/var`. macOS backend adds `/nix/store` and `/nix/var` to its SBPL profile. None backend wraps directly (inherits parent env). All three backends source the cached dev-env script (`nix print-dev-env` output) via `bash -c` rather than per-call `nix develop`. The `nix_paths`/`nix_env_vars` gating uses `Nix.enabled?/0` (static capability); the wrap decision uses `Nix.active?/0` (enabled + build not failed).

## Behaviour Contract
All three backends (`Linux`, `MacOS`, `None`) formally implement `@behaviour EvoGit.Sandbox.Behaviour`. The behaviour declares four callbacks:
- `enabled?/0` — whether sandboxing is available for this platform/mode
- `ensure_initialized/0` — lazily initialize backend resources (e.g. systemd slice); no-op when unneeded
- `run/4` — synchronous command execution returning `{output, exit_code}`
- `run_with_partial/6` — command execution with timeout + partial-output recovery returning `{:ok, output, exit_code}` or `{:timeout, partial_output}`

## Known Issues / Test Strategy
- **Test coverage gap (pre-existing):** `linux_test.exs` tests only `args/4` generation; `macos_test.exs` only `generate_profile/2` string assertions. NO test executes a real sandboxed command (systemd-run/sandbox-exec) — the `@mix_env == :test` gate in `Linux.enabled?/0` and the Linux-only CI make the real paths untested. All three backends' enabled paths are runtime-verified only.
- **macos_test.exs is under-pinned** (test node, outside this node): the hardened profile's new rules (deny-read list, `(limit number ...)`, genesis dirs, host `$TMPDIR` read, SSH literals, `file-read-metadata`, `network*`, absence of global `file-read*`) are NOT yet asserted in the committed test file — the drafted assertions were validated ad-hoc (`mix run -e`) but could not be written from this node (test dir is a sibling node). The parent should apply them at `apps/evo_git/test/evo_git/sandbox/macos_test.exs`.
- **Windows clauses untested** (see Windows section) — compile-checked only on Linux.
- **`(limit ...)` syntax unverified on real macOS** — mitigated by the fail-safe retry (see above); validate on a Mac and, if the form is wrong, fix `generate_profile/2`'s emission (tests pin `(limit number 200)`).
