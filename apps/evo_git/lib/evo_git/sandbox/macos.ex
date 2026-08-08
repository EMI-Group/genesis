defmodule EvoGit.Sandbox.MacOS do
  @moduledoc """
  macOS sandbox backend using `sandbox-exec`.

  Deny-by-default filesystem policy with an explicit allow list (SBPL):
  system paths, the repo worktree (cwd + `.git`), tmp paths, the genesis
  config/data dirs, and build caches are readable; the home directory is
  readable EXCEPT for a deny-read list of sensitive dirs (`~/.ssh`,
  `~/.gnupg`, `~/.aws`, `~/.kube`, `~/.config/sops`, `~/.git-credentials`,
  `~/.netrc`, `~/.password-store`, `~/Library/Keychains`). The host
  `$TMPDIR` is readable so temp files written before sandbox invocation
  (e.g. skill scripts) stay usable. Writes are restricted to the worktree,
  tmp paths, genesis dirs, and package-manager/toolchain cache dirs, with
  deny-write rules for sensitive dirs as defense in depth.

  Also enforces a process-count limit (`(limit number N)`, see
  `@max_processes`) and keeps network default-allowed (agents run
  `git fetch/push`, `mix deps.get`, `curl`, and web tools).
  """

  @behaviour EvoGit.Sandbox.Behaviour

  alias EvoGit.{Nix, Platform, Sandbox.Helpers}

  # Maximum number of concurrently live processes/threads the sandboxed
  # process may spawn, enforced via SBPL `(limit number N)`. Tunable —
  # chosen to fit `mix test`-style parallel workloads (worker processes,
  # compiler ports) while still capping a runaway agent's fork bombs.
  @max_processes 200

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
      System.cmd("sandbox-exec", ["-p", profile, "--", "bash", "-c", wrapped_cmd],
        cd: cwd,
        stderr_to_stdout: true,
        env: [{"TMPDIR", resolved_tmpdir} | git_env]
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
      "Library/Keychains"
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
    # agent workflows.
    build_cache_dirs = [
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

    cache_rw_rules =
      Enum.map_join(build_cache_dirs, "\n    ", fn dir ->
        path = Path.join(home, dir)
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

      {exec, exec_args} =
        if Nix.active?() do
          Nix.wrap_command("bash", ["-c", wrapped_cmd])
        else
          {"bash", ["-c", wrapped_cmd]}
        end

      git_env = if is_git, do: EvoGit.GitEnv.git_env_list(cwd), else: []

      task =
        Task.async(fn ->
          System.cmd("sandbox-exec", ["-p", profile, "--", exec | exec_args],
            cd: cwd,
            stderr_to_stdout: true,
            env: [{"TMPDIR", resolved_tmpdir} | git_env]
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
