# Custom Tools (user-defined tools)
## Intent
Houses the `EvoGit.CustomTools` subsystem: user-authored tool modules loaded dynamically from `<config_dir>/tools/`.
The directory `<config_dir>/tools/` is the user's tool drop-box (sibling of `config.toml` and `agents.toml`).
Supported file kinds are `.ex`, `.exs` and `.beam` — every candidate file in the directory is considered, sorted by basename for a deterministic load order.
`EvoGit.CustomTools` (`../custom_tools.ex`) is the public facade (load/schemas/known?/write_tool?/execute/status/reload).
`EvoGit.CustomTools.Loader` (`loader.ex`) owns directory enumeration, compilation/loading, collision detection, caching and error collection.
`EvoGit.CustomTools.Tool` (`tool.ex`) is the behaviour a user tool module implements.
## API Surface
### `EvoGit.CustomTools` (public API)
- `tools_dir/0` → `<config_dir>/tools` (delegates to the loader).
- `load/0` → `%{tool_name => entry}` for all accepted tools (`%{}` when nothing is configured); `entry = %{name: String.t(), module: module(), schema: ReqLLM.Tool.t(), read_only?: boolean(), file: String.t()}`.
- `schemas/0` → `[ReqLLM.Tool.t()]` of all loaded custom tools, sorted by name; cheap cache read, never raises.
- `known?/1` (name) → `boolean()` — whether `name` is a loaded custom tool.
- `write_tool?/1` (name) → `boolean()` — `true` for a KNOWN custom tool whose `read_only?` is `false`/absent, `false` for a KNOWN read-only custom tool, `false` for an UNKNOWN name (so it never blocks built-ins/unknowns).
- `execute/3` (name, args, ctx) → `{:ok, output :: String.t()} | {:error, reason :: String.t()} | :unknown`.
- `status/0` → EXACTLY `%{ok: [%{name: String.t(), file: String.t(), module: module(), read_only?: boolean()}], errors: [%{file: String.t(), reason: String.t()}]}`; never raises, `%{ok: [], errors: []}` when nothing is configured.
- `reload/0` → `:ok` — erases the custom-tools cache so the next call re-reads the directory; safe when nothing is cached.
### `EvoGit.CustomTools.Loader`
- `tools_dir/0` → `<config_dir>/tools`.
- `load/0,1` (dir defaults to `tools_dir/0`) → `%{tool_name => entry}`; missing or empty directory → `%{}` with NO warning.
- `load_with_errors/1` (dir) → `{entries, errors}`.
- `errors/0,1` (dir) → `[%{file: String.t(), reason: String.t()}]`.
- `invalidate/0,1` (dir) → `:ok` — `:persistent_term.erase` of the cache key.
### `EvoGit.CustomTools.Tool` (behaviour)
- `schema/0` → `ReqLLM.Tool.t()`; the tool NAME exposed to the LLM is `schema().name` (must be a non-empty binary).
- `execute/2` (args :: map(), ctx :: map()) → MUST return a `String.t()` (success text or an `"Error: ..."` string) and should never crash the agent loop.
- `ctx` map shape: `%{repo_path: String.t(), repo_root: String.t() | nil, node_path: String.t() | nil}`.
- `read_only?/0` → `boolean()`, OPTIONAL callback, defaults to `false`.
### `EvoGit.CustomAgents.reload/0` (one level up)
- `reload/0` invalidates BOTH the `ModelSelector` compile cache AND the custom-tools cache (guarded `Code.ensure_loaded?/1` + `function_exported?/3`, warning-free when a module is absent).
## Load & Error Semantics
A candidate file is considered only if it defines at least one module exporting BOTH `schema/0` and `execute/2` (checked with `Code.ensure_loaded?/1` + `function_exported?/3`).
`.ex`/`.exs` files are compiled with `Code.compile_file/1`; `.beam` files are read with `:beam_lib.chunks/2` (empty chunk list — the module name is the first tuple element, since `:module` is not a real BEAM chunk id) and loaded with `:code.load_binary/3`.
`read_only?/0` is read if exported, else `false` — an explicit `true` is the only way to mark a custom tool read-only.
Load COLLISION RULE (a): a custom tool name equal to a BUILT-IN tool name is REJECTED (built-in wins) — warned + recorded as an error.
Load COLLISION RULE (b): a duplicate name among custom tools is REJECTED with FIRST WINS (deterministic basename sort) — the later definition is warned + recorded as an error.
Built-in names = names of `EvoGit.Agent.Tools.schemas/0` ++ `EvoGit.Agent.Tools.read_only_schemas/0` (extracted via `EvoGit.Agent.tool_name/1`) PLUS the literal non-schema built-ins `["run_command", "complete_task"]`, computed at RUNTIME (never a module attribute) to avoid a compile-time cycle with `EvoGit.Agent.Tools`.
A file with no qualifying module, a compile/load failure, or a `schema/0` that raises or does not return a non-empty-named `%ReqLLM.Tool{}` is skipped with a `Logger.warning` + a `%{file, reason}` error record — never a crash.
## Caching
The cache lives in `:persistent_term` keyed `{EvoGit.CustomTools, :cache, dir}` storing `{fingerprint, entries, errors}`.
`fingerprint` is the sorted list of `{basename, mtime, size}` for every candidate file, recomputed on every `load/1` call (`File.ls` + `File.stat` — cheap).
The cached entries are reused only when the fingerprint is unchanged; a changed file set/content (including missing↔present directory transitions) triggers a full recompile.
Loading is LAZY (first `load/0`/`schemas/0`/`execute/3`/`status/0` call) — nothing loads at application boot, so a broken custom tool can never block startup.
`reload/0` (and `EvoGit.CustomAgents.reload/0`) invalidates the cache; the next call re-reads and recompiles.
## Write-Gate Classification
`read_only?/0` maps to the dispatch write gate via `EvoGit.CustomTools.write_tool?/1`.
The default for a tool that omits `read_only?/0` (or whose `read_only?/0` raises) is `false` → classified as a WRITE tool (conservative/safe default).
An UNKNOWN name returns `false` from `write_tool?/1` so the gate never accidentally blocks a built-in or unknown tool.
Both read-only and write custom tools are advertised to the LLM through the same `schemas/0` list — the classification only affects the write gate.
## Security
Files in `<config_dir>/tools/` are USER-AUTHORED code, equivalent to the `agents.toml` `[model_selection] script` (which already evaluates user Elixir in-process).
Custom tools are compiled and loaded into the running BEAM with FULL privileges — there is NO load-time sandbox.
Tool EXECUTION is NOT sandboxed by default; a tool that needs isolation must apply `EvoGit.Sandbox` itself.
Only load custom tools you trust — the directory is a privileged code-loading path.
No `String.to_atom`/`to_existing_atom` is applied to tool names or args (lookup is `Map.get/2` on the loaded map) and no `Code.eval_string` is used on user strings (`Code.compile_file/1` is the sanctioned file mechanism).
The `try/rescue` + `try/catch` boundaries around `Code.compile_file/1`, `:code.load_binary/3`, `schema/0` and `execute/2` are JUSTIFIED: that code is user-authored, so a raise/throw/exit is an expected input, not a bug.
Every such boundary LOGS a `Logger.warning` AND surfaces an explicit error (a `%{file, reason}` record at load time, or an `{:error, "... raised: ..."}` tuple at execution time) — never a silent default.
## Constraints
- Both modules and the behaviour live in this directory; `EvoGit.CustomTools` is `../custom_tools.ex` (one level up, sibling of this dir).
- Custom tools are NOT added to `EvoGit.Agent.Tools.schemas/0` or `read_only_schemas/0` — dispatch integration is a separate concern owned elsewhere.
- Never atomize untrusted input; never `Code.eval_string` untrusted strings.
- Keep the loader non-raising so `EvoGit.CustomTools.schemas/0` and `status/0` can promise "never raises".
## Notes for Agents
- `status/0`'s exact shape is a stable contract consumed by the `:evo_dash` settings UI follow-up — do not change it without updating consumers.
- `EvoGit.CustomTools.Tool` documents the full user-facing contract the settings UI and docs should surface.
- Compile-time consumers must go through the facade; the loader is an implementation detail.
