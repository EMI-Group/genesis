# EvoGit.Agent.Tools — Tool Definitions & Execution

## Intent
LLM tool definitions and implementations for EvoGit agents: each module declares a schema (`ReqLLM.tool/2`) and an `execute` function covering the filesystem, git, the web and system resources.

## Routing Table
- `./skill/` → skill tool modules (SkillAdd, SkillEdit, SkillRemove, SkillList, SkillRead) — detail `skill/CONTEXT.md`
- `./lsp/` → `EvoGit.Agent.Tools.Lsp.Protocol`, the PURE LSP wire codec (Content-Length framing, JSON-RPC encode, incremental `decode/1`, `file://` URIs, diagnostics/hover/definition normalization; no I/O, ports or processes) — detail `lsp/CONTEXT.md`

## API Surface

| Tool Name | Purpose | Type | Sandboxed |
|-----------|---------|------|-----------|
| `read` | File contents with line numbers, offset/limit, streaming | Read | No |
| `create_files` | Create empty files, auto-commit | Write | No |
| `write` | Write/overwrite file contents | Write | No |
| `edit` | Exact string replacement | Write | No |
| `make_dir` | Create directories with placeholder files, auto-commit | Write | No |
| `read_context` / `write_context` / `edit_context` | CONTEXT.md read/write/edit (reads unrestricted, writes node-scope-checked) | Read/Write | Write only |
| `bash` | Shell command in the sandbox — effective shell from `[tools] shell` (platform default bash/powershell, posix-shell overrides on Windows); `run_in_background: true` starts a background job | Read/Write | Yes |
| `rg` | ripgrep pattern search | Read | Yes |
| `run_git` | git commands (schema disabled) | Read/Write | Yes |
| `glob` | File pattern matching | Read | No |
| `list_dir` | Directory listing | Read | No |
| `web_search` | Provider-backed web search — Tavily (default), Perplexity (Sonar), Exa, Bing, Brave | Read | No |
| `web_fetch` | ONE HTTP(S) GET → readable Markdown (HTML via pure `HtmlToMarkdown`, text/JSON/XML/CSV verbatim, other binaries omitted); ≤5 same-host/same-scheme redirects, best-effort private-host gate, no JS/cookies/logins | Read | No |
| `lsp` | Language-server code intelligence — `action` ∈ `diagnostics`/`hover`/`definition`, 1-based `line`/`column`, `path` inside the repo; SCHEMA-GATED on `EvoGit.Config.lsp_enabled?/0` (`[lsp] enabled = true` + non-empty `command`), so absent by default while dispatch stays registered | Read | No |
| `search_context` | Search patterns in CONTEXT.md files | Read | Yes |
| `search_history` | Search git commit history | Read | Yes |
| `complete_task` | Agent completion (injected separately, not in the standard schemas) | Special | No |
| `run_command` | Command STRING through `EvoGit.CommandShell` — task control, user guides, system info (dispatch-registered ONLY; self-reflective agent); level-2/3 commands approval-gated via `EvoGit.CommandApproval` | Special | No |
| `job_output` | A background job's delta since the previous read + current status (optional bounded `wait`) | Control | No |
| `job_list` | This agent's background jobs with ids and statuses | Control | No |
| `job_kill` | Request cancellation of a running background job | Control | No |
| *(utility)* `Shared` | Anti-duplication home for cross-tool helpers: arg parsing/validation, path/scope checks, string edits, the single `commit_files/4` stage+commit helper (+ `validate_commit/1`, `maybe_commit_result/6`), `format_datetime/1`, `truncate/2`, `objective_snippet/2`, `tool_output_limit_description/0`, `describe_error/2` | — | — |

MODEL-FACING names differ from the INTERNAL dispatch keys `execute_tool/5` matches: `read`/`write`/`edit`/`bash`/`web_search` vs `read_file`/`write_file`/`edit_file`/`run_bash` (or `run_powershell`)/`search_web`, while `rg` and `glob` keep their names on both sides; `EvoGit.Agent.ToolNames` (`../tool_names.ex`) is the alias spine (`normalize/1`, `model_name/1`, `shell_tool_name/0`, `matches_any?/2`).

### Tool Schema Shape (`ReqLLM.tool/2`)

- `schema/0` everywhere; `WebSearch` also exposes `schema/1` (`schema/0` delegates with `[]`), and `Context` exposes `read_schema/0`, `write_schema/0`, `edit_schema/0`.
- Every call uses the same four fields — `name:`, `description:`, `parameter_schema:`, `callback:` — and no tool uses the optional `strict:`/`provider_options:`; `callback` is always the no-op `fn _ -> {:ok, nil} end` (real execution goes through `execute`).
- `parameter_schema` is a STRING-keyed JSON-Schema map with `"type" => "object"`, `"properties"` and `"required"`; property vocabulary: `type` (`string`/`integer`/`boolean`/`array` — `object` only as the top-level type), `description`, `default` (inside the property map), `enum` (`make_dir` keep-file options, `lsp` actions — the only two) and `items` (string arrays in `make_dir`, `git`, `ripgrep`, `file_create`); no tool declares `additionalProperties`.
- Descriptions may be built at schema-build time (`shell_tool` `generate_description/0`, platform/config-aware).

## Constraints
- Result contract: `String.t() | %EvoGit.Agent.ToolOutput{} | {:error, reason}`; built-ins return strings, and media rides `%ToolOutput{}` through the `EvoGit.Agent.ToolDispatch` wrap boundary (`../CONTEXT.md` → "Multimodal Tool Outputs") while every guard path stays binary.
- Sandboxed tools run via `EvoGit.sandbox_run/4`; file tools use `File` directly.
- Every output passes `EvoGit.Agent.OutputSanitizer` (ensure_utf8 → ANSI strip → progress bars → truncation) plus a `TruncationFeedback` block; `[truncation]` keys: `tool_output_max_bytes` 131072 (ceiling), `tool_output_default_max_bytes` 16384 (high-output tools), `tool_output_truncate_size` 8192 (keep size) — a per-call `max_bytes` overrides the default but never the ceiling.
- Truncation keeps head+tail, reports the omitted byte count with "narrow the pattern/path or raise `max_bytes` (up to 131072)" and one ⚠️ line, cuts on UTF-8 boundaries, and clamps the keep budget (head/tail never overlap; output between threshold and keep size survives whole).
- Batches split on `Tools.serial_tool?/1`: the file-mutating subset runs SEQUENTIALLY in the parent agent process, the rest in parallel (`Task.async_stream`, bounded by `max_tool_concurrency`); concurrent shell/git calls can still contend on git's `index.lock`.
- Write tools get 4 args (incl. `node_path`), read tools 3.
- `run_git`'s schema is commented out of `schemas/0`; agents use `bash` for git.
- New tool = module (schema + execute) + alias + dispatch clause + `schemas/0` entry.
- Exceptions: `run_command` and user-defined custom tools dispatch through their own clause / the `execute_tool/5` catch-all only, never in `schemas/0` or `read_only_schemas/0`, and are opt-in per agent `available_tools/0`.

## Execution Flow
1. `Tools.schemas/0` aggregates schemas into the agent's `available_tools/0`.
2. `Tools.execute(tool_name, args, repo_path, repo_root, node_path)` normalizes the model-facing name FIRST via `EvoGit.Agent.ToolNames.normalize/1`: catalog spellings and their `*_file`/`search_web` aliases map to internal keys, and every shell spelling (`bash`/`shell`/`sh`/`execute_bash`/`bash_command`/`run_shell`/`shell_command`/`run_bash`/`run_powershell`, case-insensitive) maps to the compile-time `@shell_tool_name`; unknown names pass through (custom tools, dynamic skills).
3. Private `execute_tool/5` pattern-matches to the module's `execute`.
4. Write tools verify `Shared.validate_file_scope/4` (CONTEXT.md writers pass `format_context_scope_error/2`) before writing.
5. Sandboxed tools call `EvoGit.sandbox_run/4`.
6. Result: string | `{:error, reason}` (dispatcher renders `"Error: …"`) | `%ToolOutput{}`; an unknown name falls to the catch-all → custom tool (`EvoGit.CustomTools.execute/3`, `:unknown` continues) → dynamic skill → `"Error: Unknown tool '<name>'. Did you mean '<closest>'? Available tools: ..."`, with names derived from `schemas/0` at runtime and the suggestion being the nearest `String.jaro_distance/2` ≥ 0.7 (`run_command` absent, `run_git` excluded).

Normalization precedes the write guards: `run_bash`/`run_powershell` are write tools, so late normalization would let a repo-less or read-only-foreign-repo agent write via "Bash".
Custom tools must return a string (`{:error, "… returned a non-string value…"}` otherwise).

### Web Search Providers
- `WebSearch` supports `:tavily` (default), `:perplexity`, `:exa`, `:bing`, `:brave` from `[:tools, :search, :provider]` (unknown/nil → `:tavily`); `EvoGit.Config.Schema.Definitions.search_providers/0` is the single source of truth (also used by schema `in:` validation and config atomization).
- Pure, I/O-free adapters live in `EvoGit.Agent.Tools.WebSearchProviders`: `build_request/5` → `{:ok, %{method: :post | :get, url:, headers:, body:}}`; `parse_response/2` → `{:ok, %{kind: :results, entries: [%{title, url, content}]}}` (Tavily/Exa/Bing/Brave) or `{:ok, %{kind: :answer, text:, citations:}}` (Perplexity).
- `WebSearch` owns schema/validation/API keys and the `Req` call, routed through the `:web_search_http_runner` app-env seam (call-time; default private runner); `do_web_search/4` is `@doc false` public for execute-level tests.
- `search_depth` is Tavily/Exa-only (Exa maps advanced→`type: "neural"`, basic→`"keyword"`); Perplexity ignores `max_results` and `search_depth`.

### Web Fetch (`web_fetch`)
- READ-ONLY page reader (ONE GET → Markdown) in both schema lists, never a write tool, not serial, and not schema-gated.
- Params: `url` (required, absolute, http/https), `max_chars` (integer, default 200_000, 100..2_000_000), `timeout` (integer, default 30_000 ms, 50..600_000 — a WHOLE-request budget spanning every hop); retries disabled.
- The streamed body halts at `raw_cap = clamp(max_chars * 8, 512 KiB, 16 MiB)`; `execute/3` validates args then hops, converting unexpected crashes to `Failure.error("web_fetch failed unexpectedly: …")`.
- Rendering: `"Fetched <url> (HTTP <code>)\n\n<text>"` plus `"[truncated: the response body exceeded the <N>-byte fetch limit]"` or `"[truncated: first N of ~M characters]"`.
- Content: HTML types (`text/html`, `application/xhtml+xml`, `application/xhtml`, `text/xhtml`) → Markdown via pure `HtmlToMarkdown` (relative `href`/`src` resolved against the FINAL url); JSON/XML/NDJSON/JSON-LD/problem-JSON/JS/TOML/YAML/CSV/GraphQL and `+json`/`+xml` verbatim; anything else → `"[binary content omitted: <label>]"`.
- Non-2xx → `Failure.error("<url> returned HTTP <code><reason phrase>")`; 301/302/303/307/308 are followed manually (`redirect: false`), at most 5 hops (the 6th errors), SAME host + scheme (port may change), relative `Location` via `URI.merge/2`.
- Private-host gate is BEST EFFORT, explicitly not a security boundary: it resolves `:inet`/`:inet6` and refuses non-public addresses (IPv4 loopback/private/link-local incl. `169.254/16`, CGNAT, `0/8`, multicast; IPv6 loopback/unspecified/ULA/link-local/multicast and IPv4-mapped) plus `localhost`/`*.localhost`; the request is issued by NAME (no IP pinning), so DNS rebinding and hostile relays are out of scope.
- Client is `Req` with a streaming `into:` callback (never a shelled-out client); test seam `:web_fetch_allow_private_hosts` (default `false`, call-time) skips the host gate.

### Language Server (`lsp`)
- READ-ONLY code intelligence over ONE user-configured server (nothing bundled or left running); never a write tool, not serial.
- The schema is appended LAST to both schema lists by `maybe_append_lsp/1` only when `EvoGit.Config.lsp_enabled?/0` is true (`[lsp] enabled = true` + non-empty `command`) — absent by default, with the dispatch clause permanently registered.
- Params: `action` (required enum `diagnostics`/`hover`/`definition`), `path` (required, absolute or repo-relative, must resolve inside `repo_path`/`repo_root` via `EvoGit.Platform.path_under?/2`), `line`/`column` (1-based; required for hover/definition, ignored for diagnostics, converted to LSP's 0-based coordinates at the request boundary).
- Config `[lsp]`: `enabled`, `command`, `args`, `timeout`, `diagnostics_timeout`; the command resolves via `EvoGit.Executable.resolve/1` then `System.find_executable/1`. Not enabled or blank command → exactly `Error: no language server configured — set [lsp] command in config.toml` (the same conditions gate the schema, so this is defence-in-depth). Malformed values normalize silently (non-map → `%{}`, non-list `args` → `[]`, bad timeouts → defaults).
- ONE server, hardcoded Elixir: `open_document/2` always sends `languageId: "elixir"` and `initialize/2` roots at `repo_root` — no per-language registry, built-in defaults, extension mapping or root markers, so non-Elixir files are analysed as Elixir.
- Per call: spawn on stdio → one handshake (`initialize` → `initialized` → `textDocument/didOpen`) → at most one request → teardown; request ids are fixed (1..4).
- `diagnostics` collects `textDocument/publishDiagnostics` until quiet for `settle_ms` (default 500) or budget expiry, rendering `<path> — <N> diagnostic(s):` plus `<path>:<line>:<col> <severity> <message>` lines (`"No diagnostics for <path>."`, `"...[truncated at 100 diagnostics]"` past the line cap); `hover` renders `Protocol.hover_text/1`; `definition` renders `<path>:<line>:<col>` per `Protocol.locations/1`.
- Bounds: file ≤ 2 MiB (rejected before `didOpen`), 4 MiB frame buffer, 30 s total / 10 s diagnostics timeouts (configurable), 100 lines and 8 000 chars of output, 2 048-byte stderr; every `receive` is bounded.
- Teardown always runs: `didClose` → `shutdown` → `exit` → SIGKILL by OS pid → drain port → idempotent `close_port/1` → stderr file removal; nothing survives the call.
- Framing/URI/result helpers are the pure sibling `EvoGit.Agent.Tools.Lsp.Protocol` (`lsp/protocol.ex`) — detail `lsp/CONTEXT.md`; test seam `execute/4` accepts `:enabled`/`:command`/`:args`/`:timeout`/`:diagnostics_timeout`/`:settle_ms` (`execute/3` delegates `[]`), exercised by `EvoGit.FakeLspServer` (`test/support/fake_lsp_server.ex`, packed once per test module into an `escript` so each spawn is a real child at bare-Erlang boot cost).
- Gotchas: (1) the dispatcher's generic timeout (10 s default — `default_timeout_ms("lsp")` is `nil`) under-cuts the tool's 30 s default, and that external shutdown skips teardown (the port dies with the process, giving stdin EOF); (2) any readable UTF-8 file ≤ 2 MiB is analysed as Elixir; (3) server→client requests are never answered (`initialize` advertises `{}` capabilities, unmatched ids dropped), so such a server dies on timeout; (4) a silent server renders `No diagnostics for <path>.` rather than an error; (5) `lsp` reaches `schemas/0` agents (Manager, Executor, Architect, TaskScheduler, GenesisPlanner, SkillExtractor, `Agents.Custom` without a whitelist) and `read_only_schemas/0` agents (Investigator, ContextExtractor) only when enabled, and `Agents.SelfReflective` never lists it; (6) the model-facing name equals the dispatch key (no alias entry); (7) it is a `@high_output_tools` member (smaller truncation cap, though the 8 000-char cap usually binds first).

### Shared utility helpers (anti-duplication home)
`EvoGit.Agent.Tools.Shared` owns every cross-tool helper listed in the API-surface row above (datetime formatting, truncation, objective snippets, error description, arg validation, scope checks and the commit glue); new cross-tool helpers belong there.

### rg output conventions
`bare_args?/1` decides the shape: BARE args (`PATTERN [PATH ...]`) get `--line-number` + `--no-heading` injected and a 250-line cap with a narrowing footer; an EXPLICIT flag set (`-l`, `-c`, `--json`, `-A/-B/-C`, `-e`/`-f`) passes VERBATIM under the legacy `Command executed successfully.\nOutput:\n<raw>` envelope. Errors become prose with advisory tips (`build_hint/1`).

### String-replace semantics (`edit` / `edit_context`)
`Shared.perform_string_replace/5` + `apply_string_edit/4`: `new_string` is inserted VERBATIM (whitespace and newline state preserved) and matching is byte-exact after smart-quote normalization (`find_actual_string/2`), so CRLF files never match. Messages: `"Error: Found N matches of old_string in file. Set replace_all=true or provide more context."` and `"Error: old_string not found in file <display_path>"`.

### Per-Tool Path Handling (scope, sandbox, TMPDIR)
- Six tools scope-check via `Shared.validate_file_scope/4`: `write`, `edit`, `create_files`, `make_dir`, `write_context`, `edit_context`.
- The CONTEXT.md writers pass the target DIRECTORY plus `format_context_scope_error/2` and check BEFORE any filesystem change (mkdir/existence check, read/replace, commit), so an out-of-node call changes nothing.
- No other tool scope-checks: `read`, `glob`, `list_dir`, `bash`, `rg`, `run_git`, `search_context`, `search_history`.
- Check order: (1) read-only foreign repo; (2) inside `repo_path` (anything outside the repo root, `/tmp/...` included, is rejected); (3) inside `node_path` (caller formatter, default `format_scope_error/2`); there is NO tmp-dir or arbitrary-path allowance. A `nil` node path is ALLOW-ALL (skips all three) — unreachable from the agent loop (enforced non-nil binary) and kept for direct/unit callers.
- Node ownership: `"./"` (root) owns the whole repo; any other node owns itself and its descendants.
- Both formatters are PUBLIC so callers and tests pin the teaching text: file target (`format_scope_error/2`) vs CONTEXT.md directory target (names the target, says the owning agent or its parent must update it, and that the finding belongs in the caller's report).
- `Shared.expand_path/2` → `Platform.safe_expand/2` returns ABSOLUTE inputs unchanged (never anchored under `repo_path`), so `read`/`list_dir`/`glob`/`read_context` can read `/tmp/...` or `/etc/...`, and `rg`/`search_context` pass args verbatim (arbitrary roots, sandbox-read-permitting).
- Shell commands run through `EvoGit.Sandbox.run_with_partial/7` (the timeout variant, not `EvoGit.sandbox_run/4`); both use `EvoGit.Sandbox.backend()`.
- Every shell path gets `TMPDIR = EvoGit.Sandbox.resolve_tmpdir/0`: sandboxed → backend injection (systemd `--setenv=TMPDIR`, bwrap `--setenv TMPDIR`, macOS `env:`); non-sandboxed/Windows → `TMPDIR`/`TMP`/`TEMP` via `Sandbox.Helpers.temp_env_vars/0` (system tmp dirs stay writable).
- `resolve_tmpdir/0` prefers the managed per-task dir installed on the calling process (`TaskTmpdir.current/0`, set by the runner and re-installed inside every spawned tool task) and returns it directly; otherwise it keeps `$TMPDIR` when it exists under `Platform.tmp_paths/0` (`/tmp`, `/var/tmp`; `System.tmp_dir!()` on Windows) and otherwise takes the first entry.
- Shell schema text: `$TMPDIR` (POSIX) / `$env:TEMP` (PowerShell), with "Always use $TMPDIR for temporary files, never /tmp." on POSIX.
- `resolve_tmpdir/0` appears in exactly ONE tool module — `shared.ex` (the commit-message temp file, removed in `try/after`); no tool module uses `System.tmp_dir!/0`.

### Foreign-Repo Role Write Gating (dispatch + path level)
- `Tools.execute/5` chains two guards before dispatch: repo-less (`Process.get(:repo_less)`) and the foreign-repo role gate.
- Role resolution: `Process.get(:foreign_repos, [])` (set by `Runner.setup_dispatch_context/1` from `AgentSpec.foreign_repos`, normalized via `EvoGit.Core.ForeignRepo.normalize/1` for struct/string-keyed shapes) matched by `:evogit_repo_id`, with a `ForeignRepo.resolve_path/2` path fallback because worktrees live under `<root>/.genesis/workers/...`.
- In a foreign repo whose `writable` is not literally `true`, every write tool (`write_tool?/1` = `@write_tools` OR `EvoGit.CustomTools.write_tool?/1`) is blocked with `"Error: this agent operates in a read-only foreign repository (<root>) — the <tool> tool is disabled. Writable foreign repos are the only foreign repos that accept modifications; read-only foreign repos are for investigation only."`
- `@write_tools` = `create_files`, `write`/`write_file`, `edit`/`edit_file`, `bash`/`run_bash`/`run_powershell`, `make_dir`, `write_context`/`edit_context`, `run_git` (schema-less, blocked as defence-in-depth and absent from the SelfReflective list) and the five skill writers.
- Path-level defence: `Shared.validate_file_scope/4` rejects a target resolving into a read-only foreign repo with `"Path '...' is inside a read-only foreign repository ('<root>')…"` before the scope checks.
- `read_only_schemas/0` = read tools + `Context` write/edit + `ShellTool` + `WebFetch` (always) + `Lsp` (gated): read-only agents must still update CONTEXT.md in their own repo and run tests, while writes inside read-only FOREIGN repos are blocked by the role gate.

### Write-Tool Classification & Serial Tools
- `tools.ex` owns the semantics: `@write_tools`, the private `write_tool?/1` (= `@write_tools` OR `EvoGit.CustomTools.write_tool?/1`, used by both gates) and the public `serial_tool?/1`.
- `serial_tool?/1` marks non-atomic read-modify-write callers that must never overlap in one batch (each would read the original bytes, and only the last write would survive while all report success). It is derived by subtraction — `@serial_tools = @write_tools -- ["run_bash", "run_powershell", "run_git", "bash"]` — giving `create_files`, `write`/`write_file`, `edit`/`edit_file`, `make_dir`, `write_context`, `edit_context`, `skill_add`, `skill_edit`, `skill_remove`, `skill_enable`, `skill_disable`.
- The shell/exec tools are excluded (opaque whole commands, legitimately concurrent); a custom tool declaring itself a write tool IS serial (conservative).
- Everything else returns `false`: `read`, `read_context`, `glob`, `list_dir`, `rg`, `search_context`, `search_history`, `skill_list`, `skill_read`, `skill_where`, `web_fetch`, `lsp` (when offered), `run_command`, `web_search`, unknown names.
- Control tools `job_output`/`job_list`/`job_kill` sit in BOTH schema lists and are neither write nor serial; a background `bash` start is gated exactly like a write tool (`run_in_background` never bypasses the guards) while `bash` stays in `@write_tools` and out of `@serial_tools`.
- Consumer: `ToolDispatch.batch_execute_tools/4` runs the serial subset first, sequentially, in request order, in the parent agent process (`../CONTEXT.md` "Standard tool call execution").

### Commit Semantics
**ONE helper: `Shared.commit_files/4`** (`(repo_path, repo_root, files, message) -> {:ok, output} | {:error, message}`).
- It stages ONLY the passed paths (`EvoGit.sandbox_run(repo_path, "git", ["add" | paths], repo_root)`) — never `git add --all`.
- It commits with `git commit -F <tmpfile>` on the same sandbox path; the co-author trailer is appended only when `[:git, :co_authored_by_enabled]` is not `false` (never a hardcoded user), and the message always rides a file, never `-m` argv.
- `{:ok, output}` is the concatenated add+commit output; `{:error, message}` is `"Error: git add failed (exit N): …"` / `"Error: git commit failed (exit N): …"`.
- Graceful no-ops: an empty file list returns `{:ok, "No files to commit"}` with no git call, and nothing staged returns `{:ok, output}`. Recognition uses git's exit-1 `@nothing_to_commit_markers` wordings ("nothing to commit, working tree clean", "nothing added to commit", "no changes added to commit") and is locale-stable thanks to `LC_ALL=C`.

Tools that commit their own write:
- `create_files` stages exactly the LLM-supplied paths (a new untracked ancestor directory, or a path tracked in a parent/spatial node, is not staged).
- `make_dir` stages only the keep-files it created (`keep_file: "none"` → no commit).
- `write_context`/`edit_context` stage their own CONTEXT.md, append `"\n\nCommitted:\n" <> output` on success (else the helper's message verbatim) and honour `commit: false` (default true).
- The five skill writers use `Shared.maybe_commit_result/6` (schema `commit`, default true): one commit for the paths written/removed plus the same appended block; `:already_enabled_here`/`:already_enabled_above`/`:not_enabled` and errors commit nothing (`skill/CONTEXT.md`).
- `write` and `edit` NEVER commit — their bytes land only via a later commit.

Auto-commit fallback: `Dispatch.commit_pending_in_worktree/0` runs `git add --all` + `Git.commit(wt, "Agent: auto-commit fallback")`, short-circuiting on a clean worktree and warning (not raising) on git errors.
`Runner.refresh_commit_sha/1` re-reads the worktree HEAD after the `after` block and refreshes `commit_sha` on every success shape, so a fallback-only commit still reaches `merge_and_report/4` as a reviewable `genesis/agent_*` branch.
Trigger sites are `Runner.run/3`'s `after` block (every exit except `:brutal_kill`/VM shutdown) and just before every subagent spawn.
The grace-period variant `maybe_recovery_auto_commit/1` (from `enter_grace/3`) commits `"auto-commit: turn-limit recovery"` when dirty, and there git errors DO propagate and crash the agent (deliberate).

`repo_root` is the MAIN working copy and `repo_path` the agent worktree: `Tools.execute/5` takes `repo_path` from `Process.get(:repo_path)` and `repo_root` from `Process.get(:genesis_repo_root)` (derived by stripping the `/.genesis/workers/<wt>` suffix).
Every tool read/write is rooted at `repo_path`, so writes land in the tree the agent commits, `git status` and the fallback operate on, while `repo_root` serves as the sandbox repo root and the reference point for the shell's main-copy block.
Loss windows (no commit lands): `:brutal_kill` and VM shutdown (they skip `Runner.run/3`'s `after`), worktree reclaim/destroy, and the primary-repo boot wipe of orphaned `evogit-agent-*` branches; only `refs/genesis/archive/T<task>-A<local>-start|-final` survive.
There is no per-turn commit; per-turn git activity is only the ETS `phylo_node.current_commit` sync.

### CompleteTask attribution metadata (git notes + archive rows)
`CompleteTask.complete/4` (from `ToolDispatch.do_complete/2` with `base_commit`/`parent_id`/`depth`/`objective`) writes two artifacts, both gated on a truthy `base_commit` (repo-less agents write neither):
- **Git note** (`add_metadata_note/4`, `git notes --ref=evogit` on the final commit): pretty-JSON with EXACTLY `agent_id, base_commit, final_commit, parent_id, depth, objective, result, usage, completed_at, agent_type, context_node_path`, read via `get_agent_metadata/2` (`{:error, {:no_note, _}}` / `{:error, {:invalid_json, _}}` shapes). Notes attach to the commit OBJECT, so merged child commits keep them (the merge commit carries none) and in a fast-forward the child notes are the only attribution. No caller in lib and no dashboard/RPC reader.
- **Archive rows** (`write_archive_refs/7`, additionally gated on the task opt `archive: true`, default false): protected refs `refs/genesis/archive/T<task_id>-A<task_local_id>-start|-final` at the base/final commits, plus ONE `task_agent_archives` row written STREAMING — `TaskRegistry.put_task_archive/1` → `Store.put_task_archive/2`, keyed `(task_id, agent_id)` so a repeat write upserts.
  Row columns: `agent_id, parent_id, depth, agent_type, context_node_path, objective, result, base_commit, final_commit, branch_name, archive_ref_start, archive_ref_final, repo_id, repo_root, repo_path, usage, llm_settings, agent_settings, foreign_repos, compression_count, started_at, completed_at`.
  Nothing is buffered in memory or collected at task end, and the archive never rides `%Result{}` or the task's `result`; a persistence failure returns `{:error, term}` and the tool still completes.
  Reads: `Store.list_task_archives/3` (roster, `result` omitted) and `Store.get_agent_archive/3` (one agent, `result` included).

These plus the live ETS summary (`RemoteAPI.list_agents/0`: `base_commit`/`current_commit`/`parent_id`/`depth`/`task_local_id`) are the only per-agent spawn/merge data sources.

### User-Defined Custom Tools (dispatch + write gating)
- Modules in `<config_dir>/tools/` loaded by `EvoGit.CustomTools` (`../custom_tools.ex`) dispatch through the `execute_tool/5` catch-all: an unknown name goes to `EvoGit.CustomTools.execute/3` first (a configured custom tool wins over a same-named dynamic skill; `:unknown` continues to the skill lookup, then the unknown-tool error; user-code failures return `"Error: " <> reason`).
- They obey the same write gates (`write_tool?/1`), so a write-classified custom tool is blocked for repo-less agents and inside read-only foreign repos.
- They are never in `schemas/0`/`read_only_schemas/0`; each agent opts in through its own `available_tools/0`.

### Configurable shell & redundant nested-shell hint
- `EvoGit.Platform.shell/0` resolves the effective shell, with `[tools] shell` overriding the platform default (`bash` on Linux/macOS, `powershell` on Windows); PowerShell executables (`powershell`/`pwsh`) get `-EncodedCommand`, everything else `["-c", command]`.
- The model-facing name is `bash` on both platforms while the internal dispatch key stays compile-time pinned (`run_bash` on POSIX, `run_powershell` on Windows), because dispatch clauses, `@write_tools` and tests pin it.
- A 💡 hint is appended when a command redundantly invokes a nested shell (`/bin/sh -c '...'`, `bash -c '...'`, a bare `/bin/sh`) as detected by `detect_redundant_shell/2`; `/bin/bash script.sh` and `sh script.sh` are not flagged.

### Main-copy mutation hard block (`shell_tool.ex`)
`do_execute/5` returns an `"Error: ..."` string BEFORE executing when a command BOTH `cd`s into `repo_root` (`Platform.safe_expand`-resolved exactly) AND matches `@mutating_git_regex` `\bgit\s+(checkout|switch|reset|merge|pull)\b`.
- Purpose: `cd <foreign_root> && git checkout evogit-agent-…` from a worktree would move the MAIN copy's HEAD onto the branch pre-merge (empty review diff).
- Only the exact `repo_root` blocks; the agent's own worktree, other worktrees under `.genesis/workers/`, and mutating git without a cd-into-root never block.
- `@cd_regex` also matches relative targets (`./x`, `../x`, `../../../`, `foo`), expanding them against `repo_path` so `cd ../../../` resolves to the repo root; `detect_cd_warnings/3`/`redundant_cd?/3` compare resolved targets and exclude descendants of the agent's own worktree.
- Platform-agnostic; PowerShell `cd`/`Set-Location` is out of scope.
- `repo_root` must be non-nil for shell tools (`Platform.safe_expand/1` accepts binaries only, so the `repo_root \\ nil` default raises a `FunctionClauseError` before any command runs); the agent loop always supplies it.

### Shell Tool — raw execution, NO allow-list
- `execute/3` resolves `command` then branches: `run_in_background` truthy → `start_background_job/3`, else `execute_foreground/4` → `EvoGit.Sandbox.run_with_partial/7` with the command VERBATIM.
- NO allow-list/deny-list/sanitization exists here — any command runs with the user's privileges; the sole pre-execution gate is `main_copy_mutation_error/3` (foreground AND background), and `detect_cd_warnings/3`/`detect_redundant_shell/2` are post-execution hints.
- Invocation: POSIX `["-c", command]`; PowerShell `EvoGit.Powershell.invoke_args/1` = `["-NoProfile", "-NonInteractive", "-ExecutionPolicy", "Bypass", "-EncodedCommand", base64(UTF-16LE("& { … } *>&1"))]`.
- On Windows the child is `powershell.exe` DIRECTLY (no `cmd.exe /c`): `Port.open({:spawn_executable, …})` plus `Helpers.wait_for_os_pid/1`; the unbounded `run/4` path uses `System.cmd/3`.
- Timeout tree-kill reaches DESCENDANTS only (`taskkill /PID <pid> /T /F` on the spawned powershell pid), so it can never reach an ANCESTOR (backend BEAM, launcher) — while an unsanitized model command such as `taskkill /IM erl.exe /F` or `Stop-Process -Name erl -Force` CAN kill the backend BEAM, which leaves no crash log (the shell only sees the sidecar exit).
- Timeouts: the schema advertises `timeout` default `@default_timeout` 120_000 ms; an omitted value resolves through `max(120_000, [:scheduler, :default_tool_timeout])` for platform shell spellings (with `default_timeout_ms/1` as a pure-max floor), an explicit value always wins, and all values clamp to `[:scheduler, :max_tool_timeout]` (30 min); other tools use `[:scheduler, :default_tool_timeout]` (10 s), and the full wrapper contract lives in `../CONTEXT.md`.
- `timeout` is FOREGROUND-only: background starts ignore it (and `run_in_background` is read first), so a bad value can never reject a start.
- `run_command` is not a general shell — it dispatches only the `EvoGit.CommandShell` whitelist (see "Task Management & Guide Tools").

### Background Jobs — `bash` `run_in_background` + `job_output` / `job_list` / `job_kill`
The backend is `EvoGit.BackgroundJobs` (`lib/evo_git/background_jobs.ex`, supervised singleton) which owns records, output capture and reaping; the three tools pass through.
- `bash` param `run_in_background` (boolean, no `"default"` key): truthy → the same main-copy guard, then `start_job/1` with `command:`, `cwd: repo_path`, `repo_root:`, `label:` (first line trimmed to 60 chars), `owner_pid: BackgroundJobs.current_owner_pid()`, `agent_id: Process.get(:evogit_agent_id)` and `task_id: Process.get(:evogit_task_id)`; success returns `started background job <id>`, failure `Failure.error/1` prose, and `timeout` is ignored.
- Owner fence: `current_owner_pid/0` (`Process.get(:evogit_agent_pid)`) is the ONE resolution site and is passed to `read/2`/`list/1`/`kill/3` only when non-nil.
- `job_output` returns the delta since the previous read, a newline, then `"[status: <status>]"` or `"[status: <status>, <detail>]"` (`detail` = `exit code: N`, `killed (<reason>)`, …); an empty delta renders `(no new output)` and `max_bytes` defaults to `[:truncation, :tool_output_default_max_bytes]`.
- `job_output` `wait: true` polls `job/2` every `poll_interval_ms()` (the call-time app-env seam `:background_poll_interval_ms`, production default 100 ms) IN THE TOOL TASK until the status is terminal (`status not in [:running, :stopping]`) or the budget ends — `timeout_ms` defaults to `wait_default_ms()` 8000 and caps at `wait_max_ms()` 60000; a timed-out wait returns the delta so far and leaves the job RUNNING.
- `job_list` takes no params and emits one `<id> [bash] <status> — <label>` line per job (EM DASH U+2014), else `(no background jobs)`.
- `job_kill` takes an optional `reason` and returns `requested cancellation of job <id>`, or `job <id> had already finished [status: …, <detail>]` for a finished job (the `{:already_finished, job}` tuple, not an error); either reply marks the job announced (no completion notice for a job the agent itself killed), while a `job_output` call afterwards still returns the output produced before the kill.
- `JobOutput.status_line/1` (`@doc false` public) is the ONE status formatter, reused by `JobKill`.
- Completion notification: `Runner.inject_background_job_notices/1` makes ONE `claim_finished_notices(owner_pid: self())` call at the turn top (after compression and the pending-message drain, before the cancel-grace check and the LLM call), claiming all terminal unannounced jobs and appending ONE `:user` `[NOTICE]` message from `BackgroundJobNotice.notice/1` (`- `id` — status (detail) — label` per job plus a `job_output`/`job_list` hint, never job output); the `bash` schema description announces this.
- The claim is exactly-once and skipped during a grace period (the job stays unannounced for the next non-grace turn); `job_output`/`job_list` mark a terminal job announced so polling never duplicates, and `job_kill` marks the job it hands back (success, `{:already_finished, job}`, or a `:stopping` record) announced because the caller requested the stop — a backend-failure `Error:` leaves it unannounced so the final status is still reported — and jobs also stay visible as tool results.
- Compression re-injects jobs ONLY on the stage-2 summarising refresh (one `## Background Jobs` snapshot via `BackgroundJobNotice.section/1`, earlier snapshots dropped); stage 1 and message #1 carry none.
- State is per-agent-process and in-memory (`jobs` + `owners` → `%{ref, ids}` in the GenServer state, fenced by the AGENT pid): it survives turns and compression, dies with the agent (owner `:DOWN` kills the job) and is LOST on registry restart (`:unit` jobs keep running unreachable until the next boot sweep).
- All failures return `Failure.error/1` prose (an unknown id and another agent's job both point at `job_list`); all three take `(args, repo_path, repo_root)` and ignore the paths, never raise (`rescue` + `catch :exit`), and never call `String.to_atom/1` on input.

### Windows MSYS2 argv quoting — commit message files
Every tools-node commit uses `git commit -F <tempfile>`, never `-m <message>` argv, because git-for-Windows re-tokenizes double-quoted elements (the co-author trailer contains `<>`), yielding "unknown switch `>`" / "too many arguments" under MSYS2.
- The temp file lives under `EvoGit.Sandbox.resolve_tmpdir()` (not `System.tmp_dir!()`, which may sit outside the macOS sandbox profile) and must be sandbox-readable, since the git calls go through the sandbox.
- Naming invariant: `genesis_git_commit_msg_<System.pid()>_<unique_integer>.txt`, generated only by `Shared.commit_message_file_path/0`. `System.unique_integer([:positive, :monotonic])` is unique only within one BEAM while the tmpdir may be SHARED (`/tmp/genesis/task_<id>` across agents and BEAMs), so a pid-less name let two BEAMs collide and the loser's `after File.rm/1` deleted the winner's `-F` file mid-commit ("fatal: could not read log file") or committed another task's message; `System.pid/0` is ASCII digits and `_` keeps the mapping injective. Regression: `test/evo_git/agent/tools/commit_files_test.exs` "commit_message_file_path/0".
- On Windows the path is normalized `\` → `/` (MSYS2 mangles backslashes).
- `try/after` removes the temp file (no rescue, no swallowed errors); a write failure surfaces as `"Error: could not write temporary commit message file: ..."`.
- Callers consume `{:ok, output}`/`{:error, message}`, and `write_context`/`edit_context` render `"\n\nCommitted:\n" <> output` or the message.
- The adapter (`EvoGit.Adapters.Git.commit/2`) keeps its own inline temp-file + `-F` pattern with `System.tmp_dir!()` (correct for raw `System.cmd`, WRONG for sandboxed reads), so the two stay separate while both generators carry the OS pid (`adapters/CONTEXT.md` "Windows argv quoting").

### Audit: other git/CLI invocations in this node
- `Shared.commit_files/4` — SAFE (`["add" | paths]` plus a `-F` tempfile under `resolve_tmpdir()`).
- `SearchHistory.do_search` — SAFE: `["log", format, commit_id, "--max-count=N", …]` (refs/flags only, no quotes in the format string), with the user pattern applied by Elixir `Regex` after the log is fetched.
- `Git.execute` (run_git) — LATENT: it would pass LLM `sanitized_args` verbatim to `EvoGit.sandbox_run/4`, and `fetch_array_arg/2` validates shape only, so `["commit", "-m", "…"]` would hit the MSYS2 class; a re-enable must intercept `-m`/`-F`.
- `context.ex` is the only module with `-m` argv instances in this node.

### Windows-Only Runtime Hazards
- `edit` cannot edit CRLF files: the read tools strip `\r` from displayed lines while `perform_string_replace`/`find_actual_string` match byte-exactly, so with `core.autocrlf=true` every edit fails with "old_string not found in file" (agents fall back to `write`/`bash`).
- The PowerShell known-location fallback is unreachable: `EvoGit.Executable.resolve/1` maps a name missing from PATH to `<priv>/vendor/windows-x64/<name>.exe` (bundled fallbacks exist only for git/rg), which `Sandbox.None.resolve_executable/1` sees as a non-existent absolute path → `nil` → `:erlang.error(:enoent, …)` → agent crash (Unix degrades to exit 127); the trigger is PowerShell/pwsh or a `[tools] shell` not on PATH.
- Tool-level raises crash the agent: `execute_tool_with_timeout/8` wraps tools in a LINKED `Task.async`, so a raise kills the worker and is reraised in the agent process (its `{:exit, reason}` arm is dead for tool raises); unvalidated args (e.g. a string `timeout`) are fatal, not readable errors.
- Port hazards (indexed in `lib/evo_git/CONTEXT.md`): `Port.info(port, :os_pid)` returns `{:os_pid, pid}` and `Port.close/1` raises when already closed; `lsp.ex` unwraps the tuple before `kill_os_pid/1` (`kill -9` / `taskkill /PID <pid> /T /F`) and closes via the idempotent `Helpers.close_port/1`; `web_fetch` opens no port; binary-env hazards are exclusive to `Port.open({:spawn_executable, …}, [{:env, …}])` (the `Sandbox.None` Windows clause) because `System.cmd` charlist-converts internally.
- `describe_exit_code/1` applies Unix `>=128` signal semantics on Windows, and the redundant-shell regexes are POSIX-only (cosmetic).
- A Windows drive-letter case mismatch (`C:` vs `c:`) in `validate_file_scope/4` makes an in-repo path look outside-repo (spurious error).
- Test gap: every Windows branch (`Sandbox.None.run_windows/3`, `run_with_partial_windows/5`, `EvoGit.Powershell`) is unexercised on Linux dev/CI, as was the OTP-27+ `:os.find_executable/1`-with-binary defect (`sandbox/none.ex`, pinned by `test/evo_git/sandbox/none_test.exs`).

### Task Management & Guide Tools (repo-less "self-reflective" workstream)
`run_command` exposes the task system (`EvoGit.TaskRegistry`), user guides (PubSub `"guides"`), recent projects and local system facts: it passes a command STRING verbatim to `EvoGit.CommandShell.execute/1` and returns the handler output (or an `Error: ...` string for parse/validation failures).
- It is dispatch-registered ONLY (one `execute_tool/5` clause) and absent from `@write_tools` — task control for every coding agent would be a scope/security violation, and a control tool must not be blocked by the repo-less guard.
- Approval gate: registry entries carry `level:`; level-2/3 commands pause at the dispatch choke point awaiting `EvoGit.CommandApproval.request/5` (blocking; PubSub `"approvals"`; default 120 s via `[:evo_git, :command_approval_timeout]`), run ONLY on `:approved` and fail closed on deny/timeout; level-1 commands run immediately.
- The 10 command handlers keep `execute/3` and are called as `apply(module, :execute, [string_keyed_args, nil, nil])` (no schema, no dispatch clause): `ListTasks`, `GetTask`, `StartTask`, `CancelTask`, `ForceKillTask`, `DeleteTask`, `SpawnInvestigator`, `GuideUser`, `ListRecentProjects`, `SystemInfo`.
- Handler output is a binary or `{:error, message}`: binary → `{:ok, output}`; `{:error, binary}` → propagated as a shell error; anything else → `{:error, "Unexpected handler output: #{inspect(output)}"}`.
- Handlers never raise (task-system calls wrap `rescue`/`catch :exit` for `:noproc` and 30 s call timeouts, returning `"task system unavailable: ..."`).
- `GuideUser` uses `with` without `else`, so its validation failures return `{:error, message}` tuples on direct `execute/3` calls (test-pinned), while through the shell `parse_args` rejects missing args first.
- `SpawnInvestigator` normalizes EVERY failure through `Failure.error/1`, so it always returns a plain single-`Error:` string (never a tuple).

Command catalog (`EvoGit.CommandShell`, compile-time literal registry):

| Command | Level | Args |
|---|---|---|
| `ListTasks.list_tasks` | 1 | optional `statuses=` (comma-separated enum_list: `pending/running/finalizing/completed/failed/cancelled/cancelling`) |
| `GetTask.get_task <task_id>` | 1 | required positional task_id |
| `StartTask.start_task <task_type> [objective] [path= mode= resume_from= starting_commit= model_id=]` | 3 | task_type positional enum `genesis/evolve/reflect/extract_skills`; objective positional optional (default `""`); rest optional kv strings |
| `CancelTask.cancel_task <task_id>` | 3 | required positional |
| `ForceKillTask.force_kill_task <task_id>` | 3 | required positional |
| `DeleteTask.delete_task <task_id>` | 3 | required positional |
| `SpawnInvestigator.spawn_investigator <path> <objective>` | 1 | both required positionals — bounded READ-ONLY investigation probe (repo facts, CONTEXT.md chain, inventory, keyword scan); no subagent spawn, no LLM, no writes |
| `GuideUser.guide_user <message> [page= selector= dismissible=true\|false]` | 2 | message required positional; page/selector optional kv; dismissible optional bool (default `true`) |
| `ListRecentProjects.list_recent_projects` | 1 | none |
| `SystemInfo.system_info` | 1 | none |
| `help [command]` | 1 | built-in — handled by the shell itself |

Level 1 = safe read-only, executes immediately; level 2 = needs the user's attention; level 3 = real side effects (levels 2/3 are approval-gated).

**SpawnInvestigator** validates `path`/`objective` (`Shared.fetch_string_arg/2` plus spec-error path checks: exists, is a directory, is a git repository via a pure `.git` dir-or-gitdir-pointer test with NO git subprocess), then calls `SpawnInvestigatorProbe.investigate/2` — a deterministic, bounded, strictly READ-ONLY probe (repo facts and ref from `.git/HEAD`, CONTEXT.md chain, top-level inventory, objective keyword scan) returning a report string, with no LLM, no subagent and no writes (no `.genesis`, worktree or branch).
Its registry entry is `level: 1` (zero side effects), both args required, `path` positional 1 and `objective` positional 2.
Errors are single-`Error:` strings — `Error: Missing required argument '<key>'. Please provide a valid value.`, `Error: Path does not exist: <path>`, `Error: Path is not a directory: <path>`, `Error: Path is not a git repository (no .git directory or gitdir pointer): <path>` — surfacing through the shell as `{:ok, "Error: …"}`; `run_command` is not a `@high_output_tools` member, so it truncates at the 128 KB ceiling.
A real Investigator agent run stays blocked by the level-1 ~10 s tool timeout (an orphaned LLM subagent with invisible spend), the worktree/`.genesis`/branch footprint in an arbitrary repo, and the missing dispatch-level path threading plus LLM test seam; the deterministic probe is self-bounded (<1-2 s) and read-only.

**Security constraints**: compile-time literal registry (no `Code.eval_string`, no input-derived module/function names), no `String.to_atom/1` on input (enums/bools/statuses validated against literal lists and passed as strings), whitelist-only dispatch, and guardrails `@max_command_length` 4000 / `@max_tokens` 40 / `@max_token_length` 2000.
To add a command: a handler `execute/3` plus ONE registry entry (including its `level:`) — no schema, no dispatch clause.

### StartTask opt-forwarding surface (shell task-start data plane)
`StartTask.start_task` forwards `:objective` (positional 2, default `""`), `:path`, `:mode`, `:resume_from`, `:starting_commit` and `:model_id` (raw strings via `maybe_put`, nil/`""` dropped) plus, for `:genesis` only, the same positional text under `:prompt` (the key the genesis executor reads).
It calls `EvoGit.TaskRegistry.start_task/2` on the LOCAL node, which validates nothing and forwards to `TaskExecutor.execute_task/3` — the entry point the CLI and dashboard also use; undeclared `key=value` tokens fall through as positionals.
NOT forwarded: `:build_system`, `:archive`, `:agent` (so `mode=custom` evolve raises), `:foreign_repos`, `:node_path`, `:model_id_locked`, reflect `:source_root`, evolve `:merge_from`/`:merge_target`, and the extract_skills PR-context keys (`:pr_title` … `:user_note`, `:base_sha`, `:commit_sha`) — all of the first group ARE consumed downstream by `RuntimeOpts.build_common_runtime_opts/3`.
Downstream quirks (all crash inside the spawned executor task → task persists `:failed`): (1) `mode` defaults to `"simple"`, so a genesis start without `mode=new|existing` raises `"invalid genesis mode: simple"` and `mode=custom` raises the evolve-only error; (2) `:path` is optional here but `fetch!`ed for genesis/evolve/extract_skills (reflect bypasses `build_common_runtime_opts`); (3) `mode` is `type: :string`, not an enum, so garbage crashes downstream; (4) `model_id=` forwards without the lock flag, so a model-selection script can still override it (dashboard picks and CLI `-m` set `model_id_locked: true`); (5) `reflect`/`extract_skills` ignore the extra keys, and `extract_skills` requires `path=`.
StartTask tests cover reflect only.
