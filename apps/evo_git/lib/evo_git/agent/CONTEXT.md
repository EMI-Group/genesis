# Agent Directory

## Intent
Contains agent implementations and tool definitions for EvoGit's LLM-powered autonomous agents. Each agent is a stateless module that uses `EvoGit.Agent` (defined in `../agent.ex`) and provides a system prompt, optional tool overrides, and subagent delegation configuration. Agents operate within a session loop managed by `EvoGit.AgentScheduler`, reading state from ETS and driving LLM tool-call cycles.

## API Surface

### Tool Library
- **`EvoGit.Agent.Tools`** (`tools.ex`) — Defines 14 LLM tool schemas and dispatch for ReqLLM function calling:
  - File I/O: `read_file`, `read_many_files`, `write_file`, `rewrite_file`, `create_files`, `create_directories`, `replace_in_file`
  - Context Tree: `read_context`, `write_context`
  - Shell & Search: `bash`, `rg`, `git`, `glob`, `list_dir`
  - Key functions: `schemas/0` (all tools), `execute/3` (run tool by name with args and repo path)

### Agent Modules
All agents `use EvoGit.Agent` and implement required callback `system_prompt/0`.

| Module | File | Role | Subagent Delegation | Write Access |
|---|---|---|---|---|
| `EvoGit.Agent.Generalist` | `generalist.ex` | Versatile full-stack agent; delegates investigation to CodebaseInvestigator | → CodebaseInvestigator | ✅ Full |
| `EvoGit.Agent.CodebaseInvestigator` | `codebase_investigator.ex` | Read-only deep codebase analysis; can update CONTEXT.md files | → self (recursive) | CONTEXT.md only |
| `EvoGit.Agent.CodebaseArchitect` | `codebase_architect.ex` | Greenfield architecture design; creates project skeletons and CONTEXT.md hierarchy | → self (recursive) | ✅ Full + shell |
| `EvoGit.Agent.ContextExtractor` | `context_extractor.ex` | Extracts semantic context from existing codebases into CONTEXT.md files | → self (recursive) | CONTEXT.md only |

### Hierarchy Pattern
Agents support recursive subagent delegation. Parent agents define `subagent_modules/0` and `subagent_tool_name/0` / `subagent_tool_description/0` callbacks. The `use EvoGit.Agent` macro automatically injects subagent tool schemas into `available_tools/0` and enforces a max-depth guard (`at_max_depth?/1`) that strips subagent tools when the depth limit is reached.

## Routing Table

The following table maps areas of concern to child node paths, so parent agents know where to spawn subagents:

| Concern / Area | Child Node Path |
|---|---|
| LLM tool implementations (file I/O, git, bash, search, context, etc.) | `tools/` |

When a task involves tool implementation details (tool schemas, execute functions, parameter validation), delegate to `tools/`. All agent behavior modules (Generalist, Manager, Investigator, etc.) live directly in this directory as individual files.

## Constraints
- Every agent module MUST `use EvoGit.Agent` and implement `system_prompt/0`.
- System prompts must NOT contain dynamic state, the objective, or the context tree — those are injected as user prompts by the framework.
- Agents that only read should restrict `available_tools/0` to read-only tools (no `write_file`, `rewrite_file`, `create_files`, `bash`).
- Subagent delegation must commit any pending changes before spawning a child agent.
- Tool schemas use `ReqLLM.tool/2` format — new tools must follow the same `{name, description, parameter_schema, callback}` structure.
- The `complete_task` tool is always injected by the `use EvoGit.Agent` macro; agents need not include it in `available_tools/0`.
