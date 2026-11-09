# The Virtual Tree — Workspaces, a Workspace Rootfs, and Repo Mounts

Status: **proposal** (nothing implemented).
This record supersedes the earlier all-in-one draft (capability mounts, virtual nodes, MCP).
The first shippable step is deliberately narrower: **git repos only, mounted into a virtual tree whose `/` is a real git repo in the Genesis state directory — the workspace "rootfs"**.
Skills, memory, MCP and non-code workloads are deferred, but they are designed *as future mounts of git repos*, so the first step is their foundation rather than a detour.

## 1. Problem

Genesis today models a task as **one primary repo + N read-mostly "foreign repos"**.
The following are verified facts about the current code, not impressions:

| Symptom | Root cause in the current design |
|---|---|
| Multi-repo work is awkward; the primary repo is implicit | `opts[:path]` *is* the task: it is the only required runtime opt (`task_registry/runtime_opts.ex:68`), and the repo root only exists as `Path.expand` at phase entry (`runtime/evolution.ex:30`, `runtime/genesis.ex:19`). Everything else is a per-task attachment (`:foreign_repos`, passed verbatim at `runtime_opts.ex:83`) |
| Git submodules cannot be modelled | `%EvoGit.Core.ForeignRepo{id, root, description, writable, base_sha}` (`core/foreign_repo.ex:25-27`) is a **flat, unanchored** list of roots; there is no parent / path-in-parent relation, so a submodule is indistinguishable from "another repo at an absolute path" |
| The self-reflective agent is blind to multi-repo tasks | `Runtime.SelfReflective.build_spec/2` never loads repos (`runtime/self_reflective.ex:72-93` has no `load_foreign_repos/2`), the CLI `reflect` builds only `[objective: …]` (`cli.ex:154-172`), and `ElixirEval.Authorization` *requires* `foreign_repos == []` |
| No global/external skills or MCP | Skills have exactly one source, `<worktree>/.agents/skills` (`skills.ex:60-63`), and the tool set is four hard-coded concatenations in `Runner.effective_tools/1` (`agent/runner.ex:801-816`); no tool-source registry, no MCP |
| Coding-only | A node is by definition an existing **directory containing `CONTEXT.md`** inside the one repo (`runtime/helpers.ex:207-229`), so a node that is not a folder cannot be expressed |
| "Which repo may I write?" is ad-hoc and partly broken | Writability is a boolean on `%ForeignRepo{}` enforced through **process-dictionary** keys (`:repo_path`, `:evogit_repo_id`, `:foreign_repos`) that `ToolDispatch.execute_tool_task/7` never re-installs (`agent/tool_dispatch.ex:1579-1639` only sets tmpdir/agent ids), so on the normal dispatch path the read-only-foreign and repo-less guards degrade to ALLOW (`agent/tools.ex:584`, `:643`) |
| A single agent cannot see a second tree | One agent = one repo (`AgentState.repo_id`/`repo_root`, `agent_scheduler/agent_state.ex:69-70`), one worktree (`agent_scheduler/dispatch.ex:231-236`), one `LoopState.repo_path`, one commit (`agent/completion.ex:50-55`); the sandbox only enumerates **writes** for that one cwd plus the repo's `.git` (`sandbox/linux.ex:205-212`, `:254-259`) |

The fix is not a feature but a re-basing: replace "primary repo + foreign repos" with **one mount table per workspace**, whose root is a small git repo Genesis owns.

## 2. Goals and non-goals of this step

Goals:
1. One spatial namespace per task: `/` plus mount points, with a deterministic path → `{mount_id, mount-relative path}` resolution.
2. A **workspace rootfs**: a real git repo under the data dir that holds the workspace definition (`workspace.toml`) and the workspace-level context (`CONTEXT.md`), committed, diffable and shareable.
3. First-class peer repos, read-only vs read-write mounts, per-mount commit/report/review.
4. Zero behaviour change for a legacy single-repo task until a flag is flipped.
5. One write-authority chokepoint, explicit (not process-dictionary), testable as a matrix.
6. The data model already carries nesting (`parent`, `path_in_parent`) so submodules become a small follow-up, not a redesign.

Non-goals for this step (deliberately deferred):
- `:dir`, `:memory`, `:virtual`, `:skills`, `:mcp` mount kinds — later everything is *a git repo mounted at a point*, so no new backend machinery is needed for them.
- A kernel filesystem / FUSE driver.
- Cross-host (remote-node) mounts.
- Session-level config overrides — unchanged: the mount table is task data + workspace data, never scheduler config.

## 3. Core model

```elixir
%EvoGit.Core.Workspace{
  id: "w_3f9c1a2b",              # stable, derived from rootfs path when auto-created
  name: "platform",
  rootfs_path: "<data_dir>/workspaces/w_3f9c1a2b/rootfs",
  primary: "app",                # mount id of the repo task entry points default to
  root_home: :auto,              # :auto | :root | :primary  (§9)
  mounts: [%EvoGit.Core.Mount{}] # the table, minus the implicit rootfs mount
}

%EvoGit.Core.Mount{
  id: "app",                     # stable identity, slug, unique in the table
  point: "/app",                 # presentation in the tree; validated (§4.4)
  kind: :git,                    # P1 accepts only :git
  source: "/home/me/src/app",    # P1: a local git repo path
  ref: nil,                      # branch | tag | sha | nil = HEAD at admission
  mode: :rw,                     # :rw | :ro (a task may only narrow to :ro)
  parent: nil,                   # nested mount: parent mount id (submodule shape)
  path_in_parent: nil,           # nested mount: path inside the parent worktree
  description: nil,              # rendered in the prompt tree block
  options: %{}                   # open map, no new kind-specific keys yet
}
```

Mount kinds beyond `:git` are **reserved field values**, not implemented code paths.

### 3.1 The rootfs is a mount, not a special case

The workspace rootfs is materialized as the mount at `/`:

```elixir
%Mount{id: "root", point: "/", kind: :git,
       source: "<data_dir>/workspaces/<ws>/rootfs",
       mode: :rw, options: %{role: :rootfs}}
```

`/` is therefore a normal git-backed node: it has `CONTEXT.md`, it commits, it can be reviewed.
This removes the need for a "virtual node" concept in this step: a context-only node is just **a directory in the rootfs containing only `CONTEXT.md`**.

### 3.2 Identity vs presentation

**`mount_id` is identity; `point` is presentation.**
A node is `{mount_id, node_path}` and `node_path` stays **mount-relative** (`./src/auth`) — byte-identical to today's node paths.
Tree-absolute paths (`/app/src/auth`) are a *new, additive* form used for cross-mount references, subagent routing, the dashboard and the review report.
Consequence: adding a second repo never rewrites a stored node path, a prompt node, an archive row or a git note.

### 3.3 `repo_id` stays as a legacy alias

Every existing consumer of `AgentSpec.repo_id` (dispatch, subagent role gate, completion, merge, archives, `TaskCommitGraph`, review) expects `"primary"` (`agent_spec.ex:28`, `dispatch.ex:675-691`, `completion.ex:100-106`, `runtime/helpers.ex:119-124`).
So: `AgentSpec.repo_id` remains, and one translation function maps it to/from mount ids — the primary mount of a workspace reports as `"primary"`, every other mount reports as its mount id.
That keeps `result["repos"]` (`%{repo_id => %{commit_sha, branch_name}}`) a drop-in compatible shape while `result["mounts"]` carries the rich descriptor (§12).

## 4. The workspace rootfs

### 4.1 Location and contents

```
<data_dir>/workspaces/<ws_id>/
  rootfs/                       # a real git repo, branch `main`
    workspace.toml              # the mount table (tracked — the source of truth)
    CONTEXT.md                  # workspace root node context (optional for auto workspaces)
    .gitignore                  # generated: every mount point + `.genesis/`
    policies/CONTEXT.md         # optional context-only nodes ("virtual" nodes for free)
```

`<data_dir>` is resolved by `EvoGit.Platform.data_dir/0`, so a `[data] dir` override relocates the whole tree coherently, exactly like the task DB.

`rootfs_path` is configurable in principle (a user-owned git repo), which is what makes a workspace shareable across machines later; the default is Genesis-owned.

### 4.2 Why a git repo and not a row in SQLite

- The workspace definition and the workspace-level context get **history, diffs and review** instead of being mutable settings.
- The workspace becomes portable: push/copy the rootfs repo and the mount table travels with its intent.
- It is the same mechanism the later features need: a personal-memory repo, a skills repo, an instruction-tree repo are all "a git repo mounted at a point" — the rootfs proves the mechanism on Genesis' own data first.
- `/` stops being a special case: it is a git mount, so context resolution, commits, archives and review reuse the existing machinery.

The task store keeps only a cache/roster row (`workspaces`, §11); the **rootfs is the truth**.

### 4.3 `workspace.toml`

```toml
[workspace]
id = "w_3f9c1a2b"
name = "platform"
primary = "app"

[tree]
root_home = "auto"          # auto | root | primary  (§9)
max_mounts = 16

[[mounts]]
id = "app"
point = "/app"
source = "/home/me/src/app"
mode = "rw"
description = "Backend application"

[[mounts]]
id = "lib"
point = "/lib"
source = "/home/me/src/lib"
mode = "ro"
ref = "v2.3.0"
```

The rootfs mount is implicit and never listed (no self-reference).
Edits are made by the dashboard / CLI, which write the file and **commit it in the rootfs**; agents may not add mounts (§8.3).

### 4.4 Validation invariants (pure function, one implementation)

`EvoGit.VirtualTree.validate/1`, used by CLI, dashboard and task admission alike:

1. Exactly one rootfs mount, `id: "root"`, `point: "/"`; it is never listed in `workspace.toml`.
2. `id` is a slug and unique; `point` is unique, absolute, has no `.`/`..`/empty segments and no trailing `/`; `id` and the last point segment are independent (no implicit coupling).
3. A mount point must not collide with a tracked path in the rootfs; `shadowed: true` grafts are rejected in this step (revisit when submodules land).
4. A mount `source` must be an existing git repo, must not live inside another mount's `.genesis/`, and must not live inside the data dir.
5. `:ro` is never silently widened: a child mount inside a `:ro` parent must be explicitly `:rw`-granted or is rejected.
6. `parent` must exist, `path_in_parent` must be a relative path inside the parent, and the child's point must equal `<parent point>/<path_in_parent>`.
7. Mount count ≤ `[tree] max_mounts` (default 16) — bounds prompt size and worktree cost.

## 5. How a mount is materialized

Agents run **real subprocesses** (`bash`, `rg`, `git`, builds) under a sandbox that today takes one `cwd` and enumerates writable paths (`sandbox/helpers.ex:191-201`; systemd `-p WorkingDirectory`/`ReadWritePaths`, `sandbox/linux.ex:301-325`; bwrap `--chdir`/`--bind`, `sandbox/bwrap.ex:486-506`; macOS `allow file-write* (subpath …)`, `sandbox/macos.ex:430-464`).
A purely in-process virtual path resolver would break every one of those tools, so the table is **materialized**.

### 5.1 A per-agent mount farm

```
<data_dir>/workspaces/<ws_id>/tasks/<task_id>/agents/<agent_id>/tree/
  root -> <rootfs view>                # rw worktree, or shared ro view
  app  -> <repo>/.genesis/workers/worker_T<n>_A<m>     # rw: per-agent worktree (same path as today)
  lib  -> <repo>/.genesis/mounts/lib@a1b2c3d4          # ro: shared, pinned, chmod a-w
```

- Symlinks are POSIX-transparent: `read`, `rg`, `glob`, `git -C lib`, `ls`, builds all work unchanged, and the sandbox only has to allow the *real* roots.
- Rejected alternatives: FUSE (daemon per task, unportable), real bind mounts from the BEAM (not possible in-process; would diverge from in-process tools), pure resolver (breaks shell tools and every build).
- Windows: directory junctions (`mklink /J`), behind a flag in this step.

Per-mount views:

| mount | view |
|---|---|
| `:rw` repo mount | one `git worktree` per agent **only when the agent is granted write** — the existing path/branch scheme `<repo>/.genesis/workers/worker_T<n>_A<m>` / `evogit-agent-T<n>-A<m>` (`agent_scheduler/worktrees.ex:26`, `:44-45`) |
| `:ro` repo mount | one **shared, pinned** read view per task at `<repo>/.genesis/mounts/<mount_id>@<sha12>`, `chmod a-w`, refcounted, GC-able (`mix mounts.gc`) |
| rootfs (`:rw`) | per-agent worktree when the agent may write `/` (root agent, or a subagent homed in the rootfs); otherwise the task's shared ro rootfs view |

Laziness matters: a mount the agent never touches costs no worktree.

### 5.2 cwd and the shell

- `cwd` = the agent's **home mount view** — for a repo-homed subagent that is exactly today's worktree path, so every existing prompt, relative path and `mix test` keeps working.
- `GENESIS_TREE_ROOT` is exported to every sandboxed command and points at the agent's farm.
- The shell does **not** interpret tree-absolute paths: `/app` inside the sandbox is the real filesystem root. Only in-process tools resolve `/…` (§6). This is stated in the prompt.
- The root agent's `cwd` = `<farm>/root` (home = rootfs) or `<farm>/<primary>` (§9).

### 5.3 Lifecycle

1. **Resolve** (at admission, pure): `workspace.toml` + task overrides + legacy inputs → `%MountTable{}`; validate; **snapshot into task opts** (`workspace_id`, `mounts`) so a later workspace edit cannot change a running task.
2. **Prepare** (per task): resolve each `ref` to a `base_sha` and record it; create/reuse pinned ro views lazily.
3. **Materialize** (per agent): farm dir + symlinks; home view; rootfs view; other mounts lazily on first use.
4. **Enforce**: `%Tools.Context{}` gate (§8) + sandbox writable set (§8.2).
5. **Collect**: commit each materialized mount in its own repo (`evogit-agent-T<n>-A<m>`), then the rootfs; nested mounts **child first**, then the parent so the gitlink points at the child's new commit.
6. **Report**: `result["repos"]` (compat) + `result["mounts"]` (rich) + one review branch per mount.
7. **Teardown**: per-(agent, mount) worktree destroy in the existing order (`agent_scheduler/worktree_manager.ex:699-731`: reap jobs → `rm_rf` → prune → delete branch), decrement ro-view refcounts, remove the farm.

### 5.4 Read-path safety

- The sandbox read side is ambient today (`ProtectSystem=strict` + `ProtectHome=read-only` for systemd, `--ro-bind / /` for bwrap, `allow file-read* "/"` for macOS): an `:ro` mount is therefore *readable* for free but must be made **unwritable** — by not adding it to the writable set **and** `chmod a-w` on the shared view (belt and braces).
- Path hygiene: `ContextNode.normalize_relpath/1` keeps interior `..` (`core/context_node.ex:69-81`); mount-aware resolution must reject any `..` that leaves its mount, and must `realpath` the result to defeat a symlink an agent created inside a writable mount.

## 6. Path resolution for tools

Two canonical forms, one parser (`EvoGit.VirtualTree.resolve/2`):

- **mount-relative** `./src/auth` — canonical for `node_path`, task opts and archives (unchanged strings).
- **tree-absolute** `/app/src/auth` — canonical for cross-mount references, subagent routing, dashboard and the review report.

```
resolve(table, "/app/vendor/lib/x") -> {:ok, %{mount_id: "lib", node_path: "./x", mount: ...}}
```

Resolution is longest-point-prefix, never crosses a mount boundary implicitly, and a mount-relative path always resolves inside its own mount (so `./vendor/lib/x` inside `app` is `app`'s tree, never the shadowed files).

Chokepoints (there are exactly two, both already exist):
`Shared.expand_path/2` → `Platform.safe_expand/2` (`agent/tools/shared.ex:318-326`, `platform.ex:375-391`), and `ToolDispatch`'s tool-task boundary (`agent/tool_dispatch.ex:1579-1639`).

## 7. Context tree in the virtual tree

### 7.1 Concatenation along the tree path

```
/             CONTEXT.md   workspace intent, member repos, cross-repo invariants   (rootfs)
/app          CONTEXT.md   the repo's own root                                     (repo mount)
/app/src/auth CONTEXT.md   the assigned node                                        (repo mount)
```

- `%EvoGit.Core.ContextNode{}` gains `mount_id` (`core/context_node.ex:17-18`: today `[:path, :repo, repo_id: "primary"]`).
- `hierarchy_nodes/2` (`core/context_node.ex:125-150`, today purely syntactic) becomes mount-aware: emit the rootfs chain (only `/CONTEXT.md`, since the rootfs is flat) then the in-mount chain. **For an auto workspace without a `/CONTEXT.md` the emitted chain is byte-identical to today.**
- `build_context/2` resolves each node against its own mount root instead of the single `node.repo` (`core/context_node.ex:172`).
- Node validity: `validate_node/2` = a real directory containing `CONTEXT.md` in that mount (`runtime/helpers.ex:207-229` checked against one root today). `./` stays always-valid. Context-only nodes (rootfs directories holding only `CONTEXT.md`) are valid with no new concept.
- Frontmatter stripping/interpretation is unchanged (`skills/context_integration.ex:42-47`).

### 7.2 Prompt

`# Foreign Repositories` (`agent/context_builder.ex:57-88`, a 3-column table that never renders `mode` or `base_sha`) becomes `# Virtual Tree` when the flag is on:

```
# Virtual Tree — workspace "platform"
/            root   rw   workspace context (rootfs)
/app         repo   rw   Backend application (primary)
/lib         repo   ro   Shared libraries @ v2.3.0
Your node: ./src/auth (mount app). Tree root: $GENESIS_TREE_ROOT.
```

The authority paragraph is derived from the agent's `write_mounts` (it is already pure over `%{parent_id, repo_less, foreign_repos}`, `context_builder.ex:114-131`).
The block is stable across compression refresh (the refresh message is appended, not rewritten — `context_builder.ex:542-555`, so `[system, first_user]` stays byte-identical, as designed today).

### 7.3 Cross-mount conflict resolution

`EvoGit.Agent.ContextMerge` keys ownership by path segments only (`agent/context_merge.ex:626-638`) and merges one repo per call (`:113`), while cross-repo children are never merged (`agent/subagent_processing.ex:541-569`).
In this step: ownership key becomes `{mount_id, node_path}`, merges stay **per mount** (one call per mount, same octopus→sequential fallback), and the workspace-root `CONTEXT.md` is owned by the root agent.
A subagent that edited the rootfs merges into the parent's rootfs view.

## 8. Write authority

### 8.1 One explicit context, no new process-dictionary keys

```elixir
%EvoGit.Agent.Tools.Context{
  workspace_id: "w_3f9c1a2b",
  farm: "<…>/tree", cwd: "<…>/tree/app",
  home: %{mount_id: "app", node_path: "./src/auth"},
  mounts: %{"app" => %{point: "/app", view: "<…>", repo_root: "<repo>", mode: :rw}, …},
  table: %MountTable{}
}
```

Passed **as an argument** through `Tools.execute/5` into the tool task (which does not inherit the caller's process dictionary — `agent/tool_dispatch.ex:1588`).
This single change fixes the currently-inert guards and makes "tool × mount mode × node scope" a unit-testable matrix.

Rule order at the gate:
1. resolve the target path → `mount_id` (or the farm root for tree-absolute paths);
2. `mount.mode == :rw` and the agent holds a grant for it? else reject naming the mount and its mode;
3. the target node must be the agent's own node, a descendant, or — when `node_path == "./"` — any node **of a mount the agent holds rw on**. Note the tightening: today `./` means "anywhere in the repo"; it must not become "anywhere in the tree";
4. write calls to the rootfs are allowed only for agents with rw on `root`.

### 8.2 Sandbox

The writable set becomes table-derived instead of `cwd`-derived:
- `:rw` mount views + the rootfs view + the farm + task tmpdir + each git metadata dir (`git rev-parse --git-common-dir`; today only the primary repo's `.git` is granted, `sandbox/linux.ex:205-212`).
- `:ro` views are excluded and `chmod a-w`.
- `[sandbox] write_paths` stays as a global extra; no new per-task config override is introduced.
- `strict_tree` (default-deny reads outside mounted paths) is a later hardening, after the TOCTOU checks exist.

### 8.3 Grants

- Modes come from `workspace.toml`; a task may only **narrow** (`:rw` → `:ro`) — a widening needs an explicit user action (dashboard/CLI).
- **Agents can never add a mount.** No `mount_add` tool. Needing more access escalates to the user.
- Root agent: rw on every `:rw` mount (`[tree] rw_grant = "root_all"`, today's root authority).
- Subagent: rw on its **home mount only** by default (today's behaviour: it writes the worktree it was spawned into); the root agent may grant extra mounts in the spawn spec.
- One writer per mount is *not* needed: per-agent worktrees already isolate writers; the merge machinery (existing, per repo) reconciles them. Leases are deferred and only become relevant if a shared per-mount worktree is introduced to save cost.

## 9. Root agent and subagents

| Today | After |
|---|---|
| `AgentSpec{repo_id: "primary", foreign_repos: [...]}` (`agent_spec.ex:21-32`) | `AgentSpec{mounts: %MountTable{}, home_mount: "root"|"app", write_mounts: [...], repo_id: <legacy alias>}`, `foreign_repos` kept as a **derived view** of the table so old consumers keep working |
| root cwd = its primary worktree | root cwd = `<farm>/root` (home = rootfs) or `<farm>/<primary>` (`root_home`), so `ls`, `rg` and cross-repo builds work; subagent cwd = its home view (unchanged) |
| children inherit `foreign_repos`; a repo is chosen by id | children inherit the table; a child spec names `{mount_id, node_path}`; routing accepts `/app/src` or `mount: "app", path: "./src"` |
| writable-foreign spawn is root-only | mount grants: root = all rw mounts, subagent = home mount by default, extra mounts explicit |
| prompt `# Foreign Repositories` table | prompt `# Virtual Tree` block + authority from `write_mounts` |
| `bash` sees only its repo | `bash` still runs in a real filesystem, but with all rw mount views writable and `GENESIS_TREE_ROOT` exported |

`root_home = "auto"` (default): a workspace with **one repo mount and no `/CONTEXT.md`** puts the root agent in that mount — i.e. a legacy single-repo task behaves exactly as today (same cwd, same node `./`, same prompt node tree).
Two or more repo mounts (or a non-empty rootfs context) put the root agent at the tree root, which is the whole point of multi-repo work.

`merge_and_report/4` (`runtime/helpers.ex:16-97`) already iterates "primary + writable foreign repos with a commit"; it becomes "every mount with a commit", including the rootfs, still reusing one branch name per mount (`genesis/agent_<8hex>`, `:192-195`).

## 10. Legacy inputs → mounts

| Legacy input | Compiles to |
|---|---|
| `opts[:path] = "/repo"` | an auto workspace: mount `id: "app"` (slugged basename), `point: "/app"`, `mode: :rw`, `primary: "app"`; rootfs created and seeded with `workspace.toml` only (no `/CONTEXT.md`, so prompts and node chains stay identical) |
| `<repo>/genesis.toml [foreign_repos.<id>]` (`project_config.ex:288-307`) | extra mounts, `point: "/<id>"`, `source: root`, `mode: writable ? :rw : :ro`, `ref: base_sha` |
| `-R <id:>path` | the same, as an ad-hoc mount on the task's auto workspace |
| `writable = true` (`core/foreign_repo.ex:27`) | `mode: :rw` |
| `base_sha` | `ref`; a task may narrow it but not widen it |
| `result["repos"]` (`runtime/helpers.ex:119-124`) | kept, keyed by `repo_id` with the primary as `"primary"`; `result["mounts"]` added alongside |
| `<root>/.genesis/foreign_repos/<id>` (`core/foreign_repo.ex:189-192`) | replaced by pinned `<root>/.genesis/mounts/<id>@<sha12>`; legacy dirs are cleaned by `mix mounts.gc` |
| `ProjectConfig.foreign_repos/1` + `load_foreign_repos/2` (`runtime/helpers.ex:312-318`) | stays as the legacy reader; it now produces mounts, and `ForeignWorktree.ensure_all/1` becomes the ro-view materializer |

Legacy inputs stay accepted indefinitely (a deprecation notice points at `workspace.toml`), because they are also how the dashboard's current project flow keeps working during the transition.

## 11. Workspaces and "recently opened projects"

Today: `projects(path PK, name, last_opened_at)` — three columns, recent-only, capped at 10 in Elixir (`task_registry.ex:33`, `:1636-1660`), and its PubSub event is the one node-less message in the system (`task_registry.ex:938`, `:969`).

Change:
- New table (one additive migration, next version above `20260815000006`) following the v5 precedent: `workspaces(id TEXT PK, name TEXT, rootfs_path TEXT UNIQUE, primary_mount TEXT, last_opened_at TEXT, inserted_at TEXT)` + an index on `last_opened_at`.
- Recents = `workspaces ORDER BY last_opened_at`, still capped in `TaskRegistry` (SQL ordering is against the store's convention); `projects` stays readable and its rows are converted **lazily** (opening a recent repo path auto-creates/reuses its workspace — never create git repos inside a migration).
- `tasks.opts` gains `workspace_id` + `mounts` — zero DDL (opaque JSON TEXT via `Types.OptsJson`, `types/json_columns.ex:1-74`), but the key must be registered in the codec whitelist (`store/codec.ex:404-406`) or `store_invariants_test.exs` fails.
- `task_agent_archives` is **not** changed: `repo_id`/`repo_root`/`repo_path`/`foreign_repos` (`operations/archives.ex:94-118`) already carry per-agent repo identity; the derived mount descriptors ride in `foreign_repos`, which is plain JSON with a pair-normalizing dumper (`types/archive_columns.ex:197`, `:53-87`).
- The dashboard's recent-projects event gains the node (`{:workspaces_updated, node}`) — today's payload-less event forces a re-read and breaks cross-node lists.
- The dashboard's foreign-repo editor (`components/project_components.ex:490-819`) becomes the **mount editor** and finally **persists**: it writes `workspace.toml` in the rootfs and commits it. Today the edits live only in the assign, `sessionStorage` and the started task's opts, so they vanish on reload.
- New **Tree page** (greenfield; nothing in the dashboard renders a context tree today): mounts with kind/mode/ref, node `CONTEXT.md` editor, "you are here" node, and the workspace rootfs context.

CLI: `--workspace <id|path|toml>`, `-M <point>=<path>[:rw|:ro]` (repeatable), `-R` retained as an alias, `--root-home`.

## 12. Collection, report and review

```elixir
result["repos"] = %{                    # compat: keyed by repo_id, primary = "primary"
  "primary" => %{commit_sha: "…", branch_name: "genesis/agent_1a2b3c4d"},
  "lib"     => %{commit_sha: "…", branch_name: "genesis/agent_1a2b3c4d"}
}
result["mounts"] = %{                   # rich: keyed by mount_id
  "root" => %{point: "/", role: :rootfs, mode: :rw, base_sha: "…", commit_sha: "…",
              branch_name: "genesis/agent_1a2b3c4d", applied: true},
  "app"  => %{point: "/app", mode: :rw, base_sha: "…", commit_sha: "…", branch_name: "…"},
  "lib"  => %{point: "/lib", mode: :ro, base_sha: "…", commit_sha: nil}
}
```

- `EvoGit.Review` is already repo-path parameterized (`review.ex:235`, `:301`, `:273`) and the dashboard already iterates `[primary | foreign]` per repo with merge / merge-all / per-repo merge check (`review_live/load_data.ex:206-260`, `actions.ex:26-59`, `merge_check.ex:47-232`) — per-mount review is nearly free. Add the mount id + point to each review entry, key cards by mount id, and add a "workspace (rootfs)" card.
- Rootfs edits (context only, root agent only) are applied to `main` on task completion by fast-forward, else a 3-way merge that auto-resolves by node ownership; `[tree] rootfs_review = "auto" | "manual"` (default `auto`). Concurrent tasks on one workspace can genuinely conflict on `/CONTEXT.md`; that is reported, not guessed.
- `TaskCommitGraph` reads `task.commit_sha` + `branch_name` + every `result["repos"]` entry (`task_commit_graph.ex:189-214`), so it keeps working; `mounts` gives it the tree paths it lacks today.
- Nested mounts: collect child → parent; review applies child → parent; a rejected parent merge leaves the child branch recorded as "applied, parent pending" (never silently dropped).

## 13. Phasing

| Phase | Content | Ships independently |
|---|---|---|
| **V1a — model** | `%Mount{}` / `%MountTable{}` / `%Workspace{}`, `VirtualTree.validate/resolve`, legacy normalization (`path`, `foreign_repos`, `-R`), rootfs bootstrap (`ensure_rootfs/1`: init, `workspace.toml`, `.gitignore`, first commit), `workspace_id`+`mounts` in task opts, prompt block rendered **behind `[tree] enabled`** (shadow mode compiles but does not render) | yes, zero behaviour change |
| **V1b — repo mounts end-to-end** | farm materialization, per-agent home worktree (unchanged path), shared pinned ro views, rootfs view, `%Tools.Context{}` + tool gate (fixes the PD bug), sandbox writable set from the table, per-mount commit/report, `result["mounts"]`, review entries per mount, root-agent multi-repo cwd | yes — replaces foreign repos |
| **V1c — workspaces** | `workspaces` table + migration, dashboard workspace switcher + mount editor (persisted), Tree page, recents with node-aware events, CLI `--workspace`/`-M` | yes |
| **V1d — nesting** | `parent`/`path_in_parent`, submodule-shaped mounts, child-first collect, topological review apply, `[tree] submodules = "as-mounts"` expansion from `.gitmodules` | yes |
| **V2** | capability mounts as git mounts: skills repo at `/skills` (bundle install + lockfile + scoped enablement + tool-budget cap), memory repo at `/memory` (append-only), MCP servers (config in the rootfs, tools registered in a tool-source registry) | yes |
| **V3** | remote/cross-node mounts, workload driver hooks (computer use, `:device`) | later |

Rollback: V1a shadow mode asserts the compiled table against the legacy inputs without changing any output; V1b sits behind `[tree] enabled` (flag flip); every DB change is additive.

## 14. Verified constraints that shape the implementation

- **Repo root is inferred from a path string**: `String.split(path, "/.genesis/workers/", parts: 2)` (`agent_scheduler/worktrees.ex:33-38`). Replace with `git rev-parse --show-toplevel` (or use the already-stored `AgentState.repo_root`) before adding a second repo per task.
- **Worktree/branch names are unique per repo only** (`worker_T<n>_A<m>`, `evogit-agent-T<n>-A<m>`), and `task_number` comes from a scan of the *root* repo's workers dir (`dispatch.ex:164-190`, `agent_scheduler.ex:678-679`). Per-mount worktrees make this correct again; a global namespace would collide.
- **The tool task does not inherit the agent's process dictionary** (`tool_dispatch.ex:1588`, `:1609-1611`), which is why the role guards are inert; the fix is the explicit struct, not more PD keys.
- **The sandbox enumerates writes only** (reads are ambient), so `:ro` enforcement needs both exclusion from the writable set and `chmod a-w` on shared views.
- **`tasks.opts` is opaque JSON** but its key whitelist is pinned by a test; a new key must be registered (`codec.ex:404-406`).
- **Archive rows are written from the completing agent's process** and must stay JSON-clean; `foreign_repos` already normalizes keyword lists/tuples.
- **The self-reflective agent** has no repo loading at all (`runtime/self_reflective.ex:72-93`) and `ElixirEval.Authorization` requires `foreign_repos == []`; it should get a **read-only farm** of the workspace and the authorization rule should become "no writable mounts".
- **The dashboard never renders a context tree** and its foreign-repo edits are not persisted; both are prerequisites for a workspace UI that makes sense.

## 15. Risks and open questions

1. **Worktree cost.** N mounts × M agents is expensive (`mix bench.io` measures the underlying I/O). Mitigations: lazy materialization, per-task shared ro views with refcounting and GC, and a hard `max_mounts`. Re-measure before enabling per-agent worktrees for `:ro` mounts.
2. **Symlink farm vs sandbox.** The sandbox must allow the *real* roots of every view, and a writable mount lets an agent create a symlink pointing outside; containment must be `realpath`-checked in `Tools.Context.resolve`, and `strict_tree` stays off until it is.
3. **cwd through a symlink.** The farm subpath is a symlink; most tools (git, mix) resolve it, but anything that compares `cwd` strings may not. Keep the real view path in the context so the runtime never relies on the symlink for its own operations.
4. **Prompt growth** with many mounts — cap count, truncate descriptions, keep the block stable across compression.
5. **Rootfs write concurrency** across tasks on one workspace (genuine `/CONTEXT.md` conflicts); auto-apply must degrade to a reported manual conflict, never to a silent overwrite.
6. **Windows symlinks** need privileges; directory junctions or a `subst`-style fallback, behind a flag.
7. **Open:** should the rootfs be per workspace (recommended: the workspace *is* the rootfs) or one global rootfs with per-workspace subtrees (simpler sharing, harder `/CONTEXT.md` ownership)?
8. **Open:** should a root agent's default write scope be every `:rw` mount (recommended, matches today's root authority) or only its home mount?
9. **Open:** may a task narrow a mount `ref`/`base_sha` (recommended: yes, narrow-only, recorded in the snapshot) or not at all?
10. **Open:** keep the legacy `[foreign_repos]` + `-R` entry points forever (recommended) or deprecate them once workspaces are stable?

## 16. Test strategy

- Pure `VirtualTree` tests (`async: true`): validation matrix, resolution table, legacy normalization, `repo_id` translation.
- Rootfs bootstrap tests: init is idempotent, `workspace.toml` round-trips, `.gitignore` matches the mount points, commits use the Genesis identity.
- Farm materialization against a temp multi-repo fixture: symlinks, per-agent rw worktree paths, shared ro view pinning + `chmod`, teardown order, refcount GC.
- `%Tools.Context{}` guard matrix (tool × mount mode × node scope × tree-absolute vs relative) — this is currently untestable because the guards read process-dictionary state.
- Golden prompt snapshots for `# Virtual Tree` plus the **V1a equivalence assertion**: for a corpus of real tasks, the compiled table, node chain, `repo_id`/`result["repos"]` shape and the legacy prompt are byte-identical with the flag off.
- Sandbox argv snapshots for systemd / bwrap / macOS derived from a table.
- One end-to-end two-mount task: both repos commit, report has `repos` + `mounts`, review shows two cards, rootfs context applied.
- Store: migration shard (fresh DB = one extra create, existing DB = one guarded DDL), codec whitelist invariant, archives unaffected.
