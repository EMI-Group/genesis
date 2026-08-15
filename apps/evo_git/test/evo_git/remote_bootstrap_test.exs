defmodule EvoGit.RemoteBootstrapTest do
  use ExUnit.Case, async: true

  alias EvoGit.RemoteBootstrap

  describe "parse_uname/2" do
    test "maps Linux/x86_64" do
      assert RemoteBootstrap.parse_uname("Linux", "x86_64") == {:ok, "linux_x64"}
    end

    test "maps Darwin/aarch64" do
      assert RemoteBootstrap.parse_uname("Darwin", "aarch64") == {:ok, "darwin_arm64"}
    end

    test "maps Darwin/arm64" do
      assert RemoteBootstrap.parse_uname("Darwin", "arm64") == {:ok, "darwin_arm64"}
    end

    test "maps Linux/amd64" do
      assert RemoteBootstrap.parse_uname("Linux", "amd64") == {:ok, "linux_x64"}
    end

    test "prefix-matches MINGW with trailing text" do
      assert RemoteBootstrap.parse_uname("MINGW64_NT-10.0", "x86_64") ==
               {:ok, "windows_x64"}
    end

    test "prefix-matches CYGWIN with trailing text" do
      assert RemoteBootstrap.parse_uname("CYGWIN_NT-10.0", "amd64") ==
               {:ok, "windows_x64"}
    end

    test "trims whitespace on both inputs" do
      assert RemoteBootstrap.parse_uname(" Linux\n", " x86_64\n") == {:ok, "linux_x64"}
    end

    test "rejects unsupported OS" do
      assert RemoteBootstrap.parse_uname("FreeBSD", "x86_64") ==
               {:error, :unsupported_platform}
    end

    test "rejects unsupported arch" do
      assert RemoteBootstrap.parse_uname("Linux", "i386") ==
               {:error, :unsupported_platform}
    end

    test "OS matching is case-sensitive" do
      assert RemoteBootstrap.parse_uname("linux", "x86_64") ==
               {:error, :unsupported_platform}
    end
  end

  describe "parse_platform/1" do
    test "parses linux_x64" do
      assert RemoteBootstrap.parse_platform("linux_x64") ==
               {:ok, %{os: "linux", arch: "x64"}}
    end

    test "parses darwin_arm64" do
      assert RemoteBootstrap.parse_platform("darwin_arm64") ==
               {:ok, %{os: "darwin", arch: "arm64"}}
    end

    test "parses windows_x64" do
      assert RemoteBootstrap.parse_platform("windows_x64") ==
               {:ok, %{os: "windows", arch: "x64"}}
    end

    test "rejects a platform with no arch" do
      assert RemoteBootstrap.parse_platform("linux") ==
               {:error, {:invalid_platform, "linux"}}
    end

    test "rejects an unknown os" do
      assert RemoteBootstrap.parse_platform("foo_bar") ==
               {:error, {:invalid_platform, "foo_bar"}}
    end

    test "rejects an unknown arch" do
      assert RemoteBootstrap.parse_platform("linux_ppc") ==
               {:error, {:invalid_platform, "linux_ppc"}}
    end

    test "rejects a platform with an extra underscore segment" do
      assert RemoteBootstrap.parse_platform("linux_x64_extra") ==
               {:error, {:invalid_platform, "linux_x64_extra"}}
    end
  end

  describe "daemon_os/1" do
    test "maps linux to Linux" do
      assert RemoteBootstrap.daemon_os("linux_x64") == {:ok, "Linux"}
    end

    test "maps darwin to Darwin" do
      assert RemoteBootstrap.daemon_os("darwin_arm64") == {:ok, "Darwin"}
    end

    test "rejects windows" do
      assert RemoteBootstrap.daemon_os("windows_x64") ==
               {:error, :unsupported_platform}
    end

    test "rejects a bogus platform" do
      assert RemoteBootstrap.daemon_os("bogus_platform") ==
               {:error, :unsupported_platform}
    end
  end

  describe "asset_name/1" do
    test "builds the tarball name for linux_x64" do
      assert RemoteBootstrap.asset_name("linux_x64") ==
               "genesis_remote_linux_x64.tar.xz"
    end

    test "builds the unsuffixed tarball name for linux_arm64" do
      assert RemoteBootstrap.asset_name("linux_arm64") ==
               "genesis_remote_linux_arm64.tar.xz"
    end

    test "builds the unsuffixed tarball name for darwin_arm64" do
      assert RemoteBootstrap.asset_name("darwin_arm64") ==
               "genesis_remote_darwin_arm64.tar.xz"
    end

    test "builds the unsuffixed tarball name for windows_x64" do
      assert RemoteBootstrap.asset_name("windows_x64") ==
               "genesis_remote_windows_x64.tar.xz"
    end
  end

  describe "direct_url/1" do
    test "builds the linux_x64 direct URL" do
      assert RemoteBootstrap.direct_url("linux_x64") ==
               "https://genesis.evox.group/dl/genesis_remote_linux_x64.tar.xz"
    end

    test "builds the linux_arm64 direct URL" do
      assert RemoteBootstrap.direct_url("linux_arm64") ==
               "https://genesis.evox.group/dl/genesis_remote_linux_arm64.tar.xz"
    end

    test "builds the darwin_arm64 direct URL" do
      assert RemoteBootstrap.direct_url("darwin_arm64") ==
               "https://genesis.evox.group/dl/genesis_remote_darwin_arm64.tar.xz"
    end

    test "builds the windows_x64 direct URL" do
      assert RemoteBootstrap.direct_url("windows_x64") ==
               "https://genesis.evox.group/dl/genesis_remote_windows_x64.tar.xz"
    end
  end

  describe "download_url/1" do
    test "returns the direct linux_x64 URL with the latest version (no network)" do
      assert RemoteBootstrap.download_url("linux_x64") ==
               {:ok, "https://genesis.evox.group/dl/genesis_remote_linux_x64.tar.xz", "latest"}
    end

    test "returns the direct linux_arm64 URL with the latest version (no network)" do
      assert RemoteBootstrap.download_url("linux_arm64") ==
               {:ok, "https://genesis.evox.group/dl/genesis_remote_linux_arm64.tar.xz", "latest"}
    end

    test "returns the direct darwin_arm64 URL with the latest version (no network)" do
      assert RemoteBootstrap.download_url("darwin_arm64") ==
               {:ok, "https://genesis.evox.group/dl/genesis_remote_darwin_arm64.tar.xz", "latest"}
    end

    test "returns the direct windows_x64 URL with the latest version (no network)" do
      assert RemoteBootstrap.download_url("windows_x64") ==
               {:ok, "https://genesis.evox.group/dl/genesis_remote_windows_x64.tar.xz", "latest"}
    end

    test "version is always latest, keying the local download cache" do
      assert {:ok, url, "latest"} = RemoteBootstrap.download_url("linux_arm64")

      assert String.ends_with?(url, "genesis_remote_linux_arm64.tar.xz")

      assert RemoteBootstrap.cache_path("linux_arm64", "latest") ==
               Path.join([
                 EvoGit.Platform.data_dir(),
                 "remote_binaries",
                 "linux_arm64_latest.tar.xz"
               ])
    end
  end

  describe "cache_path/2" do
    test "builds the cache path under the platform data dir" do
      assert RemoteBootstrap.cache_path("linux_x64", "0.1.0") ==
               Path.join([
                 EvoGit.Platform.data_dir(),
                 "remote_binaries",
                 "linux_x64_0.1.0.tar.xz"
               ])
    end

    test "handles the latest version" do
      assert RemoteBootstrap.cache_path("darwin_arm64", "latest") ==
               Path.join([
                 EvoGit.Platform.data_dir(),
                 "remote_binaries",
                 "darwin_arm64_latest.tar.xz"
               ])
    end

    test "never suffixes linux_arm64 (glibc default, no variant suffix)" do
      assert RemoteBootstrap.cache_path("linux_arm64", "latest") ==
               Path.join([
                 EvoGit.Platform.data_dir(),
                 "remote_binaries",
                 "linux_arm64_latest.tar.xz"
               ])
    end

    test "never suffixes windows_x64" do
      assert RemoteBootstrap.cache_path("windows_x64", "latest") ==
               Path.join([
                 EvoGit.Platform.data_dir(),
                 "remote_binaries",
                 "windows_x64_latest.tar.xz"
               ])
    end
  end

  describe "nixos_detect_command/0" do
    test "checks /etc/nixos as the primary marker and echoes yes/no" do
      cmd = RemoteBootstrap.nixos_detect_command()

      assert cmd =~ "test -d /etc/nixos"
      assert cmd =~ "echo yes"
      assert cmd =~ "echo no"
      assert cmd =~ "ID=nixos"
      assert cmd =~ "/etc/os-release"
    end

    test "is a single one-shot command (no embedded newlines)" do
      cmd = RemoteBootstrap.nixos_detect_command()

      refute cmd =~ "\n"
    end
  end

  describe "nixos_patch_script/1" do
    @launcher "/tmp/genesis_remote/bin/genesis_remote"

    test "interpolates the launcher path and derives the release root" do
      script = RemoteBootstrap.nixos_patch_script(@launcher)

      assert script =~ @launcher
      assert script =~ ~S|RELEASE_ROOT="$(dirname "$(dirname "$LAUNCHER")")"|
      assert script =~ ~S|PATCH_DIR="$RELEASE_ROOT/.nixos-patch"|
      assert script =~ ~S|mkdir -p "$PATCH_DIR"|
    end

    test "runs all four nix-builds with 2>&1" do
      script = RemoteBootstrap.nixos_patch_script(@launcher)

      assert script =~ ~S|nix-build "$NIXPKGS" -A patchelf --out-link "$PATCH_DIR/patchelf" 2>&1|
      assert script =~ ~S|nix-build "$NIXPKGS" -A bintools --out-link "$PATCH_DIR/bintools" 2>&1|

      assert script =~
               ~S|nix-build "$NIXPKGS" -A stdenv.cc.cc.lib --out-link "$PATCH_DIR/cc" 2>&1|

      assert script =~ ~S|nix-build "$NIXPKGS" -A openssl --out-link "$PATCH_DIR/openssl" 2>&1|
      # nixpkgs comes from NIX_PATH via the angle-bracket lookup path
      assert script =~ ~S|NIXPKGS="<nixpkgs>"|
    end

    test "reads the interpreter from the bintools nix-support file" do
      script = RemoteBootstrap.nixos_patch_script(@launcher)

      assert script =~ ~S|INTERPRETER="$(cat "$PATCH_DIR/bintools/nix-support/dynamic-linker")"|
    end

    test "sets the rpath from cc/lib and openssl/lib" do
      script = RemoteBootstrap.nixos_patch_script(@launcher)

      assert script =~ ~S|RPATH="$PATCH_DIR/cc/lib:$PATCH_DIR/openssl/lib"|
    end

    test "loops over release files with an ELF magic check and invokes patchelf" do
      script = RemoteBootstrap.nixos_patch_script(@launcher)

      assert script =~ ~S|for file in $(find "$RELEASE_ROOT" -type f); do|
      assert script =~ ~S|head -c 4 "$file"|
      assert script =~ ~S|od -An -tx1|
      assert script =~ ~S|tr -d ' \n'|
      assert script =~ ~S|7f454c46|

      assert script =~
               ~S|"$PATCH_DIR/patchelf/bin/patchelf" --set-interpreter "$INTERPRETER" --set-rpath "$RPATH" "$file"|
    end

    test "echoes nixos-patch progress markers and uses set -e" do
      script = RemoteBootstrap.nixos_patch_script(@launcher)

      assert script =~ "nixos-patch: building patchelf..."
      assert script =~ "nixos-patch: building bintools..."
      assert script =~ "nixos-patch: building stdenv.cc.cc.lib..."
      assert script =~ "nixos-patch: building openssl..."
      assert script =~ ~S|echo "nixos-patch: patched $count ELF files"|
      assert script =~ "set -e"
    end
  end

  describe "bash_wrap/1" do
    test "wraps a plain command" do
      assert RemoteBootstrap.bash_wrap("cmd") == "/usr/bin/env bash -c 'cmd'"
    end

    test "escapes embedded single quotes (close-quote/escaped-quote/reopen-quote)" do
      assert RemoteBootstrap.bash_wrap(RemoteBootstrap.nixos_detect_command()) ==
               "/usr/bin/env bash -c 'test -d /etc/nixos && echo yes || grep -qi '\\''^ID=nixos'\\'' /etc/os-release 2>/dev/null && echo yes || echo no'"
    end

    test "wraps the NixOS patch script, escaping its single quotes" do
      wrapped = RemoteBootstrap.bash_wrap(RemoteBootstrap.nixos_patch_script(@launcher))

      assert String.starts_with?(wrapped, "/usr/bin/env bash -c '#!/bin/sh")
      # the script's own single quotes survive as '\'' escape sequences
      assert String.contains?(wrapped, ~S|tr -d '\'' \n'\''|)
      refute String.contains?(wrapped, ~S|tr -d ' \n'|)
    end

    test "wraps an empty command" do
      assert RemoteBootstrap.bash_wrap("") == "/usr/bin/env bash -c ''"
    end
  end
end
