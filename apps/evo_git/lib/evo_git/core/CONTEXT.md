# Core

## Intent

Foundational domain models: **Spatial Dimension** (ContextNode — directory/file tree with CONTEXT.md contracts), **Temporal Dimension** (PhyloGraphNode — evolutionary git operations), and **multi-repo references** (ForeignRepo — cross-repository path resolution). All git operations delegate to `EvoGit.Adapters.Git`.

## Routing Table

None — leaf directory (modules: `context_node.ex`, `phylo_graph_node.ex`, `foreign_repo.ex`).

## API Surface

### `EvoGit.Core.ContextNode` (`context_node.ex`)

Struct: `path`, `repo`, `repo_id` (defaults to `"primary"`).

| Function | Description |
|---|---|
| `is_ignored?/1` | Checks if the node's path (or any parent) is gitignored |
| `load/2,3` | Creates a ContextNode from a filesystem path |
| `hierarchy_nodes/2,3` | Returns the full chain of ContextNodes from repo root to given path |
| `read_context/1` | Reads CONTEXT.md for directories, file content for files |
| `context_file_path/1` | Returns the relative path to the context-bearing file |
| `build_context/2` | Assembles full AI-ready context string by traversing hierarchy |

### `EvoGit.Core.PhyloGraphNode` (`phylo_graph_node.ex`)

Struct: `repo`, `base_commit`, `current_commit`.

| Function | Description |
|---|---|
| `new/2` | Initializes a node (base and current commit at given ref) |
| `find_merge_base/2` | Finds common ancestor between two nodes |
| `add_and_commit/2` | Stages all changes and commits; returns updated node |
| `crossover/2` | Merges another node's commit; detects conflicts |
| `get_conflict_files/1` | Lists currently conflicting files |
| `current_head/1` | Resolves HEAD SHA for a repo path |
| `list_directories/1` | Lists all directories at the node's commit |
| `list_files/1` | Lists all files at the node's commit |
| `list_immediate_children/2` | Lists direct children of a path at the node's commit |

### `EvoGit.Core.ForeignRepo` (`foreign_repo.ex`)

Struct: `id` (string), `root` (absolute path), `name` (optional string).

| Function | Description |
|---|---|
| `new/3` | Creates a ForeignRepo struct with expanded root path |
| `primary_id/0` | Returns the primary repo identifier (`"primary"`) |
| `primary?/1` | Checks if a repo id is the primary repo |
| `normalize_path/2` | Normalizes an absolute path to a relative path within this repo |
| `resolve_path/2` | Determines which repo a path belongs to; returns repo id and relative path |
| `absolute_path?/1` | Checks if a path string is absolute |

## Constraints

- All git operations must go through `EvoGit.Adapters.Git` — no direct `System.cmd` or shell calls.
- `ContextNode.build_context/2` truncates CONTEXT.md content at `context_max_bytes` (default 64 KB) to bound AI prompt size. **⚠️ BUG: the truncation uses raw `binary_part` at a byte boundary — see Known Issue below.**
- `PhyloGraphNode`: `base_commit` is immutable after creation; only `current_commit` advances.
- All `ContextNode` paths use `"./"` convention; absolute or `..`-prefixed paths are rejected.
- File names mirror module names (`context_node.ex` → `ContextNode`).

## ⚠️ Known Issue — UTF-8 Crash Bug in `build_context/2` truncation (CRITICAL)

**`ContextNode.build_context/2` truncates CONTEXT.md content at an exact BYTE boundary using raw `binary_part(display_content, 0, context_max)`, which can split a multi-byte UTF-8 character.** This produces an invalid-UTF-8 string that flows into the agent's `<context>` prompt block and ultimately to `Jason.encode!` in the req_llm request-building pipeline, crashing the LLM request:

```
%Jason.EncodeError{message: "invalid byte 0xE2 in \"<context>\\n# Context Tree\\n...\""}
```

(`0xE2` is the lead byte of a 3-byte sequence — e.g. em-dash `—` = `0xE2 0x80 0x94`. If `context_max` lands in byte position 1 or 2 of such a sequence, the truncated string is invalid UTF-8.)

**Location:** `context_node.ex:189-196` (inside the `Enum.flat_map` in `build_context/2`):
```elixir
truncated_content =
  if byte_size(display_content) > context_max do
    Logger.warning("Content truncated for file: #{file}")
    binary_part(display_content, 0, context_max) <> "\n... [Content Truncated] ..."  # ← BUG: byte-boundary cut, no UTF-8 adjustment
  else
    display_content
  end
```

**Config:** `context_max` comes from `EvoGit.Config.resolve([:truncation, :context_max_bytes])`, default **65_536 (64 KB)** (`config/config.exs:70`, schema in `definitions.exs:456`).

**Why it only fires on large CONTEXT.md files:** only triggers when a single CONTEXT.md file exceeds 64 KB after front-matter stripping. The em-dash (or other 2/3/4-byte char) must be positioned such that `context_max` cuts mid-sequence.

**Data flow (full path to the crash):**
1. `Runner.do_run/1` (`agent/runner.ex:76`) → `ContextBuilder.build_dynamic_context/1` → `ContextNode.build_context/2` → produces invalid-UTF-8 string.
2. `ContextBuilder.context_block/1` (`context_builder.ex:73`) wraps it as `<context>\n...\n</context>` — now the invalid bytes are inside the `<context>` block (matches the error message's `<context>\n# Context Tree\n...`).
3. `runner.ex:98` → `ReqLLM.Context.new([system(...), user(combined_prompt)])` — invalid bytes stored in the user message.
4. `ToolDispatch.call_llm_with_retry/5` (`agent/tool_dispatch.ex:187`) → `ReqLLM.stream_text/3` (`:196`).
5. req_llm: `Streaming.start_stream/4` → `FinchClient.start_stream/4` → provider `attach_stream` → `Provider.Defaults.build_streaming_body/4` (`deps/req_llm/lib/req_llm/provider/defaults.ex:1893`) → `encode_body` → `Jason.encode!` → **`%Jason.EncodeError{}` raised**.
6. Caught and wrapped: `{:error, {:provider_build_failed, ...}}` → `{:error, {:http_streaming_failed, {:provider_build_failed, ...}}}`. Logged as "Failed to build stream request: ..." (`defaults.ex`), "Failed to start streaming" (`streaming.ex`).

**req_llm does NOT sanitize UTF-8.** It's a git dependency (`{:req_llm, git: "...", branch: "main"}`, NOT hex, NOT vendored into the app) — its "sanitize" functions are for URLs/tool-call-IDs/metadata, none validate message content bytes. It faithfully `Jason.encode!`s whatever the caller passes. So the fix MUST be in evo_git.

**FIX (recommended):** replace the raw `binary_part/3` with a UTF-8-safe truncation. `EvoGit.Agent.OutputSanitizer` already has the correct pattern — `safe_binary_part/3` + `adjust_boundary/3` (`agent/output_sanitizer.ex:235-269`) backs up 1-3 bytes until `String.valid?/1` is true. The cleanest fix is to extract that boundary-adjustment logic into a shared helper and use it here. Even simpler inline fix:
```elixir
raw = binary_part(display_content, 0, context_max)
truncated = if String.valid?(raw), do: raw, else: trim_to_utf8_boundary(raw)
```
where `trim_to_utf8_boundary/1` drops the trailing 1-3 bytes until `String.valid?/1` holds.

**Defense-in-depth option:** also run `ensure_utf8`-style sanitization (`:unicode.characters_to_binary(content, :utf8, :utf8)`) at the point where context is assembled for the prompt, so even pre-existing invalid UTF-8 in CONTEXT.md files (read via raw `File.read`) can't crash the pipeline. The most central injection point is `Runner.do_run/1` (after `build_context` returns) or `ContextNode.build_context/2` itself.

**Related unsafe truncation (same bug class, alternate crash trigger):** `EvoGit.Sandbox.Helpers.truncate_output/2` (`sandbox/helpers.ex:58`) and `read_truncated/3` (`sandbox/helpers.ex:128`) ALSO use raw `binary_part`/`:file.pread` at byte boundaries with no UTF-8 adjustment. These affect `run_bash`/shell tool OUTPUT (which then becomes tool-result message content sent to the LLM) — a second path by which invalid UTF-8 can reach `Jason.encode!`. The `OutputSanitizer.truncate/3` (tool-output path) IS safe (`safe_binary_part`), but `Sandbox.Helpers.truncate_output` (used by the `None` backend at `sandbox/none.ex:161` and indirectly via `read_tempfile` on all backends) is NOT. If the crash is intermittent and not always tied to a 64KB+ CONTEXT.md, this is the likely alternate trigger.
