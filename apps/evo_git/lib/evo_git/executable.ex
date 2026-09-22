defmodule EvoGit.Executable do
  @moduledoc """
  Resolves executable paths with a system-first, bundled-fallback strategy.

  For desktop releases, git and ripgrep binaries are bundled in
  priv/vendor/{platform}/. This module tries the system PATH first, then falls
  back to the bundled version — but ONLY when that bundled file actually
  exists. When no bundled file exists, the original name is returned
  unchanged so that the normal PATH search (and any platform-specific
  known-location fallback, e.g. Windows PowerShell) still applies.
  """

  @doc """
  Resolves the full path to an executable.

  Returns the name unchanged if found on system PATH (so System.cmd can find it).
  Otherwise returns the absolute path to the bundled version in priv/vendor when
  that bundled file exists. When it does not exist, the name is returned
  unchanged so that PATH search / `System.find_executable/1` / platform
  known-location fallbacks can still resolve it — a non-existent absolute path
  is NEVER returned.

  Only "git" and "rg" are actually bundled (MinGit + ripgrep).
  """
  @spec resolve(String.t()) :: String.t()
  def resolve(name) do
    case System.find_executable(name) do
      nil -> bundled_path(name, resolve_vendor_dir()) || name
      _path -> name
    end
  end

  @doc false
  @spec bundled_path(String.t(), Path.t(), tuple()) :: String.t() | nil
  def bundled_path(name, vendor_dir, os_type \\ :os.type()) do
    name
    |> candidates(vendor_dir, os_type)
    |> Enum.find(&File.regular?/1)
  end

  @doc false
  @spec candidates(String.t(), Path.t(), tuple()) :: [String.t()]
  def candidates(name, vendor_dir, os_type \\ :os.type()) do
    case {name, os_type} do
      {"git", {:win32, _}} -> [Path.join([vendor_dir, "mingit", "cmd", "git.exe"])]
      {_, {:win32, _}} -> [Path.join(vendor_dir, "#{name}.exe")]
      _ -> [Path.join(vendor_dir, name)]
    end
  end

  defp resolve_vendor_dir do
    platform_path = Path.join("vendor", vendor_platform())

    # Primary: Application.app_dir (works for standard mix releases)
    app_path = Application.app_dir(:evo_git, Path.join("priv", platform_path))

    if File.dir?(app_path) do
      app_path
    else
      # Fallback: :code.priv_dir/1 for edge cases
      case :code.priv_dir(:evo_git) do
        {:error, _} -> app_path
        priv_dir -> Path.join(List.to_string(priv_dir), platform_path)
      end
    end
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
      String.starts_with?(sys_arch, "aarch64") or String.starts_with?(sys_arch, "arm64") ->
        "arm64"

      String.starts_with?(sys_arch, "x86_64") or String.starts_with?(sys_arch, "amd64") ->
        "x86_64"

      true ->
        "unknown"
    end
  end
end
