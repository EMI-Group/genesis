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

  describe "asset_name/1 and asset_matches?/2" do
    test "asset_name/1 builds the tarball name" do
      assert RemoteBootstrap.asset_name("linux_x64") ==
               "genesis_remote_linux_x64.tar.gz"
    end

    test "matches an unversioned asset" do
      assert RemoteBootstrap.asset_matches?("genesis_remote_linux_x64.tar.gz", "linux_x64")
    end

    test "matches a versioned asset" do
      assert RemoteBootstrap.asset_matches?("genesis_remote_0.1.0_linux_x64.tar.gz", "linux_x64")
    end

    test "rejects an asset for a different platform" do
      refute RemoteBootstrap.asset_matches?("genesis_remote_darwin_arm64.tar.gz", "linux_x64")
    end

    test "rejects an asset with no platform suffix" do
      refute RemoteBootstrap.asset_matches?("genesis_remote_0.1.0.tar.gz", "linux_x64")
    end
  end

  describe "direct_url/1" do
    test "builds the linux_x64 direct URL" do
      assert RemoteBootstrap.direct_url("linux_x64") ==
               "https://github.com/EMI-Group/genesis/releases/latest/download/genesis_remote_linux_x64.tar.gz"
    end

    test "builds the darwin_arm64 direct URL" do
      assert RemoteBootstrap.direct_url("darwin_arm64") ==
               "https://github.com/EMI-Group/genesis/releases/latest/download/genesis_remote_darwin_arm64.tar.gz"
    end
  end

  describe "cache_path/2" do
    test "builds the cache path under the platform data dir" do
      assert RemoteBootstrap.cache_path("linux_x64", "0.1.0") ==
               Path.join([
                 EvoGit.Platform.data_dir(),
                 "remote_binaries",
                 "linux_x64_0.1.0.tar.gz"
               ])
    end

    test "handles the latest version" do
      assert RemoteBootstrap.cache_path("darwin_arm64", "latest") ==
               Path.join([
                 EvoGit.Platform.data_dir(),
                 "remote_binaries",
                 "darwin_arm64_latest.tar.gz"
               ])
    end
  end
end
