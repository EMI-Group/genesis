# The Virtual Tree (Workspaces, Mounts, Capabilities) — Design Record

Status: **proposal** (nothing implemented). This record fixes vocabulary, invariants and sequencing for the "virtual tree / VFS" update; each phase below is independently shippable.

## 1. Problem

Genesis today models a task as **one primary repo + N read-mostly "foreign repos"**:

| Symptom | Root cause in the current design |
|---|---|
| Multi-repo work is awkward, the primary repo is implicit | `opts[:path]` *is* the task; everything else is a per-task attachment (`:foreign_repos`) merged from `<repo>/genesis.toml` `[foreign_repos.<id>]` (`EvoGit.ProjectConfig.foreign_repos/1` → `%EvoGit.Core.ForeignRepo{}`) |
| Git submodules cannot be modelled | `%ForeignRepo{id, root, writable, base_sha}` is a **flat, unanchored** list of repo roots; there is no parent/child or path-in-parent relation, so a submodule is just "another repo at some absolute path" |
| The self-reflective agent is blind to multi-repo tasks | `Runtime.SelfReflective.build_spec/2` never loads repos (`Helpers.load_foreign_repos/2` is only called by genesis/evolution/skill-extraction), and `ElixirEval.Authorization` *requires* `foreign_repos == []` |
| No global/external skills or MCP | Skills have exactly one source, `<worktree>/.agents/skills/*.md` (`EvoGit.Skills.skills_dir/0`), and the four tool sources (built-in, `<config_dir>/tools/`, skills, a test seam) are hard-coded in `Runner.effective_tools/1`; there is no tool-source registry and no MCP |
| Coding-only | A "node" is by definition an existing **directory** in a git repo (`Runtime.Helpers.validate_node_path/2`, `ContextNode`) — there is no way to express a node that is not a folder, so memory / computer-use / skill hierarchies cannot be represented |
| "Which repo may I write?" is ad-hoc | Writable-ness is a per-repo boolean on `%ForeignRepo{}`, enforced through **process-dictionary** role keys (`:repo_path`, `:evogit_repo_id`, `:foreign_repos`) — which `ToolDispatch.execute_tool_task/7` does not re-install, so on the normal dispatch path the guards silently do not fire |

The goal is a Linux-VFS-like **virtual tree**: one root `/`, repos and directories mounted at points, capability trees (skills, MCP) mounted in the same tree, and nodes that need no filesystem at all.

## 2. Goals / non-goals

Goals:
1. One spatial namespace per task: `/` plus mount points; deterministic path → `{mount, in-mount path}` resolution.
2. First-class multi-repo: peers, nested mounts (submodules), read-only and read-write mounts, per-mount review and merge.
3. Persistent, named **workspaces** so a user does not re-declare repo groups per task.
4. Capability mounts: skills (the Agent-Skills / `SKILL.md` ecosystem) and MCP servers, installed once, enabled by tree position.
5. Virtual nodes: context-only nodes with no files, enabling memory / instruction-tree / (later) computer-use workloads.
6. Write authority is a property of the mount, granted by the user, enforced at one chokepoint, and visible to the agent.
7. No regression for the single-repo case: same prompts, same `./`-relative node paths, same `.genesis/` layout.

Non-goals (this record):
- A real kernel-level filesystem (no FUSE driver); see §5 for the materialization choice.
- Cross-node mounts (a remote host's repo mounted into a local workspace). Deferred to P6; the data model reserves the field.
- Computer-use execution driver (screen/input tooling). Only the tree/vocabulary hooks are reserved.
- Session-level config overrides — still forbidden; the mount table is task-level data, not scheduler config.

## 3. Vocabulary (fixed)

| Term | Meaning |
|---|---|
| **Virtual tree (VT)** | The spatial namespace of one task: `/` plus mounts. Also the name of the core module `EvoGit.VirtualTree`. |
| **Mount** | A `(mount_id, point, backend, mode, ref)` binding of a backing source into the tree. `%EvoGit.Core.Mount{}` (generalizes `%ForeignRepo{}`). |
| **Mount table** | The immutable, ordered set of mounts of one task — `%EvoGit.VirtualTree.MountTable{}`, snapshotted into the task opts and into every agent spec. |
| **Mount point** | The tree path where a mount appears (`/`, `/app`, `/app/vendor/lib`). **Presentation**; mutable. |
| **Backend** | Where content comes from: `:git`, `:dir`, `:memory`, `:virtual`, `:skills`, `:mcp`. |
| **Node** | A position in the tree. Identity = `{mount_id, node_path}` for file-backed nodes, `{mount_id, node_path}` for virtual nodes too (mount-relative stays canonical). |
| **Virtual node** | A node with no filesystem content (context + capability enablement only). |
| **Workspace** | A named, persistent mount table + a workspace meta tree; the thing a user "opens". |
| **Mount source** | A registered, reusable backing source (a repo path/URL, a directory, a skills bundle) — replaces today's "recent project" and `genesis.toml [foreign_repos]`. |
| **Graft** | Mounting a backend onto a non-empty path of an existing mount (the parent's content at that path is shadowed) — git-submodule-like and Linux-mount-like. |

Design axis: **`mount_id` is identity, `point` is presentation.** Node paths stay mount-relative (`./src/auth`), so promoting a single-repo workspace from `point: "/"` to `point: "/app"` when a second repo is added changes no stored node path and no prompt-visible node.

## 4. The model

### 4.1 Mount

```elixir
%EvoGit.Core.Mount{
  id: "app",                 # stable identity, user-chosen, unique in the table
  point: "/app",             # where it appears in the tree (validated, §4.4)
  kind: :git,                # :git | :dir | :memory | :virtual | :skills | :mcp
  source: "/home/me/src/app",# git: path or URL; dir/skills: path; mcp: server id
  ref: "main",               # git: branch | tag | sha | nil(=HEAD at task start); pinned per task
  mode: :rw,                 # :rw | :ro  (a task may only narrow to :ro)
  parent: nil,               # nested mounts: parent mount_id (submodule / graft)
  path_in_parent: nil,       # nested mounts: path inside the parent (= the point, when derivable)
  description: "Backend app",# surfaced to agents in the tree block
  options: %{}               # kind-specific (memory: write_mode; mcp: transport; skills: legacy?)
}
```

`options` is deliberately an open map so new backends do not change the struct.

### 4.2 Mount table

```elixir
%EvoGit.VirtualTree.MountTable{
  workspace_id: "ws_uuid" | nil,   # nil for an ad-hoc (single-repo) task
  mounts: [%Mount{}],              # ordered: by point, longest-prefix wins on resolution
  origin: :adhoc | :workspace | :legacy_foreign_repos
}
```

Invariants (checked by `VirtualTree.validate_mount_table/1`, pure, used by CLI, dashboard, and task admission):
1. `id` unique and slug-like; `point` unique; `point` starts with `/`, no `.`/`..`/empty segments, no trailing `/` (except `/`).
2. At most **one** mount at `/`. A mount at `/` is only allowed when it is the **only** mount, or it is the designated *root* of a workspace whose other mounts are all grafts inside it (§4.4).
3. A graft point must be either (a) empty/absent in the parent, (b) a gitlink (submodule) in the parent, or (c) an existing directory that is explicitly marked `shadowed: true`. Validation reports which case applies; the dashboard shows a "shadows N files" warning for (c).
4. A `:ro` mount may not contain an `:rw` mount unless the child's `mode: :rw` is explicitly user-granted (no silent escalation); a `:rw` mount inside a `:ro` mount is rejected otherwise.
5. `:rw` on a `:virtual` mount means "the workspace meta repo is writable" — only the workspace owner (root agent / user) may hold it.
6. Max depth and max mounts are config-capped (`[tree] max_mounts`, default 16) to bound prompt size and worktree cost.
7. No mount may point inside another mount's *runtime* area (`.genesis/…`, the mount farm, the data dir).

### 4.3 Path resolution

Two canonical forms, one parser (`EvoGit.VirtualTree.resolve/2`):

- **Mount-relative** (`./src/auth`) — canonical for agent-facing `node_path`, stored in task opts and archives. Backward compatible: it is exactly today's node path.
- **Tree-absolute** (`/app/src/auth`) — canonical for cross-mount references, subagent routing, the dashboard, and the review report.

```
resolve(table, "/app/vendor/lib/x") ->
  {:ok, %{mount_id: "lib", node_path: "./x", mount: %Mount{...}}}
```

Algorithm: longest matching `point` prefix across all mounts, then normalize the remainder with `ContextNode.normalize_relpath/1` (which must be hardened — it currently leaves `..` intact). Resolution **never** crosses a mount boundary implicitly; `..` that would escape a mount is an error, and a mount-relative path is always resolved *inside* its mount (so `./vendor/lib/x` inside mount `app` resolves to mount `lib`, not to the shadowed files).

### 4.4 Single-repo compatibility and promotion

- An ad-hoc task (`path: <repo>`, no mounts) is compiled to `mounts: [%Mount{id: "primary", point: "/", kind: :git, mode: :rw}]`. Node paths, prompts, commits and `.genesis/` layout are unchanged.
- Adding a second mount to a workspace with a `/` root **promotes** the root: its `point` becomes `/<id>`, a virtual root mount (the workspace meta tree) takes `/`, and the peers graft at their points. Because identity is `mount_id` + mount-relative node path, nothing stored changes — only the display and the tree-absolute paths (which are new).
- `:legacy_foreign_repos` origin: `opts[:foreign_repos]` and `<repo>/genesis.toml [foreign_repos.<id>]` are normalized into mounts at admission (`point: "/<id>"` grafted onto the root repo, `ref: base_sha || nil`, `mode: writable ? :rw : :ro`). Legacy inputs stay accepted indefinitely; a deprecation note points at `workspace.toml`.

### 4.5 Backends

| Kind | Content | Writable? | Runtime view |
|---|---|---|---|
| `:git` | a git repo at `ref` | yes (`:rw`) | per-agent `git worktree`; `:ro` → shared pinned read view |
| `:dir` | a plain directory | yes, opt-in | direct path (chmod-protected when `:ro`) |
| `:memory` | a git repo of markdown | yes, `write_mode: :append_only \| :worktree` | per-agent worktree, or per-agent append files |
| `:virtual` | CONTEXT.md nodes only, backed by the workspace meta repo (git) or the task store | only root/user | materialized as **directories containing only `CONTEXT.md`** |
| `:skills` | a skills bundle directory (`*/SKILL.md` or legacy `*.md`) | no | read-only dir + tool schemas (§7) |
| `:mcp` | an external tool server | n/a (tools classified) | no files; tool schemas + dispatch (§7.3) |

`repo-cache`: remote or slow sources are mirrored once at `<data_dir>/repo-cache/<hash>/` (bare) and all task views are cut from the mirror, so a source is fetched once and works offline afterwards. Local-path git sources keep today's fast path (worktree directly from the user's repo, never touching the user's working tree).

## 5. How mounting works (materialization)

Agents run real subprocesses (`bash`, `rg`, `git`, builds) with a `cwd`, under a sandbox that takes **one cwd + one repo_root** today. A purely in-process virtual resolver would therefore break every shell-based tool, so the design materializes the mount table.

### 5.1 Mechanism: a per-agent mount farm of symlinks

Per agent, the scheduler creates a **mount farm**

```
<data_dir>/trees/task_<task_id>/agent_<agent_id>/
  app        -> /home/me/src/app/.genesis/workers/worker_T3_A1      (rw worktree)
  lib        -> /home/me/src/lib/.genesis/mounts/<sha>              (ro read view)
  docs       -> /home/me/docs                                       (ro dir)
  memory     -> /home/me/.local/share/genesis/workspaces/<id>/mem   (rw)
  skills     -> /home/me/.config/genesis/skills                     (ro)
  .genesis-tree.json                                               (the resolved table, for tools + debugging)
```

Reasons this is the right primitive:
- It is **transparent** to every existing tool: `read`, `rg`, `glob`, `git -C app`, `ls`, builds all see a normal POSIX tree; no tool needs a virtual-path rewrite to work.
- It is portable (Linux, macOS, Windows junctions) and works inside both the systemd/bwrap and macOS sandboxes as long as the *real* roots are allowed.
- It gives a natural, inspectable "workspace root" for root agents and for the dashboard.

Alternatives rejected: FUSE (a daemon per task, unportable, no Windows), real bind mounts from the BEAM (impossible in-process; would only exist for subprocesses, diverging from in-process tools), and a pure resolver (breaks shell tools and every build).

The **only** place absolute virtual paths need to work is the in-process tool layer, which already has two chokepoints: `Shared.expand_path/2` / `Platform.safe_expand/2` and `ToolDispatch.batch_execute_tools/5`. Both are extended to take a `%Tools.Context{}` (below) and to rewrite a leading `/` to the farm root.

```elixir
%EvoGit.Agent.Tools.Context{
  farm: "/…/agent_<id>",         # materialized tree root
  cwd: "/…/agent_<id>/app",       # agent cwd = its home mount (nested) or the farm (root agent)
  home_mount: "app",
  mounts: %{"app" => %{point: "/app", path: "…", mode: :rw, kind: :git, repo_root: "…"}, …},
  table: %MountTable{}
}
```

`Tools.execute/5` takes this struct **explicitly** (as a function argument, not a process-dictionary key). That fixes the current propagation bug (`execute_tool_task/7` re-installing only tmpdir/agent ids, so `:repo_less`/`:foreign_repos` guards never fire) and makes the guards testable in isolation.

### 5.2 Sandbox

The sandbox allow-list is derived from the mount table instead of from `(cwd, repo_root)`:
- `:rw` mounts → `ReadWritePaths=` (systemd) / `--bind` (bwrap) / write profile (macOS), including each git mount's metadata dir (resolved via `git rev-parse --git-common-dir`).
- `:ro` mounts → `ReadOnlyPaths=` / `--ro-bind`, and their real views are additionally `chmod`-ed `a-w`.
- The farm root is read+write (scratch space) and is the working directory of root agents.
- `[sandbox] strict_tree = true` (new, default on when a farm exists) turns the sandbox from "read everything, write the cwd" into **default-deny: only mounted paths are visible**, which also closes today's hole where foreign repo roots were never bound at all.
- Skills and MCP: a `:skills` mount is bound read-only so a skill's `scripts/` can execute; MCP servers run as host processes (documented trust boundary, §7.3).

### 5.3 Lifecycle

1. **Resolve** (pure, at task admission): workspace definition + task overrides + legacy inputs → `%MountTable{}`; validate; fail fast with a per-mount error, never a bare `ArgumentError`.
2. **Prepare** (scheduler side, per task): ensure repo objects (cache clone or local); for each `:ro` git mount create/reuse a **refcounted read view** pinned at `ref`; for each `:rw` git mount record the base sha; ensure the meta/memory repos exist.
3. **Materialize** (per agent): build the farm; for each mount create its view on first *use* (lazy) — a `:rw` mount gets its own worktree branching from the task base, a `:ro` mount reuses the task-level view; write `.genesis-tree.json`; set `Tools.Context`.
4. **Enforce**: tool gate (§6.3) + sandbox (§5.2) + chmod for `:ro`.
5. **Collect**: per mount, `git add/commit` the agent's worktree (`commit_pending_in_worktree` generalized to iterate the mount table), then `rev-parse`; nested mounts collect **child first**, then the parent so the gitlink points at the child's new commit.
6. **Report**: `result["mounts"]` (below), one branch name per task reused in every mount (`genesis/agent_<8hex>`), plus `review_status`, usage and the existing per-agent archive.
7. **Teardown**: delete `:rw` worktrees (today's `WorktreeManager.destroy_worktree/3` order: reap background jobs → `rm_rf` → prune → delete branch), decrement read-view refcounts, remove the farm.

### 5.4 Report shape

```elixir
result["mounts"] = %{
  "app" => %{point: "/app", kind: :git, mode: :rw, base_sha: "…", commit_sha: "…",
             branch_name: "genesis/agent_1a2b3c4d"},
  "lib" => %{point: "/app/vendor/lib", kind: :git, mode: :rw, parent: "app",
             path_in_parent: "vendor/lib", base_sha: "…", commit_sha: "…",
             branch_name: "genesis/agent_1a2b3c4d"},
  "docs" => %{point: "/docs", kind: :dir, mode: :ro}
}
```

`EvoGit.Review` is already repo-path-parameterized, so per-mount review is nearly free; the new work is the **workspace review**: one card per mount, the submodule ordering rule (child → parent), and an "apply all" action.

## 6. Context tree in the virtual tree

### 6.1 Where context lives

Context resolution is **concatenation along the tree path** — the VFS analogue of a mount overlay:

```
workspace root CONTEXT.md   (/CONTEXT.md, :virtual, meta repo)
  → mount-root CONTEXT.md   (/app/CONTEXT.md, the repo's own root)
    → in-repo ancestors     (/app/src/CONTEXT.md, /app/src/auth/CONTEXT.md)
```

- `EvoGit.Core.ContextNode` gains `mount_id` and is rendered from `{mount_id, node_path}`.
- `ContextNode.hierarchy_nodes/2` is extended to walk **tree ancestors across mount boundaries** — i.e. emit the mount-root chain of every ancestor mount, then the in-mount chain. For a single-repo task the output is byte-identical to today.
- The `:virtual` mounts and virtual nodes contribute their `CONTEXT.md` exactly like a directory would. Their byte source is the **workspace meta repo** (`<data_dir>/workspaces/<ws_id>/meta/`, a real git repo) so workspace-level intent is versioned, diffable, reviewable and agent-editable — the same mechanism a "personal memory repo" uses. A workspace may instead point its meta at a user-chosen repo path.
- Frontmatter (skill enablement, and new keys) is stripped from the prompt as today (`EvoGit.Skills.strip_front_matter/1`) and interpreted separately.

### 6.2 Filesystem freedom for virtual nodes

`Runtime.Helpers.validate_node_path/2` currently requires an existing directory containing `CONTEXT.md`. It is replaced by `VirtualTree.validate_node/2`: a node is valid if it is (a) a real directory in a `:git`/`:dir`/`:memory` mount, or (b) a registered virtual node, or (c) `./` in any mount. `ls`/`glob`/`rg` on virtual mounts return the node list from the meta repo; file tools fail with "virtual node — no files; use `read_context`" rather than pretending the path is empty.

### 6.3 One write-authority chokepoint

`Shared.validate_file_scope/4` is generalized to `Tools.Context`-aware scope:

1. resolve the target path → `mount_id`;
2. `mount.mode == :rw`? else reject with the mount id and its `:ro` reason;
3. the target node must be the agent's own node, a descendant, or (`node_path == "./"`) **any node of a mount the agent holds rw on** — note this is a *change*: today `./` means "anywhere in the repo", which must not become "anywhere in the tree";
4. virtual nodes: writing `CONTEXT.md` is a write to the meta repo (workspace root node is root-agent/user only).

`Tools.execute/5`'s role gate (`maybe_block_read_only_foreign_repo/5`) collapses into the same check keyed by `mount_id`, and `maybe_block_repo_less/5` becomes "this agent has no writable mounts" (which is what it really means).

### 6.4 Cross-mount CONTEXT.md merge

`EvoGit.Agent.ContextMerge` keys ownership by path segments today. It must key by `{mount_id, node_path}`, auto-resolve only within one mount, and treat the workspace-root `CONTEXT.md` as owned by the root agent. Child merge order stays spawn order; the report gains the mount id.

## 7. Capabilities (skills, MCP, custom tools)

### 7.1 One tool-source registry

Replace the four hard-coded concatenations in `Runner.effective_tools/1` with an explicit registry:

```elixir
%EvoGit.Agent.ToolSource{id, kind, schemas: [...], dispatch: fun, read_only?: bool, scope: mount_id | :workspace | :global}
```

Sources: `builtin`, `custom_tools` (`<config_dir>/tools/`), `skills` (per mount), `mcp` (per server). `ToolDispatch` consults the registry; a name collision resolves by explicit precedence (builtin > custom > skills > mcp) with a warning, instead of the current accidental "first clause wins / custom beats skill".

### 7.2 Skills — the Agent-Skills ecosystem

Current skills (`<worktree>/.agents/skills/*.md`, frontmatter `name`/`description`/`parameters`, first `bash` block = body, enablement via CONTEXT.md frontmatter `skill:` walking the node hierarchy) already implement progressive disclosure. The ecosystem's `SKILL.md` format maps almost 1:1:

| Ecosystem | Genesis mapping |
|---|---|
| `<name>/SKILL.md` + `name`/`description` frontmatter | tool schema (name, description); body is markdown instructions |
| body loaded on activation | `skill_read` / agentic call loads the body (no bash block → body returned as instructions) |
| `scripts/` executed without entering context | a script entry becomes an executable body when declared (`allowed-tools`/convention), run in the sandbox with the `:skills` mount bound |
| `references/`, `assets/` read on demand | reachable as files under the `:skills` mount (tree path), so `read`/`rg` work |
| `npx skills add owner/repo` | **`genesis skills install <repo-url|path>`**: clone/fetch into `<data_dir>/skills/<bundle>/`, copy skill dirs, record provenance + commit in `<data_dir>/skills/lock.json`. Never run npm at task time; optional passthrough wrapper for compat |

Three scopes, all expressed as mounts + inheritance:
- **global**: a `:skills` mount at `/skills` (defaults to `<config_dir>/skills`, plus bundles from the lockfile) — visible to every workspace;
- **workspace**: a `:skills` mount (or dir) mounted at `/skills`/`/<mount>/skills`, declared in `workspace.toml`;
- **project**: `<repo>/.agents/skills` inside a git mount (unchanged, still committed with the repo).

Enablement stays path-scoped and inherited: `skill:` in a CONTEXT.md frontmatter at `/` enables for the whole workspace, at `/app` for that project, at `/app/src/auth` for the subtree. Add an explicit `disable:` key (today only union exists, with no way to subtract a global default) and a task-level `skills: [...]` opt (highest precedence). Precedence: task > deepest node > mount > workspace > global.

Tool-budget guard: every *enabled* skill becomes a tool schema, so cap it (`[skills] max_enabled_tools`, default 15) and expose the rest through a bounded discovery index (name + description, top-N by relevance/keyword) plus `skill_list`/`skill_read`. This is also the honest answer to "global skills but scoped": the global bundle is *installed* once and *enabled* per node.

### 7.3 MCP

- Config: `[mcp.servers.<id>]` in the workspace definition and in global config, with `transport = "stdio" | "http"`, `command`/`args`/`env` or `url`/`headers`, `scope` (mount point), `read_only_tools = [...]`, `enabled = true`.
- Runtime: a supervised per-server client (lazy start on first use, idle stop, bounded restart), tool schemas imported with an `mcp__<server>__<tool>` name, dispatched through the registry. Resources → listed under a read-only `:mcp` node in the tree; prompts → optional.
- Classification: **every MCP tool is WRITE by default** (same conservative rule as custom tools); `read_only_tools` is the user's explicit allow-list. Write calls are serialized and gated per mount.
- Trust boundary: stdio servers run as host processes outside the sandbox; the plan documents this, offers optional `[mcp] sandbox = true` (wrap the server in the existing sandbox), and requires exact-command approval at install time.
- Approvals: reuse `EvoGit.CommandApproval` for first-time install and for sudo-ish servers; per-call approvals are *not* introduced (too noisy) — the gate is the read/write classification.

## 8. Non-code workloads

### 8.1 Memory

A memory "product" is just a git mount of markdown:

```toml
[[mounts]]
id = "memory"
point = "/memory"
kind = "memory"
source = "~/Source/personal-memory"
mode = "rw"
[mounts.options]
write_mode = "append_only"     # one file per agent/task under logs/, an index CONTEXT.md
```

`write_mode = :append_only` avoids the per-agent worktree/merge problem: agents append timestamped entries, a `CONTEXT.md` at `/memory` is the routing table, and `rg` over the mount is the retrieval. A "remember this" workflow becomes a small skill. No code changes beyond the mount kind and the `:virtual`/`:memory` node validation.

### 8.2 Instruction trees / computer use

`:virtual` mounts give the "hierarchy of skills and context with no code" directly: nodes are `CONTEXT.md` files in the workspace meta repo, each optionally enabling skills and describing a procedure. A computer-use workload later adds a `:device` backend (screen/input capabilities as a tool source) and a `workload` field on the task that selects the tool set and the completion contract (no git commit, a screenshot/trace artifact instead). The design constraint that matters *now*: **the completion protocol and review must not assume a git commit** — `Runtime.Helpers.merge_and_report/3` is already bypassed by the repo-less path, so the workload hook belongs next to `TaskExecutor`'s mode dispatch.

## 9. Root agent after the change

| Today | After |
|---|---|
| `AgentSpec{repo_id: "primary", foreign_repos: [...]}` | `AgentSpec{mounts: %MountTable{}, home_mount: "app", node_path: "./", write_mounts: ["app","lib"]}` |
| root cwd = its primary worktree | root cwd = **the farm** (so `ls`, `rg`, cross-repo builds work); nested cwd = its home mount's worktree (so all existing prompts and `mix test` still work) |
| children inherit `foreign_repos`; a repo is chosen by id | children inherit the table; a child spec names `mount_id` + `node_path`; subagent routing accepts `/app/src` or `repo: "app", path: "./src"` |
| writable-foreign spawn: root-only, one at a time, per batch | **per-mount single-writer lease** held by the scheduler (`EvoGit.Mounts.WriteLease`): at most one write-capable agent per `:rw` mount at any moment, any depth. Parallelism across *different* mounts becomes safe (two repos in parallel). |
| foreign-repo root gate (`:foreign_repo_write_not_root`) | replaced by the lease; the "root only" rule survives only as a *policy default* (`[tree] rw_grant = "root_only" | "leased"`) so existing behavior is reproducible |
| prompt: `# Foreign Repos` table + authority paragraph | `# Virtual Tree` block: an indented tree with kind, mode, point, ref, description + the authority paragraph derived from `write_mounts` (`ContextBuilder.build_foreign_repos_section/1` → `build_tree_section/1`) |
| `bash` sees only its repo | `GENESIS_TREE_ROOT` env var in every sandboxed command; absolute virtual paths are **not** interpreted by the shell (the sandbox's `/` is the real root), only by in-process tools — documented in the prompt |

`merge_and_report` becomes per mount (it already is, per repo); `format_foreign_repos/1` archives `result["mounts"]`; `Lifecycle.inject_foreign_repo_commits/2` becomes `inject_mount_commits/2`; `TaskCommitGraph` resolves per mount.

## 10. Workspaces and recently opened projects

Store (new tables, `EvoGit.Store`):
- `mount_sources(id, kind, source, display_name, default_mode, last_used_at, meta JSON)` — the reusable registry (a repo path, a dir, a skills bundle). `projects(path PK, name, last_opened_at)` migrates into it.
- `workspaces(id, name, meta_repo_path, root_spec JSON, last_opened_at, pinned)`.
- `workspace_mounts(workspace_id, mount_id, point, kind, source_id, ref, mode, parent, path_in_parent, description, options JSON, sort)`.
- `tasks.opts` gains `workspace_id` + `mounts`; `:path` / `:foreign_repos` stay readable (normalized at admission). `task_agent_archives.foreign_repos` → `mounts`.

Round-trip: the DB is a runtime cache; the **source of truth is a `workspace.toml`** (written next to the meta repo, or in the repo root for a single-repo workspace, or user-chosen). Dashboard edits write the file and re-read it, so a workspace is portable, reviewable and version-controllable. Format:

```toml
[workspace]
name = "platform"
meta = "~/Source/platform-meta"        # optional; default <data_dir>/workspaces/<id>/meta
default_mode = "ro"                    # default for newly added mounts

[tree]
root_agent_cwd = "farm"                # "farm" | "home"
rw_grant = "leased"

[[mounts]]
id = "app"
point = "/app"
kind = "git"
source = "/home/me/src/app"
mode = "rw"
[mounts.options]
submodules = "as-mounts"               # expand .gitmodules into nested mounts

[[mounts]]
id = "lib"
point = "/app/vendor/lib"
kind = "git"
parent = "app"
path_in_parent = "vendor/lib"
mode = "rw"

[[mounts]]
id = "skills"
point = "/skills"
kind = "skills"
source = "~/.config/genesis/skills"
mode = "ro"

[mcp.servers.docs]
transport = "stdio"
command = "mcp-server-docs"
scope = "/"
```

Layering (precedence, highest wins): task opts → `workspace.toml` → mount's own `<repo>/genesis.toml` (`[foreign_repos]` legacy, `[worktree]`, `[commands]`) → global `config.toml` → built-in defaults. No session-level overrides, unchanged.

Dashboard:
- The project omnibox becomes a **workspace switcher** (workspaces + "open repo as workspace" + "recent sources"); picking a bare repo path auto-creates a single-mount workspace, so today's flow stays one click.
- New **Tree page**: the virtual tree with node kinds, mount modes/refs, per-node `CONTEXT.md` editor, capability badges (skills/MCP enabled here), and the "shadowed" warning for graft points. This is the missing UI today (the dashboard never renders a context tree at all) and it is also the home for the non-code story.
- Task form: a **mount list with per-mount rw toggle** (narrow-only) instead of an implicit project + hidden foreign repos; the selected primary mount + node path replace the implicit `path`.
- Review: per-mount cards + "apply all" in topological order.
- Recents: `last_used_at` on sources and workspaces, per node (each host has its own DB), PubSub payload gains the `node` field (today it is payload-less, which breaks cross-node lists), auto-activate the last workspace.

CLI: `--workspace <name|toml|repo-path>`; `-M <point>:<source>[:rw|:ro]` (repeatable) as the replacement for `-R`; `-R` stays as an alias that compiles to a grafted mount; `--rw-mount <id>` for narrow/widen decisions; `genesis skills install|list|remove`; `genesis mount ls|gc`.

## 11. Phasing

| Phase | Content | Ships independently |
|---|---|---|
| **P0** | `EvoGit.Core.Mount`, `VirtualTree.MountTable` + validation/resolution, legacy normalization (`:path`/`:foreign_repos` → table), prompt block rendering in shadow mode, tests | yes, zero behavior change |
| **P1** | Repo mounts end-to-end: farm materialization, per-agent per-mount worktrees, ro read views, `Tools.Context` (and the PD-propagation fix), sandbox allow-list from the table, per-mount commit/report/review, write leases | yes — replaces foreign repos |
| **P2** | Workspaces: store tables, `workspace.toml`, meta repo, dashboard switcher + Tree page, CLI flags, migration of `projects`/`genesis.toml` | yes |
| **P3** | Capability mounts: tool-source registry, `SKILL.md` support, skills install/lockfile, scoped enablement + `disable:`, discovery index, `:skills` mount | yes |
| **P4** | MCP: stdio/http client, registry integration, classification + approvals, dashboard panel | yes |
| **P5** | Virtual/memory nodes: `:virtual` and `:memory` kinds, `validate_node/2`, memory workflow, workspace meta editing | yes |
| **P6** | Cross-node/remote mounts, workload driver hooks (computer use), `:device` backend | later |

Migration safety: P0's shadow mode compiles legacy inputs into a table and asserts the rendered prompt and the resolved node chain are identical for a corpus of real tasks; P1 adds a config flag (`[tree] enabled = true|false`) so a rollback is a flag flip; the DB migration rewrites nothing — new columns are additive and legacy `opts` stay readable.

## 12. Risks and open questions

1. **Symlink trust / TOCTOU.** An agent can create a symlink inside a writable mount pointing outside it. Mitigations: sandbox default-deny on unmounted paths, `File.realpath` containment check in `Tools.Context.resolve`, and ro views `chmod`-ed. Must be validated before enabling `strict_tree` by default.
2. **Windows.** Symlinks need privileges; use directory junctions (`mklink /J`) or fall back to the pure resolver + `subst`-like behavior. Windows is currently the least-tested platform — phase it in P1 with a feature flag.
3. **Worktree cost.** N worktrees per agent is expensive (`mix bench.io` exists to measure exactly this). Mitigation: lazy creation, ro views shared per task, refcounted read view cache with GC (`mix mounts.gc`).
4. **Prompt growth.** A large tree table costs tokens; cap `max_mounts` and render descriptions truncated; keep the block stable across compression refresh.
5. **Tool-budget growth** from global skills + MCP — the `max_enabled_tools` cap and discovery index are load-bearing, not optional.
6. **Legacy ambiguity**: a repo whose `genesis.toml` declares a foreign repo *inside* itself (nested working tree) must be rejected or coerced into a submodule-style graft; decide the error text.
7. **Read-only enforcement on `:dir` mounts over the user's real files** — a ro dir mount pointing at a live directory can still be mutated by the user mid-task; document that task reproducibility requires git mounts.
8. **Submodule write ordering** on review: applying a child first then the parent is required; what if the parent's merge is rejected? The workspace review must fail atomically or record a partial state.
9. **MCP trust** and secrets in `mcp` config (env vars with tokens) — redaction in the store/settings UI.
10. **Open**: should a workspace be shareable as a single commit-able file including *global* skill pins (a lockfile), so two machines reproduce exactly? Recommended yes (`workspace.toml` + `skills.lock.json`), but it introduces a versioning policy for skills.
11. **Open**: does a root agent get `:rw` on every writable mount by default, or only on the mount it was launched in (with explicit grants for the rest)? Recommended: all writable mounts (matching today's root-agent authority), configurable via `[tree] rw_grant`.
12. **Open**: per-task override of a workspace mount's `ref` — allowed (narrowing only) or forbidden? Recommended: allowed, recorded in the task snapshot and the report.

## 13. Test strategy

- Pure `VirtualTree` unit tests (resolution table, validation rules, legacy normalization, promotion) — `async: true`, no I/O.
- Farm materialization tests against a temp multi-repo fixture (including a submodule-shaped repo) asserting the tree, `git -C` behavior, ro chmod, and teardown.
- A `Tools.Context` guard matrix test (tool × mount mode × node scope) — the current guards are untestable because they read process-dictionary state; passing the context explicitly fixes that.
- Golden prompt snapshots for the `# Virtual Tree` block, plus the P0 equivalence assertion against legacy prompts.
- Sandbox argv snapshots (systemd/bwrap/macOS) for the derived allow-list.
- Skill parser fixtures for both formats, and a discovery-index budget test.
- MCP: a fake stdio server fixture (a tiny script speaking JSON-RPC) — no network.
- One end-to-end multi-repo task with two writable mounts to prove parallel writers on distinct mounts and serialization on the same mount.
