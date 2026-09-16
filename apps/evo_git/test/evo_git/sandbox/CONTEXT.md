# Sandbox — Test Tree

## Intent

ExUnit suites for the sandbox subsystem (`EvoGit.Sandbox`, `EvoGit.Sandbox.{Linux,Bwrap,MacOS,None,Helpers,Behaviour}`) plus the nix dev-env integration module (`EvoGit.Nix`). The tests are mostly **pure argument-generation** checks (systemd-run / bwrap / SBPL strings) plus direct-execution behavior of the `None` backend; no real sandboxing backend is executed in the test environment.

## File Map

- `none_test.exs` (`EvoGit.Sandbox.NoneTest`) — `None` backend: `enabled?/0`, `ensure_initialized/0`, `run/4` (direct eval/bash execution), `resolve_executable/1` (binary/charlist input, absolute paths, missing executables), `run/4` stdin redirection, `run_with_partial/6` stdin redirection, and `GIT_EDITOR`/`LC_ALL` injection for git commands.
- `truncation_test.exs` (`EvoGit.Sandbox.TruncationTest`) — `None.run_with_partial/6` truncation contract: small files within `max_bytes`, large files above both `max_bytes` and the 8192-byte truncate window (warning header + omission marker + first/last portions), the exact warning format, `max_bytes = nil` (no truncation), and files over `max_bytes` but under the truncate window. Also the **temp-file cleanup** contract: the shared `genesis_partial_outputs` temp file must not survive the run.
- `helpers_test.exs` (`EvoGit.Sandbox.HelpersTest`) — `EvoGit.Sandbox.Helpers`: `shell_escape/1` (single-quote escaping, metacharacter safety), `truncate_output/2` (nil / under / exactly-at / over `max_bytes` but under the truncate window / full truncation with notice), `read_tempfile/2` (read-and-delete semantics, missing file, truncation), `task_tmpdir_path/0` (nil when no per-task tmpdir is installed on the calling process, else the installed path), `system_cmd/2` (`{:ok, _}` / `{:error, _}` / command-not-found).
- `behaviour_test.exs` (`EvoGit.Sandbox.BehaviourTest`) — behaviour conformance: `Linux`/`MacOS`/`None` all declare `@behaviour EvoGit.Sandbox.Behaviour` and export every required + optional (`run_with_partial/6`) callback.
- `bwrap_test.exs` (`EvoGit.Sandbox.BwrapTest`) — pure `Bwrap.args/4` generation (namespace flags, tmp/writable binds, git-metadata binds, deny list, chdir + `--`, nix integration, TMPDIR setenv, git identity env, bash tail, and the managed per-task tmpdir bind — `--bind-try <dir> <dir>` spliced after the system tmp binds and before `--` — with its `TMPDIR` override); no real `bwrap` is run.
- `linux_test.exs` (`EvoGit.Sandbox.LinuxTest`) — `Linux.args/4` (systemd-run arg generation): TMPDIR forwarding, `ReadWritePaths` (incl. the managed per-task tmpdir `-p ReadWritePaths=-<dir>` pair + its `TMPDIR` override), PATH/HOME, nix, `GIT_EDITOR` injection, bash wrapping for stdin; no real `systemd-run` is run.
- `macos_test.exs` (`EvoGit.Sandbox.MacOSTest`) — `MacOS.generate_profile/2` SBPL rules (deny-by-default, tmp/cwd/git-metadata writes, sensitive-dir deny list incl. `/private` symlink spellings, write_paths `~` expansion, default cache dirs, process-count limit, the managed per-task tmpdir read+write subpath rules), the linked-worktree `gitdir:` pointer resolution, `EvoGit.Sandbox.resolve_tmpdir/0` (legacy fallback rules + the managed-per-task-dir short-circuit), and the fail-safe `{MacOS, :process_limit_rejected}` cache. A `MacOS.run/4` execution test is guarded to real macOS hosts only.
- `nix_test.exs` (`EvoGit.NixTest`) — `EvoGit.Nix`: `dev_env_state/0`, `active?/0`, `wrap_command/2` (tuple shape, dev-env sourcing, shell escaping), `reset_state/0`, `nix_env_vars/0`, `sanitize_dev_env_output/1` (NIX_BUILD_TOP mktemp rotation substitution).

## Constraints

- No mocking libraries — assertions are pure value checks plus real `System.cmd`/`File.*` I/O in ephemeral temp dirs.
- Test module names mirror the source module path under test (e.g. `EvoGit.Sandbox.LinuxTest` tests `EvoGit.Sandbox.Linux`).
- `@moduletag :tmp_dir` is used for the per-test temp dirs that ExUnit manages (e.g. in `bwrap_test.exs`).
- Every `async: false` module carries a one-line comment at the top stating the VM-global state that forces serial execution.
- Assertions must never be weakened for load robustness — where a bounded retry/wait is used, the exact assertion is still performed and a genuine failure still fails.

## Notes for Agents

### async vs sync rationale

- **`async: true`** (no global mutation): `none_test.exs`, `truncation_test.exs`, `helpers_test.exs`, `behaviour_test.exs`.
- **`async: false`** — all of these mutate BEAM-global state that production code reads, so they must never run concurrently:
  - `bwrap_test.exs` — `System.put_env/1` for `$TMPDIR` + `$XDG_CONFIG_HOME`, `Application.put_env/2` for `:nix_enabled` and the `:bwrap_capability` seam, `:persistent_term` `:evogit_nix_dev_env_state` + `{Bwrap, :capability}`.
  - `linux_test.exs` — `System.put_env/1` for `$TMPDIR` + `$XDG_CONFIG_HOME`, `Application.put_env/2` for `:nix_enabled`.
  - `macos_test.exs` — `System.put_env/1` for `$TMPDIR` + `$XDG_CONFIG_HOME`, `Application.put_env/2` for `:nix_enabled`, `:persistent_term` `{MacOS, :process_limit_rejected}`.
  - `nix_test.exs` — `Application.put_env/2` for `:nix_enabled`, `:persistent_term` `:evogit_nix_dev_env_state` (via `Nix.reset_state/0` and direct seeds).
  - Do NOT flip any of these to `async: true`: the mutated state is read by production paths and by other modules.
- Installing a per-task tmpdir (`EvoGit.TaskTmpdir.put_current/1`) is a PROCESS-LOCAL pdict write — it mutates no BEAM-global state, so it does NOT force serialization (the `async: true` `helpers_test.exs` uses it freely).

### Managed per-task tmpdir coverage (`EvoGit.TaskTmpdir`)

- `EvoGit.Sandbox.resolve_tmpdir/0` PREFERS a managed per-task dir installed on the CALLING PROCESS (`EvoGit.TaskTmpdir.put_current/1` — a process-dictionary seam); `EvoGit.Sandbox.Helpers.task_tmpdir_path/0` derives the same value (non-empty binary → path, else `nil`).
- The backend tests cover BOTH states by installing via `EvoGit.TaskTmpdir.put_current(<path>)` in the TEST PROCESS before generating args/profile: `linux_test.exs` (the `-p ReadWritePaths=-<dir>` pair + the `TMPDIR` override), `bwrap_test.exs` (`--bind-try <dir> <dir>` spliced after the system tmp binds and before `--`, + the `TMPDIR` override), `macos_test.exs` (`(allow file-read*|file-write* (subpath "<dir>"))` rules — the macOS TMPDIR ENV injection lives inside `MacOS.run/4` and is not assertable without real `sandbox-exec`), `helpers_test.exs` (`task_tmpdir_path/0`).
- The install is process-local and read back in the SAME process, so the value never leaks across tests — **do NOT add `on_exit`/cross-process cleanup** for it (ExUnit gives each test a fresh process). The installed path is a pure string (never `mkdir`'d) — arg generation never stats it; creating it would only leave untracked trash.
- Every such test ALSO asserts the system tmp rules are UNCHANGED (the per-task dir is ADDITIONAL): Linux keeps `-p ReadWritePaths=-/tmp`,`/var/tmp` and bwrap keeps `--bind-try /tmp /tmp`,`/var/tmp`; macOS keeps its tmp read/write rules. The no-install case asserts the LEGACY output (no extra dir; `TMPDIR` = the legacy resolved value).
- Assertions are GENERATION-only (args/env strings); no real `systemd-run`/`bwrap`/`sandbox-exec` is executed.

### The shared `genesis_partial_outputs` temp dir

- Every backend's `run_with_partial/6` calls `EvoGit.Sandbox.Helpers.partial_output_tmpfile/0`, which creates a fresh file under `<EvoGit.Sandbox.resolve_tmpdir()>/genesis_partial_outputs` — a **single shared dir** used by all concurrently-running tests.
- `Helpers.read_tempfile/2` deletes that file with `File.rm/1` after reading, so the file is only transiently present.
- Consequently: **never assert on an absolute file count of that dir** — `none_test.exs` (and any other backend test) creates/deletes its own temp file there at arbitrary instants. `truncation_test.exs` compares the **set difference** against a pre-run baseline, with a bounded wait for the transient file to disappear, and still fails on a genuine leftover.

### Test environment disables the real sandbox backends

- `@mix_env == :test` short-circuits the Linux backends (`Linux.enabled?/0`, `Bwrap.enabled?/0`, `SandboxSlice`/`SandboxProcessRegistry` gates) to the disabled `bash -c` path — so real `systemd-run`/`bwrap` **never** run under ExUnit (CI containers have no systemd user bus). `bwrap_test.exs` and `linux_test.exs` therefore only test pure `args/4` generation, not execution.
- Nix is disabled BEAM-globally by `test/test_helper.exs` (`Application.put_env(:evo_git, :nix_enabled, false)`), so code paths reaching `Nix.active?/0` do not shell out to real `nix print-dev-env`. `bwrap_test.exs` re-enables it explicitly for its nix-integration cases.

### Global-state test hygiene

- Tests that mutate `$TMPDIR`/`$XDG_CONFIG_HOME` save and restore the original value in `on_exit` (see `save_tmpdir/0` in `macos_test.exs`).
- `resolve_tmpdir/0` reads `$TMPDIR` fresh at call time; `System.put_env/2` mutates the VM-global OS env, so under parallel load the pair can be observed inconsistently. `macos_test.exs` uses a bounded retry helper (`assert_tmpdir_falls_back/1`) that re-establishes `$TMPDIR` and re-reads, while keeping the exact `== List.first(Platform.tmp_paths())` assertion.
- `XDG_CONFIG_HOME` isolation is what makes the sandbox mode resolve to the built-in default instead of the developer's `~/.config/genesis/config.toml`.
- The `MacOS`/`Bwrap` capability and nix dev-env decisions are cached in `:persistent_term`; tests that seed them erase the keys on exit so no state leaks between tests.
