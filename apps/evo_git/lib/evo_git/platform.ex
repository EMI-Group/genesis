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
  Returns true if `sandbox-exec` is available on this platform.

  Only returns true on macOS where sandbox-exec is found in PATH.
  """
  @spec sandbox_exec_available?() :: boolean()
  def sandbox_exec_available? do
    macos?() and System.find_executable("sandbox-exec") != nil
  end

  @doc """
  Returns true if the `nix` binary is available on this platform.

  Nix works on both Linux and macOS, so no OS guard is applied.
  """
  @spec nix_available?() :: boolean()
  def nix_available? do
    System.find_executable("nix") != nil
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
end
