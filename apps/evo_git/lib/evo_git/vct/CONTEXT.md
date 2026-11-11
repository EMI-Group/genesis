# VCT — Virtual Context Tree primitives

## Intent

The Virtual Context Tree (VCT) is a pure namespace layered over local OS paths: a mount binds a canonical `vct:///…` point to an absolute OS path.
It is NOT a filesystem — no directory is ever created for a point, a mount's OS path is never required to exist, and no symlink, bind mount, junction, FUSE mount or on-disk layout change is ever produced.
The mount table is ordinary relational store state (`vct_mounts` in `tasks.sqlite`); the only files the VCT owns are the OPTIONAL global context `<data_dir>/vct/CONTEXT.md` and its local git repository.
A project list is a persistent, CAPPED list of PROJECT mounts (oldest evicted), not a "recently opened" history.
VCT URLs are INTERNAL metadata: nothing renders a `vct:///` URL (or an OS path) as a CONTEXT.md file path in a prompt, and agent execution keeps one concrete repo worktree.
The supervised store, its client API and the global context file live one level up in `EvoGit.VCT` (`../vct.ex`); consumers are `EvoGit.AgentScheduler.RemoteAPI`/`EvoGit.RemoteNode` (`projects/0`, `mount_project/2`, `forget_project/1`), the `ListProjects.list_projects` command, and prompt rendering in `EvoGit.Core.ContextNode`.

Project mountpoints live under `vct:///projects/<name>`; everything else is a RESERVED (system) mount: `vct:///`, `vct:///projects` (no name) and any other top-level namespace such as `vct:///genesis-source` (the runtime source checkout).
Reserved mounts are real mounts for resolution but are never listed as projects, never forgotten and never evicted by the cap; hosts declare them at boot through the `:system_mounts` init option (see `EvoGit.SelfReflectiveSource`), while `EvoGit.VCT.Table` only owns the rules.

## API Surface

Primitives in this directory:

| Module | Role |
|---|---|
| `EvoGit.VCT.Path` | `root/0`, `projects/0`, `parse/1`, `parse!/1`, `format/1`, `join/2`, `segments/1`, `name/1`, `ancestor?/2`, `under?/2`, `relative_to/2`, `String.Chars` — canonical VCT URL value object (`vct:///` only: a non-local authority is rejected, as are empty/`.`/`..`/`/`-bearing segments) |
| `EvoGit.VCT.Mount` | `new/3` (validates + canonicalizes the point, `ArgumentError` on a bad point/path), `from_map/1` (string- OR atom-keyed, unparseable `last_opened_at` → `nil`), `to_map/1` — `%Mount{point, path, name, kind: "git", last_opened_at}` metadata, also the row shape the store persists |
| `EvoGit.VCT.Table` | PURE mount-LIST rules: `normalize_os_path/1`, `comparison_form/1`, `path_basename/1`, `display_name/1`, `normalize_name/1`, `project_mount?/1`, `reserved?/1`, `project_mounts/1`, `find_by_point/2`, `find_by_os_path/2`, `mount_for_path/2` (longest path-boundary prefix), `sort_by_recency/1`, `enforce_cap/2`, `register/4`, `ensure_mount/4`, `remove_by_point/2`, `remove_by_path/2`, `vct_path_for/2` (one `%Mount{}` + a relative path), `point_segment/1`, `unique_point/2` |

- `Table.project_mount?/1` / `Table.reserved?/1` are the ONE definition of the project-vs-reserved split: a point is a PROJECT mount iff it has at least two segments and the first is `"projects"`.
- Both predicates accept a canonical point string or a `%Path{}` and are TOTAL: an unparseable/non-path input is neither a project mount nor reserved (`false`, never a raise), so callers can tell "reserved" from "not a point at all".
- `Table.project_mounts/1` filters a mount list to its project mounts, preserving order — the only filter list-facing callers use.
- `Table.enforce_cap/2` caps PROJECT mounts only: reserved mounts are always retained and never count against the cap, surviving project mounts keep their original list positions, and a non-positive/non-integer cap leaves the list untouched.
- `Table.ensure_mount/4` (`{:ok, mounts, mount, changed?}` | `{:error, :invalid_point | :invalid_path | :invalid_mounts}`) is the POINT-first, PURE rule for reserved mounts: no clock and no filesystem probe, so `last_opened_at` is never refreshed and a repeated ensure never churns a timestamp.
  Same point + same normalized OS path → the existing mount UNCHANGED (`changed? = false`, no rename); same point + different path → RE-POINT (new path, supplied name only when non-blank, point and `last_opened_at` kept, a row mounting that path elsewhere removed); no row at the point but the path mounted elsewhere → MOVE that row to the point (path, name and `last_opened_at` preserved, supplied name winning when non-blank); otherwise INSERT with `last_opened_at: nil`.
  Points stay unique and an OS path never has two rows.
- `Table.register/4` stays the USER-facing open rule (it refreshes `last_opened_at`, dedupes/portability re-points and always targets a `vct:///projects/<name>` point) — do not use it for system mounts.

`EvoGit.VCT` (`../vct.ex`) is the single supervised store over these primitives:

- **State**: `%{name, data_dir, vct_dir, store, pubsub, mounts}` — `mounts` is an in-memory READ CACHE of the `vct_mounts` table, loaded at `init/1` from `EvoGit.Store.list_vct_mounts/1` through the `:store` init opt (default `EvoGit.Store`); an invalid persisted row is dropped with a warning and a store fault loads `[]` instead of crashing boot.
- **Writes**: every mutation computes the new list, persists the WHOLE table with `EvoGit.Store.save_vct_mounts/2`, and only then replaces the cached list — so memory and the database can never disagree, and a failed persist (`{:error, :disk_full}`, `{:error, :store_unavailable}`) leaves both untouched and is returned to the caller.
- Client reads are TOTAL (`[]`, `nil`, `""`, `{:error, :not_found}` when the server is missing/dead), while mutations degrade to `{:error, :vct_unavailable}` — a VCT fault can never crash a caller (e.g. a boot race from `EvoGit.Core.ContextNode`).
- `server/0` resolves the instance at CALL time from the `:evogit_vct_server` process-dictionary key (set by `init/1` for self-calls), else the registered singleton `__MODULE__`; `start_link/1` takes `:name`, `:data_dir` (default `EvoGit.Platform.data_dir/0`), `:store`, `:pubsub` and `:system_mounts`.
- Client functions: `mount/2` (`path` + `:name` → `{:ok, mount}` | `{:error, reason}`), `ensure_mount/3` (`point` + `path` + `:name` → `{:ok, mount}` | `{:error, reason}`), `projects/1` (newest first; `:limit` a positive-integer cap, any other value ignored), `search/2` (CASE-INSENSITIVE SUBSTRING over display name, OS path and point — the autocomplete interface; a blank query matches every project mount, a non-binary query matches none; `:limit` as in `projects/1`), `forget/1` (by point — a `"vct:…"` binary or `%Path{}` — or by OS path), `resolve/1` (point or exact OS path → `{:ok, mount}` | `{:error, :not_found}`), `mount_for_path/1` (longest path-boundary prefix, `nil` when none), `vct_path_for/2` (canonical URL for a relative path inside the mount containing `repo_root`, `nil` otherwise), `max_projects/0`, `global_context_path/0`, `global_context/0`, `put_global_context/1`.
- `mount/2` requires an ABSOLUTE OS path (`{:error, :relative_path}` / `:invalid_path` otherwise) and never requires it to exist; registering the SAME path again is idempotent (refreshes `last_opened_at`, keeps the point, updates `name` only for a non-blank name), and a new path matching the name/point basename of a mount whose recorded path is GONE re-points that mount instead of adding a second one.
- `ensure_mount/3` requires a valid point (`{:error, :invalid_point}` otherwise, canonicalized before use) and the same path rules, and NEVER requires the path to exist; it applies `Table.ensure_mount/4` then `Table.enforce_cap/2` and persists/broadcasts ONLY when the merge actually changed something — a no-op replies `{:ok, mount}` with no store write, no broadcast and no `last_opened_at` change.
- `projects/1` and `search/2` list PROJECT mounts only (`Table.project_mounts/1`), so the dashboard palette, auto-activation, task flows and `ListProjects` never see a reserved mount — not even for a blank query.
- `resolve/1`, `mount_for_path/1` and `vct_path_for/2` operate over EVERY mount, so a reserved mount resolves and answers for the paths underneath it (e.g. `vct_path_for(<genesis-source path>, "./src") == "vct:///genesis-source/src"`).
- `forget/1` refuses a RESERVED point with `{:error, :reserved_point}` — both when the key is a reserved point string (row or no row) and when an OS-path key matches a reserved mount — and project mounts keep `:ok` / `{:error, :not_found}` / `{:error, :invalid_point}`.
- `:system_mounts` (list of maps or keyword lists with `:point`, `:path`, optional `:name`; default `[]`) is merged at `init/1` with `Table.ensure_mount/4` IN BOOT ORDER, so boot is idempotent and a malformed entry is skipped with a `Logger.warning` (boot never fails); the merged table is persisted only when it changed, a successful change broadcasts exactly ONE `{:vct_updated, node()}`, a persist failure logs a warning and reverts the cache to the LOADED table, and an instance without the option behaves exactly as before.
- **Cap**: `max_projects/0` is 100, overridable through the app env `:vct_max_projects` (a non-positive or non-integer value falls back to the default); a registration that would exceed it EVICTS the oldest PROJECT mounts (`Table.enforce_cap/2`, `nil` `last_opened_at` = oldest), so the table stays newest-first and bounded while reserved mounts are never evicted.
- `<data_dir>/vct/` is the ONLY directory the VCT creates; a mount point is never materialized.
- The GLOBAL context is `<data_dir>/vct/CONTEXT.md`: `global_context/0` returns its contents (`""` when absent/unreadable) and `put_global_context/1` writes it verbatim, then — only for non-blank content — lazily `git init`s that directory, writes a `.gitignore` (`*.tmp`, `*.tmp.*`), stages and commits as `Update global context` (a clean tree commits nothing; git failures are logged and never lose the file); `init/1` runs the SAME best-effort sync at boot when the file already exists and is non-blank, idempotently and without ever failing boot.
- **Exactly ONE broadcast per successful mutation**: `{:vct_updated, node()}` on `"vct"`, published on the instance's `:pubsub` init option (default `EvoGit.PubSub`, so production is unchanged); a successful `put_global_context/1` and a CHANGED `:system_mounts` boot merge broadcast the same message; broadcasts are best-effort (`rescue`/`catch` → `:ok`).
- A test that asserts `"vct"` messages MUST start an isolated `Phoenix.PubSub` instance, pass it as `pubsub:` and subscribe to THAT instance — never to `EvoGit.PubSub` — otherwise a concurrently running case's broadcast is indistinguishable and `refute_receive` windows flake.

## Constraints

- No filesystem side effects except ONE `File.exists?/1` probe in `EvoGit.VCT.Table.register/4` — the portability re-point rule (a mount whose recorded OS path is gone is re-pointed instead of duplicated); `ensure_mount/4` never probes the filesystem.
- No new dependencies; the mount table is relational store state, so this directory holds no file/JSON persistence of its own.
- `EvoGit.VCT.Table` never touches a process, a data dir, the store or PubSub, so it stays unit-testable in isolation.
- Mount points are unique within a table (`unique_point/2`); OS paths compare separator-insensitively so Windows `\` paths work, and one OS path is never mounted at two points.
- A mount's `point` is STABLE for a stable OS path (idempotent registration never renames the point).
- The project-vs-reserved rule lives ONLY in `Table.project_mount?/1`/`reserved?/1` — never re-implement the `projects` namespace test at a call site.
- The cap protects reserved mounts: any code filtering or evicting a mount list must go through `project_mounts/1`/`enforce_cap/2` rather than a raw length or take.
- Isolated instances use a unique `:name` + `:data_dir` + `:store` (an isolated `EvoGit.Store` owning its own database), so a test's mounts never reach the app-global table.
