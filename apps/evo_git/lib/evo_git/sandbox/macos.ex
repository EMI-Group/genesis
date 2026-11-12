defmodule EvoGit.Sandbox.MacOS do
  @moduledoc """
  macOS sandbox backend using `sandbox-exec`.

  This module is a pure RENDERER: every root, deny list, cache dir and git
  metadata/tmp path comes from ONE `EvoGit.Sandbox.Spec` built by
  `EvoGit.Sandbox.Spec.build(:macos, cwd: cwd, repo_root: repo_root)`; the
  only macOS-specific policy left here is the extra `Library/Keychains`
  deny-read entry and the SBPL syntax itself. The renderer reads NO environment
  and no config — `$TMPDIR`, the tmp paths, the config/data dirs and the
  credential list all arrive through the spec.

  Filesystem policy: WRITES are deny-by-default with an explicit allow list
  (the repo worktree (cwd + `.git`), tmp paths, genesis config/data dirs,
  and build caches); READS are allow-by-default at the ROOT —
  `(allow file-read* (subpath "/"))` makes the whole filesystem readable so
  agents can use user-installed tools anywhere (Homebrew `/opt/homebrew`,
  Intel `/usr/local`, `/Applications`, custom `/opt` installs, nix,
  asdf/mise). Protection for credential stores comes from a deny-read list
  (SBPL deny rules take precedence over allow rules): home-based sensitive
  dirs (`~/.ssh`, `~/.gnupg`, `~/.aws`, `~/.kube`, `~/.config/sops`,
  `~/.git-credentials`, `~/.netrc`, `~/.password-store`,
  `~/Library/Keychains`, `~/.npmrc`, `~/.pypirc`, `~/.docker`, `~/.gem`)
  plus system-level sensitive locations (`/etc/ssh`, `/var/root`,
  `/etc/master.passwd`, `/var/db/dslocal`, `/var/db/Keychains` — both
  `/etc`↔`/private/etc` and `/var`↔`/private/var` spellings). This is a
  deliberate trade-off: sandboxed agents can read any user-readable file,
  mitigated by the deny list — the pre-hardening read model, restored by
  user decision because enumerating every legitimate tool path is
  unmaintainable. The host `$TMPDIR` stays readable so temp files written
  before sandbox invocation (e.g. skill scripts) remain usable. Writes are
  restricted to the worktree, tmp paths, genesis dirs, and
  package-manager/toolchain cache dirs, with deny-write rules for sensitive
  dirs as defense in depth.

  ## Spellings, credential carveouts, fcntl

  Seatbelt matches RESOLVED vnodes, so a rule written with the logical
  spelling of a path hidden behind a symlinked component (`/tmp` →
  `/private/tmp`) never matches. Every rendered path is therefore emitted once
  per SPELLING from `EvoGit.Sandbox.Spec.aliases/1` (identity when nothing
  resolves) — read/write pairs for structural paths and the resolved pair
  immediately after the logical one.

  Each credential carveout carries BOTH path filters of ONE rule —
  `(deny file-read* (literal "<p>") (subpath "<p>"))` — because SBPL
  OR-combines the filters of a rule while `subpath` alone leaves a
  first-time-creation gap (e.g. `mkdir ~/.ssh`). A single
  `(deny system-fcntl (fcntl-command 80 110))` rule closes the "mutate a file
  through a read-only fd" bypass (`F_MAKECOMPRESSED` / `F_TRANSFEREXTENTS`).

  Also enforces a process-count limit (`(limit number N)`, the spec's
  `:max_processes`) and keeps network default-allowed (agents run
  `git fetch/push`, `mix deps.get`, `curl`, and web tools). If the host's
  `sandbox-exec` rejects the `(limit ...)` or the `system-fcntl` rule
  (unverifiable without a macOS host), `run/4`/`run_with_partial/6`
  transparently retry once with the UNVERIFIED rules stripped and cache the
  decision — the sandbox keeps working with all other hardening intact.
  `generate_profile/3` exposes default-inert `:alias_fun` / `:host_tmpdir`
  seams; production calls the 2-arity form.
  """

  @behaviour EvoGit.Sandbox.Behaviour

  require Logger

  alias EvoGit.{Nix, Platform}
  alias EvoGit.Sandbox.{Helpers, Spec}

  # Cached decision that `sandbox-exec` on THIS macOS rejects the profile's
  # UNVERIFIED rules — `(limit ...)` and/or the `system-fcntl` deny (see
  # `strip_unverified_rules/1` and the retry logic in `run/4` /
  # `run_with_partial/6`). Once set to `true`, every subsequent call uses the
  # stripped profile directly, skipping the guaranteed-failing first attempt.
  # The key name is kept for the pinned test seam.
  @process_limit_rejected_key {EvoGit.Sandbox.MacOS, :process_limit_rejected}

  # macOS-only credential store: appended to the canonical
  # `EvoGit.Sandbox.Spec.credential_paths/0` deny-read list, immediately after
  # `.password-store`. It is NEVER part of the canonical list and never part of
  # the deny-WRITE list.
  @keychains_dir "Library/Keychains"

  # The two fcntl commands that mutate a file's contents through an already
  # open READ-ONLY descriptor, verified from Codex
  # (`codex-rs/macos-seatbelt/src/seatbelt.rs`): `F_MAKECOMPRESSED = 80`,
  # `F_TRANSFEREXTENTS = 110`. Denying them closes the "mutate a file through
  # a read-only fd" bypass. Emitted exactly once, and it is one of the two
  # UNVERIFIED rules `strip_unverified_rules/1` can drop.
  @fcntl_deny_rule "(deny system-fcntl (fcntl-command 80 110))"

  # Prefixes of the rules that could not be validated against a real macOS
  # host (CI is Linux); a rejected rule makes `sandbox-exec` refuse the WHOLE
  # profile, so the fail-safe retry drops every line starting with one of these.
  @unverified_rule_prefixes ["(limit ", "(deny system-fcntl "]

  @doc "Returns true when sandbox mode allows sandbox-exec on macOS."
  @spec enabled?() :: boolean()
  def enabled? do
    case EvoGit.Config.resolve([:sandbox, :mode]) do
      :enabled -> true
      :disabled -> false
      :auto -> Platform.sandbox_exec_available?()
    end
  end

  @doc "No initialization needed for sandbox-exec."
  @spec ensure_initialized() :: :ok
  def ensure_initialized, do: :ok

  @doc "Runs command via sandbox-exec with a generated SBPL profile."
  @spec run(String.t(), String.t(), [String.t()], String.t() | nil) ::
          {String.t(), non_neg_integer()}
  def run(cwd, executable, args \\ [], repo_root \\ nil) when is_list(args) do
    if enabled?() do
      resolved_tmpdir = EvoGit.Sandbox.resolve_tmpdir()

      # Once this macOS has been observed rejecting the profile's UNVERIFIED
      # rules ((limit ...) / the system-fcntl deny), use the stripped profile
      # directly — no guaranteed-failing first attempt on every call.
      profile = effective_profile(cwd, repo_root)

      {exec, exec_args} =
        if Nix.active?() do
          Nix.wrap_command(executable, args)
        else
          {executable, args}
        end

      # Inject LC_ALL=C and GIT_EDITOR=<true path> for git commands so that
      # automated operations that may open an interactive editor (e.g.
      # `git merge --continue`, rebase, am, commit) never block. Detection
      # uses the ORIGINAL executable param (before nix/bash wrapping).
      git_env =
        if EvoGit.GitEnv.git_command?(executable),
          do: EvoGit.GitEnv.git_env_list(cwd),
          else: []

      # Wrap in bash with stdin redirected from /dev/null so commands like rg
      # that read stdin on missing args get immediate EOF instead of hanging.
      wrapped_cmd = Helpers.build_shell_command(exec, exec_args) <> " < /dev/null"

      # sandbox-exec -p <profile> -- bash -c <wrapped_cmd>
      result = sandbox_exec(profile, "bash", ["-c", wrapped_cmd], cwd, resolved_tmpdir, git_env)

      # Fail-safe: if sandbox-exec rejects the `(limit ...)` rule (syntax
      # could not be validated without a macOS host), retry once with the
      # limit stripped so one bad rule can't break EVERY sandboxed command.
      maybe_retry_without_process_limit(
        result,
        profile,
        "bash",
        ["-c", wrapped_cmd],
        cwd,
        resolved_tmpdir,
        git_env
      )
    else
      # Disabled path: wrap in bash with stdin redirect from /dev/null. The
      # managed per-task tmpdir (when installed) is exported as
      # TMPDIR/TMP/TEMP — see `Helpers.temp_env_vars/0`.
      git_env =
        if EvoGit.GitEnv.git_command?(executable),
          do: EvoGit.GitEnv.git_env_list(cwd),
          else: []

      wrapped_cmd = Helpers.build_shell_command(executable, args) <> " < /dev/null"

      System.cmd("bash", ["-c", wrapped_cmd],
        cd: cwd,
        stderr_to_stdout: true,
        env: git_env ++ Helpers.temp_env_vars()
      )
    end
  end

  # Returns the SBPL profile that is actually handed to `sandbox-exec` for
  # `cwd`: `generate_profile/2`, minus the UNVERIFIED rules ((limit ...) and
  # the system-fcntl deny) when this macOS has already been observed rejecting
  # them (see the fail-safe in `run/4`). Shared with
  # `EvoGit.Sandbox.Background`, where a background job cannot be retried once
  # started — the cached rejection decision is the only signal available, so
  # the stripped profile must be chosen up front.
  @doc false
  def effective_profile(cwd, repo_root \\ nil) do
    profile = generate_profile(cwd, repo_root)
    if process_limit_rejected?(), do: strip_unverified_rules(profile), else: profile
  end

  # Generate an SBPL (Sandbox Policy Language) profile.
  #
  # Policy: READS are allow-by-default at the ROOT — `(allow file-read*
  # (subpath "/"))` makes the whole filesystem readable so agents can use
  # user-installed tools anywhere (Homebrew /opt/homebrew, Intel /usr/local,
  # /Applications, custom /opt installs, nix, asdf/mise). The previous
  # enumerated system-read allow-list proved unmaintainable (the
  # /opt/homebrew miss already broke Apple Silicon Homebrew git; ANY
  # user-installed tool outside the enumerated prefixes was unreadable).
  # Protection comes from the deny-read list below — in Apple's SBPL, deny
  # rules take precedence over allow rules, so the deny-read list (home-based
  # credential stores + system-level sensitive locations, both /etc↔/private/etc
  # and /var↔/private/var spellings) wins over the root read allow. WRITES
  # are deny-by-default: restricted to the worktree, tmp paths, genesis dirs,
  # and package-manager/toolchain cache dirs, with deny-write rules for
  # sensitive dirs as defense in depth. The git metadata rule resolves
  # linked-worktree `gitdir:` pointers so the per-worktree metadata dir
  # (objects/refs/index) is covered even when the caller passes a worktree
  # root or nil repo_root.
  #
  # NOTE: all comments are kept in Elixir source (not emitted into the
  # profile string) because `#` comment support in sandbox-exec could not be
  # validated here; the emitted profile is pure SBPL rules.
  @doc false
  def generate_profile(cwd, repo_root \\ nil, opts \\ []) when is_binary(cwd) do
    # The ONE place Genesis sandbox semantics live (roots, credential list,
    # cache dirs, git metadata, tmp/task/config/data dirs) — this module only
    # renders them as SBPL. `:host_tmpdir` is forwarded ONLY when present, so
    # an absent option keeps the spec's own `$TMPDIR` read; the renderer
    # never touches the environment or the config.
    spec_opts = [cwd: cwd, repo_root: repo_root] ++ Keyword.take(opts, [:host_tmpdir])
    spec = Spec.build(:macos, spec_opts)

    # Path → spellings (logical first, resolved alias second) — see
    # `EvoGit.Sandbox.Spec.aliases/1` and `spellings/2`.
    spellings_fun = alias_fun(opts)

    # --- Filesystem READ rules ---
    #
    # Reads are allow-by-default at the ROOT: `(allow file-read* (subpath "/"))`
    # makes the entire filesystem readable so agents can use user-installed
    # tools anywhere (Homebrew /opt/homebrew, Intel /usr/local, /Applications,
    # custom /opt installs, nix, asdf/mise). This replaces the old enumerated
    # system_read_paths allow-list — enumerating every legitimate tool path
    # proved unmaintainable (the /opt/homebrew miss already broke Apple
    # Silicon Homebrew git). Protection for sensitive locations comes from
    # the deny-read rules below (SBPL deny precedence: denies win over
    # allows).
    read_root_rules =
      Enum.map_join(spec.read_roots, "\n    ", fn path ->
        ~s{(allow file-read* (subpath "#{path}"))}
      end)

    # Repo access: the worktree (cwd) and every other structural write root,
    # emitted as a read+write PAIR per SPELLING (the logical path first, its
    # resolved alias immediately after) — Seatbelt matches resolved vnodes, so
    # a single-spelling rule can silently miss.
    write_root_rules =
      spec.write_roots
      |> Enum.flat_map(&spellings(&1, spellings_fun))
      |> Enum.map_join("\n    ", &rw_rule/1)

    # Belt-and-suspenders: the specific read rules below (nix reads, home,
    # host $TMPDIR, vendored git, file-read-metadata, ssh literals) are
    # REDUNDANT under the root-wide read allow but intentionally KEPT — a
    # safety net if `(subpath "/")` behaves unexpectedly on some macOS
    # (CI is Linux, so real-macOS validation of the root rule is pending).

    # Nix store/var: read (toolchain binaries) + write (build outputs) —
    # emitted only when nix is enabled (`spec.nix_paths` is `[]` otherwise).
    nix_rules =
      spec.nix_paths
      |> Enum.flat_map(fn path ->
        [
          ~s{(allow file-read* (subpath "#{path}"))},
          ~s{(allow file-write* (subpath "#{path}"))}
        ]
      end)
      |> Enum.join("\n    ")

    # Repo access: the git metadata dir (the worktree/cwd is the write root
    # above). Resolved by `EvoGit.Sandbox.Spec` through
    # `Helpers.git_metadata_dir/2`, which follows linked-worktree `gitdir:`
    # pointer files so the common git dir is covered even when the caller
    # passes a worktree root or nil repo_root. Read+write pair per spelling.
    git_metadata_rules =
      spec.git_metadata_dir
      |> List.wrap()
      |> Enum.flat_map(&spellings(&1, spellings_fun))
      |> Enum.map_join("\n    ", &rw_rule/1)

    # Vendored git (desktop bundle): when git is NOT on PATH,
    # `Executable.resolve("git")` returns the absolute path of the bundled
    # binary (`<app_dir>/priv/vendor/macos-<arch>/git`), and `spec.git_binary_dir`
    # carries its dirname so an explicit read rule is emitted (vendored
    # binaries are self-contained — the dirname subpath is the minimal targeted
    # rule). Redundant under the root-wide read allow but KEPT as
    # belt-and-suspenders. When git IS on PATH, resolve returns the bare name
    # "git" and no rule is emitted.
    git_binary_read_rule =
      case spec.git_binary_dir do
        nil -> ""
        dir -> ~s{(allow file-read* (subpath "#{dir}"))}
      end

    git_rules =
      [git_metadata_rules, git_binary_read_rule]
      |> Enum.reject(&(&1 == ""))
      |> Enum.join("\n    ")

    # Tmp paths: read-write — processes create temp files and read them back.
    # Per spelling: the resolved pair goes immediately after the logical pair.
    tmp_rules =
      spec.tmp_paths
      |> Enum.flat_map(&spellings(&1, spellings_fun))
      |> Enum.map_join("\n    ", &rw_rule/1)

    # Managed per-task tmpdir (when installed on the calling process): the
    # runtime injects this as the sandbox TMPDIR, so it must be granted BOTH
    # read and write access. It is an ADDITIONAL path — the system tmp dirs
    # (tmp_rules above) stay writable regardless. Evaluates to "" when unset,
    # mirroring the empty-group pattern used by git_rules/nix_rules.
    task_tmpdir_rules =
      spec.task_tmpdir
      |> List.wrap()
      |> Enum.flat_map(&spellings(&1, spellings_fun))
      |> Enum.map_join("\n    ", &rw_rule/1)

    # Genesis config/data dirs (e.g. `~/Library/Application Support/genesis`
    # on macOS — NOT under /tmp or the repo): the runtime reads and writes
    # config, credentials, state, and logs there.
    genesis_rw_rules =
      [spec.config_dir, spec.data_dir]
      |> Enum.reject(&is_nil/1)
      |> Enum.flat_map(&spellings(&1, spellings_fun))
      |> Enum.map_join("\n    ", &rw_rule/1)

    # Home reads: allow the whole home, then deny-read the sensitive dirs.
    # Deny rules take precedence over allow rules in SBPL, so the deny-read
    # list below wins over this allow.
    home_read_rule = ~s{(allow file-read* (subpath "#{spec.home}"))}

    # The canonical credential list (`Spec.credential_paths/0`) plus the
    # macOS-only `Library/Keychains` entry, emitted immediately AFTER
    # `.password-store`. Each rule carries BOTH filters (`literal` +
    # `subpath`): SBPL OR-combines a rule's filters, and `subpath` alone leaves
    # a first-time-creation gap (e.g. `mkdir ~/.ssh`); see `credential_rule/2`.
    # The resolved spelling follows the logical one when the home path has a
    # symlinked component.
    sensitive_read_dirs =
      Enum.flat_map(spec.credential_paths, fn
        ".password-store" = dir -> [dir, @keychains_dir]
        dir -> [dir]
      end)

    sensitive_read_rules =
      sensitive_read_dirs
      |> Enum.map(&Path.join(spec.home, &1))
      |> Enum.flat_map(&spellings(&1, spellings_fun))
      |> Enum.map_join("\n    ", &credential_rule("file-read*", &1))

    # System-level sensitive locations (defense in depth): under the
    # root-wide read allow these must be explicitly denied. Most are
    # root-only-readable anyway, but the deny list guarantees it even if
    # file permissions are relaxed. Both symlink spellings are covered
    # (/etc ↔ /private/etc and /var ↔ /private/var), mirroring the pattern
    # of the home-based list; these keep the subpath-only shape (no
    # first-time-creation concern for root-owned system paths).
    system_sensitive_read_rules =
      spec.deny_paths
      |> Enum.flat_map(&spellings(&1, spellings_fun))
      |> Enum.map_join("\n    ", fn path ->
        ~s{(deny file-read* (subpath "#{path}"))}
      end)

    # SSH host verification: `git fetch/push` over SSH must read known_hosts
    # and ssh config to verify the server. Private keys stay unreadable by
    # design — key-based auth over SSH requires ssh-agent (`SSH_AUTH_SOCK`),
    # which never exposes key material to the sandboxed process. These are the
    # spec's read-only carveouts inside the otherwise denied `~/.ssh`.
    # Single-spelling on purpose: the files, not the enclosing dirs, are the
    # grant.
    ssh_literal_rules =
      Enum.map_join(spec.read_only_subpaths, "\n    ", fn path ->
        ~s{(allow file-read-data (literal "#{path}"))}
      end)

    # Host $TMPDIR read: on macOS the per-user tmp dir is `/var/folders/...`,
    # NOT under /tmp. The skills executor and other callers write temp files
    # (e.g. skill scripts) to `System.tmp_dir!()` BEFORE invoking the
    # sandbox; with default-deny those files must still be readable inside.
    # Skipped when TMPDIR is unset (`spec.host_tmpdir` is `nil`); emitted for
    # both spellings.
    host_tmpdir_rules =
      spec.host_tmpdir
      |> List.wrap()
      |> Enum.flat_map(&spellings(&1, spellings_fun))
      |> Enum.map_join("\n    ", fn dir ->
        ~s{(allow file-read* (subpath "#{dir}"))}
      end)

    # stat/ls/glob on arbitrary paths (e.g. PATH probing) under default-deny.
    file_read_metadata_rule = "(allow file-read-metadata)"

    # --- Filesystem WRITE rules ---

    # Build-cache dirs: package managers and toolchains (`mix deps.get`,
    # `npm install`, `cargo build`) must write their caches — these are core
    # agent workflows. User-configurable via `[sandbox] write_paths`, resolved
    # ONCE in the spec: nil (unset) → the built-in default cache-dir list; set
    # (even `[]`) → the user's list REPLACES the default cache-dir list (only
    # these cache-dir rules; every other profile group is untouched).
    # Structural paths (cwd, tmp, nix, repo .git, genesis dirs) are always
    # granted elsewhere in the profile — they are not part of the
    # user-configurable list. Read+write pair per spelling, like the other
    # structural groups.
    cache_rw_rules =
      spec.cache_write_paths
      |> Enum.flat_map(&spellings(&1, spellings_fun))
      |> Enum.map_join("\n    ", &rw_rule/1)

    # Sensitive dirs: deny WRITE too (defense in depth — reads are already
    # blocked by the deny-read rules above). The canonical list, in canonical
    # order, WITHOUT the macOS-only `Library/Keychains` entry, with the same
    # literal+subpath pairing (and resolved spelling) as the read group.
    sensitive_write_rules =
      spec.deny_write_paths
      |> Enum.flat_map(&spellings(&1, spellings_fun))
      |> Enum.map_join("\n    ", &credential_rule("file-write*", &1))

    # --- Assembly (order matters for readability; SBPL deny precedence is
    # what makes the deny-read list win over the root read allow) ---
    #
    # Network stays default-allow: agents legitimately run `git fetch/push`,
    # `mix deps.get`, `curl`, and web tools; default-deny network breaks core
    # workflows. The primary boundary is the tightened filesystem + process
    # limits. Future extension point: a `[sandbox] network_mode = "allow" |
    # "deny"` TOML key (belongs in config/schema/) could gate the
    # `(allow network*)` rule below.
    #
    # Real-macOS validation warranted: `sandbox-exec -p` acceptance of the
    # root-wide `(allow file-read* (subpath "/"))` rule and the full profile
    # — see report.
    network_rule =
      if spec.network == :allow, do: "(allow network*)", else: ""

    """
    (version 1)
    (deny default)

    #{read_root_rules}
    #{nix_rules}
    #{write_root_rules}
    #{git_rules}
    #{tmp_rules}
    #{task_tmpdir_rules}
    #{genesis_rw_rules}
    #{home_read_rule}
    #{sensitive_read_rules}
    #{system_sensitive_read_rules}
    #{ssh_literal_rules}
    #{host_tmpdir_rules}
    #{file_read_metadata_rule}
    #{cache_rw_rules}
    (allow file-write-data (literal "/dev/null"))
    (allow file-write-data (literal "/dev/dtracehelper"))
    #{sensitive_write_rules}
    #{@fcntl_deny_rule}
    (limit number #{spec.max_processes})
    (allow process-exec)
    (allow process-fork)
    #{network_rule}
    (allow mach-lookup)
    (allow sysctl-read)
    (allow process-info*)
    (allow signal)
    (allow ipc-posix-sem)
    (allow ipc-posix-shm)
    """
    |> String.replace(~r/\n{3,}/, "\n\n")
    |> String.trim()
  end

  # One read+write allowance pair for a structural path (every group grants
  # both: a sandboxed command reads back what it writes).
  defp rw_rule(path) do
    ~s{(allow file-read* (subpath "#{path}"))\n    (allow file-write* (subpath "#{path}"))}
  end

  # A credential carveout rule: BOTH path filters in ONE rule. SBPL
  # OR-combines a rule's filters, so `literal` + `subpath` covers the path
  # itself even when it does not exist yet (a bare `subpath` leaves the
  # first-time-creation gap, e.g. `mkdir ~/.ssh`).
  defp credential_rule(operation, path) do
    ~s{(deny #{operation} (literal "#{path}") (subpath "#{path}"))}
  end

  # `:alias_fun` (test seam, default-inert): the 1-arity path → spellings
  # function the renderer emits rules for. The production default is
  # `EvoGit.Sandbox.Spec.aliases/1`.
  defp alias_fun(opts) do
    case Keyword.get(opts, :alias_fun) do
      fun when is_function(fun, 1) -> fun
      _other -> &Spec.aliases/1
    end
  end

  # Every spelling `path` can be visible under, logical first. On Linux
  # nothing resolves, so the rule set generated there is unchanged; on macOS a
  # symlinked top-level component (`/tmp` → `/private/tmp`) adds the resolved
  # spelling Seatbelt actually matches.
  defp spellings(path, alias_fun) when is_binary(path) do
    case alias_fun.(path) |> List.wrap() |> Enum.filter(&is_binary/1) |> Enum.uniq() do
      [] -> [path]
      paths -> paths
    end
  end

  defp spellings(_path, _alias_fun), do: []

  # Removes the UNVERIFIED rules — `(limit ...)` and the `system-fcntl` deny —
  # from a generated SBPL profile, preserving the rest verbatim. Used by the
  # fail-safe retry: if `sandbox-exec` on some macOS rejects either rule, the
  # whole profile would fail to parse and EVERY sandboxed command would break
  # — stripping just those lines keeps all other hardening intact (the
  # process-count limit and the fcntl deny are the only things lost).
  defp strip_unverified_rules(profile) do
    profile
    |> String.split("\n")
    |> Enum.reject(&unverified_rule?/1)
    |> Enum.join("\n")
  end

  defp unverified_rule?(line) do
    trimmed = String.trim_leading(line)
    Enum.any?(@unverified_rule_prefixes, &String.starts_with?(trimmed, &1))
  end

  defp process_limit_rejected?,
    do: :persistent_term.get(@process_limit_rejected_key, false)

  # sandbox-exec -p <profile> -- <exec> <args> (shared by the run/4 and
  # run_with_partial/6 enabled paths).
  defp sandbox_exec(profile, exec, exec_args, cwd, tmpdir, git_env) do
    System.cmd("sandbox-exec", ["-p", profile, "--", exec | exec_args],
      cd: cwd,
      stderr_to_stdout: true,
      env: [{"TMPDIR", tmpdir} | git_env]
    )
  end

  # Fail-safe retry for the UNVERIFIED rules. On macOS where `(limit ...)` and
  # the `system-fcntl` deny ARE valid, the first attempt succeeds and this
  # helper is never reached — zero overhead on healthy systems. On macOS where
  # either is rejected, the FIRST sandboxed command pays one extra spawn: the
  # failed attempt is retried once with both rules stripped; on retry success
  # the decision is cached in `:persistent_term` (warned about once), so
  # subsequent calls skip straight to the stripped profile. If the retry
  # ALSO fails, the command genuinely failed — the retry result is the more
  # accurate one.
  defp maybe_retry_without_process_limit(
         {_output, 0} = result,
         _profile,
         _exec,
         _exec_args,
         _cwd,
         _tmpdir,
         _git_env
       ) do
    result
  end

  defp maybe_retry_without_process_limit(result, profile, exec, exec_args, cwd, tmpdir, git_env) do
    if process_limit_rejected?() do
      # Another caller already discovered the rejection (and the profile we
      # ran was already stripped) — return this attempt's result as-is.
      result
    else
      case sandbox_exec(strip_unverified_rules(profile), exec, exec_args, cwd, tmpdir, git_env) do
        {retry_output, 0} ->
          :persistent_term.put(@process_limit_rejected_key, true)

          Logger.warning(
            "sandbox-exec rejected this profile's unverified rules " <>
              "((limit ...) and (deny system-fcntl ...)); running with the " <>
              "process-count limit and the fcntl deny disabled"
          )

          {retry_output, 0}

        retry_result ->
          retry_result
      end
    end
  end

  @doc """
  Runs a command with timeout, recovering partial output on timeout via temp-file redirection.

  Unlike `run/4` which uses blocking `System.cmd/3` and loses all output on timeout,
  this function redirects stdout/stderr to a temp file. If the timeout fires, the
  partial output written so far can still be read from the temp file.

  `opts` is the observability option list: `:execution_id` addresses the tracked
  record and `:record_exit_status` (default true) suppresses the terminal-fact
  recording for a command that will be re-run (the unverified-rule retry uses
  internally). Both paths spawn the child through a directly owned port (the
  enabled one via `sandbox-exec`) and attach a `:posix` handle carrying its real
  OS pid, so foreground executions are observable and controllable (macOS has
  no systemd, so there is no unit to address instead).

  Returns:
    * `{:ok, output, exit_code}` — command completed within timeout
    * `{:timeout, partial_output}` — command timed out; partial_output may be empty
  """
  @spec run_with_partial(
          String.t(),
          String.t(),
          [String.t()],
          String.t() | nil,
          pos_integer(),
          integer() | nil,
          keyword()
        ) ::
          {:ok, String.t(), non_neg_integer()} | {:timeout, String.t()}
  def run_with_partial(
        cwd,
        executable,
        args \\ [],
        repo_root \\ nil,
        timeout,
        max_bytes \\ nil,
        opts \\ []
      )
      when is_list(args) and is_integer(timeout) and timeout > 0 do
    tmpfile = Helpers.partial_output_tmpfile()

    wrapped_cmd = Helpers.build_redirected_command(executable, args, tmpfile)

    # Detect git on the ORIGINAL executable (before we wrap it in bash)
    is_git = EvoGit.GitEnv.git_command?(executable)

    if enabled?() do
      resolved_tmpdir = EvoGit.Sandbox.resolve_tmpdir()
      profile = generate_profile(cwd, repo_root)

      # The cached decision (if any) is resolved BEFORE the first attempt so a
      # known-rejecting macOS skips the guaranteed-failing one; the retry keeps
      # within the SAME overall timeout budget.
      profile = if process_limit_rejected?(), do: strip_unverified_rules(profile), else: profile

      {exec, exec_args} =
        if Nix.active?() do
          Nix.wrap_command("bash", ["-c", wrapped_cmd])
        else
          {"bash", ["-c", wrapped_cmd]}
        end

      git_env = if is_git, do: EvoGit.GitEnv.git_env_list(cwd), else: []
      env = [{"TMPDIR", resolved_tmpdir} | git_env]
      deadline = System.monotonic_time(:millisecond) + timeout

      result =
        case run_sandbox_exec(profile, exec, exec_args, cwd, env, opts, timeout) do
          {:ok, 0} = _success ->
            {:ok, Helpers.read_tempfile(tmpfile, max_bytes), 0}

          {:ok, _non_zero_exit_code} = result ->
            retry_without_process_limit(
              result,
              profile,
              exec,
              exec_args,
              cwd,
              env,
              opts,
              deadline,
              tmpfile,
              max_bytes
            )

          {:timeout, :killed} ->
            partial = Helpers.read_tempfile(tmpfile, max_bytes)
            {:timeout, partial <> "\n[TRUNCATED due to timeout]"}
        end

      record_result(opts, result)
    else
      # Non-sandbox path: no nix wrapping (consistent with run/4 disabled path).
      # The managed per-task tmpdir (when installed) rides along via
      # `Helpers.temp_env_vars/0`.
      git_env =
        if(is_git, do: EvoGit.GitEnv.git_env_list(cwd), else: []) ++ Helpers.temp_env_vars()

      Helpers.run_task_with_partial(
        "bash",
        ["-c", wrapped_cmd],
        cwd,
        git_env,
        timeout,
        tmpfile,
        max_bytes,
        opts,
        __MODULE__
      )
    end
  end

  # One `sandbox-exec -p <profile> -- <exec> <args>` attempt through the shared
  # port-based runner: real OS pid, tracked attach, tree kill on timeout.
  # `record_exit_status: false` because the unverified-rule RETRY re-runs the
  # command — only the attempt reported by `run_with_partial/7` is recorded.
  defp run_sandbox_exec(profile, exec, exec_args, cwd, env, opts, timeout) do
    Helpers.run_tracked_command(
      "sandbox-exec",
      ["-p", profile, "--", exec | exec_args],
      cwd,
      env,
      timeout,
      Keyword.put(opts, :record_exit_status, false),
      __MODULE__
    )
  end

  # Records the FINAL attempt's terminal fact on the tracked execution (the
  # unverified-rule retry means earlier attempts are not the execution's
  # outcome). Best-effort via the shared helpers; returns `result` untouched.
  defp record_result(opts, result) do
    case result do
      {:ok, _output, exit_code} -> Helpers.record_exit(opts, exit_code)
      {:timeout, _partial} -> Helpers.record_timeout(opts)
      _other -> :ok
    end

    result
  end

  # Fail-safe unverified-rule retry for the `run_with_partial` path: the first
  # attempt already failed non-zero, so — unless another caller has ALREADY
  # discovered the rejection — retry once with both UNVERIFIED rules stripped,
  # inside whatever is LEFT of the original timeout budget. On success the
  # decision is cached in `:persistent_term` (warned about once).
  defp retry_without_process_limit(
         result,
         profile,
         exec,
         exec_args,
         cwd,
         env,
         opts,
         deadline,
         tmpfile,
         max_bytes
       ) do
    if process_limit_rejected?() do
      # Another caller already discovered the rejection (and the profile we
      # ran was already stripped) — report this attempt's result as-is.
      finalize_exit(result, tmpfile, max_bytes)
    else
      remaining = max(deadline - System.monotonic_time(:millisecond), 1)

      case run_sandbox_exec(
             strip_unverified_rules(profile),
             exec,
             exec_args,
             cwd,
             env,
             opts,
             remaining
           ) do
        {:ok, 0} ->
          :persistent_term.put(@process_limit_rejected_key, true)

          Logger.warning(
            "sandbox-exec rejected this profile's unverified rules " <>
              "((limit ...) and (deny system-fcntl ...)); running with the " <>
              "process-count limit and the fcntl deny disabled"
          )

          {:ok, Helpers.read_tempfile(tmpfile, max_bytes), 0}

        other ->
          finalize_exit(other, tmpfile, max_bytes)
      end
    end
  end

  # Converts a port-runner result into `run_with_partial`'s contract.
  defp finalize_exit({:ok, exit_code}, tmpfile, max_bytes) do
    {:ok, Helpers.read_tempfile(tmpfile, max_bytes), exit_code}
  end

  defp finalize_exit({:timeout, :killed}, tmpfile, max_bytes) do
    partial = Helpers.read_tempfile(tmpfile, max_bytes)
    {:timeout, partial <> "\n[TRUNCATED due to timeout]"}
  end
end
