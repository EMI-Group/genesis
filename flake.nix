{
  description = "EvoGit desktop app — NixOS development environment for building and testing the Tauri + Burrito desktop app locally";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
    flake-utils.url = "github:numtide/flake-utils";
    # Burrito 1.5.0 (pinned in mix.lock) hard-requires exactly Zig 0.15.2 —
    # it calls exit(1) on any other version. nixpkgs does not ship 0.15.x yet,
    # so we use the zig-overlay which mirrors official Zig binaries.
    zig-overlay = {
      url = "github:mitchellh/zig-overlay";
      # Share nixpkgs to avoid a duplicate download.
      inputs.nixpkgs.follows = "nixpkgs";
    };
  };

  outputs = { self, nixpkgs, flake-utils, zig-overlay }:
    flake-utils.lib.eachDefaultSystem (system:
      let
        pkgs = nixpkgs.legacyPackages.${system};
        lib = pkgs.lib;

        # ── BEAM toolchain ──────────────────────────────────────────
        # Erlang/OTP 29 + Elixir 1.20, matching .tool-versions.
        beamPkgs = pkgs.beam.packagesWith pkgs.beam.interpreters.erlang_29;
        erlang = beamPkgs.erlang;
        elixir = beamPkgs.elixir_1_20;

        # ── Zig ─────────────────────────────────────────────────────
        # Burrito 1.5.0 requires exactly Zig 0.15.2.
        zig = zig-overlay.packages.${system}."0.15.2";

        # ── Tauri v2 native dependencies (Linux only) ──────────────
        # These are the NixOS equivalents of the apt packages installed by
        # the GitHub Actions workflow (libwebkit2gtk-4.1-dev, librsvg2-dev,
        # libayatana-appindicator3-dev, libssl-dev, etc.).
        tauriNativeDeps = lib.optionals pkgs.stdenv.isLinux (with pkgs; [
          webkitgtk_4_1
          gtk3
          glib
          glib-networking # TLS support for WebKit HTTP requests
          librsvg
          libayatana-appindicator
          libsoup_3
          openssl
          xdo # libxdo — X11 automation (Tauri build-time dep)
        ]);

        # ── Tauri runtime helpers (Linux only) ─────────────────────
        tauriRuntimeDeps = lib.optionals pkgs.stdenv.isLinux [
          pkgs.dconf # GSettings backend (required by GTK at runtime)
          pkgs.hicolor-icon-theme # icon theme needed by app bundles
        ];
      in
      {
        devShells.default = pkgs.mkShell {
          # pkg-config must be in nativeBuildInputs so the Rust/Tauri build
          # can locate the webkit/gtk libraries via *.pc files.
          nativeBuildInputs = [ pkgs.pkg-config ];

          buildInputs = [
            # ── BEAM toolchain ──
            erlang
            elixir

            # ── Rust toolchain ──
            pkgs.cargo
            pkgs.rustc
            pkgs.rustfmt
            pkgs.clippy

            # ── Zig (Burrito wrapper compiler) ──
            zig

            # ── Core build tools ──
            pkgs.gnumake
            pkgs.gcc # C compiler for NIF compilation (mdex, lumis)
            pkgs.file # required by Tauri's bundling step
            pkgs.xz # required by Burrito for payload compression
            pkgs.curl # for downloading vendor binaries

            # ── Vendor binaries (bundled into the release) ──
            pkgs.ripgrep
            pkgs.git
          ] ++ tauriNativeDeps
            ++ tauriRuntimeDeps;

          shellHook = ''
            ${lib.optionalString pkgs.stdenv.isLinux ''
              # Let GLib/GIO find the networking and dconf modules at runtime.
              export GIO_EXTRA_MODULES="${pkgs.glib-networking}/lib/gio/modules:${pkgs.dconf}/lib/gio/modules"
              # Work around WebKit rendering issues under certain compositors.
              export WEBKIT_DISABLE_DMABUF_RENDERER=1
            ''}

            # Default to native Linux x86_64 for Burrito (change to linux_arm64 on aarch64).
            export BURRITO_TARGET="''${BURRITO_TARGET:-linux_x64}"

            echo ""
            echo "  ┌─────────────────────────────────────────────┐"
            echo "  │  EvoGit Desktop — NixOS Development Shell    │"
            echo "  └─────────────────────────────────────────────┘"
            echo ""
            echo "  Toolchain:"
            echo "    Erlang/OTP : $(erl -noshell -eval '{ok,V}=file:read_file(filename:join([code:root_dir(),"releases",erlang:system_info(otp_release),"OTP_VERSION"])), io:format("OTP ~s",[string:trim(V)]), halt()' 2>/dev/null || echo 'unknown')"
            echo "    Elixir     : $(elixir --version 2>/dev/null | tail -1 || echo 'unknown')"
            echo "    Zig        : $(zig version 2>/dev/null || echo 'unknown')"
            echo "    Rust       : $(rustc --version 2>/dev/null || echo 'unknown')"
            echo ""
            echo "  ── Build the desktop app ─────────────────────"
            echo ""
            echo "  # 1. Fetch Elixir dependencies"
            echo "  mix deps.get"
            echo ""
            echo "  # 2. Build and digest frontend assets"
            echo "  mix assets.setup && mix assets.deploy"
            echo ""
            echo "  # 3. Install Tauri CLI v2 (first time only)"
            echo "  cargo install tauri-cli --version \"^2.0\""
            echo ""
            echo "  # 4. Bundle vendor binaries into the release"
            echo "  ./nix/bundle-vendor.sh"
            echo ""
            echo "  # 5. Build the Burrito-wrapped Elixir release"
            echo "  MIX_ENV=prod mix release evogit_desktop"
            echo ""
            echo "  # 6. Place the sidecar binary where Tauri expects it"
            echo "  mkdir -p desktop/src-tauri/sidecars"
            echo "  cp burrito_out/evogit_desktop_* desktop/src-tauri/sidecars/evogit-backend-$(rustc -vV | sed -n 's/host: //p')"
            echo ""
            echo "  # 7. Build the Tauri desktop app"
            echo "  cd desktop/src-tauri && cargo tauri build"
            echo ""
          '';
        };
      }
    );
}
