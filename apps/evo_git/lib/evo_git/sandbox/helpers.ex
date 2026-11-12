defmodule EvoGit.Sandbox.Helpers do
  @moduledoc """
  Shared utility functions for the sandbox subsystem.

  Extracted from the individual sandbox backend implementations
  (`EvoGit.Sandbox.Linux`, `EvoGit.Sandbox.MacOS`, `EvoGit.Sandbox.None`),
  `EvoGit.Nix`, and the sandbox lifecycle modules (`EvoGit.SandboxSlice`,
  `EvoGit.SandboxProcessRegistry`) to eliminate copy-paste duplication.

  All functions are pure or perform only the I/O they are explicitly
  responsible for (temp-file reads, `System.cmd` execution).
  """

  # When truncating large output, keep this many bytes total (first half +
  # last half). Matches OutputSanitizer's truncation window.
  @truncate_size 8192

  # Grace period between SIGTERM and SIGKILL in `kill_process_tree/1` — time
  # for a well-behaved process to flush and exit before the hard kill.
  # Overridable for tests via the app env `:kill_grace_ms` (a test-only
  # CALL-TIME seam; the production default below is unchanged).
  @kill_grace_ms 100
  # ---------------------------------------------------------------------------
  # Shell escaping
  # ---------------------------------------------------------------------------

  @doc """
  POSIX-safe shell escaping for a single argument.

  Wraps the argument in single quotes and replaces every literal single-quote
  with the standard `\\''` escape sequence. This is **security-sensitive** — it
  is used to prevent command injection when assembling shell command strings
  (e.g. `bash -c "<escaped-cmd>"`).

  All sandbox backends and `EvoGit.Nix` share this single implementation so
  that the escaping logic is defined in exactly one place.
  """
  @spec shell_escape(String.t()) :: String.t()
  def shell_escape(arg) do
    "'" <> String.replace(arg, "'", "'\\''") <> "'"
  end

  # ---------------------------------------------------------------------------
  # Output truncation (for large command outputs)
  # ---------------------------------------------------------------------------

  @doc """
  Truncates a binary to fit within `max_bytes`, keeping the first and last
  portions so that both the beginning and end of the output remain visible.

  - When `max_bytes` is `nil`, the binary is returned unchanged (no truncation).
  - When the binary is at most `max_bytes` bytes, it is returned unchanged.
  - When the binary exceeds `max_bytes` but is at most `#{@truncate_size}`
    bytes, it is returned unchanged (not worth truncating such a small amount).
  - Otherwise, the first and last `#{@truncate_size |> div(2)}` bytes are kept
    with a truncation notice in between.

  This is used both for in-memory truncation (e.g. `run_with_partial` on
  Windows where output comes directly from `System.cmd` rather than a temp
  file) and indirectly by `read_tempfile/2`.
  """
  @spec truncate_output(binary(), integer() | nil) :: binary()
  def truncate_output(output, max_bytes) do
    size = byte_size(output)

    cond do
      is_nil(max_bytes) or size <= max_bytes ->
        output

      size <= @truncate_size ->
        output

      true ->
        half_size = div(@truncate_size, 2)
        # UTF-8-safe truncation via String.byte_slice/3: the stdlib works on
        # bytes and then adjusts to eliminate truncated codepoints, avoiding
        # invalid UTF-8 that crashes Jason.encode! downstream.
        first_part = String.byte_slice(output, 0, half_size)
        last_part = String.byte_slice(output, -half_size, half_size)
        omitted = size - @truncate_size
        format_truncation_notice(first_part, last_part, omitted, max_bytes)
    end
  end

  # Shared truncation message formatting used by both truncate_output/2
  # (in-memory binary_part) and read_truncated/3 (disk reads via :file.pread).
  defp format_truncation_notice(first_part, last_part, omitted, max_bytes) do
    """
    [WARNING: Output exceeded #{max_bytes} bytes and was truncated to #{@truncate_size} bytes]
    The output was too large. Consider using more specific arguments
    or alternative tools to retrieve only the needed portion of data.
    #{first_part}
    ... [#{omitted} bytes omitted] ...
    #{last_part}
    """
    |> String.trim()
  end

  @doc """
  Reads content from a temp file and deletes it.

  Returns an empty string if the file does not exist or cannot be read.

  ## Options

    * `max_bytes` — when `nil`, reads the entire file. When set and the file
      exceeds this size, reads only the first and last portions (never loading
      the entire file into memory).
  """
  @spec read_tempfile(Path.t(), integer() | nil) :: String.t()
  def read_tempfile(path, max_bytes) do
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
  # positioned reads and :raw/:binary mode for speed. The truncation notice is
  # formatted by the shared `format_truncation_notice/4` helper.
  defp read_truncated(path, file_size, max_bytes) do
    if file_size <= @truncate_size do
      case File.read(path) do
        {:ok, data} -> data
        {:error, _} -> ""
      end
    else
      half_size = div(@truncate_size, 2)
      omitted = file_size - @truncate_size

      {:ok, device} = File.open(path, [:read, :raw, :binary])

      {:ok, raw_first} = :file.pread(device, 0, half_size)
      {:ok, raw_last} = :file.pread(device, file_size - half_size, half_size)

      File.close(device)

      # The pread byte boundaries may split multi-byte UTF-8 codepoints.
      # Run each part through String.byte_slice/3 so the result is always
      # valid UTF-8 before formatting the truncation notice.
      first_part = String.byte_slice(raw_first, 0, byte_size(raw_first))
      last_part = String.byte_slice(raw_last, -byte_size(raw_last), byte_size(raw_last))

      format_truncation_notice(first_part, last_part, omitted, max_bytes)
    end
  end

  # ---------------------------------------------------------------------------
  # Writable-path resolution (for sandbox backends)
  # ---------------------------------------------------------------------------

  @doc """
  Resolves the writable-path (cache-dir) list to absolute paths.

  Called by `EvoGit.Sandbox.Spec.build/2` only, to apply the user-configurable
  `[sandbox] write_paths` list:

    * `config_paths == nil` (config unset) → the provided `defaults` list
      (`Spec.default_cache_dirs/0`) joined to `home`.
    * `config_paths` set (even `[]`) → the user's list REPLACES the default
      cache-dir list; `[]` means no cache-dir write paths at all.

  Path convention for user entries:

    * `~`-prefixed entries expand to `home` (`System.user_home!()`), e.g.
      `~/cache` → `<home>/cache`, bare `~` → `<home>`
    * absolute entries (leading `/`) are used as-is
    * relative entries are joined to `home` — the same base the defaults use

  `Path.expand` is deliberately NOT used: on entries containing `$HOME` env
  substitution (e.g. `$HOME/.cache`) it would treat the literal `$HOME` text
  as a directory name. Env substitutions are NOT expanded — such entries are
  handled like any relative path.
  """
  @spec resolve_write_paths([String.t()] | nil, [String.t()], String.t()) :: [String.t()]
  def resolve_write_paths(nil, defaults, home),
    do: Enum.map(defaults, &Path.join(home, &1))

  def resolve_write_paths(paths, _defaults, home) do
    Enum.map(paths, fn
      "~" <> rest -> Path.join(home, String.trim_leading(rest, "/"))
      "/" <> _ = path -> path
      path -> Path.join(home, path)
    end)
  end

  @doc """
  Returns the managed per-task tmpdir that must ALSO be granted write access
  inside the sandbox, or `nil` when no per-task dir is installed on the
  calling process (`EvoGit.TaskTmpdir.current/0`).

  This is an ADDITIONAL writable path: the system tmp dirs
  (`EvoGit.Platform.tmp_paths/0`) stay writable regardless. Shared by every
  backend so the derivation lives in exactly one place.
  """
  @spec task_tmpdir_path() :: String.t() | nil
  def task_tmpdir_path do
    case EvoGit.TaskTmpdir.current() do
      path when is_binary(path) and path != "" -> path
      _ -> nil
    end
  end

  @doc """
  Returns the environment overrides that point the child process at the
  managed per-task tmpdir, or `[]` when no per-task dir is installed on the
  calling process.

  Shape when installed:

      [{"TMPDIR", dir}, {"TMP", dir}, {"TEMP", dir}]

  `TMPDIR` is the POSIX convention, `TMP`/`TEMP` the Windows ones — all three
  resolve to the SAME managed dir so a spawned command picks it up on every
  platform.

  This is an **ADDITIONAL** env override, never a replacement for the system
  tmp dirs (`/tmp`, `/var/tmp`, Windows temp): commands remain free to use the
  host temp locations, and the sandbox backends keep those paths writable
  regardless.

  It is the single shared source for the non-sandboxed / disabled execution
  paths — the sandbox-enabled paths inject the same value via their own
  `--setenv`/`env:` mechanism. Derivation delegates to `task_tmpdir_path/0`
  (no duplication). Pure and unit-testable.
  """
  @spec temp_env_vars() :: [{String.t(), String.t()}]
  def temp_env_vars do
    case task_tmpdir_path() do
      dir when is_binary(dir) -> [{"TMPDIR", dir}, {"TMP", dir}, {"TEMP", dir}]
      nil -> []
    end
  end

  @doc """
  Converts an env list into the charlist shape `Port.open/2`'s `{:env, ...}`
  option requires.

  `:erlang.open_port/2` demands **charlists** for BOTH the name and the value
  of every `{:env, [{name, value}]}` pair — an Elixir binary anywhere in an env
  tuple makes the WHOLE option list invalid and `Port.open/2` raises
  `ArgumentError` ("invalid option in list"). `System.cmd/3` converts env pairs
  itself, so code paths that go through `System.cmd/3` never hit this; a raw
  `Port.open/2` must convert at the port boundary. This helper is that boundary.

  Accepted name/value inputs:

    * binary → `String.to_charlist/1`
    * atom → `Atom.to_charlist/1`
    * integer value → `Integer.to_charlist/1`
    * charlist → passed through unchanged

  Example:

      iex> EvoGit.Sandbox.Helpers.port_env([{"TMPDIR", "/tmp/x"}])
      [{~c"TMPDIR", ~c"/tmp/x"}]

  Pure and unit-testable.
  """
  @spec port_env([{String.t() | atom(), String.t() | atom() | integer()}]) :: [
          {charlist(), charlist()}
        ]
  def port_env(env) when is_list(env) do
    Enum.map(env, fn {name, value} -> {env_name(name), env_value(value)} end)
  end

  defp env_name(name) when is_binary(name), do: String.to_charlist(name)
  defp env_name(name) when is_atom(name), do: Atom.to_charlist(name)
  defp env_name(name) when is_list(name), do: name

  defp env_value(value) when is_binary(value), do: String.to_charlist(value)
  defp env_value(value) when is_atom(value), do: Atom.to_charlist(value)
  defp env_value(value) when is_integer(value), do: Integer.to_charlist(value)
  defp env_value(value) when is_list(value), do: value

  # ---------------------------------------------------------------------------
  # Git metadata resolution (linked-worktree gitdir: pointer handling)
  # ---------------------------------------------------------------------------

  @doc """
  Resolves the git metadata directory a sandbox must grant read+write access
  to. Returns `nil` when no git metadata dir should be exposed.

  - `base = repo_root || cwd`; `literal = Path.join(base, ".git")`.
  - If `literal` is a FILE, it is a linked-worktree pointer (a
    `gitdir: <path>` line as produced by `git worktree add`). The pointer
    target is the per-worktree metadata dir (`<common>/worktrees/<name>`);
    git also needs the COMMON dir (objects/refs/logs/packed-refs/config),
    so the prefix before the LAST "/worktrees/" segment is returned (a
    subpath rule on the common dir covers the per-worktree dir inside it).
    A pointer without a "/worktrees/" segment resolves to itself.
  - Otherwise (`.git` is a real directory, or missing):
    - repo_root given → the literal `<repo_root>/.git`.
    - repo_root nil → nil, UNLESS the literal is an existing directory
      (cwd IS a repo with a real `.git` — e.g. the skills executor passing
      cwd = worktree and repo_root = nil).

  Shared by the macOS (SBPL subpath rule) and bwrap (per-path writable bind)
  backends — their pointer resolution is byte-identical.
  """
  @spec git_metadata_dir(String.t(), String.t() | nil) :: String.t() | nil
  def git_metadata_dir(cwd, repo_root) do
    base = repo_root || cwd
    literal = Path.join(base, ".git")

    case File.read(literal) do
      {:ok, content} -> parse_gitdir_pointer(content, base, literal)
      {:error, _} -> if repo_root || File.dir?(literal), do: literal, else: nil
    end
  end

  @doc """
  Parses a linked-worktree `.git` pointer file. Finds the first line
  starting with "gitdir:", strips the prefix, trims whitespace; empty or
  missing → unparseable → falls back to `literal`. The resolved target is
  expanded relative to `base` when not absolute, then reduced to the common
  git dir (prefix before the last "/worktrees/" segment — `binary_part` on
  the last match start, NOT `String.split` with parts: 2, which is wrong
  when the repo path itself contains "/worktrees/").
  """
  @spec parse_gitdir_pointer(String.t(), String.t(), String.t()) :: String.t()
  def parse_gitdir_pointer(content, base, literal) do
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

  # ---------------------------------------------------------------------------
  # Partial-output temp files (run_with_partial timeout recovery)
  # ---------------------------------------------------------------------------

  @doc """
  Creates the shared `genesis_partial_outputs` directory under
  `EvoGit.Sandbox.resolve_tmpdir/0` (if needed) and returns a fresh unique
  temp file path inside it.

  Used by every backend's `run_with_partial/6` to redirect the command's
  stdout/stderr so partial output can be recovered on timeout.
  """
  @spec partial_output_tmpfile() :: Path.t()
  def partial_output_tmpfile do
    tmpdir = Path.join(EvoGit.Sandbox.resolve_tmpdir(), "genesis_partial_outputs")
    File.mkdir_p!(tmpdir)

    Path.join(tmpdir, "#{System.monotonic_time()}_#{System.unique_integer([:positive])}")
  end

  # ---------------------------------------------------------------------------
  # Shell command building (bash -c string assembly)
  # ---------------------------------------------------------------------------

  @doc """
  Builds the `bash -c` command string for `executable` + `args`: every element
  shell-escaped and joined with single spaces (the exact `Enum.map_join`
  shape used by all Unix sandbox backends).
  """
  @spec build_shell_command(String.t(), [String.t()]) :: String.t()
  def build_shell_command(executable, args) do
    Enum.map_join([executable | args], " ", &shell_escape/1)
  end

  @doc """
  Builds a `bash -c` command string that redirects stdout/stderr to `tmpfile`
  and stdin from `/dev/null` — the `run_with_partial/6` wrapping used by every
  Unix sandbox backend:

      <escaped executable + args> > <escaped tmpfile> 2>&1 < /dev/null
  """
  @spec build_redirected_command(String.t(), [String.t()], Path.t()) :: String.t()
  def build_redirected_command(executable, args, tmpfile) do
    build_shell_command(executable, args) <>
      " > " <> shell_escape(tmpfile) <> " 2>&1 < /dev/null"
  end

  # ---------------------------------------------------------------------------
  # Timed command execution (directly owned port + partial-output recovery)
  # ---------------------------------------------------------------------------

  @doc """
  Runs `exec` + `exec_args` (a `bash -c` wrapped command) through a directly
  owned `Port` with a `timeout`, recovering partial output from `tmpfile`
  (created beforehand via `partial_output_tmpfile/0`) when the timeout fires.

  Shared tail of every backend's `run_with_partial/7` non-sandbox / Unix path
  (linux/bwrap/macos disabled paths and the `None` backend's Unix path — which
  passes nix-wrapped `exec`/`exec_args`). `run_tracked_command/7` is the same
  primitive reused by the macOS `sandbox-exec` enabled path.

  **Why a port instead of `System.cmd/3`**: the child is spawned directly
  (`Port.open({:spawn_executable, …})` with `System.cmd`'s option set), so its
  real OS pid is readable via `Port.info(port, :os_pid)` and published to the
  tracked execution (`opts` `:execution_id`, a no-op otherwise) BEFORE the wait.
  That makes foreground executions observable (CPU/memory stats) and
  controllable (pause/resume/signal) and lets the timeout path kill the whole
  process TREE rather than only a wrapper process.

  The command's stdout/stderr go to `tmpfile` via the caller's
  `build_redirected_command/3` wrapping, so port data messages are drained and
  deliberately discarded; only the exit status is awaited.

  `opts` is the observability option list (`:execution_id` addresses the
  tracked record; `:record_exit_status`, default `true`, suppresses the
  terminal-fact recording for a command that will be re-run);
  `backend` names the sandbox backend module for the handle's diagnostics.

  Returns:
    * `{:ok, output, exit_code}` — command completed within timeout
    * `{:timeout, partial_output}` — command timed out; partial_output may be empty
  """
  @spec run_task_with_partial(
          String.t(),
          [String.t()],
          String.t(),
          [{String.t(), String.t()}],
          pos_integer(),
          Path.t(),
          integer() | nil,
          keyword(),
          module() | nil
        ) ::
          {:ok, String.t(), non_neg_integer()} | {:timeout, String.t()}
  def run_task_with_partial(
        exec,
        exec_args,
        cwd,
        env,
        timeout,
        tmpfile,
        max_bytes,
        opts \\ [],
        backend \\ nil
      ) do
    case run_tracked_command(exec, exec_args, cwd, env, timeout, opts, backend) do
      {:ok, exit_code} ->
        content = read_tempfile(tmpfile, max_bytes)
        {:ok, content, exit_code}

      {:timeout, :killed} ->
        partial = read_tempfile(tmpfile, max_bytes)
        {:timeout, partial <> "\n[TRUNCATED due to timeout]"}
    end
  end

  @doc """
  Spawns `exec` + `exec_args` as a directly owned port, attaches the child's
  real OS pid to the tracked execution (when `opts` carries an
  `:execution_id`), and waits up to `timeout` for the exit status.

  The port is opened with `System.cmd/3`'s own option set (`:binary`,
  `:exit_status`, `:hide`, `:stderr_to_stdout`, `{:args, …}`, `{:cd, …}` and a
  `Helpers.port_env/1`-converted `{:env, …}` — `Port.open/2` requires charlist
  env pairs). `exec` is resolved first (`EvoGit.Sandbox.None.resolve_executable/1`,
  binary-safe and PATH-searching); an unresolvable name raises `:enoent`, the
  same `ErlangError` `System.cmd/3` reports.

  Data messages are drained and discarded, so a caller whose command does NOT
  redirect its output would lose it — this helper is for the redirected
  `run_with_partial` shape, where only the exit status matters. On timeout the
  whole process TREE is killed (`kill_process_tree/1` on the OS pid) and the
  port is closed/drained, so a wedged child cannot outlive the call.

  The observed status is recorded as the tracked execution's terminal fact —
  `record_exit/2` on completion, `record_timeout/1` on the timeout (AFTER the
  tree kill, so the recorded status is truthful); `:record_exit_status: false`
  in `opts` suppresses it for a command that will be re-run.

  Returns `{:ok, exit_code}` or `{:timeout, :killed}`.
  """
  @spec run_tracked_command(
          String.t(),
          [String.t()],
          String.t(),
          [{String.t(), String.t()}],
          pos_integer(),
          keyword(),
          module() | nil
        ) :: {:ok, integer()} | {:timeout, :killed}
  def run_tracked_command(exec, exec_args, cwd, env, timeout, opts \\ [], backend \\ nil) do
    {port, os_pid} = spawn_tracked_port(exec, exec_args, cwd, env, opts, backend)
    deadline = System.monotonic_time(:millisecond) + timeout

    result =
      case await_exit_status(port, deadline) do
        {:ok, exit_code} ->
          {:ok, exit_code}

        :timeout ->
          # The child may hold a whole tree (bash -c → command). Kill the tree
          # first (a no-op when the pid never materialized), then close the port.
          kill_process_tree(os_pid)
          close_port(port)
          drain_port_messages(port)
          {:timeout, :killed}
      end

    record_result(opts, result)
  end

  # Spawns the executable through a directly owned port and publishes its OS pid
  # (when the execution is tracked). `:undefined` (the pid never materialized)
  # is normalized to nil by `Handle.new/2`, leaving the execution with degraded
  # stats exactly as before.
  defp spawn_tracked_port(exec, exec_args, cwd, env, opts, backend) do
    exec =
      case EvoGit.Sandbox.None.resolve_executable(exec) do
        nil -> :erlang.error(:enoent, [exec, exec_args, cwd])
        resolved -> resolved
      end

    port =
      Port.open(
        {:spawn_executable, exec},
        [:binary, :exit_status, :hide, :stderr_to_stdout] ++
          [{:args, exec_args}, {:cd, cwd}] ++ env_option(env)
      )

    os_pid = wait_for_os_pid(port)
    attach_execution(opts, :posix, os_pid: os_pid, backend: backend)
    {port, os_pid}
  end

  # `Port.open/2` needs CHARLISTS in `{:env, …}`; an empty env is omitted
  # entirely (passing `{:env, []}` is valid but pointless).
  defp env_option([]), do: []
  defp env_option(env), do: [{:env, port_env(env)}]

  # Waits for THIS port's exit status until the monotonic deadline, discarding
  # data messages (the command's output goes to its own redirect target).
  defp await_exit_status(port, deadline) do
    remaining = max(deadline - System.monotonic_time(:millisecond), 0)

    receive do
      {^port, {:data, _data}} ->
        await_exit_status(port, deadline)

      {^port, {:exit_status, exit_code}} ->
        {:ok, exit_code}
    after
      remaining ->
        # A status already delivered to the mailbox still wins: `receive`
        # matches queued messages BEFORE its `after` timeout fires.
        receive do
          {^port, {:exit_status, exit_code}} -> {:ok, exit_code}
        after
          0 -> :timeout
        end
    end
  end

  # ---------------------------------------------------------------------------
  # Execution tracking (best-effort, observability-only)
  # ---------------------------------------------------------------------------

  @doc """
  Best-effort attachment of a real OS handle to a live tracked execution.

  `opts` is a sandbox `run_with_partial/7` option list; the only key read is
  `:execution_id` (`"proc-<n>"`, the record created by
  `EvoGit.ProcessManager.track/3`). When it is absent/nil this is a no-op and no
  handle is built.

  `kind`/`attrs` are handed to `EvoGit.ProcessManager.Handle.new/2`, so callers
  pass the addressing facts they actually know — `unit:` for a transient
  systemd unit, `os_pid:` for a raw process (`:undefined`/nil normalizes to
  nil, and the execution's stats then degrade to nil fields), `backend:` for
  diagnostics.

  Total by construction: a missing or restarting manager, or a handle the
  registry does not accept, can never fail or slow the command being tracked.
  """
  @spec attach_execution(keyword() | nil, EvoGit.ProcessManager.Handle.kind(), keyword()) :: :ok
  def attach_execution(opts, kind, attrs \\ []) do
    case execution_id(opts) do
      id when is_binary(id) ->
        EvoGit.ProcessManager.attach(id, EvoGit.ProcessManager.Handle.new(kind, attrs))

      _ ->
        :ok
    end
  rescue
    _ -> :ok
  catch
    _kind, _reason -> :ok
  end

  @doc """
  Best-effort terminal fact for a command that RAN to completion: the tracked
  execution is finished `:completed` with `reason: :exited` and the real OS
  `exit_code` — a non-zero code still means the tool call itself succeeded.

  `exit_code` degrades to `nil` when the backend could not observe one. No-op
  without an `:execution_id`; total by construction, so observability can never
  change a command result.
  """
  @spec record_exit(keyword() | nil, integer() | nil) :: :ok
  def record_exit(opts, exit_code) do
    finish_execution(opts, :completed,
      exit_code: normalize_exit_code(exit_code),
      reason: :exited
    )
  end

  @doc """
  Best-effort terminal fact for a command that exhausted its timeout budget: the
  tracked execution is finished `:killed` with `reason: :timeout` and no exit
  code. No-op without an `:execution_id`; total by construction.
  """
  @spec record_timeout(keyword() | nil) :: :ok
  def record_timeout(opts) do
    finish_execution(opts, :killed, exit_code: nil, reason: :timeout)
  end

  # The ONE settlement call in the sandbox layer: every backend records its
  # terminal fact through this funnel, so the finish option shape lives here.
  defp finish_execution(opts, status, finish_opts) do
    case execution_id(opts) do
      id when is_binary(id) -> EvoGit.ProcessManager.finish(id, status, finish_opts)
      _ -> :ok
    end
  rescue
    _ -> :ok
  catch
    _kind, _reason -> :ok
  end

  defp normalize_exit_code(code) when is_integer(code), do: code
  defp normalize_exit_code(_code), do: nil

  # Records a command RESULT so call sites stay one-liners; returns the result
  # untouched. `:record_exit_status` (default true) suppresses the recording for
  # a command a caller will RE-RUN (the macOS process-limit retry), so only the
  # FINAL attempt's status becomes the execution's outcome.
  defp record_result(opts, result) do
    if record_exit_status?(opts) do
      case result do
        {:ok, {_output, exit_code}} -> record_exit(opts, exit_code)
        {:ok, exit_code} -> record_exit(opts, exit_code)
        {:timeout, _partial} -> record_timeout(opts)
        _other -> :ok
      end
    end

    result
  end

  defp record_exit_status?(opts) when is_list(opts),
    do: Keyword.get(opts, :record_exit_status, true) != false

  defp record_exit_status?(_opts), do: true

  defp execution_id(opts) when is_list(opts), do: Keyword.get(opts, :execution_id)
  defp execution_id(_opts), do: nil

  # ---------------------------------------------------------------------------
  # Port helpers (direct Port ownership in run_with_partial enabled paths)
  # ---------------------------------------------------------------------------

  @doc """
  Waits for the OS PID of a spawned port to materialize (it is populated
  asynchronously after spawn). `Port.info(port, :os_pid)` returns the tuple
  `{:os_pid, pid}` while the port is open (and `nil` once it is closed), so
  this helper unwraps that tuple and returns the integer pid. Polls briefly;
  falls back to `:undefined` when it never appears — the caller's timeout path
  then degrades to closing the port (group/process-tree kill skipped).
  """
  @spec wait_for_os_pid(port(), non_neg_integer()) :: pos_integer() | :undefined
  def wait_for_os_pid(port, attempts \\ 10) do
    case Port.info(port, :os_pid) do
      {:os_pid, pid} when is_integer(pid) ->
        pid

      _ when attempts > 0 ->
        Process.sleep(10)
        wait_for_os_pid(port, attempts - 1)

      _ ->
        :undefined
    end
  end

  @doc """
  After `Port.close/1`, messages already delivered stay in the calling
  process's mailbox; drain them so they cannot be matched by later receives.
  """
  @spec drain_port_messages(port()) :: :ok
  def drain_port_messages(port) do
    receive do
      {^port, _message} -> drain_port_messages(port)
    after
      0 -> :ok
    end
  end

  @doc """
  Idempotently closes a port. `Port.close/1` RAISES `ArgumentError` on an
  already-closed port (e.g. after `{:exit_status, _}` has been delivered), so
  every timeout path closes through this guard instead of a bare
  `Port.close/1`. A `nil` port is a no-op.
  """
  @spec close_port(port() | nil) :: :ok
  def close_port(nil), do: :ok

  def close_port(port) when is_port(port) do
    if Port.info(port) != nil, do: Port.close(port)
    :ok
  end

  # ---------------------------------------------------------------------------
  # Process-tree termination (background / detached jobs)
  # ---------------------------------------------------------------------------

  @doc """
  Kills a whole process TREE, given the pid of its session/process-group
  leader. Total: never raises and always returns `:ok` — every failure (missing
  `kill`/`taskkill` binary, already-dead pid, permission denied) is swallowed
  because termination is best-effort and the caller (a background-job registry)
  must not crash on it.

  POSIX: `pid` is expected to be BOTH the session leader and the process-group
  id — the shapes produced by `Port.open({:spawn_executable, ...})` (each child
  gets its own process group) and by `bwrap --new-session` (bwrap `setsid`s
  before forking, so its pid IS the pgid) both satisfy this. Signals the GROUP
  (`kill -TERM -- -<pgid>`, 100 ms grace, then `kill -KILL -- -<pgid>`) and
  falls back to signalling the bare pid when the group is already gone.

  Windows: `taskkill /PID <pid> /T /F`, which walks the pid's CURRENT
  descendants (cmd.exe / powershell grandchildren included). The blast radius is
  strictly descendant-only, so it can never reach the BEAM (the child's parent).
  """
  @spec kill_process_tree(pos_integer() | nil) :: :ok
  def kill_process_tree(pid) when is_integer(pid) do
    try do
      if EvoGit.Platform.windows?() do
        run_kill("taskkill", ["/PID", Integer.to_string(pid), "/T", "/F"])
      else
        posix_kill_tree(Integer.to_string(pid))
      end
    rescue
      _ -> :ok
    catch
      _, _ -> :ok
    end
  end

  def kill_process_tree(_), do: :ok

  # TERM the group, grace period, then KILL the group; when the group is
  # already gone (kill exits non-zero) escalate on the bare pid instead.
  defp posix_kill_tree(pid) do
    case run_kill("kill", ["-TERM", "--", "-" <> pid]) do
      :ok ->
        Process.sleep(kill_grace_ms())
        run_kill("kill", ["-KILL", "--", "-" <> pid])

      :error ->
        run_kill("kill", ["-TERM", "--", pid])
        Process.sleep(kill_grace_ms())
        run_kill("kill", ["-KILL", "--", pid])
    end

    :ok
  end

  # Test-only CALL-TIME override (`:kill_grace_ms`); the production default
  # `@kill_grace_ms` is unchanged.
  defp kill_grace_ms do
    case Application.get_env(:evo_git, :kill_grace_ms, @kill_grace_ms) do
      ms when is_integer(ms) and ms >= 0 -> ms
      _other -> @kill_grace_ms
    end
  end

  # Runs a kill primitive and reports only whether the exit code was 0. The
  # output is deliberately discarded — `kill` diagnostics are not actionable.
  defp run_kill(cmd, args) do
    case System.cmd(cmd, args, stderr_to_stdout: true) do
      {_output, 0} -> :ok
      {_output, _code} -> :error
    end
  end

  # ---------------------------------------------------------------------------
  # Sandbox mode resolution
  # ---------------------------------------------------------------------------

  @doc """
  Resolves the `[sandbox] mode` config value to an enabled boolean:

    * `:enabled` → `true`
    * `:disabled` → `false`
    * `:auto` → the result of `auto_available?.()` — the caller's platform
      availability check for the `:auto` fallback

  Shared by the Linux backend and the systemd lifecycle modules
  (`SandboxSlice`/`SandboxProcessRegistry`), whose `:auto` arms are identical
  (`EvoGit.Platform.systemd_available?/0`).
  """
  @spec sandbox_mode_enabled?((-> boolean())) :: boolean()
  def sandbox_mode_enabled?(auto_available?) do
    case EvoGit.Config.resolve([:sandbox, :mode]) do
      :enabled -> true
      :disabled -> false
      :auto -> auto_available?.()
    end
  end

  # ---------------------------------------------------------------------------
  # Command execution (for SandboxSlice / SandboxProcessRegistry)
  # ---------------------------------------------------------------------------

  @doc """
  Runs a `System.cmd/3` and normalizes the result into `{:ok, output}` or
  `{:error, output}`.

  `System.cmd/3` raises `ErlangError(:enoent)` when the binary is missing; this
  function pre-checks executability via `System.find_executable/1` to avoid the
  exception and return an `{:error, ...}` tuple instead.
  """
  @spec system_cmd(String.t(), [String.t()]) :: {:ok, String.t()} | {:error, String.t()}
  def system_cmd(cmd, args) do
    if System.find_executable(cmd) do
      case System.cmd(cmd, args, stderr_to_stdout: true) do
        {output, 0} -> {:ok, output}
        {output, _code} -> {:error, output}
      end
    else
      {:error, "command not found: #{cmd}"}
    end
  end
end
