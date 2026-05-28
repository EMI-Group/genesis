# EvoGit Agent Behaviour & Tools

## Intent
Contains the `EvoGit.Agent` behaviour module, its LLM tool definitions, and extracted helper modules for context compression and subagent processing. Each agent is a stateless Elixir module that `use EvoGit.Agent` and provides a system prompt, optional tool overrides, and subagent delegation configuration. The `use` macro injects the complete agent loop (LLM turn cycle, tool dispatch, subagent management, context compression, budget warnings, and completion).

**Note:** Agent type implementations (Generalist, Manager, Executor, etc.) have been moved to `../agents/`. This directory retains the behaviour module, tool library, and extracted helper modules.

## Routing Table
- `./tools/` → LLM tool modules (17+ tools for file I/O, context, search, shell, etc.)
- `./context_compression.ex` → Context compression helper (compresses chat history when token threshold exceeded)
- `./subagent_processing.ex` → Subagent call processing (builds specs, spawns subagents, merges results)

## API Surface

### Extracted Helper Modules

#### `EvoGit.Agent.ContextCompression`
- `compress_if_needed/2` — Compresses agent chat context when `total_tokens` exceeds threshold
- `format_messages_for_compression/1` — Formats messages into readable text for compression prompt
- `format_single_message/1` — Formats a single message for compression
- `extract_message_content/1` — Extracts text content from message parts

#### `EvoGit.Agent.SubagentProcessing`
- `process_subagent_calls/3` — Spawns subagents, merges results via octopus merge, returns `{indexed_results, merge_message}`
- `build_subagent_specs/2` — Builds `AgentSpec` structs from tool calls with cross-repo path resolution
- `resolve_subagent_path/3` — Resolves absolute vs relative paths for cross-repo support
- `process_subagent_result/5` — Processes individual subagent results into indexed tuples
- `format_subagent_result/1` — Formats subagent results for LLM context

### Tool Library (`EvoGit.Agent.Tools`)
- **`tools.ex`** — Central dispatch: `schemas/0` returns 14 LLM tool schemas, `execute/5` dispatches by name
- Available standard tools: `read_file`, `create_files`, `write_file`, `edit_file`, `make_dir`, `read_context`, `write_context`, `run_bash`/`run_powershell`, `rg`, `glob`, `list_dir`, `search_web`, `search_context`, `search_history`
- Commented out (available but not in default set): `run_git`, `curl`
- **`CompleteTask`** (`complete_task.ex`) — Special completion tool; NOT in standard schemas, injected separately by the `use` macro

### How Tools Are Assigned to Agents
1. Default `available_tools/0` = `EvoGit.Agent.Tools.schemas()` ++ `subagent_schemas()` ++ `[CompleteTask.schema()]`
2. Agents override `available_tools/0` to customize (e.g., `CodebaseInvestigator` removes write tools)
3. `effective_tools/1` strips subagent tools when at max depth
4. The `use` macro makes all callbacks overridable via `defoverridable`

### Subagent Delegation Pattern
- Parent agents declare `subagent_modules/0` → framework auto-generates LLM tool schemas
- Each subagent module provides `subagent_tool_name/0` and `subagent_tool_description/0`
- Subagent schemas have standard parameters: `path` (required), `objective` (required), `commit_id` (optional)
- Spatial contract validation: `:read_write` subagents can only operate on same/child nodes as parent

### Agent Loop Constants (injected by `use EvoGit.Agent`)
- `@max_turns 128` — maximum LLM turn cycles
- `@timeout_ms 30 min` — LLM time budget (wall clock accumulated during LLM calls)
- `@grace_period_ms 3 min` — extra time after limit exceeded for forced completion
- `@default_tool_timeout 10s` — per-tool execution timeout
- `@max_tool_timeout 30 min` — hard cap on any single tool execution
- `@tool_output_max_bytes 128KB` — truncation threshold for tool output
- Budget warnings at 25%, 50%, 80% of time/turn limits

## Constraints
- Every agent MUST `use EvoGit.Agent` and implement `system_prompt/0`.
- System prompts MUST NOT contain dynamic state, objectives, or context trees — those are injected as user prompts.
- Read-only agents (`agent_type: :read`) should restrict `available_tools/0` to read-only tools.
- The `complete_task` tool is always injected by the macro; agents need not include it.
- Tool schemas use `ReqLLM.tool/2` format.
- Agents commit before delegating subagents (enforced by auto-commit fallback in scheduler).
- Context compression and subagent processing are extracted to dedicated modules but invoked from the agent loop via callbacks.
