# EvoGit.Agent.Tools — Tool Definitions & Execution

## Intent
This directory contains all tool definitions and implementations for EvoGit's LLM-powered agents. Each tool is a self-contained Elixir module that defines both a **schema** (for the LLM to understand what the tool does and what parameters it accepts via `ReqLLM.tool/2`) and an **execute** function (the actual implementation). The tools are the primary interface through which agents interact with the filesystem, git, the web, and other system resources.

## API Surface

### Central Dispatcher: `EvoGit.Agent.Tools` (parent `tools.ex`)
| Function | Description |
|----------|-------------|
| `schemas/0` | Returns all active tool schemas for ReqLLM (Git & Curl schemas are commented out) |
| `execute(tool_name, args, repo_path, repo_root \\ nil, node_path \\ nil)` | Dispatches tool execution by name to the appropriate module via pattern-matched private `execute_tool/5` clauses |

### Tool Modules (each in its own file)

| Module | File | Tool Name | Purpose | Type | Uses sandbox_run? | Has scope validation? |
|--------|------|-----------|---------|------|--------------------|-----------------------|
| `FileRead` | `file_read.ex` | `read_file` | Read file contents with line numbers, offset/limit, streaming for large files | Read | No (uses `File.read`/`File.stream!`) | No |
| `FileCreate` | `file_create.ex` | `create_files` | Create empty files with auto-git-commit | Write | No (uses `File.write`, `Git.run`/`Git.commit`) | Yes |
| `FileWrite` | `file_write.ex` | `write_file` | Write/overwrite file contents | Write | No (uses `File.write`) | Yes |
| `FileEdit` | `file_edit.ex` | `edit_file` | Exact string replacement in files (diff-style editing) | Write | No (uses `File.read`/`File.write`) | Yes |
| `MakeDir` | `make_dir.ex` | `make_dir` | Create directories with optional placeholder files (CONTEXT.md/.gitkeep) and auto-commit | Write | No (uses `File.mkdir_p`, `Git.run`/`Git.commit`) | Yes |
| `Context` | `context.ex` | `read_context` / `write_context` | Read/write directory CONTEXT.md files (write auto-commits) | Read/Write | Yes (write only, via `EvoGit.sandbox_run` for git add/commit) | No |
| `ShellTool` | `shell_tool.ex` | `run_bash` (Linux/macOS) / `run_powershell` (Windows) | Execute shell commands via sandboxed `systemd-run`; uses compile-time platform detection for tool name, description, and prompts | Read/Write | Yes (`EvoGit.sandbox_run`) | No |
| `Ripgrep` | `ripgrep.ex` | `rg` | Search files with ripgrep patterns | Read | Yes (`EvoGit.sandbox_run`) | No |
| `Git` | `git.ex` | `run_git` | Execute git commands (**commented out** in `schemas/0`) | Read/Write | Yes (`EvoGit.sandbox_run`) | No |
| `Glob` | `glob.ex` | `glob` | File pattern matching with glob patterns (uses `Path.wildcard`) | Read | No (uses `Path.wildcard`, `File.stat`) | No |
| `ListDirectory` | `list_dir.ex` | `list_dir` | List directory contents (uses `File.ls`) | Read | No (uses `File.ls`) | No |
| `WebSearch` | `web_search.ex` | `search_web` | Web search via Tavily API (requires `TAVILY_API_KEY` env var; uses `Req.post`) | Read | No (uses `Req.post`) | No |
| `SearchContext` | `search_context.ex` | `search_context` | Search patterns in CONTEXT.md files across a node path (wraps ripgrep with `--glob CONTEXT.md`) | Read | Yes (`EvoGit.sandbox_run`) | No |
| `SearchHistory` | `search_history.ex` | `search_history` | Search git commit history by pattern with regex filtering (wraps `git log`) | Read | Yes (`EvoGit.sandbox_run`) | No |
| `Curl` | `curl.ex` | `curl` | HTTP requests via curl (**commented out** in `schemas/0`; uses `System.cmd("curl", ...)`) | Read | No (uses `System.cmd("curl", ...)`) | No |
| `CompleteTask` | `complete_task.ex` | `complete_task` | Agent completion tool — special handling, NOT in standard schemas | Special | No (uses `Git` adapter) | No |
| `Shared` | `shared.ex` | *(utility)* | Shared argument parsing, path validation, scope checking utilities | Utility | N/A | N/A |

### How `EvoGit.sandbox_run/4` Is Called

Defined in `lib/evo_git.ex`. Wraps command execution in `systemd-run` with strict sandboxing (filesystem, CPU, memory, syscall restrictions).

```elixir
# Signature
EvoGit.sandbox_run(cwd, executable, args \\ [], repo_root \\ nil)
# Returns: {output :: String.t(), exit_code :: non_neg_integer()}

# Used in tools:
# ShellTool (uses Platform.shell/0 and Platform.shell_args/1 at runtime):
EvoGit.sandbox_run(repo_path, shell, shell_args, repo_root)

# Ripgrep tool:
EvoGit.sandbox_run(repo_path, "rg", sanitized_args, repo_root)

# Git tool:
EvoGit.sandbox_run(repo_path, "git", sanitized_args, repo_root)

# Context write (for git operations):
EvoGit.sandbox_run(repo_path, "git", ["add", relative_path], repo_root)
EvoGit.sandbox_run(repo_path, "git", ["commit", "-m", msg], repo_root)
```

When `repo_root` is provided, the shared `.git` directory is added as a `ReadWritePath` so worktrees can access the shared git database.

### Tool Schema Pattern (Exact Convention)

Every tool module follows this identical pattern:

```elixir
defmodule EvoGit.Agent.Tools.MyTool do
  @moduledoc """
  Tool for <purpose>.
  """

  alias EvoGit.Agent.Tools.Shared

  @doc """
  Returns the tool schema for ReqLLM.
  """
  def schema do
    ReqLLM.tool(
      name: "tool_name",                          # String identifier used by the LLM
      description: "Human-readable description",  # Can be string or heredoc
      parameter_schema: %{                         # JSON Schema object
        "type" => "object",
        "properties" => %{
          "param_name" => %{
            "type" => "string",
            "description" => "What this param does",
            "default" => "value"                   # Optional default
          }
        },
        "required" => ["param_name"]
      },
      callback: fn _ -> {:ok, nil} end            # ALWAYS a no-op placeholder
    )
  end

  @doc """
  Executes the tool.
  """
  def execute(args, repo_path, _repo_root) do       # Read tools: 3 args
  # OR
  def execute(args, repo_path, _repo_root, node_path \\ nil) do  # Write tools: 4 args
    # Pattern: use Shared.fetch_string_arg / fetch_array_arg to validate args
    # Return a string result (success message or error message)
  end
end
```

Key schema fields:
- **`name`** — String identifier used by the LLM to call the tool
- **`description`** — Detailed instructions for the LLM; can be a string (`<>` concat or plain) or a heredoc `"""`
- **`parameter_schema`** — JSON Schema object defining parameters (types, defaults, descriptions, enum values)
- **`callback`** — Always `fn _ -> {:ok, nil} end` (placeholder; real execution via the module's `execute` function)

### Special Case: ShellTool Module (Compile-Time Platform Adaptation)

The `ShellTool` module uses compile-time module attributes to adapt its tool name, shell identity, and description to the current platform. Key attributes:
- `@os Platform.os()` — compile-time OS detection
- `@tool_name` — `"run_bash"` on Linux/macOS, `"run_powershell"` on Windows
- `@shell_name`, `@shell_flag`, `@tmp_var` — platform-specific strings
- `schema/0` uses these attributes; `execute/3` uses `Platform.shell()` and `Platform.shell_args()` at runtime

### Special Case: Context Module (Two Schemas, One Module)

The `Context` module defines two separate schemas (`read_schema/0` and `write_schema/0`) and two separate execute functions (`execute_read/3` and `execute_write/3`). This is the only module with multiple schemas.

### Special Case: CompleteTask Module

The `CompleteTask` module is NOT included in `Tools.schemas/0`. It is injected separately by the agent framework. It has special methods: `check_workspace_dirty/1`, `complete/4`, `get_agent_metadata/2`. It uses the `Git` adapter directly rather than `sandbox_run`.

## How `Shared` Module Works

### Argument Fetching
```elixir
# Required string arg — returns {:ok, value} or {:error, message}
Shared.fetch_string_arg(args, "file_path")

# Required array arg — validates all elements are strings
Shared.fetch_array_arg(args, "paths")

# Optional string arg — returns {:ok, value} or {:ok, default}
Shared.fetch_optional_string_arg(args, "method", "GET")

# Batch validation — fetches multiple args, calls fun on success
Shared.with_valid_args(args, ["file_path", "content"], fn fetched ->
  # fetched is a map with validated keys
end)
```

### Path Handling
```elixir
# Expands relative path to absolute
Shared.expand_path(file_path, repo_path)  # => Path.expand(file_path, repo_path)

# Normalizes a path to the "./" convention (root is "./")
Shared.normalize_path(path)
# "." → "./", "" → "./", "foo/bar" → "./foo/bar", "./foo/bar" → "./foo/bar"

# Checks if a child path is within or equal to a parent path
# Both paths should be normalized before calling.
Shared.is_child_or_same_node?(parent_path, child_path)
```

### Scope Validation (Write Tools Only)
```elixir
# Validates file is within agent's assigned node_path
Shared.validate_file_scope(expanded_path, node_path, repo_path)
# Returns :ok or {:error, message}
# Returns :ok if node_path is nil (backward compat)
```

### String Utilities
```elixir
Shared.normalize_quotes(str)              # Curly quotes → straight quotes
Shared.find_actual_string(content, search) # Handles quote mismatches for edit_file
Shared.count_occurrences(content, pattern) # Counts pattern occurrences
Shared.to_string_binary(value)            # Converts int/float/atom to string
```

## Execution Flow Summary

1. **Registration**: `Tools.schemas/0` aggregates schemas → injected into agent's `available_tools/0`
2. **Dispatch**: LLM returns tool call → agent loop calls `Tools.execute(tool_name, args, repo_path, repo_root, node_path)`
3. **Pattern match**: `execute_tool/5` dispatches to the correct module's `execute` function
4. **Write tools**: Call `Shared.validate_file_scope/3` to enforce spatial scope
5. **Sandboxed tools**: Call `EvoGit.sandbox_run(repo_path, executable, args, repo_root)` which returns `{output, exit_code}`
6. **Result**: All execute functions return a **string** — either a success message or an error message

## Constraints
- **All tool execution results must be strings** — the agent loop expects string output to send back to the LLM
- **Sandboxed execution** — tools that run external commands (`ShellTool`, `Ripgrep`, `Git`, `Context.write`) use `EvoGit.sandbox_run/4` which wraps in `systemd-run`
- **Direct File/System calls** — tools like `FileRead`, `FileWrite`, `FileEdit`, `Glob`, `ListDirectory` use Elixir's `File` module directly (not sandboxed)
- **Tool output truncation** — outputs exceeding 128 KB are truncated to 8 KB (first/last 4 KB) by the agent loop (outside this directory)
- **Sequential execution** — standard tool calls execute sequentially (not parallel) to avoid git lock conflicts
- **`callback` is always a no-op** — the `callback` field in `ReqLLM.tool()` is never used for actual execution; dispatch goes through `execute` functions
- **Write tools receive `node_path`** — 4-arity execute functions for spatial scope validation; read tools use 3-arity
- **Disabled tools**: `Git.schema()` and `Curl.schema()` are commented out in `Tools.schemas/0`; agents use `run_bash` for git operations instead
- **New tools must**: follow the module pattern (schema + execute), be aliased in `tools.ex`, have a dispatch clause in `execute_tool/5`, and be added to the `schemas/0` list
