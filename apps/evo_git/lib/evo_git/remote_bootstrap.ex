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
    * computing the local download-cache path (`cache_path/2`),
    * building the one-shot NixOS detection command (`nixos_detect_command/0`)
      and the on-the-fly NixOS patch script (`nixos_patch_script/1`) — the
      glibc-linked release cannot execute on NixOS hosts (no
      `/lib64/ld-linux-x86-64.so.2`), so bootstrap patches the extracted
      release's ELF binaries with a Nix-built `patchelf` (mirroring the NixOS
      `vscode-remote-ssh` extension patch pattern): dynamic executables get
      interpreter + rpath, shared libraries get rpath only, and truly static
      binaries are skipped,
    * building the remote shell wrapper (`bash_wrap/1`) that makes every
      remote command execute under bash regardless of the remote user's login
      shell (fixes bootstrap failures on hosts whose login shell is fish).

  **Linux asset rule:** glibc is the default and ONLY published Linux variant.
  Remote tarball names are NEVER suffixed (`genesis_remote_linux_x64.tar.xz`,
  `genesis_remote_linux_arm64.tar.xz`); the musl build is disabled for now.
  Non-Linux platforms are never suffixed either
  (`genesis_remote_darwin_arm64.tar.xz`, `genesis_remote_windows_x64.tar.xz`).
  NixOS hosts are supported via on-the-fly patching during bootstrap — no new
  asset variants.

  All functions are deterministic and perform **no network I/O** — the actual
  tarball downloads happen in `EvoGit.RemoteConnection` via curl/wget, and the
  NixOS patch script is executed on the remote host via ssh.
  """

  @download_base_url "https://genesis.evox.group/dl/"

  @valid_os ["linux", "darwin", "windows"]
  @valid_arch ["x64", "arm64"]

  # Matches a single `KEY=value` token: a run of non-whitespace, non-quote
  # characters, OR a double-quoted section (which may contain spaces). This
  # mirrors how systemd quotes Environment values that contain whitespace.
  @unit_env_token_re ~r/(?:[^\s"]+|"[^"]*")+/
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
  `"genesis_remote_linux_x64.tar.xz"`.

  Names are NEVER suffixed: glibc is the default and only published Linux
  variant (the musl build is disabled for now), so Linux platforms get plain
  `genesis_remote_linux_<arch>.tar.xz` names, and non-Linux platforms are
  never suffixed either.
  """
  @spec asset_name(String.t()) :: String.t()
  def asset_name(platform) when is_binary(platform) do
    "genesis_remote_#{platform}.tar.xz"
  end

  @doc """
  The direct download URL for a platform's release tarball:
  `https://genesis.evox.group/dl/genesis_remote_<platform>.tar.xz`.

  This Cloudflare-worker "smart download" endpoint serves the latest GitHub
  release asset, auto-detecting mainland-China users and proxying the asset
  through the Cloudflare network when needed.
  """
  @spec direct_url(String.t()) :: String.t()
  def direct_url(platform), do: @download_base_url <> asset_name(platform)

  @doc """
  Resolves the download URL for a platform's release tarball.

  Deterministic and network-free: always returns the direct
  `https://genesis.evox.group/dl/genesis_remote_<platform>.tar.xz`
  Cloudflare-worker "smart download" URL — no API query and no asset
  listing/matching is performed (the worker proxies the GitHub release asset
  and auto-detects mainland-China users).

  Returns `{:ok, url, version}` — `version` is always `"latest"` and keys the
  local download cache.
  """
  @spec download_url(String.t()) :: {:ok, String.t(), String.t()}
  def download_url(platform), do: {:ok, direct_url(platform), "latest"}

  @doc """
  Local cache path for a platform/version tarball under
  `EvoGit.Platform.data_dir()`:
  `<data_dir>/remote_binaries/<platform>_<version>.tar.xz`.

  Names are never suffixed — glibc is the default and only published Linux
  variant, so every platform/version maps to a single cache entry.
  """
  @spec cache_path(String.t(), String.t()) :: String.t()
  def cache_path(platform, version) do
    Path.join([
      EvoGit.Platform.data_dir(),
      "remote_binaries",
      "#{platform}_#{version}.tar.xz"
    ])
  end

  @doc """
  Returns the one-shot remote command that detects NixOS on the remote host.

  The command prints `yes` when the host is NixOS (the `/etc/nixos` directory
  is the primary marker) and `no` otherwise, with `/etc/os-release` as a
  secondary marker:

      test -d /etc/nixos && echo yes || grep -qi '^ID=nixos' /etc/os-release 2>/dev/null && echo yes || echo no

  Note: shell `&&`/`||` left-associativity makes the `/etc/nixos` branch echo
  `yes` twice — `EvoGit.RemoteConnection` treats any output containing `yes`
  as a NixOS detection, which is robust against both forms.

  Pure builder — performs no I/O; the command is executed on the remote host
  by `EvoGit.RemoteConnection` (one SSH round trip).
  """
  @spec nixos_detect_command() :: String.t()
  def nixos_detect_command do
    "test -d /etc/nixos && echo yes || grep -qi '^ID=nixos' /etc/os-release 2>/dev/null && echo yes || echo no"
  end

  # The script template. `__LAUNCHER__` is interpolated at build time by
  # nixos_patch_script/1; everything else ($, quotes, $(...)) is literal and
  # interpreted by the REMOTE shell at run time.
  @nixos_patch_script_template ~S"""
  #!/bin/sh
  set -e

  LAUNCHER="__LAUNCHER__"
  RELEASE_ROOT="$(dirname "$(dirname "$LAUNCHER")")"
  PATCH_DIR="$RELEASE_ROOT/.nixos-patch"
  NIXPKGS="<nixpkgs>"

  echo "nixos-patch: creating patch dir $PATCH_DIR"
  mkdir -p "$PATCH_DIR"

  echo "nixos-patch: building patchelf..."
  nix-build "$NIXPKGS" -A patchelf --out-link "$PATCH_DIR/patchelf" 2>&1

  echo "nixos-patch: building bintools..."
  nix-build "$NIXPKGS" -A bintools --out-link "$PATCH_DIR/bintools" 2>&1
  INTERPRETER="$(cat "$PATCH_DIR/bintools/nix-support/dynamic-linker")"

  echo "nixos-patch: building stdenv.cc.cc.lib..."
  nix-build "$NIXPKGS" -A stdenv.cc.cc.lib --out-link "$PATCH_DIR/cc" 2>&1
  # nix-build names the out-link "$PATCH_DIR/cc-lib" because the attr selects
  # the non-default `lib` output of the multi-output gcc derivation; alias it
  # as "$PATCH_DIR/cc" so the RPATH entry below always resolves.
  if [ ! -e "$PATCH_DIR/cc" ]; then
    ln -s "$PATCH_DIR/cc-lib" "$PATCH_DIR/cc"
  fi

  echo "nixos-patch: building openssl..."
  nix-build "$NIXPKGS" -A openssl.out --out-link "$PATCH_DIR/openssl" 2>&1

  echo "nixos-patch: building zlib..."
  nix-build "$NIXPKGS" -A zlib --out-link "$PATCH_DIR/zlib" 2>&1

  echo "nixos-patch: building ncurses..."
  nix-build "$NIXPKGS" -A ncurses --out-link "$PATCH_DIR/ncurses" 2>&1

  echo "nixos-patch: building pcre2..."
  nix-build "$NIXPKGS" -A pcre2.out --out-link "$PATCH_DIR/pcre2" 2>&1

  RPATH="$PATCH_DIR/cc/lib:$PATCH_DIR/openssl/lib:$PATCH_DIR/zlib/lib:$PATCH_DIR/ncurses/lib:$PATCH_DIR/pcre2/lib"

  count=0
  rpath_count=0
  for file in $(find "$RELEASE_ROOT" -type f); do
    magic="$(head -c 4 "$file" | od -An -tx1 | tr -d ' \n')"
    if [ "$magic" = "7f454c46" ]; then
      if "$PATCH_DIR/patchelf/bin/patchelf" --print-interpreter "$file" >/dev/null 2>&1; then
        echo "nixos-patch: patching $file"
        "$PATCH_DIR/patchelf/bin/patchelf" --set-interpreter "$INTERPRETER" --set-rpath "$RPATH" "$file"
        count=$((count + 1))
      elif "$PATCH_DIR/patchelf/bin/patchelf" --print-rpath "$file" >/dev/null 2>&1 &&
           "$PATCH_DIR/bintools/bin/readelf" -d "$file" 2>/dev/null | grep -q NEEDED; then
        echo "nixos-patch: setting rpath on $file"
        "$PATCH_DIR/patchelf/bin/patchelf" --set-rpath "$RPATH" "$file"
        rpath_count=$((rpath_count + 1))
      else
        echo "nixos-patch: skipping static binary $file"
      fi
    fi
  done

  echo "nixos-patch: patched $count executables, set rpath on $rpath_count ELF files"
  """

  @doc """
  Builds the remote shell script that patches the extracted `genesis_remote`
  release's ELF binaries for NixOS, given the remote launcher path (e.g.
  `/tmp/genesis_remote/bin/genesis_remote`).

  The glibc-linked release tarball cannot execute on NixOS hosts (no
  `/lib64/ld-linux-x86-64.so.2`), so bootstrap patches it on the fly —
  mirroring the NixOS `vscode-remote-ssh` extension patch pattern:

    * derives the release root via `dirname` twice and creates a patch dir
      `<release>/.nixos-patch` — persisted across re-extractions as GC roots,
      so re-bootstrap `nix-build`s are instant,
    * runs the seven `nix-build "<nixpkgs>"` builds (`patchelf`, `bintools`,
      `stdenv.cc.cc.lib`, `openssl.out`, `zlib`, `ncurses`, `pcre2.out`) with
      `2>&1` on each so errors land in stdout. Each lib covers the release's
      NEEDED deps: `cc` (stdenv.cc.cc.lib) = `libstdc++.so.6`/`libgcc_s.so.1`
      (beam.smp; glibc's `libc.so.6`/`libm.so.6` resolve from the patched
      interpreter's own directory, so glibc itself is NOT in the RPATH —
      nix-build names the out-link `<patch_dir>/cc-lib` because the attr
      selects the non-default `lib` output of the multi-output gcc
      derivation, so the script aliases it as `<patch_dir>/cc`),
      `openssl.out` = `libcrypto.so.3`/`libssl.so.3` (the OTP `:crypto` NIF
      `crypto.so` — the plain `openssl` attr's default `bin` output has no
      `lib/`, so `.out` is required; `crypto.so` is in the release because
      req_llm → req → finch → mint pull in `:ssl`, harmless when unneeded),
      `zlib` = `libz.so.1` (beam.smp, vendored git), `ncurses` =
      `libtinfo.so.6` (beam.smp), `pcre2.out` = `libpcre2-8.so.0` (vendored
      git — same `bin`-output trap as openssl, so `.out` is required),
    * reads the Nix dynamic linker from
      `<patch_dir>/bintools/nix-support/dynamic-linker`,
    * sets `RPATH` to
      `<patch_dir>/cc/lib:<patch_dir>/openssl/lib:<patch_dir>/zlib/lib:<patch_dir>/ncurses/lib:<patch_dir>/pcre2/lib`,
    * loops over every regular file under the release root and detects ELF
      binaries via the `\\x7fELF` magic (`7f454c46` from
      `head -c 4 | od -An -tx1 | tr -d ' \\n'`). Each ELF file is handled three
      ways:
        - **dynamic executables** (have a PT_INTERP segment — probed with
          `patchelf --print-interpreter`): patched as before with
          `<patch_dir>/patchelf/bin/patchelf --set-interpreter "$INTERPRETER"
          --set-rpath "$RPATH"` (idempotent — re-running on already-patched
          files is safe, no `.orig` handling),
        - **shared libraries** (no PT_INTERP but a `.dynamic` section with
          NEEDED entries — probed with `patchelf --print-rpath` plus
          `<patch_dir>/bintools/bin/readelf -d "$file" | grep NEEDED`):
          rpath-only patch with `--set-rpath "$RPATH"` so their NEEDED deps
          resolve through the Nix store paths,
        - **static binaries** (no PT_INTERP and no NEEDED deps — e.g.
          static-pie executables like the vendored `rg`, which carry a
          `.dynamic` section but declare no shared-library dependencies):
          skipped with a `nixos-patch: skipping static binary` marker —
          nothing to patch (they run unpatched, and patchelf's ELF rewrite
          corrupts static-pie binaries).

  The script echoes `nixos-patch:` progress/step markers to stdout on every
  step and uses `set -e` so any failure aborts with a non-zero exit. `$`,
  quotes and `$(...)` in the script are intended — they are interpreted by the
  REMOTE shell when `EvoGit.RemoteConnection` passes the whole script as a
  single ssh argv element.

  Pure builder — performs no I/O.
  """
  @spec nixos_patch_script(String.t()) :: String.t()
  def nixos_patch_script(launcher_path) do
    String.replace(@nixos_patch_script_template, "__LAUNCHER__", launcher_path)
  end

  @doc """
  Wraps a remote command so it executes under bash regardless of the remote
  user's login shell.

  OpenSSH executes the remote command via the remote user's login shell
  (`$SHELL -c "<command>"`). On hosts whose login shell is not POSIX-ish
  (e.g. fish on NixOS), POSIX constructs like `VAR=...` assignments are
  rejected at PARSE time and the command fails before it ever runs. Wrapping
  as `/usr/bin/env bash -c '<escaped>'` forces execution under bash.

  Single quotes inside the command are escaped as `'\\''` — the standard
  close-quote / escaped-quote / reopen-quote idiom — which parses correctly
  under fish, zsh, and any POSIX-ish remote shell.

  Pure builder — performs no I/O; the wrapping happens only at the ssh
  boundary in `EvoGit.RemoteConnection.run_ssh_command/3`.
  """
  @spec bash_wrap(String.t()) :: String.t()
  def bash_wrap(remote_cmd) do
    "/usr/bin/env bash -c '" <> String.replace(remote_cmd, "'", "'\\''") <> "'"
  end

  @doc """
  Parses the output of `systemctl --user show <unit> -p Environment --value`
  into a `%{"KEY" => "value"}` map.

  systemd prints the unit's environment space-separated on one or more lines
  (multiple `Environment=` lines), quoting values that contain whitespace:

      RELEASE_NODE=genesis_remote_x@127.0.0.1 RELEASE_COOKIE=abc123

  or, multi-line:

      RELEASE_NODE=genesis_remote_x@127.0.0.1
      RELEASE_COOKIE="some value with spaces"

  Tokens without an `=` (stray output) are skipped; surrounding double quotes
  are stripped from values. Empty / whitespace-only input → `%{}`.

  Pure parser — performs no I/O.
  """
  @spec parse_unit_environment(String.t()) :: %{String.t() => String.t()}
  def parse_unit_environment(output) when is_binary(output) do
    Regex.scan(@unit_env_token_re, output)
    |> List.flatten()
    |> Enum.reduce(%{}, fn token, acc ->
      case String.split(token, "=", parts: 2) do
        [key, value] -> Map.put(acc, key, strip_quotes(value))
        _ -> acc
      end
    end)
  end

  # --- Private ---

  defp strip_quotes(value) do
    if String.starts_with?(value, "\"") and String.ends_with?(value, "\"") and
         String.length(value) >= 2 do
      String.slice(value, 1, String.length(value) - 2)
    else
      value
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
