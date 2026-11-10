# Core

## Intent

Foundational domain models: **Spatial Dimension** (ContextNode — directory/file tree with CONTEXT.md contracts), **Temporal Dimension** (PhyloGraphNode — evolutionary git operations), and **multi-repo references** (ForeignRepo — cross-repository path resolution). All git operations delegate to `EvoGit.Adapters.Git`.

## Routing Table

None — leaf directory (modules: `context_node.ex`, `phylo_graph_node.ex`, `foreign_repo.ex`).
The persisted task struct is NOT here: `EvoGit.TaskInfo` is `lib/evo_git/task_info.ex` (owning detail: `lib/evo_git/CONTEXT.md` + `store/`).
Of this directory's three structs, only `ForeignRepo` is persisted (as JSON nested in `TaskInfo.opts[:foreign_repos]`, so it round-trips string-keyed); `ContextNode` and `PhyloGraphNode` are runtime-only and never touch the store.

## API Surface

### `EvoGit.Core.ContextNode` (`context_node.ex`)

Struct: `path`, `repo`, `vct_path` (`nil` by default), `repo_id` (defaults to `"primary"`).

`path` is ALWAYS the in-repo relative `"./…"` string and is never derived from `vct_path`; `vct_path` is the node's canonical Virtual Context Tree URL (`vct:///projects/foo/src/auth`, see `EvoGit.VCT.Path`) when the node's repository root is mounted in the VCT, else `nil`.

`vct_path` is INTERNAL METADATA, not a path: it is never rendered as a CONTEXT.md file path, never used to expand a file, and the VCT read behind it is TOTAL (a missing VCT server, an unmounted repo or a relative/invalid node path all yield `nil`).

| Function | Description |
|---|---|
| `is_ignored?/1` | Checks if the node's path (or any parent) is gitignored |
| `normalize_relpath/1` | Normalizes a relative path to canonical `"./foo/bar"`; raises on absolute paths; `""`/`"."` → `"./"`; only trims/normalizes separators + prepends `"./"` (it does NOT collapse interior `..`/`.` segments; UNCHANGED by the VCT). ⚠️ `EvoGit.Agent.Tools.Shared.normalize_relpath/1` is a DIFFERENT function with the same name and returns `{:error, msg}` for absolute paths instead of raising |
| `load/2,3` | Creates a ContextNode from a filesystem path (`repo_id` for multi-repo); sets `vct_path` via `EvoGit.VCT.vct_path_for(repo_path, normalized_path)` — `nil` when unmounted/no server |
| `hierarchy_nodes/2,3` | Full chain of ContextNodes from repo root to given path (`{:ok, nodes} \| {:error, :invalid_path}`); every node is built by `load/2,3`, so each carries its own `vct_path` |
| `build_context/2` | Assembles full AI-ready context string by traversing hierarchy (directories only; YAML frontmatter stripped via `EvoGit.Skills.strip_front_matter/1`) |

> The agent loop calls `build_context/2` and `EvoGit.Skills.hierarchical_skill_names/2` separately — there is no combined context+skills load function. `hierarchical_skill_names/2` has live callers in the session setup path — `EvoGit.Agent.Session.Setup.build_initial_state/3` (`agent/session/setup.ex`, skill loading at agent startup) — and `agent/tools/skill/skill_list.ex`.

### Context-Tree Render Format (what reaches the agent prompt)
`build_context/2` (`context_node.ex:181-209`) is the ONLY function that turns the context tree into prompt text.
Its caller is `EvoGit.Agent.ContextBuilder.build_dynamic_context/1` (`agent/context_builder.ex:45`, reached from `build_context_block/1`), which `EvoGit.Agent.Session.Setup.build_initial_state/3` invokes from the session's `:start` event via `ContextBuilder.build_initial_messages/4` — injecting the string into the agent's first-user `<context>` block.
Output = `"# Context Tree\n" <> <rendered stages joined by "\n\n"> <> "\n\n" <> <location_info>`, or just `location_info` when NO stage renders (`context_node.ex:198-204`).
Stages are, in order, the VCT GLOBAL context first (`global_stage/1`) and then the in-repo directory chain (`in_repo_stage/2`).
The global stage is read from `EvoGit.VCT.global_context()` (`<data_dir>/vct/CONTEXT.md`, `""` when absent or when the VCT server is unreachable) and is ALWAYS labelled with the literal `File: global/CONTEXT.md` — never an OS path, never `"/"`, never the file's `vct:///` URL.
In-repo stages use RELATIVE paths ONLY: header is the literal `File: ./CONTEXT.md` for the root node, else `File: #{Path.join(node.path, "CONTEXT.md")}` (e.g. `File: ./lib/CONTEXT.md`); `node.repo` and `node.vct_path` are NEVER rendered here — no absolute OS path and no `vct:///` URL ever appears as a CONTEXT.md file label.
A stage whose CONTEXT.md is absent, blank after `EvoGit.Skills.strip_front_matter/1`, or front-matter-only is SKIPPED (`render_stage/3` → `nil`, `List.wrap(nil)` → `[]`), so no empty fenced code block is ever emitted.
`build_context/2` calls `hierarchy_nodes/2` (`context_node.ex:182`), never `/3`, so every node it builds carries `repo_id: "primary"` — the multi-repo repo_id plays no part in prompt rendering.
`location_info` (`context_node.ex:189-196`) is where the ABSOLUTE path appears: `Current Repository (worktree): '#{repo_path}'` interpolates the raw 2nd argument, plus `Current Assigned Node: '#{relative_path}'` (relative, raw 1st argument).
So the agent's first prompt ALWAYS carries the absolute repo/worktree path; the assigned node is rendered as the caller's relative `./...` path in the success path, and a contextless tree still yields that location block (no `# Context Tree` header).
`repo_path` at this call site = `Process.get(:repo_path)` = the agent's WORKTREE path (installed by `EvoGit.Agent.Session.Setup.bind_worktree/2` + `install_process_context/3` in `agent/session/setup.ex`, read at `agent/tool_dispatch.ex:916`), NOT the repo root.
On the `{:error, _}` path `build_dynamic_context/1` returns `"Current Path: '#{state.node_path}'."` (no repo path at all).
`ContextNode.load/2,3` (`context_node.ex:103-120`) sets `path: normalize_relpath(relative_path)` (canonical relative `./...`), `repo: repo_path` VERBATIM (absolute when the caller passes an absolute root — all runtime callers do: `runtime/genesis.ex:219`, `runtime/evolution.ex:97`, `runtime/skill_extraction.ex:21`, `runtime/self_reflective.ex:78`) and `vct_path: EvoGit.VCT.vct_path_for(repo_path, normalized_path)` — but `build_context/2` receives `repo_path` as a SEPARATE argument, not via `node.repo`.

### Node identity & path semantics (canonical definition)
A context-tree node is identified ONLY by the pair `{%ContextNode{}.repo_id, %ContextNode{}.path}` — there is no id, hash or registry row; `path` is ALWAYS a relative directory path from that repo's root (`"primary"` or a foreign repo id), in canonical `"./foo/bar"` form with `"./"` as the root; `vct_path` is derived METADATA and takes no part in identity.
`repo` is the absolute base path the relative `path` is expanded against (`Platform.safe_expand(node.path, node.repo)`); runtime callers pass the agent's WORKTREE, so the same relative path resolves inside that worktree.
`load/2,3` performs NO existence/type check (paths may not exist yet); `@enforce_keys [:path, :repo]` (`vct_path` defaults to `nil` and is never enforced).
Directory-ness is decided at READ time: `hierarchy_nodes/3` is purely SYNTACTIC (it splits the normalized path into `["./", "./a", "./a/b", …]` and includes the target itself), and `build_context/2` drops every node whose expanded path is not `File.dir?/1`, so a file-shaped node path silently contributes no `File: …/CONTEXT.md` block.
`hierarchy_nodes/3` rejects absolute paths and raw `..`-prefixed input with `{:error, :invalid_path}`; the `..` guard is `String.starts_with?(relative_path, "..")` on the RAW argument, so an interior `..` (`"a/../b"`) is accepted and produces literal `".."` segments while a legitimate directory named `..foo` is rejected.
The absolute-path guard is host-dependent `Path.type(relative_path) == :relative` (`context_node.ex:127`), whereas `normalize_relpath/1` uses the cross-platform `Platform.absolute_path?/1` (`platform.ex:275-287`, which also matches `C:\`/`\\` on any host) — so a Windows-absolute node path passes the guard on a non-Windows host and then RAISES from `normalize_relpath/1` instead of returning `{:error, :invalid_path}`.
There is NO children-discovery function in this directory: the ancestor chain (root → node) is the only tree walk, and the lone children listing is `PhyloGraphNode.list_immediate_children/2` (git `ls-tree` at `node.current_commit`, test-only caller).
Task admission of a ROOT node path is stricter than `load/2,3`: `EvoGit.Runtime.Helpers.validate_node_path/2` requires an existing directory that contains a `CONTEXT.md` (except literal `"./"`), and subagents' node paths are dirname-coerced from file paths at spawn.
No virtual/synthetic/file/skill node types exist: skills are per-DIRECTORY frontmatter on the same directory nodes (`EvoGit.Skills.ContextIntegration.hierarchical_skill_names/2` walks the same hierarchy and keeps existing dirs only; `find_skill_node/3` returns a plain relative node path).
`is_ignored?/1` returns `true` when the path or ANY parent is gitignored, and `false` (not an error) when `git check-ignore` fails.

### `EvoGit.Core.PhyloGraphNode` (`phylo_graph_node.ex`)

Struct: `repo`, `base_commit`, `current_commit`.

| Function | Description |
|---|---|
| `new/1,2` | Initializes a node (base and current commit at given ref) — used by the runtime phases (genesis, evolution, skill_extraction) |
| `find_merge_base/2` | Finds common ancestor between two nodes — used by `phylo_graph_node_test.exs` |
| `add_and_commit/2` | Stages all changes and commits; returns updated node — used by `phylo_graph_node_test.exs` |
| `crossover/2` | Merges another node's commit; detects conflicts — used by `phylo_graph_node_test.exs` |
| `get_conflict_files/1` | Lists currently conflicting files — used by `phylo_graph_node_test.exs` |
| `current_head/1` | Resolves HEAD SHA for a repo path — used by `Runtime.Helpers`, `Runtime.Genesis`, `Runtime.SkillExtraction` |
| `list_immediate_children/2` | Lists direct children of a path at the node's commit — used by `phylo_graph_node_test.exs` |

`base_commit`/`current_commit`/`repo` NEVER reach prompt text: the SHAs live only in scheduler ETS (`AgentState.phylo_node`, updated by `AgentScheduler.update_phylo_node/2`) and are consumed by git operations + the worktree checkout (`Worktrees.create_worktree` uses `spec.phylo_node.current_commit`); `PhyloGraphNode.new/2` (`phylo_graph_node.ex:23-24`) is the only constructor and `repo` is a repo/worktree path used solely for git calls (`Git.merge_base`/`status`/`rev_parse`/`run`). No SHA is ever interpolated into prompt text.

### `EvoGit.Core.ForeignRepo` (`foreign_repo.ex`)

Struct: `id` (string), `root` (absolute path), `description` (string | nil),
`writable` (boolean, default `false`), `base_sha` (string | nil, default `nil` = HEAD).

| Function | Description |
|---|---|
| `new/3` | Creates a ForeignRepo struct with expanded root path; opts `:description`, `:writable` (non-`true` coerced to `false`), `:base_sha` (blank → `nil`) |
| `normalize/1` | Coerces any persisted/CLI shape into a `%ForeignRepo{}` struct (`%ForeignRepo{}` passthrough; atom-keyed or string-keyed maps; `"path"`/`:path` accepted as a root fallback; `"writable"`/`"base_sha"` read with defaults `false`/`nil` when missing — legacy persisted rows round-trip safely); returns `nil` for unparseable input (callers map lists through it and drop `nil`s). Needed because `TaskInfo.opts` persist to SQLite via `Store.Codec` JSON and come back with `:foreign_repos` as STRING-keyed maps — raw dot-access crashes with `KeyError`. Used centrally by `TaskRegistry.MergeContext` and `Runtime.Helpers.merge_foreign_repos/2` |
| `primary_id/0` | Returns the primary repo identifier (`"primary"`) |
| `primary?/1` | Checks if a repo id is the primary repo |
| `normalize_path/2` | Normalizes an absolute path to a relative path within this repo (prefix-matches `repo.root` only) |
| `resolve_path/2` | Determines which repo a path belongs to; returns repo id and relative path — delegates to `resolve/2` (3-tuple contract preserved) |
| `resolve/2` | Like `resolve_path/2` but returns a 4-tuple `{:ok, repo, base_dir, rel_path}`: for a WRITABLE repo it intercepts the persistent-worktree prefix `<root>/.genesis/foreign_repos/<id>` BEFORE the generic `root` match, returning the worktree as `base_dir` with `rel_path` taken RELATIVE TO THE WORKTREE (`<wt>/src/foo` → `./src/foo`, NOT `./.genesis/foreign_repos/<id>/src/foo`; the worktree root → `"./"`); otherwise `base_dir` = `repo.root`. Foreign-first ordering unchanged. Used by `EvoGit.Agent.SubagentProcessing.resolve_subagent_path/4` |
| `worktree_path/1` | Derives a repo's PERSISTENT worktree path `<root>/.genesis/foreign_repos/<id>` (pure; derivable from the two enforced keys, so NO struct field / `@derive` / Codec / dashboard change). Meaningful only for a `writable: true` repo — its lifecycle is owned by `EvoGit.AgentScheduler.ForeignWorktree` |
| `absolute_path?/1` | Checks if a path string is absolute |

`@derive {Jason.Encoder, only: [:id, :root, :description, :writable, :base_sha]}` — the Store/Codec JSON round trip preserves all five fields (encoded `null` for `nil` base_sha). TOML keys in `genesis.toml` `[foreign_repos.<id>]`: `path` (required), `description`, `writable` (default `false`), `base_sha` (default `nil`). CLI `-R` repos are always read-only (`writable: false`, `base_sha: nil`) — marking writable / pinning the starting commit is a `genesis.toml`-only mechanism.
**Persistent worktree (writable repos)**: `worktree_path/1` derives `<root>/.genesis/foreign_repos/<id>` — the PERSISTENT worktree maintained for every WRITABLE non-primary repo so agents can READ its latest committed state by absolute path. It lives OUTSIDE `.genesis/workers/` (so the `WorktreeManager`'s primary-only init wipe and per-agent `destroy_worktree/3` never touch it) and the repo's MAIN working-copy HEAD is never moved. `resolve/2` recognizes BOTH the root and this worktree path as the same repo (the worktree prefix wins for a writable repo). Create/reset/sync lifecycle (kept after task end) is owned by `EvoGit.AgentScheduler.ForeignWorktree` — see `agent_scheduler/CONTEXT.md`.

## Constraints

- All git operations must go through `EvoGit.Adapters.Git` — no direct `System.cmd` or shell calls.
- `ContextNode.build_context/2` truncates CONTEXT.md content at `context_max_bytes` (default 64 KB, resolved via `EvoGit.Config.resolve([:truncation, :context_max_bytes])`), appending `"\n... [Content Truncated] ..."`. Truncation is UTF-8-safe via `String.byte_slice/3` (works on bytes, adjusts to eliminate truncated codepoints — never splits a multi-byte char). **Any truncation site must use `String.byte_slice/3` — never raw `binary_part/3` on potentially-multibyte content** (same approach in `EvoGit.Sandbox.Helpers.truncate_output/2` and `read_truncated/3`).
- `PhyloGraphNode`: `base_commit` is immutable after creation; only `current_commit` advances.
- All `ContextNode` paths use `"./"` convention; `hierarchy_nodes/3` rejects absolute and raw `..`-prefixed inputs (`normalize_relpath/1` raises on absolute, `load/2,3` does neither).
- File names mirror module names (`context_node.ex` → `ContextNode`).
- `ForeignRepo.id` is an **opaque string** with NO slugification or validation inside this module (`new/3` only requires `is_binary(id)`; `normalize/1` additionally rejects nil/empty) — only the literal `"primary"` is special (`primary_id/0`, `primary?/1`, `ContextNode`'s `repo_id: "primary"` default). Ids are supplied at the edges: `genesis.toml` `[foreign_repos.<id>]` uses the TOML **table key verbatim** (`ProjectConfig.build_foreign_repo/2`, project_config.ex:309-326), and CLI `-R <id>:<path>` uses the explicit id or — for a bare path — `Path.basename(path)` (`CLI.Parser.split_foreign_repo_spec/1`, cli/parser.ex:134-143); neither path slugifies.
- `ForeignRepo` has NO `name` and NO `path` field: the struct is exactly `%{id, root, description, writable, base_sha}` (`path`/`:path` is accepted only as a `normalize/1` fallback key for `root`).
- `normalize_path/2`'s prefix check is **byte-based**: the separator probe passes `byte_size(root)` into `Platform.path_next_is_separator?/2`, which compares the BYTE at that offset — never mix a byte offset with a grapheme-indexed helper (`String.at/2`), which silently mis-resolves any repo root containing multi-byte UTF-8.
- `normalize/1` funnels through `new/3`, so it EXPANDS the root (`Platform.safe_expand/1`) — normalizing a STRING-keyed persisted map re-resolves `root` locally; a remote-node repo root must not be passed through local expansion (callers needing raw remote roots build the struct directly — see `EvoDashWeb.ProjectsLive.ProjectFlow.build_foreign_repo/4`).
- **Nothing in this directory normalizes the task-result `repos` map** (`%{repo_id => %{"commit_sha", "branch_name"}}` from `EvoGit.Runtime.Helpers.merge_and_report/3,4`, string-keyed after the Codec round trip since `Codec.decode_result` does not atomize `"repos"`). Defensive reads of it live elsewhere: `EvoGit.TaskRegistry.PrevTaskRepos` (`prev_repos_map/1`, `repo_commit_sha/2` — merge/resume contexts) and the dashboard's `ReviewLive.LoadData.build_review_repos/7` + `ProjectFlow.repos_from_task_data/2`.

## Known Issues

- **`hierarchy_nodes/3` docstring vs behavior**: `context_node.ex:113` claims "Nodes that do not exist in the filesystem are excluded from the result list", but the function never touches the filesystem — it returns the full syntactic chain (pinned by `test/evo_git/core/context_node_test.exs:26-34`). Existence filtering happens only downstream in `build_context/2` (`File.dir?/1`) and `EvoGit.Skills.ContextIntegration.existing_hierarchy_nodes/2`.
- **`normalize_relpath/1` is lossy for path traversal**: it trims separators and prefixes `"./"` but never collapses `".."`/`"."` segments, so `"a/../../b"` normalizes to `"./a/../../b"` and `build_context/2` then expands it OUTSIDE the repo when reading CONTEXT.md files; the only `..` rejection lives in `hierarchy_nodes/3` and is a raw-prefix check.
