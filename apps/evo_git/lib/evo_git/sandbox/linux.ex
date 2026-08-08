defmodule EvoGit.Sandbox.Linux do
  @moduledoc """
  Linux sandbox backend using `systemd-run`.

  Provides full sandboxing: filesystem isolation, resource limits (CPU, memory),
  syscall filtering, and process isolation. Requires systemd.
  """

  @behaviour EvoGit.Sandbox.Behaviour

  alias EvoGit.{Nix, Platform, Sandbox.Helpers}

  # Compile-time Mix env — safe in releases (Mix.env/0 is evaluated at compile
  # time; in prod releases it resolves to :prod). Used to skip systemd-run
  # execution entirely in the test environment, where the user D-Bus session
  # bus is typically unavailable (CI containers, nested sandboxes).
  @mix_env Mix.env()

  # Built-in writable cache dirs (home-relative) for package managers and
  # toolchains (`mix deps.get`, `npm install`, `cargo build`). This is the
  # DEFAULT list emitted as `-p ReadWritePaths=-<home>/<dir>` when the user has
  # NOT set `[sandbox] write_paths`. When set, the user's list REPLACES this
  # one wholesale (even an empty list) — see `resolve_write_paths/2`.
  @default_cache_dirs [
    # Universal cache (Python pip, Go build, C/C++ ccache)
    ".cache",
    # Universal local share (pnpm state, generic tools)
    ".local/share",
    # Universal local state
    ".local/state",
    # Rust packages
    ".cargo",
    # Rust toolchains
    ".rustup",
    # Elixir Mix
    ".mix",
    # Elixir Hex
    ".hex",
    # Node.js npm
    ".npm",
    # Node.js yarn
    ".yarn",
    # Bun JS
    ".bun",
    # Java Maven
    ".m2",
    # Java Gradle
    ".gradle",
    # Golang workspace (default GOPATH)
    "go"
  ]

  @doc "Returns true when sandbox mode allows systemd-run on Linux."
  @spec enabled?() :: boolean()
  def enabled? do
    cond do
      # Tests never need systemd sandboxing, and the user bus is typically
      # unavailable in CI/local test environments. Skip systemd-run execution.
      @mix_env == :test ->
        false

      true ->
        case EvoGit.Config.resolve([:sandbox, :mode]) do
          :enabled -> true
          :disabled -> false
          :auto -> Platform.systemd_available?()
        end
    end
  end

  @doc """
  Inserts `--unit=<name>` into a systemd-run argument list, immediately after
  the `--user` flag. This is a pure function with no side effects.

  ## Example

      iex> EvoGit.Sandbox.Linux.inject_unit(["--user", "--slice=evogit", "--wait"], "evogit-run-123")
      ["--user", "--unit=evogit-run-123", "--slice=evogit", "--wait"]
  """
  @spec inject_unit([String.t()], String.t()) :: [String.t()]
  def inject_unit(["--user" | rest], unit_name) do
    ["--user", "--unit=#{unit_name}" | rest]
  end

  @doc "Creates the evogit.slice if not already active."
  @spec ensure_initialized() :: :ok | {:error, term()}
  def ensure_initialized do
    if enabled?() do
      EvoGit.SandboxSlice.ensure_slice()
    else
      :ok
    end
  end

  @doc "Runs command via systemd-run."
  @spec run(String.t(), String.t(), [String.t()], String.t() | nil) ::
          {String.t(), non_neg_integer()}
  def run(cwd, executable, args \\ [], repo_root \\ nil) when is_list(args) do
    if enabled?() do
      ensure_initialized()
      unit = EvoGit.SandboxProcessRegistry.register()
      # Wrap in bash with stdin redirect: systemd-run --pipe connects stdin as a
      # pipe (overriding StandardInput=null), so we redirect on our side.
      is_git = EvoGit.GitEnv.git_command?(executable)
      inner_cmd = Enum.map_join([executable | args], " ", &Helpers.shell_escape/1)
      wrapped_cmd = inner_cmd <> " < /dev/null"
      sandbox_args = inject_unit(args(cwd, "bash", ["-c", wrapped_cmd], repo_root), unit)
      # args/4 won't detect git on "bash", so append git env manually
      sandbox_args = maybe_append_git_env(sandbox_args, is_git, cwd)
      result = System.cmd("systemd-run", sandbox_args, stderr_to_stdout: true)
      EvoGit.SandboxProcessRegistry.unregister(unit)
      result
    else
      # Disabled path: wrap in bash with stdin redirect from /dev/null.
      inner_cmd = Enum.map_join([executable | args], " ", &Helpers.shell_escape/1)
      wrapped_cmd = inner_cmd <> " < /dev/null"

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
  end

  @doc "Generates systemd-run argument list."
  @spec args(String.t(), String.t(), [String.t()], String.t() | nil) :: [String.t()]
  def args(cwd, executable, args \\ [], repo_root \\ nil) when is_list(args) do
    home = System.user_home!()

    # Keep sensitive credentials locked down
    inaccessible_args =
      [
        ".ssh",
        ".gnupg",
        ".aws",
        ".kube",
        ".config/sops",
        ".npmrc",
        ".git-credentials",
        ".netrc"
      ]
      |> Enum.flat_map(fn dir ->
        ["-p", "InaccessiblePaths=-#{Path.join(home, dir)}"]
      end)

    # User-configurable writable paths (`[sandbox] write_paths`): nil (unset)
    # → the built-in default cache-dir list; set (even `[]`) → the user's list
    # REPLACES the default cache-dir list. Structural paths (cwd, tmp paths,
    # nix store/var, repo .git) are ALWAYS appended below — they are required
    # for the sandbox to function, not part of the user-configurable list.
    write_paths = resolve_write_paths(EvoGit.Config.resolve([:sandbox, :write_paths]), home)

    # Add nix store and daemon socket dirs when nix wrapping is enabled
    nix_paths =
      if Nix.enabled?() do
        ["/nix/store", "/nix/var"]
      else
        []
      end

    # Add cwd, the system temp folders, and the language caches
    read_write_paths =
      [cwd | Platform.tmp_paths()] ++
        write_paths ++
        nix_paths ++
        if repo_root do
          [Path.join(repo_root, ".git")]
        else
          []
        end

    read_write_args =
      Enum.flat_map(read_write_paths, fn path ->
        # The "-" prefix ensures systemd won't crash if the directory doesn't exist yet
        ["-p", "ReadWritePaths=-#{path}"]
      end)

    # Propagate PATH and HOME so tools installed in non-standard locations (e.g. /usr/local/bin,
    # nix store, user-local bin) are found inside the sandbox the same way they are in
    # the user's interactive shell. TMPDIR is forwarded to a path the sandbox actually
    # grants write access to (resolved by EvoGit.Sandbox.resolve_tmpdir/0) so that
    # LLM-generated temp-file writes don't fail.
    # Inject LC_ALL=C and GIT_EDITOR=<true path> for git commands so that
    # automated operations that may open an interactive editor (e.g.
    # `git merge --continue`, rebase, am, commit) never block inside the
    # sandbox. Detection uses the ORIGINAL executable param (before any
    # nix wrapping) since the nix-wrapped exec is `{"bash", ["-c", ...]}`.
    env_args =
      [
        {"PATH", System.get_env("PATH")},
        {"HOME", System.get_env("HOME")},
        {"TMPDIR", EvoGit.Sandbox.resolve_tmpdir()}
      ] ++
        if EvoGit.GitEnv.git_command?(executable),
          do: EvoGit.GitEnv.git_env_list(cwd),
          else: []

    env_args =
      Enum.flat_map(env_args, fn
        {_key, nil} -> []
        {key, value} -> ["--setenv=#{key}=#{value}"]
      end)

    nix_env_args =
      if Nix.enabled?() do
        Nix.nix_env_vars()
        |> Enum.flat_map(fn {key, value} -> ["--setenv=#{key}=#{value}"] end)
      else
        []
      end

    [
      "--user",
      "--slice=evogit",
      "--wait",
      "--pipe",
      "--collect",
      "-q"
    ] ++
      env_args ++
      nix_env_args ++
      [
        "-p",
        "WorkingDirectory=#{cwd}",
        "-p",
        "StandardInput=null"
      ] ++
      security_args() ++
      resource_args() ++
      read_write_args ++
      inaccessible_args ++
      if Nix.active?() do
        {nix_exe, nix_args} = Nix.wrap_command(executable, args)
        [nix_exe | nix_args]
      else
        [executable | args]
      end
  end

  defp resource_args do
    process_resources = get_process_resources()

    cpu_quota_args =
      case Map.get(process_resources, :cpu_quota) do
        nil -> []
        v -> ["-p", "CPUQuota=#{v}"]
      end

    memory_args =
      case Map.get(process_resources, :memory_max) do
        nil -> []
        v -> ["-p", "MemoryMax=#{v}"]
      end

    nofile_args =
      case Map.get(process_resources, :limit_nofile) do
        nil -> []
        v -> ["-p", "LimitNOFILE=#{v}"]
      end

    oom_args =
      case Map.get(process_resources, :oom_score_adjust) do
        nil -> []
        v -> ["-p", "OOMScoreAdjust=#{v}"]
      end

    cpu_quota_args ++ memory_args ++ nofile_args ++ oom_args
  end

  # Returns the list of systemd-run security property arguments based on
  # the `[sandbox.linux]` config section. Each feature defaults to `true`
  # when the config key is missing (full security). Users on older systemd
  # versions can disable unsupported features in ~/.config/genesis/config.toml.
  defp security_args do
    cfg = EvoGit.Config.resolve([:sandbox, :linux])

    protect_system =
      if Map.get(cfg, :protect_system, true) do
        ["-p", "ProtectSystem=strict"]
      else
        []
      end

    protect_home =
      if Map.get(cfg, :protect_home, true) do
        ["-p", "ProtectHome=read-only"]
      else
        []
      end

    protect_kernel_tunables =
      if Map.get(cfg, :protect_kernel_tunables, true) do
        ["-p", "ProtectKernelTunables=yes"]
      else
        []
      end

    protect_control_groups =
      if Map.get(cfg, :protect_control_groups, true) do
        ["-p", "ProtectControlGroups=yes"]
      else
        []
      end

    system_call_filter =
      if Map.get(cfg, :system_call_filter, true) do
        [
          "-p",
          "SystemCallArchitectures=native",
          "-p",
          "SystemCallErrorNumber=EPERM",
          "-p",
          "SystemCallFilter=~ @clock @module @mount @raw-io @reboot @swap"
        ]
      else
        []
      end

    no_new_privileges =
      if Map.get(cfg, :no_new_privileges, true) do
        ["-p", "NoNewPrivileges=yes"]
      else
        []
      end

    private_pids =
      if Map.get(cfg, :private_pids, false) do
        ["-p", "PrivatePIDs=yes"]
      else
        []
      end

    protect_proc =
      if Map.get(cfg, :protect_proc, false) do
        ["-p", "ProtectProc=invisible"]
      else
        []
      end

    protect_system ++
      protect_home ++
      protect_kernel_tunables ++
      protect_control_groups ++
      system_call_filter ++
      no_new_privileges ++
      private_pids ++
      protect_proc
  end

  defp get_process_resources do
    # JUSTIFIED try/catch: AgentScheduler.get_config/0 is a GenServer.call
    # that exits the caller (noproc/timeout) when the scheduler isn't
    # running — e.g. during early init or tests. GenServer.call has no
    # non-raising variant (it exits the process, it doesn't return an
    # error tuple), so try/catch is the correct way to guard this.
    # Config.resolve never raises and returns nil for missing keys, so it
    # needs no protection.
    scheduler_config =
      try do
        EvoGit.AgentScheduler.get_config()
      catch
        :exit, _ -> %{}
      end

    case scheduler_config[:sandbox_process_resources] do
      nil -> EvoGit.Config.resolve([:sandbox, :process])
      resources when map_size(resources) == 0 -> EvoGit.Config.resolve([:sandbox, :process])
      resources -> resources
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

    # Detect git on the ORIGINAL executable (before we wrap it in bash).
    # The sandbox args/4 won't detect git since it receives "bash", so we
    # append git env vars ourselves when needed.
    is_git = EvoGit.GitEnv.git_command?(executable)

    if enabled?() do
      ensure_initialized()
      unit = EvoGit.SandboxProcessRegistry.register()
      sandbox_args = inject_unit(args(cwd, "bash", ["-c", wrapped_cmd], repo_root), unit)

      # Append git env vars for the inner command (args/4 won't detect git on "bash")
      sandbox_args = maybe_append_git_env(sandbox_args, is_git, cwd)

      task =
        Task.async(fn ->
          System.cmd("systemd-run", sandbox_args, stderr_to_stdout: true)
        end)

      case Task.yield(task, timeout) || Task.shutdown(task) do
        {:ok, {_output, exit_code}} ->
          EvoGit.SandboxProcessRegistry.unregister(unit)
          content = Helpers.read_tempfile(tmpfile, max_bytes)
          {:ok, content, exit_code}

        nil ->
          # CRITICAL: Task.shutdown killed the systemd-run CLIENT, but the
          # .service unit keeps running. Release spawns an async Task to stop it.
          EvoGit.SandboxProcessRegistry.release(unit)
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

  # Resolves the writable-path (cache-dir) list to absolute paths.
  #
  #   * `nil` (config unset) → the built-in `@default_cache_dirs` list joined
  #     to `home` — byte-identical to the historical hard-coded output.
  #   * set (even `[]`) → the user's list REPLACES the default cache-dir list;
  #     `[]` means no cache-dir write paths at all.
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

  # Appends --setenv args for git env vars when the original executable is git.
  # The identity is resolved for `cwd` (the working directory the git command
  # runs in) so repo-local `git config` is honored inside the sandbox.
  defp maybe_append_git_env(sandbox_args, true, cwd) do
    git_env_args =
      EvoGit.GitEnv.git_env_list(cwd)
      |> Enum.flat_map(fn {k, v} -> ["--setenv=#{k}=#{v}"] end)

    sandbox_args ++ git_env_args
  end

  defp maybe_append_git_env(sandbox_args, false, _cwd), do: sandbox_args
end
