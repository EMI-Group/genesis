<h1 align="center">
  <img src="apps/evo_dash/priv/static/images/logo.svg" alt="" height="28" style="vertical-align: middle;"> Genesis
</h1>

<p align="center">
  The recursive agentic <strong>system</strong>.
</p>

<p align="center">
  <a href="https://github.com/BillHuang2001/genesis/releases"><img src="https://img.shields.io/badge/version-0.8.5-8b5cf6" alt="Version"></a>
  <img src="https://img.shields.io/badge/license-AGPL--3.0-blue" alt="License">
  <a href="https://genesis-doc.evoxgroup.workers.dev/"><img src="https://img.shields.io/badge/docs-genesis_doc-22c55e" alt="Documentation"></a>
</p>

---

EvoX Genesis reimagines how software gets written. Instead of a single chat that runs out of room, it runs a **system** that recursively splits your project into a hierarchy of focused tasks — each agent working only where it should, with its own context and its own clean copy of the code.

It's evolutionary: every change lands on a branch of the Git history, and partial progress is celebrated. A version that passes more tests or ships one more feature is a step forward — even if other pieces are still in flight.

### ✨ Highlights

- 🔭 **Scales without limits** — Recursive decomposition keeps every agent's context small. Projects of a million lines or more present no special challenge — size is a non-issue.
- 🧬 **Evolves, doesn't just generate** — Code grows through a Git DAG where incremental, measurable improvement always wins.
- 🌳 **Knows its way around** — Every directory carries a semantic contract, so agents always understand the structure they're working in.
- 🧠 **Stateless by design** — Agents are transient and wake up anywhere in history. No long-lived memory to corrupt, ever.
- 🔒 **Sandboxed by default** — Generated code runs in your platform's native sandbox (systemd-run, sandbox-exec, or direct).

## 📦 Install

Genesis ships as a native desktop app. Grab the installer for your platform from the **[GitHub Releases](https://github.com/BillHuang2001/genesis/releases)** page:

| Platform    | Download |
|-------------|----------|
| **macOS** (Apple Silicon / Intel) | `.dmg` |
| **Linux**   | `.rpm`, `.AppImage`, or `.tar.gz` |
| **Windows** | `.msi` or `.exe` installer |
| **FreeBSD** | From source |

Download, run the installer, and launch **Genesis**. That's it.

### For AI agents

#### Install the app

To fetch and install the latest release programmatically:

```bash
# Download the installer for your platform (permanent links — always the latest release):
#   macOS (Apple Silicon): https://github.com/BillHuang2001/genesis/releases/latest/download/genesis_desktop_darwin_arm64.dmg
#   Linux x86_64:          https://github.com/BillHuang2001/genesis/releases/latest/download/genesis_desktop_linux_x64.AppImage  (or .deb / .rpm / .tar.gz)
#   Linux ARM64:           https://github.com/BillHuang2001/genesis/releases/latest/download/genesis_desktop_linux_arm64.deb     (or .rpm)
#   Windows x86_64:        https://github.com/BillHuang2001/genesis/releases/latest/download/genesis_desktop_windows_x64.msi     (or .exe)

curl -LO "https://github.com/BillHuang2001/genesis/releases/latest/download/genesis_desktop_darwin_arm64.dmg"

# Install based on your platform:
#   macOS:   open <file>.dmg
#   Linux:   sudo rpm -i <file>.rpm   OR   tar xzf <file>.tar.gz
#   Windows: msiexec /i <file>.msi
```

#### Run from source

To clone and run Genesis from source:

```bash
# Prerequisites: Elixir ~> 1.18 and Erlang/OTP 29

# Install Elixir and Erlang (choose one):
#   - asdf:    https://asdf-vm.com  →  asdf plugin add erlang && asdf plugin add elixir
#   - mise:    https://mise.jdx.dev →  mise use erlang@29 elixir@1.20
#   - Official: https://elixir-lang.org/install.html
#   - Or via your system package manager:
#       macOS (Homebrew):  brew install elixir
#       Ubuntu/Debian:     sudo apt install elixir erlang-dev
#       Arch:              sudo pacman -S elixir
#       Fedora:            sudo dnf install elixir

git clone https://github.com/BillHuang2001/genesis.git
cd genesis
mix deps.get
mix assets.setup
mix phx.server
```

Then open http://localhost:4100 in your browser.

#### Build the macOS desktop app

For a signed/notarized `.app` (or `.dmg`) locally, use the helpers under `desktop/scripts/`. This packages the Elixir `genesis_desktop` release into a Tauri shell.

**Prerequisites**

- Xcode Command Line Tools (`xcode-select --install`)
- Rust (`rustup`) and Tauri CLI: `cargo install tauri-cli --version "^2.0" --locked`
- Elixir / OTP matching `.tool-versions`
- Apple Developer ID Application certificate in your keychain, plus notarization credentials (App Store Connect API key or Apple ID)

**Configure signing**

```bash
cp desktop/scripts/.env.macos.example desktop/scripts/.env.macos
# Edit desktop/scripts/.env.macos — APPLE_SIGNING_IDENTITY plus notarization credentials
```

`desktop/scripts/.env.macos` is gitignored; do not commit secrets.

**Build**

```bash
./desktop/scripts/build-macos-local.sh              # default: --bundles app
./desktop/scripts/build-macos-local.sh --bundles dmg
./desktop/scripts/build-macos-local.sh --bundles app,dmg
```

The script builds the Elixir release, copies it into Tauri resources, codesigns nested Mach-O binaries (including the BEAM JIT entitlement), then runs `cargo tauri build`. It notarizes and staples the final DMG when requested, and verifies the signatures, notarization tickets, and Gatekeeper assessments before returning successfully.

Output:

- `.app`: `desktop/src-tauri/target/release/bundle/macos/`
- `.dmg`: `desktop/src-tauri/target/release/bundle/dmg/`

Notarization contacts Apple and can take several minutes with little log output while `notarytool` waits.

**CI (GitHub Actions)** — `build-macos-arm64` imports the Developer ID certificate, signs the nested runtime, lets Tauri sign and notarize the app, then notarizes the final DMG and verifies both artifacts before uploading them. Required repository secrets:

| Secret | Value |
|--------|--------|
| `APPLE_CERTIFICATE` | base64 of Developer ID Application `.p12` (`openssl base64 -A -in cert.p12`) |
| `APPLE_CERTIFICATE_PASSWORD` | password used when exporting the `.p12` |
| `APPLE_SIGNING_IDENTITY` | e.g. `Developer ID Application: Org (TEAMID)` |
| `APPLE_API_ISSUER` | App Store Connect Issuer ID |
| `APPLE_API_KEY` | App Store Connect Key ID |
| `APPLE_API_KEY_P8_BASE64` | base64 of `AuthKey_<KEYID>.p8` (`openssl base64 -A -in AuthKey_XXX.p8`) |

## 📦 Distribution via Package Managers

We're working to make Genesis available through popular package managers so you can install and update it with the tools you already use. Planned targets include:

| Package Manager | Platform | Status |
|-----------------|----------|--------|
| **AUR** | Arch Linux | Planned |
| **Homebrew** | macOS / Linux | Planned |
| **Nix** | NixOS / macOS | Planned |

More package managers will be added over time. If you'd like to help package Genesis for your preferred platform, please see [CONTRIBUTING.md](./CONTRIBUTING.md) — contributions are very welcome!

Stay tuned — we'll update this section as packages become available.

## 🤝 Contributing

We welcome contributions! All contributors are required to sign an Individual Contributor License Agreement (CLA) — our CLA assistant bot handles this automatically when you open your first pull request.

For full details on the CLA, development setup, and contribution guidelines, see [CONTRIBUTING.md](./CONTRIBUTING.md).

## 🙏 Acknowledgements

Genesis was born out of the [EvoGit](https://github.com/BillHuang2001/evogit) project.

## 📄 License

Genesis is released under the [GNU Affero General Public License v3.0](./LICENSE).
