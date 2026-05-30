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
| Struct | Purpose |
|---|---|
| `EvoGit.Agent.LoopState` | Agent loop state (enforced keys: `agent_id`, `agent_module`, `depth`, `node_path`, `context`; remaining fields have defaults). Threaded through every turn. |
| `EvoGit.Agent.Result` | Structured result of a completed run (`result`, `commit_sha`; optional `tag`, `branch`, `base_commit`). Produced by `CompleteTask`. |

### Helper Modules
| Module | Purpose |
|---|---|
| `EvoGit.Agent.ContextCompression` | Compresses chat history when `total_tokens` exceeds threshold |
| `EvoGit.Agent.SubagentProcessing` | Spawns subagents, resolves cross-repo paths, merges results via octopus merge, formats results for LLM context |

### Tool Library (`EvoGit.Agent.Tools`)
| Component | Role |
|---|---|
| `tools.ex` | Central dispatch: `schemas/0` returns tool schemas, `execute/5` dispatches by name |
| Standard tools | `read_file`, `create_files`, `write_file`, `edit_file`, `make_dir`, `read_context`, `write_context`, `edit_context`, `run_bash`, `rg`, `glob`, `list_dir`, `search_web`, `search_context`, `search_history` |
| `CompleteTask` | Special completion tool injected by `use` macro; returns `%Result{}` |

## Constraints
- Every agent MUST `use EvoGit.Agent` and implement `system_prompt/0`.
- System prompts MUST NOT contain dynamic state, objectives, or context trees — those are injected as user prompts.
- Read-only agents (`agent_type: :read`) should restrict `available_tools/0` to read-only tools.
- The `complete_task` tool is always injected by the macro; agents need not include it.
- Tool schemas use `ReqLLM.tool/2` format.
- Agents commit before delegating subagents (enforced by auto-commit fallback in scheduler).
- Context compression and subagent processing are extracted to dedicated modules but invoked from the agent loop via callbacks.
- **LoopState discipline**: Agent loop state must always be a `%LoopState{}` struct. Update syntax preserves the struct type.
- **Result discipline**: Agent completion produces `%Result{}` structs. Consumers pattern-match on struct fields rather than using `Map.get/2`.
