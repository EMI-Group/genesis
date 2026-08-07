# genesis.nix — Nix derivation for the Genesis application.
#
# Builds a Mix release of the Genesis umbrella project (evo_git + evo_dash)
# with pre-fetched Rustler NIFs and vendored system binaries (ripgrep + git).
#
# Usage (from the flake):
#   nix build   — build the release
#   nix run     — start the Genesis app
#
# After updating mix.lock or NIF versions, update the hashes below. Use
# `lib.fakeHash` as a placeholder, build, and copy the reported hashes.
{ 
  src,
  beamPackages,
  tailwindcss_4,
  esbuild,
  ripgrep,
  git,
  stdenv,
  fetchurl,
  lib,
  mixReleaseName ? "genesis",
}:
let
  # ── App metadata ──────────────────────────────────────────────────
  pname = "genesis";
  version = "0.8.6";

  # ── Mix dependencies ──────────────────────────────────────────────
  # Lockfile-driven dependency fetch. Update this hash when mix.lock changes.
  mixFodDeps = beamPackages.fetchMixDeps {
    pname = "mix-deps-${pname}";
    inherit src version;
    hash = "sha256-+3388XM/R8LX2aP7uDlHf4so8dCn39sSDI0WnZNjHKM=";
  };

  # ── Platform mapping ──────────────────────────────────────────────
  # Map the Nix system string to a Rust target triple for precompiled NIFs.
  rustTarget =
    if stdenv.hostPlatform.isLinux && stdenv.hostPlatform.isx86_64 then
      "x86_64-unknown-linux-gnu"
    else if stdenv.hostPlatform.isLinux && stdenv.hostPlatform.isAarch64 then
      "aarch64-unknown-linux-gnu"
    else if stdenv.hostPlatform.isDarwin && stdenv.hostPlatform.isx86_64 then
      "x86_64-apple-darwin"
    else if stdenv.hostPlatform.isDarwin && stdenv.hostPlatform.isAarch64 then
      "aarch64-apple-darwin"
    else
      throw "Unsupported platform: ${stdenv.hostPlatform.system}";

  # Compute the vendor platform directory name used by EvoGit.Executable.
  # On Linux: "linux-x86_64" or "linux-arm64".
  # On macOS: "macos-x86_64" or "macos-arm64".
  vendorPlatform =
    let
      arch = if stdenv.hostPlatform.isx86_64 then "x86_64" else "arm64";
    in
    if stdenv.hostPlatform.isLinux then
      "linux-${arch}"
    else if stdenv.hostPlatform.isDarwin then
      "macos-${arch}"
    else
      throw "Unsupported platform for vendor binaries: ${stdenv.hostPlatform.system}";

  # ── Precompiled NIFs ──────────────────────────────────────────────
  # Each entry describes a precompiled Rustler NIF tarball. The NIF version
  # (e.g. 2.15, 2.17) is tied to the Erlang/OTP ABI that the package was
  # compiled against. These are per-package and may differ.
  #
  # Actual release names/tags were verified against the respective GitHub
  # repositories (2025-07).
  #
  # To update hashes: use lib.fakeHash, build, then copy the reported hashes.
  precompiled_nifs = [
    # ── lumis 0.6.3 ──────────────────────────────────────────────
    {
      name = "liblumis_nif-v0.6.3-nif-2.15-${rustTarget}.so.tar.gz";
      version = "0.6.3";
      file = fetchurl {
        url =
          "https://github.com/leandrocp/lumis/releases/download/hex-lumis%2Fv0.6.3/"
          + "liblumis_nif-v0.6.3-nif-2.15-${rustTarget}.so.tar.gz";
        hash = "sha256-SqvVkgNljREPvsg2jKAN7BpWZmgGMAUxZ/neUTrXXiA=";
      };
    }

    # ── mdex_native 0.2.7 (base) ──────────────────────────────────
    {
      name = "libmdex_native_nif-v0.2.7-nif-2.15-${rustTarget}.so.tar.gz";
      version = "0.2.7";
      file = fetchurl {
        url =
          "https://github.com/leandrocp/mdex_native/releases/download/v0.2.7/"
          + "libmdex_native_nif-v0.2.7-nif-2.15-${rustTarget}.so.tar.gz";
        hash = "sha256-8MvCRKDqtgM/lf3A3F7MxTRZA4EFTlG94xz0TJob6AY=";
      };
    }

    # ── mdex_native 0.2.7 (--lumis variant) ──────────────────────
    # This variant is required when lumis is also a dependency (which it is
    # in the Genesis project). Without it, mdex_native fails to load because
    # the rustler_precompiled loader looks for the feature-specific binary.
    {
      name = "libmdex_native_nif-v0.2.7-nif-2.15-${rustTarget}--lumis.so.tar.gz";
      version = "0.2.7";
      file = fetchurl {
        url =
          "https://github.com/leandrocp/mdex_native/releases/download/v0.2.7/"
          + "libmdex_native_nif-v0.2.7-nif-2.15-${rustTarget}--lumis.so.tar.gz";
        hash = "sha256-02P3ONjNGMkrz2+LG7cGC9IDowCWBpGG+OcSui45TKc=";
      };
    }

    # ── html5ever 0.18.0 ─────────────────────────────────────────═
    # Note: this package lives under rusterlium/html5ever_elixir, not
    # leandrocp/html5ever as one might expect.
    {
      name = "libhtml5ever_nif-v0.18.0-nif-2.15-${rustTarget}.so.tar.gz";
      version = "0.18.0";
      file = fetchurl {
        url =
          "https://github.com/rusterlium/html5ever_elixir/releases/download/v0.18.0/"
          + "libhtml5ever_nif-v0.18.0-nif-2.15-${rustTarget}.so.tar.gz";
        hash = "sha256-7BoEq16kT9dRm0B/bljH2bDX/UgDHcnjliOg3TtigmI=";
      };
    }

    # ── xqlite 0.10.0 ───────────────────────────────────────────═
    # Note: this package lives under dimitarvp/xqlite, not leandrocp/xqlite.
    # The library prefix is "libxqlitenif" (no underscore between xqlite and nif).
    {
      name = "libxqlitenif-v0.10.0-nif-2.17-${rustTarget}.so.tar.gz";
      version = "0.10.0";
      file = fetchurl {
        url =
          "https://github.com/dimitarvp/xqlite/releases/download/v0.10.0/"
          + "libxqlitenif-v0.10.0-nif-2.17-${rustTarget}.so.tar.gz";
        hash = "sha256-yO0mFn7IXcs5j1T6vK6YQFNNUkMISaOXUW5+6SwmmL4=";
      };
    }
  ];
in
beamPackages.mixRelease {
  inherit pname version src mixFodDeps;

  # Build the specified release. Default is "genesis" (CLI, both evo_git + evo_dash).
  # Pass mixReleaseName = "genesis_desktop" for the Tauri-desktop variant.
  inherit mixReleaseName;

  # ── Build-time tools ────────────────────────────────────────────
  nativeBuildInputs = [
    tailwindcss_4
    esbuild
  ];

  # Point the tailwind/esbuild hex packages at the system-provided binaries.
  # These env vars are read by config/config.exs which sets :path on the
  # :tailwind and :esbuild application config, causing the hex packages to
  # use the pre-installed binary instead of downloading one at build time.
  TAILWIND_BIN = "${tailwindcss_4}/bin/tailwindcss";
  ESBUILD_BIN = "${esbuild}/bin/esbuild";

  # ── Precompiled NIF cache ───────────────────────────────────────
  # Rustler precompiled looks for tarballs in this directory. We populate it
  # with pre-fetched NIFs so the build works inside the Nix sandbox (no network).
  preConfigure = ''
    export RUSTLER_PRECOMPILED_GLOBAL_CACHE_PATH=$TMPDIR/rustler_precompiled_cache
    mkdir -p $RUSTLER_PRECOMPILED_GLOBAL_CACHE_PATH
    ${builtins.concatStringsSep "\n" (
      map (nif: ''
        echo "Populating Rustler cache with ${nif.name}"
        cp ${nif.file} $RUSTLER_PRECOMPILED_GLOBAL_CACHE_PATH/${nif.name}
      '') precompiled_nifs
    )}
    ls -l $RUSTLER_PRECOMPILED_GLOBAL_CACHE_PATH
  '';

  # ── Asset pipeline ──────────────────────────────────────────────
  # Deploy frontend assets (Tailwind CSS, esbuild, phx.digest) after
  # compilation but before the release is assembled.
  postBuild = ''
    mix do deps.loadpaths --no-deps-check, assets.deploy
  '';

  # ── Vendor binaries ─────────────────────────────────────────────
  # Copy ripgrep and git into the evo_git priv/vendor directory so
  # EvoGit.Executable can find them at runtime via Application.app_dir.
  postInstall = ''
    vendor_dir=$out/lib/evo_git-${version}/priv/vendor/${vendorPlatform}
    mkdir -p "$vendor_dir"
    cp ${ripgrep}/bin/rg "$vendor_dir/rg"
    cp ${git}/bin/git "$vendor_dir/git"
    chmod +x "$vendor_dir"/*
    echo "Vendor binaries installed to $vendor_dir"
    ls -l "$vendor_dir"

    # Mix release launcher cookie. bin/<release> reads
    # $RELEASE_ROOT/releases/COOKIE when RELEASE_COOKIE is unset; the
    # Nix store is read-only, so a deterministic cookie must be baked in
    # at build time or the launcher fails with "cat: .../COOKIE: No such
    # file or directory" (this surfaced in both GUI and --headless runs
    # of the nix-built desktop app).
    echo -n "genesis-nix-${version}" > "$out/releases/COOKIE"
    echo "Release cookie written to $out/releases/COOKIE"
  '';
}
