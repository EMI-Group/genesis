# Core

## Intent

Foundational domain models: **Spatial Dimension** (ContextNode — directory/file tree with CONTEXT.md contracts), **Temporal Dimension** (PhyloGraphNode — evolutionary git operations), and **multi-repo references** (ForeignRepo — cross-repository path resolution). All git operations delegate to `EvoGit.Adapters.Git`.

## Routing Table

None — leaf directory (modules: `context_node.ex`, `phylo_graph_node.ex`, `foreign_repo.ex`).

## API Surface

### `EvoGit.Core.ContextNode` (`context_node.ex`)

Struct: `path`, `repo`, `repo_id` (defaults to `"primary"`).

| Function | Description |
|---|---|
| `is_ignored?/1` | Checks if the node's path (or any parent) is gitignored |
| `normalize_relpath/1` | Normalizes a relative path to canonical `"./foo/bar"`; raises on absolute paths |
| `load/2,3` | Creates a ContextNode from a filesystem path (`repo_id` for multi-repo) |
| `hierarchy_nodes/2,3` | Full chain of ContextNodes from repo root to given path (`{:ok, nodes} \| {:error, :invalid_path}`) |
| `build_context/2` | Assembles full AI-ready context string by traversing hierarchy (directories only; YAML frontmatter stripped via `EvoGit.Skills.strip_front_matter/1`) |

> The agent loop calls `build_context/2` and `EvoGit.Skills.hierarchical_skill_names/2` separately — there is no combined context+skills load function. `hierarchical_skill_names/2` has live callers in `agent/runner.ex` (skill loading at agent startup) and `agent/tools/skill/skill_list.ex`.

### `EvoGit.Core.PhyloGraphNode` (`phylo_graph_node.ex`)

Struct: `repo`, `base_commit`, `current_commit`.

| Function | Description |
|---|---|
| `new/1,2` | Initializes a node (base and current commit at given ref) — used by `EvoGit.Task` and the runtime phases (genesis, evolution, skill_extraction) |
| `find_merge_base/2` | Finds common ancestor between two nodes — used by `phylo_graph_node_test.exs` |
| `add_and_commit/2` | Stages all changes and commits; returns updated node — used by `EvoGit.Task` (`mutate/3` commit path) |
| `crossover/2` | Merges another node's commit; detects conflicts — used by `phylo_graph_node_test.exs` |
| `get_conflict_files/1` | Lists currently conflicting files — used by `phylo_graph_node_test.exs` |
| `current_head/1` | Resolves HEAD SHA for a repo path — used by `Runtime.Helpers`, `Runtime.Genesis`, `Runtime.SkillExtraction` |
| `list_files/1` | Lists all files at the node's commit — used by `EvoGit.Task` (`diagnose/3` file tree) |
| `list_immediate_children/2` | Lists direct children of a path at the node's commit — used by `phylo_graph_node_test.exs` |

### `EvoGit.Core.ForeignRepo` (`foreign_repo.ex`)

Struct: `id` (string), `root` (absolute path), `name` (optional string).

| Function | Description |
|---|---|
| `new/3` | Creates a ForeignRepo struct with expanded root path |
| `normalize/1` | Coerces any persisted/CLI shape into a `%ForeignRepo{}` struct (`%ForeignRepo{}` passthrough; atom-keyed or string-keyed maps; `"path"`/`:path` accepted as a root fallback); returns `nil` for unparseable input (callers map lists through it and drop `nil`s). Needed because `TaskInfo.opts` persist to SQLite via `Store.Codec` JSON and come back with `:foreign_repos` as STRING-keyed maps — raw dot-access crashes with `KeyError`. Used centrally by `TaskRegistry.MergeContext` and `Runtime.Helpers.merge_foreign_repos/2` |
| `primary_id/0` | Returns the primary repo identifier (`"primary"`) |
| `primary?/1` | Checks if a repo id is the primary repo |
| `normalize_path/2` | Normalizes an absolute path to a relative path within this repo |
| `resolve_path/2` | Determines which repo a path belongs to; returns repo id and relative path |
| `absolute_path?/1` | Checks if a path string is absolute |

## Constraints

- All git operations must go through `EvoGit.Adapters.Git` — no direct `System.cmd` or shell calls.
- `ContextNode.build_context/2` truncates CONTEXT.md content at `context_max_bytes` (default 64 KB, resolved via `EvoGit.Config.resolve([:truncation, :context_max_bytes])`), appending `"\n... [Content Truncated] ..."`. Truncation is UTF-8-safe via `String.byte_slice/3` (works on bytes, adjusts to eliminate truncated codepoints — never splits a multi-byte char). **Any truncation site must use `String.byte_slice/3` — never raw `binary_part/3` on potentially-multibyte content** (same approach in `EvoGit.Sandbox.Helpers.truncate_output/2` and `read_truncated/3`).
- `PhyloGraphNode`: `base_commit` is immutable after creation; only `current_commit` advances.
- All `ContextNode` paths use `"./"` convention; absolute or `..`-prefixed paths are rejected.
- File names mirror module names (`context_node.ex` → `ContextNode`).
