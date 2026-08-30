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
| `run_bash` (Linux/macOS) / `run_powershell` (Windows) | Execute shell commands via `systemd-run` sandbox — effective shell configurable via `[tools] shell` (defaults bash/powershell per platform; posix-shell overrides on Windows supported) | Read/Write | Yes |
| `rg` | Search files with ripgrep patterns | Read | Yes |
| `run_git` | Execute git commands (disabled in schemas) | Read/Write | Yes |
| `glob` | File pattern matching | Read | No |
| `list_dir` | List directory contents | Read | No |
| `search_web` | Web search via configurable provider — Tavily, Perplexity (Sonar), Exa, Bing, or Brave (Tavily by default) | Read | No |
| `search_context` | Search patterns in CONTEXT.md files | Read | Yes |
| `search_history` | Search git commit history | Read | Yes |
| `curl` | HTTP requests via curl (disabled in schemas) | Read | No |
| `complete_task` | Agent completion (injected separately, not in standard schemas) | Special | No |
| `run_command` | Executes a command-string through `EvoGit.CommandShell` — task control, user guides, system info (dispatch-registered ONLY; exposed to the self-reflective agent) | Special | No |
| *(utility)* `Shared` | Argument parsing, path validation, scope checking | — | — |

## Constraints
- All tool execution results must be strings.
- Sandboxed tools use `EvoGit.sandbox_run/4` (`systemd-run`); file tools use Elixir `File` directly.
- All tool outputs are sanitized and truncated by `EvoGit.Agent.OutputSanitizer` (ANSI stripping, progress bar removal, configurable truncation via `[truncation]` config section).
- Tool calls within a batch execute in parallel (`Task.async_stream`, bounded by the scheduler's tool-slot pool `max_tool_concurrency`); parallel committing tools (`write_context`/`edit_context`/`make_dir` with `commit: true`) may contend on git's `index.lock` — lower `max_tool_concurrency` if contention appears.
- `callback` in `ReqLLM.tool()` is always a no-op; real execution goes through `execute`.
- Write tools receive 4 args (including `node_path` for scope); read tools receive 3.
- `Git` and `Curl` schemas are commented out in `schemas/0`; agents use `run_bash` for git operations.
- New tools must: follow module pattern (schema + execute), be aliased in `tools.ex`, have a dispatch clause, and be added to `schemas/0`. **Exception**: `run_command` — the single task-control shell tool — is dispatch-registered ONLY, never added to `schemas/0` or `read_only_schemas/0` (scope/security: giving every coding agent task-control access would be a violation; see "Task Management & Guide Tools" below).

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

### Foreign-Repo Role Write Gating (dispatch + path level)

`EvoGit.Agent.Tools.execute/5` chains two guards before dispatch: (1) the repo-less guard (`maybe_block_repo_less/5` — `Process.get(:repo_less)`), then (2) the **foreign-repo role gate** (`maybe_block_read_only_foreign_repo/5`). The agent's repo role is resolved from `Process.get(:foreign_repos, [])` (populated by `Runner.setup_dispatch_context/1` from `AgentSpec.foreign_repos`; entries normalized via `EvoGit.Core.ForeignRepo.normalize/1` to handle struct AND string-keyed-map shapes from persisted opts) via `:evogit_repo_id` id-match with a `ForeignRepo.resolve_path/2` root-path fallback (agent worktree paths live under `<root>/.genesis/workers/...`, so the prefix-aware path resolution matters). When the agent operates inside a foreign repo whose `writable` is not literally `true`, every `@write_tools` entry is blocked — **`@write_tools` now includes `run_git` and `curl`** (both also blocked by the repo-less guard; safe — neither is in `schemas/0`, both commented out, and neither is in the SelfReflective tool list). Block message: `"Error: this agent operates in a read-only foreign repository (<root>) — the <tool> tool is disabled. Writable foreign repos are the only foreign repos that accept modifications; read-only foreign repos are for investigation only."`. Primary-repo and writable-foreign-repo agents are unaffected (existing behavior).

`Shared.validate_file_scope/3` (`shared.ex`) adds a **path-level defense-in-depth check**: a write target path that resolves (via `ForeignRepo.resolve_path/2` against the same process-dict list) to a read-only foreign repo is rejected with `{:error, "Path '...' is inside a read-only foreign repository ('<root>'). Read-only foreign repos are for investigation only — modifications are not permitted."}` BEFORE the within-repo-root/within-node scope checks run.

**`read_only_schemas/0` no longer includes `Curl.schema()`** (no legitimate read-only role; not in default `schemas/0` either). It KEEPS `Context.write_schema`/`edit_schema` + `ShellTool.schema()` by design: read-only agents (Investigator, ContextExtractor) must keep updating CONTEXT.md in their own repo (documented investigator contract) and run tests/diagnostics (`mix test`); their WRITE usage inside read-only FOREIGN repos is blocked by the role gate instead.

### Configurable shell & redundant nested-shell hint (`shell_tool.ex`)
- The shell tool's effective shell is resolved at runtime by `EvoGit.Platform.shell/0`: the `[tools] shell` config key overrides the platform default (`"bash"` on Linux/macOS, `"powershell"` on Windows). `shell_args/1` chooses the invocation shape from the effective shell — PowerShell executables (`powershell`/`pwsh`) get `-EncodedCommand` args, everything else gets `["-c", command]`. The tool NAME stays compile-time pinned per platform (`run_powershell` on Windows / `run_bash` otherwise) — dispatch clauses, the `@write_tools` block, and tests pin it.
- The tool appends a short hint (💡) when the agent redundantly invokes a nested shell, e.g. a command starting with `/bin/sh -c '...'`, `bash -c '...'`, or a bare `/bin/sh` — the tool already runs the command inside the effective shell. Detection is `ShellTool.detect_redundant_shell/2` (absolute shell paths + bare shell names followed by a `-c`-style flag; legitimate cases like `/bin/bash script.sh` or `sh script.sh` are NOT flagged).

### Main-copy mutation hard block — `cd` into the repo root + mutating git (`shell_tool.ex`)
`do_execute/5` hard-blocks (returns an `"Error: ..."` string BEFORE any execution — no sandbox call) any command that **`cd`s into the repository's MAIN working copy (`repo_root`, `Path.expand`-resolved exactly) AND runs a mutating git subcommand** (`git checkout|switch|reset|merge|pull`, regex `@mutating_git_regex` `\bgit\s+(checkout|switch|reset|merge|pull)\b`). This closes the writable-foreign-repo main-HEAD leak: `cd <foreign_root> && git checkout evogit-agent-T<task>-A<agent>` from inside an agent worktree switches the MAIN copy (cwd outside a registered linked worktree → main tree), moving its HEAD onto the branch before the user merges (review diff goes empty). Semantics:
- Only the exact `repo_root` resolution blocks — `cd` into the agent's own worktree, another agent's worktree under `.genesis/workers/`, or anywhere else never blocks (existing warning behavior applies).
- A mutating git command WITHOUT a cd-into-root (run from the worktree itself) is never blocked.
- `@cd_regex` (shell_tool.ex:30) now matches relative `cd` targets too (`./x`, `../x`, `../../../`, plain `foo`) in addition to absolute `/x`; `cd_targets/2` `Path.expand`s each target against `repo_path` (the worktree cwd) so `cd ../../../` resolves to the repo root. Consumers `detect_cd_warnings/3` + `redundant_cd?/3` compare resolved targets; the cross-worktree warning excludes descendants of the agent's own worktree (a `cd src` inside the worktree is not an escape). Platform-agnostic: the block applies on all platforms; PowerShell `cd`/`Set-Location` syntax is out of scope (the regex targets bash-style command text).

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

The **task system** (`EvoGit.TaskRegistry`), transient **user guides** (PubSub topic `"guides"`), recent-projects inspection, and local platform/system facts are exposed to the self-reflective agent through ONE generic tool: `run_command` (`run_command.ex`). The tool passes a command STRING verbatim to `EvoGit.CommandShell.execute/1` and returns the handler output (or an `Error: ...` string for parse/validation failures). It is dispatch-registered ONLY — a single `execute_tool/5` clause in `tools.ex`, never in `schemas/0` or `read_only_schemas/0` (giving every coding agent task-control access would be a scope/security violation), and deliberately absent from `@write_tools` (a control tool, NOT a write tool — the repo-less guard must not block the self-reflective agent's own task control).

**The 10 former per-function tool modules are now COMMAND HANDLERS**: `ListTasks`, `GetTask`, `StartTask`, `CancelTask`, `ForceKillTask`, `DeleteTask`, `SpawnInvestigator`, `GuideUser`, `ListRecentProjects`, `SystemInfo` keep their `execute/3` functions and are invoked by the shell as `apply(module, :execute, [parsed_args_map, nil, nil])` with a STRING-keyed argument map built from the registry entry's declared arg specs (no per-tool schema, no dispatch clause). They return readable strings and never raise — the task-system calls are wrapped in justified tool-boundary `rescue`/`catch :exit` (TaskRegistry GenServer down → `:noproc` exit; 30s `GenServer.call` timeout) returning `"task system unavailable: ..."` style strings.

**Command catalog** — the declarative compile-time registry lives in `EvoGit.CommandShell` (`apps/evo_git/lib/evo_git/command_shell.ex`):

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
