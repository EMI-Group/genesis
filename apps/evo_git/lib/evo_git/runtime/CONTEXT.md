# Runtime

## Intent
Execution engine for the runtime phases: **Genesis** (create a new codebase, or analyze an existing one), **Evolution** (iterative modification), repo-less **SelfReflective** (one-shot) and **Assistant** (interactive session), and post-PR **SkillExtraction**.
A shared `PullRequest` module offers optional PR creation.
There is NO centralized `EvoGit.Runtime.Prompts` module — prompt text lives in agent `system_prompt/0` callbacks and inline strings.

## Routing Table
None — leaf directory.
Modules: `../runtime.ex` (`EvoGit.Runtime`), `helpers.ex`, `genesis.ex`, `evolution.ex`, `pull_request.ex`, `worktree_init_script.ex`, `skill_extraction.ex`, `self_reflective.ex`, `assistant.ex`.

## API Surface

### Modules

| Module | File | Public API | Role |
|--------|------|------------|------|
| `EvoGit.Runtime` | `../runtime.ex` | `ensure_repo/1` | Raises the UNC diagnostic, then `git init` + `/.genesis` `.gitignore` + initial commit when `<repo>/.git` is missing; called by `TaskExecutor.execute_task/3`. There is no combined orchestration entry point. |
| `EvoGit.Runtime.Helpers` | `helpers.ex` | `merge_and_report/4` (3-arity delegates with `foreign_repos: []`; a `nil` repo path is the repo-less finalization — no HEAD, no branch, no git call, returns `{:ok, %{result:, commit_sha: nil, branch_name: nil, tag: nil}}`), `resolve_starting_commit/2`, `resolve_foreign_repo_starting_commit/2`, `format_invalid_starting_commit_error/3`, `notify_finalizing/1`, `generate_branch_name/1`, `new_codebase?/1`, `validate_node_path/2`, `validate_repo_path!/1`, `load_foreign_repos/2`, `merge_foreign_repos/2`, `load_repo_notes/2`, `resolve_root_agent/2`, `model_id_locked?/1`, `normalize_model_selection_opts/1`, `build_root_agent_spec/7` | Shared phase helpers — branch creation, change detection, node/repo-path validation, starting-commit resolution, foreign-repo loading + up-front validation, repo-notes rendering, root-spec building. |
| `EvoGit.Runtime.Genesis` | `genesis.ex` | `run/2` | Creation/Analysis; mode auto-detected. `{:ok, report}` or `{:ok, %{..., no_changes: true}}`, else `{:error, reason}`. |
| `EvoGit.Runtime.Evolution` | `evolution.ex` | `run/2`, `mode_atom/1` (`@doc false` test wrapper) | Evolutionary loop; modes `:simple`/`:custom`; same return shape as Genesis. |
| `EvoGit.Runtime.PullRequest` | `pull_request.ex` | `try_create/4`, `generate_title/2`, `format_body/2` | LLM title, body formatting, push + PR via `gh`; `try_create/4` returns `{pr_url, pr_title}` or `{nil, nil}`, never raises. |
| `EvoGit.Runtime.WorktreeInitScript` | `worktree_init_script.ex` | `build_systems/0`, `get_build_system/1`, `scripts_for/1` | Per-build-system catalog (Elixir, Node.js, Python, Rust, Go, None): one unix (bash) + one windows (PowerShell) script copying deps/build artifacts from the source repo into new worktrees, preserving source mtimes so Mix `_build`/Cargo/npm caches stay warm (Linux `cp -R --preserve=timestamps --reflink=auto`, macOS `cp -cRp`, Windows `Copy-Item -Recurse -Force`). Genesis Mode B writes them to `genesis.toml` as `script.linux`/`script.macos`/`script.windows`. The `:elixir` variants then delete `_build/*/consolidated` and `_build/*/lib/*/consolidated` in the TARGET worktree, because preserved mtimes would otherwise make Mix reuse the source checkout's consolidated protocol beams; dep manifests self-heal, so no `mix deps.get`/`deps.compile` step is added. |
| `EvoGit.Runtime.SkillExtraction` | `skill_extraction.ex` | `run/1` | Distills a completed PR's changes into Genesis skills (`.agents/skills/`): takes a PR-context keyword list (title, objective, summary, commit history, base_sha, commit_sha, user_note), builds the objective, spawns a `SkillExtractor` agent. |
| `EvoGit.Runtime.SelfReflective` | `self_reflective.ex` | `run/1`, `run/2`, `source_root/0`, `build_spec/2` | Repo-less one-shot operator runtime (no repo, no worktree, no git ops, no merge); `source_root/0` delegates to `EvoGit.SelfReflectiveSource.reference_path/0` with terminal fallback `File.cwd!()`. Rules below. |
| `EvoGit.Runtime.Assistant` | `assistant.ex` | `run/1`, `run/2` | Interactive repo-less phase: reuses `SelfReflective.build_spec/2` verbatim plus `session_mode: :interactive`, `AgentScheduler.start_session/1`, awaits the close for the session's lifetime, then reports ONCE. Only entered on an explicit `session_mode: "interactive"`; `"oneshot"` raises `ArgumentError`. Rules below. |

There is NO `%EvoGit.Runtime.Spec{}` (or similarly named) struct here: each phase builds an `%EvoGit.AgentSpec{}` directly, and the only runtime-level container is the plain report map from `Helpers.report_map/5`.
Repo identity therefore lives entirely on `%EvoGit.AgentSpec{}` — `repo_id` (which repo this agent works in) plus `foreign_repos` (the full task-level list) — not in a runtime-side spec type.

### SelfReflective & Assistant — Repo-less Rules
`self_reflective.ex` is the only runtime-directory source behind the repo-less phases; no assistant, evaluation, approval or source-clone module lives under `runtime/`.
Mode is `"reflect"` with NO `:path`: `TaskExecutor` sends `:reflect` to `SelfReflective.run/1` (raw task opts + `task_id`), or to `Assistant.run/1,2` when opts carry `session_mode: "interactive"` — routing lives in `../task_registry/task_executor.ex`, never here.
`build_spec/2` hardcodes `EvoGit.Agents.SelfReflective`, a nil phylo node and forced `repo_less: true`, forwarding every opt except `:objective`, `:source_root`, `:node_path` through `Helpers.normalize_model_selection_opts/1` (not the shared root-spec builder); `run/1` defaults the objective to `""`, `run/2` requires a binary objective and adds `node_path: "./"`.
The spec has no worktree, no git operation and no subagents (`subagent_modules/0` is `[]`), and never loads foreign repos or calls `ensure_repo/1`/`merge_and_report/4`; only `{:ok, %EvoGit.Agent.Result{}}` is projected into the four-key map (usage/agent_count omitted), and any other scheduler response is logged and returned unchanged.
A nonempty `opts[:source_root]` overrides the context root only when `File.dir?/1` succeeds (no expansion, no checkout validation); otherwise `source_root/0` runs the chain `:self_reflective_source_root` app env → `GENESIS_SOURCE_ROOT` → the reserved VCT mount `vct:///genesis-source` when valid → the managed clone → `File.cwd!()`. `node_path` goes straight to `ContextNode.load/2` with no `validate_node_path/2`; a non-directory root yields a bare `%ContextNode{}` with repo `"[system]"`.
A reflect run is STATELESS: no `:history`/`:messages`/`:conversation`/`:resume_from`/`:session` key is read here or on the registration path (a supplied `:resume_from` is inert for `:reflect`), each call is ONE fresh `AgentSpec` + `run_agent/1` whose first message `ContextBuilder.build_initial_messages/4` rebuilds from the objective, and nothing here uses `Process.put/get`, `:persistent_term` or ETS.
The run ends on the completion protocol (a reply with no tool calls is the result), the scheduler then recycles the agent's ETS state so a later `send_user_message/2` answers `{:error, :not_found}`, and the task is persisted `:completed` with its tmpdir reclaimed; the transcript lives only in the live session's state and dies with it.
Multi-turn chat is a DASHBOARD construct: each send starts a NEW `:reflect` task with prior turns as bounded TEXT in the objective (`EvoDashWeb.HomeLive.Transcript.build_preamble/2`, last 8 exchanges × 600 chars capped at 4000), and `ChatHistory` restores only UI state.
`build_spec/2` drops only `:objective`/`:source_root`/`:node_path`, so an unknown caller key (even `:foreign_repos`) lands in `AgentSpec.opts` unvalidated but is inert: `repo_less: true` short-circuits repo-root resolution (`Dispatch.resolve_repo_less_root/0`) and the tool layer blocks writes.

### `Assistant` — Interactive Lifetime
`Assistant.run/1,2` is the multi-turn sibling of `SelfReflective`: ONE long-lived `EvoGit.Agent.Session` driven message by message (`AgentScheduler.send_session_message/3`), not one agent run per task.
It reads only `:objective`, `:source_root`, `:node_path` (default `"./"`) and `:task_id`; the spec is `SelfReflective.build_spec/2` plus `session_mode: :interactive` appended after it, so the interactive opt always wins.
Lifecycle is exactly four steps: `AgentScheduler.start_session/1` (non-blocking, returns the agent id used for messages and close) → `AgentScheduler.await_close(agent_id, :infinity)` → `Helpers.notify_finalizing(task_id)` → `Helpers.merge_and_report(nil, result, "assistant")`.
The await is `:infinity` by design: an interactive session ends only when closed, gracefully cancelled or force killed — no idle timeout — and the task wrapper's cancellation path ends a session whose caller went away. A parked session keeps the task non-terminal (`:awaiting_input`), and a close while idle finalizes with the session's last tool-free reply.
Finalization runs EXACTLY ONCE, broadcast then report, through the nil-repo `merge_and_report` clause (no HEAD, no branch, no git call), returning the same four-key map.
A start failure (`:llm_not_configured`, `:cancelled`, …) or a session ending without a `%Result{}` returns the error verbatim and performs NO finalization.
`send_message/3` and `close/1` are NOT duplicated here — they are `AgentScheduler.send_session_message/3` and `AgentScheduler.close_session/1`, called directly by the dashboard.
Sessions are IN-MEMORY only: a BEAM restart loses the session and fails the task (no transcript persistence, no resume), and boot reconciliation marks the abandoned task failed. If `:interactive` mode is not honored and the session finalizes on its first tool-free reply, the same `await_close/2` still yields one identical report — never a hang, never double finalization.

### `Genesis.run/2` — Steps

1. `repo_path` = `opts[:repo_path]` (default `File.cwd!()`) through `EvoGit.Platform.safe_expand/1` (UNC-preserving).
2. `Runtime.ensure_repo/1`, then HEAD via `Helpers.resolve_starting_commit(repo_path, nil)` — Genesis always resolves HEAD and has no `:starting_commit` clause.
3. Mode via private `resolve_mode/2`: explicit `:mode` `:new`/`:existing`, else `Helpers.new_codebase?/1` (files beyond `.git`, `README.md`, `.genesis`, `.gitignore`); `:custom`/`"custom"` raises `ArgumentError` (custom is evolve-only).
4. Mode B only: the `build_system` task opt → `WorktreeInitScript.scripts_for/1` → `ProjectConfig.write_worktree_script/2` writes the `script.*` variants (skipped when nil or `:none`), re-written by `ensure_worktree_script/3` after each root phase if `genesis.toml` was corrupted.
5. `foreign_repos` = `Helpers.load_foreign_repos/2`, threaded into the spec by `build_phase_spec/6` → `build_root_agent_spec/7` (`foreign_repos:` opt).
6. Dispatch: **Mode A (Existing)** → `ContextExtractor` root (read-only recursive CONTEXT.md tree extraction); **Mode B (New)** → `Architect` root (architecture & design → implementation delegation → review & accountability) then a second `Manager` root for implementation.
7. `AgentSpec.new(...)` → `AgentScheduler.run_agent/1` (blocks until complete).
8. Post-processing `merge_and_report/4`: base SHA vs the agent-reported final SHA (`agent_output.commit_sha`, the POST-fallback worktree HEAD). Changed → `genesis/agent_<hex>` branch at the agent commit (reviewable on the dashboard); unchanged → `no_changes: true`.

### `Evolution.run/2` — Steps

1. `mode_atom/1`: `nil`/absent, `:simple`, `"simple"` → `:simple`; `:custom`/`"custom"` → `:custom`; ANY other value → warning + `:simple` fallback.
2. Custom mode requires an `agent:` opt — nil/empty raises `ArgumentError` ("custom mode requires an agent id; pass agent: <id> (defined in agents.toml)") BEFORE any repo/git I/O; unknown ids raise in `Helpers.resolve_root_agent/2`.
3. `repo_path` (safe_expand) → `ensure_repo/1` → `resolve_starting_commit(repo_path, opts[:starting_commit])` → `validate_node_path(node_path, repo_path)` (`node_path` default `"./"`).
4. `run_mode/7` is the ONE shared flow for both modes, parameterized by the default root module: phylo node at the resolved SHA, context node at `node_path`, `load_foreign_repos/2`, `load_repo_notes/2`, `build_root_agent_spec/7` → `run_agent/1` → `notify_finalizing/1` → `merge_and_report(repo_path, output, "evolve", foreign_repos)`.
5. `:simple` root = `Manager` (plans, delegates to Executor/TaskScheduler/Investigator subagents); `:custom` root = `EvoGit.Agents.Custom` bound to the `agent:` id.
6. Errors: `{:error, {:invalid_node_path, msg}}`; invalid starting commit → `{:error, message}` from `format_invalid_starting_commit_error/3`; anything else propagates.

### Task Pause Result Pass-Through (`{:paused, info}`)

`AgentScheduler.run_agent/2` is a blocking `GenServer.call(…, :infinity)` returning `{:ok, %Result{}} | {:error, term()} | {:paused, map()}`, where `info = %{agent_id, task_id, reason: :task_pause, pause_kind, checkpoint, branch, durable, clean_freeze, frozen_agents}` (the ROOT's own facts plus the task-level freeze verdict) — a pause is a THIRD terminal term, never completion.
`Evolution.deliver_agent_result/4` is the ONE explicit pause branch (`evolution.ex:124-133`): it logs "task paused at a turn boundary … not merging" and returns `{:paused, info}` UNCHANGED, with NO `notify_finalizing/1` and NO `merge_and_report/3,4`.
`merge_and_report/4` never receives a pause — its `is_map(agent_output)` guard cannot match the tuple, and it is only reachable from the `{:ok, %Result{}}` arm.
Pass-through is the whole contract: `TaskRegistry.TaskExecutor` returns the phase value verbatim and `TaskRegistry.handle_wrapper_result/3`'s `{:paused, info}` arm parks the row via `persist_paused/3` (`:paused`, `finished_at` nil, result/usage untouched, `pause_kind` DERIVED from that report by `Pause.pause_kind/1` — `:clean` only when it proves `clean_freeze: true` and `durable: true`).
`Genesis` (Mode A and Mode B architecture), `SkillExtraction` and `SelfReflective` have NO pause arm: they fall into their generic `error ->` clause, log it as a failure and return the tuple unchanged for the wrapper to park.
`Assistant.finalize/3` has no `{:paused, info}` clause (a `CaseClauseError` would fail the wrapper), but that is unreachable because `TaskRegistry.Pause` refuses an interactive task with `:not_pausable`.
**Genesis Mode B implementation phase is the exception**: a paused manager result matches its `error ->` arm, which logs "implementation phase failed", fires `notify_finalizing/1` and returns `merge_and_report(repo_path, architect_output, …)` — the paused second root therefore becomes an `{:ok, report}` architect partial success and the task COMPLETES instead of parking.
This directory never sees individual subagent results (`spawn_sub_agents/2` blocks inside the scheduler); child-result narration, including the paused-child text, belongs to `../agent/subagent_processing.ex` (`format_subagent_result/1`).

### `starting_commit` Opt — Evolution Only

`TaskRegistry.RuntimeOpts.build_common_runtime_opts/3` passes `:starting_commit` for BOTH `:genesis` and `:evolve`, but only `Evolution.run/2` reads it — a genesis value is silently ignored.
`Helpers.resolve_starting_commit/2` is the single choke point (`resolve_foreign_repo_starting_commit/2` delegates to it): `nil` → current HEAD via `PhyloGraphNode.current_head/1`; a ref (SHA, branch, lightweight or annotated tag) → `Git.rev_parse` with the `^{commit}` peel, so an annotated tag resolves to its peeled commit and a tree/blob ref is rejected.
A non-existent ref, a non-commit object or an unborn HEAD yields the structured `{:error, {:invalid_starting_commit, ref, repo_path, git_output}}` — never the raw git tuple — which the genesis/evolution `else` arms render via `format_invalid_starting_commit_error/3`.
The resolved SHA becomes `PhyloGraphNode.new(repo_path, sha)` (`base_commit` = `current_commit` = SHA) → `spec.phylo_node` → the worktree is created AT that commit (`Worktrees.create_worktree/6` reads `spec.phylo_node.current_commit`); it is never injected into prompt text, so the agent learns its starting point from the worktree contents.
Resume (`ResumeContext`), merge-auto-resolve (`MergeContext`) and Genesis Mode B phase 2 pass real prior SHAs and are unaffected.

### Genesis Mode B Second Root

The `Manager` second root spawns only after a successful Architect run (`run_implementation_phase/8`), starting at the architect's final commit (`architect_output.commit_sha || base_sha`); Mode B is gated only by `resolve_mode/2`.
Both roots share ONE `task_id` (`:crypto.strong_rand_bytes(8)` when absent), and the scheduler's cancel guard refuses the second root while the task is cancelling.
Implementation-phase failure merges the architect's output as partial success, with `notify_finalizing/1` fired on that arm too.
`:attachments` reach both sequential roots verbatim (shared `opts` → `build_phase_spec/6` → `build_root_agent_spec/7`), so no per-phase stripping exists.

### Prompt / Objective Assembly — No Cross-Agent File Hand-Off

Runtime phases never pass file locations between agents; hand-off is text + a commit SHA only.
- `:objective` reaches the root agent's FIRST user message **verbatim** (4th positional arg of `AgentSpec.new/5` → scheduler → wrapped in `<objective>…</objective>`); only blank→`""` normalization, no truncation. Any absolute path in an objective comes from the CALLER.
- Genesis Mode B hand-off is TEXT ONLY: `impl_objective` interpolates the original objective plus `architect_output.result`; the Manager starts from `architect_commit` (a SHA). No scratch/artifact file is written or read.
- This directory embeds NO absolute path into a prompt; the only interpolations are the objective, the architect report, commit SHAs and RELATIVE gitlink paths (`render_repo_notes/1`). Absolute paths reach prompts from the AGENT layer only — non-primary foreign-repo roots (`ContextBuilder.build_foreign_repos_section/1`) and the agent's own worktree path (`ContextNode.build_context/2`) → `../agent/CONTEXT.md` + `../core/CONTEXT.md`.
- `PullRequest.generate_title_with_llm/3` embeds the objective + a 2000-char result slice into a PR-TITLE prompt — a post-phase utility, not a hand-off.
- **Repo notes**: `load_repo_notes/2` renders the git-submodules block (via `render_repo_notes/1` from `Git.ls_tree_gitlinks`; `nil` when there are none or detection fails — graceful, no `try/rescue`); spec builders pass it as `repo_notes:` → `ContextBuilder.build_repo_notes_section/1`, and subagents inherit it.

### `merge_and_report/4` Never Merges

`merge_and_report/4` only `rev_parse`s HEAD and calls `Git.create_branch(repo_path, branch_name, final_sha)` — for the primary repo AND each WRITABLE foreign repo that produced commits (ONE branch name across repos; NEVER merged into any default branch).
`final_sha` is `agent_output.commit_sha`, the POST-fallback worktree HEAD, because the Runner's `after` auto-commit fallback (`Dispatch.commit_pending_in_worktree/0`) runs BEFORE the result is returned and the runner re-reads the worktree HEAD.
A change committed ONLY by that fallback therefore still produces a real `genesis/agent_<hex>` branch; `no_changes: true`/`branch_name: nil` apply only when the POST-fallback `final_sha` equals the repo-root HEAD.
There is no conflict path in the phases: real branch merging with conflict reporting lives in `EvoGit.Review.merge_branch/2,3` (`{:conflict, details}`).

### Per-Repo Branches & the `repos` Report Key

`merge_and_report/4` (3-arity delegates with `foreign_repos: []`) reports the PRIMARY repo in the top-level keys and adds the top-level `repos` key.

- **Shape**: `repos` maps every STRING repo id (`ForeignRepo.primary_id()` = `"primary"`, else the foreign `repo.id`) to `%{commit_sha, branch_name: String.t() | nil}` — plain maps only (must survive JSON); inner keys are atoms in memory and become strings after the Codec/JSON round trip. `"primary"` is ALWAYS present; each WRITABLE foreign repo that got a branch appears under its id; READ-ONLY repos produce NO entry.
- **One branch name per task**: `generate_branch_name/1` is called ONCE per call and the resulting `genesis/agent_<hex>` name is REUSED for the primary and every writable foreign repo with commits (uniform dashboard merge/reject); in the no-changes / rev_parse-error paths the primary keeps `branch_name: nil` while foreign branches are still created.
- **Data source**: `result.foreign_repo_commits` (`repo_id => latest SHA`, a field of `%EvoGit.Agent.Result{}` defaulting to `%{}`, read via `Map.get(result, :foreign_repo_commits, %{})`); entries are matched against the 4th arg's `foreign_repos` list — only `writable: true` repos WITH a binary SHA are processed, unknown/read-only/sha-less ids produce no entry, and branch-creation failure logs an error and keeps `branch_name: nil`.
- **Codec round trip**: `repos` is NOT in `EvoGit.Store.Codec.@result_data_fields`, so after encode/decode the top-level key is the STRING `"repos"` with string-keyed inner maps — consumers read `Map.get(decoded, "repos")`.
- **Starting commits**: `resolve_foreign_repo_starting_commit(entry, repo_root)` → `{:ok, sha}`: a set `base_sha` resolves via the `^{commit}` peel (guaranteed by up-front validation), a `nil` `base_sha` uses the foreign HEAD via `PhyloGraphNode.current_head/1`; else the structured `{:error, {:invalid_starting_commit, ref, repo_root, git_output}}`.
- **Up-front validation**: after merging TOML + task-opt repos, `load_foreign_repos/2` validates EVERY entry before any agent spawns (spec-error style, no `try/rescue`): the path must exist and be a git repo (`Git.rev_parse(root)`), and a non-nil `base_sha` must resolve; the UNC guard (`validate_repo_path!/1`) runs first per repo. Failure raises an `ArgumentError` naming the repo id, path and problem. `merge_foreign_repos/2` (resume/review paths) stays lenient: it normalizes BOTH lists via `ForeignRepo.normalize/1` and dedups by id with task-opt precedence.
- **Paths and ids**: `load_foreign_repos/2` does NOT expand paths — `ForeignRepo.normalize/1`/`new/3` → `Platform.safe_expand/1` resolves a RELATIVE `genesis.toml` path against the **BEAM cwd** (not the primary repo root) and expands `~`. Dedup is by ID only, so two ids over one root both survive, and a foreign id of the reserved `"primary"` is NOT filtered here (only `ForeignWorktree.ensure_all/1` skips it).
- **Persistent read-view worktrees**: `load_foreign_repos/2` then provisions/resets every WRITABLE non-primary repo's worktree (`AgentScheduler.ForeignWorktree.ensure_all/1`, best-effort, warning-logged) at `<root>/.genesis/foreign_repos/<id>`, so agents can read foreign code for the whole task → `../agent_scheduler/CONTEXT.md`.
- **Propagation**: `load_foreign_repos/2` has four call sites — Genesis Mode A and Mode B (the implementation phase REUSES the architecture list with no re-validation), `run_mode/7` for simple + custom Evolution, and `SkillExtraction.run/1`. The list becomes the root `AgentSpec.foreign_repos`, `merge_and_report/4`'s 4th argument, `AgentState.foreign_repos`, `Process.put(:foreign_repos, …)` for tool gating, and every subagent spec inherits the ENTIRE task-level list verbatim with its own `repo_id` — the per-agent repo is selected by `repo_id`, never by a filtered list.

### `PullRequest.try_create/4` — Steps

1. `Git.gh_available?/0` (absent → `{nil, nil}`).
2. `Git.has_origin_remote?/1`; if none, `Git.create_origin_remote/1`.
3. Base branch from `Git.origin_default_branch/1` (a push failure is only logged).
4. `build_title/3` → optional LLM streaming title (`generate_title/2`/`generate_title_with_llm/3`), falling back to `"Genesis: <head_branch>"`.
5. `format_body/2` — header `## 🤖 Auto-generated by Genesis` + `@username` + the agent result.
6. `Git.push_branch/2` → `Git.create_pull_request/5`.
7. Returns `{pr_url, pr_title}` or `{nil, nil}` on any failure (never raises).

## Constraints

- Both phases: ensure repo → create phylo node → load context node → foreign repos + repo notes → root spec → run agent → `notify_finalizing/1` → `merge_and_report`.
- Agent changes go to **isolated branches** (`genesis/agent_<hex>`), never the working tree; PR creation is optional (requires `gh`).
- `merge_and_report/3` is shared via `EvoGit.Runtime.Helpers` with phase `"genesis"`, `"evolve"` or `"skill"`; the phase only feeds `String.capitalize/1` log prefixes — `generate_branch_name/1` ignores its argument and always yields `"genesis/agent_" <> 8 lowercase hex`, so evolve and skill-extraction branches are ALSO `genesis/agent_*`.
- No centralized `prompts.ex` — all prompt text lives in agent modules' `system_prompt/0` callbacks.
- No `try/rescue` in this directory (spec errors raise; conditions use `with`/`case`/`cond`).
- PR creation is best-effort and never fails the phase — errors log and return `nil`s.
- Evolution `node_path` must be RELATIVE and have a `CONTEXT.md` at the target directory (root `"./"` always passes).

### Task Lifecycle Boundary — Entry Opts, Finalization Report, Disk Ownership

The runtime phases are pure executors run by `TaskRegistry.TaskExecutor` in a spawned `Task.Supervisor` process; they own NO task-level scratch/directory lifecycle, and every directory belongs either to the repo (`repo_path`) or the AgentScheduler's WorktreeManager.

- **Entry points**: `Genesis.run(objective, opts \\ [])`, `Evolution.run(objective, opts \\ [])`, `SelfReflective.run/1,2`, `Assistant.run/1,2`, `SkillExtraction.run(opts \\ [])`; no `Prompts` module.
- **Genesis/Evolve opts** come from `TaskRegistry.RuntimeOpts.build_common_runtime_opts/3`: `repo_path:` = `Keyword.fetch!(opts, :path)` (ABSOLUTE, resolved pre-enqueue), `mode:` atom, `task_id:`, plus put-if-present `node_path`/`starting_commit`/`foreign_repos`/`archive`/`model_id`/`agent`/`model_id_locked`/`build_system`/`attachments`. `SelfReflective.run/2` gets the RAW task opts + `task_id:` (no `build_common_runtime_opts`, which would `KeyError` without `:path`); `SkillExtraction` gets `[repo_path, task_id]` + PR-context keys. Detail: `../task_registry/CONTEXT.md`.
- **Return shapes**: Genesis/Evolution/SkillExtraction → `{:ok, report_map}` else `{:error, reason}` (`{:error, message}` for an invalid starting commit; `{:error, {:invalid_node_path, msg}}` for evolution). SelfReflective/Assistant → `{:ok, %{result:, commit_sha: nil, branch_name: nil, tag: nil}}` | `{:error, reason}`, never `repos` (Assistant reaches it via the nil-repo `merge_and_report/4` clause). TaskRegistry maps any non-`{:ok, _}` to `:failed`.
- **Finalization report**: private `report_map/5` = `%{commit_sha, result, tag, branch_name, pr_url: nil, pr_title: nil, usage, agent_count, repos: %{...}}` (+ `no_changes: true` when the POST-fallback `final_sha` == repo-root HEAD). PR fields are ALWAYS nil here — PR creation is `PullRequest.try_create/4`, called only from `EvoGit.Review`. The map is returned as `{:ok, report_map}`, so `TaskRegistry.handle_wrapper_result/3` persists the WHOLE tuple as `tasks.result` (Codec `__result_tag__: "ok"`), making `result:` the agent's final reply string verbatim.
- **`notify_finalizing/1`** (`nil` → `:ok`) fires IMMEDIATELY BEFORE `merge_and_report/4` at every success site: Mode A success, Mode B implementation success, Mode B partial-success error arm, evolution, skill extraction and the interactive `Assistant` (which reads `opts[:task_id]` once before starting the session). No `:finalizing` broadcast on the one-shot reflect path.
- **Disk ownership**: no task scratch dirs and no `EvoGit.Platform.data_dir/0` or system-tmp use (zero `data_dir`/`System.tmp_dir` references under `runtime/`). The only writes are `ensure_repo/1` (repo dir + `.git` + a `/.genesis` `.gitignore`), `ProjectConfig.write_worktree_script/2` (`genesis.toml` inside the repo) and `Git.create_branch/3` refs inside `.git`. `usage`/`agent_count` are produced by the agents, per-agent archives are persisted by the agents themselves, and worktrees are created/reclaimed ENTIRELY by the WorktreeManager — the runtime hands over only `repo_path` and never sees a worktree path.

### Task Status & Event Emission (Dashboard Contract)

- **`"tasks"` topic**: the ONLY runtime-phase emitter is `Helpers.notify_finalizing/1`, broadcasting `{:task_updated, task_id, :finalizing, node()}` after `run_agent/1` returns and BEFORE `merge_and_report/4`; no `task_id` → no-op. No `:failed`/`:completed`/`:running` is ever broadcast from these modules — the full status set (plus `nil` for review/metadata and `{:task_deleted, …}`) comes from `EvoGit.TaskRegistry` (`../task_registry/CONTEXT.md`). Scheduler topics differ: `"agents"` → `{:agent_registered|:agent_updated|:agent_removed, …, node}` + `{:agents_updated, node}`; `"scheduler_config"` → `{:scheduler_config_updated, node}`.
- **Task monitor exit** (`Task.Supervisor.async_nolink`): any non-`{:ok, _}` runtime result (incl. `{:error, _}`) maps to `:failed`.
- **Finalizing window** (broadcast → phase return) contains only the broadcast, Mode B's in-memory `Usage.add`/result merging and `merge_and_report/4`'s git calls. `Phoenix.PubSub.broadcast/3` is fire-and-forget, so a long `:finalizing` dwell is entirely the in-process `Git.rev_parse` + one `Git.create_branch` per repo with commits, all via `Git.run/2` → raw `System.cmd` with NO timeout (`:infinity`) — they can block indefinitely on a slow (e.g. NFS) filesystem.
- **Per-step logging**: `merge_and_report/4` brackets each blocking git op with `Logger.info` (`"<Phase>: Finalizing repo '<path>': resolving HEAD"`, `"<Phase>: Creating branch '<name>' at <sha7>"`, foreign-repo variants), so a hung op leaves the last line naming the stuck step; the git adapter itself has ZERO `Logger` usage, and git timeouts are out of scope.
- `merge_and_report/4` NEVER raises and ALWAYS returns `{:ok, map}`; worktree cleanup is NOT in the window (WorktreeManager reclaims asynchronously on `:DOWN`: `File.rm_rf` → `Git.prune_worktrees` → `Git.delete_branch`).
- **Critical implication**: every entry point returns whatever `run_agent/1` returns on the error arm, so `{:error, _}` marks the task `:failed` — e.g. `:agent_max_retries_exceeded`, `:cancelled`, `:recovery_failed`, `:path_not_exist` (the wrapper Task exits `:normal` but the result is non-`{:ok, _}`). Detail: `../agent_scheduler/CONTEXT.md`.

### ETS Table Ownership & Crash Resilience

- `:evogit_agent_summary` and `:evogit_sched_meta` are created in `EvoGit.Application.start/2` via idempotent `ensure_ets_table/2`, owned by the long-lived application process, so they survive an `AgentScheduler` restart; `init/1` only warns when a table is missing.
- `EvoGit.AgentGroupSupervisor` is `:one_for_all` over `EvoGit.TaskSupervisor` + `EvoGit.AgentScheduler`, so a scheduler crash tears down ALL running agents (no orphans). Agent Tasks are spawned via `Task.Supervisor.async_nolink/4`, monitored (not linked) by the scheduler. Detail: `../agent_scheduler/CONTEXT.md`.
- Foreign repos are loaded + validated up front and carried on the root AgentSpec via `foreign_repos:` — the scheduler derives each agent's repo role from that list; the phases never call `AgentScheduler.register_foreign_repo`.
- **`ForeignRepo.root` is the single knob the agent layer uses to locate a foreign repo**: the runtime never computes a foreign worktree path. `Dispatch.resolve_agent_repo_root/2` finds the entry by id and reads `.root`; foreign agents get the same transient per-agent worktrees under `<foreign_root>/.genesis/workers/worker_T<task>_A<local>`, destroyed on agent exit — the persistent read-view worktree (`<root>/.genesis/foreign_repos/<id>`) is separate and lives for the task.

## Agent Spawning & Coordination

### How Agents Are Spawned

Both phases build an `AgentSpec` and call `AgentScheduler.run_agent/1` (a synchronous call blocking until the agent completes):

```
AgentSpec.new(context_node, phylo_node, agent_module, objective, opts)
|> AgentScheduler.run_agent()
```

The scheduler: 1) assigns `task_id` (GUID), `task_number` (short integer) and `agent_id` (`T<task_number>_A<task_local_id>`); 2) computes the worktree path (`worker_T<task_number>_A<task_local_id>`) into sched_meta — no worktree I/O; 3) stores initial state in `:evogit_agent_summary` (agent-owned) + `:evogit_sched_meta` (scheduler-owned); 4) spawns the agent's `EvoGit.Agent.Session` (no per-agent Task); 5) the session's `:start` event (`Agent.Session.Setup.bind_worktree/2`) requests a FRESH worktree from `WorktreeManager.create_worktree_for_agent/6` (waits indefinitely; lazy per-repo init + the create pipeline run inside WorktreeManager); 6) on completion (a plain-text reply)/crash/cancel, WorktreeManager reclaims via its `:DOWN` monitor and the scheduler replies to the caller.

### Agent Lifecycle: One-Shot Phases, One Interactive Exception

Every phase EXCEPT `Assistant` is ONE-SHOT: it blocks in `AgentScheduler.run_agent/2` (`GenServer.call(…, :infinity)`) until the scheduler replies for that root via `GenServer.reply(meta.from, result)`, then does post-processing and RETURNS — no phase process outlives the wrapper Task or waits for user input. `Assistant` instead starts an `Agent.Session` and awaits its close, so the SESSION owns the conversation and its worktree for its whole life.
Root count: exactly ONE for Genesis Mode A, Evolution and SkillExtraction; TWO SEQUENTIAL (architect then manager, same `task_id`) for Genesis Mode B — never a re-dispatch of the same root for a follow-up message.
A run ends at the model's FIRST assistant reply with zero tool calls (`EvoGit.Agent.CompletionProtocol.classify/1` → `{:text_reply, text}`). Continued conversation is not a runtime concern for one-shot phases: mid-run input is only `AgentScheduler.send_user_message/2` (or a session `:input` command) into the LIVE run, and a follow-up is a NEW task (`resume_from` / Review page), not a resumed session.
There is no `EvoGit.Runtime.Phase` and no `EvoGit.Runtime.Prompts` module; the only `run_agent` call sites under `runtime/` are those four roots.

### Root-Agent Spec Builder (`Helpers.build_root_agent_spec/7`)

`Helpers.build_root_agent_spec/7` is the shared builder for the evolution (simple AND custom) and genesis phase roots; new code should reuse it instead of hand-assembling specs.
It resolves the root module via `resolve_root_agent/2` → `{module, opts}` (unknown ids raise `ArgumentError`) and threads `foreign_repos`, `repo_notes`, `archive`, `task_id`, model selection, `quality_level` (absent → `nil`; subagent builders never carry it), `:persistent_state` and `:attachments` (omit-when-nil), then appends custom-agent identity/canonical defaults and applies the legacy definition fallback without changing the task lock.
`:persistent_state` is task-wide, defaults to `true` (absent or `nil`), and only an explicit `false` opts out; descendants inherit it from `%EvoGit.Agent.State{}`.
A pause resume's `:resume_kind` (`:clean_pause | :dirty_pause`) is forwarded verbatim and omitted otherwise, and so are the ROOT run's five resume facts — `:pause_commit`, `:resume_agent_id`, `:resume_current_commit`, `:resume_branch`, `:resume_anchor_ref` — forwarded PRESENCE-based (nil included) from `EvoGit.TaskRegistry.RuntimeOpts.resume_fact_keys/0`, the ONE key list both hops share, so a non-resume spec's opts stay byte-identical.
`spec_opts` is an explicit ALLOWLIST — any other runtime opt (`:build_system`, `:starting_commit`, `:session_mode`, `:concurrency`, …) is DROPPED, so a new task-wide flag needs its own `Keyword.get(opts, …)` line there, plus `RuntimeOpts` admission and `Store.Codec` `@atomized_opt_keys` membership if it must survive task persistence. `SkillExtraction.run/1` keeps its own smaller allowlist (`foreign_repos`/`archive`/`task_id` + model selection), and only `SelfReflective.build_spec/2` forwards opts wholesale.

### Task Model Selection

Runtime opts may carry `:model_spec`, a STRING-keyed map of `provider_profile_id`, `model` and optional `reasoning_effort`.
`Helpers.normalize_model_selection_opts/1` passes a non-nil spec verbatim, removes the competing legacy `:model_id` and forces `:model_id_locked` true even when the caller said false; without a spec, legacy ids and explicit locks retain their semantics and Auto adds nothing.
`Helpers.model_id_locked?/1` is true for an explicit lock, a non-nil `model_spec`, or a non-nil legacy `model_id`.
The shared root builder (including BOTH Mode B roots), `SelfReflective.build_spec/2` and `SkillExtraction.run/1` apply the same normalization before `AgentSpec.new/5`.
Auto leaves selection to the scheduler: explicit/locked task selection > model-selection script > custom definition canonical default > legacy `spec.model_id` > configured default.
Runtime wrappers never resolve or rewrite provider/model/reasoning fields — validation and `Schema.resolve_model_spec/2` belong to the config/scheduler boundary.

### Custom Root Model Defaults

`Helpers.resolve_root_agent/2` forwards a custom definition's canonical STRING-keyed `model_spec` as `opts[:default_model_spec]` (omitted when absent) plus its legacy `model_id` when present; definition defaults never use `opts[:model_spec]` and never set `model_id_locked`.
`build_root_agent_spec/7` normalizes explicit task selections first, then supplies the legacy definition id only when the task has neither a canonical spec nor a legacy id.
Scheduler dispatch resolves explicit task `model_spec` first, then locked task ids, then script selections, then `default_model_spec`, then legacy `spec.model_id`, then configured defaults — so Auto lets a script override either definition default, and a nil script result uses the canonical default ahead of the legacy one.
Both Mode B roots and custom Evolution roots share this builder; built-in roots receive no custom definition opts.
Permanent regression tests belong in the parent-owned test tree (never under lib) and must cover that precedence, Auto with and without a script result, canonical vs legacy definition defaults, explicit locked task overrides, and unchanged built-in roots.

### Agent Hierarchy by Phase

- **Genesis Mode A (Existing)**: `ContextExtractor` root → recursive `subagent_context_extractor` children (one per child dir).
- **Genesis Mode B (New)**: `Architect` root (optional `subagent_genesis_planner`, `subagent_executor` for design artifacts, recursive `subagent_architect` + `subagent_executor` per child dir, `subagent_manager` for implementation delegation) → then `Manager` root (implementation) → `subagent_executor`/`subagent_manager` subtrees. TWO sequential roots share a `task_id`.
- **Evolution Simple Mode**: `Manager` (target node) → `subagent_task_scheduler` (complex objectives), `subagent_investigator` (exploration), `subagent_executor` (code changes), `subagent_manager` (child-node delegation).
- **Evolution Custom Mode**: `EvoGit.Agents.Custom` root (resolved from agents.toml via the `agent:` opt) → subagent modules declared in the custom definition. Custom agents are ROOT-only; the module resolves its definition (system prompt, tools, subagents, max_turns, model_id) at run time via the process-dictionary `:custom_agent_id` bridge.

### Subagent Spawning Mechanics

`AgentScheduler.spawn_sub_agents/2` (from within the agent process) validates depth ≤ `max_agent_depth`, checks the parent's path isn't git-ignored, marks the parent `:waiting` (parent Task blocked; its worktree stays alive until process exit), dispatches each subagent with its own fresh worktree + incremented task-local ID, and blocks until all subagents complete, returning the results in order.

## Phase Transitions

No automatic transition between Genesis and Evolution — each dashboard/shell invocation enqueues its OWN task via `TaskRegistry.start_task/2`, and `TaskExecutor.execute_task/3` runs it: `:genesis` → `Genesis.run/2`, `:evolve` → `Evolution.run/2`, `:reflect` → `SelfReflective.run/1` (raw opts + `task_id`), `:extract_skills` → `SkillExtraction.run/1`.
An interactive `:reflect` task — one whose opts carry `session_mode: "interactive"` — goes to `Assistant.run/1,2` instead; that routing lives in the caller (`../task_registry/task_executor.ex`), never in this directory, and `SelfReflective` stays the default for every non-interactive `:reflect` task.

## Key Dependencies

| Dependency | Role in Runtime |
|------------|----------------|
| `EvoGit.Core.PhyloGraphNode` | Temporal state — base_commit/current_commit in the git DAG |
| `EvoGit.Core.ContextNode` | Spatial state — a directory node in the Context Tree |
| `EvoGit.AgentScheduler` | Lifecycle manager — scheduling, ETS state, slot management, subagent spawning (worktree lifecycle owned by `WorktreeManager`) |
| `EvoGit.AgentSpec` | Structured spec passed to the scheduler (context_node + phylo_node + module + objective + opts) |
| `EvoGit.Agent.Result` | Structured agent output (result string, commit_sha, tag, branch, base_commit, usage, agent_count, foreign_repo_commits) |
| `EvoGit.Agents.Architect` | Genesis Mode B root — architecture & design → implementation delegation → review & accountability |
| `EvoGit.Agents.ContextExtractor` | Genesis Mode A root — read-only context extraction |
| `EvoGit.Agents.Manager` | Evolution simple-mode root (planning, delegation, validation) and Genesis Mode B second root |
| `EvoGit.Agents.Executor` / `.TaskScheduler` | Code-implementation subagent / lightweight task-scheduling subagent (spawned by Manager) |
| `EvoGit.Adapters.Git` | All git CLI operations |
| `ReqLLM` | LLM streaming for PR title generation in `PullRequest` |

<!-- genesis:local -->

### Known Issue — Completion Note & Archive Refs Lag the Reported `commit_sha`

`EvoGit.Agent.Completion.complete/4` writes its `refs/notes/evogit` note and, when `archive` is on, its archive refs (`refs/genesis/archive/T<task>-A<local>-start`/`-final`) at COMPLETE time from the pre-fallback `commit_sha` (`sync_and_get_current_commit/1`).
For a commit produced ONLY by the agent-exit auto-commit fallback those refs lag the `commit_sha` `merge_and_report/4` reports by one commit; the change itself is still reviewable/mergeable via the `genesis/agent_<hex>` branch.
Each completing agent writes its OWN `task_agent_archives` row plus those refs; nothing archive-related is combined across agents or carried in `%Result{}`/the report. Detail: `../agent/CONTEXT.md` + `../store/CONTEXT.md`.

### Known Issue — Foreign-Repo Starting-Commit Staleness & Report Last-Writer-Wins

Every foreign-repo spawn resolves its starting commit by: task-level `repo_entry.base_sha` (when non-nil) → the SPAWNING agent's OWN `foreign_repo_commits` map → the foreign HEAD (`SubagentProcessing.resolve_foreign_phylo_commit/4`).
The map is read from the spawning agent's own SchedMeta row (`AgentScheduler.get_foreign_repo_commits/1`), so it is **per-agent**: another agent (another subtree, or Genesis Mode B's second root) sees `%{}` and falls back to `base_sha`/HEAD, and a non-nil `base_sha` wins UNCONDITIONALLY, so even the same agent's later foreign spawns start from it. Writable foreign spawns are ROOT-ONLY (`parent.depth == 0`) and one-per-batch (`{:error, {:foreign_repo_write_not_root, msg}}`).
Reachable stale-start paths: (a) Genesis Mode B's two sequential roots (both depth 0, independent maps) — the two maps merge MANAGER-WINS, so the branch carries only the manager's lineage; (b) any task with an explicit `base_sha`; (c) a write-capable Manager spawned INTO the foreign repo and its cross-repo children in a different repo — the parent's own `commit_sha` then OVERWRITES the tracked sha for that repo id (`Subagents.roll_up_foreign_repo_commits/3`). The Manager's own same-repo children DO inherit the parent's `current_commit` and ARE merged into its worktree (`collect_mergeable_results/3`).
The report takes exactly ONE sha per repo id, so with two foreign commits for one id the LAST writer wins and the earlier lineage survives only as a dangling object (per-agent `evogit-agent-T<task>-A<local>` branches are DELETED on agent exit, primary and foreign).
**No branch clobber is possible**: `Git.create_branch/3` is non-force (`git branch <name> <sha>`; an existing ref fails with `{:error, {128, ...}}`, never resets) and the task branch name is a fresh random `genesis/agent_<hex>` per call; nothing in the runtime does `update-ref`/`branch -f`/`reset` on such a branch. A branch-creation failure is tolerated silently (`commit_sha` kept, `branch_name: nil` → dashboard merge unavailable: `EvoGit.Review.merge_branch/3` → `{:error, :no_branch}`).
`PullRequest.try_create/4` has no merge path — it pushes a branch and opens a PR, and the runtime phases never call it (caller: `EvoGit.Review.create_github_pr`).

## Known Issues — `repo_path` Resolution vs. BEAM cwd (dashboard Windows path bug)

- **UNC / network-share repo roots are UNSUPPORTED for worktree-based tasks** (`\\server\share\...`, `\\wsl.localhost\...`, `\\wsl$\...`, and the forward-slash `//server/share/...` form). git-for-Windows (incl. the bundled MinGit) normalizes the two spellings inconsistently across `.git` and `.git/worktrees/<n>/gitdir`, so path-form comparison fails ("outside repository"/worktree not detected), and Elixir-side form-sensitive code (`ensure_linked_worktree/2`'s `Path.expand` prefix check, the literal `"/.genesis/workers/"` splits) assumes forward slashes. **Guard**: `EvoGit.Platform.unc_path?/1` detects the share shape (`^//[^/]+/[^/]+` after separator normalization — distinct from `unc?/1`'s ANY double separator; bare `//foo` is not flagged) and `Helpers.validate_repo_path!/1` raises an `ArgumentError` naming the path, the git-for-Windows limitation and the workarounds (local drive, `subst X: \\server\share\proj`, WSL at the native path) at task start, from `Runtime.ensure_repo/1` (before the `File.dir?` check) and `validate_foreign_repo!/1` (before `Git.rev_parse`).
- All three `run/2` entry points resolve a possibly-relative/name-only `:repo_path` against the **BEAM process cwd** via `EvoGit.Platform.safe_expand/1`.
- **No repo-root detection exists**: `git rev-parse --show-toplevel` has zero call sites, and `Runtime.ensure_repo/1`'s only root test is `File.dir?(Path.join(repo_path, ".git"))` — so a `:path` naming a SUBDIRECTORY of a git repo is git-initialized in place (nested repo), and foreign validation (`Git.rev_parse(repo.root)`) passes for a subdirectory, making `repo.root` the branch/worktree base rather than the true toplevel.
- The desktop Tauri sidecar spawns the launcher with **no `current_dir`**, so BEAM cwd is inherited from Tauri (Windows `%LOCALAPPDATA%\genesis-desktop`); because `ensure_repo/1` silently `File.mkdir_p!`s + git-inits, `"Test"` becomes a stray repo under the app dir instead of an error.
- `"Directory does not exist: <path>"` comes ONLY from `Helpers.validate_node_path/2` (evolution `:node_path` tasks) and prints the raw repo-relative `node_path`, not the joined `abs_path`; absolute node paths are rejected earlier. Dashboard flash messages print the raw submitted path (`ProjectFlow…`, `projects_live.ex`), and the JS File System Access fallback reduces a picked absolute path to its basename (`fillInput(handle.name)`), which `Path.expand/1` then resolves against the BEAM cwd.
- **No absolute-ness/existence validation of `:path`/`:repo_path` exists between dashboard and runtime**: `TaskRegistry.start_task/2` → `RuntimeOpts.build_common_runtime_opts/3` (`Keyword.fetch!(opts, :path)`, verbatim) → runtime; the only checks are `Adapters.Git.run/2`'s `File.dir?(cd)` pre-check (`{:error, {:enoent, "Repository path does not exist: …"}}`) and `validate_node_path/2`.
- **Fix direction**: validate/expand the project path at the task boundary (TaskRegistry or RuntimeOpts), reject non-absolute paths, and/or make `Runtime.ensure_repo/1` require an absolute path.

## Known Issues — Windows / Platform Generation & Silent Failures

- **Windows worktree-init scripts are GENERATED here but EXECUTED by `../agent_scheduler/worktrees.ex`, and the two disagree about the shell**: the catalog bodies are PowerShell, while `Worktrees.run_init_script/3` picks the preamble LANGUAGE from `Platform.windows?()` but the EXECUTABLE from `Platform.shell()` (`[tools].shell`), so `shell = "bash"`/`"cmd"` on Windows feeds PowerShell text to bash/cmd.
- **Any init-script failure is silent**: `run_init_script/3` logs a non-zero exit and still returns `:ok` — the worktree cold-builds with no task error.
- **The `Copy-Item … "$env:TARGET_WORKTREE_PATH/"` destination-trailing-separator form is never executed or parsed by any test** (tests only substring-assert env vars); its PowerShell semantics are unverified, and the POSIX variants were never equivalent.
- **`validate_repo_path!/1` rejects Windows extended-length paths**: `unc_path?/1` matches `\\?\C:\…` and `//?/C:/…`, so `ensure_repo/1` raises the UNC `ArgumentError` (with wrong advice) for a purely local long path.
- **`Runtime.ensure_repo/1` discards `Git.init/1` and `Git.add/1` results**, propagating only `Git.commit/1`, so an init/add failure surfaces misleadingly at commit after `.gitignore` was written; `File.dir?(repo/.git)` also treats a `.git` FILE (linked worktree/submodule) as missing and git-inits inside it.
- **`ProjectConfig.write_worktree_script/2`'s `{:error, reason}` is ignored at both genesis call sites**, so a failed write still logs "Saved worktree init script" and the task proceeds with no/wrong script.
- **`binary_part(sha, 0, 7)` is unguarded** at the four `helpers.ex` log sites — `binary_part(nil, 0, 7)`/`binary_part("", 0, 7)` raise inside the finalizing window → task `:failed` (CRLF is not the trigger; `rev_parse` output is trimmed).
- **`scripts_for/1` accepts only an atom or a config map** — a STRING `build_system` raises FunctionClauseError and an unknown atom returns `nil` → `write_worktree_script(repo_path, nil)` raises; the dashboard pre-validates, so this is boundary hardening.
- **`pull_request.ex`**: `gh` use is gated by `Git.gh_available?/0`, but `case Git.origin_default_branch(repo_path) do {:ok, b} -> b end` has no catch-all, and the `gh` invocations are bare-name `System.cmd` calls that raise `ErlangError :enoent` on a check→use race.
- **No POSIX-only assumption exists here**: zero `System.cmd`/`Port.open`/`:os.*`/`System.find_executable`/`File.chmod`/symlink/`/tmp`/`sh -c` usage; the only platform-conditional content is the three script variants. **Test gap**: neither `Platform.windows?()` nor the `script.windows` bodies are reachable from Linux/macOS CI.

## Notes for Agents — Temp/Scratch Prompt Guidance & Env Injection

- **No `EvoGit.Runtime.Prompts` module exists**; shared prompt text lives in `EvoGit.Agents.PromptFragments` (`../agents/CONTEXT.md`).
- **This directory contributes NO agent instruction about temp/intermediate/scratch output** (zero hits for `scratch|temp|intermediate|artifact|/tmp|build output|cleanup` in its `.ex` files). Its only prompt-facing text is the Mode-B phase-2 objective, objectives passed verbatim, the rendered git-submodules note and PR title/body text — none mentions scratch space.
- **`merge_and_report/4` is the only scratch-adjacent place** — it creates `genesis/agent_<hex>` branches and never merges; it says nothing about untracked/temp files.
- **Nothing here injects environment variables into agent specs or prompts** — `EvoGit.AgentSpec` has no env field (only `model_id`, `repo_id`, `opts`, `foreign_repos`, `repo_notes`).
- **`TMPDIR` is handled at the SANDBOX layer at command-execution time**: `EvoGit.Sandbox.resolve_tmpdir/0` (the managed per-task dir from `EvoGit.TaskTmpdir`, `<tmp>/genesis/task_<id>`) is forced into every sandboxed command and re-installed inside each spawned tool task, with `/tmp` as fallback. Detail: `../sandbox/CONTEXT.md` + root `./CONTEXT.md`.
- The ONLY agent-visible prompt text mentioning temp files is the ShellTool description (POSIX `", never /tmp."`, `"- Always use #{tmp_var()} for temporary files..."`, `tmp_var/0` = `$TMPDIR` on POSIX / `$env:TEMP` on PowerShell) → `../agent/tools/CONTEXT.md`; `../agent/tools/context.ex` uses `resolve_tmpdir/0` for the `git commit -F <tmpfile>` message file (framework-internal, not agent guidance).
