# Runtime

## Intent
Execution engine for the runtime phases: **Genesis** (create a new codebase, or analyze an existing one), **Evolution** (iterative modification), repo-less **SelfReflective**, and post-PR **SkillExtraction**.
A shared `PullRequest` module offers optional PR creation.
There is NO centralized `EvoGit.Runtime.Prompts` module — prompt text lives in agent `system_prompt/0` callbacks and inline strings.

## Routing Table
None — leaf directory.
Modules: `../runtime.ex` (`EvoGit.Runtime`), `helpers.ex`, `genesis.ex`, `evolution.ex`, `pull_request.ex`, `worktree_init_script.ex`, `skill_extraction.ex`, `self_reflective.ex`.

## API Surface

### Modules

| Module | File | Public API | Role |
|--------|------|------------|------|
| `EvoGit.Runtime` | `../runtime.ex` | `ensure_repo/1` | Raises the UNC diagnostic, then `git init` + `/.genesis` `.gitignore` + initial commit when `<repo>/.git` is missing. Phases are invoked by `TaskExecutor.execute_task/3` (CLI/dashboard/shell all enqueue via `TaskRegistry.start_task/2`); there is no combined orchestration entry point. |
| `EvoGit.Runtime.Helpers` | `helpers.ex` | `merge_and_report/4` (3-arity delegates with `foreign_repos: []`), `resolve_starting_commit/2`, `resolve_foreign_repo_starting_commit/2`, `format_invalid_starting_commit_error/3`, `notify_finalizing/1`, `generate_branch_name/1`, `new_codebase?/1`, `validate_node_path/2`, `validate_repo_path!/1`, `load_foreign_repos/2`, `merge_foreign_repos/2`, `load_repo_notes/2`, `resolve_root_agent/2`, `model_id_locked?/1`, `build_root_agent_spec/7` | Shared phase helpers — branch creation, change detection, node-path/repo-path validation, starting-commit resolution, foreign-repo loading + up-front validation, repo-notes rendering, root-agent spec building. |
| `EvoGit.Runtime.Genesis` | `genesis.ex` | `run/2` | Creation/Analysis; mode auto-detected. `{:ok, %{commit_sha, result, tag, branch_name, pr_url, pr_title, usage, agent_count, repos}}` or `{:ok, %{..., no_changes: true}}`, else `{:error, reason}`. |
| `EvoGit.Runtime.Evolution` | `evolution.ex` | `run/2`, `mode_atom/1` (`@doc false` test wrapper) | Evolutionary loop; modes `:simple`/`:custom`; same return shape as Genesis. |
| `EvoGit.Runtime.PullRequest` | `pull_request.ex` | `try_create/4`, `generate_title/2`, `format_body/2` | LLM title generation, body formatting, push + PR via `gh`. `try_create/4` returns `{pr_url, pr_title}` or `{nil, nil}`, never raises. |
| `EvoGit.Runtime.WorktreeInitScript` | `worktree_init_script.ex` | `build_systems/0`, `get_build_system/1`, `scripts_for/1` | Per-build-system catalog (Elixir, Node.js, Python, Rust, Go, None): a unix (bash) + windows (PowerShell) script copying deps/build artifacts from the source repo into new worktrees, preserving source mtimes so Mix `_build`/Cargo/npm caches stay warm — Linux `cp -R --preserve=timestamps --reflink=auto` (narrow `--preserve=timestamps`, so a failed chown cannot fail the copy), macOS `cp -cRp`, Windows `Copy-Item -Recurse -Force`. Genesis Mode B writes the selected scripts to `genesis.toml` as `script.linux`/`script.macos`/`script.windows`. |
| `EvoGit.Runtime.SkillExtraction` | `skill_extraction.ex` | `run/1` | Distills a completed PR's changes into EvoGit skills (`.agents/skills/`): takes a PR-context keyword list (title, objective, summary, commit history, base_sha, commit_sha, user_note), builds the objective, spawns a `SkillExtractor` agent. |
| `EvoGit.Runtime.SelfReflective` | `self_reflective.ex` | `run/1`, `run/2`, `source_root/0`, `build_spec/2` | Repo-less chatbot-style introspection. `source_root/0` delegates to `EvoGit.SelfReflectiveSource.reference_path/0` (`:self_reflective_source_root` app env → `GENESIS_SOURCE_ROOT` → valid managed clone at `<data_dir>/genesis-source`) with terminal fallback `File.cwd!()` — the same chain as `Dispatch.resolve_repo_less_root/0`. `run/2` builds a repo-less spec (phylo nil; context node over the source root when it is a real dir, else bare `%ContextNode{}` with `"[system]"` placeholder repo), spawns `EvoGit.Agents.SelfReflective` via `run_agent/1`, returns `{:ok, %{result: ..., commit_sha: nil, branch_name: nil, tag: nil}}` — no git ops, no `merge_and_report`, no PR. `build_spec/2` is a test seam (`spec.opts[:repo_less] == true`; `:objective`/`:source_root`/`:node_path` are dropped, `repo_less: true` is put last so it always wins). |

### `Genesis.run/2` — Steps

1. `repo_path` = `opts[:repo_path]` (default `File.cwd!()`) through `EvoGit.Platform.safe_expand/1` (UNC-preserving).
2. `Runtime.ensure_repo/1`, then HEAD via `Helpers.resolve_starting_commit(repo_path, nil)` — Genesis always resolves HEAD and has no `:starting_commit` clause.
3. Mode via private `resolve_mode/2`: explicit `:mode` `:new`/`:existing`, else auto-detect with `Helpers.new_codebase?/1` (files beyond `.git`, `README.md`, `.genesis`, `.gitignore`); `:custom`/`"custom"` raises `ArgumentError` (custom mode is evolve-only).
4. Mode B only: `build_system` opt (CLI `--build-system`) → `WorktreeInitScript.scripts_for/1` → `ProjectConfig.write_worktree_script/2` writes the `script.*` variants; skipped when nil or `:none`. `ensure_worktree_script/3` re-writes them after each root phase if `genesis.toml` was corrupted.
5. `foreign_repos` = `Helpers.load_foreign_repos/2`, threaded into the spec by `build_phase_spec/6` → `build_root_agent_spec/7` (`foreign_repos:` opt); no separate scheduler registration.
6. Dispatch: **Mode A (Existing)** → `ContextExtractor` root (read-only recursive CONTEXT.md tree extraction); **Mode B (New)** → `Architect` root (3 phases: architecture & design → implementation delegation → review & accountability) then a second root `Manager` for implementation.
7. `AgentSpec.new(...)` → `AgentScheduler.run_agent/1` (blocks until complete).
8. Post-processing `merge_and_report/4`: base SHA vs the agent-reported final SHA (`agent_output.commit_sha`, the POST-fallback worktree HEAD). Changed → `genesis/agent_<hex>` branch at the agent commit (reviewable on the dashboard); unchanged → `no_changes: true`.

### `Evolution.run/2` — Steps

1. `mode_atom/1`: `nil`/absent, `:simple`, `"simple"` → `:simple`; `:custom`/`"custom"` → `:custom`; ANY other value → warning + `:simple` fallback.
2. Custom mode requires an `agent:` opt — nil/empty raises `ArgumentError` ("custom mode requires an agent id; pass agent: <id> (defined in agents.toml)") BEFORE any repo/git I/O; unknown ids raise in `Helpers.resolve_root_agent/2`.
3. `repo_path` (safe_expand) → `ensure_repo/1` → `resolve_starting_commit(repo_path, opts[:starting_commit])` → `validate_node_path(node_path, repo_path)` (`node_path` default `"./"`).
4. `run_mode/7` is the ONE shared flow for both modes, parameterized by the default root module: phylo node at the resolved SHA, context node at `node_path`, `load_foreign_repos/2`, `load_repo_notes/2`, `build_root_agent_spec/7` → `run_agent/1` → `notify_finalizing/1` → `merge_and_report(repo_path, output, "evolve", foreign_repos)`.
5. `:simple` root = `Manager` (plans, delegates to Executor/TaskScheduler/Investigator subagents); `:custom` root = `EvoGit.Agents.Custom` bound to the `agent:` id.
6. Errors: `{:error, {:invalid_node_path, msg}}`; invalid starting commit → `{:error, message}` from `format_invalid_starting_commit_error/3`; anything else propagates.

### `starting_commit` Opt — Evolution Only

`TaskRegistry.RuntimeOpts.build_common_runtime_opts/3` passes `:starting_commit` into runtime opts for BOTH `:genesis` and `:evolve`, and the CLI passes it for evolve (`--starting-commit`); only `Evolution.run/2` reads it, so a genesis `:starting_commit` is silently ignored.
Resolution is `Helpers.resolve_starting_commit/2` — the single choke point (`resolve_foreign_repo_starting_commit/2` delegates to it): `nil` → current HEAD via `PhyloGraphNode.current_head/1`; a ref (commit SHA, branch name, lightweight or annotated tag) → `Git.rev_parse` with the `^{commit}` peel suffix, so an annotated tag resolves to its peeled COMMIT SHA (all downstream consumers — worktree add, phylo node, merge_and_report, resume contexts — work on real commit SHAs) and a ref pointing at a non-commit object (tree/blob) is rejected.
A non-existent ref, a non-commit object, or an unborn-HEAD repo yields the structured `{:error, {:invalid_starting_commit, ref, repo_path, git_output}}` — NEVER the raw git `{:error, {code, output}}` tuple — which the genesis/evolution `else` arms turn into a human-readable `{:error, message}` via `format_invalid_starting_commit_error/3`, persisted as the failed-task result.
Resume (`ResumeContext`), merge-auto-resolve (`MergeContext`) and genesis Mode B phase 2 are unaffected — they pass real prior commit SHAs.
**Path to the agent**: resolved SHA → `PhyloGraphNode.new(repo_path, sha)` (both `base_commit`/`current_commit` = SHA) → `AgentSpec.phylo_node` → `run_agent/1` → the worktree is created AT that commit (`Worktrees.create_worktree/6` reads `spec.phylo_node.current_commit`; `assign_and_prepare_worktree/2` rebuilds the worktree-bound phylo node into ETS).
The SHA is NOT injected into prompt text — the agent learns its starting point from the worktree contents (`base_commit`/`current_commit` live only in ETS; Manager's `system_prompt/0` describes them abstractly).

### Genesis Mode B Second Root

The `Manager` second root spawns only after a successful Architect run (`run_implementation_phase/8`); Mode B is gated only by `resolve_mode/2` (explicit `:mode` opt or `Helpers.new_codebase?/1`), with no condition on repo non-emptiness or `starting_commit != base`.
The Manager's phylo node starts at the architect's final commit (`architect_output.commit_sha || base_sha`).
Both roots share ONE `task_id` (generated with `:crypto.strong_rand_bytes(8)` when absent), and the scheduler's cancel guard refuses the second root while the task is cancelling.
Implementation-phase failure merges the architect's output as partial success, and `notify_finalizing/1` fires on that arm too.
`:attachments` are forwarded verbatim to the phase-2 Manager (the shared runtime `opts` go through `build_phase_spec/6` → `build_root_agent_spec/7`), so both sequential roots may use the initial media — no per-phase stripping or extra plumbing.

### Prompt / Objective Assembly — No Cross-Agent File Hand-Off

Runtime phases never pass file locations between agents; hand-off is text + a commit SHA only.

- `:objective` reaches the root agent's FIRST user message **verbatim**: passed as the 4th positional arg of `AgentSpec.new/5` → `AgentSpec.objective` → scheduler → the Runner wraps it in `<objective>…</objective>`. Only blank→`""` normalization — no truncation or reformatting; any absolute path inside an objective comes from the CALLER, not prompt assembly.
- **Genesis Mode B (Architect → Manager) hand-off is TEXT ONLY**: `impl_objective` interpolates the ORIGINAL objective plus `architect_output.result` (the architect's report STRING); the Manager starts from `architect_commit` (a SHA). No scratch/artifact file is written by the architect or read by the Manager.
- This directory embeds NO absolute filesystem path into any prompt; the only interpolations are the objective text, the architect report string, commit SHAs (`git diff <base_sha> <commit_sha>` in the skill-extraction objective), and RELATIVE gitlink paths (`render_repo_notes/1`). No `/tmp`/`$TMPDIR` scratch-file instruction exists here.
- Absolute paths DO reach prompts, but from the AGENT layer: non-primary foreign-repo ROOT paths via `ContextBuilder.build_foreign_repos_section/1`, and the agent's own worktree path via `ContextNode.build_context/2`'s `location_info` block. Detail: `../agent/CONTEXT.md` + `../core/CONTEXT.md`.
- `PullRequest.generate_title_with_llm/3` embeds the objective + a 2000-char slice of the agent result into a PR-TITLE prompt — a post-phase utility, not an agent hand-off.
- **Repo notes**: `load_repo_notes/2` renders the git-submodules note block (via `render_repo_notes/1` from `Git.ls_tree_gitlinks`; `nil` when there are no gitlinks or detection fails — graceful, no `try/rescue`); root spec builders pass it as `AgentSpec` `repo_notes:` → `ContextBuilder.build_repo_notes_section/1`, and subagents inherit it.

### `merge_and_report/4` Never Merges

`merge_and_report/4` only `rev_parse`s HEAD and calls `Git.create_branch(repo_path, branch_name, final_sha)` — for the primary repo AND each WRITABLE foreign repo that produced commits (ONE branch name across repos; NEVER merged into any default branch).
`final_sha` is `agent_output.commit_sha`, the POST-fallback worktree HEAD, because the Runner's `after` auto-commit fallback (`Dispatch.commit_pending_in_worktree/0`) runs BEFORE the agent result is returned and the runner then re-reads the worktree HEAD.
A change committed ONLY by that fallback therefore still differs from the repo root's live HEAD and produces a real `genesis/agent_<hex>` branch (reviewable/mergeable on the dashboard) instead of `no_changes: true` / `branch_name: nil` — those outcomes apply only when the POST-fallback `final_sha` equals the repo root HEAD.
The agent commit is NOT merged into any target branch and no PR is created here; there is no conflict path in the phases.
Real branch merging with conflict reporting lives in `EvoGit.Review.merge_branch/2,3` (dashboard review flow → `{:conflict, details}`).

### Per-Repo Branches & the `repos` Report Key

`merge_and_report/4` (3-arity `merge_and_report/3` delegates with `foreign_repos: []`) reports the PRIMARY repo in the top-level keys (see "Finalization report" below) and adds the top-level `repos` key consumed by the dashboard review workstream.

- **Shape**: `repos` is a map `repo_id (String) => %{commit_sha: String.t(), branch_name: String.t() | nil}` — plain maps only, no structs inside (must survive JSON). The repo-id KEYS are strings (`ForeignRepo.primary_id()` = `"primary"`, else the foreign `repo.id`); the INNER keys are ATOMS in memory (`%{commit_sha:, branch_name:}`) and become strings only after the Codec/JSON round trip. The `"primary"` entry is ALWAYS present (commit_sha = the top-level `commit_sha`, branch_name = the primary branch or nil when no changes/no primary branch); each WRITABLE foreign repo that got a branch appears under its string id; READ-ONLY foreign repos produce NO entries.
- **One branch name per task**: `generate_branch_name/1` is called ONCE per `merge_and_report` call and the resulting `genesis/agent_<hex>` name is REUSED for the primary AND every writable foreign repo with commits → uniform dashboard merge/reject broadcast. In the no-changes / rev_parse-error paths the primary keeps `branch_name: nil` while foreign branches are still created (a name is generated only when foreign commits exist).
- **Per-repo data source**: `result.foreign_repo_commits`, a map `repo_id => latest commit SHA in that repo`; it IS a field of `%EvoGit.Agent.Result{}` (default `%{}`, still read defensively via `Map.get(result, :foreign_repo_commits, %{})` — Mode B merges the two maps into a plain map). Entries are matched against the `foreign_repos` list (4th arg): only `writable: true` repos WITH a binary tracked SHA are processed; unknown/read-only/sha-less ids → no entry; branch-creation failure → `Logger.error` + entry kept with `branch_name: nil` (same tolerance as the primary path).
- **Codec round trip**: `repos` is NOT in `EvoGit.Store.Codec.@result_data_fields`, so after `encode_result`/`decode_result` the top-level key stays the STRING `"repos"` and its inner maps are string-keyed (Jason stringifies atom keys) — consumers read `Map.get(decoded, "repos")` with string keys.
- **Per-repo starting commits**: `resolve_foreign_repo_starting_commit(entry, repo_root)` → `{:ok, sha}`: a set `base_sha` resolves via the `^{commit}` peel (guaranteed resolvable by the up-front validation), a `nil` `base_sha` resolves the foreign repo's HEAD via `PhyloGraphNode.current_head/1`; a non-resolving `base_sha` or an unborn foreign HEAD yields the structured `{:error, {:invalid_starting_commit, ref, repo_root, git_output}}`.
- **Up-front validation in `load_foreign_repos/2`**: after merging TOML + CLI repos, EVERY entry is validated in the task process before any agent spawns (spec-error style, no `try/rescue`): the path must exist AND be a git repo (`Git.rev_parse(root)` succeeds) and a non-nil `base_sha` must resolve (`Git.rev_parse(root, base_sha)`). The UNC guard runs first per repo (`validate_repo_path!/1`). Failure raises `ArgumentError` naming the repo id, path and problem — e.g. `"Foreign repo '<id>' at '<root>' is not a valid git repository: <inspect(reason)>"` / `"…: base_sha '<sha>' does not resolve in the repository (<inspect(reason)>)"`. `merge_foreign_repos/2` (resume/review paths) stays lenient (no validation) and normalizes BOTH lists via `ForeignRepo.normalize/1` before dedup-by-id with CLI precedence (entries may be `%ForeignRepo{}` structs, atom-keyed or string-keyed maps; unparseable entries dropped; raw dot-access on map entries raises `KeyError`).
- **Persistent read-view worktrees**: after validation, `load_foreign_repos/2` provisions/resets the PERSISTENT worktree of every WRITABLE non-primary repo (`AgentScheduler.ForeignWorktree.ensure_all/1`, best-effort — warning-logged, never raises) at `<root>/.genesis/foreign_repos/<id>` (`ForeignRepo.worktree_path/1`), so agents can read the foreign code through that path for the whole task. Detail: `../agent_scheduler/CONTEXT.md`.

### Known Issue — CompleteTask Note & Archive Refs Lag the Reported `commit_sha`

`EvoGit.Agent.Tools.CompleteTask.complete/4` writes its git note (`refs/notes/evogit`, `add_metadata_note/3`) and — when `archive` is enabled — its archive refs (`refs/genesis/archive/T<task>-A<local>-start` at `base_commit`, `-final` at the SHA it was handed) at COMPLETE time, from the pre-fallback `commit_sha` resolved by `sync_and_get_current_commit/1`.
For a commit produced ONLY by the agent-exit auto-commit fallback those refs point at the PRE-fallback SHA, lagging the `commit_sha` `merge_and_report/4` reports by one commit.
Acceptable: the change itself is reviewable/mergeable via the `genesis/agent_<hex>` branch — only the note and archive-ref metadata can reference the pre-fallback commit.
Archive ownership: each completing agent writes its OWN `task_agent_archives` row (plus those refs); nothing archive-related is combined across agents or carried in `%Result{}`/the report, and nothing is compressed. Detail: `../agent/CONTEXT.md` + `../store/CONTEXT.md`.

### Known Issue — Foreign-Repo Starting-Commit Staleness & Report Last-Writer-Wins

Every foreign-repo spawn resolves its starting commit with the precedence: task-level `repo_entry.base_sha` (when non-nil) → the SPAWNING agent's OWN `foreign_repo_commits` map → the foreign repo's HEAD (`SubagentProcessing.resolve_foreign_phylo_commit/4`).
The tracked-commit map is read from the spawning agent's own SchedMeta row (`AgentScheduler.get_foreign_repo_commits/1`), so it is **per-agent**: a DIFFERENT agent (another subtree, or Genesis Mode B's second root) sees `%{}` and falls back to `base_sha` / foreign HEAD — an OLD commit. A non-nil task-level `base_sha` wins UNCONDITIONALLY, so even the SAME agent's later foreign spawns start from the fixed `base_sha`, never from a previously tracked advanced commit.
Writable foreign spawns are gated ROOT-ONLY (`parent.depth == 0`) + one-per-batch (`{:error, {:foreign_repo_write_not_root, msg}}`), so the literal "sibling branches over the advanced commit" topology is blocked.
Reachable stale-start paths: (a) Genesis Mode B's TWO sequential roots (both depth 0, independent maps) — the runtime merges the two `foreign_repo_commits` maps MANAGER-WINS, so the created `genesis/agent_<hex>` branch carries only the manager's lineage; (b) any task whose foreign entry sets an explicit `base_sha`; (c) a write-capable Manager spawned INTO the foreign repo and its CROSS-repo children in a DIFFERENT repo — such a child starts at `base_sha`/that repo's tracked commit/HEAD, and the parent's own `commit_sha` then OVERWRITES the tracked sha for that repo id (`Subagents.roll_up_foreign_repo_commits/3`). The Manager's OWN same-repo children (relative path, or absolute back into the parent's repo) DO inherit the parent's `current_commit` and ARE merged into its worktree (`collect_mergeable_results/3` merges when `spec.repo_id == parent_repo_id`).
The report takes exactly ONE sha per repo id (`Map.get(commits, repo.id)`), so when two foreign commits exist for the same id the LAST writer wins and the earlier lineage is absent from the branch; that earlier commit survives only as a dangling object, because each agent's per-agent branch `evogit-agent-T<task>-A<local>` is DELETED on agent exit for PRIMARY AND FOREIGN repos (`WorktreeManager` destroy).
**No branch clobber is possible**: `Git.create_branch/3` is non-force (`git branch <name> <sha>`) — an existing same-named ref fails with `{:error, {128, ...}}` and is never reset — and the task branch name is a fresh random `genesis/agent_<hex>` per call; nothing in the runtime does `update-ref`/`branch -f`/`reset` on a `genesis/agent_*` branch.
Branch-creation failure is tolerated SILENTLY: the entry keeps its `commit_sha` with `branch_name: nil`, which makes the dashboard merge/reject unavailable for that repo (`EvoGit.Review.merge_branch/3` → `{:error, :no_branch}`).
`PullRequest.try_create/4` contains no merge path — it only pushes a branch and opens a PR, and the runtime phases never call it (caller: `EvoGit.Review.create_github_pr`).

### `PullRequest.try_create/4` — Steps

1. `Git.gh_available?/0` check (absent → `{nil, nil}`).
2. `Git.has_origin_remote?/1`; if none, `Git.create_origin_remote/1`.
3. Base branch from `Git.origin_default_branch/1`; its push failure is only logged.
4. `build_title/3` → optional LLM streaming title via `generate_title/2`/`generate_title_with_llm/3`, falling back to `"Genesis: <head_branch>"`.
5. `format_body/2` — header `## 🤖 Auto-generated by Genesis` + `@username` + the agent result.
6. `Git.push_branch/2` → `Git.create_pull_request/5`.
7. Returns `{pr_url, pr_title}`, or `{nil, nil}` on any failure (never raises).

## Constraints

- Both phases: ensure repo → create phylo node → load context node → foreign repos + repo notes → root spec → run agent → `notify_finalizing/1` → `merge_and_report`.
- Agent changes go to **isolated branches** (`genesis/agent_<hex>`), never the working tree; PR creation is optional (requires `gh`).
- `merge_and_report/3` is shared via `EvoGit.Runtime.Helpers` with phase `"genesis"`, `"evolve"` or `"skill"`; the phase is used ONLY for `String.capitalize/1` log prefixes — `generate_branch_name/1` ignores its argument (`def generate_branch_name(_prefix)`) and always yields `"genesis/agent_" <> 8 lowercase hex`, so evolve and skill-extraction branches are ALSO `genesis/agent_*`.
- No centralized `prompts.ex` — all prompt text lives in agent modules' `system_prompt/0` callbacks.
- No `try/rescue` in this directory (spec errors raise; conditions use `with`/`case`/`cond`).
- PR creation is best-effort and never fails the phase — errors log and return `nil`s.
- Evolution `node_path` must be RELATIVE and have a `CONTEXT.md` at the target directory (root `"./"` always passes).

### Task Lifecycle Boundary — Entry Opts, Finalization Report, Disk Ownership

The runtime phases are pure executors run by `TaskRegistry.TaskExecutor` inside a spawned `Task.Supervisor` process; they own NO task-level scratch/directory lifecycle.
Every directory on disk belongs either to the repo (`repo_path`) or to the AgentScheduler's WorktreeManager.

- **Entry points**: `Genesis.run(objective, opts \\ [])`, `Evolution.run(objective, opts \\ [])`, `SelfReflective.run/1,2`, `SkillExtraction.run(opts \\ [])`; no `Prompts` module.
- **Genesis/Evolve opts** are built by `TaskRegistry.RuntimeOpts.build_common_runtime_opts/3`: `repo_path:` = `Keyword.fetch!(opts, :path)` (ABSOLUTE, resolved pre-enqueue), `mode:` atom, `task_id:`, plus put-if-present `node_path`/`starting_commit`/`foreign_repos`/`archive`/`model_id`/`agent`/`model_id_locked`/`build_system`/`attachments` (Genesis ignores `:starting_commit`). `SelfReflective.run/2` gets the RAW task opts + `task_id:` — deliberately no `build_common_runtime_opts`, which would `KeyError` without `:path`. `SkillExtraction` gets `[repo_path, task_id]` + PR-context keys. Detail: `../task_registry/CONTEXT.md`.
- **Return shapes**: Genesis/Evolution/SkillExtraction → `{:ok, report_map}` on success, else `{:error, reason}` (`{:error, message}` for an invalid starting commit; `{:error, {:invalid_node_path, msg}}` for evolution). SelfReflective → `{:ok, %{result:, commit_sha: nil, branch_name: nil, tag: nil}}` | `{:error, reason}`, and NEVER calls `merge_and_report`. TaskRegistry maps any non-`{:ok, _}` to `:failed`.
- **Finalization report**: `Helpers.merge_and_report/3,4` → private `report_map/5` = `%{commit_sha, result, tag, branch_name, pr_url: nil, pr_title: nil, usage, agent_count, repos: %{...}}` (+ `no_changes: true` when the POST-fallback `final_sha` == the repo root HEAD SHA); `repos` maps every STRING repo id (`"primary"` always present) to `%{commit_sha, branch_name}`. `pr_url`/`pr_title` are ALWAYS nil here — PR creation is `PullRequest.try_create/4`, called only from `EvoGit.Review`, never by the phases.
- **`notify_finalizing/1`** (`nil` → `:ok`) is called IMMEDIATELY BEFORE `merge_and_report/4` at every success site: Mode A success, Mode B implementation success, Mode B partial-success error arm, evolution, skill extraction. Mode B reads its shared `task_id`; Mode A / Evolution read `Keyword.get(opts, :task_id)` at those call sites only. No `:finalizing` broadcast on the reflect path.
- **Disk ownership**: the phases create NO task scratch dirs and never touch `EvoGit.Platform.data_dir/0` or system tmp (zero `data_dir`/`System.tmp_dir` references under `runtime/`). The only filesystem writes are `ensure_repo/1` (repo dir + `.git` + a `/.genesis` `.gitignore` when `<repo>/.git` is absent), `ProjectConfig.write_worktree_script/2` writing `genesis.toml` INSIDE the repo, and `Git.create_branch/3` refs inside the repo's `.git` (primary + each writable foreign repo). `usage`/`agent_count` are produced by the AGENTS (scheduler/tools) and merely passed through; per-agent archives are persisted by the agents themselves and never ride the report. Agent worktrees are created/reclaimed ENTIRELY by the AgentScheduler (`WorktreeManager.create_worktree_for_agent/6` + `:DOWN` reclaim) — the runtime hands over only `repo_path` via `PhyloGraphNode.new(repo_path, sha)` / `ContextNode.load/2` and never sees a worktree path.

### Task Status & Event Emission (Dashboard Contract)

- **PubSub topic `"tasks"`**: the ONLY runtime-phase emitter is `Helpers.notify_finalizing/1`, broadcasting `{:task_updated, task_id, :finalizing, node()}` immediately after `AgentScheduler.run_agent/1` returns and BEFORE `merge_and_report/4`. No `task_id` → no-op (every task entry point goes through `TaskExecutor.execute_task/3`, which always passes one; the phases' own `Keyword.get(opts, :task_id)` reads keep direct API calls working). No `:failed`/`:completed`/`:running` is EVER broadcast on `"tasks"` from these modules — the full status set (`:running`, `:cancelling`, `:completed`, `:failed`, `:cancelled`, `:finalizing`, plus `nil` for review-status/metadata mutations and `{:task_deleted, task_id, node}`) is emitted by `EvoGit.TaskRegistry` (`../task_registry/CONTEXT.md`). `AgentScheduler.PubSub` topics are different: `"agents"` → `{:agent_registered|:agent_updated|:agent_removed, ..., node}` + `{:agents_updated, node}`; `"scheduler_config"` → `{:scheduler_config_updated, node}`.
- **Task monitor exit** (`Task.Supervisor.async_nolink` in `EvoGit.TaskRegistry`): any non-`{:ok, _}` runtime-process result (incl. `{:error, _}`) maps to `:failed`.
- **Finalizing window** (between the broadcast and the phase return) contains ONLY the broadcast, (Mode B success) the in-memory `Usage.add`/result merging, and `merge_and_report/4`'s git calls. The broadcast is a fire-and-forget `Phoenix.PubSub.broadcast/3` (async cast, never waits for subscribers), so a long dwell at `:finalizing` is ENTIRELY the subsequent in-process work — `Git.rev_parse` (plain `git rev-parse HEAD`, no `--verify`) and one `Git.create_branch` per repo with commits (primary + writable foreign repos), all via `Git.run/2` → raw `System.cmd` with **NO timeout (`:infinity`)**, so they can block indefinitely on a slow filesystem (e.g. an NFS-mounted home on a remote daemon).
- **Per-step visibility logging**: `merge_and_report/4` brackets every blocking git op in the window with `Logger.info` — `"<Phase>: Finalizing repo '<path>': resolving HEAD"` before `rev_parse`, `"<Phase>: Creating branch '<name>' at <sha7>"` before the primary `create_branch` (with `"<Phase>: Created branch ..."` right after success), and `"Creating/Created branch '<name>' in foreign repo '<id>' at '<root>'"` around each writable foreign-repo branch. A hung op leaves the last-issued line naming the exact stuck step. The git adapter itself has ZERO `Logger` usage by design; git timeouts are out of scope.
- `merge_and_report/4` NEVER raises and ALWAYS returns `{:ok, map}`. Worktree cleanup is NOT in the window — `WorktreeManager` reclaims and destroys on agent exit (`:DOWN`: `File.rm_rf` → `Git.prune_worktrees` → `Git.delete_branch`), asynchronously.
- **Critical implication**: every runtime entry point returns whatever `run_agent/1` returns on the error arm, so `{:error, _}` reaches the dashboard and marks the task `:failed` — `{:error, :agent_max_retries_exceeded}` (crashed `agent_max_retries` times), `{:error, :cancelled}`, and graceful `{:error, :recovery_failed}` / `{:error, :path_not_exist}` (the wrapper Task exits `:normal` but the result is non-`{:ok, _}`). Detail: `../agent_scheduler/CONTEXT.md`.

### ETS Table Ownership & Crash Resilience

- The two scheduler ETS tables (`:evogit_agent_state`, `:evogit_sched_meta`) are created in `EvoGit.Application.start/2` via the idempotent `ensure_ets_table/2`, owned by the long-lived application process, so they survive an `AgentScheduler` crash/restart; `AgentScheduler.init/1` only warns if a table is missing.
- `EvoGit.AgentGroupSupervisor` is `strategy: :one_for_all` over `EvoGit.TaskSupervisor` + `EvoGit.AgentScheduler` — a scheduler crash kills/restarts the TaskSupervisor, tearing down ALL running agent Tasks (no orphaned agents). Agent Tasks are spawned via `Task.Supervisor.async_nolink/4` (monitored by the scheduler, not linked to the wrapper). Detail: `../agent_scheduler/CONTEXT.md`.
- Foreign repos are loaded + validated up front (`Helpers.load_foreign_repos/2`) and carried on the root AgentSpec via the `foreign_repos:` opt (`build_root_agent_spec/7`) — the scheduler derives each agent's repo role from that list; the phases never call `AgentScheduler.register_foreign_repo`.
- **`ForeignRepo.root` is the single knob the agent layer uses to locate a foreign repo**: the runtime phase code never computes a foreign worktree path, it merely threads the validated `%ForeignRepo{}` list. Downstream, `Dispatch.resolve_agent_repo_root/2` finds the entry by `spec.foreign_repos` id and reads `.root`; foreign agents then get the SAME transient per-agent worktrees under `<foreign_root>/.genesis/workers/worker_T<task>_A<local>` as the primary, destroyed on agent exit — the persistent read-view worktree (`<root>/.genesis/foreign_repos/<id>`) is a separate, task-lifetime directory.

## Agent Spawning & Coordination

### How Agents Are Spawned

Both phases build an `AgentSpec` and call `AgentScheduler.run_agent/1` (synchronous GenServer call blocking until the agent completes):

```
AgentSpec.new(context_node, phylo_node, agent_module, objective, opts)
|> AgentScheduler.run_agent()
```

The scheduler: 1) assigns a unique `task_id` (GUID), `task_number` (short integer), `agent_id` (`T<task_number>_A<task_local_id>`); 2) computes the worktree path (`worker_T<task_number>_A<task_local_id>`) into sched_meta — **no worktree I/O here**; 3) stores initial state in `:evogit_agent_state` (agent-owned) + `:evogit_sched_meta` (scheduler-owned); 4) spawns a Task running the agent loop; 5) inside the Task, `Runner.setup_dispatch_context/1` requests a FRESH worktree from `WorktreeManager.create_worktree_for_agent/6` (waits indefinitely — no call timeout; lazy per-repo init + the create pipeline — `git clean`/checkout/init script — is offloaded inside WorktreeManager); 6) on `complete_task`/crash/cancel → WorktreeManager reclaims the worktree via its `:DOWN` process monitor and the scheduler replies to the caller.

### Root-Agent Spec Builder (`Helpers.build_root_agent_spec/7`)

`Helpers.build_root_agent_spec/7` is the shared builder producing the root `AgentSpec` for evolution (simple AND custom) and the genesis phase roots.
It resolves the default/custom root module via `resolve_root_agent/2` → `{module, opts}` (unknown ids raise `ArgumentError`) and threads `foreign_repos`, `repo_notes`, `archive`, `task_id`, `model_id`, `model_id_locked` (`model_id_locked?/1` = explicit lock OR a non-nil `model_id`), `quality_level` (absent → `nil`; subagent spec builders never carry the key, so subagent prompts stay unaffected) and `:attachments` (omit-when-nil, so no-attachment specs stay byte-identical), then appends the resolved custom-agent opts.
New code constructing a root-agent spec should reuse it instead of hand-assembling specs at call sites.

### Agent Hierarchy by Phase

- **Genesis Mode A (Existing)**: `ContextExtractor` root → recursive `subagent_context_extractor` children (one per child dir).
- **Genesis Mode B (New)**: `Architect` root (optional `subagent_genesis_planner` for large-scale planning, `subagent_executor` for design artifacts — CONTEXT.md/init commands/directories/API stubs, recursive `subagent_architect` + `subagent_executor` per child dir, `subagent_manager` for implementation delegation) → then `Manager` root (implementation) → `subagent_executor`/`subagent_manager` subtrees. TWO sequential root agents share a `task_id`.
- **Evolution Simple Mode**: `Manager` (target node) → `subagent_task_scheduler` (complex objectives), `subagent_investigator` (exploration), `subagent_executor` (code changes), `subagent_manager` (child-node delegation).
- **Evolution Custom Mode**: `EvoGit.Agents.Custom` root (resolved from agents.toml via the `agent:` opt) → subagent modules declared in the custom agent definition. Custom agents are ROOT-only; the module resolves its definition (system prompt, tools, subagents, max_turns, model_id) at run time via the process-dictionary `:custom_agent_id` bridge.

### Subagent Spawning Mechanics

`AgentScheduler.spawn_sub_agents/2` (from within the agent process) validates depth ≤ `max_agent_depth`, checks the parent's path isn't git-ignored, marks the parent `:waiting` (parent Task blocked; its worktree stays alive — reclaimed only on process exit via WorktreeManager's `:DOWN` monitor), dispatches each subagent with its own fresh worktree + incremented task-local ID, and blocks until all subagents complete, returning the results in order.

## Phase Transitions

No automatic transition between Genesis and Evolution — each CLI/dashboard/shell invocation enqueues its OWN task via `TaskRegistry.start_task/2` and `TaskExecutor.execute_task/3` runs it: `:genesis` → `Genesis.run/2`, `:evolve` → `Evolution.run/2`, `:reflect` → `SelfReflective.run/1` (raw opts + `task_id`), `:extract_skills` → `SkillExtraction.run/1`.

## Key Dependencies

| Dependency | Role in Runtime |
|------------|----------------|
| `EvoGit.Core.PhyloGraphNode` | Temporal state — base_commit/current_commit in the git DAG |
| `EvoGit.Core.ContextNode` | Spatial state — a directory node in the Context Tree |
| `EvoGit.AgentScheduler` | Lifecycle manager — scheduling, ETS state, slot management, subagent spawning (worktree lifecycle owned by `WorktreeManager`) |
| `EvoGit.AgentSpec` | Structured spec passed to the scheduler (context_node + phylo_node + module + objective + opts) |
| `EvoGit.Agent.Result` | Structured agent output (result string, commit_sha, tag, branch, base_commit, usage, agent_count, foreign_repo_commits) |
| `EvoGit.Agents.Architect` | Genesis Mode B root — 3 phases: architecture & design → implementation delegation → review & accountability; delegates implementation to Manager subagents |
| `EvoGit.Agents.ContextExtractor` | Genesis Mode A root — read-only context extraction |
| `EvoGit.Agents.Manager` | Evolution simple-mode root (planning, delegation, validation) and Genesis Mode B second root |
| `EvoGit.Agents.Executor` / `.TaskScheduler` | Code-implementation subagent / lightweight task-scheduling subagent (spawned by Manager) |
| `EvoGit.Adapters.Git` | All git CLI operations |
| `ReqLLM` | LLM streaming for PR title generation in `PullRequest` |

## Known Issues — `repo_path` Resolution vs. BEAM cwd (dashboard Windows path bug)

- **UNC / network-share repo roots are UNSUPPORTED for worktree-based tasks** (`\\server\share\...`, `\\wsl.localhost\...`, `\\wsl$\...`, and the forward-slash `//server/share/...` form). git-for-Windows (incl. the bundled MinGit on the desktop) is broken/limited for `git worktree add` on UNC roots: MSYS2 normalizes `\\server\share` ↔ `//server/share` inconsistently across the worktree metadata files (`.git` pointer + `.git/worktrees/<n>/gitdir`), so path-form comparison fails → "outside repository"/worktree-not-detected errors. Worktrees are created INSIDE the repo root, so a UNC root puts all worktree I/O on the share; even if `worktree add` succeeds, Elixir-side form-sensitive code breaks — `ensure_linked_worktree/2`'s `Path.expand` prefix check and the literal `"/.genesis/workers/"` splits assume forward-slash-normalized paths. **Guard**: `EvoGit.Platform.unc_path?/1` detects the UNC share shape (`^//[^/]+/[^/]+` after separator normalization — distinct from `unc?/1`, which flags ANY double separator; bare `//foo` with no share is NOT flagged) and `Helpers.validate_repo_path!/1` raises an `ArgumentError` naming the path, the git-for-Windows worktree-metadata limitation and the workarounds (local drive, `subst X: \\server\share\proj`, or WSL at the native Linux path) at task start, BEFORE any git/worktree I/O. It runs from `Runtime.ensure_repo/1` (before the `File.dir?` check, covering genesis/evolution/skill_extraction) and from `validate_foreign_repo!/1` (before `Git.rev_parse`), so foreign repos with UNC roots fail early with the same diagnostic.
- All three `run/2` entry points resolve a possibly-relative/name-only `:repo_path` against the **BEAM process cwd** via `EvoGit.Platform.safe_expand()`.
- The desktop Tauri sidecar spawns the release launcher with **no `current_dir`**, so BEAM cwd is inherited from the Tauri process (typically the app install/data dir; Windows `%LOCALAPPDATA%\genesis-desktop`) — `"Test"` becomes `c:/Users/<user>/AppData/Local/genesis-desktop/Test`. `Runtime.ensure_repo/1` silently `File.mkdir_p!`s + git-inits a missing repo dir, so a name-only path creates a stray repo under the app dir instead of erroring.
- The string `"Directory does not exist: <path>"` is produced ONLY by `Helpers.validate_node_path/2` (called from `Evolution.run/2` for tasks with a `:node_path`), and it prints the raw repo-relative `node_path`, NOT the joined `abs_path`; absolute node paths are rejected earlier ("Node path must be relative…"). On Windows the full-path strings users see come from dashboard-side flash messages that print the raw submitted path (`ProjectFlow.open_project/2`/`select_project/2`, `projects_live.ex` `handle_palette_key/3` (`"Enter"`)); the dashboard reduces a picked absolute path to its basename only in the JS File System Access API fallback (`fillInput(handle.name)`), after which `Path.expand/1` resolves the bare name against the BEAM cwd.
- **No absolute-ness/existence validation of `:path`/`:repo_path` exists between the dashboard and the runtime**: `TaskRegistry.start_task/2` → `RuntimeOpts.build_common_runtime_opts` (`Keyword.fetch!(opts, :path)`, verbatim) → runtime. Only existence checks: `Adapters.Git.run/2`'s `File.dir?(cd)` pre-check → `{:error, {:enoent, "Repository path does not exist: …"}}`, and `validate_node_path/2` (node sub-paths only). `TaskRegistry.add_recent_project/2` stores the path verbatim — no expansion, no validation.
- **Fix direction**: validate/expand the project path at the task boundary (TaskRegistry or RuntimeOpts) and reject non-absolute paths; the dashboard's `ProjectFlow` already expands before registering recents, so the runtime should do the same (and/or `Runtime.ensure_repo/1` should require an absolute path).

## Known Issues — Windows / Platform Generation & Silent Failures

- **Windows worktree-init scripts are GENERATED here but EXECUTED by `../agent_scheduler/worktrees.ex`, and the two disagree about the shell.** The catalog bodies are PowerShell (`Test-Path` / `Copy-Item -Recurse -Force <src> "$env:TARGET_WORKTREE_PATH/"`); `Worktrees.run_init_script/3` picks the preamble LANGUAGE from `Platform.windows?()` but the EXECUTABLE from `Platform.shell()` (config `[tools].shell`, Windows default `"powershell"`), so `[tools] shell = "bash"`/`"cmd"` on Windows feeds PowerShell text plus a `$env:` preamble to bash/cmd.
- **Any init-script failure is silent**: `run_init_script/3` logs a non-zero exit and still returns `:ok` — the worktree just cold-builds (deps/build artifacts never copied) with no task error.
- **The `Copy-Item … "$env:TARGET_WORKTREE_PATH/"` destination-trailing-separator form is never executed or parsed by any test** (tests only substring-assert `$env:SOURCE_REPO_PATH`/`_build`/etc.); its exact PowerShell semantics (copy-into-directory vs. nest vs. error) are unverified, and the POSIX variants were never equivalent (`cp -R src dst/` vs `Copy-Item -Recurse`).
- **`validate_repo_path!/1` rejects Windows extended-length paths**: `unc_path?/1` matches `\\?\C:\very\long\path` and `//?/C:/very/long/path`, so `Runtime.ensure_repo/1` raises the UNC `ArgumentError` — with wrong remediation advice — for a purely local long path (reachable only when the `\\?\` prefix survives `safe_expand/1`).
- **`Runtime.ensure_repo/1` discards `Git.init/1` and `Git.add/1` results**, propagating only `Git.commit/1` — an init/add failure (long paths, path form, antivirus, missing git) surfaces at the commit step as a misleading "not a git repository"/"nothing to commit" after `.gitignore` was already written. `File.dir?(repo/.git)` also treats a `.git` FILE (linked worktree / submodule checkout) as a missing repo and git-inits inside it.
- **`ProjectConfig.write_worktree_script/2`'s `{:error, reason}` return is ignored at both genesis call sites**, so a failed write still logs "Genesis: Saved worktree init script" and the task proceeds with no/wrong init script.
- **`binary_part(sha, 0, 7)` is unguarded** at the four `helpers.ex` log sites — `binary_part(nil, 0, 7)` / `binary_part("", 0, 7)` raise `ArgumentError` inside the finalizing window → task `:failed`. `Git.rev_parse` output is `String.trim`-ed by the adapter, so CRLF is not the trigger.
- **`scripts_for/1` accepts only an atom or a config map** — a STRING `build_system` raises FunctionClauseError, and an unknown atom returns `nil` → `write_worktree_script(repo_path, nil)` raises. Both entry points currently pre-validate (CLI `get_build_system/1`, dashboard `String.to_existing_atom`), so this is boundary hardening, not a live defect.
- **`pull_request.ex`**: `gh` use is correctly gated by `Git.gh_available?/0`, but `case Git.origin_default_branch(repo_path) do {:ok, b} -> b end` has no catch-all (CaseClauseError if that function ever gains an error arm), and the `gh` invocations live in `../adapters/git.ex` as bare-name `System.cmd` calls that raise `ErlangError :enoent` on a check→use race (`System.cmd` raises, it never returns a tuple).
- **No POSIX-only assumption exists in this directory**: zero `System.cmd` / `Port.open` / `:os.*` / `System.find_executable` / `File.chmod` / symlink / `/tmp` / `sh -c` usage — the only platform-conditional content is the three generated script variants. **Test gap**: neither `Platform.windows?()` nor the Windows `script.windows` bodies are reachable from Linux/macOS CI; nothing executes them.

## Notes for Agents — Temp/Scratch Prompt Guidance & Env Injection

- **No `EvoGit.Runtime.Prompts` module exists.** Shared prompt text lives in `EvoGit.Agents.PromptFragments` (`../agents/prompt_fragments.ex`) — detail: `../agents/CONTEXT.md`.
- **This directory contributes NO agent instruction about where to put temporary/intermediate/scratch output** (zero hits for `scratch|temp|intermediate|artifact|/tmp|build output|cleanup` in its `.ex` files). The only prompt-facing text it produces is the Mode-B phase-2 objective literal, objectives passed verbatim via `build_phase_spec/6`, the rendered git-submodules note (`load_repo_notes/2` → `AgentSpec` `repo_notes:` → `ContextBuilder.build_repo_notes_section/1`), and PR title/body text — none mentions temp/scratch space.
- **`merge_and_report/4` is the only scratch-adjacent place** — it creates `genesis/agent_<hex>` branches and never merges; it says nothing about untracked/temp files.
- **Nothing here injects environment variables into agent specs or prompts.** `EvoGit.AgentSpec` has no env field — only `model_id`, `repo_id`, `opts`, `foreign_repos`, `repo_notes`; the runtime passes only those keys (plus the spec-opts above).
- **`TMPDIR` is handled at the SANDBOX layer at command-execution time**: `EvoGit.Sandbox.resolve_tmpdir/0` is forced into every sandboxed command (`--setenv=TMPDIR=` on Linux, `env:` on macOS), falling back to `/tmp` when `$TMPDIR` is unset or not under `Platform.tmp_paths/0`. The value is the managed PER-TASK directory (`EvoGit.TaskTmpdir`, `<tmp>/genesis/task_<id>`); the runner resolves it and installs it via `put_current/1`, and tool dispatch re-installs it inside each spawned tool task — the sandbox layer only forwards it. Detail: `../sandbox/CONTEXT.md` + root `./CONTEXT.md`.
- The ONLY agent-visible prompt text in the app that mentions temp files is the ShellTool tool description: POSIX suffix `", never /tmp."` and `"- Always use #{tmp_var()} for temporary files..."` with `tmp_var/0` = `$TMPDIR` on POSIX, `$env:TEMP` on PowerShell. Detail: `../agent/tools/CONTEXT.md`.
- `../agent/tools/context.ex` uses `EvoGit.Sandbox.resolve_tmpdir/0` for the `git commit -F <tmpfile>` commit-message file (framework-internal use, not agent guidance).
