<p align="center">
  <img src="apps/evo_dash/priv/static/images/logo.svg" height="44" alt="Genesis" style="vertical-align: middle;">
  <span style="font-size: 2.75em; font-weight: bold; vertical-align: middle; margin-left: 12px;">Genesis</span>
</p>

<p align="center">
  The evolutionary agentic <strong>system</strong>.
</p>

<p align="center">
  <a href="https://github.com/BillHuang2001/genesis/releases"><img src="https://img.shields.io/badge/version-0.8.5-8b5cf6" alt="Version"></a>
  <img src="https://img.shields.io/badge/platform-macOS%20·%20Linux%20·%20Windows-success" alt="Platform">
  <img src="https://img.shields.io/badge/license-AGPL--3.0-blue" alt="License">
  <img src="https://img.shields.io/badge/built%20with-Elixir-4B275F" alt="Elixir">
</p>

---

Genesis reimagines how software gets written. Instead of a single chat that runs out of room, it runs a **team of agents** that recursively split your project into a hierarchy of focused tasks — each agent working only where it should, with its own context and its own clean copy of the code.

It's evolutionary: every change lands on a branch of the Git history, and partial progress is celebrated. A version that passes more tests or ships one more feature is a step forward — even if other pieces are still in flight.

### ✨ Highlights

- 🔭 **Scales without limits** — Recursive decomposition keeps every agent's context small, so there's no ceiling on how big a project can get.
- 🧬 **Evolves, doesn't just generate** — Code grows through a Git DAG where incremental, measurable improvement always wins.
- 🌳 **Knows its way around** — Every directory carries a semantic contract, so agents always understand the structure they're working in.
- 🧠 **Stateless by design** — Agents are transient and wake up anywhere in history. No long-lived memory to corrupt, ever.
- 🔒 **Sandboxed by default** — Generated code runs in your platform's native sandbox (systemd-run, sandbox-exec, or direct).
- 🖥️ **A real GUI** — A native desktop dashboard to launch tasks, watch the agent tree, review diffs, and tune settings in real time.

## 📦 Install

Genesis ships as a native desktop app. Grab the installer for your platform from the **[GitHub Releases](https://github.com/BillHuang2001/genesis/releases)** page:

| Platform | Download |
|----------|----------|
| **macOS** (Apple Silicon / Intel) | `.dmg` |
| **Linux** | `.rpm`, `.AppImage`, or `.tar.gz` |
| **Windows** | `.msi` or `.exe` installer |

Download, run the installer, and launch **Genesis**. That's it.

### For AI agents

#### Install the app

To fetch and install the latest release programmatically:

```bash
# List the download URLs in the newest release
curl -s https://api.github.com/repos/BillHuang2001/genesis/releases/latest \
  | grep '"browser_download_url"' \
  | grep -E '\.(dmg|rpm|AppImage|tar\.gz|msi|exe)"'

# Download the artifact matching your OS and architecture
# (filenames encode the target — e.g. darwin-arm64, linux-x64, windows-x64)
curl -LO "<download-url>"

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

Then open http://localhost:4000 in your browser.

## 🙏 Acknowledgements

Genesis was born out of the [EvoGit](https://github.com/BillHuang2001/evogit) project.

## 📄 License

Genesis is released under the [GNU Affero General Public License v3.0](./LICENSE).
