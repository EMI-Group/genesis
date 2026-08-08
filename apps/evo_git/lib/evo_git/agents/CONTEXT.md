# EvoGit Agent Type Implementations

## Intent
Contains agent type modules that implement the `EvoGit.Agent` behaviour. Each module defines a specialized agent role with its own system prompt, tool set, and subagent delegation configuration. These are the concrete agent implementations used by the runtime and scheduler.

## Routing Table
(No subdirectories — all agent type modules are at this level.)

## API Surface

### Agent Modules
All agents `use EvoGit.Agent` and implement overridable callbacks.

| Module | File | Role | Type | Subagents | Write Access |
|---|---|---|---|---|---|
| `EvoGit.Agents.Manager` | `manager.ex` | Gradual improvements, bug fixing, refining, and polishing orchestrator — does NOT do initial implementation; delegates code changes to Executors | `:read_write` | → Manager (self/recursive), Executor, TaskScheduler, CodebaseInvestigator | ✅ Full |
| `EvoGit.Agents.TaskScheduler` | `task_scheduler.ex` | Lightweight task scheduling agent; transforms rough ideas into execution sequences | `:read` | → CodebaseInvestigator | CONTEXT.md only |
| `EvoGit.Agents.GenesisPlanner` | `genesis_planner.ex` | Specialized planning agent for genesis stage; transforms architectural designs into genesis-aware execution plans | `:read` | → CodebaseInvestigator | CONTEXT.md only |
| `EvoGit.Agents.Executor` | `executor.ex` | Implements precise, targeted code changes from a specific objective | `:read_write` | → CodebaseInvestigator, self (recursive) | ✅ Full |
| `EvoGit.Agents.CodebaseInvestigator` | `codebase_investigator.ex` | Read-only deep codebase analysis; updates CONTEXT.md | `:read` | → self (recursive) | CONTEXT.md only |
| `EvoGit.Agents.CodebaseLead` | `codebase_lead.ex` | Greenfield architecture design and public API definition; delegates implementation to Manager subagents. Accountable for all code in its node path. | `:read_write` | → self (recursive), Manager, Executor, GenesisPlanner | ✅ Full |
| `EvoGit.Agents.ContextExtractor` | `context_extractor.ex` | Extracts semantic context from existing codebases into CONTEXT.md | `:read` | → self (recursive) | CONTEXT.md only |
| `EvoGit.Agents.SkillExtractor` | `skill_extractor.ex` | Analyzes a completed PR and distills reusable knowledge into EvoGit skills | `:read_write` | None (non-recursive) | ✅ Full (`.agents/skills/`) |

### PromptFragments — Prompt Composition Library

`EvoGit.Agents.PromptFragments` (`prompt_fragments.ex`) is **NOT an agent** — it does not `use EvoGit.Agent` and has no system prompt of its own. It is a library of verbatim shared prompt text that the 8 agent `system_prompt/0` functions compose from (via `~S"""...""" <> PromptFragments.X() <> "..."` concatenation) instead of copy-pasting. It exists to eliminate the 4–7× copy-pasted boilerplate that previously drifted across prompts.

**Invariants:**
- The composed `system_prompt/0` strings are **byte-identical** (character-for-character) to the pre-refactor prompts — agent behavior depends on exact wording.
- Fragments carry **NO trailing newline**; callers add `"\n"` explicitly (or mid-line `" "` joiners) so mid-line composition stays exact.
- Near-duplicates are **deliberate separate functions** (or stay inline in the owning module) — never normalized/merged.

**Function inventory (27 functions, grouped by theme):**

| Function | First line (verbatim start) | Used by |
|---|---|---|
| **Worktree isolation notes** | | |
| `worktree_isolation_note/0` | "You are currently working in an isolated worktree. The current working directory is automatically set…" | Executor, ContextExtractor, TaskScheduler, CodebaseInvestigator |
| `worktree_isolation_note_short/0` | First two sentences of variant A (no subagent-spawning sentence) | SkillExtractor |
| `subagent_worktree_tail_isolated/0` | "Each subagent runs in its OWN isolated worktree — never include worktree paths…" | Manager, CodebaseLead |
| **Delegation principles** | | |
| `delegation_investigation_sentence/0` | "Investigating child subtrees yourself is rarely the best use of your turns — a subagent can do it faster…" | Manager, CodebaseInvestigator |
| `delegation_occasional_reads_sentence/0` | "Occasional targeted reads for quick context are fine, but if you find yourself reading multiple files…" | Manager, CodebaseInvestigator, GenesisPlanner |
| **Genesis architecture** | | |
| `genesis_architecture_header/0` | "# Genesis System Architecture\n\nGenesis is a recursive software development framework" | Manager, CodebaseLead |
| `context_tree_routing_table_clause/0` | "as both documentation (Intent, API Surface, Constraints) and a **Routing Table** (a map of…)" | Manager, CodebaseLead |
| `phylogenetic_graph_sentence/0` | "Code evolves through a DAG of immutable Git commits." | Manager, CodebaseLead |
| `transient_memory_clause/0` | "in the Context Tree (CONTEXT.md files) or the Phylogenetic Graph (Git history)." | Manager, CodebaseLead |
| `recursive_loop_intro/0` | "Every agent at every level has the same fundamental loop: read CONTEXT.md" | Manager, CodebaseLead |
| `recursive_loop_tail/0` | "→ delegate to deepest correct child → validate → complete." | Manager, CodebaseLead |
| **Sibling paths & routing tables** | | |
| `routing_sibling_prefix/0` | "Routing tables primarily map to child subdirectories, but may also include sibling paths…" | Manager, CodebaseLead |
| `sibling_example_parenthetical/0` | "`../tests/auth_tests/` → Authentication test suite (sibling — read-only, escalate writes to parent)" | Manager, CodebaseLead, ContextExtractor |
| **Code quality & file structure** | | |
| `solid_principles_sentence/0` | "Single Responsibility (each file has one reason to change), Low Coupling…" | Manager, CodebaseLead |
| `large_files_intro/0` | "Some files are long for a good reason — generated code, comprehensive test suites…" | Manager, CodebaseLead |
| `large_files_remediation/0` | "leave a short comment at the top of the file explaining its role…" | Manager, CodebaseLead |
| `user_config_specifies_clause/0` | "the user or project config specifies a particular structure, convention, or file organization," | Manager, CodebaseLead |
| `file_structure_expectations_prefix/0` | "file-structure expectations in the objective (e.g., \"keep files under ~1000 lines…" | Manager, CodebaseLead |
| **Context Tree definition** | | |
| `context_tree_definition_clause/0` | "spatial, recursive representation of the codebase structure." | CodebaseLead, ContextExtractor |
| `routing_table_markdown_list_clause/0` | "simple markdown list mapping each area/module/feature to its owning child subdirectory" | CodebaseLead, ContextExtractor |
| `delegate_without_investigating_clause/0` | "where to delegate work without investigating the subtree." | CodebaseLead, ContextExtractor |
| **Shared canonical phrases** | | |
| `standard_sections_enum/0` | "standard sections (Intent, API Surface, Constraints, Routing Table)" | CodebaseLead, CodebaseInvestigator |
| `context_chain_example/0` | "CONTEXT.md chain from `./` → `./src/` → `./src/auth/` → `./src/auth/oauth/`" | Manager, CodebaseLead |
| `genesis_context_header/0` | "# Genesis Context\n\nGenesis models the codebase as a **Context Tree**: …`CONTEXT.md`" | TaskScheduler, GenesisPlanner |
| **Foreign repositories** | | |
| `foreign_repo_absolute_path_clause/0` | "a foreign repository (an absolute path like `/Source/original-proj`)," | CodebaseLead, ContextExtractor |
| `foreign_repo_spawn_right_level/0` | "- **Spawn at the right level**: When you know the foreign repo's structure" | CodebaseLead, ContextExtractor |
| **Objective scope** | | |
| `objective_not_in_node_prefix/0` | "If the objective clearly does not belong to your" | Executor, ContextExtractor |

## Notes for Agents (prompt composition)

- **Prompt boilerplate lives in `prompt_fragments.ex`.** When editing an agent system prompt, update the fragment module — either edit the shared fragment (if the text is shared) or add a new fragment function there. **Never inline copy-paste** prompt boilerplate into an agent module.
- **Extract new shared text** (verbatim, shared by ≥2 prompts) as a new function in `prompt_fragments.ex` with a `@doc` noting which modules use it and any "do NOT merge" warnings.
- **Near-duplicates are deliberate variants** — preserve them as separate functions or leave them inline; never normalize/reword/merge (behavior depends on exact wording).
- **Verification practice (golden dump):** after any prompt change, dump every agent's `system_prompt/0` before and after and diff — outputs must match character-for-character unless a deliberate wording change was made. E.g.:
  ```bash
  mix run --no-start -e 'mods = [EvoGit.Agents.Manager, EvoGit.Agents.Executor, EvoGit.Agents.TaskScheduler, EvoGit.Agents.CodebaseInvestigator, EvoGit.Agents.CodebaseLead, EvoGit.Agents.ContextExtractor, EvoGit.Agents.SkillExtractor, EvoGit.Agents.GenesisPlanner]; File.write!(Path.join(System.fetch_env!("TMPDIR"), "prompts.txt"), Enum.map_join(mods, "\n=====SEP=====\n", fn m -> "#{inspect(m)}\n" <> m.system_prompt() end))'
  ```
- **Fragments carry no trailing newline** — callers add `"\n"` explicitly; a fragment that must end a line without a newline (mid-line composition) is composed with `" "` joiners inline in the caller.
- The guard-check pattern `never include worktree paths|OWN isolated worktree` should match ONLY `prompt_fragments.ex` plus any intentional single-module inline variants (documented in fragment `@doc`s).

## Known Issues
- **Agent reachability mechanism:** an agent type is reachable at runtime ONLY via (a) a root spawn site — `AgentSpec.new(..., Mod, ...)` + `AgentScheduler.run_agent/1` in `runtime/genesis.ex`, `runtime/evolution.ex`, `runtime/skill_extraction.ex`, or `task.ex` — or (b) appearing in a spawned agent's `subagent_modules/0` (tool schemas are generated from that list via `EvoGit.Agent.SubagentSchemas` and resolved by `subagent_tool_name()` match in `tool_dispatch.ex:884-886`). There is NO string-based module resolution (`Module.concat`/`String.to_atom`) for agent types anywhere.

## Constraints
- Every agent module MUST `use EvoGit.Agent` and implement `system_prompt/0`.
- The behaviour module (`EvoGit.Agent`) lives in `../agent.ex`, NOT in this directory.
- Tool modules (`EvoGit.Agent.Tools.*`) live in `../agent/tools/`, NOT in this directory.
- Cross-references between agent types use the `EvoGit.Agents.*` namespace.
- Each agent declares a `delegation_level/0` (`:high` or `:low`) controlling turn-budget warning frequency for delegation reminders. High-level agents (Manager, CodebaseLead, CodebaseInvestigator, GenesisPlanner) receive full delegation guidance. Low-level agents (Executor, TaskScheduler, ContextExtractor, SkillExtractor) receive reduced warnings.
