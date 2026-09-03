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

  Shared by the Linux and macOS sandbox backends to apply the user-configurable
  `[sandbox] write_paths` list:

    * `config_paths == nil` (config unset) → the provided `defaults` list (each
      backend's built-in `@default_cache_dirs`) joined to `home` — byte-identical
      to the historical hard-coded output.
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
  # Timed command execution (Task + partial-output recovery)
  # ---------------------------------------------------------------------------

  @doc """
  Runs `exec` + `exec_args` (a `bash -c` wrapped command) in a `Task` with a
  `timeout`, recovering partial output from `tmpfile` (created beforehand via
  `partial_output_tmpfile/0`) when the timeout fires.

  Shared tail of every backend's `run_with_partial/6` non-sandbox / Unix path
  (linux/bwrap/macos disabled paths + the `None` backend's Unix path, which
  passes nix-wrapped `exec`/`exec_args`).

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
          integer() | nil
        ) ::
          {:ok, String.t(), non_neg_integer()} | {:timeout, String.t()}
  def run_task_with_partial(exec, exec_args, cwd, env, timeout, tmpfile, max_bytes) do
    task =
      Task.async(fn ->
        System.cmd(exec, exec_args,
          cd: cwd,
          stderr_to_stdout: true,
          env: env
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

  # ---------------------------------------------------------------------------
  # Port helpers (direct Port ownership in run_with_partial enabled paths)
  # ---------------------------------------------------------------------------

  @doc """
  Waits for the OS PID of a spawned port to materialize (it is populated
  asynchronously after spawn). Polls briefly; falls back to `:undefined` when
  it never appears — the caller's timeout path then degrades to closing the
  port (group/process-tree kill skipped).
  """
  @spec wait_for_os_pid(port(), non_neg_integer()) :: pos_integer() | :undefined
  def wait_for_os_pid(port, attempts \\ 10) do
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
