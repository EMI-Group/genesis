# Adapters

## Intent
Adapter layer that wraps external tool CLIs, providing a safe and idiomatic Elixir API for the rest of the application. Contains the Git adapter (abstracting all `System.cmd("git", ...)` calls behind structured result tuples) and a CoW-optimized worktree creation module.

## Routing Table

None — leaf directory (`git.ex`, `cow_worktree.ex`).

## API Surface

### `EvoGit.Adapters` (parent module — `../adapters.ex`)
Documentation-only module declaring the adapter namespace.

### `EvoGit.Adapters.Git` (`git.ex`)
Low-level Git CLI wrapper centred on **worktree isolation**. Every function takes a `path` (working directory) as its first argument and returns tagged tuples.

| Category | Key Functions |
|---|---|
| **Generic execution** | `run/2` — execute arbitrary `git` args in a directory |
| **Worktree** | `add_worktree/4`, `prune_worktrees/1` |
| **Working tree ops** | `checkout/2`, `reset_hard/2`, `clean/1`, `add/2`, `commit/2` |
| **Merge** | `merge/2`, `merge_octopus/2`, `merge_base/3` |
| **Status / query** | `conflict_files/1`, `status/1`, `rev_parse/2`, `check_ignore/2` |
| **Tree listing** | `ls_tree_names/2` — recursive file list in a git tree |
| **History** | `log/2`, `file_history/3`, `show/2` |
| **Diff** | `diff/4`, `file_diff/5`, `diff_stat/3`, `diff_numstat/3`, `diff_name_only/3` — changed file paths between two commits |
| **Notes** | `add_note/4`, `remove_note/3`, `show_note/3`, `list_notes/2` |
| **Tags** | `tag/3`, `delete_tag/2` |
| **Branches** | `create_branch/3`, `current_branch/1`, `branch_exists?/2`, `delete_branch/2` |
| **Init** | `init/1` |
| **GitHub** | `gh_available?/0`, `create_pull_request/5` |

**Return convention:**
- `{:ok, String.t()}` — success (trimmed stdout)
- `{:conflict, String.t()}` — exit code 1 (merge conflict, etc.)
- `{:error, code :: integer, String.t()}` — any other non-zero exit

Note: `ls_tree_names/2` and `diff_name_only/3` return `{:ok, [files]}` (list of paths, empty list if no results) instead of `{:ok, String.t()}`.

### `EvoGit.Adapters.CowWorktree` (`cow_worktree.ex`)
CoW (copy-on-write) optimized worktree creation. Instead of extracting every file from the git database, copies unchanged files from a source working tree using `cp` (leveraging filesystem reflink on Linux, clonefile on macOS), then lets git restore only the differing files via a checkout. Designed as an **optimization with graceful fallback** — any failure disables the feature and returns `{:fallback, reason}` so the caller can use the standard worktree method.

| Function | Description |
|---|---|
| `enabled?/0` | Gate: reads `[:git, :cow_worktree_creation]` config (`:auto`/`:enabled`/`:disabled`). In `:auto`, auto-detects once (non-Windows + `cp` available) and caches via `:persistent_term`. |
| `create_worktree/5` | Main entry — creates a CoW-optimized worktree. Returns `:ok` or `{:fallback, reason}`. |
| `flag/0` | Reads the persistent-term flag (`:not_set`/`:enabled`/`:disabled`). |
| `enable/0`, `disable/0` | Set the persistent-term flag. |

**Algorithm**: resolve source HEAD → get dirty files in source working tree → compute changed files between source and target commits → get all target tree files → compute shared files (identical + not dirty) → create empty worktree (`git worktree add --no-checkout`) → copy shared files via batched `cp` (Linux: `--reflink=auto --parents`; macOS: `-c` with pre-created dirs) → checkout remaining files. All steps handle errors gracefully (NO `try/rescue`), cleaning up partial worktrees and disabling the feature on failure.

## Constraints

- One adapter module per external tool; each file in this directory must follow the `EvoGit.Adapters.<Tool>` naming pattern.
- All external command invocation must go through `run/2` (or equivalent `System.cmd` wrappers) to keep error handling consistent.
- Functions must never raise on CLI failures — they always return tagged tuples.
- No business logic belongs here; adapters are thin wrappers that translate CLI I/O into Elixir data structures.
- **CowWorktree** is an exception to the "thin wrapper" rule — it orchestrates a multi-step optimization, but follows the no-`try/rescue` convention and uses non-crashing variants (`File.mkdir_p/1`, `case`/`with` for error propagation).
