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
  Returns true if `systemd-run` is likely available on this platform.
  
  Only returns true on Linux where systemd is the init system.
  """
  @spec systemd_available?() :: boolean()
  def systemd_available? do
    linux?() and System.find_executable("systemd-run") != nil
  end
end
