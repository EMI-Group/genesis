defmodule EvoGit.Sandbox.None do
  @moduledoc """
  No-op sandbox backend for Windows and other unsupported platforms.

  All commands run directly without any sandboxing. When the Nix dev
  environment is active (enabled via config + available `nix` binary +
  `flake.nix` + successful dev-env build), commands are run inside the
  cached dev environment (sourced via `bash -c`) so that LLM-generated
  tool calls have access to the tools and environment defined in the
  user's Nix flake.

  On Windows there is still no OS-level isolation (no Job Objects, no
  AppContainer, no resource limits, no network isolation); the one hardening
  provided is that `run_with_partial/6` kills the entire process tree on
  timeout via `taskkill /T /F` (a bare `Task.shutdown/1` would only reach the
  direct child). See `run_with_partial/6` for details.
  """

  @behaviour EvoGit.Sandbox.Behaviour

  alias EvoGit.{Nix, Sandbox.Helpers}

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
    if EvoGit.Platform.windows?() do
      run_windows(cwd, executable, args)
    else
      run_unix(cwd, executable, args)
    end
  end

  defp run_unix(cwd, executable, args) do
    {exec, exec_args} =
      if Nix.active?() do
        Nix.wrap_command(executable, args)
      else
        {executable, args}
      end

    # Wrap in bash with stdin redirected from /dev/null so commands like rg
    # that read stdin on missing args get immediate EOF instead of hanging.
    inner_cmd = Enum.map_join([exec | exec_args], " ", &Helpers.shell_escape/1)
    wrapped_cmd = inner_cmd <> " < /dev/null"

    # Inject LC_ALL=C and GIT_EDITOR=<true path> for git commands so that
    # automated operations that may open an interactive editor (e.g.
    # `git merge --continue`, rebase, am, commit) never block. Detection uses
    # the ORIGINAL executable param (before nix/bash wrapping).
    if EvoGit.GitEnv.git_command?(executable) do
      System.cmd("bash", ["-c", wrapped_cmd],
        cd: cwd,
        stderr_to_stdout: true,
        env: EvoGit.GitEnv.git_env_list(cwd)
      )
    else
      System.cmd("bash", ["-c", wrapped_cmd], cd: cwd, stderr_to_stdout: true)
    end
  end

  defp run_windows(cwd, executable, args) do
    # On Windows, System.cmd passes args as an array (no shell injection risk),
    # so we call the executable directly without a shell wrapper. This avoids the
    # need for shell escaping and avoids PowerShell's lack of input redirection
    # (the `<` operator is reserved and throws a parser error).
    if EvoGit.GitEnv.git_command?(executable) do
      System.cmd(executable, args,
        cd: cwd,
        stderr_to_stdout: true,
        env: EvoGit.GitEnv.git_env_list(cwd)
      )
    else
      System.cmd(executable, args, cd: cwd, stderr_to_stdout: true)
    end
  end

  @doc """
  Runs a command with timeout, recovering partial output on timeout via temp-file redirection.

  Unlike `run/4` which uses blocking `System.cmd/3` and loses all output on timeout,
  this function redirects stdout/stderr to a temp file. If the timeout fires, the
  partial output written so far can still be read from the temp file.

  On Windows the implementation differs: output is accumulated in memory (no temp
  file), and on timeout the **entire process tree** is killed via `taskkill /T /F`
  (not just the direct child, which is all that `Task.shutdown/1` can reach), with
  the partial output accumulated so far returned.

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
  def run_with_partial(cwd, executable, args \\ [], _repo_root \\ nil, timeout, max_bytes \\ nil)
      when is_list(args) and is_integer(timeout) and timeout > 0 do
    if EvoGit.Platform.windows?() do
      run_with_partial_windows(cwd, executable, args, timeout, max_bytes)
    else
      run_with_partial_unix(cwd, executable, args, timeout, max_bytes)
    end
  end

  defp run_with_partial_unix(cwd, executable, args, timeout, max_bytes) do
    tmpdir = Path.join(EvoGit.Sandbox.resolve_tmpdir(), "genesis_partial_outputs")
    File.mkdir_p!(tmpdir)

    tmpfile =
      Path.join(tmpdir, "#{System.monotonic_time()}_#{System.unique_integer([:positive])}")

    inner_cmd = Enum.map_join([executable | args], " ", &Helpers.shell_escape/1)
    wrapped_cmd = inner_cmd <> " > " <> Helpers.shell_escape(tmpfile) <> " 2>&1 < /dev/null"

    # Detect git on the ORIGINAL executable (before we wrap it in bash)
    is_git = EvoGit.GitEnv.git_command?(executable)

    {exec, exec_args} =
      if Nix.active?() do
        Nix.wrap_command("bash", ["-c", wrapped_cmd])
      else
        {"bash", ["-c", wrapped_cmd]}
      end

    git_env = if is_git, do: EvoGit.GitEnv.git_env_list(cwd), else: []

    task =
      Task.async(fn ->
        System.cmd(exec, exec_args,
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

  defp run_with_partial_windows(cwd, executable, args, timeout, max_bytes) do
    # On Windows, System.cmd passes args as an array (no shell injection risk),
    # so we call the executable directly without a shell wrapper. This avoids the
    # need for shell escaping and avoids PowerShell's lack of input redirection
    # (the `<` operator is reserved and throws a parser error).
    #
    # A timeout is needed here, but System.cmd/3 is blocking, and wrapping it in
    # a Task would make Task.shutdown/1 kill only the DIRECT child process — any
    # process tree it spawned (e.g. a cmd.exe or powershell grandchild) would be
    # orphaned and keep running. So instead we open the port ourselves, mirroring
    # System.cmd's exact port options (binary, exit_status, hide, stderr_to_stdout,
    # args, cd, env). Direct port ownership lets us read the OS PID and, on
    # timeout, kill the WHOLE process tree via `taskkill /T /F` — Windows'
    # built-in tree killer — before returning the partial output.
    is_git = EvoGit.GitEnv.git_command?(executable)
    git_env = if is_git, do: EvoGit.GitEnv.git_env_list(cwd), else: []

    # Same resolution System.cmd/3 performs: absolute paths are used as-is,
    # otherwise a PATH/PATHEXT lookup (raises ErlangError(:enoent) when missing).
    exec =
      if Path.type(executable) == :absolute do
        executable
      else
        :os.find_executable(executable) || :erlang.error(:enoent, [executable, args, cwd])
      end

    port =
      Port.open(
        {:spawn_executable, exec},
        [:binary, :exit_status, :hide, :stderr_to_stdout] ++
          [{:args, args}, {:cd, cwd}, {:env, git_env}]
      )

    os_pid = wait_for_os_pid(port)

    collect_windows_output(port, [], timeout, max_bytes, os_pid)
  end

  # The OS PID is populated asynchronously after the child process is spawned;
  # poll briefly for it. If it never materializes, fall back to :undefined and
  # the timeout path degrades to closing the port (kills only the direct child —
  # identical to the pre-hardening behavior).
  defp wait_for_os_pid(port, attempts \\ 10) do
    case Port.info(port, :os_pid) do
      pid when is_integer(pid) ->
        pid

      _ when attempts > 0 ->
        Process.sleep(10)
        wait_for_os_pid(port, attempts - 1)

      _ ->
        :undefined
    end
  end

  defp collect_windows_output(port, acc, timeout, max_bytes, os_pid) do
    receive do
      {^port, {:data, data}} ->
        collect_windows_output(port, [data | acc], timeout, max_bytes, os_pid)

      {^port, {:exit_status, exit_code}} ->
        output = acc |> Enum.reverse() |> IO.iodata_to_binary()
        {:ok, Helpers.truncate_output(output, max_bytes), exit_code}
    after
      timeout ->
        kill_windows_tree(os_pid)
        Port.close(port)
        drain_port_messages(port)

        partial = acc |> Enum.reverse() |> IO.iodata_to_binary()

        {:timeout, Helpers.truncate_output(partial, max_bytes) <> "\n[TRUNCATED due to timeout]"}
    end
  end

  # `taskkill /T` walks the whole descendant tree; `/F` forces termination. The
  # result is ignored: the direct process may already have exited on its own
  # (taskkill then reports "process not found", which is harmless).
  defp kill_windows_tree(os_pid) when is_integer(os_pid) do
    System.cmd("taskkill", ["/PID", Integer.to_string(os_pid), "/T", "/F"],
      stderr_to_stdout: true
    )

    :ok
  end

  defp kill_windows_tree(_), do: :ok

  # After Port.close/1, messages already delivered stay in this process's
  # mailbox; drain them so they can't be matched by later receives.
  defp drain_port_messages(port) do
    receive do
      {^port, _message} -> drain_port_messages(port)
    after
      0 -> :ok
    end
  end
end
