# The Virtual Context Tree (VCT)

Status: **implemented — deliberately minimal, internal only**.
What shipped is a data-structure and namespace refactor, not a kernel filesystem and not a visible workspace feature.
The VCT is an **analogy and an internal namespace**: a canonical `vct:///…` point is bound to an absolute OS path so Genesis can name repositories and context levels independently of where the bytes live.
This step does **NOT** create symlink farms, bind mounts, FUSE mounts, directory junctions, per-mount worktrees, or change any filesystem layout.
A task still executes in exactly one concrete repo worktree, and every user-visible path is what it was before.
The intended future extension (remote hosts, capability mounts, nested mounts) is described at the end; none of it is built.

This record replaces the earlier heavyweight proposal (workspace rootfs as a mount, symlink farm per agent, shared pinned read-only views, per-mount review).

## 1. Scope of the implemented step

The VCT currently provides three things and nothing more:

1. A canonical, parseable **namespace** for repositories (`vct:///projects/<name>`) — `EvoGit.VCT.Path`.
2. A machine-local **mount table** binding those points to absolute OS paths — `EvoGit.VCT`, `EvoGit.VCT.Mount`, `EvoGit.VCT.Table`, `EvoGit.VCT.Persistence`.
3. A **spatial-dimension annotation** (`%EvoGit.Core.ContextNode{}.vct_path`) and an optional **global context level** rendered ahead of the in-repo context chain.

Everything else that the word "virtual tree" might suggest is out of scope for this step.

## 2. Unchanged behaviour (verify before touching any of these)

- A task runs in **one concrete repo worktree**; `opts[:path]` is still the primary repo and the worktree/branch layout is untouched.
- **Foreign repositories are unchanged**: `%EvoGit.Core.ForeignRepo{}` keeps read-only vs writable (`writable`), absolute OS paths (`root`) and `base_sha`, and is passed through task opts exactly as before.
- **In-repo references stay relative**: a node is still `"./src/auth"`, byte-identical to before; no `vct:///` URL is ever written where a node path is expected.
- The `# Foreign Repositories` prompt block is still emitted as before.
- Agent `cwd`, the sandbox writable set, worktree create/teardown, branch names, the completion/merge path and task execution are all untouched.
- No `vct:///` URL and no OS path is rendered as a CONTEXT.md file path in a prompt (the one global stage uses the fixed label `global/CONTEXT.md`).
- Legacy SQLite `projects` rows remain readable; the table is deprecated but not dropped.

The mount table is **pure metadata**: creating a mount never touches the filesystem, never resolves symlinks and never requires the OS path to exist.

## 3. URL format — `EvoGit.VCT.Path`

Canonical forms:

```
vct:///                     # the VCT root
vct:///projects             # the projects folder
vct:///projects/foo         # a project mount point
vct:///projects/foo/bar     # a nested node under a mount
```

Only **local** addressing is supported today: the authority must be empty.
`vct://host/projects/foo` is rejected with `{:error, :non_local_authority}`, and that reserved error (not a different scheme) is what leaves the door open for a future `vct://<host>/<path>` remote form.

Parsing/normalization rules (`parse/1`; `parse!/1` raises `ArgumentError`):

- the input must begin with the literal `vct://` scheme (`{:error, :invalid_scheme}` otherwise);
- after the scheme, a `vct://` with no path is `{:error, :invalid_path}`; a remainder that does not start with `/` is a host authority (`{:error, :non_local_authority}`);
- duplicate and trailing slashes are collapsed (`vct:////projects//foo/` → `vct:///projects/foo`);
- a segment is rejected when it is empty, `"."`, `".."`, contains `/`, or contains control characters (`\x00`–`\x1F`, `\x7F`) — reported as `{:error, {:invalid_segment, segment}}`;
- non-binary input is `{:error, :invalid_path}`.

`format/1` always emits the canonical form: one slash between segments and no trailing slash except the root (`vct:///`).
The canonical round-trip holds: `parse(format(p)) == {:ok, p}` for every successfully parsed URL, and formatting is stable under repeated parse/format.
`join/2`, `segments/1`, `name/1`, `ancestor?/2` (strict segment prefix), `under?/2` (prefix incl. equality) and `relative_to/2` operate on segments only — never on a filesystem.
A `String.Chars` implementation renders the canonical URL.

Mount points are **virtual**: they are never created as directories, and a mount entry may point at an OS path that does not exist (portability across machines, backup/restore, or a repo on a detached volume).

## 4. Storage — `<data_dir>/vct/`

`<data_dir>` is `EvoGit.Platform.data_dir/0`, so a `[data] dir` config override relocates the VCT coherently with the task DB and logs.

```
<data_dir>/vct/
  virtual-tree.json   # machine-local mount table (never committed)
  CONTEXT.md          # optional GLOBAL context (committed when present)
  .gitignore          # only when the git repo is lazily initialized
```

### 4.1 The mount table

`<data_dir>/vct/virtual-tree.json` is the single machine-local table, encoded by `EvoGit.VCT.Persistence`:

```json
{
  "version": 1,
  "legacy_projects_imported": true,
  "mounts": [
    {"point": "vct:///projects/foo", "path": "/home/me/src/foo", "name": "foo", "kind": "git", "last_opened_at": "2026-11-09T05:53:00Z"}
  ]
}
```

- `save/3` writes to a temporary file in the **same** directory and renames it into place atomically, so a reader never observes a partial table; a failed rename removes the temporary.
- `load/1` is **total**: a missing, unreadable or corrupt file yields the empty state (with a `Logger.warning`) instead of raising, and invalid individual mount entries are skipped with a warning.
- `Mount.from_map/1` accepts string- or atom-keyed maps; an absent, `nil` or unparseable `last_opened_at` decodes to `nil` without raising.
- `legacy_projects_imported` gates the one-time legacy import (§7).

### 4.2 The optional global context

`<data_dir>/vct/CONTEXT.md` is the **global context level**, read by `global_context/0` (`""` when absent or unreadable) and written verbatim by `put_global_context/1`.

When content is non-blank, writing it lazily initializes a git repository at `<data_dir>/vct/` (idempotent — an existing `.git` is reused), writes a `.gitignore` excluding the machine-local mount table and atomic-write temporaries (`virtual-tree.json`, `*.tmp`, `*.tmp.*`), stages the context and commits it as `Update global context`; a clean tree commits nothing.
Git failures are logged and never lose the written file.
**Blank content never initializes a repository** — an empty global context leaves `<data_dir>/vct/` a plain directory.

## 5. Spatial dimension — `%EvoGit.Core.ContextNode{}`

The node struct now separates **identity** from **presentation**:

| Field | Meaning |
|---|---|
| `path` | in-repo relative `"./…"` string; byte-identical to before; the ONLY field used to expand files |
| `repo` | the concrete repo root (absolute OS path); unchanged |
| `repo_id` | which repository this node belongs to (`"primary"` by default); unchanged |
| `vct_path` | canonical VCT URL (`vct:///projects/foo/src/auth`) or `nil`; INTERNAL metadata |

`load/2,3` populates `vct_path` via `EvoGit.VCT.vct_path_for(repo_path, normalized_path)`, which finds the mount containing `repo_path` (longest OS-path prefix, path-boundary aware) and joins the relative segments.
The read is **total**: a missing/dead VCT server, an unmounted repository, an absolute/`..`-bearing relative path or a non-binary input all yield `nil`.
`vct_path` is never used to expand a file, never derived from `path` and never rendered in a prompt.

**Routing to a deeper node still works exactly as before**: `hierarchy_nodes/2,3` remains purely syntactic (it builds the `"./"; "./foo"; "./foo/bar"` chain and never touches the filesystem), `build_context/2` filters by `File.dir?/1`, and the agent loop still addresses nodes by their relative `path`.

## 6. Context-tree generation

`EvoGit.Core.ContextNode.build_context/2` is still the only function that turns the context tree into prompt text.
Its output is: the **global level first** (when the VCT global context is non-empty), then the in-repo directory chain, then the unchanged location block.

- The global stage is read from `EvoGit.VCT.global_context()` and is always labelled with the literal `File: global/CONTEXT.md` — **never `/`** and never an OS path or the `vct:///` URL of the file.
- Every stage whose `CONTEXT.md` is absent or blank **after front-matter stripping** is skipped, so no empty fenced code block is ever rendered.
- If nothing renders (no global context and no non-blank in-repo stage), only the location block is emitted — `build_context/2` still returns `{:ok, location_info}`.
- The rest of the `<context>` block is unchanged: authority paragraph, foreign-repositories table, repo notes, quality guidance, background-job snapshot and clock are all injected by `EvoGit.Agent.ContextBuilder` as before.
- The message-#1 byte-identity / refresh contract is unchanged: dynamic context is assembled into the first user message, compression refreshes append a runtime-context message rather than rewriting `[system, first_user]`.

The VCT therefore changes **what can appear at the top of the tree**, not how context is assembled or refreshed.

## 7. Recently opened projects, reworked onto the VCT

The dashboard/CLI "recent projects" list is now VCT-backed.

- The SQLite `projects(path PK, name, last_opened_at)` table is **deprecated legacy**.
  At most once, on first boot, the VCT imports its rows as mounts (absolute-path rows only; `name` and `last_opened_at` preserved; `nil` timestamps stay `nil`), then records `legacy_projects_imported: true`.
  A failed save during the import leaves the marker false so the next boot retries; the import is idempotent per OS path.
- `EvoGit.TaskRegistry`'s public recents API keeps its **exact signatures and semantics**: `add_recent_project/2` always replies `:ok` (failures are logged), `list_recent_projects/0` returns `%EvoGit.RecentProject{path, name, last_opened_at, vct_path}`, and `remove_recent_project/1` is idempotent.
  The registry no longer touches the SQLite `projects` table and never broadcasts on its own; it delegates to `EvoGit.VCT`.
- `RecentProject.vct_path` is the mount point; the max-10 cap is a **display projection** only — the VCT retains every mount.
- Registration derives a stable, deduplicated `vct:///projects/<basename>` point (a basename collision gets `-N`), is idempotent per normalized OS path (refreshes recency, keeps the point, updates the name only for a non-blank name), and **re-points** a same-named/same-basename mount whose recorded OS path is gone instead of accumulating a second point. A new path is never required to exist.
- PubSub: the legacy node-less `{:recent_projects_updated}` on `"recent_projects"` is kept for existing consumers, and every successful mount mutation additionally publishes the node-aware `{:vct_updated, node}` on `"vct"`.
  A successful `put_global_context/1` publishes `{:vct_updated, node}`.

## 8. API surface — `EvoGit.VCT`

The supervised GenServer owns I/O (persistence, broadcasts, the global context file and its git history); the pure rules live in `EvoGit.VCT.Table` so they can be tested without a process or a data directory.

| Function | Contract |
|---|---|
| `mounts/0` | every mount in raw persisted order |
| `list_projects/1` | mounts sorted by `last_opened_at` DESC (`nil` last); `:limit` is a display cap only |
| `register_project/2` | absolute OS path → `{:ok, mount}`; idempotent per path; `{:error, :relative_path \| :invalid_path}` for bad input |
| `remove_project/1` | by VCT point (`"vct:…"` / `%Path{}`) or OS path → `:ok`; `{:error, :not_found}` where callers may map to `:ok` |
| `resolve/1` | point or exact OS path → `{:ok, mount}` \| `{:error, :not_found}` |
| `mount_for_path/1` | mount containing an OS path (longest path-boundary prefix), or `nil` |
| `vct_path_for/2` | canonical URL for a relative path inside the mount containing `repo_root`, or `nil` |
| `global_context_path/0` | `<vct_dir>/CONTEXT.md` (computed default even with no server) |
| `global_context/0` | file contents, `""` when absent or unreadable |
| `put_global_context/1` | write verbatim; lazily `git init` + commit only for non-blank content |

**Reads are total, mutations degrade.** Every client call resolves a missing/dead server to its documented empty value (`[]`, `nil`, `""`, `{:error, :not_found}`); mutations return `{:error, :vct_unavailable}`. A VCT fault can never crash a caller (for example a boot race from `ContextNode`), and broadcasts are best-effort.

**Isolation seam.** `server/0` is read at call time from the `:evogit_vct_server` process-dictionary key (set by `init/1` for self-calls), falling back to the registered singleton `EvoGit.VCT`.
`start_link/1` accepts `:name`, `:data_dir` (default `EvoGit.Platform.data_dir/0`), `:path` (the JSON table file), `:legacy_projects` and `:legacy_projects_fun`.
Tests start isolated instances with a unique name, path and data dir, and pass `legacy_projects: []`; the app-global table is never touched.

## 9. Migration and test strategy

- **One-time legacy import, no migration-time repo creation.** Nothing in an Ecto migration creates a git repo or a mount; the import runs in `EvoGit.VCT.init/1` and only reads rows. The `projects` table stays in place as a read-only legacy source.
- The VCT child starts **after** `EvoGit.Store` (the import reads the legacy rows) and **before** `EvoGit.TaskRegistry` (so every later reader finds a ready table).
- Tests are `async: true` and touch only pure modules or isolated instances:
  - `path_test.exs` — parsing, normalization, rejection of non-local authorities / dot / control segments, and the parse/format round-trip.
  - `persistence_test.exs` — mount round-trip, total loads (missing/corrupt/unexpected shape), invalid-entry skipping, atomic save leaving no temp file.
  - `vct_test.exs` — registration idempotency and dedup, portability re-pointing, resolution, recency sorting and the display cap, the one-time import, broadcasts, global-context git initialization, and total reads with no running server.
  - `recent_projects_vct_test.exs` — the unchanged `TaskRegistry` recents API, durability across a registry restart, the max-10 display projection over 12 mounts, and the legacy notification.
- **Equivalence expectation**: with an empty global context and an unmounted repo, every rendered context chain, node `path`, `repo_id`, foreign-repositories block, worktree path and prompt is byte-identical to before the VCT.

## 10. Deliberately deferred / future extension

The following are design intent, **not implemented**, and the first two are explicitly rejected for now:

- **`vct://<host>/<path>` — remote/cross-node mounts.** The URL format reserves the authority segment, and `Path.parse/1` already returns `:non_local_authority`; no transport or resolution exists.
- **Filesystem materialization — symlink farms, bind mounts, FUSE, junctions, per-mount worktrees.** Rejected for this step: a task runs in one concrete worktree and the mount table never creates layout. Any future materialization would have to solve sandbox containment and `realpath` TOCTOU before it could be considered.
- **Global-context UI.** There is no dashboard editor for `<data_dir>/vct/CONTEXT.md` yet; it is written through the API only.
- **Capability mounts as future mounts of git repos** — skills, memory and MCP servers expressed as ordinary git repos mounted at a point, so no new backend is needed per kind.
- **Nested / submodule mounts.** The mount model has no `parent`/`path_in_parent` yet; submodules remain indistinguishable from an unrelated repo at an absolute path.

Open questions:

1. Should the global context be one per machine (today's single `<data_dir>/vct/CONTEXT.md`) or per workspace/project?
2. When remote mounts arrive, is the authority a host identity or a named connection, and how does a mount point stay stable across hosts?
3. Should `kind` grow beyond `"git"` in the in-memory model before any non-git mount exists, or only when the first one is built?
4. Does the deprecated `projects` table ever get dropped, or stay as a permanent read-only legacy source?
