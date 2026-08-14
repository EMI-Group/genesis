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
    * resolving the download URL (`download_url/1`) — the deterministic
      `https://genesis.evox.group/dl/...` Cloudflare-worker "smart download"
      endpoint (auto-detects mainland-China users and proxies the GitHub
      release asset through Cloudflare when needed),
    * computing the local download-cache path (`cache_path/2`).

  **Linux arm64 asset rule:** CI no longer publishes a musl arm64 tarball, so
  for platform `"linux_arm64"` EVERY libc variant (`:musl`, `:glibc`, `nil`)
  resolves to the `_glibc`-suffixed asset (`genesis_remote_linux_arm64_glibc.tar.xz`).
  `"linux_x64"` keeps the musl-default behavior (musl/nil → unsuffixed, glibc →
  `_glibc`-suffixed), and non-Linux platforms are never suffixed. The
  normalization lives in the private `effective_libc/2` helper, threaded
  through `asset_name/2` and `cache_path/3` (and hence through the delegating
  `direct_url/2` / `download_url/2`), so the asset name, download URL, and
  local cache entry always stay consistent.

  All functions are deterministic and perform **no network I/O** — the actual
  tarball downloads happen in `EvoGit.RemoteConnection` via curl/wget.
  """

  @download_base_url "https://genesis.evox.group/dl/"

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
  Detects the libc implementation from `ldd --version` output.

  Takes a string (the first line of `ldd --version 2>&1 | head -1`) and returns:
    * `:musl`  — the string contains "musl" (case-insensitive),
    * `:glibc` — the string contains "glibc" or "gnu libc" (case-insensitive),
    * `nil`    — the libc can't be determined (unknown/empty input).

  Pure function — no I/O.
  """
  @spec detect_libc(String.t() | nil) :: :musl | :glibc | nil
  def detect_libc(nil), do: nil

  def detect_libc(str) when is_binary(str) do
    downcased = String.downcase(str)

    cond do
      String.contains?(downcased, "musl") -> :musl
      String.contains?(downcased, "glibc") -> :glibc
      String.contains?(downcased, "gnu libc") -> :glibc
      true -> nil
    end
  end

  @doc """
  The release asset file name for a platform, e.g.
  `"genesis_remote_linux_x64.tar.xz"`.

  When `libc` is `:glibc` and the platform is Linux, a `_glibc` suffix is
  inserted before the extension
  (e.g. `"genesis_remote_linux_x64_glibc.tar.xz"`). For `"linux_x64"`, musl
  (the default) is unsuffixed. **Linux arm64 exception:** CI publishes no
  musl arm64 tarball, so `"linux_arm64"` ALWAYS gets the `_glibc` suffix
  regardless of `libc` (`:musl`, `:glibc`, or `nil`). Non-Linux platforms are
  never suffixed.
  """
  @spec asset_name(String.t(), :musl | :glibc | nil) :: String.t()
  def asset_name(platform, libc \\ nil)

  def asset_name(platform, libc) when is_binary(platform) do
    if effective_libc(platform, libc) == :glibc and linux_platform?(platform) do
      "genesis_remote_#{platform}_glibc.tar.xz"
    else
      "genesis_remote_#{platform}.tar.xz"
    end
  end

  @doc """
  The direct download URL for a platform's release tarball:
  `https://genesis.evox.group/dl/genesis_remote_<platform>.tar.xz`.

  The optional `libc` variant threads through to `asset_name/2` so glibc Linux
  builds get the `_glibc`-suffixed URL (and `"linux_arm64"` always does —
  see `asset_name/2`).

  This Cloudflare-worker "smart download" endpoint serves the latest GitHub
  release asset, auto-detecting mainland-China users and proxying the asset
  through the Cloudflare network when needed.
  """
  @spec direct_url(String.t(), :musl | :glibc | nil) :: String.t()
  def direct_url(platform, libc \\ nil), do: @download_base_url <> asset_name(platform, libc)

  @doc """
  Resolves the download URL for a platform's release tarball.

  Deterministic and network-free: always returns the direct
  `https://genesis.evox.group/dl/genesis_remote_<platform>.tar.xz`
  Cloudflare-worker "smart download" URL — no API query and no asset
  listing/matching is performed (the worker proxies the GitHub release asset
  and auto-detects mainland-China users). The optional `libc` variant threads
  through to `direct_url/2`.

  Returns `{:ok, url, version}` — `version` is always `"latest"` and keys the
  local download cache.
  """
  @spec download_url(String.t(), :musl | :glibc | nil) :: {:ok, String.t(), String.t()}
  def download_url(platform, libc \\ nil), do: {:ok, direct_url(platform, libc), "latest"}

  @doc """
  Local cache path for a platform/version tarball under
  `EvoGit.Platform.data_dir()`:
  `<data_dir>/remote_binaries/<platform>_<version>.tar.xz`.

  When the effective libc is `:glibc` and the platform is Linux, the cache
  filename includes a `_glibc` suffix so musl and glibc builds have separate
  cache entries. For `"linux_arm64"` the effective libc is ALWAYS `:glibc`
  (no musl arm64 tarball is published), so its cache entry is always the
  `_glibc`-suffixed one.
  """
  @spec cache_path(String.t(), String.t(), :musl | :glibc | nil) :: String.t()
  def cache_path(platform, version, libc \\ nil) do
    name =
      if effective_libc(platform, libc) == :glibc and linux_platform?(platform) do
        "#{platform}_glibc_#{version}.tar.xz"
      else
        "#{platform}_#{version}.tar.xz"
      end

    Path.join([EvoGit.Platform.data_dir(), "remote_binaries", name])
  end

  # --- Private ---

  # Normalizes the libc variant for asset selection. CI publishes NO musl
  # arm64 tarball, so "linux_arm64" always resolves to the glibc asset
  # regardless of the probed/nil libc. All other platforms keep the caller's
  # variant unchanged.
  defp effective_libc("linux_arm64", _libc), do: :glibc
  defp effective_libc(_platform, libc), do: libc

  defp linux_platform?(platform) when is_binary(platform) do
    case parse_platform(platform) do
      {:ok, %{os: "linux"}} -> true
      _ -> String.starts_with?(platform, "linux_")
    end
  end

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
