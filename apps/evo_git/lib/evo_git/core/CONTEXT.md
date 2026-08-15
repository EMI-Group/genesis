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
| `load/2,3` | Creates a ContextNode from a filesystem path |
| `hierarchy_nodes/2,3` | Returns the full chain of ContextNodes from repo root to given path |
| `read_context/1` | Reads CONTEXT.md for directories, file content for files |
| `context_file_path/1` | Returns the relative path to the context-bearing file |
| `build_context/2` | Assembles full AI-ready context string by traversing hierarchy |

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
| `normalize/1` | Coerces any persisted/CLI shape into a `%ForeignRepo{}` struct (`%ForeignRepo{}` passthrough; atom-keyed or string-keyed maps; `"path"`/`:path` accepted as a root fallback); returns `nil` for unparseable input (callers map lists through it and drop `nil`s). Exists because `TaskInfo.opts` persist to SQLite via `Store.Codec` JSON and come back with `:foreign_repos` as STRING-keyed maps — raw dot-access on those crashes with `KeyError`. Used centrally by `TaskRegistry.MergeContext` and `Runtime.Helpers.merge_foreign_repos/2` |
| `primary_id/0` | Returns the primary repo identifier (`"primary"`) |
| `primary?/1` | Checks if a repo id is the primary repo |
| `normalize_path/2` | Normalizes an absolute path to a relative path within this repo |
| `resolve_path/2` | Determines which repo a path belongs to; returns repo id and relative path |
| `absolute_path?/1` | Checks if a path string is absolute |

## Constraints

- All git operations must go through `EvoGit.Adapters.Git` — no direct `System.cmd` or shell calls.
- `ContextNode.build_context/2` truncates CONTEXT.md content at `context_max_bytes` (default 64 KB) to bound AI prompt size. Truncation is UTF-8-safe (uses `String.byte_slice/3`, the Elixir stdlib function that works on bytes and adjusts to eliminate truncated codepoints).
- `PhyloGraphNode`: `base_commit` is immutable after creation; only `current_commit` advances.
- All `ContextNode` paths use `"./"` convention; absolute or `..`-prefixed paths are rejected.
- File names mirror module names (`context_node.ex` → `ContextNode`).

## UTF-8-Safe Truncation in `build_context/2`

`ContextNode.build_context/2` truncates large CONTEXT.md content at `context_max_bytes` (default 64 KB) with `String.byte_slice/3` (Elixir stdlib), which works on bytes and then adjusts to eliminate truncated codepoints — a multi-byte UTF-8 character (e.g. em-dash `—` = `0xE2 0x80 0x94`) is never split, so the context string handed to the LLM request pipeline is always valid UTF-8. The same approach is used in `EvoGit.Sandbox.Helpers.truncate_output/2` and `read_truncated/3` (sandbox output truncation). **Any truncation site must use `String.byte_slice/3` — never raw `binary_part/3` on potentially-multibyte content.**
