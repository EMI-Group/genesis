<h1 align="center">
  <img src="apps/evo_dash/priv/static/images/logo.svg" alt="" height="28" style="vertical-align: middle;"> EvoX Genesis
</h1>

<p align="center">
  The recursive agentic <strong>system</strong> for autonomous software evolution.
</p>

<p align="center">
  👉 <strong>Home &amp; docs:</strong> <a href="https://genesis.evox.group">genesis.evox.group</a>
</p>

<p align="center">
  <a href="https://github.com/EMI-Group/genesis/releases"><img src="https://img.shields.io/badge/version-0.9.2-8b5cf6" alt="Version"></a>
  <img src="https://img.shields.io/badge/license-AGPL--3.0-blue" alt="License">
  <a href="https://genesis.evox.group"><img src="https://img.shields.io/badge/docs-genesis_doc-22c55e" alt="Documentation"></a>
</p>

---

## Describe what you want. Genesis recursively develops the software.

**EvoX Genesis** is a system for long-horizon autonomous software development.

Give Genesis a high-level software objective and its constraints. You do **not** need to hand-design an agent team, manually construct a task tree, or keep one coding session alive for the lifetime of the project.

Genesis recursively unfolds the work as development proceeds: managers decompose objectives, delegate local responsibilities, and judge returned contributions; executors implement concrete changes at the leaves. Accepted results become part of the evolving software world, and later agents continue from that world.

> **You specify what the software should become. Genesis unfolds how to build it.**

> **Agents come and go. The software world persists.**

Genesis is built around a simple principle: long-horizon development does not have to be carried by one persistent intelligent agent. It can instead be carried by a **persistent recursive software world** whose accepted artifacts, context, constraints, validation evidence, and lineage remain available as local agents are created, replaced, and terminated.

## 🚀 What Genesis has already done

Genesis has been exercised across three distinct forms of long-horizon software development:

**formation · continuation · redevelopment**

### 🧱 A C compiler from an implementation-empty repository

Using **DeepSeek V4 Flash** as the foundation model, Genesis developed `jcc`, a C compiler written in Rust, starting from a repository containing only `.gitignore` and `genesis.toml` and **no compiler implementation code**.

The task supplied the target, constraints, toolchain requirements, and validation sources, but no compiler implementation or concrete repository decomposition. Genesis recursively organized and implemented the resulting system.

**248,989 physical lines · 1,019 archived agent episodes · 123.4 hours · US$44.38 model-token cost**

Final recorded validation included:

- **220 / 220** c-testsuite cases
- **32 / 36** evaluated LLVM cases
- **93 / 93** executed Csmith programs
- **2,904** Rust workspace tests passed
- **106 / 106** internal compiler cases
- recorded LZ4 and SQLite validation completed

The accepted development lineage reached an observed recursive delegation depth of **5** and accumulated **327 first-parent commits**.

### 🔄 Development continues after the foundation model changes

Genesis was also tested on a separate completed compiler world originally developed with **GLM 5.2**.

The same accepted compiler world was independently continued by:

- **GLM 5.2**
- **DeepSeek V4 Flash**

Both branches continued development through repeated turnover of finite-lived agents.

The DeepSeek V4 Flash continuation reached:

**1,820 / 1,820 retained LLVM SingleSource cases**

The GLM 5.2 continuation reached:

**1,445 / 1,448 retained LLVM SingleSource cases**

Both also reported **220 / 220 c-testsuite** cases and **4 / 4 LZ4** files at completion.

The two continuations followed different developmental trajectories — different agent counts, recursion depths, commit histories, code churn, and final code footprints — while both advanced the inherited compiler world.

> **The proposal process can change. Development can continue.**

This demonstrates **model-switchable continuation** of an accepted software world. It is not a controlled comparison of model quality, and the present experiment does not isolate the causal contribution of non-executable developmental records beyond the source artifact alone.

### 🔬 Redeveloping scientific software while preserving numerical behaviour

Genesis redeveloped a selected chain of **13 Fortran-based modules** from [MESA](https://github.com/MESAHub/mesa), the open-source *Modules for Experiments in Stellar Astrophysics* software suite, into corresponding Rust crates.

**139,414 physical Fortran lines → 89,946-line Rust workspace**

**33.22 hours · 272 spawned agents · US$10.64 model-token cost**

The resulting Rust workspace passed:

**1,052 tests · 0 failures · 18 ignored**

Numerical preservation was audited across six scientific workloads:

| Workload | Median speedup | Numerical agreement |
| --- | ---: | --- |
| End-to-end burn | **1.55×** | relative checksum difference `3.1 × 10⁻⁹` |
| EOS lookup | **1.60×** | **bit-exact** |
| Opacity lookup | **1.98×** | relative checksum difference `1.3 × 10⁻¹³` |
| 2D interpolation | **1.58×** | relative checksum difference `4.9 × 10⁻¹²` |
| ROS2 integration | **5.30×** | relative checksum difference `5.1 × 10⁻¹⁵` |
| Newton solve | **6.87×** | **bit-exact** |

A separate 40-run end-to-end validation retained the same recorded integrator counters and showed a **1.23× median speedup**.

> **Genesis does not only create software. It can inherit and transform it.**

The reported MESA result applies to the audited 13-module scope and tested workloads; it is not a claim of complete replacement of the full MESA application.

> **Note on costs:** all dollar amounts above are recorded foundation-model token charges only. They do not include local compute, storage, orchestration, networking, or human labour.

## 🌍 How Genesis works

Genesis does not treat a project as one long agent conversation.

It represents development as a **persistent recursive software world**.

A local software world is situated by:

```text
world = (accepted version, repository path)
```

The **accepted version** determines what currently exists and what history can be inherited. The **path** determines where local agency is situated: its context, responsibility, and modification scope.

An agent can inspect the complete accepted project, but it begins from a particular path and objective.

### Recursive development

At the theoretical level, Genesis needs only two functional agent roles:

- **Manager** — decomposes objectives, delegates work, and judges returned contributions.
- **Executor** — directly modifies the artifact at a leaf task and returns a candidate contribution.

Managers can recursively instantiate new managers at more specific paths. The resulting development hierarchy is therefore **not a fixed hand-written agent workflow**: it unfolds from the current objective and software world as development proceeds.

### Accepted consequences, not persistent conversations

Every local agent is finite-lived.

An agent may use a conversation, scratch state, tools, and an isolated workspace during its episode, but that private episode state is not the accepted software lineage.

Agent actions are proposals.

Only accepted consequences advance the persistent version history.

> **Agent does not persist. Its validated consequences do.**

This allows later work to resume from the accepted software world rather than requiring the previous agent identity to remain alive.

## ✨ Highlights

- 💬 **Objective in, recursive development out** — Give Genesis a high-level software objective and constraints; Genesis unfolds the development hierarchy as it works.
- 🌳 **Self-unfolding organization** — Managers recursively decompose, delegate, and validate work. You do not need to hand-design the complete agent tree.
- 🌍 **Persistent worlds, transient agents** — Agents are finite-lived; accepted artifacts, context, constraints, evidence, and lineage persist.
- 🔄 **Development across handoffs** — Accepted software worlds can continue developing through repeated agent turnover and even foundation-model replacement.
- ✅ **Only accepted consequences persist** — Agent outputs are proposals; parent-level judgement and validation determine what enters the software lineage.
- 🧭 **Path-situated local agency** — Agents work from bounded local responsibilities while retaining visibility of the accepted project.
- 🔒 **Sandboxed by default** — Candidate work runs in isolated, scoped workspaces with platform-specific execution controls before accepted changes enter project history.
- 🖥️ **A real GUI** — A native desktop dashboard to launch tasks, watch the agent tree, review diffs, and tune settings in real time.
- 🧬 **Formation, continuation, and redevelopment** — Genesis is designed for software that keeps developing rather than for a single bounded generation step.

## ⚡ Start with a requirement

Open Genesis and describe the software you want to build or evolve.

For example, the compiler experiment began from a high-level constrained objective of this form:

> Build a clean-room C compiler in Rust for LLVM-centric workflows, with C11 as the primary language target, x86/x86-64 back ends, standard toolchain interoperability, and external compiler validation.

Genesis then recursively develops the project: it creates local responsibilities, instantiates agents where needed, integrates accepted contributions, and continues from the resulting software world.

The important separation is:

> **The user specifies what the software should become. Genesis determines how development unfolds.**

## 📦 Install

Genesis ships as a native desktop app.

💡 **Prefer a guided download?** Visit [genesis.evox.group/#download](https://genesis.evox.group/#download) — it detects your platform automatically and points you to the right installer, so you don't have to pick through the GitHub release artifacts.

Grab the installer for your platform from the **[GitHub Releases](https://github.com/EMI-Group/genesis/releases)** page:

| Platform                          | Download                          |
| --------------------------------- | --------------------------------- |
| **macOS** (Apple Silicon / Intel) | `.dmg`                            |
| **Linux**                         | `.rpm`, `.AppImage`, or `.tar.gz` |
| **Windows**                       | `.msi` or `.exe` installer        |
| **FreeBSD**                       | From source                       |

Download, run the installer, and launch **Genesis**. That's it.

### For AI agents

#### Install the app

To fetch and install the latest release programmatically:

```bash
# Download the installer for your platform (permanent links — always the latest release):
#   macOS (Apple Silicon): https://github.com/EMI-Group/genesis/releases/latest/download/genesis_desktop_darwin_arm64.dmg
#   Linux x86_64:          https://github.com/EMI-Group/genesis/releases/latest/download/genesis_desktop_linux_x64.AppImage  (or .deb / .rpm / .tar.gz)
#   Linux ARM64:           https://github.com/EMI-Group/genesis/releases/latest/download/genesis_desktop_linux_arm64.deb     (or .rpm)
#   Windows x86_64:        https://github.com/EMI-Group/genesis/releases/latest/download/genesis_desktop_windows_x64.msi     (or .exe)

curl -LO "https://github.com/EMI-Group/genesis/releases/latest/download/genesis_desktop_darwin_arm64.dmg"

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

git clone https://github.com/EMI-Group/genesis.git
cd genesis
mix deps.get
mix assets.setup
mix phx.server
```

Then open [http://localhost:4100](http://localhost:4100) in your browser.

## 📦 Distribution via Package Managers

We're working to make Genesis available through popular package managers so you can install and update it with the tools you already use. Planned targets include:

| Package Manager | Platform      | Status  |
| --------------- | ------------- | ------- |
| **AUR**         | Arch Linux    | Planned |
| **Homebrew**    | macOS / Linux | Planned |
| **Nix**         | NixOS / macOS | Planned |

More package managers will be added over time. If you'd like to help package Genesis for your preferred platform, please see [CONTRIBUTING.md](./CONTRIBUTING.md) — contributions are very welcome!

Stay tuned — we'll update this section as packages become available.

## 🔬 Research

Genesis is being studied as a different computational organization for long-horizon software development:

> **Persistent recursive worlds enable autonomous software evolution**

The current experiments investigate three complementary capabilities:

| Capability | Evidence |
| --- | --- |
| **Formation** | implementation-empty repository → 248,989-line C compiler |
| **Continuation** | inherited compiler world → continued development across foundation-model replacement |
| **Redevelopment** | selected MESA Fortran modules → Rust while preserving audited numerical behaviour |

The current evidence establishes these as **system-level capabilities** of the reported Genesis organization. Stronger mechanism-level questions — including how much continuity is caused specifically by non-executable developmental organization beyond source code alone — remain active research questions.

Project website: **[genesis.evox.group](https://genesis.evox.group/)**

## 🙏 Acknowledgements

Genesis was born out of the [EvoGit](https://github.com/EMI-Group/evogit) project and follows the broader [EvoX](https://github.com/EMI-Group/evox) research lineage.

## 🤝 Contributing

We welcome contributions! All contributors are required to sign an Individual Contributor License Agreement (CLA) — our CLA assistant bot handles this automatically when you open your first pull request.

For full details on the CLA, development setup, and contribution guidelines, see [CONTRIBUTING.md](./CONTRIBUTING.md).

## 📄 License

Genesis is released under the [GNU Affero General Public License v3.0](./LICENSE).
