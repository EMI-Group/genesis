defmodule EvoGit.Sandbox.Bwrap do
  @moduledoc """
  Linux sandbox backend using `bwrap` (bubblewrap).

  Provides **filesystem-only isolation**: the whole root filesystem is bind-mounted
  read-only (`--ro-bind / /`), with explicit writable binds (worktree, git metadata
  dir, tmp dirs, package-manager cache dirs, nix store) and empty-tmpfs overlays
  hiding sensitive credential stores. There are **no resource limits** (no CPU/memory
  quotas, no process-count limit — bwrap has no equivalent of systemd's
  `CPUQuota`/`MemoryMax`) and **no syscall filtering**.

  Use case: Linux environments where `systemd-run` is unavailable or undesirable —
  containers/docker, minimal or systemd-less distros, sandboxed CI. It needs only a
  `bwrap` binary and either root privileges or unprivileged user namespaces. It does
  NOT need the `evogit.slice` systemd slice or the unit registry, so
  `ensure_initialized/0` is a no-op and this backend never touches
  `EvoGit.SandboxSlice`/`EvoGit.SandboxProcessRegistry`.

  ## Namespace shape (verified against bwrap 0.11.2)

  The argv uses `--unshare-user-try --unshare-ipc --unshare-pid --unshare-uts
  --unshare-cgroup-try` (this is exactly `--unshare-all` minus `--unshare-net`, but
  spelled out so future bwrap versions adding namespaces to `--unshare-all` do not
  silently change the shape):

  * `--unshare-user-try` — explicit: works as root in docker AND as an unprivileged
    user where user namespaces are enabled; bwrap itself skips it gracefully when the
    kernel has user namespaces disabled (it checks `/proc/self/ns/user`,
    `/sys/module/user_namespace/parameters/enable`, `/proc/sys/user/max_user_namespaces`).
    `--unshare-user` (hard) is deliberately NOT used: in a container where the runtime
    blocks `CLONE_NEWUSER` (e.g. older docker default seccomp), the hard flag aborts the
    whole sandbox, while `-try` + the non-setuid DWIM fallback keeps root-in-docker
    working (root does not need a userns to run bwrap).
  * `--unshare-ipc`, `--unshare-pid`, `--unshare-uts` — hard (no `-try` variants exist;
    both target cases — root-in-docker and unprivileged-with-userns — support them).
    `--unshare-pid` gives process isolation (the sandbox cannot see other agents'
    processes) AND is the timeout-cleanup guarantee: the sandboxed command becomes
    PID 1 in its namespace, so when it dies the kernel SIGKILLs every remaining
    process in the namespace.
  * `--unshare-cgroup-try` — try variant (cgroup namespaces are the most commonly
    unsupported: cgroup v1-only or old kernels); bwrap only adds `CLONE_NEWCGROUP`
    when `/proc/self/ns/cgroup` exists.
  * **`--unshare-net` is deliberately NOT used** — the network namespace is retained so
    `git fetch/push`, `mix deps.get`, `curl` and web tools keep working. This matches
    both existing Unix backends (systemd backend sets no `PrivateNetwork`; macOS
    profile emits `(allow network*)`) and the documented posture that default-deny
    network breaks core agent workflows. Filesystem-only isolation is the scope of
    this backend.

  `--die-with-parent` + `--new-session` are always set: bwrap SIGKILLs the sandboxed
  command if bwrap or the BEAM parent dies, and `setsid()` runs in bwrap's MAIN
  process before it forks (bubblewrap.c: `setsid()` → fork), so bwrap is the session
  leader and its pgid == its pid — the whole sandbox tree (monitor + sandboxed
  command + descendants) is one process group that `run_with_partial` can kill with a
  single negative-pgid `kill`.

  ## Filesystem layout (order matters)

  1. `--ro-bind / /` — whole root read-only first ("everything readable, writes
     restricted", the same posture as the systemd backend's `ProtectSystem=strict`
     and macOS's root-wide read allow).
  2. `--dev /dev`, `--proc /proc` — fresh dev and procfs (the proc mount is allowed
     because the pid namespace is unshared).
  3. `--bind-try` for each of `Platform.tmp_paths()` (`/tmp`, `/var/tmp`) — writable.
  4. `--bind-try` for the writable paths: `cwd` (the worktree), the resolved
     `[sandbox] write_paths` cache-dir list (see "Configurable Writable Paths" in
     `sandbox/CONTEXT.md`), `/nix/store` + `/nix/var` when `Nix.enabled?()`, and the
     git metadata dir (linked-worktree `gitdir:` pointers resolved to the COMMON git
     dir, same logic as the macOS backend).
  5. `--tmpfs <home>/<dir>` over each sensitive credential-store dir (the deny list)
     — an empty tmpfs overlay hides the real content, which is bwrap's replacement
     for systemd's `InaccessiblePaths` (bwrap has no "inaccessible" primitive). These
     come AFTER the `--ro-bind / /` so they override it.
  6. `--chdir cwd`.

  `--bind-try` (not `--bind`) is used for all writable paths so a non-existent cache
  dir never aborts the sandbox: bwrap 0.11.2 skips the mount op entirely when the
  source is missing (`ALLOW_NOTEXIST` + `ENOENT` → `continue` in `setup_newroot`),
  which is exactly systemd's `ReadWritePaths=-` semantics. The deny `--tmpfs` mounts
  are safe even for non-existent dirs (bwrap `mkdir_with_parents`es the destination
  in the new root).

  ## Environment handling

  bwrap inherits the caller's environment (unlike `systemd-run --user`, which starts
  nearly clean), so `PATH`, `HOME`, `NIX*`/`SSL_CERT_FILE` etc. flow through by
  inheritance and are NOT re-injected. Explicit `--setenv` is added ONLY where needed:

  * `TMPDIR` — set to `EvoGit.Sandbox.resolve_tmpdir/0` (a tmp path the sandbox
    actually grants write access to). On systemd desktops `$TMPDIR` is
    `/run/user/<uid>`, which would be read-only inside the sandbox (covered by the
    `--ro-bind / /`).
  * **Git identity** — when the original executable is a git command, the full
    `EvoGit.GitEnv.git_env_list(cwd)` (`LC_ALL=C`, resolved `GIT_EDITOR`, and the
    `GIT_AUTHOR_*`/`GIT_COMMITTER_*` identity) is injected via `--setenv`. The BEAM
    process does NOT carry the GitEnv-resolved identity vars (they are injected only
    at `System.cmd` call time), so inheritance would give the sandboxed git nothing.
    Repo/global `git config` IS readable inside the sandbox (via `--ro-bind / /`), but
    GitEnv's `"Genesis"`/`"noreply@evogit.ai"` fallback identity would NOT apply
    there — commits in unconfigured repos would fail with "Please tell me who you
    are". Injecting the resolved identity preserves the exact semantics of the
    systemd backend (which also `--setenv`s it). ⚠️ These `--setenv` args MUST come
    BEFORE the command: bwrap's GOption parser stops at the first non-option argument
    (empirically verified — `bwrap ... true --bogus` does not report "Unknown
    option"), unlike systemd-run's GNU getopt which permutes options after the
    command.

  ## Timeout handling (`run_with_partial/6`)

  There is no systemd unit to stop, so the enabled path owns a `Port` directly to
  read the OS PID, redirects output to a temp file, and on timeout kills the whole
  sandbox: `kill -TERM -<pgid>` → short grace → `kill -KILL -<pgid>` (the pgid of
  bwrap itself — session leader, see above), then a direct `kill -KILL <pid>` as
  belt-and-suspenders (killing bwrap triggers `--die-with-parent`; and because the
  sandboxed command is PID 1 in its pid namespace, its death makes the kernel
  SIGKILL every remaining namespace member — this also catches daemonized
  grandchildren that escaped the process group). Partial output is recovered from
  the temp file exactly like the other backends.

  ## Empirical validation note

  `bwrap --help` and the full argv shape were parse-validated against bwrap 0.11.2
  (every flag accepted — bwrap fails only at the mount-setup stage in environments
  that block `mount(2)`). Real sandbox execution requires a host where `mount(2)`
  works (bare metal, privileged container, or unprivileged userns host); the
  `@mix_env == :test` gate means tests never invoke real bwrap.
  """

  @behaviour EvoGit.Sandbox.Behaviour

  alias EvoGit.{Nix, Platform, Sandbox.Helpers}

  # Compile-time Mix env — safe in releases (Mix.env/0 is evaluated at compile
  # time; in prod releases it resolves to :prod). Tests must NEVER invoke real
  # bwrap (CI/worker environments typically block mount(2) or lack user
  # namespaces), so the test gate comes first and is unconditional.
  @mix_env Mix.env()

  # Built-in writable cache dirs (home-relative) for package managers and
  # toolchains (`mix deps.get`, `npm install`, `cargo build`). Local copy per
  # backend convention (see sandbox/CONTEXT.md): this is the DEFAULT list
  # emitted as writable binds when the user has NOT set `[sandbox] write_paths`.
  # When set, the user's list REPLACES this one wholesale (even an empty list) —
  # see `Helpers.resolve_write_paths/3`.
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

  # Sensitive credential stores (home-relative) hidden from the sandbox by
  # binding an EMPTY tmpfs over each — bwrap's replacement for systemd's
  # InaccessiblePaths (bwrap has no "inaccessible" primitive). Mirrors the
  # macOS deny-read list minus the macOS-specific `Library/Keychains`, and is a
  # superset of linux.ex's 8 InaccessiblePaths dirs (adds `.password-store`,
  # `.docker`, `.gem`, `.pypirc`).
  @deny_list [
    ".ssh",
    ".gnupg",
    ".aws",
    ".kube",
    ".config/sops",
    ".git-credentials",
    ".netrc",
    ".password-store",
    ".docker",
    ".gem",
    ".npmrc",
    ".pypirc"
  ]

  @doc "Returns true when sandbox mode allows bwrap on this platform."
  @spec enabled?() :: boolean()
  def enabled? do
    cond do
      # Tests never invoke real bwrap (CI/worker environments usually cannot run
      # it), and the args builders are exercised directly instead.
      @mix_env == :test ->
        false

      true ->
        case EvoGit.Config.resolve([:sandbox, :mode]) do
          :enabled -> true
          :disabled -> false
          :auto -> Platform.bwrap_available?()
        end
    end
  end

  @doc "No initialization needed — bwrap needs no systemd slice and no unit registry."
  @spec ensure_initialized() :: :ok
  def ensure_initialized, do: :ok

  @doc "Runs command via bwrap."
  @spec run(String.t(), String.t(), [String.t()], String.t() | nil) ::
          {String.t(), non_neg_integer()}
  def run(cwd, executable, args \\ [], repo_root \\ nil) when is_list(args) do
    if enabled?() do
      ensure_initialized()
      # Wrap in bash with stdin redirect from /dev/null, exactly like the other
      # Unix backends: bwrap inherits our stdin, and commands like rg that read
      # stdin on missing args must get immediate EOF instead of hanging.
      is_git = EvoGit.GitEnv.git_command?(executable)
      inner_cmd = Enum.map_join([executable | args], " ", &Helpers.shell_escape/1)
      wrapped_cmd = inner_cmd <> " < /dev/null"
      sandbox_args = args(cwd, "bash", ["-c", wrapped_cmd], repo_root)
      # args/4 can't detect git on the wrapped "bash", so inject the resolved
      # git identity explicitly — BEFORE the command (bwrap's GOption parser
      # stops at the first non-option argument).
      sandbox_args = if is_git, do: git_env_args(cwd) ++ sandbox_args, else: sandbox_args
      System.cmd("bwrap", sandbox_args, stderr_to_stdout: true)
    else
      # Disabled path: identical to linux.ex — bash -c with stdin redirect.
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

  @doc "Generates the bwrap argument list."
  @spec args(String.t(), String.t(), [String.t()], String.t() | nil) :: [String.t()]
  def args(cwd, executable, args \\ [], repo_root \\ nil) when is_list(args) do
    home = System.user_home!()

    # Writable tmp dirs (always exist on Linux; --bind-try tolerates anything)
    tmp_bind_args =
      Enum.flat_map(Platform.tmp_paths(), fn path -> ["--bind-try", path, path] end)

    # User-configurable writable paths (`[sandbox] write_paths`): nil (unset)
    # → the built-in default cache-dir list; set (even `[]`) → the user's list
    # REPLACES the default cache-dir list. Structural paths (cwd, tmp paths,
    # nix store/var, git metadata dir) are ALWAYS included below — they are
    # required for the sandbox to function, not part of the user-configurable
    # list.
    write_paths =
      Helpers.resolve_write_paths(
        EvoGit.Config.resolve([:sandbox, :write_paths]),
        @default_cache_dirs,
        home
      )

    nix_paths =
      if Nix.enabled?() do
        ["/nix/store", "/nix/var"]
      else
        []
      end

    # The git metadata dir is resolved through linked-worktree `gitdir:`
    # pointers (see git_metadata_dir/2) so `git commit` works in worktrees
    # whose `.git` is a pointer file into a common dir.
    git_meta = git_metadata_dir(cwd, repo_root)

    writable_bind_args =
      ([cwd] ++ write_paths ++ nix_paths ++ List.wrap(git_meta))
      |> Enum.flat_map(fn path -> ["--bind-try", path, path] end)

    # Deny list: bind an EMPTY tmpfs over each sensitive home dir. Must come
    # AFTER the --ro-bind / / (and after the writable binds) so it overrides
    # them. bwrap mkdir_with_parents the destination, so non-existent dirs are
    # still covered.
    deny_args =
      Enum.flat_map(@deny_list, fn dir -> ["--tmpfs", Path.join(home, dir)] end)

    # Environment: PATH/HOME/NIX* flow through by inheritance (bwrap inherits
    # the caller env). TMPDIR must point at a path the sandbox actually grants
    # write access to; the git identity is resolved by GitEnv (the BEAM process
    # does not carry it) — see the moduledoc for the full rationale.
    env_args =
      [{"TMPDIR", EvoGit.Sandbox.resolve_tmpdir()}] ++
        if EvoGit.GitEnv.git_command?(executable),
          do: EvoGit.GitEnv.git_env_list(cwd),
          else: []

    env_setenv_args =
      Enum.flat_map(env_args, fn
        {_key, nil} -> []
        {key, value} -> ["--setenv", key, value]
      end)

    # Nix wrapping when the dev env is active (same as linux.ex: the nix
    # wrapper is `bash -c "source <dev-env>; exec <cmd>"`, which runs INSIDE
    # the sandbox — the dev-env script itself exports the NIX* vars).
    {cmd_exe, cmd_args} =
      if Nix.active?() do
        Nix.wrap_command(executable, args)
      else
        {executable, args}
      end

    [
      "--die-with-parent",
      "--new-session",
      # user + cgroup use -try variants so the sandbox RUNS in the common
      # cases (root-in-docker, unprivileged-with-userns); net is deliberately
      # NOT unshared (network must keep working — see moduledoc).
      "--unshare-user-try",
      "--unshare-ipc",
      "--unshare-pid",
      "--unshare-uts",
      "--unshare-cgroup-try",
      "--ro-bind",
      "/",
      "/",
      "--dev",
      "/dev",
      "--proc",
      "/proc"
    ] ++
      tmp_bind_args ++
      writable_bind_args ++
      deny_args ++
      ["--chdir", cwd] ++
      env_setenv_args ++
      ["--", cmd_exe | cmd_args]
  end

  @doc """
  Runs a command with timeout, recovering partial output on timeout via temp-file
  redirection.

  Unlike `run/4` which uses blocking `System.cmd/3` and loses all output on timeout,
  this function redirects stdout/stderr to a temp file. If the timeout fires, the
  partial output written so far can still be read from the temp file.

  There is no systemd unit to stop on timeout, so the enabled path opens the port
  directly, reads the OS PID, and kills the WHOLE bwrap process group
  (`kill -TERM -<pgid>` escalating to `-KILL`) — see the moduledoc for the process
  model and the pid-namespace cleanup guarantee.

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

    # Detect git on the ORIGINAL executable (before we wrap it in bash), so the
    # resolved identity can be injected into the sandbox explicitly.
    is_git = EvoGit.GitEnv.git_command?(executable)

    if enabled?() do
      ensure_initialized()
      sandbox_args = args(cwd, "bash", ["-c", wrapped_cmd], repo_root)
      # Same GOption ordering constraint as run/4: git --setenv BEFORE command.
      sandbox_args = if is_git, do: git_env_args(cwd) ++ sandbox_args, else: sandbox_args

      # Resolve bwrap to an absolute path for direct port spawning (Port.open
      # does no PATH search). Binary-safe resolution via the shared helper.
      exec =
        case EvoGit.Sandbox.None.resolve_executable("bwrap") do
          nil -> :erlang.error(:enoent, ["bwrap", sandbox_args])
          resolved -> resolved
        end

      port =
        Port.open(
          {:spawn_executable, exec},
          [:binary, :exit_status, :hide, :stderr_to_stdout] ++ [{:args, sandbox_args}]
        )

      os_pid = wait_for_os_pid(port)
      collect_output(port, timeout, max_bytes, os_pid, tmpfile)
    else
      # Disabled path: identical to linux.ex — Task + bash -c (no nix wrapping,
      # consistent with run/4's disabled path).
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

  # Builds --setenv args for the resolved git identity. Used by run/4 and
  # run_with_partial/6 where the command is wrapped in bash (so args/4 receives
  # "bash" and cannot detect git). These MUST precede the command: bwrap's
  # GOption parser stops at the first non-option argument (empirically verified
  # — `bwrap --ro-bind / / true --bogus` does not report "Unknown option"),
  # unlike systemd-run's GNU getopt which permutes options after the command.
  defp git_env_args(cwd) do
    EvoGit.GitEnv.git_env_list(cwd)
    |> Enum.flat_map(fn {key, value} -> ["--setenv", key, value] end)
  end

  # Waits for the OS PID of the spawned bwrap process. The PID is populated
  # asynchronously after spawn; poll briefly. If it never materializes, fall
  # back to :undefined and the timeout path degrades to closing the port (the
  # group kill is skipped).
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

  # Collects the exit status of the bwrap port, killing the whole sandbox
  # process group on timeout and recovering partial output from the temp file.
  defp collect_output(port, timeout, max_bytes, os_pid, tmpfile) do
    receive do
      {^port, {:exit_status, exit_code}} ->
        content = Helpers.read_tempfile(tmpfile, max_bytes)
        {:ok, content, exit_code}
    after
      timeout ->
        kill_process_group(os_pid)
        Port.close(port)
        drain_port_messages(port)

        partial = Helpers.read_tempfile(tmpfile, max_bytes)
        {:timeout, partial <> "\n[TRUNCATED due to timeout]"}
    end
  end

  # Kills the whole bwrap sandbox tree on timeout. bwrap --new-session calls
  # setsid() in its own main process BEFORE forking (bubblewrap.c: setsid →
  # fork), so bwrap is the session leader and pgid == bwrap's pid; a
  # negative-pgid kill reaches the monitor, the sandboxed command and its
  # descendants (process groups are kernel-wide, NOT namespaced by
  # --unshare-pid). TERM first (graceful), then escalate to KILL. The direct
  # -KILL of bwrap itself is belt-and-suspenders: if the group kill somehow
  # missed it, killing bwrap triggers --die-with-parent (SIGKILL to the
  # sandboxed command), and because the command is PID 1 in its pid namespace,
  # its death makes the kernel SIGKILL every remaining namespace member — this
  # also catches daemonized grandchildren that escaped the process group.
  defp kill_process_group(os_pid) when is_integer(os_pid) do
    pid = Integer.to_string(os_pid)

    System.cmd("kill", ["-TERM", "--", "-" <> pid], stderr_to_stdout: true)
    Process.sleep(100)
    System.cmd("kill", ["-KILL", "--", "-" <> pid], stderr_to_stdout: true)
    System.cmd("kill", ["-KILL", pid], stderr_to_stdout: true)
    :ok
  end

  defp kill_process_group(_), do: :ok

  # After Port.close/1, messages already delivered stay in this process's
  # mailbox; drain them so they can't be matched by later receives.
  defp drain_port_messages(port) do
    receive do
      {^port, _message} -> drain_port_messages(port)
    after
      0 -> :ok
    end
  end

  # Resolves the git metadata directory the sandbox must grant write access to.
  # Returns nil when no git metadata dir should be exposed.
  #
  # - `base = repo_root || cwd`; `literal = Path.join(base, ".git")`.
  # - If `literal` is a FILE, it is a linked-worktree pointer (a
  #   `gitdir: <path>` line as produced by `git worktree add`). The pointer
  #   target is the per-worktree metadata dir (`<common>/worktrees/<name>`);
  #   git also needs the COMMON dir (objects/refs/logs/packed-refs/config),
  #   so the prefix before the LAST "/worktrees/" segment is returned (a
  #   writable bind on the common dir covers the per-worktree dir inside it).
  #   A pointer without a "/worktrees/" segment resolves to itself.
  # - Otherwise (`.git` is a real directory, or missing):
  #   - repo_root given → the literal `<repo_root>/.git`.
  #   - repo_root nil → nil, UNLESS the literal is an existing directory
  #     (cwd IS a repo with a real `.git` — e.g. the skills executor passing
  #     cwd = worktree and repo_root = nil).
  #
  # Mirrors the macOS backend's resolution (the Linux systemd backend uses the
  # plain `Path.join(repo_root, ".git")` shape — left unchanged there; this
  # backend resolves pointers because bwrap binds are per-path, not per-tree).
  defp git_metadata_dir(cwd, repo_root) do
    base = repo_root || cwd
    literal = Path.join(base, ".git")

    case File.read(literal) do
      {:ok, content} -> parse_gitdir_pointer(content, base, literal)
      {:error, _} -> if repo_root || File.dir?(literal), do: literal, else: nil
    end
  end

  # Parses a linked-worktree `.git` pointer file. Finds the first line
  # starting with "gitdir:", strips the prefix, trims whitespace; empty or
  # missing → unparseable → falls back to `literal`. The resolved target is
  # expanded relative to `base` when not absolute, then reduced to the common
  # git dir (prefix before the last "/worktrees/" segment — `binary_part` on
  # the last match start, NOT `String.split` with parts: 2, which is wrong
  # when the repo path itself contains "/worktrees/").
  defp parse_gitdir_pointer(content, base, literal) do
    target =
      content
      |> String.split("\n")
      |> Enum.find(&String.starts_with?(&1, "gitdir:"))
      |> case do
        nil -> nil
        line -> line |> String.replace_prefix("gitdir:", "") |> String.trim()
      end

    case target do
      nil ->
        literal

      "" ->
        literal

      pointer ->
        resolved = Path.expand(pointer, base)

        case :binary.matches(resolved, "/worktrees/") do
          [] ->
            resolved

          matches ->
            {start, _len} = List.last(matches)

            case :binary.part(resolved, 0, start) do
              # Pathological: common dir at filesystem root — never emit a
              # broken empty path; use the resolved target itself.
              "" -> resolved
              common -> common
            end
        end
    end
  end
end
