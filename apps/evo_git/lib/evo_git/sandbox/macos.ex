defmodule EvoGit.Sandbox.MacOS do
  @moduledoc """
  macOS sandbox backend using `sandbox-exec`.

  Deny-by-default filesystem policy with an explicit allow list (SBPL):
  system paths, the repo worktree (cwd + `.git`), tmp paths, the genesis
  config/data dirs, and build caches are readable; the home directory is
  readable EXCEPT for a deny-read list of sensitive dirs (`~/.ssh`,
  `~/.gnupg`, `~/.aws`, `~/.kube`, `~/.config/sops`, `~/.git-credentials`,
  `~/.netrc`, `~/.password-store`, `~/Library/Keychains`, `~/.npmrc`,
  `~/.pypirc`, `~/.docker`, `~/.gem` — credential stores). The host
  `$TMPDIR` is readable so temp files written before sandbox invocation
  (e.g. skill scripts) stay usable. Writes are restricted to the worktree,
  tmp paths, genesis dirs, and package-manager/toolchain cache dirs, with
  deny-write rules for sensitive dirs as defense in depth.

  Also enforces a process-count limit (`(limit number N)`, see
  `@max_processes`) and keeps network default-allowed (agents run
  `git fetch/push`, `mix deps.get`, `curl`, and web tools). If the host's
  `sandbox-exec` rejects the `(limit ...)` syntax (unverifiable without a
  macOS host), `run/4`/`run_with_partial/6` transparently retry once with
  the limit stripped and cache the decision — the sandbox keeps working
  with all other hardening intact.
  """

  @behaviour EvoGit.Sandbox.Behaviour

  require Logger

  alias EvoGit.{Nix, Platform, Sandbox.Helpers}

  # Maximum number of concurrently live processes/threads the sandboxed
  # process may spawn, enforced via SBPL `(limit number N)`. Tunable —
  # chosen to fit `mix test`-style parallel workloads (worker processes,
  # compiler ports) while still capping a runaway agent's fork bombs.
  @max_processes 200

  # Cached decision that `sandbox-exec` on THIS macOS rejects the
  # `(limit ...)` rule (see `strip_process_limit/1` and the retry logic in
  # `run/4` / `run_with_partial/6`). Once set to `true`, every subsequent
  # call uses the stripped profile directly, skipping the guaranteed-failing
  # first attempt.
  @process_limit_rejected_key {EvoGit.Sandbox.MacOS, :process_limit_rejected}

  # Built-in writable cache dirs (home-relative) for package managers and
  # toolchains (`mix deps.get`, `npm install`, `cargo build`). This is the
  # DEFAULT list emitted as `(allow file-write* (subpath "<home>/<dir>"))`
  # (rule group 12) when the user has NOT set `[sandbox] write_paths`. When
  # set, the user's list REPLACES this one wholesale (even an empty list) —
  # see `resolve_write_paths/2`.
  @default_cache_dirs [
    ".cache",
    ".local/share",
    ".local/state",
    ".cargo",
    ".rustup",
    ".mix",
    ".hex",
    ".npm",
    ".yarn",
    ".bun",
    ".m2",
    ".gradle",
    "go"
  ]

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
      profile = generate_profile(cwd, repo_root)

      # Once this macOS has been observed rejecting the `(limit ...)` rule,
      # use the stripped profile directly — no guaranteed-failing first
      # attempt on every call.
      profile = if process_limit_rejected?(), do: strip_process_limit(profile), else: profile

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
      inner_cmd = Enum.map_join([exec | exec_args], " ", &Helpers.shell_escape/1)
      wrapped_cmd = inner_cmd <> " < /dev/null"

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
      # Disabled path: wrap in bash with stdin redirect from /dev/null.
      git_env =
        if EvoGit.GitEnv.git_command?(executable),
          do: EvoGit.GitEnv.git_env_list(cwd),
          else: []

      inner_cmd = Enum.map_join([executable | args], " ", &Helpers.shell_escape/1)
      wrapped_cmd = inner_cmd <> " < /dev/null"

      System.cmd("bash", ["-c", wrapped_cmd],
        cd: cwd,
        stderr_to_stdout: true,
        env: git_env
      )
    end
  end

  # Generate an SBPL (Sandbox Policy Language) profile.
  #
  # Policy: DENY-BY-DEFAULT reads — the global `(allow file-read*)` is gone.
  # Reads are granted only for: system paths, nix (when enabled), the repo
  # worktree (cwd + repo_root/.git), tmp paths, the genesis config/data dirs,
  # the host $TMPDIR (pre-sandbox temp files), and the home directory minus a
  # deny-read list of sensitive dirs. In Apple's SBPL, deny rules take
  # precedence over allow rules — so the deny-read list wins over the home
  # read allow below. Writes are restricted to the worktree, tmp paths,
  # genesis dirs, and package-manager/toolchain cache dirs, with deny-write
  # rules for sensitive dirs as defense in depth.
  #
  # NOTE: all comments are kept in Elixir source (not emitted into the
  # profile string) because `#` comment support in sandbox-exec could not be
  # validated here; the emitted profile is pure SBPL rules.
  @doc false
  def generate_profile(cwd, repo_root \\ nil) when is_binary(cwd) do
    home = System.user_home!()

    # --- Filesystem READ rules (deny-by-default, explicit allows only) ---

    # System paths: binaries, dyld, system libraries/frameworks, fonts,
    # certificates, device nodes (/dev/urandom, /dev/null, ...). bash and
    # every toolchain binary read from these at startup (see the note on
    # real-macOS validation in the report).
    system_read_paths = [
      "/System",
      "/usr",
      "/bin",
      "/sbin",
      "/Library",
      "/etc",
      "/private/etc",
      "/private/var",
      "/dev"
    ]

    system_read_rules =
      Enum.map_join(system_read_paths, "\n    ", fn path ->
        ~s{(allow file-read* (subpath "#{path}"))}
      end)

    # Nix store/var: read (toolchain binaries) + write (build outputs) —
    # only when nix is enabled.
    nix_rules =
      if Nix.enabled?() do
        nix_paths = ["/nix/store", "/nix/var"]

        nix_paths
        |> Enum.flat_map(fn path ->
          [
            ~s{(allow file-read* (subpath "#{path}"))},
            ~s{(allow file-write* (subpath "#{path}"))}
          ]
        end)
        |> Enum.join("\n    ")
      else
        ""
      end

    # Repo access: the worktree (cwd) plus the git metadata dir. cwd is
    # emitted here with the read allow; the write allow follows below.
    git_rules =
      if repo_root do
        git_path = Path.join(repo_root, ".git")

        ~s{(allow file-read* (subpath "#{git_path}"))\n    (allow file-write* (subpath "#{git_path}"))}
      else
        ""
      end

    # Tmp paths: read-write — processes create temp files and read them back.
    tmp_paths = Platform.tmp_paths()

    tmp_rules =
      Enum.map_join(tmp_paths, "\n    ", fn path ->
        ~s{(allow file-read* (subpath "#{path}"))\n    (allow file-write* (subpath "#{path}"))}
      end)

    # Genesis config/data dirs (e.g. `~/Library/Application Support/genesis`
    # on macOS — NOT under /tmp or the repo): the runtime reads and writes
    # config, credentials, state, and logs there.
    genesis_rw_rules =
      [Platform.config_dir(), Platform.data_dir()]
      |> Enum.map_join("\n    ", fn path ->
        ~s{(allow file-read* (subpath "#{path}"))\n    (allow file-write* (subpath "#{path}"))}
      end)

    # Home reads: allow the whole home, then deny-read the sensitive dirs.
    # Deny rules take precedence over allow rules in SBPL, so the deny-read
    # list below wins over this allow.
    home_read_rule = ~s{(allow file-read* (subpath "#{home}"))}

    sensitive_read_dirs = [
      ".ssh",
      ".gnupg",
      ".aws",
      ".kube",
      ".config/sops",
      ".git-credentials",
      ".netrc",
      ".password-store",
      "Library/Keychains",
      # Additional credential stores (parity with the Linux backend's
      # InaccessiblePaths, which already includes .npmrc).
      ".npmrc",
      ".pypirc",
      ".docker",
      ".gem"
    ]

    sensitive_read_rules =
      Enum.map_join(sensitive_read_dirs, "\n    ", fn dir ->
        path = Path.join(home, dir)
        ~s{(deny file-read* (subpath "#{path}"))}
      end)

    # SSH host verification: `git fetch/push` over SSH must read known_hosts
    # and ssh config to verify the server. Private keys stay unreadable by
    # design — key-based auth over SSH requires ssh-agent (`SSH_AUTH_SOCK`),
    # which never exposes key material to the sandboxed process.
    ssh_literal_rules =
      Enum.map_join(
        [Path.join(home, ".ssh/known_hosts"), Path.join(home, ".ssh/config")],
        "\n    ",
        fn path -> ~s{(allow file-read-data (literal "#{path}"))} end
      )

    # Host $TMPDIR read: on macOS the per-user tmp dir is `/var/folders/...`,
    # NOT under /tmp. The skills executor and other callers write temp files
    # (e.g. skill scripts) to `System.tmp_dir!()` BEFORE invoking the
    # sandbox; with default-deny those files must still be readable inside.
    # Skipped when TMPDIR is unset.
    host_tmpdir_rule =
      case System.get_env("TMPDIR") do
        nil -> ""
        "" -> ""
        dir -> ~s{(allow file-read* (subpath "#{dir}"))}
      end

    # stat/ls/glob on arbitrary paths (e.g. PATH probing) under default-deny.
    file_read_metadata_rule = "(allow file-read-metadata)"

    # --- Filesystem WRITE rules ---

    # Build-cache dirs: package managers and toolchains (`mix deps.get`,
    # `npm install`, `cargo build`) must write their caches — these are core
    # agent workflows. User-configurable via `[sandbox] write_paths`: nil
    # (unset) → the built-in default cache-dir list; set (even `[]`) → the
    # user's list REPLACES the default cache-dir list (only these cache-dir
    # write rules; every other profile group is untouched). Structural paths
    # (cwd, tmp, nix, repo .git, genesis dirs) are always granted elsewhere in
    # the profile — they are not part of the user-configurable list.
    write_paths = resolve_write_paths(EvoGit.Config.resolve([:sandbox, :write_paths]), home)

    cache_rw_rules =
      Enum.map_join(write_paths, "\n    ", fn path ->
        ~s{(allow file-write* (subpath "#{path}"))}
      end)

    # Sensitive dirs: deny WRITE too (defense in depth — reads are already
    # blocked by the deny-read rules above).
    sensitive_write_dirs = [
      ".ssh",
      ".gnupg",
      ".aws",
      ".kube",
      ".config/sops",
      ".npmrc",
      ".git-credentials",
      ".netrc"
    ]

    sensitive_write_rules =
      Enum.map_join(sensitive_write_dirs, "\n    ", fn dir ->
        path = Path.join(home, dir)
        ~s{(deny file-write* (subpath "#{path}"))}
      end)

    # --- Assembly (order matters for readability; SBPL deny precedence is
    # what makes the deny-read list win over the home allow) ---
    #
    # Network stays default-allow: agents legitimately run `git fetch/push`,
    # `mix deps.get`, `curl`, and web tools; default-deny network breaks core
    # workflows. The primary boundary is the tightened filesystem + process
    # limits. Future extension point: a `[sandbox] network_mode = "allow" |
    # "deny"` TOML key (belongs in config/schema/) could gate the
    # `(allow network*)` rule below.
    #
    # Real-macOS validation warranted: bash/dyld startup reads (all covered
    # by the system paths above) and `sandbox-exec -p` acceptance of the
    # full profile — see report.
    """
    (version 1)
    (deny default)

    #{system_read_rules}
    #{nix_rules}
    (allow file-read* (subpath "#{cwd}"))
    (allow file-write* (subpath "#{cwd}"))
    #{git_rules}
    #{tmp_rules}
    #{genesis_rw_rules}
    #{home_read_rule}
    #{sensitive_read_rules}
    #{ssh_literal_rules}
    #{host_tmpdir_rule}
    #{file_read_metadata_rule}
    #{cache_rw_rules}
    (allow file-write-data (literal "/dev/null"))
    (allow file-write-data (literal "/dev/dtracehelper"))
    #{sensitive_write_rules}
    (limit number #{@max_processes})
    (allow process-exec)
    (allow process-fork)
    (allow network*)
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

  # Resolves the writable-path (cache-dir) list to absolute paths.
  #
  #   * `nil` (config unset) → the built-in `@default_cache_dirs` list joined
  #     to `home` — byte-identical to the historical hard-coded output.
  #   * set (even `[]`) → the user's list REPLACES the default cache-dir list;
  #     `[]` means no cache-dir write rules at all.
  #
  # Path convention for user entries:
  #   * `~`-prefixed entries expand to `System.user_home!()` (e.g. `~/cache`
  #     → `<home>/cache`, bare `~` → `<home>`)
  #   * absolute entries (leading `/`) are used as-is
  #   * relative entries are joined to `home` — the same base the built-in
  #     defaults use
  #
  # `Path.expand` is deliberately NOT used: on entries containing `$HOME` env
  # substitution (e.g. `$HOME/.cache`) it would treat the literal `$HOME` text
  # as a directory name. Env substitutions are NOT expanded — such entries are
  # handled like any relative path.
  defp resolve_write_paths(nil, home), do: Enum.map(@default_cache_dirs, &Path.join(home, &1))

  defp resolve_write_paths(paths, home) do
    Enum.map(paths, fn
      "~" <> rest -> Path.join(home, String.trim_leading(rest, "/"))
      "/" <> _ = path -> path
      path -> Path.join(home, path)
    end)
  end

  # Removes the `(limit ...)` line from a generated SBPL profile, preserving
  # the rest verbatim. Used by the fail-safe retry: if `sandbox-exec` on
  # some macOS rejects the `(limit number N)` syntax, the whole profile
  # would fail to parse and EVERY sandboxed command would break — stripping
  # just that line keeps all other hardening intact (the process-count limit
  # is the only thing lost).
  defp strip_process_limit(profile) do
    profile
    |> String.split("\n")
    |> Enum.reject(&String.starts_with?(String.trim_leading(&1), "(limit "))
    |> Enum.join("\n")
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

  # Fail-safe process-limit retry. On macOS where `(limit ...)` IS valid,
  # the first attempt succeeds and this helper is never reached — zero
  # overhead on healthy systems. On macOS where it is rejected, the FIRST
  # sandboxed command pays one extra spawn: the failed attempt is retried
  # once with the process-count limit stripped; on retry success the
  # decision is cached in `:persistent_term` (warned about once), so
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
      case sandbox_exec(strip_process_limit(profile), exec, exec_args, cwd, tmpdir, git_env) do
        {retry_output, 0} ->
          :persistent_term.put(@process_limit_rejected_key, true)

          Logger.warning(
            "sandbox-exec rejected the (limit ...) rule on this macOS; " <>
              "running with the process-count limit disabled"
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
          integer() | nil
        ) ::
          {:ok, String.t(), non_neg_integer()} | {:timeout, String.t()}
  def run_with_partial(cwd, executable, args \\ [], repo_root \\ nil, timeout, max_bytes \\ nil)
      when is_list(args) and is_integer(timeout) and timeout > 0 do
    tmpdir = Path.join(EvoGit.Sandbox.resolve_tmpdir(), "genesis_partial_outputs")
    File.mkdir_p!(tmpdir)

    tmpfile =
      Path.join(tmpdir, "#{System.monotonic_time()}_#{System.unique_integer([:positive])}")

    inner_cmd = Enum.map_join([executable | args], " ", &Helpers.shell_escape/1)
    wrapped_cmd = inner_cmd <> " > " <> Helpers.shell_escape(tmpfile) <> " 2>&1 < /dev/null"

    # Detect git on the ORIGINAL executable (before we wrap it in bash)
    is_git = EvoGit.GitEnv.git_command?(executable)

    if enabled?() do
      resolved_tmpdir = EvoGit.Sandbox.resolve_tmpdir()
      profile = generate_profile(cwd, repo_root)

      # The cached decision (if any) is resolved BEFORE spawning the Task so
      # a known-rejecting macOS skips the guaranteed-failing first attempt.
      # The attempt-then-retry dance only happens when no decision is cached
      # yet — and it runs inside the Task so it stays within the timeout.
      profile = if process_limit_rejected?(), do: strip_process_limit(profile), else: profile

      {exec, exec_args} =
        if Nix.active?() do
          Nix.wrap_command("bash", ["-c", wrapped_cmd])
        else
          {"bash", ["-c", wrapped_cmd]}
        end

      git_env = if is_git, do: EvoGit.GitEnv.git_env_list(cwd), else: []

      task =
        Task.async(fn ->
          result = sandbox_exec(profile, exec, exec_args, cwd, resolved_tmpdir, git_env)

          maybe_retry_without_process_limit(
            result,
            profile,
            exec,
            exec_args,
            cwd,
            resolved_tmpdir,
            git_env
          )
        end)

      case Task.yield(task, timeout) || Task.shutdown(task) do
        {:ok, {_output, exit_code}} ->
          content = Helpers.read_tempfile(tmpfile, max_bytes)
          {:ok, content, exit_code}

        nil ->
          partial = Helpers.read_tempfile(tmpfile, max_bytes)
          {:timeout, partial <> "\n[TRUNCATED due to timeout]"}
      end
    else
      # Non-sandbox path: no nix wrapping (consistent with run/4 disabled path)
      git_env = if is_git, do: EvoGit.GitEnv.git_env_list(cwd), else: []

      task =
        Task.async(fn ->
          System.cmd("bash", ["-c", wrapped_cmd],
            cd: cwd,
            stderr_to_stdout: true,
            env: git_env
          )
        end)

      case Task.yield(task, timeout) || Task.shutdown(task) do
        {:ok, {_output, exit_code}} ->
          content = Helpers.read_tempfile(tmpfile, max_bytes)
          {:ok, content, exit_code}

        nil ->
          partial = Helpers.read_tempfile(tmpfile, max_bytes)
          {:timeout, partial <> "\n[TRUNCATED due to timeout]"}
      end
    end
  end
end
