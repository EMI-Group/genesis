defmodule EvoGit.RemoteBootstrap do
  @moduledoc """
  Pure platform / asset / download-resolution logic for the SSH remote
  bootstrap flow (`EvoGit.RemoteConnection`).

  `EvoGit.RemoteConnection` owns all ssh/scp/curl command orchestration and
  bootstrap-stage broadcasting; this module owns the decision logic:

    * mapping `uname -s` / `uname -m` output to CI platform strings
      (`<os>_<arch>`, e.g. `linux_x64`, `darwin_arm64`),
    * validating platform strings (`parse_platform/1`),
    * computing release asset names and matching them while tolerating the
      embedded version (`asset_name/1`, `asset_matches?/2`),
    * resolving the GitHub download URL (`download_url/1`) — latest-release
      API query via `Req` with a direct-URL fallback,
    * computing the local download-cache path (`cache_path/2`).

  All functions are deterministic given their inputs. The only network I/O is
  `download_url/1`, which queries the GitHub latest-release API and — when the
  query fails, is rate-limited, or the matching asset is missing — falls back
  to the direct `releases/latest/download` URL (GitHub 302-redirects that to
  the versioned asset; `curl -L` / Req follow redirects by default).
  """

  require Logger

  @github_repo "BillHuang2001/genesis"
  @latest_release_api_url "https://api.github.com/repos/#{@github_repo}/releases/latest"
  @latest_download_base_url "https://github.com/#{@github_repo}/releases/latest/download/"

  # GitHub API query timeout (the actual tarball download uses curl and has its
  # own, much larger timeout in RemoteConnection).
  @api_timeout_ms 30_000

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
  Returns `true` when the given GitHub asset name is the release tarball for
  `platform`. Uses a suffix match (`_<platform>.tar.gz`) so versioned asset
  names (e.g. `genesis_remote_0.1.0_linux_x64.tar.gz`) match, as do
  unversioned names (`genesis_remote_linux_x64.tar.gz`).
  """
  @spec asset_matches?(String.t(), String.t()) :: boolean()
  def asset_matches?(asset_name, platform) when is_binary(asset_name) do
    String.ends_with?(asset_name, "_#{platform}.tar.gz")
  end

  @doc """
  The direct (redirecting) download URL for a platform's release tarball:
  `.../releases/latest/download/genesis_remote_<platform>.tar.gz`.

  GitHub 302-redirects this to the actual versioned asset.
  """
  @spec direct_url(String.t()) :: String.t()
  def direct_url(platform), do: @latest_download_base_url <> asset_name(platform)

  @doc """
  Resolves the download URL for a platform's release tarball.

  Queries the GitHub latest-release API and picks the asset whose name matches
  `asset_matches?/2` (tolerating the embedded version), returning its
  `browser_download_url`. When the API call fails, is rate-limited, or the
  asset is missing, falls back to `direct_url/1`.

  Returns `{:ok, url, version}` — `version` is the release version (e.g.
  `"0.1.0"`, or `"latest"` when unknown) used to key the local download cache.
  """
  @spec download_url(String.t()) :: {:ok, String.t(), String.t()}
  def download_url(platform) do
    case query_latest_release() do
      {:ok, body} ->
        version = version_from_body(body)

        case find_asset_url(body, platform) do
          {:ok, url} -> {:ok, url, version}
          :error -> {:ok, direct_url(platform), version}
        end

      {:error, reason} ->
        Logger.warning(
          "RemoteBootstrap: GitHub API query failed (#{inspect(reason)}); " <>
            "falling back to direct download URL."
        )

        {:ok, direct_url(platform), "latest"}
    end
  end

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

  defp query_latest_release do
    case Req.get(@latest_release_api_url, receive_timeout: @api_timeout_ms) do
      {:ok, %{status: 200, body: body}} when is_map(body) ->
        {:ok, body}

      {:ok, %{status: status, body: body}} ->
        {:error, {:api_status, status, body}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp version_from_body(body) do
    case Map.get(body, "tag_name") do
      tag when is_binary(tag) -> String.trim_leading(tag, "v")
      _ -> "latest"
    end
  end

  defp find_asset_url(body, platform) do
    assets = Map.get(body, "assets", [])

    case Enum.find(assets, fn asset ->
           asset_matches?(Map.get(asset, "name"), platform)
         end) do
      %{"browser_download_url" => url} when is_binary(url) -> {:ok, url}
      _ -> :error
    end
  end
end
