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
| `EvoGit.Agents.Generalist` | `generalist.ex` | Versatile full-stack agent; delegates investigation and execution | `:read_write` | → CodebaseInvestigator, Executor, self (recursive) | ✅ Full |
| `EvoGit.Agents.Manager` | `manager.ex` | Planning, delegation, validation orchestrator — does NOT implement features directly | `:read_write` | → Manager (self/recursive), Executor, TaskScheduler, CodebaseInvestigator | ✅ Full |
| `EvoGit.Agents.TaskScheduler` | `task_scheduler.ex` | Lightweight task scheduling agent; transforms rough ideas into execution sequences | `:read` | → CodebaseInvestigator | CONTEXT.md only |
| `EvoGit.Agents.Executor` | `executor.ex` | Implements precise, targeted code changes from a specific objective | `:read_write` | → CodebaseInvestigator, self (recursive) | ✅ Full |
| `EvoGit.Agents.CodebaseInvestigator` | `codebase_investigator.ex` | Read-only deep codebase analysis; updates CONTEXT.md | `:read` | → self (recursive) | CONTEXT.md only |
| `EvoGit.Agents.CodebaseArchitect` | `codebase_architect.ex` | Greenfield architecture design; creates project skeletons | `:read_write` | → self (recursive), Generalist | ✅ Full |
| `EvoGit.Agents.ContextExtractor` | `context_extractor.ex` | Extracts semantic context from existing codebases into CONTEXT.md | `:read` | → self (recursive) | CONTEXT.md only |
| `EvoGit.Agents.Evaluator` | `evaluator.ex` | Verifies code changes satisfy objectives via git diff review | `:read` | → CodebaseInvestigator | CONTEXT.md only |
| `EvoGit.Agents.Warnings` | `warnings.ex` | Budget warning thresholds and messages (not an agent; utility module) | N/A | N/A | N/A |

## Constraints
- Every agent module MUST `use EvoGit.Agent` and implement `system_prompt/0`.
- The behaviour module (`EvoGit.Agent`) lives in `../agent.ex`, NOT in this directory.
- Tool modules (`EvoGit.Agent.Tools.*`) live in `../agent/tools/`, NOT in this directory.
- Cross-references between agent types use the `EvoGit.Agents.*` namespace.
