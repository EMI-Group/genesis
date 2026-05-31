# EvoGit.Agent.Tools — Tool Definitions & Execution

## Intent
LLM tool definitions and implementations for EvoGit agents. Each tool module defines a schema (via `ReqLLM.tool/2`) and an `execute` function. Tools are the primary interface for agent interaction with the filesystem, git, the web, and system resources.

## Tool Modules

| Tool Name | Purpose | Type | Sandboxed |
|-----------|---------|------|-----------|
| `read_file` | Read file contents with line numbers, offset/limit, streaming | Read | No |
| `create_files` | Create empty files with auto-commit | Write | No |
| `write_file` | Write/overwrite file contents | Write | No |
| `edit_file` | Exact string replacement in files | Write | No |
| `make_dir` | Create directories with placeholder files, auto-commit | Write | No |
| `read_context` / `write_context` / `edit_context` | Read/write/edit CONTEXT.md files | Read/Write | Write only |
| `run_bash` (Linux/macOS) / `run_powershell` (Windows) | Execute shell commands via `systemd-run` sandbox | Read/Write | Yes |
| `rg` | Search files with ripgrep patterns | Read | Yes |
| `run_git` | Execute git commands (disabled in schemas) | Read/Write | Yes |
| `glob` | File pattern matching | Read | No |
| `list_dir` | List directory contents | Read | No |
| `search_web` | Web search via Tavily API | Read | No |
| `search_context` | Search patterns in CONTEXT.md files | Read | Yes |
| `search_history` | Search git commit history | Read | Yes |
| `curl` | HTTP requests via curl (disabled in schemas) | Read | No |
| `complete_task` | Agent completion (injected separately, not in standard schemas) | Special | No |
| *(utility)* `Shared` | Argument parsing, path validation, scope checking | — | — |

## Execution Flow
1. **Registration**: `Tools.schemas/0` aggregates schemas → injected into agent's `available_tools/0`
2. **Dispatch**: Agent loop calls `Tools.execute(tool_name, args, repo_path, repo_root, node_path)`
3. **Pattern match**: Private `execute_tool/5` dispatches to the correct module's `execute` function
4. **Write tools**: Validate spatial scope via `Shared.validate_file_scope/3` before writing
5. **Sandboxed tools**: Call `EvoGit.sandbox_run/4` which wraps commands in `systemd-run`
6. **Result**: All execute functions return a string (success or error message)

## Constraints
- All tool execution results must be strings.
- Sandboxed tools use `EvoGit.sandbox_run/4` (`systemd-run`); file tools use Elixir `File` directly.
- All tool outputs are sanitized and truncated by `EvoGit.Agent.OutputSanitizer` (ANSI stripping, progress bar removal, configurable truncation via `[truncation]` config section).
- Tools execute sequentially to avoid git lock conflicts.
- `callback` in `ReqLLM.tool()` is always a no-op; real execution goes through `execute`.
- Write tools receive 4 args (including `node_path` for scope); read tools receive 3.
- `Git` and `Curl` schemas are commented out in `schemas/0`; agents use `run_bash` for git operations.
- New tools must: follow module pattern (schema + execute), be aliased in `tools.ex`, have a dispatch clause, and be added to `schemas/0`.
