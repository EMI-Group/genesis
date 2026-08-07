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
    hash = lib.fakeHash;
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
  # Build a precompiled NIF entry for the current target platform.
  # `tag` defaults to "v{version}" but some repos use a custom tag (e.g. lumis).
  mkNif =
    {
      repo,       # GitHub owner/repo (e.g. "leandrocp/lumis")
      version,    # Package version (e.g. "0.6.3")
      name,       # Library prefix (e.g. "liblumis_nif")
      tag ? "v${version}",  # Git tag on the release
    }:
    let
      target = rustTarget;
      filename = "${name}-v${version}-nif-2.17-${target}.so.tar.gz";
    in
    {
      inherit version;
      name = filename;
      file = fetchurl {
        url = "https://github.com/${repo}/releases/download/${tag}/${filename}";
        hash = lib.fakeHash;
      };
    };

  # All precompiled NIFs needed at build time.
  # Each entry maps to a Rustler-precompiled tarball for the current target.
  precompiled_nifs = [
    (mkNif {
      repo = "leandrocp/lumis";
      version = "0.6.3";
      name = "liblumis_nif";
      tag = "hex-lumis%2Fv0.6.3";
    })
    (mkNif {
      repo = "leandrocp/mdex_native";
      version = "0.2.7";
      name = "libmdex_native_nif";
    })
    (mkNif {
      repo = "leandrocp/html5ever";
      version = "0.18.0";
      name = "libhtml5ever_nif";
    })
    (mkNif {
      repo = "leandrocp/xqlite";
      version = "0.10.0";
      name = "libxqlite_nif";
    })
  ];
in
beamPackages.mixRelease {
  inherit pname version src mixFodDeps;

  # Build the "genesis" release (both evo_git + evo_dash, no desktop flag).
  mixReleaseName = "genesis";

  # ── Build-time tools ────────────────────────────────────────────
  nativeBuildInputs = [
    tailwindcss_4
    esbuild
  ];

  # Point the Phoenix tailwind/esbuild hex packages at the system-provided
  # binaries instead of downloading platform-specific versions at build time.
  TAILWIND_PATH = "${tailwindcss_4}/bin/tailwindcss";
  ESBUILD_PATH = "${esbuild}/bin/esbuild";

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
  '';
}
