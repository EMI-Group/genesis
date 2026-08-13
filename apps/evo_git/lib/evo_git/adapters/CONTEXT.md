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
| **Merge** | `merge/2`, `merge_octopus/2`, `merge_base/3` — the two merge variants are thin wrappers over one private `do_merge/2` that goes through `run/2` (no raw `System.cmd` copy-paste) |
| **Status / query** | `conflict_files/1`, `status/1`, `rev_parse/2`, `check_ignore/2` |
| **Tree listing** | `ls_tree_names/2` — recursive file list in a git tree |
| **History** | `log/2`, `file_history/3`, `show/2` |
| **Diff** | `diff/4`, `file_diff/5`, `diff_stat/3`, `diff_numstat/3`, `diff_shortstat/3`, `diff_name_only/3` — changed file paths between two commits |
| **Notes** | `add_note/4`, `remove_note/3`, `show_note/3`, `get_note/4`, `list_notes/2` |
| **Tags** | `tag/3`, `delete_tag/2` |
| **Refs** | `update_ref/3`, `delete_ref/2` — archive refs protecting commits from GC |
| **Branches** | `create_branch/3`, `current_branch/1`, `list_branches/1`, `list_branches/2`, `branch_exists?/2`, `delete_branch/2` |
| **Init** | `init/1` |
| **GitHub** | `gh_available?/0`, `create_pull_request/5`, `create_origin_remote/1`, `origin_default_branch/1`, `has_origin_remote?/1`, `push_branch/2` |

**Return convention (uniform, single documented shape):**
Every function returns `{:ok, value}` on success or `{:error, {tag, output}}` on failure, where `output` is a trimmed `String.t` and `tag` is:

| Tag | Meaning |
|-----|---------|
| `code :: integer` | git CLI exited with that non-zero status (other than the conflict case below) |
| `:conflict` | git exited 1 in a merge-style conflict (or any other exit-1 command) |
| `:enoent` | the repository path does not exist (`run/2` pre-check) |
| `:no_note` | `git notes show` found no note for the object (`get_note/4`) |
| `:invalid_json` | the note content is not valid JSON metadata (`get_note/4`) |
| `:temp_file` | writing the temporary `-F` content file failed (`add_note/4`, `commit/2`) — `output` is the `:file.format_error/1` reason string |

This aligns the adapter with `EvoGit.Review`, which normalizes adapter errors to exactly this `{tag, output}` form internally (review.ex:380-381, 460-461).

**Documented exceptions** (deliberately NOT part of the uniform contract):
- Predicates `branch_exists?/2`, `gh_available?/0`, `branch_has_unique_commits?/3`, `has_origin_remote?/1` return booleans (consumed in boolean contexts, e.g. review.ex:347 `Enum.find(..., &Git.branch_exists?/2)`, pull_request.ex:20-22).
- `origin_default_branch/1` always returns `{:ok, branch}` with a `"main"` fallback (pull_request.ex:26-28 pattern-matches only `{:ok, branch}`; origin/HEAD is frequently unset — deliberate).
- `commit/2` treats "nothing to commit, working tree clean" (exit 1) as success `{:ok, _}`.

Notes on specific functions:
- `ls_tree_names/2`, `diff_name_only/3`, `check_ignore/2`, `list_branches/1`, `list_branches/2` return `{:ok, [files]}` (list, empty on no results) instead of `{:ok, String.t()}`.
- `check_ignore/2`: exit 1 ("no matches") → `{:ok, []}` — a valid result, not an error.
- `list_branches/2` (glob pattern) returns `{:ok, names} | {:error, {tag, output}}` like `list_branches/1`.
- `get_note/4` returns `{:error, {:no_note, output}}` (missing note) / `{:error, {:invalid_json, note_content}}` (unparseable or non-map JSON) / passes through other `{:error, {tag, output}}` (e.g. `:enoent`).
- `merge/2`, `merge_octopus/2` share one private `do_merge/2` → `run/2`; conflict (exit 1) surfaces as `{:error, {:conflict, output}}`, other exits as `{:error, {code, output}}`.
- **Merge dry-runs do NOT use worktrees**: `Review.check_merge/3` runs `git merge-tree --write-tree --name-only --no-messages <branch_sha> <target_sha>` via `run/2` (review.ex) — an in-memory real merge that touches no worktree, index, or ref (nothing is ever created under `.genesis/`). Clean → exit 0 (stdout = resulting tree OID); conflict → exit 1 (stdout = conflicted tree OID line(s) followed by one conflicted path per line; OID lines are dropped by shape, `~r/^[0-9a-f]{40}$/`); any other failure → `{code, output}`. **Requires git >= 2.38** (the `--name-only`/`--no-messages` flags; without `--no-messages` the conflict output carries "Auto-merging"/"CONFLICT" chatter, and exit-1 non-conflict errors — e.g. a missing ref — produce no file lines and are reported as `{:error, {:merge_failed, output}}`). No `merge_abort` helper exists. After a conflicted `merge/2` the repo is left mid-merge (MERGE_HEAD present + unmerged index entries + conflict markers in the working tree). Empirically verified: `git checkout --force <branch>` clears MERGE_HEAD, the unmerged index, and the working-tree markers (so `Review.merge_into_other`'s `force_restore_branch` does discard the conflicted merge state), but `Review.merge_into_current` (target == currently checked-out branch) returns `{:conflict, details}` WITHOUT any restore — the repo stays mid-merge on that branch.

## Known Issues / Notes for Agents — Windows argv quoting (`-m` vs `-F`)

**Never pass arbitrary user/LLM-generated content (commit messages, note content) as a `-m`-style argv element.** On Windows, the command line is re-parsed by git-for-Windows' MSYS2 runtime, which mangles embedded double quotes: a quoted argument splits into multiple argv tokens, and a token starting with `>` is then treated as an option switch (`error: unknown switch `>'`, `too many arguments`). Observed in production with `git notes add -m <message>` where the message is pretty-printed JSON (`Jason.encode!(metadata, pretty: true)` — always contains quotes, newlines, and often `>`/`->` from objective/result text).

**Current implementation:** `Git.add_note/4` (git.ex) and `Git.commit/2` (git.ex) write their content to a unique temp file (`System.tmp_dir!()` + `genesis_git_msg_<unique_integer>.json|.txt`; on Windows the path is passed to git with forward slashes — `C:/Users/...` is safe for MSYS2, backslashes get mangled) and run `git notes ... add [-f] -F <file> <object>` / `git commit -F <file>` instead of `-m`. `-F` matches `-m` semantics: both apply the `whitespace` cleanup for non-edited messages (byte-identical stored messages incl. embedded quotes and `>`); `git notes -F` applies the same cleanup as `-m` (strips `#`-comment lines and surplus empty lines). The note/commit content is written exactly as given (no appended trailing newline). Temp-file deletion ALWAYS runs via `try/after` (cleanup in `after` — this is `try/after`, NOT `try/rescue`; nothing is rescued/swallowed, so the directory's "No try/rescue" constraint is not violated). If `File.write` (non-bang, returns `{:error, reason}`) fails, the function returns `{:error, {:temp_file, reason_string}}` per the uniform contract (`reason_string` from `:file.format_error/1`; see the tag table above).

**Rules for future work in this file:**
- Content-bearing args → `-F <tempfile>` with the `temp_file_path/1` + `normalize_temp_path/1` helpers (private, git.ex) and `try/after` cleanup; never `-m`.
- Other call sites: `tag/3`/`delete_tag/2` have zero callers in lib/test (unused API surface; git itself validates tag names as ref names). `create_branch/3` branch names come from `Runtime.Helpers.generate_branch_name/1` (`genesis/agent_<hex>`, safe alphabet) or fixed test literals; `add_worktree/4` (fallback inside `Worktrees.prepare_new_worktree/5`) uses `Worktrees.branch_name/2` (`evogit-agent-T<task_number>-A<task_local_id>`, safe alphabet) — safe. `create_pull_request/5` title/body are content-bearing but go to the `gh` CLI (a native Go binary parsing via CommandLineToArgvW, NOT MSYS2 — Erlang's Windows argv quoting round-trips embedded quotes correctly for it) — different bug class. `agent/tools/context.ex` (write_context/edit_context commit path) passes the message via `git commit -F <tempfile>` under `EvoGit.Sandbox.resolve_tmpdir()` (sandbox-readable) with Windows path normalization and `try/after` cleanup (details in `agent/tools/CONTEXT.md` → "Known Issues — Windows MSYS2 argv quoting").

### `EvoGit.Adapters.CowWorktree` (`cow_worktree.ex`)
CoW (copy-on-write) optimized worktree creation. Instead of extracting every file from the git database, copies unchanged files from a source working tree using `cp` (leveraging filesystem reflink on Linux, clonefile on macOS), then lets git restore only the differing files via a checkout. Designed as an **optimization with graceful fallback** — any failure disables the feature and returns `{:fallback, reason}` so the caller can use the standard worktree method. **Shape-agnostic w.r.t. the Git adapter contract** — its tagged `with` patterns (`{:source_head, {:ok, sha}} <- ...`) and catch-all `error` arms are contract-agnostic; its `{:error, code, output}` at cow_worktree.ex:207 comes from its own internal `copy_shared_files` (cp), NOT the Git adapter.

| Function | Description |
|---|---|
| `enabled?/0` | Gate: reads `[:git, :cow_worktree_creation]` config (`:auto`/`:enabled`/`:disabled`). In `:auto`, auto-detects once (non-Windows + `cp` available) and caches via `:persistent_term`. |
| `create_worktree/5` | Main entry — creates a CoW-optimized worktree. Returns `:ok` or `{:fallback, reason}`. |
| `flag/0` | Reads the persistent-term flag (`:not_set`/`:enabled`/`:disabled`). |
| `enable/0`, `disable/0` | Set the persistent-term flag. |

**Algorithm**: resolve source HEAD → get dirty files in source working tree → compute changed files between source and target commits → get all target tree files → compute shared files (identical + not dirty) → create empty worktree (`git worktree add --no-checkout`) → copy shared files via batched `cp` (Linux: `--reflink=auto --parents`, ~1000 files per invocation; macOS: `-c` clonefile with pre-created dirs — within each 1000-file batch, files are grouped by parent directory via `Enum.group_by(&Path.dirname/1)` and ONE `cp -c` invocation is run per distinct directory, reducing process spawns from N files to D directories; top-level files (`dir == "."`) target the worktree root directly) → checkout remaining files. All steps handle errors gracefully (NO `try/rescue`), cleaning up partial worktrees and disabling the feature on failure.

## Constraints

- One adapter module per external tool; each file in this directory must follow the `EvoGit.Adapters.<Tool>` naming pattern.
- All external command invocation must go through `run/2` (or equivalent `System.cmd` wrappers) to keep error handling consistent.
- Functions must never raise on CLI failures — they always return tagged tuples. Uniform error shape: `{:error, {tag, output}}` (see return contract above).
- No business logic belongs here; adapters are thin wrappers that translate CLI I/O into Elixir data structures.
- No `try/rescue` — errors are returned as tagged tuples, never rescued/swallowed.
- **CowWorktree** is an exception to the "thin wrapper" rule — it orchestrates a multi-step optimization, but follows the no-`try/rescue` convention and uses non-crashing variants (`File.mkdir_p/1`, `case`/`with` for error propagation).
