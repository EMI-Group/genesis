# EvoGit Course — Course Build & Distribution

## Intent
The `EvoGit.Course` namespace handles building courses from multi‑branch git repos and pulling built artifacts from a remote builder node. It supports language‑variant branches (e.g., `main` for English, `lang-zh` for Chinese) that are extracted into per‑language directories and compressed into `.tar.zst` archives for distribution.

## API Surface

| Module | File | Purpose |
|---|---|---|
| `EvoGit.Course` | `../course.ex` | Main module — `Course` struct, `mode/0`, `builder_node/0` |
| `EvoGit.Course.Builder` | `builder.ex` | Builds courses: branch extraction → transformations → compression |
| `EvoGit.Course.FilePuller` | `file_puller.ex` | Pulls `.tar.zst` artifacts from a remote builder node and extracts them |
| `EvoGit.Course.Server` | `server.ex` | (future) Local course server |

## Constraints
- The `EvoGit.Course` struct and config accessors live in `apps/evo_git/lib/evo_git/course.ex` (one level above this directory).
- `EvoGit.Course.Builder` uses `System.cmd("git", ...)` directly for branch listing and archive, not `EvoGit.Adapters.Git`.
- `EvoGit.Course.FilePuller` depends on `EvoGit.Cluster.FilePuller` for the actual network transfer.
- Transformation modules must implement `transform/2` (`(dir_path, opts) -> :ok | {:error, reason}`).
