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
    cargoHash = "sha256-st8uXR5GqC3ToSRJGWQNZu1I4mX/Stbz2WCVqx8ADoY=";

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

    # tauri-build 2.x validates at compile time (relative to the crate
    # dir) that every path declared in bundle.resources in
    # tauri.conf.json exists — `resources/genesis-backend` must be
    # present when build.rs runs, or the build fails with "resource
    # path `resources/genesis-backend` doesn't exist". The bare git
    # source tree contains no resources/ directory, so we symlink the
    # Elixir release into the unpacked crate source in preBuild (cwd =
    # desktop/src-tauri). Tauri's build.rs embeds the config at compile
    # time; at runtime the binary resolves resources via
    # sidecar_path::resolve_launcher, checking <exe_dir>/resources/…
    # first, then resource_dir() and $CARGO_MANIFEST_DIR (see
    # desktop/src-tauri/src/sidecar_path.rs). The final package below
    # still links the release into place at install time so the runtime
    # resolution finds it next to the binary.
    preBuild = ''
      mkdir -p resources
      ln -s ${genesisRelease} resources/genesis-backend
    '';
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
    librsvg
    libsoup_3
    webkitgtk_4_1
    libayatana-appindicator
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

    # Wrapper script in $out/bin. The full runtime library stack is put on
    # LD_LIBRARY_PATH because Tauri's runtime dlopens these libraries
    # (tray-icon dlopens libayatana-appindicator, wry dlopens WebKitGTK,
    # librsvg provides the SVG pixbuf loader) — on minimal NixOS systems
    # they are not reachable otherwise.
    makeWrapper $out/lib/genesis-desktop/genesis-desktop \
                $out/bin/genesis-desktop \
      --prefix LD_LIBRARY_PATH : "${lib.makeLibraryPath (
        lib.optionals stdenv.isLinux [
          stdenv.cc.cc.lib
          glib
          glib-networking
          gtk3
          librsvg
          libsoup_3
          webkitgtk_4_1
          libayatana-appindicator
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
