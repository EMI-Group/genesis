# EvoGit.Agent.Tools — Tool Definitions & Execution

## Intent
LLM tool definitions and implementations for EvoGit agents. Each tool module defines a schema (via `ReqLLM.tool/2`) and an `execute` function. Tools are the primary interface for agent interaction with the filesystem, git, the web, and system resources.

## Routing Table
- `./skill/` → Skill management tool modules (SkillAdd, SkillEdit, SkillRemove, SkillList, SkillRead)

## API Surface

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
| `search_web` | Web search via configurable provider — Tavily, Perplexity (Sonar), Exa, Bing, or Brave (Tavily by default) | Read | No |
| `search_context` | Search patterns in CONTEXT.md files | Read | Yes |
| `search_history` | Search git commit history | Read | Yes |
| `curl` | HTTP requests via curl (disabled in schemas) | Read | No |
| `complete_task` | Agent completion (injected separately, not in standard schemas) | Special | No |
| *(utility)* `Shared` | Argument parsing, path validation, scope checking | — | — |

## Constraints
- All tool execution results must be strings.
- Sandboxed tools use `EvoGit.sandbox_run/4` (`systemd-run`); file tools use Elixir `File` directly.
- All tool outputs are sanitized and truncated by `EvoGit.Agent.OutputSanitizer` (ANSI stripping, progress bar removal, configurable truncation via `[truncation]` config section).
- Tool calls within a batch execute in parallel (`Task.async_stream`, bounded by the scheduler's tool-slot pool `max_tool_concurrency`); parallel committing tools (`write_context`/`edit_context`/`make_dir` with `commit: true`) may contend on git's `index.lock` — lower `max_tool_concurrency` if contention appears.
- `callback` in `ReqLLM.tool()` is always a no-op; real execution goes through `execute`.
- Write tools receive 4 args (including `node_path` for scope); read tools receive 3.
- `Git` and `Curl` schemas are commented out in `schemas/0`; agents use `run_bash` for git operations.
- New tools must: follow module pattern (schema + execute), be aliased in `tools.ex`, have a dispatch clause, and be added to `schemas/0`. **Exception**: the self-reflective/task-control tools (`list_tasks`, `get_task`, `start_task`, `cancel_task`, `force_kill_task`, `delete_task`, `guide_user`, `subagent_investigator`, `list_recent_projects`, `system_info`) are dispatch-registered ONLY — never added to `schemas/0` (see "Task Management & Guide Tools" below).

## Execution Flow
1. **Registration**: `Tools.schemas/0` aggregates schemas → injected into agent's `available_tools/0`
2. **Dispatch**: Agent loop calls `Tools.execute(tool_name, args, repo_path, repo_root, node_path)`
3. **Pattern match**: Private `execute_tool/5` dispatches to the correct module's `execute` function
4. **Write tools**: Validate spatial scope via `Shared.validate_file_scope/3` before writing
5. **Sandboxed tools**: Call `EvoGit.sandbox_run/4` which wraps commands in `systemd-run`
6. **Result**: All execute functions return a string (success or error message)

### Web Search Providers (provider-adapter architecture)

`WebSearch` (`web_search.ex`) supports five providers — `:tavily`, `:perplexity`, `:exa`, `:bing`, `:brave` — selected via `EvoGit.Config.resolve()` (`[:tools, :search, :provider]`, default `:tavily`; unknown/nil normalizes to `:tavily`). Per-provider request building and response parsing are **pure, I/O-free functions** in `EvoGit.Agent.Tools.WebSearchProviders` (`web_search_providers.ex`): `build_request/5` → `{:ok, %{method: :post \| :get, url:, headers:, body:}}` and `parse_response/2` → `{:ok, %{kind: :results, entries: [%{title, url, content}]}}` (Tavily/Exa/Bing/Brave) or `{:ok, %{kind: :answer, text:, citations:}}` (Perplexity). `WebSearch` itself keeps the schema/validations/API-key resolution and does the real HTTP via `Req`; the HTTP call is routed through the `:web_search_http_runner` app-env test seam (read at call time, default = private Req runner), and `do_web_search/4` is `@doc false` public so execute-level tests can drive the full tail with hardcoded provider maps. The provider list's single source of truth is `EvoGit.Config.Schema.Definitions.search_providers/0` (also used by the schema `in:` validation and config atomization); this module reads the provider atom generically via `EvoGit.Config.resolve()` and needs no per-provider changes beyond a `WebSearchProviders` adapter clause. Param applicability: `search_depth` is Tavily/Exa-only (Exa maps advanced→`type: "neural"`, basic→`"keyword"`); `max_results` is ignored by Perplexity (as is `search_depth`).

## Known Issues / Notes for Agents

### Windows MSYS2 argv quoting — git commit message files (`context.ex`)
`write_context`/`edit_context` commits (`Context.do_context_edit/8` and `Context.do_context_write/6`) run `git commit -F <tempfile>` via the private `Context.commit_with_message_file/3` — **never** `git commit -m <message>` as argv. Content-bearing git args must not be passed as argv elements: git-for-Windows re-tokenizes elements containing double quotes (the `@co_author_trailer` contains `<>`), producing "unknown switch `>'` / "too many arguments" failures under MSYS2.

- The temp message file is written under `EvoGit.Sandbox.resolve_tmpdir()` (NOT `System.tmp_dir!()` — the sandbox profile only grants write access to the resolved dir; `System.tmp_dir!()` may be `/var/folders/...` on macOS, outside the sandbox profile). These calls go through `EvoGit.sandbox_run/4` → sandbox, so the file MUST be sandbox-readable.
- On Windows the temp path is normalized `\` → `/` (`EvoGit.Platform.windows?()` gate; MSYS2 mangles backslashes). Only meaningful on Windows (no sandbox there).
- `try/after` cleans up the temp file (`File.rm` in `after` — no `try/rescue`, no swallowed errors). File-write failure returns `{"Error: could not write temporary commit message file: ...", 1}`.
- Both call sites use `case {output, code}` contracts ("Committed:" success, "Error: git commit failed (exit #{code})" failure).
- Mirrors the adapter pattern (`EvoGit.Adapters.Git.commit/2` temp-file + `-F`; see `adapters/CONTEXT.md` "Windows argv quoting"). A **cross-node shared temp-file helper was deliberately NOT extracted**: the adapter's private `temp_file_path/1` uses `System.tmp_dir!()` (correct for its raw `System.cmd` path but WRONG for sandboxed reads). A future refactor could unify both under `resolve_tmpdir()`.

### Audit: other git/CLI invocations in this node
- `Shared.do_git_commit/3` (`shared.ex:431`) — SAFE: delegates to `EvoGit.Adapters.Git.run(["add" | files])` + `EvoGit.Adapters.Git.commit(repo_path, message)` (the `-F` temp-file form).
- `SearchHistory.do_search` (`search_history.ex:101`) — SAFE: git args are `["log", format, commit_id, "--max-count=N", ...]` — refs/flags only; the `--format` string contains no double quotes; the user pattern is compiled/applied via Elixir `Regex` AFTER the log output is fetched, never passed to git.
- `Git.execute` (`git.ex:67`, run_git tool) — **LATENT AUDIT ITEM**: tool DISABLED (schema commented out in `tools.ex`). When enabled, it passes LLM-derived `sanitized_args` verbatim to `EvoGit.sandbox_run(repo_path, "git", sanitized_args, repo_root)`. `Shared.fetch_array_arg/2` only validates shape (list of strings, JSON-string double-encode recovery) — it does NOT sanitize content, so an LLM-supplied `["commit", "-m", "..."]` with quotes would hit the same MSYS2 bug class. Arbitrary git args cannot be generically `-F`-mapped; a proper fix (if re-enabled) must intercept `-m`/`-F` arguments specifically.
- `rg -n '"-m"'` confirms context.ex is the only module with `-m` argv instances in this node; no other content-bearing argv cases exist (`search_history`/`ripgrep`/`search_context` pass refs/flags/format strings only).

### Task Management & Guide Tools (repo-less "self-reflective" workstream)

Ten additional tool modules live in this directory. They drive the **task system** (`EvoGit.TaskRegistry`), show transient **user guides** (PubSub topic `"guides"`), inspect the user's recent projects, and read local platform/system facts. All follow the standard `schema/0` + `execute/3` pattern, return readable strings, and never raise — the task-system calls are wrapped in justified tool-boundary `rescue`/`catch :exit` (TaskRegistry GenServer down → `:noproc` exit; 30s `GenServer.call` timeout) returning `"task system unavailable: ..."` style strings.

**Registration contract — DISPATCH ONLY, never in `Tools.schemas/0`**: registered in `tools.ex` solely via `execute_tool/5` dispatch clauses (and aliases). Exposed to agents ONLY through the SelfReflective agent's explicit `available_tools/0` list (`EvoGit.Agents.SelfReflective`, `agents/self_reflective.ex`), which references the schema functions directly. Normal coding agents (Manager, Executor, Architect, custom agents, ...) must NOT see these tools. **Critical collision**: `SpawnInvestigator.schema()` declares the name `subagent_investigator` — IDENTICAL to the real subagent tool schema generated by `EvoGit.Agent.SubagentSchemas.schemas/1` for every agent whose `subagent_modules/0` includes `EvoGit.Agents.Investigator` (Manager, Architect, Executor, GenesisPlanner, custom agents). Two tools with the same name in one LLM request → provider 400 ("Tool names must be unique") → every task fails. Never re-add any of these to `schemas/0` (regression-pinned by `tools_test.exs` uniqueness/absence tests).

| Module | Tool | Purpose |
|---|---|---|
| `ListTasks` (`list_tasks.ex`) | `list_tasks` | Optional `statuses` (validated against `pending/running/finalizing/completed/failed/cancelled/cancelling` via a lookup map — never `String.to_atom` on LLM input); calls `TaskRegistry.list_tasks_summary/1`; one line per task (id, status, type, `project_path \|\| "<system>"`, objective snippet, started_at). `opts` comes from the store as a STRING-keyed map — small `objective_from_opts/1` helper checks `"objective"`/`:objective`/keyword forms. |
| `GetTask` (`get_task.ex`) | `get_task` | `TaskRegistry.get_task/1` → `%TaskInfo{} \| nil`; formats id/status/type/objective/times/result. Result formatted defensively (nil / plain string / map with `"result"`/`:result` key), truncated to 2000 chars. |
| `StartTask` (`start_task.ex`) | `start_task` | Validates `task_type` ∈ `genesis/evolve/reflect/extract_skills` (map conversion), builds opts kw list (nil/empty skipped: `objective`, `path`, `mode`, `resume_from`, `starting_commit`, `model_id`), calls `TaskRegistry.start_task/2`. **Return shape (verified)**: `{:ok, %TaskInfo{}}` (NOT a bare id string) \| `{:error, :cancelled}` — success extracts `task.id`. |
| `CancelTask` (`cancel_task.ex`) | `cancel_task` | Graceful `TaskRegistry.cancel_task/1` (`:cancelling` → `:cancelled`, results preserved). |
| `ForceKillTask` (`force_kill_task.ex`) | `force_kill_task` | Brutal `TaskRegistry.force_kill_task/1` (persists `:failed`, progress lost). |
| `DeleteTask` (`delete_task.ex`) | `delete_task` | `TaskRegistry.delete_task/1` (cast — always `:ok`; single-clause error describer). |
| `GuideUser` (`guide_user.ex`) | `guide_user` | Broadcasts `{:guide_updated, id, %{message, page, selector, dismissible}, node()}` on `EvoGit.PubSub` topic `"guides"` via `Phoenix.PubSub.broadcast/3` (repo-wide idiom, cf. system_sampler.ex). Best-effort: broadcast failure (PubSub down) is swallowed with a comment and the confirmation is still returned. |
| `SpawnInvestigator` (`spawn_investigator.ex`) | `subagent_investigator` | **v1 placeholder**: schema copied IDENTICALLY from `EvoGit.Agent.SubagentSchemas` (name/description/parameter_schema with `path`, `objective`, optional `commit_id`) so a real implementation slots in later without schema changes; `execute/3` does NOT spawn — returns a message telling the agent to use its own read-only tools (read_file/read_context/rg/glob/search_context/search_history). Exposed ONLY via the SelfReflective agent's tool list — never via `Tools.schemas/0` (name collision with the real `subagent_investigator` subagent tool). |
| `ListRecentProjects` (`list_recent_projects.ex`) | `list_recent_projects` | Calls `TaskRegistry.list_recent_projects/0` (GenServer.call, live store read); one line per project (`- <name> \| path: <path> \| last opened: <iso>`; nil `name` → path, nil `last_opened_at` → "unknown"); registry-down → `"task system unavailable: ..."` style string; empty → `"No recent projects found."`; no params. |
| `SystemInfo` (`system_info.ex`) | `system_info` | Pure local system facts — OS (`EvoGit.Platform.os/0` + `:os.type()`), architecture (`:erlang.system_info(:system_architecture)`), hostname (best-effort `:inet.gethostname()` → `HOSTNAME` env → `"unknown"`), local wall-clock time + best-effort TZ (`TZ` env, else "server local (TZ unset)"), UTC time, Elixir/OTP versions, data dir (`EvoGit.Platform.data_dir/0`); no params, no side effects; whole body under a tool-boundary `rescue`/`catch` (data_dir can call `System.user_home!()`). |
