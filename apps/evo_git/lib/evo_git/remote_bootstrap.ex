defmodule EvoGit.RemoteBootstrap do
  @moduledoc """
  Pure platform / asset / download-resolution logic for the SSH remote
  bootstrap flow (`EvoGit.RemoteConnection`).

  `EvoGit.RemoteConnection` owns all ssh/scp/curl/wget command orchestration and
  bootstrap-stage broadcasting; this module owns the decision logic:

    * mapping `uname -s` / `uname -m` output to CI platform strings
      (`<os>_<arch>`, e.g. `linux_x64`, `darwin_arm64`),
    * validating platform strings (`parse_platform/1`),
    * computing the release tarball file name (`asset_name/1`),
    * resolving the GitHub download URL (`download_url/1`) — the direct
      `releases/latest/download/...` URL (GitHub 302-redirects it to the
      versioned asset),
    * computing the local download-cache path (`cache_path/2`).

  All functions are deterministic and perform **no network I/O** — the actual
  tarball downloads happen in `EvoGit.RemoteConnection` via curl/wget.
  """

  @github_repo "EMI-Group/genesis"
  @latest_download_base_url "https://github.com/#{@github_repo}/releases/latest/download/"

  @valid_os ["linux", "darwin", "windows"]
  @valid_arch ["x64", "arm64"]

  @doc """
  Maps `uname -s` / `uname -m` output to a CI platform string `<os>_<arch>`.

  OS mapping: `Linux` → `linux`, `Darwin` → `darwin`, anything starting with
  `MINGW` or `CYGWIN` → `windows`. Architecture mapping: `x86_64` / `amd64` →
  `x64`, `aarch64` / `arm64` → `arm64`.

  Returns `{:ok, platform}` or `{:error, :unsupported_platform}`.
  """
  @spec parse_uname(String.t(), String.t()) :: {:ok, String.t()} | {:error, :unsupported_platform}
  def parse_uname(os, arch) when is_binary(os) and is_binary(arch) do
    with {:ok, os} <- os_from_uname(String.trim(os)),
         {:ok, arch} <- arch_from_uname(String.trim(arch)) do
      {:ok, "#{os}_#{arch}"}
    end
  end

  @doc """
  Validates a platform string of the form `<os>_<arch>` (e.g. `"linux_x64"`,
  `"darwin_arm64"`).

  Returns `{:ok, %{os: os, arch: arch}}` (both CI strings) or
  `{:error, {:invalid_platform, platform}}`.
  """
  @spec parse_platform(String.t()) ::
          {:ok, %{os: String.t(), arch: String.t()}} | {:error, term()}
  def parse_platform(platform) when is_binary(platform) do
    case String.split(platform, "_", parts: 2) do
      [os, arch] when os in @valid_os and arch in @valid_arch ->
        {:ok, %{os: os, arch: arch}}

      _ ->
        {:error, {:invalid_platform, platform}}
    end
  end

  @doc """
  Returns the daemon-launch OS string used by `EvoGit.RemoteConnection`'s
  launcher functions (`"Linux"` or `"Darwin"`) for a platform string.

  Windows platforms resolve to `{:error, :unsupported_platform}` — the daemon
  launcher only supports Linux (`systemd-run`) and macOS (`launchctl`).
  """
  @spec daemon_os(String.t()) :: {:ok, String.t()} | {:error, :unsupported_platform}
  def daemon_os(platform) do
    case parse_platform(platform) do
      {:ok, %{os: "linux"}} -> {:ok, "Linux"}
      {:ok, %{os: "darwin"}} -> {:ok, "Darwin"}
      _ -> {:error, :unsupported_platform}
    end
  end

  @doc """
  The release asset file name for a platform, e.g.
  `"genesis_remote_linux_x64.tar.gz"`.
  """
  @spec asset_name(String.t()) :: String.t()
  def asset_name(platform), do: "genesis_remote_#{platform}.tar.gz"

  @doc """
  The direct (redirecting) download URL for a platform's release tarball:
  `.../releases/latest/download/genesis_remote_<platform>.tar.gz`.

  GitHub 302-redirects this to the actual versioned asset.
  """
  @spec direct_url(String.t()) :: String.t()
  def direct_url(platform), do: @latest_download_base_url <> asset_name(platform)

  @doc """
  Resolves the download URL for a platform's release tarball.

  Deterministic and network-free: always returns the direct
  `releases/latest/download/...` URL — no GitHub API query and no asset
  listing/matching is performed (GitHub 302-redirects the URL to the actual
  versioned asset).

  Returns `{:ok, url, version}` — `version` is always `"latest"` and keys the
  local download cache.
  """
  @spec download_url(String.t()) :: {:ok, String.t(), String.t()}
  def download_url(platform), do: {:ok, direct_url(platform), "latest"}

  @doc """
  Local cache path for a platform/version tarball under
  `EvoGit.Platform.data_dir()`:
  `<data_dir>/remote_binaries/<platform>_<version>.tar.gz`.
  """
  @spec cache_path(String.t(), String.t()) :: String.t()
  def cache_path(platform, version) do
    Path.join([EvoGit.Platform.data_dir(), "remote_binaries", "#{platform}_#{version}.tar.gz"])
  end

  # --- Private ---

  defp os_from_uname(os) when os in ["Linux", "Darwin"], do: {:ok, String.downcase(os)}

  defp os_from_uname(os) when is_binary(os) do
    if String.starts_with?(os, ["MINGW", "CYGWIN"]) do
      {:ok, "windows"}
    else
      {:error, :unsupported_platform}
    end
  end

  defp os_from_uname(_), do: {:error, :unsupported_platform}

  defp arch_from_uname(arch) when arch in ["x86_64", "amd64"], do: {:ok, "x64"}
  defp arch_from_uname(arch) when arch in ["aarch64", "arm64"], do: {:ok, "arm64"}
  defp arch_from_uname(_), do: {:error, :unsupported_platform}
end
