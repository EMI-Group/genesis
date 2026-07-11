defmodule EvoGit.Sandbox.None do
  @moduledoc """
  No-op sandbox backend for Windows and other unsupported platforms.

  All commands run directly without any sandboxing. When the Nix dev
  environment is active (enabled via config + available `nix` binary +
  `flake.nix` + successful dev-env build), commands are run inside the
  cached dev environment (sourced via `bash -c`) so that LLM-generated
  tool calls have access to the tools and environment defined in the
  user's Nix flake.
  """

  alias EvoGit.Nix

  @doc "Always returns false — no sandbox available."
  @spec enabled?() :: false
  def enabled?, do: false

  @doc "No initialization needed."
  @spec ensure_initialized() :: :ok
  def ensure_initialized, do: :ok

  @doc "Runs command directly, optionally inside the cached nix dev env when active."
  @spec run(String.t(), String.t(), [String.t()], String.t() | nil) ::
          {String.t(), non_neg_integer()}
  def run(cwd, executable, args \\ [], _repo_root \\ nil) do
    {exec, exec_args} =
      if Nix.active?() do
        Nix.wrap_command(executable, args)
      else
        {executable, args}
      end

    # Wrap in bash with stdin redirected from /dev/null so commands like rg
    # that read stdin on missing args get immediate EOF instead of hanging.
    inner_cmd = Enum.map_join([exec | exec_args], " ", &shell_escape/1)
    wrapped_cmd = inner_cmd <> " < /dev/null"

    # Inject LC_ALL=C and GIT_EDITOR=<true path> for git commands so that
    # automated operations that may open an interactive editor (e.g.
    # `git merge --continue`, rebase, am, commit) never block. Detection uses
    # the ORIGINAL executable param (before nix/bash wrapping).
    if EvoGit.GitEnv.git_command?(executable) do
      System.cmd("bash", ["-c", wrapped_cmd],
        cd: cwd,
        stderr_to_stdout: true,
        env: EvoGit.GitEnv.git_env_list()
      )
    else
      System.cmd("bash", ["-c", wrapped_cmd], cd: cwd, stderr_to_stdout: true)
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
  @spec run_with_partial(String.t(), String.t(), [String.t()], String.t() | nil, pos_integer(), integer() | nil) ::
          {:ok, String.t(), non_neg_integer()} | {:timeout, String.t()}
  def run_with_partial(cwd, executable, args \\ [], _repo_root \\ nil, timeout, max_bytes \\ nil)
      when is_list(args) and is_integer(timeout) and timeout > 0 do
    tmpdir = Path.join(EvoGit.Sandbox.resolve_tmpdir(), "genesis_partial_outputs")
    File.mkdir_p!(tmpdir)
    tmpfile = Path.join(tmpdir, "#{System.monotonic_time()}_#{System.unique_integer([:positive])}")

    inner_cmd = Enum.map_join([executable | args], " ", &shell_escape/1)
    wrapped_cmd = inner_cmd <> " > " <> shell_escape(tmpfile) <> " 2>&1 < /dev/null"

    # Detect git on the ORIGINAL executable (before we wrap it in bash)
    is_git = EvoGit.GitEnv.git_command?(executable)

    {exec, exec_args} =
      if Nix.active?() do
        Nix.wrap_command("bash", ["-c", wrapped_cmd])
      else
        {"bash", ["-c", wrapped_cmd]}
      end

    git_env = if is_git, do: EvoGit.GitEnv.git_env_list(), else: []

    task = Task.async(fn ->
      System.cmd(exec, exec_args,
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
