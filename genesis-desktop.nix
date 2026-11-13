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
# Rust dependencies are vendored from desktop/src-tauri/Cargo.lock (the single
# source of truth) via cargoLock — the vendor store path is derived purely from
# the lock file contents, so there is NO hash to update when Cargo.lock changes.
# The old cargoHash / lib.fakeHash workflow is obsolete; only if git
# dependencies are ever added must they be declared in cargoLock.outputHashes.
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
  # EGL: the vendor mesa the app must use instead of the host's
  mesa,
  libglvnd,
  # Runtime helpers for the wrapper (Linux)
  wrapGAppsHook3,
}:
let
  pname = "genesis-desktop";
  # Version is read from the repo-root VERSION file (single source of truth),
  # so no manual version bump is needed here.
  version = lib.trim (lib.fileContents ./VERSION);

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

    # Dependencies are vendored from desktop/src-tauri/Cargo.lock (the single
    # source of truth): the vendor directory is derived from the lock file, so
    # no hash needs updating when Cargo.lock changes. If git dependencies are
    # ever added, they must be declared in cargoLock.outputHashes.
    cargoLock.lockFile = ./desktop/src-tauri/Cargo.lock;

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

    # tauri-build's copy_resources copies resources/genesis-backend (a symlink
    # to the immutable Nix store release, files 0444) into the cargo target dir
    # via fs::copy, which preserves mode bits. checkPhase's `cargo test` re-runs
    # the build script, which re-copies and fails with EACCES on the 0444 dests
    # (build.rs panics: "Permission denied (os error 13)"). Make the copies
    # writable after buildPhase so the build-script re-run succeeds.
    postBuild = ''
      chmod -R u+w target/x86_64-unknown-linux-gnu/release/resources
      # Belt and suspenders: also cover any non-tuple-target layout.
      chmod -R u+w target/release/resources 2>/dev/null || true
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
    mesa
    libglvnd
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
    #
    # __EGL_VENDOR_LIBRARY_DIRS OVERRIDES the vendor dirs libglvnd was
    # compiled with (host `/run/opengl-driver/share/glvnd/egl_vendor.d`,
    # `/etc/glvnd/egl_vendor.d`, `/usr/share/glvnd/egl_vendor.d`). On a NixOS
    # host those point at a mesa built against the host's own glibc, which can
    # be NEWER than this package's glibc pin; dlopen of libEGL_mesa.so.0 then
    # fails with "version `GLIBC_2.4x' not found", glvnd finds no usable EGL
    # vendor, eglGetDisplay returns EGL_NO_DISPLAY and WebKitWebProcess aborts
    # with "Could not create default EGL display: EGL_BAD_PARAMETER" (blank
    # window, dashboard never loads). Pointing glvnd at the mesa this package
    # was built with keeps the EGL stack glibc-consistent, and on non-NixOS
    # hosts (where /run/opengl-driver does not exist) it is simply the only
    # vendor dir. No EGL_PLATFORM or WebKit workaround is set: none is needed.
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
          mesa
          libglvnd
        ]
      )}" \
      --set-default __EGL_VENDOR_LIBRARY_DIRS "${mesa}/share/glvnd/egl_vendor.d"
  '';

  meta = with lib; {
    description = "EvoX Genesis — Tauri-wrapped native app for the Genesis dashboard";
    mainProgram = "genesis-desktop";
    platforms = platforms.linux ++ platforms.darwin;
    license = licenses.mit;
  };
}
