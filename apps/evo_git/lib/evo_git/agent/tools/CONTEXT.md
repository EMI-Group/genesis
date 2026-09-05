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
| `run_command` | Executes a command-string through `EvoGit.CommandShell` — task control, user guides, system info (dispatch-registered ONLY; exposed to the self-reflective agent). Level-2/3 commands approval-gated via `EvoGit.CommandApproval` | Special | No |
| *(utility)* `Shared` | Designated anti-duplication home for cross-tool helpers — arg parsing/validation, path/scope checking, string edits, plus the consolidated `format_datetime/1`, `truncate/2`, `objective_snippet/2`, `tool_output_limit_description/0`, `describe_error/2` | — | — |

### Tool Schema Shape (ReqLLM.tool/2 conventions in this directory)

Every tool module exposes a schema via a `schema/0` (or `schema/1` — only `WebSearch` has the 1-arity variant, `schema/0` delegates to it with `[]`; `Context` exposes three: `read_schema/0`, `write_schema/0`, `edit_schema/0`). All calls use the same four top-level keyword fields — `name:`, `description:`, `parameter_schema:`, `callback:` — and NO EvoGit tool uses the optional `strict:`/`provider_options:` fields of the `ReqLLM.Tool` struct (deps/req_llm/lib/req_llm/tool.ex:71-79). `parameter_schema` is always a STRING-keyed JSON-Schema map: `%{"type" => "object", "properties" => %{<arg> => %{"type" => ..., "description" => ...}}, "required" => [<args>]}`. Per-property vocabulary actually used: `"type"` (`string`/`integer`/`boolean`/`array`/`object`), `"description"`, `"default"` (declared INSIDE the property map), `"enum"` (`make_dir.ex` `@keep_file_options`, `curl.ex` HTTP methods), `"items"` (`make_dir`/`git`/`ripgrep`/`file_create` array args), `"additionalProperties"` (`curl.ex` headers object). `callback` is always the no-op `fn _ -> {:ok, nil} end` — real execution goes through the module's `execute`. Richest example: `curl.ex:15-67` (6 properties covering string/integer/object/array vocabulary + enum + default); second: `make_dir.ex:13-70` (array + items + enum). `file_read.ex:11-55` shows the standard multi-optional-param shape with defaults. `shell_tool.ex:67-93` builds its description dynamically at schema-build time via `generate_description/0` (platform/config-aware prose).

## Constraints
- All tool execution results must be strings.
- Sandboxed tools use `EvoGit.sandbox_run/4` (`systemd-run`); file tools use Elixir `File` directly.
- All tool outputs are sanitized and truncated by `EvoGit.Agent.OutputSanitizer` (ensure_utf8 → ANSI stripping → progress bar removal → truncation) with an actionable feedback block appended by `EvoGit.Agent.TruncationFeedback`. Truncation thresholds (`[truncation]` config section): `tool_output_max_bytes` = 131072 global ceiling, `tool_output_default_max_bytes` = 16384 for high-output tools, `tool_output_truncate_size` = 8192 keep size; a per-call `max_bytes` tool arg overrides the default but is capped by the global ceiling. On truncation the LLM sees a short factual header (head + tail kept, N bytes omitted, with the remediation "narrow the pattern/path or raise `max_bytes` (up to 131072)") followed by a single concise ⚠️ feedback line. Cuts are UTF-8-boundary-safe (`String.byte_slice/3` + defensive `ensure_utf8`), and the kept-budget clamp avoids head/tail overlap and negative omitted counts when the output exceeds the threshold but is smaller than the keep size (full content retained).
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

### Shared utility helpers (anti-duplication home)

`EvoGit.Agent.Tools.Shared` (`tools/shared.ex`) is the **designated anti-duplication home** for helpers shared across tool modules. It owns the consolidated helpers `format_datetime/1`, `truncate/2`, `objective_snippet/2`, `tool_output_limit_description/0`, and `describe_error/2`, alongside its pre-existing arg-validation / file-scope / string-edit helpers (e.g. `fetch_string_arg/2`, `fetch_array_arg/2`, `validate_file_scope/3`, `do_git_commit/3`). New cross-tool helpers should be added there rather than re-created in individual tool modules.

## Known Issues / Notes for Agents

### Foreign-Repo Role Write Gating (dispatch + path level)

`EvoGit.Agent.Tools.execute/5` chains two guards before dispatch: (1) the repo-less guard (`maybe_block_repo_less/5` — `Process.get(:repo_less)`), then (2) the **foreign-repo role gate** (`maybe_block_read_only_foreign_repo/5`). The agent's repo role is resolved from `Process.get(:foreign_repos, [])` (populated by `Runner.setup_dispatch_context/1` from `AgentSpec.foreign_repos`; entries normalized via `EvoGit.Core.ForeignRepo.normalize/1` to handle struct AND string-keyed-map shapes from persisted opts) via `:evogit_repo_id` id-match with a `ForeignRepo.resolve_path/2` root-path fallback (agent worktree paths live under `<root>/.genesis/workers/...`, so the prefix-aware path resolution matters). When the agent operates inside a foreign repo whose `writable` is not literally `true`, every `@write_tools` entry is blocked — **`@write_tools` now includes `run_git` and `curl`** (both also blocked by the repo-less guard; safe — neither is in `schemas/0`, both commented out, and neither is in the SelfReflective tool list). Block message: `"Error: this agent operates in a read-only foreign repository (<root>) — the <tool> tool is disabled. Writable foreign repos are the only foreign repos that accept modifications; read-only foreign repos are for investigation only."`. Primary-repo and writable-foreign-repo agents are unaffected (existing behavior).

`Shared.validate_file_scope/3` (`shared.ex`) adds a **path-level defense-in-depth check**: a write target path that resolves (via `ForeignRepo.resolve_path/2` against the same process-dict list) to a read-only foreign repo is rejected with `{:error, "Path '...' is inside a read-only foreign repository ('<root>'). Read-only foreign repos are for investigation only — modifications are not permitted."}` BEFORE the within-repo-root/within-node scope checks run.

**`read_only_schemas/0` no longer includes `Curl.schema()`** (no legitimate read-only role; not in default `schemas/0` either). It KEEPS `Context.write_schema`/`edit_schema` + `ShellTool.schema()` by design: read-only agents (Investigator, ContextExtractor) must keep updating CONTEXT.md in their own repo (documented investigator contract) and run tests/diagnostics (`mix test`); their WRITE usage inside read-only FOREIGN repos is blocked by the role gate instead.

### Configurable shell & redundant nested-shell hint (`shell_tool.ex`)
- The shell tool's effective shell is resolved at runtime by `EvoGit.Platform.shell/0`: the `[tools] shell` config key overrides the platform default (`"bash"` on Linux/macOS, `"powershell"` on Windows). `shell_args/1` chooses the invocation shape from the effective shell — PowerShell executables (`powershell`/`pwsh`) get `-EncodedCommand` args, everything else gets `["-c", command]`. The tool NAME stays compile-time pinned per platform (`run_powershell` on Windows / `run_bash` otherwise) — dispatch clauses, the `@write_tools` block, and tests pin it.
- The tool appends a short hint (💡) when the agent redundantly invokes a nested shell, e.g. a command starting with `/bin/sh -c '...'`, `bash -c '...'`, or a bare `/bin/sh` — the tool already runs the command inside the effective shell. Detection is `ShellTool.detect_redundant_shell/2` (absolute shell paths + bare shell names followed by a `-c`-style flag; legitimate cases like `/bin/bash script.sh` or `sh script.sh` are NOT flagged).

### Main-copy mutation hard block — `cd` into the repo root + mutating git (`shell_tool.ex`)
`do_execute/5` hard-blocks (returns an `"Error: ..."` string BEFORE any execution — no sandbox call) any command that **`cd`s into the repository's MAIN working copy (`repo_root`, `EvoGit.Platform.safe_expand`-resolved exactly) AND runs a mutating git subcommand** (`git checkout|switch|reset|merge|pull`, regex `@mutating_git_regex` `\bgit\s+(checkout|switch|reset|merge|pull)\b`). This closes the writable-foreign-repo main-HEAD leak: `cd <foreign_root> && git checkout evogit-agent-T<task>-A<agent>` from inside an agent worktree switches the MAIN copy (cwd outside a registered linked worktree → main tree), moving its HEAD onto the branch before the user merges (review diff goes empty). Semantics:
- Only the exact `repo_root` resolution blocks — `cd` into the agent's own worktree, another agent's worktree under `.genesis/workers/`, or anywhere else never blocks (existing warning behavior applies).
- A mutating git command WITHOUT a cd-into-root (run from the worktree itself) is never blocked.
- `@cd_regex` (shell_tool.ex:30) now matches relative `cd` targets too (`./x`, `../x`, `../../../`, plain `foo`) in addition to absolute `/x`; `cd_targets/2` `EvoGit.Platform.safe_expand`s each target against `repo_path` (the worktree cwd) so `cd ../../../` resolves to the repo root. Consumers `detect_cd_warnings/3` + `redundant_cd?/3` compare resolved targets; the cross-worktree warning excludes descendants of the agent's own worktree (a `cd src` inside the worktree is not an escape). Platform-agnostic: the block applies on all platforms; PowerShell `cd`/`Set-Location` syntax is out of scope (the regex targets bash-style command text).

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

The **task system** (`EvoGit.TaskRegistry`), transient **user guides** (PubSub topic `"guides"`), recent-projects inspection, and local platform/system facts are exposed to the self-reflective agent through ONE generic tool: `run_command` (`run_command.ex`). The tool passes a command STRING verbatim to `EvoGit.CommandShell.execute/1` and returns the handler output (or an `Error: ...` string for parse/validation failures). It is dispatch-registered ONLY — a single `execute_tool/5` clause in `tools.ex`, never in `schemas/0` or `read_only_schemas/0` (giving every coding agent task-control access would be a scope/security violation), and deliberately absent from `@write_tools` (a control tool, NOT a write tool — the repo-less guard must not block the self-reflective agent's own task control). **Approval gate**: registry entries carry `level:` and level-2/3 commands (`GuideUser.guide_user`, `StartTask`/`CancelTask`/`ForceKillTask`/`DeleteTask`) pause inside the shell at the dispatch choke point, awaiting user approval via `EvoGit.CommandApproval.request/5` (blocking; broadcasts on PubSub topic `"approvals"`; bounded window, default 120s via app env `[:evo_git, :command_approval_timeout]`); they run ONLY on `:approved` — denied/timed-out fail closed and the handler never runs. Level-1 commands execute immediately.

**The 10 former per-function tool modules are now COMMAND HANDLERS**: `ListTasks`, `GetTask`, `StartTask`, `CancelTask`, `ForceKillTask`, `DeleteTask`, `SpawnInvestigator`, `GuideUser`, `ListRecentProjects`, `SystemInfo` keep their `execute/3` functions and are invoked by the shell as `apply(module, :execute, [parsed_args_map, nil, nil])` with a STRING-keyed argument map built from the registry entry's declared arg specs (no per-tool schema, no dispatch clause). They return readable strings and never raise — the task-system calls are wrapped in justified tool-boundary `rescue`/`catch :exit` (TaskRegistry GenServer down → `:noproc` exit; 30s `GenServer.call` timeout) returning `"task system unavailable: ..."` style strings.

**Command catalog** — the declarative compile-time registry lives in `EvoGit.CommandShell` (`apps/evo_git/lib/evo_git/command_shell.ex`):

| Command | Level | Args |
|---|---|---|
| `ListTasks.list_tasks` | 1 | optional `statuses=` (comma-separated enum_list: `pending/running/finalizing/completed/failed/cancelled/cancelling`) |
| `GetTask.get_task <task_id>` | 1 | required positional task_id |
| `StartTask.start_task <task_type> [objective] [path= mode= resume_from= starting_commit= model_id=]` | 3 | task_type positional enum `genesis/evolve/reflect/extract_skills`; objective positional optional (default `""`); rest optional kv strings |
| `CancelTask.cancel_task <task_id>` | 3 | required positional |
| `ForceKillTask.force_kill_task <task_id>` | 3 | required positional |
| `DeleteTask.delete_task <task_id>` | 3 | required positional |
| `SpawnInvestigator.spawn_investigator <path> <objective>` | 1 | both required positionals — **v1 placeholder, does NOT spawn** |
| `GuideUser.guide_user <message> [page= selector= dismissible=true\|false]` | 2 | message required positional; page/selector optional kv; dismissible optional bool (default `true`) |
| `ListRecentProjects.list_recent_projects` | 1 | none |
| `SystemInfo.system_info` | 1 | none |
| `help [command]` | 1 | built-in — handled by the shell itself |

Level 1 = safe read-only, executes immediately; level 2 = needs the user's attention; level 3 = real side effects. Level-2/3 commands are approval-gated (see above).

**StartTask gotchas** (`start_task.ex`): the handler forwards `task_type` + `objective/path/mode/resume_from/starting_commit/model_id` (nil and `""` dropped via `maybe_put`) straight to `EvoGit.TaskRegistry.start_task/2` on the LOCAL node. For `:genesis` the positional text is carried under BOTH `:objective` (kept for the shell's own ListTasks/GetTask display) AND `:prompt` (the key `TaskExecutor.execute_task(:genesis)` actually reads) — a shell-started genesis task is no longer silently prompt-less. Still NOT forwarded: `:agent`, `:foreign_repos`, `:archive`, `:build_system`, `:node_path`, `:model_id_locked`, `:merge_from`/`:merge_target`, `:source_root`; undeclared `key=value` tokens fall through as positionals (usually "Too many positional arguments" or swallowed as the objective). Registry `mode` is declared `:string`, NOT an enum — an invalid mode passes the shell gate and raises later inside the spawned `TaskExecutor` (`RuntimeOpts` strict `genesis_mode_atom`/`evolution_mode_atom`), crashing the background task rather than returning a graceful error. A genesis task started WITHOUT `mode=new|existing` still defaults to `"simple"` → `genesis_mode_atom("simple")` raises (pass `mode=new`/`mode=existing` explicitly). `reflect`/`extract_skills` ignore the extra forwarded keys (`extract_skills` requires `path=`; reflect's downstream ignores path/mode/starting_commit).

**Security constraints**: the registry is a compile-time literal — no `Code.eval_string`, no dynamic apply/eval with input-derived names (module/function atoms come only from the literal registry); **no `String.to_atom` on input** — enum/bool/statuses are validated against fixed literal lists and passed through as strings (handlers do their own validated atom conversion); whitelist-only dispatch (unknown command paths rejected); length guardrails `@max_command_length` 4000, `@max_tokens` 40, `@max_token_length` 2000. **Security levels**: each entry carries `level:` (see table above); level-2/3 commands are additionally gated on human approval at the shell's dispatch choke point (`EvoGit.CommandShell.run_command/3` → `EvoGit.CommandApproval.request/5`) — level-1 commands and parse/validation errors bypass the gate. `security_level/1` maps a path string to 1\|2\|3 (`"help"`/`"Help"` → 1; unknown/non-binary → 1).

**HOW TO ADD A NEW COMMAND**: write/point a handler `execute/3` + add ONE registry entry in `EvoGit.CommandShell` (including its `level:`) — no tool schema, no dispatch clause.

### StartTask opt-forwarding surface (shell task-start data plane)

`StartTask.start_task` (registry entry `command_shell.ex:103-123`, handler `start_task.ex`) forwards: `:objective` (positional 2, default `""`), `:path`, `:mode`, `:resume_from`, `:starting_commit`, `:model_id` — all raw strings via `maybe_put` (nil/`""` dropped) — plus, for `:genesis` only, the SAME positional text ALSO under `:prompt` (`start_task.ex:45`: `TaskExecutor.execute_task(:genesis, ...)` reads `opts[:prompt]`, not `:objective`). It calls `EvoGit.TaskRegistry.start_task/2` (`task_registry.ex:55-58` → GenServer `{:start_task, ...}` handler `:316-374`, which validates NOTHING — type/opts forwarded verbatim to `TaskExecutor.execute_task/3`, `task_executor.ex`) — the SAME entry point the CLI (`cli.ex`) and the dashboard use.

**NOT supported (forwarded nowhere — the shell task-start surface is intentionally narrower than the CLI/dashboard callers)**: `:build_system`, `:archive`, `:agent` (agents.toml id — also makes `mode=custom` evolve unusable: `Evolution.run` raises on missing `:agent`), `:foreign_repos`, `:node_path`, `:model_id_locked`, reflect `:source_root`, evolve merge-context `:merge_from`/`:merge_target`, and extract_skills PR-context keys (`:pr_title` … `:user_note`, `:base_sha`, `:commit_sha`). All of the first group ARE consumed downstream by `RuntimeOpts.build_common_runtime_opts` (`runtime_opts.ex:16-66` — `fetch!(:path)` at :17, `mode` default `"simple"` at :18, `mode_atom/2` at :24, `:node_path` :28/56, `:starting_commit` :29/57, `:foreign_repos` :32/58, `:archive` :34/59, `:model_id` :39/60, `:agent` :43/61, `:model_id_locked` :48/62, `:build_system` :52/63).

**Downstream quirks to know** (all crash/raise INSIDE the spawned executor task → task persists `:failed`): (1) `mode` default is `"simple"` → a genesis task started WITHOUT `mode=new|existing` raises `"invalid genesis mode: simple"` (`runtime_opts.ex:18,111-112`); genesis `mode=custom` raises the specific evolve-only error (:97-99); (2) `:path` is optional in the shell but `fetch!`ed by the executor for genesis/evolve/extract_skills (`runtime_opts.ex:17`, `task_executor.ex:67`) — omitting it KeyErrors the task; reflect is the exception (executor bypasses `build_common_runtime_opts` entirely, `task_executor.ex:95-104`); (3) shell `mode` is declared `type: :string` (not an enum) — garbage forwards and crashes downstream; (4) `model_id=` forwards WITHOUT the lock flag — a model-selection script could still override it (dashboard explicit picks and CLI `-m` are implicitly locked via `model_id_locked: true`; see `runtime_opts.ex:45-48`). Test coverage of StartTask exercises reflect only (`test/evo_git/agent/tools/reflect_tools_test.exs` "StartTask" describe — genesis/evolve start paths are untested).
