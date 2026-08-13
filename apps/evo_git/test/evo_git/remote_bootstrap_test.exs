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
    test "builds the tarball name" do
      assert RemoteBootstrap.asset_name("linux_x64") ==
               "genesis_remote_linux_x64.tar.xz"
    end
  end

  describe "asset_name/2" do
    test "builds the glibc-suffixed name for linux_x64" do
      assert RemoteBootstrap.asset_name("linux_x64", :glibc) ==
               "genesis_remote_linux_x64_glibc.tar.xz"
    end

    test "builds the unsuffixed name for musl" do
      assert RemoteBootstrap.asset_name("linux_x64", :musl) ==
               "genesis_remote_linux_x64.tar.xz"
    end

    test "defaults to unsuffixed (musl) name when libc is nil" do
      assert RemoteBootstrap.asset_name("linux_x64") ==
               "genesis_remote_linux_x64.tar.xz"

      assert RemoteBootstrap.asset_name("linux_x64", nil) ==
               "genesis_remote_linux_x64.tar.xz"
    end

    test "builds the glibc-suffixed name for linux_arm64" do
      assert RemoteBootstrap.asset_name("linux_arm64", :glibc) ==
               "genesis_remote_linux_arm64_glibc.tar.xz"
    end

    test "never suffixes darwin even with glibc" do
      assert RemoteBootstrap.asset_name("darwin_arm64", :glibc) ==
               "genesis_remote_darwin_arm64.tar.xz"
    end

    test "never suffixes windows even with glibc" do
      assert RemoteBootstrap.asset_name("windows_x64", :glibc) ==
               "genesis_remote_windows_x64.tar.xz"
    end
  end

  describe "detect_libc/1" do
    test "detects musl" do
      assert RemoteBootstrap.detect_libc("musl libc (x86_64)") == :musl
    end

    test "detects musl on aarch64" do
      assert RemoteBootstrap.detect_libc("musl libc (aarch64)") == :musl
    end

    test "detects MUSL case-insensitively" do
      assert RemoteBootstrap.detect_libc("MUSL libc (x86_64)") == :musl
    end

    test "detects glibc" do
      assert RemoteBootstrap.detect_libc("ldd (GNU libc) 2.39") == :glibc
    end

    test "detects GLIBC case-insensitively" do
      assert RemoteBootstrap.detect_libc("ldd (Ubuntu GLIBC 2.39-0ubuntu8.4) 2.39") == :glibc
    end

    test "detects gnu libc" do
      assert RemoteBootstrap.detect_libc("ldd (GNU libc) stable release version 2.31") ==
               :glibc
    end

    test "returns nil for empty string" do
      assert RemoteBootstrap.detect_libc("") == nil
    end

    test "returns nil for unknown libc" do
      assert RemoteBootstrap.detect_libc("some unknown libc implementation") == nil
    end

    test "returns nil for nil input" do
      assert RemoteBootstrap.detect_libc(nil) == nil
    end
  end

  describe "direct_url/1" do
    test "builds the linux_x64 direct URL" do
      assert RemoteBootstrap.direct_url("linux_x64") ==
               "https://genesis.evox.group/dl/genesis_remote_linux_x64.tar.xz"
    end

    test "builds the darwin_arm64 direct URL" do
      assert RemoteBootstrap.direct_url("darwin_arm64") ==
               "https://genesis.evox.group/dl/genesis_remote_darwin_arm64.tar.xz"
    end
  end

  describe "direct_url/2" do
    test "builds the glibc-suffixed URL for linux_x64" do
      assert RemoteBootstrap.direct_url("linux_x64", :glibc) ==
               "https://genesis.evox.group/dl/genesis_remote_linux_x64_glibc.tar.xz"
    end

    test "builds the unsuffixed URL for musl" do
      assert RemoteBootstrap.direct_url("linux_x64", :musl) ==
               "https://genesis.evox.group/dl/genesis_remote_linux_x64.tar.xz"
    end

    test "never suffixes darwin even with glibc" do
      assert RemoteBootstrap.direct_url("darwin_arm64", :glibc) ==
               "https://genesis.evox.group/dl/genesis_remote_darwin_arm64.tar.xz"
    end
  end

  describe "download_url/1" do
    test "returns the direct linux_x64 URL with the latest version (no network)" do
      assert RemoteBootstrap.download_url("linux_x64") ==
               {:ok, "https://genesis.evox.group/dl/genesis_remote_linux_x64.tar.xz", "latest"}
    end

    test "returns the direct darwin_arm64 URL with the latest version (no network)" do
      assert RemoteBootstrap.download_url("darwin_arm64") ==
               {:ok, "https://genesis.evox.group/dl/genesis_remote_darwin_arm64.tar.xz", "latest"}
    end

    test "version is always latest, keying the local download cache" do
      assert {:ok, url, "latest"} = RemoteBootstrap.download_url("windows_x64")

      assert RemoteBootstrap.cache_path("windows_x64", "latest") ==
               Path.join([
                 EvoGit.Platform.data_dir(),
                 "remote_binaries",
                 "windows_x64_latest.tar.xz"
               ])

      assert String.ends_with?(url, "genesis_remote_windows_x64.tar.xz")
    end
  end

  describe "download_url/2" do
    test "returns the glibc-suffixed URL for linux_x64" do
      assert RemoteBootstrap.download_url("linux_x64", :glibc) ==
               {:ok, "https://genesis.evox.group/dl/genesis_remote_linux_x64_glibc.tar.xz",
                "latest"}
    end

    test "returns the unsuffixed URL for musl" do
      assert RemoteBootstrap.download_url("linux_x64", :musl) ==
               {:ok, "https://genesis.evox.group/dl/genesis_remote_linux_x64.tar.xz", "latest"}
    end

    test "returns the unsuffixed URL for darwin even with glibc" do
      assert RemoteBootstrap.download_url("darwin_arm64", :glibc) ==
               {:ok, "https://genesis.evox.group/dl/genesis_remote_darwin_arm64.tar.xz", "latest"}
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
  end

  describe "cache_path/3" do
    test "includes _glibc in the cache filename for glibc" do
      assert RemoteBootstrap.cache_path("linux_x64", "latest", :glibc) ==
               Path.join([
                 EvoGit.Platform.data_dir(),
                 "remote_binaries",
                 "linux_x64_glibc_latest.tar.xz"
               ])
    end

    test "has no suffix for musl (same as default)" do
      assert RemoteBootstrap.cache_path("linux_x64", "latest", :musl) ==
               Path.join([
                 EvoGit.Platform.data_dir(),
                 "remote_binaries",
                 "linux_x64_latest.tar.xz"
               ])
    end

    test "has no suffix when libc is nil (backward compat)" do
      assert RemoteBootstrap.cache_path("linux_x64", "latest") ==
               Path.join([
                 EvoGit.Platform.data_dir(),
                 "remote_binaries",
                 "linux_x64_latest.tar.xz"
               ])

      assert RemoteBootstrap.cache_path("linux_x64", "latest", nil) ==
               Path.join([
                 EvoGit.Platform.data_dir(),
                 "remote_binaries",
                 "linux_x64_latest.tar.xz"
               ])
    end

    test "has no suffix for darwin even with glibc (non-linux)" do
      assert RemoteBootstrap.cache_path("darwin_arm64", "latest", :glibc) ==
               Path.join([
                 EvoGit.Platform.data_dir(),
                 "remote_binaries",
                 "darwin_arm64_latest.tar.xz"
               ])
    end

    test "separates musl and glibc cache entries" do
      musl_path = RemoteBootstrap.cache_path("linux_x64", "latest", :musl)
      glibc_path = RemoteBootstrap.cache_path("linux_x64", "latest", :glibc)

      assert musl_path != glibc_path
    end
  end
end
