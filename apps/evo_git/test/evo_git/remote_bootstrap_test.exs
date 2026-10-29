defmodule EvoGit.RemoteBootstrapTest do
  use ExUnit.Case, async: true

  alias EvoGit.RemoteBootstrap
  alias EvoGit.RemoteDaemon

  # Constructs the remote login shell may not be able to parse (the inner
  # interpreter is POSIX `sh`, and the OUTER login shell may be anything).
  @bashisms ["[[", " source ", " local ", " type -t", "pushd"]

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

    test "runs all seven nix-builds with 2>&1" do
      script = RemoteBootstrap.nixos_patch_script(@launcher)

      assert script =~ ~S|nix-build "$NIXPKGS" -A patchelf --out-link "$PATCH_DIR/patchelf" 2>&1|
      assert script =~ ~S|nix-build "$NIXPKGS" -A bintools --out-link "$PATCH_DIR/bintools" 2>&1|

      assert script =~
               ~S|nix-build "$NIXPKGS" -A stdenv.cc.cc.lib --out-link "$PATCH_DIR/cc" 2>&1|

      assert script =~
               ~S|nix-build "$NIXPKGS" -A openssl.out --out-link "$PATCH_DIR/openssl" 2>&1|

      assert script =~ ~S|nix-build "$NIXPKGS" -A zlib --out-link "$PATCH_DIR/zlib" 2>&1|
      assert script =~ ~S|nix-build "$NIXPKGS" -A ncurses --out-link "$PATCH_DIR/ncurses" 2>&1|
      assert script =~ ~S|nix-build "$NIXPKGS" -A pcre2.out --out-link "$PATCH_DIR/pcre2" 2>&1|
      # nixpkgs comes from NIX_PATH via the angle-bracket lookup path
      assert script =~ ~S|NIXPKGS="<nixpkgs>"|
    end

    test "aliases the cc-lib out-link so the RPATH cc entry always resolves" do
      script = RemoteBootstrap.nixos_patch_script(@launcher)

      # nix-build names the out-link "$PATCH_DIR/cc-lib" because the attr
      # selects the non-default `lib` output; the script aliases it as cc
      assert script =~ ~S|if [ ! -e "$PATCH_DIR/cc" ]; then|
      assert script =~ ~S|ln -s "$PATCH_DIR/cc-lib" "$PATCH_DIR/cc"|
      assert script =~ ~S|fi|
    end

    test "reads the interpreter from the bintools nix-support file" do
      script = RemoteBootstrap.nixos_patch_script(@launcher)

      assert script =~ ~S|INTERPRETER="$(cat "$PATCH_DIR/bintools/nix-support/dynamic-linker")"|
    end

    test "sets the rpath from cc, openssl, zlib, ncurses and pcre2 lib dirs" do
      script = RemoteBootstrap.nixos_patch_script(@launcher)

      assert script =~
               ~S|RPATH="$PATCH_DIR/cc/lib:$PATCH_DIR/openssl/lib:$PATCH_DIR/zlib/lib:$PATCH_DIR/ncurses/lib:$PATCH_DIR/pcre2/lib"|
    end

    test "loops over release files with an ELF magic check and invokes patchelf" do
      script = RemoteBootstrap.nixos_patch_script(@launcher)

      assert script =~ ~S|for file in $(find "$RELEASE_ROOT" -type f); do|
      assert script =~ ~S|head -c 4 "$file"|
      assert script =~ ~S|od -An -tx1|
      assert script =~ ~S|tr -d " \n"|
      assert script =~ ~S|7f454c46|

      assert script =~
               ~S|"$PATCH_DIR/patchelf/bin/patchelf" --set-interpreter "$INTERPRETER" --set-rpath "$RPATH" "$file"|
    end

    test "guards the full patch behind a PT_INTERP probe" do
      script = RemoteBootstrap.nixos_patch_script(@launcher)

      assert script =~
               ~S|if "$PATCH_DIR/patchelf/bin/patchelf" --print-interpreter "$file" >/dev/null 2>&1; then|
    end

    test "patches shared libraries rpath-only" do
      script = RemoteBootstrap.nixos_patch_script(@launcher)

      # shared libs are distinguished from static-pie binaries by NEEDED deps
      assert script =~
               ~S("$PATCH_DIR/bintools/bin/readelf" -d "$file" 2>/dev/null | grep -q NEEDED)

      assert script =~ ~S|echo "nixos-patch: setting rpath on $file"|
      assert script =~ ~S|"$PATCH_DIR/patchelf/bin/patchelf" --set-rpath "$RPATH" "$file"|
    end

    test "skips truly static binaries" do
      script = RemoteBootstrap.nixos_patch_script(@launcher)

      assert script =~ ~S|echo "nixos-patch: skipping static binary $file"|
    end

    test "echoes nixos-patch progress markers and uses set -e" do
      script = RemoteBootstrap.nixos_patch_script(@launcher)

      assert script =~ "nixos-patch: building patchelf..."
      assert script =~ "nixos-patch: building bintools..."
      assert script =~ "nixos-patch: building stdenv.cc.cc.lib..."
      assert script =~ "nixos-patch: building openssl..."
      assert script =~ "nixos-patch: building zlib..."
      assert script =~ "nixos-patch: building ncurses..."
      assert script =~ "nixos-patch: building pcre2..."

      assert script =~
               ~S|echo "nixos-patch: patched $count executables, set rpath on $rpath_count ELF files"|

      assert script =~ "set -e"
    end
  end

  describe "sh_wrap/1" do
    test "wraps a plain command as a command word + ONE single-quoted word" do
      assert RemoteBootstrap.sh_wrap("cmd") == "/bin/sh -c 'cmd'"
    end

    test "wraps an empty command" do
      assert RemoteBootstrap.sh_wrap("") == "/bin/sh -c ''"
    end

    test "wraps the single-quote-free NixOS detection command verbatim" do
      # The detection command uses double quotes (not `'`) precisely so the
      # plain `<interpreter> -c '<script>'` form survives nushell/tcsh.
      assert RemoteBootstrap.sh_wrap(RemoteBootstrap.nixos_detect_command()) ==
               ~S{/bin/sh -c 'test -d /etc/nixos && echo yes || grep -qi "^ID=nixos" /etc/os-release 2>/dev/null && echo yes || echo no'}
    end

    test "wraps the NixOS patch script verbatim (no escaping needed)" do
      wrapped = RemoteBootstrap.sh_wrap(RemoteBootstrap.nixos_patch_script(@launcher))

      assert String.starts_with?(wrapped, "/bin/sh -c '#!/bin/sh")
      assert String.ends_with?(wrapped, "'")
      # the script quotes with `"` only, so it rides the wrapper unchanged
      assert String.contains?(wrapped, ~S|tr -d " \n"|)
      refute String.contains?(wrapped, "'\\''")
    end

    test "honours the :remote_shell app-env interpreter override" do
      # The interpreter is read at CALL time (test seam) — an alternative
      # POSIX shell keeps the same command-word + single-quoted-word shape.
      # `async: true` is safe: `sh_wrap/1` is the ONLY reader of this key, and
      # the other suite that drives it (`remote_connection_test`) is sync.
      Application.put_env(:evo_git, :remote_shell, "/usr/local/bin/dash")
      on_exit(fn -> Application.delete_env(:evo_git, :remote_shell) end)

      assert RemoteBootstrap.sh_wrap("cmd") == "/usr/local/bin/dash -c 'cmd'"
    end

    test "falls back to POSIX close-quote/escaped-quote/reopen-quote escaping" do
      # Last-resort form for a script that DOES carry a `'` — parses under
      # POSIX-ish shells and fish, which is why remote commands never carry one.
      assert RemoteBootstrap.sh_wrap("echo 'hi'") == "/bin/sh -c 'echo '\\''hi'\\'''"
    end
  end

  # WHY: sshd hands the remote command to the remote user's LOGIN shell
  # (`$SHELL -c "<command>"`). The only form that parses identically under
  # fish / nushell / tcsh / POSIX sh is a plain command word plus ONE
  # single-quoted word — and nushell/tcsh cannot parse a single-quoted word
  # that CONTAINS `'` at all (the `'\''` fallback only helps POSIX-ish shells
  # + fish). Every remote command must therefore stay single-quote-free and
  # bash-ism-free, or the wrapper breaks on a real login shell.
  describe "login-shell compatibility contract" do
    test "bootstrap commands are single-quote-free and bash-ism-free" do
      commands = [
        RemoteBootstrap.nixos_detect_command(),
        RemoteBootstrap.nixos_patch_script("/tmp/genesis_remote/bin/genesis_remote")
      ]

      for command <- commands, do: assert_login_shell_safe!(command)
    end

    test "every RemoteDaemon command builder is login-shell safe in BOTH scopes" do
      unit = "genesis-remote-abc123"
      node = "genesis_remote_abc123@127.0.0.1"
      cookie = "s3cret"
      launcher = "/tmp/genesis_remote/bin/genesis_remote"

      for scope <- [:user, :system] do
        commands = [
          RemoteDaemon.login_user_probe_command(),
          RemoteDaemon.is_active_command(scope, unit),
          RemoteDaemon.show_environment_command(scope, unit),
          RemoteDaemon.reset_failed_command(scope, unit),
          RemoteDaemon.stop_command(scope, unit),
          RemoteDaemon.status_command(scope, unit),
          RemoteDaemon.start_command(scope, unit, node, cookie, launcher),
          RemoteDaemon.show_environment_hint(scope, unit),
          RemoteDaemon.stop_hint(scope, unit)
        ]

        for command <- commands, do: assert_login_shell_safe!(command)
      end
    end
  end

  # Asserts a remote command carries no `'` and no bash-ism, and that the
  # wrapper around it stays the plain `<interpreter> -c '<script>'` form (i.e.
  # never needs the `'\''` fallback).
  defp assert_login_shell_safe!(command) do
    assert is_binary(command)

    refute String.contains?(command, "'"),
           "remote command contains a single quote: #{inspect(command)}"

    for bashism <- @bashisms do
      refute String.contains?(command, bashism),
             "remote command contains the bash-ism #{inspect(bashism)}: #{inspect(command)}"
    end

    wrapped = RemoteBootstrap.sh_wrap(command)

    assert String.starts_with?(wrapped, "/bin/sh -c '")
    assert String.ends_with?(wrapped, "'")

    refute String.contains?(wrapped, "'\\''"),
           "wrapper needed quote escaping: #{inspect(wrapped)}"

    command
  end

  describe "parse_unit_environment/1" do
    test "parses space-separated KEY=value tokens" do
      assert RemoteBootstrap.parse_unit_environment(
               "RELEASE_NODE=genesis_remote_x@127.0.0.1 RELEASE_COOKIE=abc123"
             ) == %{"RELEASE_NODE" => "genesis_remote_x@127.0.0.1", "RELEASE_COOKIE" => "abc123"}
    end

    test "parses multi-line output" do
      assert RemoteBootstrap.parse_unit_environment(
               "RELEASE_NODE=genesis_remote_x@127.0.0.1\nRELEASE_COOKIE=abc123\n"
             ) == %{"RELEASE_NODE" => "genesis_remote_x@127.0.0.1", "RELEASE_COOKIE" => "abc123"}
    end

    test "strips double quotes around values containing spaces" do
      assert RemoteBootstrap.parse_unit_environment(~s|FOO=bar BAZ="hello world" QUX=1|) ==
               %{"FOO" => "bar", "BAZ" => "hello world", "QUX" => "1"}
    end

    test "returns empty map for empty / whitespace-only input" do
      assert RemoteBootstrap.parse_unit_environment("") == %{}
      assert RemoteBootstrap.parse_unit_environment("   \n  ") == %{}
    end

    test "skips tokens without an equals sign" do
      assert RemoteBootstrap.parse_unit_environment("RELEASE_NODE=abc stray RELEASE_COOKIE=xyz") ==
               %{"RELEASE_NODE" => "abc", "RELEASE_COOKIE" => "xyz"}
    end

    test "handles empty values" do
      assert RemoteBootstrap.parse_unit_environment("RELEASE_NODE= RELEASE_COOKIE=") ==
               %{"RELEASE_NODE" => "", "RELEASE_COOKIE" => ""}
    end
  end
end
