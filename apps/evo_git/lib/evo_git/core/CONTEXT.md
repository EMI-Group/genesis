# Core

## Intent

Defines the foundational domain models of EvoGit — the **Spatial Dimension**, the **Temporal Dimension**, and **multi-repo references** — as pure data structures with domain logic. These modules encapsulate how EvoGit reasons about repository structure, history, and cross-repository relationships.

- `ContextNode` models the Spatial Dimension: a tree of directories and files, each annotated with a `CONTEXT.md` contract that gives semantic meaning to AI agents. Supports multi-repo via the `repo_id` field.
- `PhyloGraphNode` models the Temporal Dimension: a mapping from phylogenetic graph operations (mutation, crossover) to git operations (commit, merge), enabling evolutionary workflows on code.
- `ForeignRepo` models a reference to a Git repository (primary or foreign), enabling multi-repo support with path resolution across repositories.

`ContextNode` and `PhyloGraphNode` delegate all low-level git interactions to `EvoGit.Adapters.Git`.

## API Surface

### `EvoGit.Core.ContextNode` (`context_node.ex`)

A struct with fields `path` (relative), `repo` (absolute path), and `repo_id` (atom, defaults to `:primary`).

| Function | Signature | Description |
|---|---|---|
| `is_ignored?/1` | `(t()) -> boolean()` | Checks if the node's path (or any parent) is gitignored |
| `load/2` | `(relative_path, repo_path) -> t()` | Creates a ContextNode from a filesystem path (defaults `repo_id` to `:primary`) |
| `load/3` | `(relative_path, repo_path, repo_id) -> t()` | Creates a ContextNode with an explicit `repo_id` for multi-repo support |
| `hierarchy_nodes/2` | `(relative_path, repo_path) -> {:ok, [t]} \| {:error, term}` | Returns the full chain of ContextNodes from repo root to the given path (defaults `repo_id` to `:primary`) |
| `hierarchy_nodes/3` | `(relative_path, repo_path, repo_id) -> {:ok, [t]} \| {:error, term}` | Returns the full chain of ContextNodes with an explicit `repo_id` |
| `read_context/1` | `(t()) -> {:ok, String.t()} \| {:error, term}` | Reads `CONTEXT.md` for directories, file content for files |
| `read_context!/1` | `(t()) -> String.t()` | Raising variant of `read_context/1` |
| `context_file_path/1` | `(t()) -> String.t()` | Returns the relative path to the context-bearing file |
| `build_context/2` | `(relative_path, repo_path) -> {:ok, String.t()} \| {:error, term}` | Assembles the full AI-ready context string by traversing the hierarchy and reading each node's context |
| `build_context!/2` | `(relative_path, repo_path) -> String.t()` | Raising variant of `build_context/2` |

### `EvoGit.Core.PhyloGraphNode` (`phylo_graph_node.ex`)

A struct with fields `repo`, `base_commit`, and `current_commit`.

| Function | Signature | Description |
|---|---|---|
| `new/2` | `(repo, commit \\ "main") -> t()` | Initializes a node; `base_commit` and `current_commit` both start at the given ref |
| `find_merge_base/2` | `(t(), t()) -> {:ok, String} \| {:error, term}` | Finds the common ancestor between two nodes |
| `add_and_commit/2` | `(t(), message) -> {:ok, t()} \| {:error, term}` | Stages all changes and commits; returns updated node with new SHA |
| `crossover/2` | `(t(), t()) -> {:ok, t()} \| {:conflict, t(), [String]} \| {:error, term}` | Merges another node's commit; detects conflicts |
| `get_conflict_files/1` | `(t()) -> {:ok, [String]} \| {:error, term}` | Lists currently conflicting files |
| `current_head/1` | `(repo) -> {:ok, String} \| {:error, term}` | Resolves HEAD SHA for a repo path |
| `list_directories/1` | `(t()) -> {:ok, [String]} \| {:error, term}` | Lists all directories at the node's commit |
| `list_files/1` | `(t()) -> {:ok, [String]} \| {:error, term}` | Lists all files at the node's commit |
| `list_immediate_children/2` | `(t(), path) -> {:ok, [String]} \| {:error, term}` | Lists direct children of a path at the node's commit |

### `EvoGit.Core.ForeignRepo` (`foreign_repo.ex`)

A struct with fields `id` (atom), `root` (absolute path), and `name` (human-readable string or nil). Represents a reference to a Git repository in the multi-repo system.

| Function | Signature | Description |
|---|---|---|
| `new/3` | `(atom(), String.t(), keyword()) :: t()` | Creates a new ForeignRepo struct with expanded root path |
| `primary_id/0` | `() :: :primary` | Returns the primary repo identifier |
| `primary?/1` | `(atom()) :: boolean()` | Checks if the given repo id is the primary repo |
| `normalize_path/2` | `(t(), String.t()) :: {:ok, String.t()} \| {:error, :not_in_repo}` | Normalizes an absolute path to a relative path within this repo |
| `resolve_path/2` | `([t()], String.t()) :: {:ok, atom(), String.t()} \| {:error, :not_in_any_repo}` | Determines which repo a path belongs to and returns the repo id with relative path |
| `absolute_path?/1` | `(String.t()) :: boolean()` | Checks if a path string is absolute (starts with /) |

## Constraints

- Both modules must depend **only** on `EvoGit.Adapters.Git` for git operations — never call `System.cmd` or shell out directly.
- `ContextNode.build_context/2` truncates individual file contents at 10,000 characters to bound AI prompt size.
- `PhyloGraphNode` maintains the invariant that `base_commit` is immutable after creation; only `current_commit` advances.
- All `ContextNode` paths must be relative to the repository root using the `"./"` convention (e.g., `"./"` for root, `"./foo/bar"` for subdirectories); absolute or `..`-prefixed paths are rejected by `hierarchy_nodes/3`.
- Directory naming follows `snake_case` Elixir convention; file names mirror their module name (`context_node.ex` → `ContextNode`).
