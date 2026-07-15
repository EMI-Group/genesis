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
  Returns the default shell executable for the current platform.

  - Linux/macOS: `"bash"`
  - Windows: `"powershell"`
  """
  @spec shell() :: String.t()
  def shell do
    case os() do
      :windows -> "powershell"
      _ -> "bash"
    end
  end

  @doc """
  Returns the shell arguments to execute a command string.

  - Linux/macOS: `["-c", command]`
  - Windows: `["-Command", command]`
  """
  @spec shell_args(String.t()) :: [String.t()]
  def shell_args(command) do
    case os() do
      :windows -> ["-Command", command]
      _ -> ["-c", command]
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
    case os() do
      os when os in [:linux, :unknown] ->
        # XDG convention (Linux standard; fallback for unknown platforms)
        xdg = System.get_env("XDG_DATA_HOME")
        base = if xdg && xdg != "", do: xdg, else: Path.join(System.user_home!(), ".local/share")
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
    case os() do
      os when os in [:linux, :unknown] ->
        # XDG convention (Linux standard; fallback for unknown platforms)
        xdg = System.get_env("XDG_CONFIG_HOME")
        base = if xdg && xdg != "", do: xdg, else: Path.join(System.user_home!(), ".config")
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
  Returns true if the given path is an absolute path on any platform.
  Handles Unix paths (/foo), Windows drive-letter paths (C:\\foo, D:/bar),
  and UNC paths (\\\\server\\share).
  """
  @spec absolute_path?(String.t()) :: boolean()
  def absolute_path?(path) when is_binary(path) do
    Path.type(path) == :absolute or windows_absolute_path?(path)
  end

  def absolute_path?(_other), do: false

  # Detects Windows-style absolute paths: drive letters (C:\\..., D:/...)
  # and UNC paths (\\\\server\\share\\...)
  @windows_absolute_regex ~r/^[A-Za-z]:[\/\\]|^\\\\/

  defp windows_absolute_path?(path) do
    String.match?(path, @windows_absolute_regex)
  end

  @doc """
  Returns true if `child_path` is equal to `parent_path` or is a sub-path of it.
  Handles both Unix and Windows path separators (/ and \\).
  """
  @spec path_under?(String.t(), String.t()) :: boolean()
  def path_under?(child_path, parent_path)
      when is_binary(child_path) and is_binary(parent_path) do
    child = String.replace(child_path, "\\", "/")
    parent = String.replace(parent_path, "\\", "/")
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
  - `:sandbox_exec` — macOS with sandbox-exec
  - `:none` — Windows or unsupported platform
  """
  @spec sandbox_backend() :: :systemd_run | :sandbox_exec | :none
  def sandbox_backend do
    cond do
      systemd_available?() -> :systemd_run
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

  Returns `nil` if given `nil`.
  """
  @spec trim_leading_separators(String.t() | nil) :: String.t() | nil
  def trim_leading_separators(nil), do: nil

  def trim_leading_separators(path) when is_binary(path) do
    String.replace(path, ~r/^[\/\\]+/, "")
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

  Returns `nil` if given `nil`. Returns `[]` if given an empty string.
  """
  @spec split_path(String.t() | nil, keyword()) :: [String.t()] | nil
  def split_path(nil, _opts), do: nil
  def split_path("", _opts), do: []

  def split_path(path, opts) when is_binary(path) and is_list(opts) do
    path |> normalize_separators() |> String.split("/", opts)
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
