# VCT — Virtual Context Tree primitives

## Intent

The Virtual Context Tree (VCT) is a pure namespace layered over local OS paths: a mount binds a canonical `vct:///…` point to an absolute OS path.
It is NOT a filesystem — no directory is ever created for a point, a mount's OS path is never required to exist, and no symlink, bind mount, junction, FUSE mount or on-disk layout change is ever produced.
The mount table is ordinary relational store state (`vct_mounts` in `tasks.sqlite`); the only files the VCT owns are the OPTIONAL global context `<data_dir>/vct/CONTEXT.md` and its local git repository.
A project list is a persistent, CAPPED list of mounts (oldest evicted), not a "recently opened" history.
VCT URLs are INTERNAL metadata: nothing renders a `vct:///` URL (or an OS path) as a CONTEXT.md file path in a prompt, and agent execution keeps one concrete repo worktree.
The supervised store, its client API and the global context file live one level up in `EvoGit.VCT` (`../vct.ex`); consumers are `EvoGit.RemoteAPI`/`EvoGit.RemoteNode` (`projects/0`, `mount_project/2`, `forget_project/1`), the `ListProjects.list_projects` command, and prompt rendering in `EvoGit.Core.ContextNode`.

## API Surface

Primitives in this directory:

| Module | Role |
|---|---|
| `EvoGit.VCT.Path` | `root/0`, `projects/0`, `parse/1`, `parse!/1`, `format/1`, `join/2`, `segments/1`, `name/1`, `ancestor?/2`, `under?/2`, `relative_to/2`, `String.Chars` — canonical VCT URL value object (`vct:///` only: a non-local authority is rejected, as are empty/`.`/`..`/`/`-bearing segments) |
| `EvoGit.VCT.Mount` | `new/3` (validates + canonicalizes the point, `ArgumentError` on a bad point/path), `from_map/1` (string- OR atom-keyed, unparseable `last_opened_at` → `nil`), `to_map/1` — `%Mount{point, path, name, kind: "git", last_opened_at}` metadata, also the row shape the store persists |
| `EvoGit.VCT.Table` | PURE mount-LIST rules: `normalize_os_path/1`, `comparison_form/1`, `path_basename/1`, `display_name/1`, `normalize_name/1`, `find_by_point/2`, `find_by_os_path/2`, `mount_for_path/2` (longest path-boundary prefix), `sort_by_recency/1`, `enforce_cap/2`, `register/4`, `remove_by_point/2`, `remove_by_path/2`, `vct_path_for/2` (one `%Mount{}` + a relative path), `point_segment/1`, `unique_point/2` |

`EvoGit.VCT` (`../vct.ex`) is the single supervised store over these primitives:

- **State**: `%{name, data_dir, vct_dir, store, mounts}` — `mounts` is an in-memory READ CACHE of the `vct_mounts` table, loaded at `init/1` from `EvoGit.Store.list_vct_mounts/1` through the `:store` init opt (default `EvoGit.Store`); an invalid persisted row is dropped with a warning and a store fault loads `[]` instead of crashing boot.
- **Writes**: every mutation computes the new list, persists the WHOLE table with `EvoGit.Store.save_vct_mounts/2`, and only then replaces the cached list — so memory and the database can never disagree, and a failed persist (`{:error, :disk_full}`, `{:error, :store_unavailable}`) leaves both untouched and is returned to the caller.
- Client reads are TOTAL (`[]`, `nil`, `""`, `{:error, :not_found}` when the server is missing/dead), while mutations degrade to `{:error, :vct_unavailable}` — a VCT fault can never crash a caller (e.g. a boot race from `EvoGit.Core.ContextNode`).
- `server/0` resolves the instance at CALL time from the `:evogit_vct_server` process-dictionary key (set by `init/1` for self-calls), else the registered singleton `__MODULE__`; `start_link/1` takes `:name`, `:data_dir` (default `EvoGit.Platform.data_dir/0`) and `:store`.
- Client functions: `mount/2` (`path` + `:name` → `{:ok, mount}` | `{:error, reason}`), `projects/1` (newest first; `:limit` a positive-integer cap, any other value ignored), `search/2` (CASE-INSENSITIVE SUBSTRING over display name, OS path and point — the autocomplete interface; a blank query matches every mount, a non-binary query matches none; `:limit` as in `projects/1`), `forget/1` (by point — a `"vct:…"` binary or `%Path{}` — or by OS path), `resolve/1` (point or exact OS path → `{:ok, mount}` | `{:error, :not_found}`), `mount_for_path/1` (longest path-boundary prefix, `nil` when none), `vct_path_for/2` (canonical URL for a relative path inside the mount containing `repo_root`, `nil` otherwise), `max_projects/0`, `global_context_path/0`, `global_context/0`, `put_global_context/1`.
- `mount/2` requires an ABSOLUTE OS path (`{:error, :relative_path}` / `:invalid_path` otherwise) and never requires it to exist; registering the SAME path again is idempotent (refreshes `last_opened_at`, keeps the point, updates `name` only for a non-blank name), and a new path matching the name/point basename of a mount whose recorded path is GONE re-points that mount instead of adding a second one.
- **Cap**: `max_projects/0` is 100, overridable through the app env `:vct_max_projects` (a non-positive or non-integer value falls back to the default); a registration that would exceed it EVICTS the oldest mounts (`Table.enforce_cap/2`, `nil` `last_opened_at` = oldest), so the table stays newest-first and bounded.
- `<data_dir>/vct/` is the ONLY directory the VCT creates; a mount point is never materialized.
- The GLOBAL context is `<data_dir>/vct/CONTEXT.md`: `global_context/0` returns its contents (`""` when absent/unreadable) and `put_global_context/1` writes it verbatim, then — only for non-blank content — lazily `git init`s that directory, writes a `.gitignore` (`*.tmp`, `*.tmp.*`), stages and commits as `Update global context` (a clean tree commits nothing; git failures are logged and never lose the file); `init/1` runs the SAME best-effort sync at boot when the file already exists and is non-blank, idempotently and without ever failing boot.
- **Exactly ONE broadcast per successful mutation**: `{:vct_updated, node()}` on `"vct"`; a successful `put_global_context/1` broadcasts the same message; broadcasts are best-effort (`rescue`/`catch` → `:ok`).

## Constraints

- No filesystem side effects except ONE `File.exists?/1` probe in `EvoGit.VCT.Table.register/4` — the portability re-point rule (a mount whose recorded OS path is gone is re-pointed instead of duplicated).
- No new dependencies; the mount table is relational store state, so this directory holds no file/JSON persistence of its own.
- `EvoGit.VCT.Table` never touches a process, a data dir, the store or PubSub, so it stays unit-testable in isolation.
- Mount points are unique within a table (`unique_point/2`); OS paths compare separator-insensitively so Windows `\` paths work.
- A mount's `point` is STABLE for a stable OS path (idempotent registration never renames the point).
- Isolated instances use a unique `:name` + `:data_dir` + `:store` (an isolated `EvoGit.Store` owning its own database), so a test's mounts never reach the app-global table.
