# genesis-desktop.nix — Nix derivation for the Genesis Tauri desktop app.
#
# Builds the Elixir Mix release (genesis_desktop variant), then builds the
# Tauri Rust binary and wraps them together so the binary can find the
# release at runtime.
#
# Usage (from the flake):
#   nix build .#desktop   — build the Tauri desktop app
#   nix run   .#desktop   — launch the Genesis desktop app
#
# After updating Cargo.lock, update cargoHash below. Use lib.fakeHash as a
# placeholder, build, and copy the reported hash.
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
  rustPlatform,
  makeWrapper,
  pkg-config,
  openssl,
  file,
  # Linux-only dependencies for Tauri's WebView
  webkitgtk_4_1,
  gtk3,
  glib,
  glib-networking,
  librsvg,
  libayatana-appindicator,
  libsoup_3,
  xdo,
  # Runtime helpers for the wrapper (Linux)
  wrapGAppsHook3,
}:
let
  pname = "genesis-desktop";
  version = "0.8.6";

  # ── Elixir desktop release ─────────────────────────────────────────
  genesisRelease = import ./genesis.nix {
    inherit
      src
      beamPackages
      tailwindcss_4
      esbuild
      ripgrep
      git
      stdenv
      fetchurl
      lib
      ;
    mixReleaseName = "genesis_desktop";
  };

  # ── Tauri Rust binary ──────────────────────────────────────────────
  tauriBinary = rustPlatform.buildRustPackage {
    pname = "${pname}-bin";
    inherit version;
    src = src + "/desktop/src-tauri";

    # Update this hash when Cargo.lock changes.
    cargoHash = lib.fakeHash;

    nativeBuildInputs = [
      pkg-config
      file
    ];

    buildInputs =
      [
        openssl
      ]
      ++ lib.optionals stdenv.isLinux [
        webkitgtk_4_1
        gtk3
        glib
        glib-networking
        librsvg
        libayatana-appindicator
        libsoup_3
        xdo
      ];

    # Tauri's build.rs embeds the config at compile time; the runtime
    # resolves resources relative to the binary (exe_dir/resources/…).
    # We don't bundle resources at build time — they are linked into the
    # final package below via symlink.
  };
in
# ── Final package: binary + release in the expected layout ───────────
stdenv.mkDerivation {
  inherit pname version;

  nativeBuildInputs = [
    makeWrapper
  ] ++ lib.optionals stdenv.isLinux [
    wrapGAppsHook3
  ];

  buildInputs = lib.optionals stdenv.isLinux [
    glib
    glib-networking
    gtk3
  ];

  dontUnpack = true;

  installPhase = ''
    mkdir -p $out/lib/genesis-desktop/resources
    mkdir -p $out/bin

    # Copy the Tauri binary into the lib directory. The binary resolves
    # the release at <exe_dir>/resources/genesis-backend/bin/<launcher>.
    cp ${tauriBinary}/bin/genesis-desktop $out/lib/genesis-desktop/genesis-desktop

    # Symlink the Elixir release so the Tauri binary finds it at runtime.
    ln -s ${genesisRelease} $out/lib/genesis-desktop/resources/genesis-backend

    # Wrapper script in $out/bin.
    makeWrapper $out/lib/genesis-desktop/genesis-desktop \
                $out/bin/genesis-desktop \
      --prefix LD_LIBRARY_PATH : "${lib.makeLibraryPath (
        lib.optionals stdenv.isLinux [
          stdenv.cc.cc.lib
        ]
      )}"
  '';

  meta = with lib; {
    description = "Genesis Desktop — Tauri-wrapped native app for the Genesis dashboard";
    mainProgram = "genesis-desktop";
    platforms = platforms.linux ++ platforms.darwin;
    license = licenses.mit;
  };
}
