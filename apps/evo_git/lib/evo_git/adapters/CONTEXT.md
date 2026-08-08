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
| **Merge** | `merge/2`, `merge_no_commit/2`, `merge_octopus/2`, `merge_base/3` — the three merge variants are thin wrappers over one private `do_merge/2` that goes through `run/2` (no raw `System.cmd` copy-paste) |
| **Status / query** | `conflict_files/1`, `status/1`, `rev_parse/2`, `check_ignore/2` |
| **Tree listing** | `ls_tree_names/2` — recursive file list in a git tree |
| **History** | `log/2`, `file_history/3`, `show/2` |
| **Diff** | `diff/4`, `file_diff/5`, `diff_stat/3`, `diff_numstat/3`, `diff_name_only/3` — changed file paths between two commits |
| **Notes** | `add_note/4`, `remove_note/3`, `show_note/3`, `get_note/4`, `list_notes/2` |
| **Tags** | `tag/3`, `delete_tag/2` |
| **Branches** | `create_branch/3`, `current_branch/1`, `list_branches/1`, `list_branches/2`, `branch_exists?/2`, `delete_branch/2` |
| **Init** | `init/1` |
| **GitHub** | `gh_available?/0`, `create_pull_request/5`, `create_origin_remote/1`, `origin_default_branch/1`, `has_origin_remote?/1` |

**Return convention (uniform, single documented shape):**
Every function returns `{:ok, value}` on success or `{:error, {tag, output}}` on failure, where `output` is a trimmed `String.t` and `tag` is:

| Tag | Meaning |
|-----|---------|
| `code :: integer` | git CLI exited with that non-zero status (other than the conflict case below) |
| `:conflict` | git exited 1 in a merge-style conflict (or any other exit-1 command) |
| `:enoent` | the repository path does not exist (`run/2` pre-check) |
| `:no_note` | `git notes show` found no note for the object (`get_note/4`) |
| `:invalid_json` | the note content is not valid JSON metadata (`get_note/4`) |

This aligns the adapter with `EvoGit.Review`, which normalizes adapter errors to exactly this `{tag, output}` form internally (review.ex:380-381, 460-461).

**Documented exceptions** (deliberately NOT part of the uniform contract):
- Predicates `branch_exists?/2`, `gh_available?/0`, `branch_has_unique_commits?/3`, `has_origin_remote?/1` return booleans (consumed in boolean contexts, e.g. review.ex:347 `Enum.find(..., &Git.branch_exists?/2)`, pull_request.ex:20-22).
- `origin_default_branch/1` always returns `{:ok, branch}` with a `"main"` fallback (pull_request.ex:26-28 pattern-matches only `{:ok, branch}`; origin/HEAD is frequently unset — deliberate).
- `commit/2` treats "nothing to commit, working tree clean" (exit 1) as success `{:ok, _}`.

Notes on specific functions:
- `ls_tree_names/2`, `diff_name_only/3`, `check_ignore/2`, `list_branches/1`, `list_branches/2` return `{:ok, [files]}` (list, empty on no results) instead of `{:ok, String.t()}`.
- `check_ignore/2`: exit 1 ("no matches") → `{:ok, []}` — a valid result, not an error.
- `list_branches/2` (glob pattern) previously returned a **bare list** (`[]` on error); it now returns `{:ok, names} | {:error, {tag, output}}` like `list_branches/1`.
- `get_note/4` previously returned bare `:error`; it now returns `{:error, {:no_note, output}}` (missing note) / `{:error, {:invalid_json, note_content}}` (unparseable or non-map JSON) / passes through other `{:error, {tag, output}}` (e.g. `:enoent`).
- `merge/2`, `merge_no_commit/2`, `merge_octopus/2` all share one private `do_merge/2` → `run/2`; conflict (exit 1) surfaces as `{:error, {:conflict, output}}`, other exits as `{:error, {code, output}}`.

### `EvoGit.Adapters.CowWorktree` (`cow_worktree.ex`)
CoW (copy-on-write) optimized worktree creation. Instead of extracting every file from the git database, copies unchanged files from a source working tree using `cp` (leveraging filesystem reflink on Linux, clonefile on macOS), then lets git restore only the differing files via a checkout. Designed as an **optimization with graceful fallback** — any failure disables the feature and returns `{:fallback, reason}` so the caller can use the standard worktree method. **Shape-agnostic w.r.t. the Git adapter contract** — its tagged `with` patterns (`{:source_head, {:ok, sha}} <- ...`) and catch-all `error` arms need no changes; its `{:error, code, output}` at cow_worktree.ex:207 comes from its own internal `copy_shared_files` (cp), NOT the Git adapter.

| Function | Description |
|---|---|
| `enabled?/0` | Gate: reads `[:git, :cow_worktree_creation]` config (`:auto`/`:enabled`/`:disabled`). In `:auto`, auto-detects once (non-Windows + `cp` available) and caches via `:persistent_term`. |
| `create_worktree/5` | Main entry — creates a CoW-optimized worktree. Returns `:ok` or `{:fallback, reason}`. |
| `flag/0` | Reads the persistent-term flag (`:not_set`/`:enabled`/`:disabled`). |
| `enable/0`, `disable/0` | Set the persistent-term flag. |

**Algorithm**: resolve source HEAD → get dirty files in source working tree → compute changed files between source and target commits → get all target tree files → compute shared files (identical + not dirty) → create empty worktree (`git worktree add --no-checkout`) → copy shared files via batched `cp` (Linux: `--reflink=auto --parents`; macOS: `-c` with pre-created dirs) → checkout remaining files. All steps handle errors gracefully (NO `try/rescue`), cleaning up partial worktrees and disabling the feature on failure.

## Legacy callers pending update (adapter refactor — follow-up agent)

The adapter was refactored to the uniform `{:ok, value} | {:error, {tag, output}}` contract (commit `8b0854a0`). The following callers still match the OLD shapes (`{:conflict, output}`, `{:error, code, output}` 3-tuples, bare `:error`, bare-list returns). They are READ-ONLY for the adapter owner — a follow-up agent must update them. Compile warnings ("clause will never match") and CaseClauseErrors mark the exact spots.

### lib/ call sites (runtime breaks)
| File:line | Current expected shape | Minimal change |
|---|---|---|
| `lib/evo_git/task.ex:145` | `{:conflict, _}` from `Git.merge/2` (resolve_conflict) | → `{:error, {:conflict, _}}` |
| `lib/evo_git/review.ex:68, 248` | `{:error, _, _}` from `Git.log/2` (list_commits/list_commits_from_shas) | → `{:error, {_, _}}` (keep `-> {:ok, []}` semantics) |
| `lib/evo_git/review.ex:331, 335, 425, 441` | `normalize_git_error/1` receives `{:error, {code, output}}` | `normalize_git_error({:error, {code, output}}) -> {:error, {code, output}}`; delete the `{:conflict, output}` clause (unreachable) and the `{:error, code, output}` clause |
| `lib/evo_git/review.ex:377-382, 400-421` | `{:conflict, details}` / `{:error, code, output}` from `Git.merge/2` (merge_into_current/merge_into_other) | match `{:error, {:conflict, details}}` / `{:error, {code, output}}`; keep Review's public `{:conflict, details} \| {:error, {code, output}}` contract unchanged |
| `lib/evo_git/review.ex:470` | `{:error, code, output}` from `Git.delete_branch/2` (reject_branch) | → `{:error, {code, output}}` |
| `lib/evo_git/review.ex:362-363, 165, 291` | doc strings "`{:error, code, output}`" | doc-only updates (`{tag, output}`) |
| `lib/evo_git/agent/subagent_processing.ex:475` | `{:conflict, output}` from `Git.merge_octopus/2` | → `{:error, {:conflict, output}}` |
| `lib/evo_git/agent/subagent_processing.ex:505` | `{:error, code, output}` from `Git.merge_octopus/2` | → `{:error, {code, output}}` |
| `lib/evo_git/agent/subagent_processing.ex:538` | `{:error, _code, msg}` from `Git.rev_parse/3` (build_subagent_phylo_node) | → `{:error, {_code, msg}}` |
| `lib/evo_git/agent/tools/shared.ex:439-447` | `{:error, _, _}` / `{:conflict, _}` from `Git.run`/`Git.commit` (do_git_commit) | → `{:error, {_, _}}` / `{:error, {:conflict, _}}` arms |
| `lib/evo_git/agent/tools/complete_task.ex:211-217, 227-233` | `{:error, _, _msg}` / `{:conflict, _msg}` from `Git.add_note/4` (add_metadata_note/handle_fallback) | → `{:error, {:conflict, _msg}}` / `{:error, {_code, msg}}` arms; keep the force-fallback semantics (note-exists → retry with `-f`) |
| `lib/evo_git/agent/tools/complete_task.ex:252-254` | doc says `:error` for `get_agent_metadata/2` (wraps `get_note`) | doc-only: now `{:error, {:no_note, _}}` / `{:error, {:invalid_json, _}}` / `{:error, {:enoent, _}}` |
| `lib/evo_git/agent_scheduler/dispatch.ex:275` | `{:error, _, msg}` from `Git.add_worktree/4` (setup_worktree) | → `{:error, {_, msg}}` (code raises on failure either way) |
| `lib/evo_git/agent/tool_dispatch.ex:62, 75` | `{:error, code, msg}` from `Git.rev_parse/2` (sync_current_commit_after_tools/sync_and_get_current_commit) | → `{:error, {code, msg}}` |
| `lib/evo_git/core/phylo_graph_node.ex:69` | `{:conflict, _output}` from `Git.merge/2` (crossover) | → `{:error, {:conflict, _output}}` |
| `lib/evo_git/core/phylo_graph_node.ex:148` | `{:error, _code, msg}` from `Git.run/2` (list_immediate_children) | → `{:error, {_code, msg}}` |
| `lib/evo_git/runtime/pull_request.ex:40, 44, 57, 62, 66` | `{:error, _code, output}` / `{:conflict, output}` from `Git.push_branch/2` / `Git.create_pull_request/5` | → `{:error, {_code, output}}` / `{:error, {:conflict, output}}` (log-only arms) |
| `lib/evo_git/runtime/pull_request.ex:71` | `{:error, _code, output}` in `with` else (create_remote_repo_and_continue) | → `{:error, {_code, output}}` |
| `lib/evo_git/runtime/pull_request.ex:189` | `{:error, _code, output}` from `Git.create_origin_remote/1` | → `{:error, {_code, output}}` |
| `lib/evo_git/agent_scheduler/worktree_manager.ex:177-180` | `Git.list_branches(repo_root, "evogit-agent-*")` piped into `Enum.each` (bare-list contract) | wrap: `case Git.list_branches(...) do {:ok, branches} -> Enum.each(branches, ...); _ -> :ok end` — runs at WorktreeManager init (worktree_manager.ex:113 `clean_orphaned_branches/1`), will raise `Protocol.UndefinedError` at runtime otherwise |

### Verified FINE (no change needed)
- `review.ex:306` (`{:error, _} = error` — Review's own default_merge_target error), `review.ex:541-543` (resolve_merge_base catch-all `_`), `runner.ex:339-345` (`{:ok, _}` matches only — status errors crashed before too, unchanged), `dispatch.ex:350-361` (with-chain result discarded), `tool_dispatch.ex:744` (catch-all `_ -> []`), `context_node.ex:41` (catch-all `_`), `phylo_graph_node.ex:89` (pass-through `error`), `complete_task.ex:297-298` (update_ref results ignored), `evo_dash review_live.ex:699` (catch-all `_ -> []`).

### Test call sites (will fail until updated)
| Test:line | Current expected shape | Minimal change |
|---|---|---|
| `test/evo_git/adapters/git_test.exs:129` | `assert {:conflict, _} = Git.show_note(...)` | → `{:error, {:conflict, _}}` |
| `test/evo_git/adapters/git_test.exs:170` | `assert :error = Git.get_note(...)` (invalid JSON) | → `{:error, {:invalid_json, _}}` |
| `test/evo_git/adapters/git_test.exs:180` | `assert :error = Git.get_note(...)` (no note) | → `{:error, {:no_note, _}}` |
| `test/evo_git/adapters/git_test.exs:216` | `assert {:error, _, _} = Git.rev_parse(...)` | → `{:error, {_, _}}` |
| `test/evo_git/agent/tools/complete_task_test.exs:273, 342` | `assert :error = Git.get_note(...)` | → `{:error, {:no_note, _}}` |
| `test/evo_git/agent/tools/complete_task_test.exs:407` | `assert :error = CompleteTask.get_agent_metadata(...)` (no note) | → `{:error, {:no_note, _}}` |
| `test/evo_git/agent/tools/complete_task_test.exs:411` | `assert :error = CompleteTask.get_agent_metadata(...)` (nonexistent path) | → `{:error, {:enoent, _}}` |
| `test/evo_git/agent/tools/complete_task_test.exs:528-529` | `assert {:error, _, _} = Git.rev_parse(...)` (archive refs absent) | → `{:error, {_, _}}` |
| `test/evo_git/agent/tools/complete_task_test.exs:718, 753` | CaseClauseError — `CompleteTask.complete` → `add_metadata_note` (complete_task.ex:206) on note-exists conflict | fix complete_task.ex arms (see above) |
| `test/evo_git/review_test.exs:384` | CaseClauseError — `Review.merge_branch/3` → `merge_into_other` (review.ex:391) on `Git.merge` conflict | fix review.ex arms; Review public contract `{:conflict, details}` unchanged |
| `test/evo_git/core/phylo_graph_node_test.exs:77` | CaseClauseError — `PhyloGraphNode.crossover/2` (phylo_graph_node.ex:69) on `Git.merge` conflict | fix phylo_graph_node.ex:69 arm; PhyloGraphNode contract `{:conflict, node, files}` unchanged |

## Constraints

- One adapter module per external tool; each file in this directory must follow the `EvoGit.Adapters.<Tool>` naming pattern.
- All external command invocation must go through `run/2` (or equivalent `System.cmd` wrappers) to keep error handling consistent.
- Functions must never raise on CLI failures — they always return tagged tuples. Uniform error shape: `{:error, {tag, output}}` (see return contract above).
- No business logic belongs here; adapters are thin wrappers that translate CLI I/O into Elixir data structures.
- No `try/rescue` — errors are returned as tagged tuples, never rescued/swallowed.
- **CowWorktree** is an exception to the "thin wrapper" rule — it orchestrates a multi-step optimization, but follows the no-`try/rescue` convention and uses non-crashing variants (`File.mkdir_p/1`, `case`/`with` for error propagation).
