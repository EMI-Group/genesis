defmodule EvoGit.Platform do
  @moduledoc """
  Platform detection utilities for cross-platform support.

  Detects the current operating system and provides helpers for
  platform-specific behavior throughout EvoGit.
  """

  @type os :: :linux | :macos | :windows | :unknown

  @doc """
  Detects the current operating system.

  Returns one of:
  - `:linux` - Linux-based systems
  - `:macos` - macOS / Darwin
  - `:windows` - Windows (including WSL detection as Linux, not Windows)
  - `:unknown` - Unable to determine
  """
  @spec os() :: os()
  def os do
    case :os.type() do
      {:unix, :darwin} -> :macos
      {:unix, _} -> :linux
      {:win32, _} -> :windows
    end
  end

  @doc """
  Returns true if the current platform is Linux.
  """
  @spec linux?() :: boolean()
  def linux?, do: os() == :linux

  @doc """
  Returns true if the current platform is macOS.
  """
  @spec macos?() :: boolean()
  def macos?, do: os() == :macos

  @doc """
  Returns true if the current platform is Windows.
  """
  @spec windows?() :: boolean()
  def windows?, do: os() == :windows

  @doc """
  Returns the shell executable used by the shell tools.

  Resolves the `[:tools, :shell]` config key first (see `EvoGit.Config`); when
  it is set to a non-empty string, that shell is used. Otherwise falls back to
  the platform default:

  - Linux/macOS: `"bash"`
  - Windows: `"powershell"`
  """
  @spec shell() :: String.t()
  def shell do
    case EvoGit.Config.resolve([:tools, :shell]) do
      shell when is_binary(shell) and shell != "" -> shell
      _ -> default_shell()
    end
  end

  defp default_shell do
    case os() do
      :windows -> "powershell"
      _ -> "bash"
    end
  end

  @doc """
  Returns the shell arguments to execute a command string.

  The invocation shape is chosen from the EFFECTIVE shell — what `shell/0`
  returns, which honors the `[:tools, :shell]` config override:

  - PowerShell executables (`powershell`, `pwsh`, ...): `-EncodedCommand`
    arguments via `EvoGit.Powershell.invoke_args/1`.
  - POSIX shells (`bash`, `sh`, `zsh`, ...): `["-c", command]`.

  On Windows with PowerShell the script is base64-encoded as UTF-16LE and passed
  via `-EncodedCommand`, which eliminates PowerShell's `-Command` command-line
  re-parsing (broken by construction when spawned from Erlang) and its
  interactive-mode fallback on lost arguments, and forces UTF-8 output.
  See `EvoGit.Powershell` for details.
  """
  @spec shell_args(String.t()) :: [String.t()]
  def shell_args(command) do
    if EvoGit.Powershell.powershell_executable?(shell()) do
      EvoGit.Powershell.invoke_args(command)
    else
      ["-c", command]
    end
  end

  @doc """
  Returns the system temporary directory in a platform-aware manner.

  Uses `System.tmp_dir!/1` which is cross-platform, but also provides
  the known temp paths for use in sandbox configuration.
  """
  @spec tmp_dir() :: String.t()
  def tmp_dir do
    System.tmp_dir!()
  end

  @doc """
  Returns the list of known temporary directory paths for the current platform.

  Used by the sandbox to configure ReadWritePaths.
  """
  @spec tmp_paths() :: [String.t()]
  def tmp_paths do
    case os() do
      :windows -> [System.tmp_dir!()]
      _ -> ["/tmp", "/var/tmp"]
    end
  end

  @doc """
  Returns the platform-appropriate data directory for EvoGit.

  - **Linux**: `$XDG_DATA_HOME/genesis` (defaults to `~/.local/share/genesis`)
  - **macOS**: `~/Library/Application Support/genesis`
  - **Windows**: `%APPDATA%/genesis` (defaults to `~/genesis` if APPDATA not set)
  """
  @spec data_dir() :: String.t()
  def data_dir, do: data_dir("genesis")

  @doc """
  Returns the platform-appropriate data directory for the given application name.

  The directory is not created automatically — callers should use `File.mkdir_p!/1`
  if needed.
  """
  @spec data_dir(String.t()) :: String.t()
  def data_dir(app_name) do
    base_dir(app_name, "XDG_DATA_HOME", ".local/share")
  end

  @doc """
  Returns the platform-appropriate config directory for EvoGit.

  - **Linux**: `$XDG_CONFIG_HOME/genesis` (defaults to `~/.config/genesis`)
  - **macOS**: `~/Library/Application Support/genesis`
  - **Windows**: `%APPDATA%/genesis` (defaults to `~/genesis` if APPDATA not set)
  """
  @spec config_dir() :: String.t()
  def config_dir, do: config_dir("genesis")

  @doc """
  Returns the platform-appropriate config directory for the given application name.

  The directory is not created automatically — callers should use `File.mkdir_p!/1`
  if needed.
  """
  @spec config_dir(String.t()) :: String.t()
  def config_dir(app_name) do
    base_dir(app_name, "XDG_CONFIG_HOME", ".config")
  end

  # Shared platform-directory resolution used by both `data_dir/1` and
  # `config_dir/1` — the four arms differ only in the XDG env var (and its
  # home-relative fallback subpath) on Linux/unknown platforms; macOS and
  # Windows are identical.
  defp base_dir(app_name, xdg_env, fallback_rel) do
    case os() do
      os when os in [:linux, :unknown] ->
        # XDG convention (Linux standard; fallback for unknown platforms)
        xdg = System.get_env(xdg_env)
        base = if xdg && xdg != "", do: xdg, else: Path.join(System.user_home!(), fallback_rel)
        Path.join(base, app_name)

      :macos ->
        Path.join([System.user_home!(), "Library", "Application Support", app_name])

      :windows ->
        appdata = System.get_env("APPDATA")
        base = if appdata && appdata != "", do: appdata, else: System.user_home!()
        Path.join(base, app_name)
    end
  end

  @doc """
  Returns true if `systemd-run` is likely available on this platform.

  Only returns true on Linux where systemd is the init system.
  """
  @spec systemd_available?() :: boolean()
  def systemd_available? do
    linux?() and System.find_executable("systemd-run") != nil
  end

  @doc """
  Returns true if `bwrap` (bubblewrap) is available on this platform.

  Only returns true on Linux where the `bwrap` binary is found in PATH.
  """
  @spec bwrap_available?() :: boolean()
  def bwrap_available? do
    linux?() and System.find_executable("bwrap") != nil
  end

  @doc """
  Returns true if the given path is an absolute path on any platform.
  Handles Unix paths (/foo), Windows drive-letter paths (C:\\foo, D:/bar),
  and UNC paths (\\\\server\\share and //server/share, e.g. WSL paths like
  //wsl.localhost/Ubuntu-22.04/...).
  """
  @spec absolute_path?(String.t()) :: boolean()
  def absolute_path?(path) when is_binary(path) do
    Path.type(path) == :absolute or windows_absolute_path?(path)
  end

  def absolute_path?(_other), do: false

  # Detects Windows-style absolute paths: drive letters (C:\\..., D:/...)
  # and UNC paths (\\\\server\\share\\... and //server/share/...).
  @windows_absolute_regex ~r/^[A-Za-z]:[\/\\]|^\\\\|^\/\//

  defp windows_absolute_path?(path) do
    String.match?(path, @windows_absolute_regex)
  end

  @doc """
  Returns true if the path starts with a double-separator UNC marker.

  UNC paths begin with `\\\\server\\share\\...` (Windows style) or
  `//server/share/...` (forward-slash style, e.g. WSL paths like
  `//wsl.localhost/Ubuntu-22.04/...`). Separators are normalized first, so
  mixed `\\/`-style prefixes are recognized too.

  Returns false for `nil` and non-binary values.
  """
  @spec unc?(String.t() | nil) :: boolean()
  def unc?(nil), do: false

  def unc?(path) when is_binary(path) do
    path |> normalize_separators() |> String.starts_with?("//")
  end

  def unc?(_other), do: false

  @doc """
  Returns true if the path has a UNC **share shape** — at least a server
  component and a share component after the double-separator marker, both
  non-empty.

  Distinct from `unc?/1`: `unc?/1` flags ANY double-separator prefix
  (`unc?("//foo")` → true), while `unc_path?/1` requires the
  `//server/share/...` shape (`unc_path?("//foo")` → false). Separators are
  normalized first, so both the Windows `\\\\server\\share\\...` and
  forward-slash `//server/share/...` (WSL) forms are recognized.

  This is the predicate used by the worktree-unsupported diagnostic
  (`EvoGit.Runtime.Helpers.validate_repo_path!/1`): a bare `//foo` with no
  share component is NOT flagged.

  Returns false for `nil` and non-binary values.
  """
  @spec unc_path?(String.t() | nil) :: boolean()
  def unc_path?(nil), do: false

  def unc_path?(path) when is_binary(path) do
    path |> normalize_separators() |> String.match?(~r{^//[^/]+/[^/]+})
  end

  def unc_path?(_other), do: false

  @doc """
  Like `Path.expand/1`, but preserves UNC path prefixes on non-Windows hosts.

  On Windows `Path.expand/1` keeps the `//` root of a UNC path, so this
  function delegates to it directly. On non-Windows hosts (where EvoGit
  commonly runs while operating on repos mounted at WSL/network UNC paths like
  `//wsl.localhost/Ubuntu-22.04/...`) `Path.expand/1` collapses the `//`
  prefix to a single `/`, corrupting the path. This function captures the
  original double-separator marker (`//` or `\\\\`), strips it, expands the
  remainder with `Path.expand/1`, and re-attaches the marker — so `.`/`..`
  components and trailing separators are still resolved while the UNC root
  survives.

  Non-UNC paths behave exactly like `Path.expand/1`.
  """
  @spec safe_expand(String.t()) :: String.t()
  def safe_expand(path) when is_binary(path) do
    if unc?(path) and not windows?() do
      marker = String.slice(path, 0, 2)
      rest = String.slice(path, 2..-1//1)

      # `Path.expand("/" <> rest)` resolves `..`/`.` and strips trailing
      # separators but keeps its own leading `/` — strip that before
      # re-attaching the marker so `//wsl...` never becomes `///wsl...`.
      marker <> (Path.expand("/" <> rest) |> trim_leading_separators())
    else
      Path.expand(path)
    end
  end

  @doc """
  Like `Path.expand/2`, but preserves a UNC `base` prefix on non-Windows hosts.

  When `base` is a UNC path and the host is not Windows, the (relative)
  `path` is resolved against the base with the double-separator marker
  preserved: `base_marker <> Path.expand(path, "/" <> base_rest)`. If `path`
  itself is absolute (per `absolute_path?/1`) it is expanded on its own,
  mirroring `Path.expand/2` semantics. On Windows or with a non-UNC base,
  delegates to `Path.expand/2`.
  """
  @spec safe_expand(String.t(), String.t()) :: String.t()
  def safe_expand(path, base) when is_binary(path) and is_binary(base) do
    cond do
      absolute_path?(path) ->
        safe_expand(path)

      unc?(base) and not windows?() ->
        marker = String.slice(base, 0, 2)
        base_rest = String.slice(base, 2..-1//1)

        # Same leading-separator strip as `safe_expand/1` so the re-attached
        # marker never produces a `///` root.
        marker <> (Path.expand(path, "/" <> base_rest) |> trim_leading_separators())

      true ->
        Path.expand(path, base)
    end
  end

  @doc """
  Returns true if `child_path` is equal to `parent_path` or is a sub-path of it.
  Handles both Unix and Windows path separators (/ and \\).
  """
  @spec path_under?(String.t(), String.t()) :: boolean()
  def path_under?(child_path, parent_path)
      when is_binary(child_path) and is_binary(parent_path) do
    child = normalize_separators(child_path)
    parent = normalize_separators(parent_path)
    child == parent or String.starts_with?(child, parent <> "/")
  end

  @doc """
  Returns true if the character at `prefix_len` in `path` is a path separator
  (either / or \\).
  """
  @spec path_next_is_separator?(String.t(), non_neg_integer()) :: boolean()
  def path_next_is_separator?(path, prefix_len) when is_binary(path) and is_integer(prefix_len) do
    case String.at(path, prefix_len) do
      nil -> false
      char -> char == "/" or char == "\\"
    end
  end

  @doc """
  Returns true if `nix` is available on the system.

  Returns true on any platform where the `nix` binary is found in PATH.
  """
  @spec nix_available?() :: boolean()
  def nix_available? do
    System.find_executable("nix") != nil
  end

  @doc """
  Returns true if `sandbox-exec` is available on this platform.

  Only returns true on macOS where sandbox-exec is found in PATH.
  """
  @spec sandbox_exec_available?() :: boolean()
  def sandbox_exec_available? do
    macos?() and System.find_executable("sandbox-exec") != nil
  end

  @doc """
  Returns the sandbox backend available on this platform.

  - `:systemd_run` — Linux with systemd
  - `:bwrap` — Linux with bubblewrap
  - `:sandbox_exec` — macOS with sandbox-exec
  - `:none` — Windows or unsupported platform
  """
  @spec sandbox_backend() :: :systemd_run | :bwrap | :sandbox_exec | :none
  def sandbox_backend do
    cond do
      systemd_available?() -> :systemd_run
      bwrap_available?() -> :bwrap
      sandbox_exec_available?() -> :sandbox_exec
      true -> :none
    end
  end

  # --- Cross-Platform Path Helpers ---

  @doc """
  Converts all backslash (`\\`) characters to forward slashes (`/`) for
  consistent internal path handling.

  Returns `nil` if given `nil`.
  """
  @spec normalize_separators(String.t() | nil) :: String.t() | nil
  def normalize_separators(nil), do: nil
  def normalize_separators(path) when is_binary(path), do: String.replace(path, "\\", "/")

  @doc """
  Strips leading `/` and `\\` characters from a path.

  UNC-aware: when the path begins with a double-separator UNC marker (`//` or
  `\\\\`, detected via `unc?/1`), the marker survives — only leading
  separators beyond the first two are trimmed (e.g.
  `trim_leading_separators("///x")` → `"//x"`,
  `trim_leading_separators("\\\\server\\share\\x")` → `"\\\\server\\share\\x"`).
  A single leading separator is still fully stripped (`"/foo"` → `"foo"`).

  Returns `nil` if given `nil`.
  """
  @spec trim_leading_separators(String.t() | nil) :: String.t() | nil
  def trim_leading_separators(nil), do: nil

  def trim_leading_separators(path) when is_binary(path) do
    if unc?(path) do
      <<marker::binary-size(2), rest::binary>> = path
      marker <> String.replace(rest, ~r/^[\/\\]+/, "")
    else
      String.replace(path, ~r/^[\/\\]+/, "")
    end
  end

  @doc """
  Strips trailing `/` and `\\` characters from a path.

  Returns `nil` if given `nil`.
  """
  @spec trim_trailing_separators(String.t() | nil) :: String.t() | nil
  def trim_trailing_separators(nil), do: nil

  def trim_trailing_separators(path) when is_binary(path) do
    String.replace(path, ~r/[\/\\]+$/, "")
  end

  @doc """
  Strips both leading and trailing `/` and `\\` characters from a path.

  Composed from `trim_leading_separators/1` and `trim_trailing_separators/1`.
  Returns `nil` if given `nil`.
  """
  @spec trim_separators(String.t() | nil) :: String.t() | nil
  def trim_separators(nil), do: nil

  def trim_separators(path) when is_binary(path) do
    path |> trim_leading_separators() |> trim_trailing_separators()
  end

  @doc """
  Splits a path on both `/` and `\\` separators.

  First normalizes all separators to `/` via `normalize_separators/1`, then
  delegates to `String.split/3` with `"/"` as the pattern. Accepts the same
  options as `String.split/3` (e.g., `parts: 2`).

  UNC-aware: when the path starts with the `//` UNC marker (after
  normalization), the marker is dropped before splitting so the first path
  element is the share host rather than a bogus empty segment
  (`split_path("//wsl.localhost/Ubuntu-22.04/x")` →
  `["wsl.localhost", "Ubuntu-22.04", "x"]`). Non-UNC behavior is unchanged
  (`split_path("/foo")` → `["", "foo"]`).

  Returns `nil` if given `nil`. Returns `[]` if given an empty string.
  """
  @spec split_path(String.t() | nil, keyword()) :: [String.t()] | nil
  def split_path(nil, _opts), do: nil
  def split_path("", _opts), do: []

  def split_path(path, opts) when is_binary(path) and is_list(opts) do
    path
    |> normalize_separators()
    |> drop_unc_root()
    |> String.split("/", opts)
  end

  # Drops the leading `//` UNC root marker (already normalized) so no bogus
  # empty leading segment is produced — a UNC path's first element is the
  # share host.
  defp drop_unc_root(normalized) do
    if String.starts_with?(normalized, "//") do
      String.slice(normalized, 2..-1//1)
    else
      normalized
    end
  end

  @doc """
  Returns `true` if the path ends with `/` or `\\`.

  Returns `false` if given `nil`.
  """
  @spec trailing_separator?(String.t() | nil) :: boolean()
  def trailing_separator?(nil), do: false

  def trailing_separator?(path) when is_binary(path) do
    String.ends_with?(path, "/") or String.ends_with?(path, "\\")
  end
end
