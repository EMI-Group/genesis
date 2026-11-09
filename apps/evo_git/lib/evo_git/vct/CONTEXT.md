# VCT — Virtual Context Tree primitives

## Intent

The Virtual Context Tree (VCT) is a pure in-memory namespace layered over local OS paths: a mount binds a canonical `vct:///…` point to an absolute OS path.
It is NOT a filesystem — no directory is ever created for a point, a mount's OS path is never required to exist, and no symlink, bind mount, junction, FUSE mount or on-disk layout change is ever produced.
The supervised store, its client API and the global context file live one level up in `EvoGit.VCT` (`../vct.ex`).

## API Surface

| Module | Role |
|---|---|
| `EvoGit.VCT.Path` | `root/0`, `projects/0`, `parse/1`, `parse!/1`, `format/1`, `join/2`, `segments/1`, `name/1`, `ancestor?/2`, `under?/2`, `relative_to/2`, `String.Chars` — canonical VCT URL value object |
| `EvoGit.VCT.Mount` | `new/3`, `from_map/1`, `to_map/1` — `%Mount{point, path, name, kind: "git", last_opened_at}` |
| `EvoGit.VCT.Persistence` | `load/1` (total, always `%{mounts, legacy_projects_imported}`), `save/3` (atomic temp+rename), `encode/2`, `decode/1` |
| `EvoGit.VCT.Table` | table rules over a mount LIST: `normalize_os_path/1`, `comparison_form/1`, `path_basename/1`, `display_name/1`, `normalize_name/1`, `find_by_point/2`, `find_by_os_path/2`, `mount_for_path/2`, `sort_by_recency/1`, `register/4`, `remove_by_point/2`, `remove_by_path/2`, `import_legacy/2`, `vct_path_for/2`, `point_segment/1`, `unique_point/2` |

## Constraints

- No filesystem side effects except ONE `File.exists?/1` probe in `EvoGit.VCT.Table.register/4` — the portability re-point rule (a mount whose recorded OS path is gone is re-pointed instead of duplicated).
- No new dependencies; everything is plain Elixir data + `Jason` (via `EvoGit.VCT.Persistence`).
- `EvoGit.VCT.Table` never touches a process, a data dir, the store or PubSub, so it stays unit-testable in isolation.
- Mount points are unique within a table (`unique_point/2`); OS paths compare separator-insensitively so Windows `\` paths work.
- A mount's `point` is STABLE for a stable OS path (idempotent registration never renames the point).
