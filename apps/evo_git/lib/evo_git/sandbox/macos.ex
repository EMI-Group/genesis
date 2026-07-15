defmodule EvoGit.Sandbox.MacOS do
  @moduledoc """
  macOS sandbox backend using `sandbox-exec`.

  Provides filesystem isolation only — no resource limits or syscall filtering.
  Uses Apple's Sandbox Policy Language (SBPL) to restrict filesystem access,
  allowing read-write on project directories and build caches while blocking
  sensitive directories like ~/.ssh, ~/.gnupg, etc.
  """

  @behaviour EvoGit.Sandbox.Behaviour

  alias EvoGit.{Nix, Platform, Sandbox.Helpers}

  @doc "Returns true when sandbox mode allows sandbox-exec on macOS."
  @spec enabled?() :: boolean()
  def enabled? do
    case EvoGit.Defaults.sandbox() do
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
          do: EvoGit.GitEnv.git_env_list(),
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
          do: EvoGit.GitEnv.git_env_list(),
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
  # Strategy: deny default, then allow specific paths.
  # - Allow read-write on: cwd, tmp dirs, build caches, repo_root/.git
  # - Deny write on: sensitive dirs (.ssh, .gnupg, .aws, etc.)
  # - Allow read on: everything (so tools can read system headers, libraries, etc.)
  # - Allow process execution (subprocess exec)
  @doc false
  def generate_profile(cwd, repo_root \\ nil) when is_binary(cwd) do
    home = System.user_home!()

    # Sensitive directories to explicitly deny write access
    sensitive_dirs = [
      ".ssh",
      ".gnupg",
      ".aws",
      ".kube",
      ".config/sops",
      ".npmrc",
      ".git-credentials",
      ".netrc"
    ]

    sensitive_rules =
      Enum.map(sensitive_dirs, fn dir ->
        path = Path.join(home, dir)
        ~s{(deny file-write* (subpath "#{path}"))}
      end)
      |> Enum.join("\n    ")

    # Build cache dirs to allow read-write
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
      Enum.map(build_cache_dirs, fn dir ->
        path = Path.join(home, dir)
        ~s{(allow file-write* (subpath "#{path}"))}
      end)
      |> Enum.join("\n    ")

    nix_rw_rules =
      if Nix.enabled?() do
        nix_paths = ["/nix/store", "/nix/var"]

        nix_paths
        |> Enum.map(fn path ->
          ~s{(allow file-write* (subpath "#{path}"))}
        end)
        |> Enum.join("\n    ")
      else
        ""
      end

    # Tmp paths
    tmp_paths = Platform.tmp_paths()

    tmp_rules =
      tmp_paths
      |> Enum.map(fn path ->
        ~s{(allow file-write* (subpath "#{path}"))}
      end)
      |> Enum.join("\n    ")

    # Repo .git access
    git_rule =
      if repo_root do
        git_path = Path.join(repo_root, ".git")
        ~s{(allow file-write* (subpath "#{git_path}"))}
      else
        ""
      end

    """
    (version 1)
    (deny default)
    (allow file-read*)
    (allow file-write* (subpath "#{cwd}"))
    #{tmp_rules}
    #{cache_rw_rules}
    #{nix_rw_rules}
    #{git_rule}
    (allow process-exec)
    (allow process-fork)
    (allow network*)
    (allow mach-lookup)
    (allow signal)
    (allow ipc-posix-sem)
    (allow ipc-posix-shm)
    (allow file-write-data (literal "/dev/null"))
    (allow file-write-data (literal "/dev/dtracehelper"))
    #{sensitive_rules}
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

      git_env = if is_git, do: EvoGit.GitEnv.git_env_list(), else: []

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
      git_env = if is_git, do: EvoGit.GitEnv.git_env_list(), else: []

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
