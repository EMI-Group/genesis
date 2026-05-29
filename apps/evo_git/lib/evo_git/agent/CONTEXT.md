# EvoGit Agent Behaviour & Tools

## Intent
Contains the `EvoGit.Agent` behaviour module, its LLM tool definitions, data structs for agent state and results, and extracted helper modules for context compression and subagent processing. Each agent is a stateless Elixir module that `use EvoGit.Agent` and provides a system prompt, optional tool overrides, and subagent delegation configuration. The `use` macro injects the complete agent loop (LLM turn cycle, tool dispatch, subagent management, context compression, budget warnings, and completion).

**Note:** Agent type implementations (Generalist, Manager, Executor, etc.) have been moved to `../agents/`. This directory retains the behaviour module, tool library, data structs, and extracted helper modules.

## Routing Table
- `./tools/` → LLM tool modules (17+ tools for file I/O, context, search, shell, etc.)
- `./context_compression.ex` → Context compression helper (compresses chat history when token threshold exceeded)
- `./subagent_processing.ex` → Subagent call processing (builds specs, spawns subagents, merges results)
- `./loop_state.ex` → `LoopState` struct — agent loop state threaded through every turn
- `./result.ex` → `Result` struct — structured output of a completed agent run

## API Surface

### Data Structs

#### `EvoGit.Agent.LoopState`
The loop state struct threaded through the agent's turn loop. Created once when the agent starts, updated on every turn. Enforced keys: `[:agent_id, :agent_module, :depth, :node_path, :context]`. Remaining fields have defaults: `repo_path` (nil), `turn` (0), `in_grace_period` (false), `deadline` (0), `llm_time_ms` (0), `total_tokens` (0), `last_warned_time_percent` (0), `last_warned_turns_percent` (0). Referenced by `EvoGit.Agent.@type state`.

#### `EvoGit.Agent.Result`
Structured result of a completed agent run, produced by `CompleteTask.complete/4`. Enforced keys: `[:result, :commit_sha]`. Optional fields: `tag`, `branch`, `base_commit`. Constructor: `new/3`. Used throughout runtime modules (Genesis, Evolution) and subagent processing.

### Extracted Helper Modules

#### `EvoGit.Agent.ContextCompression`
- `compress_if_needed/2` — Compresses agent chat context when `total_tokens` exceeds threshold. Takes and returns `LoopState.t()`.

#### `EvoGit.Agent.SubagentProcessing`
- `process_subagent_calls/3` — Spawns subagents, merges results via octopus merge, returns `{indexed_results, merge_message}`. Takes `LoopState.t()` as state param.
- `build_subagent_specs/2` — Builds `AgentSpec` structs from tool calls with cross-repo path resolution
- `resolve_subagent_path/3` — Resolves absolute vs relative paths for cross-repo support
- `process_subagent_result/5` — Processes individual subagent results into indexed tuples
- `format_subagent_result/1` — Formats subagent results for LLM context (pattern matches on `%Result{}`)

### Tool Library (`EvoGit.Agent.Tools`)
- **`tools.ex`** — Central dispatch: `schemas/0` returns 14 LLM tool schemas, `execute/5` dispatches by name
- Available standard tools: `read_file`, `create_files`, `write_file`, `edit_file`, `make_dir`, `read_context`, `write_context`, `run_bash`/`run_powershell`, `rg`, `glob`, `list_dir`, `search_web`, `search_context`, `search_history`
- Commented out (available but not in default set): `run_git`, `curl`
- **`CompleteTask`** (`complete_task.ex`) — Special completion tool; NOT in standard schemas, injected separately by the `use` macro. Returns `%Result{}` struct.

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
- **LoopState discipline**: The agent loop state must always be a `%LoopState{}` struct. All `%{state | ...}` update syntax preserves the struct type.
- **Result discipline**: Agent completion produces `%Result{}` structs. Consumers pattern-match on struct fields rather than using `Map.get/2`.
