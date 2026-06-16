# Adapters

## Intent
Adapter layer that wraps external tool CLIs, providing a safe and idiomatic Elixir API for the rest of the application. Currently contains only a Git adapter, abstracting all `System.cmd("git", ...)` calls behind structured result tuples.

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
| **History** | `log/2`, `file_history/3`, `show/2` |
| **Diff** | `diff/4`, `file_diff/5`, `diff_stat/3`, `diff_numstat/3` |
| **Notes** | `add_note/4`, `remove_note/3`, `show_note/3`, `list_notes/2` |
| **Tags** | `tag/3`, `delete_tag/2` |
| **Branches** | `create_branch/3`, `current_branch/1`, `branch_exists?/2`, `delete_branch/2` |
| **Init** | `init/1` |
| **GitHub** | `gh_available?/0`, `create_pull_request/5` |

**Return convention:**
- `{:ok, String.t()}` — success (trimmed stdout)
- `{:conflict, String.t()}` — exit code 1 (merge conflict, etc.)
- `{:error, code :: integer, String.t()}` — any other non-zero exit

## Constraints
- One adapter module per external tool; each file in this directory must follow the `EvoGit.Adapters.<Tool>` naming pattern.
- All external command invocation must go through `run/2` (or equivalent `System.cmd` wrappers) to keep error handling consistent.
- Functions must never raise on CLI failures — they always return tagged tuples.
- No business logic belongs here; adapters are thin wrappers that translate CLI I/O into Elixir data structures.
