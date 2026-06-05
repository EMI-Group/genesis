defmodule EvoGit.Executable do
  @moduledoc """
  Resolves executable paths with a system-first, bundled-fallback strategy.

  For desktop releases on macOS and Windows, git and ripgrep binaries are bundled
  in priv/vendor/{platform}/. This module tries the system PATH first, then falls
  back to the bundled version.
  """

  @doc """
  Resolves the full path to an executable.

  Returns the name unchanged if found on system PATH (so System.cmd can find it).
  Otherwise returns the absolute path to the bundled version in priv/vendor.

  Only "git" and "rg" are supported for bundling.
  """
  @spec resolve(String.t()) :: String.t()
  def resolve(name) do
    case System.find_executable(name) do
      nil -> bundled_path(name)
      _path -> name
    end
  end

  defp bundled_path(name) do
    vendor_dir = Application.app_dir(:evo_git, Path.join("priv/vendor", vendor_platform()))
    path = Path.join(vendor_dir, name)
    path
  end

  defp vendor_platform do
    arch = arch_string()
    case :os.type() do
      {:unix, :darwin} -> "macos-#{arch}"
      {:win32, _} -> "windows-x64"
      {:unix, _} -> "linux-#{arch}"
    end
  end

  defp arch_string do
    # :erlang.system_info(:system_architecture) returns e.g. "aarch64-apple-darwin23.0.0"
    sys_arch = List.to_string(:erlang.system_info(:system_architecture))
    cond do
      String.starts_with?(sys_arch, "aarch64") or String.starts_with?(sys_arch, "arm64") -> "arm64"
      String.starts_with?(sys_arch, "x86_64") or String.starts_with?(sys_arch, "amd64") -> "x86_64"
      true -> "unknown"
    end
  end
end
