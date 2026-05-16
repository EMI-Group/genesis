# EvoGit.Agent.Tools — Tool Definitions & Execution

## Intent
This directory contains all tool definitions and implementations for EvoGit's LLM-powered agents. Each tool is a self-contained module that defines both a **schema** (for the LLM to understand what the tool does and what parameters it accepts) and an **execute** function (the actual implementation). The tools are the primary interface through which agents interact with the filesystem, git, the web, and other system resources.

## API Surface

### Central Dispatcher: `EvoGit.Agent.Tools` (parent `tools.ex`)
| Function | Description |
|----------|-------------|
| `schemas/0` | Returns all tool schemas for ReqLLM (excluding `complete_task`) |
| `execute(tool_name, args, repo_path, repo_root, node_path)` | Dispatches tool execution by name to the appropriate module |

### Tool Modules (each in its own file)

| Module | Tool Name | Purpose | Type |
|--------|-----------|---------|------|
| `FileRead` | `read_file` | Read file contents with line numbers, offset/limit, streaming for large files | Read |
| `FileCreate` | `create_files` | Create empty files with auto-git-commit | Write |
| `FileWrite` | `write_file` | Write/overwrite file contents | Write |
| `FileEdit` | `edit_file` | Exact string replacement in files (diff-style editing) | Write |
| `MakeDir` | `make_dir` | Create directories with optional placeholder files (CONTEXT.md/.gitkeep) and auto-commit | Write |
| `Context` | `read_context` / `write_context` | Read/write directory CONTEXT.md files (write auto-commits) | Read/Write |
| `Bash` | `run_bash` | Execute arbitrary bash commands via sandboxed `systemd-run` | Read/Write |
| `Ripgrep` | `rg` | Search files with ripgrep patterns | Read |
| `Git` | `run_git` | Execute git commands (currently **commented out** in `schemas/0`) | Read/Write |
| `Glob` | `glob` | File pattern matching with glob patterns | Read |
| `ListDirectory` | `list_dir` | List directory contents | Read |
| `WebSearch` | `search_web` | Web search via Tavily API (requires `TAVILY_API_KEY` env var) | Read |
| `Curl` | `curl` | HTTP requests via curl (currently **commented out** in `schemas/0`) | Read |
| `CompleteTask` | `complete_task` | Agent completion tool — special handling, NOT in standard schemas | Special |
| `Shared` | *(utility)* | Shared argument parsing, path validation, scope checking utilities | Utility |

### Tool Schema Pattern
Every tool module follows this pattern:

```elixir
defmodule EvoGit.Agent.Tools.MyTool do
  alias EvoGit.Agent.Tools.Shared

  @doc "Returns the tool schema for ReqLLM."
  def schema do
    ReqLLM.tool(
      name: "tool_name",
      description: "Human-readable description for the LLM...",
      parameter_schema: %{
        "type" => "object",
        "properties" => %{ ... },
        "required" => [...]
      },
      callback: fn _ -> {:ok, nil} end   # Placeholder; execution handled separately
    )
  end

  @doc "Executes the tool."
  def execute(args, repo_path, repo_root) do
    # Parse args with Shared helpers, perform operation, return string result
  end
end
```

Key fields in `ReqLLM.tool()`:
- **`name`** — String identifier used by the LLM to call the tool
- **`description`** — Detailed instructions for the LLM on when and how to use the tool
- **`parameter_schema`** — JSON Schema object defining parameters (types, defaults, descriptions)
- **`callback`** — Always `fn _ -> {:ok, nil} end` (placeholder; real execution via `execute/2,3,4`)

### Execution Context Parameters
All tool `execute` functions receive:
- `args` — Map of arguments from the LLM's tool call
- `repo_path` — The worktree working directory path
- `repo_root` — Optional git repository root (for shared `.git` database access in worktrees)
- `node_path` — Optional agent's assigned node path (for spatial scope validation; write tools only)

### Currently Disabled Tools
`Git.schema()` and `Curl.schema()` are commented out in `Tools.schemas/0` — agents use `run_bash` for git operations instead.

## How Tools Are Registered & Used

### Registration Flow
1. **`Tools.schemas/0`** aggregates schemas from all tool modules → returns list of `ReqLLM.tool()` structs
2. **Agent's `available_tools/0`** (in `EvoGit.Agent` `use` macro) combines: `Tools.schemas() ++ subagent_schemas() ++ [CompleteTask.schema()]`
3. Individual agents can override `available_tools/0` to provide a restricted subset (e.g., `CodebaseInvestigator` only has read tools)
4. **`effective_tools/1`** filters out subagent tools when at max recursion depth

### Execution Flow
1. LLM returns tool calls in its response
2. Agent loop (`process_tool_calls/2`) splits them into:
   - **`complete_task`** → special handling (git status check, metadata recording, completion)
   - **Subagent calls** → `AgentScheduler.spawn_sub_agents/1` (creates worktree, runs agent)
   - **Standard tool calls** → `Tools.execute(tool_name, args, repo_path, repo_root, node_path)` → dispatches to module's `execute` function
3. Results are returned as `tool_result(id, name, output)` messages appended to the LLM context

### Spatial Scope Validation
Write tools (`FileCreate`, `FileWrite`, `FileEdit`, `MakeDir`) call `Shared.validate_file_scope/3` which ensures the target path is within the agent's assigned `node_path`. Read tools do not perform this check.

## Constraints
- **All tool execution results must be strings** — the agent loop expects string output to send back to the LLM
- **Sandboxed execution** — tools that run external commands (`Bash`, `Ripgrep`, `Git`, `Context.write`) use `EvoGit.sandbox_run/4` which wraps commands in `systemd-run` with filesystem/CPU/memory restrictions
- **Tool output truncation** — outputs exceeding 128 KB are truncated to 8 KB (first/last 4 KB) by the agent loop
- **Sequential execution** — standard tool calls execute sequentially (not in parallel) to avoid git lock conflicts
- **`callback` is unused** — the `callback` field in `ReqLLM.tool()` is always a no-op placeholder; actual execution goes through the module's `execute` function
- **Subagent tools are dynamically generated** — each agent's `subagent_modules/0` drives schema generation and dispatch via `subagent_schemas/0` and `subagent_module_for/1`
