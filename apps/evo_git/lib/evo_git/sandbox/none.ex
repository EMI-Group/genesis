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

    # Inject LC_ALL=C and GIT_EDITOR=<true path> for git commands so that
    # automated operations that may open an interactive editor (e.g.
    # `git merge --continue`, rebase, am, commit) never block. Detection uses
    # the ORIGINAL executable param (before nix wrapping) since the nix-wrapped
    # exec is `{"bash", ["-c", ...]}`.
    if EvoGit.GitEnv.git_command?(executable) do
      System.cmd(exec, exec_args,
        cd: cwd,
        stderr_to_stdout: true,
        env: EvoGit.GitEnv.git_env_list()
      )
    else
      System.cmd(exec, exec_args, cd: cwd, stderr_to_stdout: true)
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
  @spec run_with_partial(String.t(), String.t(), [String.t()], String.t() | nil, pos_integer()) ::
          {:ok, String.t(), non_neg_integer()} | {:timeout, String.t()}
  def run_with_partial(cwd, executable, args \\ [], _repo_root \\ nil, timeout)
      when is_list(args) and is_integer(timeout) and timeout > 0 do
    tmpdir = Path.join(EvoGit.Sandbox.resolve_tmpdir(), "genesis_partial_outputs")
    File.mkdir_p!(tmpdir)
    tmpfile = Path.join(tmpdir, "#{System.monotonic_time()}_#{System.unique_integer([:positive])}")

    inner_cmd = Enum.map_join([executable | args], " ", &shell_escape/1)
    wrapped_cmd = inner_cmd <> " > " <> shell_escape(tmpfile) <> " 2>&1"

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
        content = read_tempfile(tmpfile)
        {:ok, content, exit_code}

      nil ->
        partial = read_tempfile(tmpfile)
        {:timeout, partial <> "\n[TRUNCATED due to timeout]"}
    end
  end

  # POSIX-safe shell escaping
  defp shell_escape(arg) do
    "'" <> String.replace(arg, "'", "'\\''") <> "'"
  end

  defp read_tempfile(path) do
    content =
      case File.read(path) do
        {:ok, data} -> data
        {:error, _} -> ""
      end

    _ = File.rm(path)
    content
  end
end
