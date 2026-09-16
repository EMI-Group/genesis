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
| `normalize_relpath/1` | Normalizes a relative path to canonical `"./foo/bar"`; raises on absolute paths |
| `load/2,3` | Creates a ContextNode from a filesystem path (`repo_id` for multi-repo) |
| `hierarchy_nodes/2,3` | Full chain of ContextNodes from repo root to given path (`{:ok, nodes} \| {:error, :invalid_path}`) |
| `build_context/2` | Assembles full AI-ready context string by traversing hierarchy (directories only; YAML frontmatter stripped via `EvoGit.Skills.strip_front_matter/1`) |

> The agent loop calls `build_context/2` and `EvoGit.Skills.hierarchical_skill_names/2` separately — there is no combined context+skills load function. `hierarchical_skill_names/2` has live callers in `agent/runner.ex` (skill loading at agent startup) and `agent/tools/skill/skill_list.ex`.

### Context-Tree Render Format (what reaches the agent prompt)
`build_context/2` (`context_node.ex:162-231`) is the ONLY function that turns the context tree into prompt text.
Its caller is `EvoGit.Agent.ContextBuilder.build_dynamic_context/1` (`agent/context_builder.ex:21-26`, invoked from `Runner.do_run/2` at `agent/runner.ex:90-94`) which injects the string into the agent's first-user `<context>` block.
Output = `"# Context Tree\n" <> <per-directory CONTEXT.md blocks joined by "\n\n"> <> "\n\n" <> <location_info>`, or just `location_info` when no directory CONTEXT.md exists (`context_node.ex:222-226`).
Per-directory blocks (`context_node.ex:181-206`) use RELATIVE paths ONLY: header is the literal `File: ./CONTEXT.md` for the root node, else `File: #{Path.join(node.path, "CONTEXT.md")}` (e.g. `File: ./lib/CONTEXT.md`); `node.repo` is NEVER rendered here.
`location_info` (`context_node.ex:213-220`) is where the ABSOLUTE path appears: `Current Repository (worktree): '#{repo_path}'` interpolates the raw 2nd argument, plus `Current Assigned Node: '#{relative_path}'` (relative, raw 1st argument).
So the agent's first prompt ALWAYS carries the absolute repo/worktree path; the assigned node is rendered as the caller's relative `./...` path in the success path.
`repo_path` at this call site = `Process.get(:repo_path)` = the agent's WORKTREE path (`agent/runner.ex:62` + `:256`), NOT the repo root.
On the `{:error, _}` path `build_dynamic_context/1` returns `"Current Path: '#{state.node_path}'."` (no repo path at all).
`ContextNode.load/2,3` (`context_node.ex:93-107`) sets `path: normalize_relpath(relative_path)` (canonical relative `./...`) and `repo: repo_path` VERBATIM (absolute when the caller passes an absolute root — all runtime callers do: `runtime/genesis.ex:219`, `runtime/evolution.ex:97`, `runtime/skill_extraction.ex:21`, `runtime/self_reflective.ex:78`, `task.ex:68`) — but `build_context/2` receives `repo_path` as a SEPARATE argument, not via `node.repo`.

### `EvoGit.Core.PhyloGraphNode` (`phylo_graph_node.ex`)

Struct: `repo`, `base_commit`, `current_commit`.

| Function | Description |
|---|---|
| `new/1,2` | Initializes a node (base and current commit at given ref) — used by `EvoGit.Task` and the runtime phases (genesis, evolution, skill_extraction) |
| `find_merge_base/2` | Finds common ancestor between two nodes — used by `phylo_graph_node_test.exs` |
| `add_and_commit/2` | Stages all changes and commits; returns updated node — used by `EvoGit.Task` (`mutate/3` commit path) |
| `crossover/2` | Merges another node's commit; detects conflicts — used by `phylo_graph_node_test.exs` |
| `get_conflict_files/1` | Lists currently conflicting files — used by `phylo_graph_node_test.exs` |
| `current_head/1` | Resolves HEAD SHA for a repo path — used by `Runtime.Helpers`, `Runtime.Genesis`, `Runtime.SkillExtraction` |
| `list_files/1` | Lists all files at the node's commit — used by `EvoGit.Task` (`diagnose/3` file tree) |
| `list_immediate_children/2` | Lists direct children of a path at the node's commit — used by `phylo_graph_node_test.exs` |

### `EvoGit.Core.ForeignRepo` (`foreign_repo.ex`)

Struct: `id` (string), `root` (absolute path), `description` (string | nil),
`writable` (boolean, default `false`), `base_sha` (string | nil, default `nil` = HEAD).

| Function | Description |
|---|---|
| `new/3` | Creates a ForeignRepo struct with expanded root path; opts `:description`, `:writable` (non-`true` coerced to `false`), `:base_sha` (blank → `nil`) |
| `normalize/1` | Coerces any persisted/CLI shape into a `%ForeignRepo{}` struct (`%ForeignRepo{}` passthrough; atom-keyed or string-keyed maps; `"path"`/`:path` accepted as a root fallback; `"writable"`/`"base_sha"` read with defaults `false`/`nil` when missing — legacy persisted rows round-trip safely); returns `nil` for unparseable input (callers map lists through it and drop `nil`s). Needed because `TaskInfo.opts` persist to SQLite via `Store.Codec` JSON and come back with `:foreign_repos` as STRING-keyed maps — raw dot-access crashes with `KeyError`. Used centrally by `TaskRegistry.MergeContext` and `Runtime.Helpers.merge_foreign_repos/2` |
| `primary_id/0` | Returns the primary repo identifier (`"primary"`) |
| `primary?/1` | Checks if a repo id is the primary repo |
| `normalize_path/2` | Normalizes an absolute path to a relative path within this repo |
| `resolve_path/2` | Determines which repo a path belongs to; returns repo id and relative path |
| `absolute_path?/1` | Checks if a path string is absolute |

`@derive {Jason.Encoder, only: [:id, :root, :description, :writable, :base_sha]}` — the Store/Codec JSON round trip preserves all five fields (encoded `null` for `nil` base_sha). TOML keys in `genesis.toml` `[foreign_repos.<id>]`: `path` (required), `description`, `writable` (default `false`), `base_sha` (default `nil`). CLI `-R` repos are always read-only (`writable: false`, `base_sha: nil`) — marking writable / pinning the starting commit is a `genesis.toml`-only mechanism.

## Constraints

- All git operations must go through `EvoGit.Adapters.Git` — no direct `System.cmd` or shell calls.
- `ContextNode.build_context/2` truncates CONTEXT.md content at `context_max_bytes` (default 64 KB, resolved via `EvoGit.Config.resolve([:truncation, :context_max_bytes])`), appending `"\n... [Content Truncated] ..."`. Truncation is UTF-8-safe via `String.byte_slice/3` (works on bytes, adjusts to eliminate truncated codepoints — never splits a multi-byte char). **Any truncation site must use `String.byte_slice/3` — never raw `binary_part/3` on potentially-multibyte content** (same approach in `EvoGit.Sandbox.Helpers.truncate_output/2` and `read_truncated/3`).
- `PhyloGraphNode`: `base_commit` is immutable after creation; only `current_commit` advances.
- All `ContextNode` paths use `"./"` convention; absolute or `..`-prefixed paths are rejected.
- File names mirror module names (`context_node.ex` → `ContextNode`).
- `ForeignRepo.id` is an **opaque string** with NO slugification or validation inside this module (`new/3` only requires `is_binary(id)`; `normalize/1` additionally rejects nil/empty) — only the literal `"primary"` is special (`primary_id/0`, `primary?/1`, `ContextNode`'s `repo_id: "primary"` default). Ids are supplied at the edges: `genesis.toml` `[foreign_repos.<id>]` uses the TOML **table key verbatim** (`ProjectConfig.build_foreign_repo/2`, project_config.ex:309-326), and CLI `-R <id>:<path>` uses the explicit id or — for a bare path — `Path.basename(path)` (`CLI.Parser.split_foreign_repo_spec/1`, cli/parser.ex:134-143); neither path slugifies.
- `ForeignRepo` has NO `name` and NO `path` field: the struct is exactly `%{id, root, description, writable, base_sha}` (`path`/`:path` is accepted only as a `normalize/1` fallback key for `root`).
- `normalize/1` funnels through `new/3`, so it EXPANDS the root (`Platform.safe_expand/1`) — normalizing a STRING-keyed persisted map re-resolves `root` locally; a remote-node repo root must not be passed through local expansion (callers needing raw remote roots build the struct directly — see `EvoDashWeb.ProjectsLive.ProjectFlow.build_foreign_repo/4`).
- **Nothing in this directory normalizes the task-result `repos` map** (`%{repo_id => %{"commit_sha", "branch_name"}}` from `EvoGit.Runtime.Helpers.merge_and_report/3,4`, string-keyed after the Codec round trip since `Codec.decode_result` does not atomize `"repos"`). Defensive reads of it live elsewhere: `EvoGit.TaskRegistry.PrevTaskRepos` (`prev_repos_map/1`, `repo_commit_sha/2` — merge/resume contexts) and the dashboard's `ReviewLive.LoadData.build_review_repos/7` + `ProjectFlow.repos_from_task_data/2`.
