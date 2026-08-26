# Adapters

## Intent
Adapter layer wrapping external tool CLIs behind a safe, idiomatic Elixir API. Contains the Git adapter (all `System.cmd("git", ...)` calls behind structured result tuples), the GitHub adapter (`gh` CLI issue queries — no GitHub API HTTP calls), and a CoW-optimized worktree creation module.

## Routing Table
None — leaf directory (`git.ex`, `github.ex`, `cow_worktree.ex`).

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
| **Merge** | `merge/2`, `merge_octopus/2`, `merge_base/3`, `merge_ff_only/2` — thin wrappers over one private `do_merge/2` via `run/2`; `merge_ff_only/2` = `run(["merge", "--ff-only", ref], path)` |
| **Status / query** | `conflict_files/1`, `status/1`, `rev_parse/2`, `rev_parse_short/2`, `check_ignore/2`, `remote_url/1,2` |
| **Clone / sync** | `clone/2,3`, `fetch/2` — remote clone (extra args like `["--depth", "1"]` between `clone` and url/path; runs from `File.cwd!()`) + fetch; used by `EvoGit.SelfReflectiveSource` |
| **Tree listing** | `ls_tree_names/2` (recursive file list, gitlinks excluded), `ls_tree_gitlinks/2` (gitlink paths only, mode `160000`/type `commit`) — shared private parser `parse_ls_tree_output/2`; `ls_tree_gitlinks/2` feeds `EvoGit.Runtime.Helpers.load_repo_notes/2` |
| **History** | `log/2`, `file_history/3`, `show/2` |
| **Diff** | `diff/4`, `file_diff/5`, `diff_stat/3`, `diff_numstat/3`, `diff_shortstat/3`, `diff_name_only/3` — changed file paths between two commits |
| **Notes** | `add_note/4`, `remove_note/3`, `show_note/3`, `get_note/4`, `list_notes/2` |
| **Tags** | `tag/3`, `delete_tag/2` |
| **Refs** | `update_ref/3`, `delete_ref/2` — archive refs protecting commits from GC |
| **Branches** | `create_branch/3`, `current_branch/1`, `list_branches/1`, `list_branches/2`, `branch_exists?/2`, `delete_branch/2` |
| **Init** | `init/1` |
| **GitHub** | `gh_available?/0`, `create_pull_request/5`, `create_origin_remote/1`, `origin_default_branch/1`, `has_origin_remote?/1`, `push_branch/2` |

**Return convention (uniform):** every function returns `{:ok, value}` or `{:error, {tag, output}}` (output = trimmed `String.t`). Tag table:

| Tag | Meaning |
|-----|---------|
| `code :: integer` | git CLI exited non-zero (other than the conflict case) |
| `:conflict` | git exited 1 in a merge-style conflict (or any other exit-1 command) |
| `:enoent` | repository path does not exist (`run/2` pre-check) |
| `:no_note` | `git notes show` found no note for the object (`get_note/4`) |
| `:invalid_json` | note content is not valid JSON metadata (`get_note/4`) |
| `:temp_file` | writing the temporary `-F` content file failed (`add_note/4`, `commit/2`) — output is the `:file.format_error/1` reason string |

This matches `EvoGit.Review`, which normalizes adapter errors to exactly this `{tag, output}` form (review.ex:380-381, 460-461).

**Documented exceptions** (deliberately NOT part of the uniform contract):
- Predicates `branch_exists?/2`, `gh_available?/0`, `branch_has_unique_commits?/3`, `has_origin_remote?/1` return booleans (consumed in boolean contexts, e.g. review.ex:347, pull_request.ex:20-22).
- `origin_default_branch/1` always returns `{:ok, branch}` with a `"main"` fallback (pull_request.ex:26-28 pattern-matches only `{:ok, branch}`; origin/HEAD is frequently unset).
- `commit/2` treats "nothing to commit, working tree clean" (exit 1) as success `{:ok, _}`.

Notes on specific functions:
- `ls_tree_names/2`, `diff_name_only/3`, `check_ignore/2`, `list_branches/1`, `list_branches/2` return `{:ok, [files]}` (empty on no results).
- `ls_tree_names/2` runs `git ls-tree -r <treeish>` (NOT `--name-only`, which hides the entry type) and **excludes gitlink/submodule entries** — actual file paths only. Submodule dirs arrive in worktrees as **empty placeholders** (same as `git worktree add`); populate via `git submodule update --init`.
- `check_ignore/2`: exit 1 ("no matches") → `{:ok, []}` — a valid result, not an error.
- `get_note/4` → `{:error, {:no_note, output}}` (missing note) / `{:error, {:invalid_json, note_content}}` (unparseable or non-map JSON) / passes through other `{:error, {tag, output}}` (e.g. `:enoent`).
- `merge/2`/`merge_octopus/2` share one private `do_merge/2` → `run/2`; conflict (exit 1) → `{:error, {:conflict, output}}`, other exits → `{:error, {code, output}}`.
- **Merge dry-runs use NO worktrees**: `Review.check_merge/3` runs `git merge-tree --write-tree --name-only --no-messages <branch_sha> <target_sha>` via `run/2` — an in-memory real merge touching no worktree, index, or ref (nothing ever created under `.genesis/`). Requires git >= 2.38. Clean → exit 0 (stdout = resulting tree OID); conflict → exit 1 (stdout = conflicted tree OID line(s) + one conflicted path per line; OID lines dropped by shape `~r/^[0-9a-f]{40}$/`); exit-1 non-conflict errors (e.g. missing ref) → `{:error, {:merge_failed, output}}`; other failures → `{code, output}`. No `merge_abort` helper exists. After a conflicted `merge/2` the repo is left mid-merge (MERGE_HEAD + unmerged index + conflict markers); `git checkout --force <branch>` clears all three (so `Review.merge_into_other`'s `force_restore_branch` discards the conflicted state), but `Review.merge_into_current` (target == checked-out branch) returns `{:conflict, details}` with NO restore — the repo stays mid-merge on that branch.

## Known Issues — Windows argv quoting (`-m` vs `-F`)

**Never pass arbitrary user/LLM-generated content (commit messages, note content) as a `-m` argv element.** On Windows, git-for-Windows' MSYS2 runtime re-parses the command line: embedded double quotes split an argument into multiple argv tokens, and a token starting with `>` is treated as an option switch (`error: unknown switch `>'`). Hit with `git notes add -m <JSON metadata>` (pretty-printed JSON always contains quotes, newlines, and often `>`/`->`).

- `Git.add_note/4` and `Git.commit/2` write content to a unique temp file (`System.tmp_dir!()` + `genesis_git_msg_<unique_integer>.json|.txt`; Windows path passed with forward slashes — safe for MSYS2) and run `-F <file>` instead of `-m`. `-F` matches `-m` semantics: both apply the `whitespace` cleanup for non-edited messages (byte-identical stored messages incl. embedded quotes and `>`); `git notes -F` strips `#`-comment lines and surplus empty lines. Content written exactly as given (no trailing newline).
- Temp-file deletion ALWAYS runs via `try/after` (NOT `try/rescue` — nothing rescued/swallowed, so the no-`try/rescue` constraint is not violated). `File.write` (non-bang) failure → `{:error, {:temp_file, reason_string}}` (`:file.format_error/1`).
- **Rules for future work**: content-bearing args → `-F <tempfile>` using the private `temp_file_path/1` + `normalize_temp_path/1` helpers (git.ex) + `try/after` cleanup; never `-m`.
- Safe call sites: `tag/3`/`delete_tag/2` (zero callers in lib/test); `create_branch/3` (names from `Runtime.Helpers.generate_branch_name/1` — `genesis/agent_<hex>`, safe alphabet); `add_worktree/4` fallback (uses `Worktrees.branch_name/2` — `evogit-agent-T<task>-A<agent>`, safe alphabet); `create_pull_request/5` title/body go to the `gh` CLI (native Go binary parsing via CommandLineToArgvW, NOT MSYS2 — Erlang's Windows argv quoting round-trips embedded quotes correctly) — different bug class. `agent/tools/context.ex` passes commit messages via `git commit -F <tempfile>` under `EvoGit.Sandbox.resolve_tmpdir()` (details in `agent/tools/CONTEXT.md`).

### `EvoGit.Adapters.GitHub` (`github.ex`)
Thin wrapper for GitHub issue queries via the `gh` CLI (`gh issue list` / `gh issue view`) — no GitHub API HTTP calls. `gh_available?/0` is **reused from `EvoGit.Adapters.Git`** (never duplicated).

**Invocation conventions** (deliberately distinct per binary):
- **gh**: `System.cmd("gh", args, cd: repo_path, stderr_to_stdout: true)` — plain `"gh"`, no GitEnv. Every invocation guarded by `Git.gh_available?/0` first (`System.cmd("gh", ...)` raises `ErlangError` when gh is not on PATH).
- **git**: `System.cmd(EvoGit.Executable.resolve("git"), args, cd: repo_path, stderr_to_stdout: true, env: EvoGit.GitEnv.git_env(repo_path))`.
- `:enoent` convention: every function PRE-CHECKS `File.dir?(repo_path)` → `{:error, {:enoent, repo_path}}`.

**Functions** (all take `repo_path` first; pinned check order: dir exists → gh available → upstream resolvable → run gh):

| Function | Success | Errors |
|---|---|---|
| `github_upstream/1` | `{:ok, %{owner, repo, url, gh_available}}` | `{:error, {:enoent, _}}` / `{:error, :no_github_upstream}` (non-GitHub origin URL, or no origin remote — contract-pinned exit 128, plus exit 2 from git ≥2.55 "No such remote") / `{:error, {:code, code, trimmed_output}}` |
| `list_github_issues/2` (`opts \\ []`: `:state` default `"open"`, `:limit` default 100, integer) | `{:ok, [issue_map]}` | `{:error, {:enoent, _}}` / `{:error, :gh_not_available}` / upstream error as-is / `{:error, {:gh, code, trimmed_output}}` / `{:error, {:invalid_json, reason}}` (malformed JSON — `reason` = Jason error; non-array — `reason` = `:not_an_array`) |
| `github_issue_markdown/2` | `{:ok, markdown}` | same error shapes as `list_github_issues/2` (view JSON is a single object; non-object → `{:error, {:invalid_json, :not_an_object}}`) |

**Upstream URL parsing**: own regexes (NOT git.ex's `@repo_url_re`, which covers https only) — https `https://github.com/owner/repo` AND ssh `git@github.com:owner/repo.git`, each with optional trailing `.git`/slash/whitespace (input trimmed first, then anchored match). `url` = trimmed origin URL verbatim; `repo` has `.git` stripped.

**JSON normalization** (list fields `number,title,state,labels,url,author,createdAt`; view uses `body` instead of `createdAt`): each gh object → `%{number: integer, title: String.t(), state: String.t(), labels: [String.t()], url: String.t(), author: String.t(), created_at: String.t()}` (list map has exactly these 7 keys). `labels` = `name` strings extracted from label objects (missing `name` skipped); `author` = `login` of the author map (missing → `""`); `createdAt` → `:created_at`.

**Pinned markdown format** (`github_issue_markdown/2`, asserted character-for-character):
- With labels: `# GitHub Issue #<n>: <title>\nURL: <url> | State: <state> | Labels: <l1>, <l2>\n\n<body>`
- WITHOUT labels the labels segment is omitted: `# GitHub Issue #<n>: <title>\nURL: <url> | State: <state>\n\n<body>`
- Labels joined with `", "`; body embedded verbatim after one blank line. No `try/rescue` — all failures are tagged tuples.

### `EvoGit.Adapters.CowWorktree` (`cow_worktree.ex`)
CoW (copy-on-write) worktree creation: copies unchanged files from a source working tree via `cp` (filesystem reflink on Linux, clonefile on macOS), then git restores only the differing files via checkout. **Optimization with graceful fallback** — any failure disables the feature and returns `{:fallback, reason}` so the caller uses the standard worktree method. **Shape-agnostic w.r.t. the Git adapter contract** — its tagged `with` patterns and catch-all `error` arms are contract-agnostic; its `{:error, code, output}` at cow_worktree.ex:207 comes from its own internal `copy_shared_files` (cp), NOT the Git adapter.

| Function | Description |
|---|---|
| `enabled?/0` | Gate: reads `[:git, :cow_worktree_creation]` config (`:auto`/`:enabled`/`:disabled`). In `:auto`, auto-detects once (non-Windows + `cp` available) and caches via `:persistent_term`. |
| `create_worktree/5` | Main entry — `:ok` or `{:fallback, reason}`. |
| `flag/0` | Persistent-term flag (`:not_set`/`:enabled`/`:disabled`). |
| `enable/0`, `disable/0` | Set the persistent-term flag. |

**Algorithm**: resolve source HEAD → dirty files in source working tree → changed files between source and target commits → all target tree files → shared files (identical + not dirty) → `git worktree add --no-checkout` → copy shared files via batched `cp` (Linux: `--reflink=auto --parents`, ~1000 files/invocation; macOS: `-c` clonefile with pre-created dirs, files grouped by parent dir via `Enum.group_by(&Path.dirname/1)` with ONE `cp -c` per distinct directory; top-level files (`dir == "."`) target the worktree root directly) → checkout remaining files. All steps handle errors gracefully (NO `try/rescue`), cleaning up partial worktrees and disabling the feature on failure. **Gitlink/submodule entries are excluded from the file lists** (`ls_tree_names/2` never returns gitlink paths — a populated submodule checkout is a DIRECTORY; feeding it to `cp` as a file would fail). Submodule paths arrive in the worktree as **empty placeholder dirs** (populate via `git submodule update --init`). `parse_dirty_files/1` parses submodule `git status --porcelain` lines (e.g. ` M vendor/Sub`) with the same path slicing as regular files, so a dirty submodule is excluded from the copy list like any other dirty file.

## Constraints

- One adapter module per external tool; each file must follow the `EvoGit.Adapters.<Tool>` naming pattern.
- All external command invocation must go through `run/2` (or equivalent `System.cmd` wrappers) to keep error handling consistent.
- Functions must never raise on CLI failures — always tagged tuples. Uniform error shape: `{:error, {tag, output}}` (see return contract above).
- No business logic belongs here; adapters are thin wrappers translating CLI I/O into Elixir data structures.
- No `try/rescue` — errors are returned as tagged tuples, never rescued/swallowed.
- **CowWorktree** is an exception to the "thin wrapper" rule — it orchestrates a multi-step optimization, but follows the no-`try/rescue` convention and uses non-crashing variants (`File.mkdir_p/1`, `case`/`with` for error propagation).
