# The Virtual Context Tree (VCT)

Status: **implemented — deliberately minimal, internal only**.
What shipped is a data-structure and namespace refactor, not a kernel filesystem and not a visible workspace feature.
The VCT is an **analogy and an internal namespace**: a canonical `vct:///…` point is bound to an absolute OS path so Genesis can name repositories and context levels independently of where the bytes live.
Its scope is the project registry (`vct:///projects/<name>`) plus one **reserved system mount**, `vct:///genesis-source` (Genesis's own source checkout, §8).
This step does **NOT** create symlink farms, bind mounts, FUSE mounts, directory junctions, per-mount worktrees, or change any filesystem layout.
A task still executes in exactly one concrete repo worktree, and every user-visible path is what it was before.
The intended future extension (remote hosts, further capability mounts, nested mounts) is described at the end; none of it is built.

This record replaces the earlier heavyweight proposal (workspace rootfs as a mount, symlink farm per agent, shared pinned read-only views, per-mount review).

## 1. Scope of the implemented step

The VCT currently provides four things and nothing more:

1. A canonical, parseable **namespace** for repositories (`vct:///projects/<name>`) — `EvoGit.VCT.Path`.
2. A machine-local **mount registry** (SQLite `vct_mounts` in the task store) binding those points to absolute OS paths — `EvoGit.VCT`, `EvoGit.VCT.Mount`, `EvoGit.VCT.Table`.
3. A **spatial-dimension annotation** (`%EvoGit.Core.ContextNode{}.vct_path`) and an optional **global context level** rendered ahead of the in-repo context chain.
4. One **reserved system mount** at `vct:///genesis-source`, giving Genesis's own source checkout a VCT identity (§8).

Everything else that the word "virtual tree" might suggest is out of scope for this step.

## 2. Unchanged behaviour (verify before touching any of these)

- A task runs in **one concrete repo worktree**; `opts[:path]` is still the primary repo and the worktree/branch layout is untouched.
- **Foreign repositories are unchanged**: `%EvoGit.Core.ForeignRepo{}` keeps read-only vs writable (`writable`), absolute OS paths (`root`) and `base_sha`, and is passed through task opts exactly as before.
- **In-repo references stay relative**: a node is still `"./src/auth"`, byte-identical to before; no `vct:///` URL is ever written where a node path is expected.
- **The project list stays project-only**: the reserved system mount `vct:///genesis-source` never appears in `projects/1` / `search/2`, so the dashboard project palette, project auto-activation and the `ListProjects` agent command are unchanged.
- The `# Foreign Repositories` prompt block is still emitted as before.
- Agent `cwd`, the sandbox writable set, worktree create/teardown, branch names, the completion/merge path and task execution are all untouched.
- No `vct:///` URL and no OS path is rendered as a CONTEXT.md file path in a prompt (the one global stage uses the fixed label `global/CONTEXT.md`).
- Legacy SQLite `projects` rows are moved into `vct_mounts` by migration `…000007_vct_mounts`, which then drops `projects`; a fresh database never creates it.

The mount table is **pure metadata**: creating a mount never touches the filesystem, never resolves symlinks and never requires the OS path to exist.

## 3. URL format — `EvoGit.VCT.Path`

Canonical forms:

```
vct:///                     # the VCT root
vct:///projects             # the projects folder
vct:///projects/foo         # a project mount point
vct:///projects/foo/bar     # a nested node under a mount
vct:///genesis-source       # a reserved SYSTEM mount point (§8)
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

## 4. Storage — task store + `<data_dir>/vct/`

`<data_dir>` is `EvoGit.Platform.data_dir/0`, so a `[data] dir` config override relocates the task DB and the VCT's global context coherently with the logs.

The **mount registry is relational state in the task store** (`<data_dir>/tasks.sqlite`), not a file; `<data_dir>/vct/` holds only the optional global context:

```
<data_dir>/tasks.sqlite   # task store: the vct_mounts table lives here
<data_dir>/vct/
  CONTEXT.md              # optional GLOBAL context (committed when present)
  .gitignore              # only when the git repo is lazily initialized
```

### 4.1 The mount table — `vct_mounts`

`vct_mounts` is created by migration `…000007_vct_mounts`, the only create site:

| column | type | notes |
|---|---|---|
| `point` | TEXT PRIMARY KEY | canonical `vct:///projects/<name>` point, or a reserved system point such as `vct:///genesis-source`; unique within the table |
| `path` | TEXT NOT NULL UNIQUE | absolute OS path the point binds to |
| `name` | TEXT NOT NULL | display name |
| `kind` | TEXT NOT NULL | mount kind, `"git"` today |
| `last_opened_at` | TEXT | ISO-8601, or NULL for a mount never opened |

- `EvoGit.Store.list_vct_mounts/1` returns STRING-KEYED entries newest first (`last_opened_at` DESC, `nil` LAST, `point` ASC tie-break); a failed read degrades to `[]` through the store's fault-isolated read path.
- `EvoGit.Store.save_vct_mounts/2` is an **atomic replace-all** inside one transaction, so a reader sees either the old table or the new one.
- `EvoGit.VCT` keeps the authoritative list in memory as a read cache and writes the whole table back before its state changes, so memory and database can never disagree.
- `last_opened_at` uses the store's shared ISO-8601 TEXT wire format (`EvoGit.Store.Types.TaskTimestamp`).
- The one table holds **both** user project mounts and reserved system mounts (§8); the two differ only in their point namespace and in the rules applied to them, never in storage or in the write path.
- There is no JSON mount table and no boot-time import.

### 4.2 The optional global context

`<data_dir>/vct/CONTEXT.md` is the **global context level**, read by `global_context/0` (`""` when absent or unreadable) and written verbatim by `put_global_context/1`.

When content is non-blank, writing it lazily initializes a git repository at `<data_dir>/vct/` (idempotent — an existing `.git` is reused), writes a `.gitignore` excluding only atomic-write temporaries (`*.tmp`, `*.tmp.*`) — the mount table is task-store state, not a file here — stages the context and commits it as `Update global context`; a clean tree commits nothing.
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

## 7. The VCT project registry

The dashboard project list is a **persistent, capped registry of project mounts**.

- Opening or creating a project mounts it (`EvoGit.VCT.mount/2`), which refreshes `last_opened_at`; mounting an already-mounted normalized OS path is idempotent and keeps the existing point.
- Registration derives a stable, deduplicated `vct:///projects/<basename>` point (a basename collision gets `-N`), updates the name only for a non-blank name, and **re-points** a same-named mount whose recorded OS path is gone instead of accumulating a second point. A new path is never required to exist.
- The registry is **capped**: `EvoGit.VCT.max_projects/0` is 100 by default (app env seam `:vct_max_projects`); mounting beyond the cap evicts the oldest mounts (`nil` `last_opened_at` counts as oldest, deterministic tie-break), so the table stays bounded and newest-first.
- `%EvoGit.VCT.Mount{point, path, name, kind, last_opened_at}` is the single project struct; `EvoGit.TaskRegistry` carries no project API, and the only project topic is `"vct"`.
- PubSub: every successful mount mutation publishes exactly one node-aware `{:vct_updated, node()}` on `"vct"`; a successful `put_global_context/1` publishes the same message, and broadcasts are best-effort.
- Cross-node access: `EvoGit.AgentScheduler.RemoteAPI.projects/0 | mount_project/2 | forget_project/1`, mirrored by `EvoGit.RemoteNode.projects/1 | mount_project/3 | forget_project/2` and `EvoDash.NodeContext.projects/1 | mount_project/3 | forget_project/2`.
- Agent command: `ListProjects.list_projects` (`EvoGit.Agent.Tools.ListProjects`) lists this node's mounts newest-first.

The registry is **project-only where it is visible**: `projects/1` and `search/2` exclude reserved system mounts (§8), so the cap, the palette and the agent command never see them. They are still resolvable by point and by OS path through `resolve/1`, `mount_for_path/1` and `vct_path_for/2`.

**Dashboard.** The Projects palette lists the persisted VCT projects newest-first and renders the mount `point` (`vct:///projects/<name>`) as the primary identity with the OS path as the secondary line.
Opening or creating a project mounts it, "Forget project" is offered for local AND remote nodes, and the palette reloads on `{:vct_updated, node}`.
Ordering is by mount recency only.

## 8. Reserved system mounts — the first one: `vct:///genesis-source`

A **system mount** is a mount Genesis owns for its own operation rather than one the user opens.
The first (and, today, only) one is `vct:///genesis-source`, the VCT identity of Genesis's own source checkout.

### 8.1 The reserved-point rule

- Project mounts live under `vct:///projects/…`; **every point outside that subtree is reserved** for a system mount and is a fixed literal, never derived from a user path.
- Reserved mounts live in the **same `vct_mounts` table** and the same `%EvoGit.VCT.Mount{}` struct, with the same atomic replace-all write and the same node-aware `"vct"` broadcast — there is no second registry, no separate file and no new transport.
- They **are** resolvable like any mount: `resolve/1`, `mount_for_path/1` and `vct_path_for/2` see them, which is what gives a node inside the source tree a `vct_path` (the repo-less assistant's context node carries `vct:///genesis-source`).
- They are **excluded** from `projects/1` and `search/2`, so the dashboard project palette, project auto-activation and `ListProjects` keep listing user projects only.
- They are **never evicted**: the `max_projects/0` cap applies to project mounts only.
- `forget/1` **refuses** them with `{:error, :reserved_point}`.

### 8.2 Registration and the source-root chain

- `vct:///genesis-source` binds to the managed shallow clone directory (`<data_dir>/genesis-source`, app env `:self_reflective_source_dir` to override), which `EvoGit.SelfReflectiveSource` owns.
- The mount is **seeded at boot** from `EvoGit.SelfReflectiveSource.system_mounts/0` through an `EvoGit.VCT` init option, and **re-ensured after a successful clone or update** via `EvoGit.VCT.ensure_mount/3`. Like every mount it is pure metadata: seeding does not clone, does not touch the filesystem, and a not-yet-downloaded checkout is a mount pointing at an absent path.
- **Point-addressed registration is idempotent**: the same OS path is a no-op (no write, no broadcast, no `last_opened_at` churn), a different OS path **re-points** the same point, and the same OS path already mounted elsewhere (for example as a project) is **moved** to the reserved point rather than duplicated.
- Re-pointing `vct:///genesis-source` at another local checkout is therefore the supported way to make the self-reflective agent read a different source tree. The source-root chain is: `:self_reflective_source_root` app env → `GENESIS_SOURCE_ROOT` → the VCT mount at `vct:///genesis-source` when it is a valid Genesis checkout → the managed clone directory → `nil`.
- `EvoGit.SelfReflectiveSource.status/0` reports `point` and `mounted` alongside the existing fields, and the dashboard System page's **Source** card shows the mount point (a VCT row) next to the checkout directory.

### 8.3 What changes and what explicitly does not

Changes: the source tree has a VCT identity, so it resolves through the ordinary mount API (`resolve/1`, `mount_for_path/1`, `vct_path_for/2`) and appears on the System page's Source card.

Does **not** change:

- **No materialization and no filesystem-layout change**: nothing is created, linked or mounted on disk; the clone directory stays an ordinary directory at its usual path.
- **No new transport or protocol**: the mount rides the existing `vct_mounts` table, the existing API and the existing `"vct"` topic.
- **The project list/palette is untouched**: no reserved point appears in `projects/1`, `search/2`, the dashboard palette or `ListProjects`.
- **Task execution is untouched**: `reflect` tasks are repo-less and have no worktree; every other task still runs in one concrete repo worktree with unchanged `foreign_repos`.
- **Nothing becomes user-editable in the VCT**: the mount exposes a location, not an editor; the source gate, clone/update actions and configuration stay where they are.

## 9. API surface — `EvoGit.VCT`

The supervised GenServer owns I/O (the store-backed table, broadcasts, the global context file and its git history); the pure rules live in `EvoGit.VCT.Table` so they can be tested without a process, a store or a data directory.

| Function | Contract |
|---|---|
| `mount(path, opts \\ [])` | absolute OS path → `{:ok, %Mount{}}` (`:name` sets the display name); idempotent per normalized OS path (refreshes `last_opened_at`, keeps the point); `{:error, :relative_path \| :invalid_path}` for bad input |
| `ensure_mount(point, path, opts \\ [])` | point-addressed registration used for reserved system mounts: same point+path → `:ok` no-op (no write, no broadcast, no recency churn); same point, different path → re-points it; same normalized OS path mounted at another point → moves it here |
| `projects(opts \\ [])` | **project** mounts newest-first (`last_opened_at` DESC, `nil` last), reserved system mounts excluded; `:limit` is a positive-integer cap, any other value ignored |
| `search(query, opts \\ [])` | case-insensitive substring over display name, OS path and point, reserved system mounts excluded; a blank query matches every project mount, a non-binary query none; `:limit` as in `projects/1` |
| `forget(key)` | by VCT point (`"vct:…"` / `%Path{}`) or OS path → `:ok`; `{:error, :not_found}` when no mount matches; `{:error, :invalid_point}` for a bad key; `{:error, :reserved_point}` for a reserved system mount |
| `resolve/1` | point or exact OS path → `{:ok, mount}` \| `{:error, :not_found}` |
| `mount_for_path/1` | mount containing an OS path (longest path-boundary prefix), or `nil` |
| `vct_path_for/2` | canonical URL for a relative path inside the mount containing `repo_root`, or `nil` |
| `max_projects/0` | the cap: 100 by default, app env `:vct_max_projects` (a non-positive or non-integer value falls back to the default) |
| `global_context_path/0` | `<data_dir>/vct/CONTEXT.md` (computed default even with no server) |
| `global_context/0` | file contents, `""` when absent or unreadable |
| `put_global_context/1` | write verbatim; lazily `git init` + commit only for non-blank content |

**Reads are total, mutations degrade.** Every client call resolves a missing/dead server to its documented empty value (`[]`, `nil`, `""`, `{:error, :not_found}`); mutations return `{:error, :vct_unavailable}`. A VCT fault can never crash a caller (for example a boot race from `ContextNode`), and broadcasts are best-effort.

**Isolation seam.** `server/0` is read at call time from the `:evogit_vct_server` process-dictionary key (set by `init/1` for self-calls), falling back to the registered singleton `EvoGit.VCT`.
`start_link/1` accepts `:name`, `:data_dir` (default `EvoGit.Platform.data_dir/0`), `:store` (default `EvoGit.Store`) and `:system_mounts` (reserved mounts to seed at boot, default `[]`, fed from `EvoGit.SelfReflectiveSource.system_mounts/0`).
Tests start isolated instances with a unique name, data dir and store (an isolated `EvoGit.Store` owning its own database), so the app-global table is never touched.

## 10. Migration and test strategy

- **One migration owns the table.** `…000007_vct_mounts` is the only create site for `vct_mounts`. On a legacy database it moves the `projects` rows into `vct_mounts` (VCT-identical point derivation from the basename with `-N` dedupe, preserved display names, newest-first, non-absolute rows skipped with a `Logger.warning`, inserts `INSERT OR IGNORE`) and then drops `projects`. A fresh database never creates `projects` at all (`…000001` deliberately omits it), so the legacy section is an O(1) no-op there.
- The fan-out is capped to the 100 NEWEST mounts, so a migration can never produce a table the VCT itself would refuse to grow.
- The migration is self-contained Elixir (the point rules are inlined so an applied migration stays frozen history), runs its statements in body order and asserts post-conditions: the exact `vct_mounts` shape and the absence of `projects`.
- The VCT child starts **after** `EvoGit.Store` (its table lives there) and **before** `EvoGit.TaskRegistry` (so every later reader finds a ready list).
- Tests are `async: true` and touch only pure modules or isolated instances:
  - `vct/path_test.exs` — parsing, normalization, rejection of non-local authorities / dot / control segments, and the parse/format round-trip.
  - `vct_test.exs` — mount idempotency and dedup, portability re-pointing, resolution, newest-first ordering, search, the cap/oldest-eviction rule, reserved system mounts (boot seeding, point-addressed no-op / re-point / move, exclusion from `projects/1` and `search/2`, exemption from the cap, `{:error, :reserved_point}` on forget), broadcasts, global-context git initialization, degradation with an unavailable store or dead server, and durability across a server restart.
  - `store/operations/vct_mounts_test.exs` — newest-first ordering, string-keyed entries with a loaded `DateTime`, the atomic replace-all write (including a rolled-back failure) and disk-full mapping.
  - `store/vct_mounts_migration_test.exs` — the legacy→`vct_mounts` move + drop + cap, and the fresh-database path with no `projects` table.
- **Equivalence expectation**: with an empty global context and an unmounted repo, every rendered context chain, node `path`, `repo_id`, foreign-repositories block, worktree path and prompt is byte-identical to before the VCT.

## 11. Deliberately deferred / future extension

The following are design intent, **not implemented**, and the first two are explicitly rejected for now:

- **`vct://<host>/<path>` — remote/cross-node mounts.** The URL format reserves the authority segment, and `Path.parse/1` already returns `:non_local_authority`; no transport or resolution exists.
- **Filesystem materialization — symlink farms, bind mounts, FUSE, junctions, per-mount worktrees.** Rejected for this step: a task runs in one concrete worktree and the mount table never creates layout. Any future materialization would have to solve sandbox containment and `realpath` TOCTOU before it could be considered.
- **Global-context UI.** There is no dashboard editor for `<data_dir>/vct/CONTEXT.md` yet; it is written through the API only.
- **Capability mounts as future mounts of git repos** — skills, memory and MCP servers expressed as ordinary git repos mounted at a point, so no new backend is needed per kind. `vct:///genesis-source` (§8) is the **first system mount** and the proof of the reserved-point mechanism, but it is the only one built: no skills/memory/MCP capability mount, no per-capability backend and no capability UI exists yet, and adding one stays deferred.
- **Nested / submodule mounts.** The mount model has no `parent`/`path_in_parent` yet; submodules remain indistinguishable from an unrelated repo at an absolute path.

Open questions:

1. Should the global context be one per machine (today's single `<data_dir>/vct/CONTEXT.md`) or per workspace/project?
2. When remote mounts arrive, is the authority a host identity or a named connection, and how does a mount point stay stable across hosts?
3. Should `kind` grow beyond `"git"` in the in-memory model before any non-git mount exists, or only when the first one is built?
