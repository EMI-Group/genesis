defmodule EvoGit.Sandbox.MacOS do
  @moduledoc """
  macOS sandbox backend using `sandbox-exec`.

  Provides filesystem isolation only — no resource limits or syscall filtering.
  Uses Apple's Sandbox Policy Language (SBPL) to restrict filesystem access,
  allowing read-write on project directories and build caches while blocking
  sensitive directories like ~/.ssh, ~/.gnupg, etc.
  """

  alias EvoGit.{Nix, Platform}

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
      # uses the ORIGINAL executable param (before nix wrapping) since the
      # nix-wrapped exec is `{"bash", ["-c", ...]}`.
      git_env =
        if EvoGit.GitEnv.git_command?(executable),
          do: EvoGit.GitEnv.git_env_list(),
          else: []

      # sandbox-exec -p <profile> -- <executable> <args...>
      System.cmd("sandbox-exec", ["-p", profile, "--", exec | exec_args],
        cd: cwd,
        stderr_to_stdout: true,
        env: [{"TMPDIR", resolved_tmpdir} | git_env]
      )
    else
      if EvoGit.GitEnv.git_command?(executable) do
        System.cmd(executable, args,
          cd: cwd,
          stderr_to_stdout: true,
          env: EvoGit.GitEnv.git_env_list()
        )
      else
        System.cmd(executable, args, cd: cwd, stderr_to_stdout: true)
      end
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
  @spec run_with_partial(String.t(), String.t(), [String.t()], String.t() | nil, pos_integer(), integer() | nil) ::
          {:ok, String.t(), non_neg_integer()} | {:timeout, String.t()}
  def run_with_partial(cwd, executable, args \\ [], repo_root \\ nil, timeout, max_bytes \\ nil)
      when is_list(args) and is_integer(timeout) and timeout > 0 do
    tmpdir = Path.join(EvoGit.Sandbox.resolve_tmpdir(), "genesis_partial_outputs")
    File.mkdir_p!(tmpdir)
    tmpfile = Path.join(tmpdir, "#{System.monotonic_time()}_#{System.unique_integer([:positive])}")

    inner_cmd = Enum.map_join([executable | args], " ", &shell_escape/1)
    wrapped_cmd = inner_cmd <> " > " <> shell_escape(tmpfile) <> " 2>&1"

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

      task = Task.async(fn ->
        System.cmd("sandbox-exec", ["-p", profile, "--", exec | exec_args],
          cd: cwd,
          stderr_to_stdout: true,
          env: [{"TMPDIR", resolved_tmpdir} | git_env]
        )
      end)

      case Task.yield(task, timeout) || Task.shutdown(task) do
        {:ok, {_output, exit_code}} ->
          content = read_tempfile(tmpfile, max_bytes)
          {:ok, content, exit_code}

        nil ->
          partial = read_tempfile(tmpfile, max_bytes)
          {:timeout, partial <> "\n[TRUNCATED due to timeout]"}
      end
    else
      # Non-sandbox path: no nix wrapping (consistent with run/4 disabled path)
      git_env = if is_git, do: EvoGit.GitEnv.git_env_list(), else: []

      task = Task.async(fn ->
        System.cmd("bash", ["-c", wrapped_cmd],
          cd: cwd,
          stderr_to_stdout: true,
          env: git_env
        )
      end)

      case Task.yield(task, timeout) || Task.shutdown(task) do
        {:ok, {_output, exit_code}} ->
          content = read_tempfile(tmpfile, max_bytes)
          {:ok, content, exit_code}

        nil ->
          partial = read_tempfile(tmpfile, max_bytes)
          {:timeout, partial <> "\n[TRUNCATED due to timeout]"}
      end
    end
  end

  # POSIX-safe shell escaping
  defp shell_escape(arg) do
    "'" <> String.replace(arg, "'", "'\\''") <> "'"
  end

  # Reads content from the temp file and deletes it. Returns empty string
  # if the file does not exist or cannot be read.
  #
  # When `max_bytes` is nil, reads the entire file (current behavior).
  # When `max_bytes` is set and the file exceeds it, reads only the first
  # and last portions (never loading the entire file into memory).
  defp read_tempfile(path, max_bytes) do
    content =
      case File.stat(path) do
        {:ok, %{size: size}} ->
          if is_nil(max_bytes) or size <= max_bytes do
            case File.read(path) do
              {:ok, data} -> data
              {:error, _} -> ""
            end
          else
            read_truncated(path, size, max_bytes)
          end

        {:error, _} ->
          ""
      end

    _ = File.rm(path)
    content
  end

  # Reads only the first and last portions of a large file directly from disk
  # without loading the entire file into memory. Uses :file.pread/3 for
  # positioned reads and :raw/:binary mode for speed. The truncation size
  # (8192 bytes: 4096 first + 4096 last) matches OutputSanitizer.
  defp read_truncated(path, file_size, max_bytes) do
    truncate_size = 8192

    if file_size <= truncate_size do
      case File.read(path) do
        {:ok, data} -> data
        {:error, _} -> ""
      end
    else
      half_size = div(truncate_size, 2)
      omitted = file_size - truncate_size

      {:ok, device} = File.open(path, [:read, :raw, :binary])

      {:ok, first_part} = :file.pread(device, 0, half_size)
      {:ok, last_part} = :file.pread(device, file_size - half_size, half_size)

      File.close(device)

      """
      [WARNING: Output exceeded #{max_bytes} bytes and was truncated to #{truncate_size} bytes]
      The output was too large. Consider using more specific arguments
      or alternative tools to retrieve only the relevant portion of data.
      #{first_part}
      ... [#{omitted} bytes omitted] ...
      #{last_part}
      """
      |> String.trim()
    end
  end
end
