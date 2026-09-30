<h1 align="center">
  <img src="apps/evo_dash/priv/static/images/logo.svg" alt="" height="28" style="vertical-align: middle;"> EvoX Genesis
</h1>

<p align="center">
  👉 <strong>Home &amp; docs:</strong> <a href="https://genesis.evox.group">genesis.evox.group</a>
</p>

<p align="center">
  <a href="https://github.com/EMI-Group/genesis/releases"><img src="https://img.shields.io/badge/version-0.13.6-8b5cf6" alt="Version"></a>
  <img src="https://img.shields.io/badge/license-AGPL--3.0-blue" alt="License">
  <a href="https://genesis.evox.group/getting-started/"><img src="https://img.shields.io/badge/docs-genesis_doc-22c55e" alt="Documentation"></a>
  <a href="https://arxiv.org/abs/2608.10450"><img src="https://img.shields.io/badge/arXiv-2608.10450-b31b1b" alt="arXiv"></a>
</p>

---

<h2 align="center">Let software worlds evolve</h2>

<p align="center">
  One objective in. A persistent software world unfolds.
</p>

From an implementation-empty repository, Genesis built a **248,989-line C compiler** in a **123.4-hour** run. Different foundation models then independently continued development from the same accepted software world.

**EvoX Genesis is an AI system for long-horizon autonomous software evolution.**

Its key idea is not to keep one agent—or one coding session—alive. Genesis maintains a persistent recursive software world. Finite-lived agents enter where needed, develop local parts, validate proposed changes, and carry only accepted results forward for later agents to inherit and extend. The approach is described in our paper: [arXiv:2608.10450](https://arxiv.org/abs/2608.10450).

> **You specify what the software should become. Genesis unfolds how to build it.**

> **Agents come and go. The software world keeps evolving.**

---

https://github.com/user-attachments/assets/d7f3d520-e39f-45cd-a525-77e5e8d00a75

<p align="center">
  ▶ <a href="https://genesis.evox.group/#film"><strong>Watch the Genesis promo film</strong></a> — built with Genesis — at <a href="https://genesis.evox.group">genesis.evox.group</a>
</p>

---

## ✨ Key Features

* 🧭 **Long-horizon autonomous software evolution** — recursive agent hierarchies advance one persistent software world across many finite-lived agent episodes, carrying validated results forward.
* 🪶 **Transient agents, persistent world** — each agent spawns fresh for one task and disappears when done: less context, fewer tokens, more reliable results.
* 🌳 **Git-native workflow** — the repository itself is the only state. Agents and humans share the same repo, the same `git log`, the same `git diff` — no hidden databases, no custom formats.

---

## Built with Genesis

Three developmental regimes. One principle: agents come and go, the software world persists.

| Regime | From → To | Headline result |
| ------ | --------- | --------------- |
| 🧱 **Formation** | Implementation-empty repository → Rust-based C compiler | **248,989 lines** built in **123.4 h** · **220/220** c-testsuite |
| 🔄 **Continuation** | The same accepted compiler world, a new foundation model | **GLM 5.2** and **DeepSeek V4 Flash** each continued development independently |
| 🔬 **Redevelopment** | 13 MESA Fortran modules → Rust crates | **139,414 → 89,946 lines** · **1,052 tests, 0 failures** |

The demo repositories: [genesis-demo-jcc](https://github.com/EMI-Group/genesis-demo-jcc) (formation and continuation) · [genesis-demo-mesa-rs](https://github.com/EMI-Group/genesis-demo-mesa-rs) (redevelopment).

> As far as we can determine, Genesis is the first publicly known autonomous system to submit a result for the [Terminal-Bench Challenges](https://github.com/BillHuang2001/tbench-wasm) — the WASM Render challenge — for just **US$36**, far below the ~US$1K+ per-challenge expectation.

📄 **[Full experimental results and figures →](docs/experiments.md)** · Paper: [arXiv:2608.10450](https://arxiv.org/abs/2608.10450)

<sub>
Reported dollar amounts are foundation-model token charges only, and these are observed system-level results rather than normalized model-comparison benchmarks.
</sub>

---


## Why Genesis is different

**One objective, not a workflow.**  
The user specifies the goal and constraints; Genesis decides how development should recursively unfold.

**Recursive organization emerges during development.**  
Managers decompose, delegate and judge returned work. Executors implement concrete changes at the leaves.

**The world persists; agents do not.**

```text
world = (accepted version, repository path)
```

What evolves is the software world—not the foundation model. Accepted development state and validated results remain available for later agents to inherit and extend.

The accepted version determines **what exists and can be inherited**. The path determines **where agency is situated**.

**Only accepted consequences become history.**  
Agent outputs are proposals. Only accepted results advance the persistent version lineage.

> **Agents do not persist. Their validated contributions do.**

---

## ⚡ Start with a requirement

Open Genesis and describe the software you want to build or evolve.

For example:

> Build a clean-room C compiler in Rust for LLVM-centric workflows, with C11 as the primary language target, x86/x86-64 back ends, standard toolchain interoperability, and external compiler validation.

Genesis takes it from there.

---

## 🖥️ Product

- **Native desktop app** for launching and supervising development
- **Recursive agent tree** visible as work unfolds
- **Scoped local workspaces** for isolated candidate changes
- **Cross-platform** support for macOS, Linux and Windows
- **Native sandboxing** where supported by the platform

---

## 📦 Install

Genesis ships as a native desktop app.

💡 **Prefer a guided download?** Visit [genesis.evox.group/#download](https://genesis.evox.group/#download) — it detects your platform automatically and points you to the right installer.

Or use the **[GitHub Releases](https://github.com/EMI-Group/genesis/releases)** page:

| Platform                          | Download                          |
| --------------------------------- | --------------------------------- |
| **macOS** (Apple Silicon / Intel) | `.dmg`                            |
| **Linux**                         | `.rpm`, `.AppImage`, or `.tar.gz` |
| **Windows**                       | `.msi` or `.exe` installer        |
| **FreeBSD**                       | From source                       |

Download, install, and launch **Genesis**.

### For AI agents

#### Install the app

```bash
# Permanent links — always the latest release:
# macOS (Apple Silicon):
# https://github.com/EMI-Group/genesis/releases/latest/download/genesis_desktop_darwin_arm64.dmg
#
# Linux x86_64:
# https://github.com/EMI-Group/genesis/releases/latest/download/genesis_desktop_linux_x64.AppImage
#
# Linux ARM64:
# https://github.com/EMI-Group/genesis/releases/latest/download/genesis_desktop_linux_arm64.deb
#
# Windows x86_64:
# https://github.com/EMI-Group/genesis/releases/latest/download/genesis_desktop_windows_x64.msi

curl -LO "https://github.com/EMI-Group/genesis/releases/latest/download/genesis_desktop_darwin_arm64.dmg"

# Install:
# macOS:   open <file>.dmg
# Linux:   sudo rpm -i <file>.rpm   OR   tar xzf <file>.tar.gz
# Windows: msiexec /i <file>.msi
```

#### Run from source

```bash
# Prerequisites: Elixir ~> 1.18 and Erlang/OTP 29

# Install Elixir and Erlang (choose one):
#   - asdf:    https://asdf-vm.com
#   - mise:    https://mise.jdx.dev
#   - Official: https://elixir-lang.org/install.html
#   - macOS:   brew install elixir
#   - Ubuntu:  sudo apt install elixir erlang-dev
#   - Arch:    sudo pacman -S elixir
#   - Fedora:  sudo dnf install elixir

git clone https://github.com/EMI-Group/genesis.git
cd genesis
mix deps.get
mix assets.setup
mix phx.server
```

Then open [http://localhost:4100](http://localhost:4100).

---

## 📦 Distribution via Package Managers

| Package Manager | Platform      | Status  |
| --------------- | ------------- | ------- |
| **AUR**         | Arch Linux    | Planned |
| **Homebrew**    | macOS / Linux | Planned |
| **Nix**         | NixOS / macOS | Planned |

More package managers will be added over time. Contributions are welcome — see [CONTRIBUTING.md](./CONTRIBUTING.md).

---

## 🙏 Acknowledgements

Genesis was born out of the [EvoGit](https://github.com/BillHuang2001/evogit) project and follows the broader [EvoX](https://github.com/EMI-Group/evox) research lineage.

---

## 🤝 Contributing

We welcome contributions. All contributors are required to sign an Individual Contributor License Agreement (CLA); our CLA assistant bot handles this automatically on your first pull request.

For development setup, CLA details and contribution guidelines, see [CONTRIBUTING.md](./CONTRIBUTING.md).

---

## 📄 License

Genesis is released under the [GNU Affero General Public License v3.0](./LICENSE).
