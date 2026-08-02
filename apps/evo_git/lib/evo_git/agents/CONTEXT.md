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
| `EvoGit.Agents.Evaluator` | `evaluator.ex` | Verifies code changes satisfy objectives via git diff review | `:read` | → CodebaseInvestigator | CONTEXT.md only |
| `EvoGit.Agents.SkillExtractor` | `skill_extractor.ex` | Analyzes a completed PR and distills reusable knowledge into EvoGit skills | `:read_write` | None (non-recursive) | ✅ Full (`.agents/skills/`) |

## Known Issues
- **⚠️ `EvoGit.Agents.Evaluator` (`evaluator.ex`) is defined but NEVER used at runtime (dead code).** Verified 2026-02 investigation: it is NOT spawned as a root agent by any runtime phase (`runtime/genesis.ex`, `runtime/evolution.ex`, `runtime/skill_extraction.ex`, `task.ex`, `review.ex`, CLI, TaskRegistry — none reference it), and it is NOT in any other agent's `subagent_modules/0` list (Manager `manager.ex:26-33`, CodebaseLead `codebase_lead.ex:29-34`, Executor, GenesisPlanner, TaskScheduler all exclude it). Its tool name `subagent_evaluator` appears nowhere outside its own module; no string-type references (`"evaluator"`) exist anywhere in lib/test/evo_dash. Only references: its own definition, a doc comment in `agent.ex:130`, and this CONTEXT.md. **Why:** commit `98e3fb88` ("Agent: Add a new planner agent...") removed `EvoGit.Agents.Evaluator` from the Planner's (now GenesisPlanner's) `subagent_modules` and removed `subagent_evaluator` from its prompt; no call site has existed since. If an evaluation subagent is ever needed again, it must be added to a spawned agent's `subagent_modules/0` (e.g. Manager's) to become reachable.
- **Agent reachability mechanism:** an agent type is reachable at runtime ONLY via (a) a root spawn site — `AgentSpec.new(..., Mod, ...)` + `AgentScheduler.run_agent/1` in `runtime/genesis.ex`, `runtime/evolution.ex`, `runtime/skill_extraction.ex`, or `task.ex` — or (b) appearing in a spawned agent's `subagent_modules/0` (tool schemas are generated from that list via `EvoGit.Agent.SubagentSchemas` and resolved by `subagent_tool_name()` match in `tool_dispatch.ex:884-886`). There is NO string-based module resolution (`Module.concat`/`String.to_atom`) for agent types anywhere.
- **Stale names in parent CONTEXT.md:** the root `./apps/evo_git/CONTEXT.md` routing table still lists "Investigator, Architect, Extractor" — those map to the current modules `CodebaseInvestigator`, `CodebaseLead`, `ContextExtractor` (all USED). There are no agent modules named `*Investigator`/`*Architect`/`*Extractor` beyond these.

## Constraints
- Every agent module MUST `use EvoGit.Agent` and implement `system_prompt/0`.
- The behaviour module (`EvoGit.Agent`) lives in `../agent.ex`, NOT in this directory.
- Tool modules (`EvoGit.Agent.Tools.*`) live in `../agent/tools/`, NOT in this directory.
- Cross-references between agent types use the `EvoGit.Agents.*` namespace.
- Each agent declares a `delegation_level/0` (`:high` or `:low`) controlling turn-budget warning frequency for delegation reminders. High-level agents (Manager, CodebaseLead, CodebaseInvestigator, GenesisPlanner) receive full delegation guidance. Low-level agents (Executor, TaskScheduler, Evaluator, ContextExtractor, SkillExtractor) receive reduced warnings.
