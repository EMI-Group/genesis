# EvoGit Agent Type Implementations

## Intent
Contains agent type modules that implement the `EvoGit.Agent` behaviour. Each module defines a specialized agent role with its own system prompt, tool set, and subagent delegation configuration — the concrete agent implementations used by the runtime and scheduler.

## Routing Table
(No subdirectories — all agent type modules are at this level.)

## API Surface

### Agent Modules
All agents `use EvoGit.Agent` and implement overridable callbacks.

| Module | File | Role | Type | Subagents | Write Access |
|---|---|---|---|---|---|
| `EvoGit.Agents.Manager` | `manager.ex` | Gradual improvements, bug fixing, refining, and polishing orchestrator — does NOT do initial implementation; delegates code changes to Executors | `:read_write` | → Manager (self/recursive), Executor, TaskScheduler, Investigator | ✅ Full |
| `EvoGit.Agents.TaskScheduler` | `task_scheduler.ex` | Lightweight task scheduling agent; transforms rough ideas into execution sequences | `:read` | → Investigator | CONTEXT.md only |
| `EvoGit.Agents.GenesisPlanner` | `genesis_planner.ex` | Specialized planning agent for genesis stage; transforms architectural designs into genesis-aware execution plans | `:read` | → Investigator | CONTEXT.md only |
| `EvoGit.Agents.Executor` | `executor.ex` | Implements precise, targeted code changes from a specific objective | `:read_write` | → Investigator, self (recursive) | ✅ Full |
| `EvoGit.Agents.Investigator` | `investigator.ex` | Read-only deep codebase analysis; updates CONTEXT.md | `:read` | → self (recursive) | CONTEXT.md only |
| `EvoGit.Agents.Architect` | `architect.ex` | Greenfield architecture design and public API definition; delegates implementation to Manager subagents. Accountable for all code in its node path. | `:read_write` | → self (recursive), Manager, Executor, GenesisPlanner | ✅ Full |
| `EvoGit.Agents.ContextExtractor` | `context_extractor.ex` | Extracts semantic context from existing codebases into CONTEXT.md | `:read` | → self (recursive) | CONTEXT.md only |
| `EvoGit.Agents.SkillExtractor` | `skill_extractor.ex` | Analyzes a completed PR and distills reusable knowledge into EvoGit skills | `:read_write` | None (non-recursive) | ✅ Full (`.agents/skills/`) |
| `EvoGit.Agents.Custom` | `custom.ex` | Generic runtime agent for user-defined custom agents — resolves its definition (prompt, agent type, delegation level, tools whitelist, subagents) at runtime from `EvoGit.CustomAgents` via the `:custom_agent_id` process-dictionary key (set by the Runner from `spec.opts[:custom_agent_id]`). Root agents only (`subagent_tool_name/0` = nil); its prompt comes from the definition, NOT from `PromptFragments` | from definition (`:read` / `:read_write`, absent → `:read_write`) | from definition (`subagents` name list → built-in modules; unknown names skipped with warning) | from definition (tools whitelist) |
| `EvoGit.Agents.SelfReflective` | `self_reflective.ex` | Repo-less self-reflective agent (chatbot-like, no worktree, no repository of its own) — read-only over the Genesis source (its `repo_path` IS the Genesis source root); controls tasks, shows user guides, and reports system info on the user's behalf via the single `run_command` shell tool (`ListTasks.list_tasks`/`GetTask.get_task`/`StartTask.start_task`/`CancelTask.cancel_task`/`ForceKillTask.force_kill_task`/`DeleteTask.delete_task`/`SpawnInvestigator.spawn_investigator`, `GuideUser.guide_user`, `ListRecentProjects.list_recent_projects`, `SystemInfo.system_info`; `SpawnInvestigator.spawn_investigator` is a v1 placeholder) | `:read` | None | None (read-only) |

### PromptFragments — Prompt Composition Library

`EvoGit.Agents.PromptFragments` (`prompt_fragments.ex`) is **NOT an agent** — it does not `use EvoGit.Agent` and has no system prompt of its own. It is a library of verbatim shared prompt text that the 8 built-in agent `system_prompt/0` functions compose from (via `~S"""...""" <> PromptFragments.X() <> "..."` concatenation) instead of copy-pasting — a single source of truth eliminating the 4–7× copy-pasted boilerplate across prompts. (`EvoGit.Agents.Custom` — the user-defined `prompt` field — and `EvoGit.Agents.SelfReflective` — a fully inline literal — are the two modules whose prompts do NOT come from fragments.)

**Invariants:**
- The composed `system_prompt/0` strings are **byte-identical** (character-for-character) to the prompt text they reproduce — agent behavior depends on exact wording, so any wording change must be deliberate.
- Fragments carry **NO trailing newline**; callers add `"\n"` explicitly (or mid-line `" "` joiners) so mid-line composition stays exact.
- Near-duplicates are **deliberate separate functions** (or stay inline in the owning module) — never normalized/merged.

**Function inventory (29 functions, grouped by theme; verbatim first lines live in `prompt_fragments.ex`):**

| Theme | Functions (users) |
|---|---|
| **Worktree isolation** | `worktree_isolation_note/0` (Executor, ContextExtractor, TaskScheduler, Investigator); `worktree_isolation_note_short/0` (SkillExtractor); `subagent_worktree_tail_isolated/0` (Manager, Architect) |
| **Delegation principles** | `delegation_investigation_sentence/0` (Manager, Investigator); `delegation_occasional_reads_sentence/0` (Manager, Investigator, GenesisPlanner) |
| **Genesis architecture** | `genesis_architecture_header/0`, `context_tree_routing_table_clause/0`, `phylogenetic_graph_sentence/0`, `transient_memory_clause/0`, `recursive_loop_intro/0`, `recursive_loop_tail/0` (all Manager, Architect) |
| **Sibling paths & routing tables** | `routing_sibling_prefix/0` (Manager, Architect); `sibling_example_parenthetical/0` (Manager, Architect, ContextExtractor) |
| **Code quality & file structure** | `solid_principles_sentence/0`, `large_files_intro/0`, `large_files_remediation/0`, `user_config_specifies_clause/0`, `file_structure_expectations_prefix/0` (all Manager, Architect) |
| **Context Tree definition** | `context_tree_definition_clause/0`, `routing_table_markdown_list_clause/0`, `delegate_without_investigating_clause/0` (all Architect, ContextExtractor) |
| **CONTEXT.md = current state, not history** | `context_current_state_clause/0` (Manager, Architect, Investigator, ContextExtractor) — the shared "current state, not history" paragraph + active-maintenance guidance (keep CONTEXT.md concise by pruning when adding; write findings at the best-fit child/descendant node with a routing-table entry at the current level; extract oversized sections into skills; the `... [Content Truncated] ...` marker in a read CONTEXT.md signals the file exceeded the per-file ~64 KB truncation limit — prune it) |
| **Shared canonical phrases** | `standard_sections_enum/0` (Architect, Investigator); `context_chain_example/0` (Manager, Architect); `genesis_context_header/0` (TaskScheduler, GenesisPlanner) |
| **Foreign repositories** | `foreign_repo_absolute_path_clause/0`, `foreign_repo_spawn_right_level/0`, `writable_foreign_repo_clause/0` (Architect, ContextExtractor) |
| **Objective scope** | `objective_not_in_node_prefix/0` (Executor, ContextExtractor) |

## Notes for Agents (prompt composition)

- **Architect foreign-repo role rule** (in `architect.ex` "Foreign Repository Integration"): the Architect must determine what each foreign repo is FOR (tests / reference implementation / dependency / docs) before designing, and treat foreign-repo test suites as given tests to design for (100% pass-rate target) that carry into Phase 2. Do not remove when editing the prompt — it fixes the real-world failure mode where tests were implicitly supplied as foreign repos and the Architect ignored them.
- **Writable vs read-only foreign repo semantics (prompt guidance)**: the revised delegation model is taught in `manager.ex`, `executor.ex`, `architect.ex`, `context_extractor.ex` and the shared canonical clause `PromptFragments.writable_foreign_repo_clause/0` (weaved into Architect's Key Rules and ContextExtractor's Key rules, near-duplicate of their local bullets by design). Model: **read-only foreign-repo access is unrestricted** — any agent may spawn a read-only agent (subagent_investigator / subagent_task_scheduler / subagent_context_extractor) into any foreign repo at any time. **Write-capable (`:read_write`) spawns into a foreign repo (`writable = true` in `genesis.toml` `[foreign_repos.<id>]`) are ROOT-AGENT-ONLY (depth 0) and ONE-AT-A-TIME (serialized)** — only the root agent may spawn writable subagents into a foreign repo, one at a time (spawn one, wait for it to complete, then spawn the next; never in parallel). Rationale: the original spatial-contract design — every agent edits only files under its own path, and parallel writes to a foreign repo create merge conflicts the spawning agent cannot control (the sandbox restricts write access to the agent's LOCAL path, not the foreign repo path); parallelism inside a writable foreign repo is the job of the Manager running INSIDE that repo. Nested/child agents needing foreign-repo changes must report back up to the root agent, which spawns the writable subagent (one at a time). Writable changes are committed to `evogit-agent-*` branches, tracked by the task (per-repo commit + branch in the final report), and NEVER merged back into the foreign repo's default branch by the task (merging/rejecting happens later via the dashboard review page). `task_scheduler.ex` / `genesis_planner.ex` still mention writable capability in general terms only (both are `:read`-type planners that can never spawn write-capable agents — consistent, leave as-is). Do not regress the updated prompts to read-only-only; do not remove the Architect's "determine what each foreign repo is FOR" / "Never investigate the foreign repo yourself" rules.
- **Prompt boilerplate lives in `prompt_fragments.ex`.** When editing an agent system prompt, update the fragment module — edit the shared fragment (if shared) or add a new fragment function there. **Never inline copy-paste** prompt boilerplate into an agent module.
- **Extract new shared text** (verbatim, shared by ≥2 prompts) as a new function in `prompt_fragments.ex` with a `@doc` noting which modules use it and any "do NOT merge" warnings.
- **Near-duplicates are deliberate variants** — preserve them as separate functions or leave them inline; never normalize/reword/merge (behavior depends on exact wording).
- **Golden dump verification:** after any prompt change, dump every agent's `system_prompt/0` before and after and diff — outputs must match character-for-character unless a deliberate wording change was made (e.g. `mix run --no-start -e 'mods = [EvoGit.Agents.Manager, ...]; ...'`).
- **Fragments carry no trailing newline** — callers add `"\n"` explicitly; a fragment that must end a line without a newline (mid-line composition) is composed with `" "` joiners inline in the caller.
- The guard-check pattern `never include worktree paths|OWN isolated worktree` should match ONLY `prompt_fragments.ex` plus any intentional single-module inline variants (documented in fragment `@doc`s).

## Known Issues
- **Agent reachability mechanism:** an agent type is reachable at runtime ONLY via (a) a root spawn site — `AgentSpec.new(..., Mod, ...)` + `AgentScheduler.run_agent/1` in `runtime/genesis.ex`, `runtime/evolution.ex`, `runtime/skill_extraction.ex`, or `task.ex` — or (b) appearing in a spawned agent's `subagent_modules/0` (tool schemas are generated from that list via `EvoGit.Agent.SubagentSchemas` and resolved by `subagent_tool_name()` match in `tool_dispatch.ex:884-886`). There is NO string-based module resolution (`Module.concat`/`String.to_atom`) for agent types anywhere.
- **`TaskScheduler` and `GenesisPlanner` carry the FULL default write-tool schema despite being `:read` type.** Only `Investigator`, `ContextExtractor`, `SelfReflective`, and `Custom` define `available_tools/0` (rg confirms); the other six agents (incl. TaskScheduler + GenesisPlanner) inherit the `EvoGit.Agent` default `Tools.schemas/0` (all write tools). Their prompts claim read-only behavior ("you do NOT modify files"), and the cross-repo spawn gate allows any `:read`-type agent into foreign repos — so a TaskScheduler/GenesisPlanner spawned in a foreign repo has write tools in its schema, but runtime write enforcement is layered: `Tools.execute/5` chains `maybe_block_read_only_foreign_repo/5` after `maybe_block_repo_less/5` (agent/tools.ex:178-208) — the agent's foreign-repo role is resolved by id-matching `Process.get(:evogit_repo_id)` against `Process.get(:foreign_repos, [])` (the task-level foreign repo list, normalized) with a `ForeignRepo.resolve_path/2` fallback, blocking every write tool inside a read-only foreign repo (`writable != true`); `Shared.validate_file_scope/3` additionally rejects write targets inside read-only foreign repos (defense-in-depth). Read-only enforcement for foreign repos also includes: (1) spawn-time `agent_type()` gate (`Subagents.validate_spatial_contract_for_spec/3`, agent_scheduler/subagents.ex:202-229, blocks `:read_write` with `{:error, {:foreign_repo_read_only, msg}}`), and (2) prompt instructions. `Tools.read_only_schemas/0` (agent/tools.ex:119-156) includes read tools + `Context.write_schema`/`Context.edit_schema` (CONTEXT.md writes allowed) + `ShellTool` — NO Curl (removed: it has no legitimate read-only role) — so "read-only agents" can still update CONTEXT.md and run read-only shell in their own repo.

## Constraints
- Every agent module MUST `use EvoGit.Agent` and implement `system_prompt/0`.
- The behaviour module (`EvoGit.Agent`) lives in `../agent.ex`, NOT in this directory.
- Tool modules (`EvoGit.Agent.Tools.*`) live in `../agent/tools/`, NOT in this directory.
- Cross-references between agent types use the `EvoGit.Agents.*` namespace.
- Each agent declares a `delegation_level/0` (`:high` or `:low`) controlling turn-budget warning frequency for delegation reminders. High-level agents (Manager, Architect, Investigator, GenesisPlanner) receive full delegation guidance. Low-level agents (Executor, TaskScheduler, ContextExtractor, SkillExtractor) receive reduced warnings.
