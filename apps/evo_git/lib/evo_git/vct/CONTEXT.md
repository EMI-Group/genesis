# VCT — Virtual Context Tree primitives

## Intent

The Virtual Context Tree (VCT) is a pure in-memory namespace layered over local OS paths: a mount binds a canonical `vct:///…` point to an absolute OS path.
It is NOT a filesystem — no directory is ever created for a point, a mount's OS path is never required to exist, and no symlink, bind mount, junction, FUSE mount or on-disk layout change is ever produced.
VCT URLs are INTERNAL metadata: nothing renders a `vct:///` URL (or an OS path) as a CONTEXT.md file path in a prompt, and agent execution keeps one concrete repo worktree.
The supervised store, its client API and the global context file live one level up in `EvoGit.VCT` (`../vct.ex`); recents consumers are `EvoGit.TaskRegistry` and prompt rendering is `EvoGit.Core.ContextNode`.

## API Surface

Primitives in this directory:

| Module | Role |
|---|---|
| `EvoGit.VCT.Path` | `root/0`, `projects/0`, `parse/1`, `parse!/1`, `format/1`, `join/2`, `segments/1`, `name/1`, `ancestor?/2`, `under?/2`, `relative_to/2`, `String.Chars` — canonical VCT URL value object (`vct:///` only: a non-local authority is rejected, as are empty/`.`/`..`/`/`-bearing segments) |
| `EvoGit.VCT.Mount` | `new/3` (validates + canonicalizes the point, `ArgumentError` on a bad point/path), `from_map/1` (string- OR atom-keyed, unparseable `last_opened_at` → `nil`), `to_map/1` — `%Mount{point, path, name, kind: "git", last_opened_at}` metadata |
| `EvoGit.VCT.Persistence` | `load/1` (TOTAL: missing/unreadable/corrupt file → empty state + warning, invalid entries skipped), `save/3` (atomic temp+rename in the same directory), `encode/2`, `decode/1` — the JSON mount table |
| `EvoGit.VCT.Table` | table rules over a mount LIST: `normalize_os_path/1`, `comparison_form/1`, `path_basename/1`, `display_name/1`, `normalize_name/1`, `find_by_point/2`, `find_by_os_path/2`, `mount_for_path/2` (longest path-boundary prefix), `sort_by_recency/1`, `register/4`, `remove_by_point/2`, `remove_by_path/2`, `import_legacy/2`, `vct_path_for/2` (one `%Mount{}` + a relative path), `point_segment/1`, `unique_point/2` |

`EvoGit.VCT` (`../vct.ex`) is the single supervised store over these primitives:

- Client reads are TOTAL (`[]`, `nil`, `""`, `{:error, :not_found}` when the server is missing/dead), while mutations degrade to `{:error, :vct_unavailable}` — a VCT fault can never crash a caller (e.g. a boot race from `EvoGit.Core.ContextNode`).
- `server/0` resolves the instance at CALL time from the `:evogit_vct_server` process-dictionary key (set by `init/1` for self-calls), else the registered singleton `__MODULE__`; `start_link/1` takes `:name`, `:path` (the JSON table file), `:data_dir` (default `EvoGit.Platform.data_dir/0`), `:legacy_projects` and `:legacy_projects_fun`.
- Client functions: `mounts/0` (raw persisted order), `list_projects/1` (`:limit` — a positive-integer DISPLAY cap; the store keeps every mount; sorted by `last_opened_at` DESC with `nil` LAST), `register_project/2` (`{:ok, mount}` | `{:error, reason}`), `remove_project/1` (`:ok` | `{:error, :not_found}` | `{:error, :invalid_point}` | `{:error, reason}`), `resolve/1` (point or exact OS path → `{:ok, mount}` | `{:error, :not_found}`), `mount_for_path/1` (longest path-boundary prefix, `nil` when none), `vct_path_for/2` (canonical URL for a relative path inside the mount containing `repo_root`, `nil` otherwise), `global_context_path/0`, `global_context/0`, `put_global_context/1`.
- `register_project/2` requires an ABSOLUTE OS path (`{:error, :relative_path}` / `:invalid_path` otherwise) and never requires it to exist; registering the SAME path again is idempotent (refreshes `last_opened_at`, keeps the point, updates `name` only for a non-blank name), and a new path matching the name/point basename of a mount whose recorded path is GONE re-points that mount instead of adding a second one.
- The persisted table is ONE machine-local JSON file (`<data_dir>/vct/virtual-tree.json`): `{"version": 1, "legacy_projects_imported": <bool>, "mounts": [...]}`; `legacy_projects_imported` gates the ONE-TIME import of the deprecated SQLite `projects` rows (absolute-path rows only, `name`/`last_opened_at` preserved, a failed save leaves the marker false so the next boot retries — the import is idempotent per OS path).
- `<data_dir>/vct/` is the ONLY directory the VCT creates; a mount point is never materialized.
- The GLOBAL context is `<data_dir>/vct/CONTEXT.md`: `global_context/0` returns its contents (`""` when absent/unreadable) and `put_global_context/1` writes it verbatim, then — only for non-blank content — lazily `git init`s that directory, writes a `.gitignore` (the table file + `*.tmp*`), stages and commits as `Update global context` (a clean tree commits nothing; git failures are logged and never lose the file).
- Every successful mount mutation broadcasts BOTH `{:recent_projects_updated}` on `"recent_projects"` and `{:vct_updated, node}` on `"vct"`; a successful `put_global_context/1` broadcasts `{:vct_updated, node}`; broadcasts are best-effort (`rescue`/`catch` → `:ok`).

## Constraints

- No filesystem side effects except ONE `File.exists?/1` probe in `EvoGit.VCT.Table.register/4` — the portability re-point rule (a mount whose recorded OS path is gone is re-pointed instead of duplicated).
- No new dependencies; everything is plain Elixir data + `Jason` (via `EvoGit.VCT.Persistence`).
- `EvoGit.VCT.Table` never touches a process, a data dir, the store or PubSub, so it stays unit-testable in isolation.
- Mount points are unique within a table (`unique_point/2`); OS paths compare separator-insensitively so Windows `\` paths work.
- A mount's `point` is STABLE for a stable OS path (idempotent registration never renames the point).
- Isolated instances use a unique `:name` + `:path` + `:data_dir` + `legacy_projects: []` (see `apps/evo_git/test/support/task_registry_case.ex`); tests must never touch the app-global table.
