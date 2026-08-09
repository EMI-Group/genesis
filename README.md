<h1 align="center">
  <img src="apps/evo_dash/priv/static/images/logo.svg" alt="" height="28" style="vertical-align: middle;"> EvoX Genesis
</h1>

<p align="center">
  👉 <strong>Home &amp; docs:</strong> <a href="https://genesis.evox.group">genesis.evox.group</a>
</p>

<p align="center">
  <a href="https://github.com/EMI-Group/genesis/releases"><img src="https://img.shields.io/badge/version-0.9.2-8b5cf6" alt="Version"></a>
  <img src="https://img.shields.io/badge/license-AGPL--3.0-blue" alt="License">
  <a href="https://genesis.evox.group/getting-started/"><img src="https://img.shields.io/badge/docs-genesis_doc-22c55e" alt="Documentation"></a>
</p>

---

<h2 align="center">One objective in. A software world unfolds.</h2>

<p align="center">
  Describe what the software should become. Genesis recursively develops it.
</p>

**EvoX Genesis** turns a high-level software objective into a continuously developing software world.

You do not hand-design an agent team, pre-build a task tree, or keep one coding session alive. Genesis recursively creates local responsibilities, instantiates agents where needed, validates returned contributions, and carries accepted results forward.

> **You specify what the software should become. Genesis unfolds how to build it.**

> **Agents come and go. The software world persists.**

---

## Built with Genesis

Three regimes. One developmental principle.

### 🧱 Formation

#### C compiler from an implementation-empty repository

Using **DeepSeek V4 Flash**, Genesis developed a Rust-based C compiler from a repository containing no compiler implementation code.

> **248,989 lines · 1,019 archived agent episodes · 123.4 h · US$44.38**

**Validation:** 220/220 c-testsuite · 32/36 LLVM · 93/93 executed Csmith · 2,904 Rust tests · 106/106 internal cases

**Development:** observed recursive depth 5 · 327 first-parent commits

---

### 🔄 Continuation

#### The model changed. Development continued.

A separate compiler world originally developed with **GLM 5.2** was independently continued by both GLM 5.2 and **DeepSeek V4 Flash**.

> **DeepSeek: 1,820/1,820 retained LLVM SingleSource cases**  
> **GLM 5.2: 1,445/1,448**

**Both:** 220/220 c-testsuite · 4/4 LZ4

---

### 🔬 Redevelopment

#### MESA → Rust, with numerical behaviour preserved

Genesis redeveloped a selected chain of **13 MESA Fortran modules** into corresponding Rust crates.

> **139,414 Fortran lines → 89,946-line Rust workspace**

**Run:** 33.22 h · 272 agents · US$10.64  
**Validation:** 1,052 tests · 0 failures  
**Numerics:** 2 bit-exact workloads · remaining relative checksum differences ≤ 3.1 × 10⁻⁹ · median speedups **1.55×–6.87×**

<sub>
Reported dollar amounts are foundation-model token charges only. Compiler formation, continuation and MESA redevelopment are observed system-level results, not normalized model-comparison benchmarks. The MESA result covers the audited 13-module scope, not the full application.
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

The accepted version determines **what exists and can be inherited**. The path determines **where agency is situated**.

**Only accepted consequences become history.**  
Agent outputs are proposals. Only accepted results advance the persistent version lineage.

> **Agent does not persist. Its validated consequences do.**

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

## 🔬 Research

Genesis is being studied under the working title:

> **Persistent recursive worlds enable autonomous software evolution**

The current evidence supports three system-level capabilities:

**formation · model-switchable continuation · behaviour-preserving scientific-software redevelopment**

Stronger mechanism-level questions — including how much continuity is caused specifically by non-executable developmental organization beyond source code alone — remain open research questions.

Project website: **[genesis.evox.group](https://genesis.evox.group/)**

---

## 🙏 Acknowledgements

Genesis was born out of the [EvoGit](https://github.com/EMI-Group/evogit) project and follows the broader [EvoX](https://github.com/EMI-Group/evox) research lineage.

---

## 🤝 Contributing

We welcome contributions. All contributors are required to sign an Individual Contributor License Agreement (CLA); our CLA assistant bot handles this automatically on your first pull request.

For development setup, CLA details and contribution guidelines, see [CONTRIBUTING.md](./CONTRIBUTING.md).

---

## 📄 License

Genesis is released under the [GNU Affero General Public License v3.0](./LICENSE).
