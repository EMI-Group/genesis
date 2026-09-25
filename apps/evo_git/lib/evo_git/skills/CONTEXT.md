# EvoGit.Skills — Dynamic Skill Tools System

## Intent

Skills are **custom tools defined as markdown files** in `<repo_root>/.agents/skills/`.
Each file has YAML frontmatter (name, description, parameters) and a markdown body
(typically a bash code block). Skills are loaded at runtime as LLM-callable tools,
enabling project-specific automation without modifying EvoGit source.

## Routing Table

None — leaf directory (modules: `skill.ex`, `executor.ex`, `crud.ex`, `context_integration.ex`; the top-level `EvoGit.Skills` module lives in the sibling `../skills.ex`).

## API Surface

### Module Structure

| Module | Purpose |
|--------|---------|
| `EvoGit.Skills` | Top-level API — loading, parsing, YAML, delegation wrappers |
| `EvoGit.Skills.Skill` | `%Skill{}` struct |
| `EvoGit.Skills.Executor` | Skill execution — find, extract bash block, positional-param substitution, sandboxed run |
| `EvoGit.Skills.CRUD` | Skill file management — create, read, update, delete, validate |
| `EvoGit.Skills.ContextIntegration` | Hierarchical enablement via CONTEXT.md frontmatter |

### `EvoGit.Skills` — Key Functions

| Function | Purpose |
|----------|---------|
| `load_skills/1` | Parse all `.md` files from `.agents/skills/` into `[Skill.t()]` |
| `to_tool_schemas/1` | Convert skills to `ReqLLM` tool schemas for the LLM |
| `skill_names/1`, `find_skill/2` | Query loaded skills by name |
| `parse_frontmatter/1` | Parse YAML frontmatter from skill/CONTEXT.md content |
| `parse_yaml_simple/1` | Parse a YAML string via `yaml_elixir` |
| `strip_front_matter/1` | Strip YAML frontmatter from CONTEXT.md (used by `ContextNode.build_context/2`) |

### Execution (delegates to `EvoGit.Skills.Executor`)

| Function | Purpose |
|----------|---------|
| `execute/4` | Find a skill by name, build positional refs, run its bash block (sandboxed), return output |
| `extract_bash_block/1` | Extract the first ```bash fenced block from markdown |
| `build_positional_script/3` | **Injection-safe substitution** — replaces `{{param}}` with double-quoted `"$N"` refs, returns `{script_with_refs, values}` (values passed as argv, never inlined) |
| `substitute_params/3` | ⚠️ LEGACY raw `String.replace` — retained as-is for API/test compatibility, **NOT safe for shell execution** (runtime path does not use it) |
| `run_script/3` | Writes script to a `resolve_tmpdir` temp file, executes via `EvoGit.sandbox_run/4` (Unix) or direct `System.cmd` argv (Windows) with values as positional args |

### CRUD Operations (delegates to `EvoGit.Skills.CRUD`)

| Function | Purpose |
|----------|---------|
| `add_skill/4`, `edit_skill/3`, `remove_skill/2` | Create / update / delete skill files |
| `list_skills/1`, `read_skill/2` | List all skills or read raw markdown |
| `validate_skill_text/1` | Validate skill text will produce a valid skill |

### Hierarchical Enablement (delegates to `EvoGit.Skills.ContextIntegration`)

Skills are **globally defined** in `.agents/skills/` but **hierarchically enabled** per Context Tree node: each `CONTEXT.md` may carry a YAML frontmatter `skill:` list naming skills active at that node. Skills are **inherited downward** — enabling at a parent node makes the skill available to all agents in that subtree.

| Function | Purpose |
|----------|---------|
| `enable_skill/3` | Add a skill name to a node's CONTEXT.md frontmatter (avoids redundant entries if already enabled here/above) |
| `disable_skill/3` | Remove a skill name from a node's CONTEXT.md frontmatter |
| `hierarchical_skill_names/2` | Walk root→node, collecting all inherited skill names (used by agent loop to filter available skills) |
| `where_enabled/2` | Search all CONTEXT.md files to find which nodes have a skill enabled, reported relative to the given checkout root (works for a worktree root) |
| `extract_context_skill_names/1` | Parse a CONTEXT.md's `skill:` frontmatter field |
| `remove_skill_from_all_contexts/2` | Clean up all CONTEXT.md references (used when deleting a skill) |

Agent-loop startup pipeline (`EvoGit.Agent`): `load_skills/1` → `hierarchical_skill_names/2` → `filter_skills/2` → `to_tool_schemas/1`. Only skills enabled at/above the agent's node become LLM-callable tools.

### Skill Struct (`EvoGit.Skills.Skill`)

Fields: `name`, `description`, `parameters` (list of `{name, type, description, required, default}` maps), `body`, `file_path`.

## Security Design

- **Positional substitution — values NEVER enter the script text.** Text-level quoting is provably unsafe in bash (a `"`-containing value inside a double-quoted placeholder region can break any quoting wrapper). `build_positional_script/3` iterates `parameters` in list order, replacing ALL occurrences of each `{{param}}` with a double-quoted positional ref `"$N"` (N = 1-indexed); returns `{script_with_refs, values}` (`values` = resolved via `get_param_value/2`: provided arg → default → empty string). Works for bare tokens (`DEBUG={{debug}}` → `DEBUG="$1"`), double-quoted contexts (`echo "{{name}}"` → `echo ""$1""`), and partial-token concatenation. **Caveat**: placeholders inside SINGLE quotes (`'{{name}}'`) render literally — only bare and double-quoted contexts are supported.
- `execute_skill/3` passes `values` to bash as **argv** (`$1..$N`): `EvoGit.sandbox_run(repo_path, "bash", [tmp_file | values], nil)` on Unix, `System.cmd(bash_path, [tmp_file | values], ...)` on Windows. Both arg-list forms are injection-safe — no metacharacter in a value (`;`, backticks, `$(...)`, quotes) can execute; values echo literally.
- **Sandbox routing**: `run_script/3` (Unix) writes the script to `Path.join(EvoGit.Sandbox.resolve_tmpdir(), "evogit_skill_<unique>.sh")` — NOT `System.tmp_dir!()` (resolve_tmpdir guarantees a dir under `/tmp`/`/var/tmp`, which the Linux systemd-run backend grants via `ReadWritePaths=-<...>` and macOS sandbox-exec allows via tmp write rules). chmod 0o755, then `EvoGit.sandbox_run(repo_path, "bash", [tmp_file | values], nil)` → `{output, exit_code}`; in test env the `Linux.enabled?/0` `@mix_env == :test` gate routes to the plain-bash path (hermetic tests). Output: `"Skill executed successfully:\n#{String.trim(output)}"` (exit 0) / `"Skill failed with exit code N:\n#{String.trim(output)}"` (non-zero). Tmp file removed best-effort (`File.rm/1` result ignored). Windows: bash-not-found error branch; direct `System.cmd(bash_path, [tmp_file | values], ...)` (no sandbox; argv execution is injection-safe).
- **Windows bash resolution is PATH-only** (`executor.ex:201-204` `System.find_executable("bash")`): the vendored MinGit that ships in a desktop release is under `<priv>/vendor/windows-x64/mingit/` and is NOT put on PATH, and it contains NO `bash.exe` (per Git for Windows' MinGit docs the POSIX shell ships as `sh` only — `/usr/bin/bash` is deliberately absent; `EvoGit.Executable.resolve/1` knows only `git`/`rg` anyway), so on a Windows desktop install every bash skill returns the "Install Git for Windows" error unless the user's own Git for Windows bash is on PATH; the branch degrades gracefully (no raise).
- **`substitute_params/3` legacy warning**: raw `String.replace` inlines values verbatim into the script text — LLM-controlled values containing shell metacharacters would execute. NOT safe for execution, not used by the runtime path; retained as-is for API/test compatibility (pinned by `skills_test.exs`); its `@doc` carries an explicit warning.
- **Security tests** (`executor_security_test.exs` in this node, `async: false`): pinned raw `substitute_params/3` behavior, `build_positional_script/3` refs/values/fallbacks, and end-to-end injection resistance through the FULL `Executor.execute/4` path (real bash; payloads `; rm -rf <sentinel>; #`, backtick `touch <marker>`, `$(touch <marker>)` — sentinel must survive, marker must not be created, literal payload appears in output).

## Path Resolution & Commit Ownership

- **Every root/path argument in this API is a repo checkout root (worktree)** — the `repo_root`/`repo_path` parameter of `add_skill/4`, `edit_skill/3`, `remove_skill/2`, `list_skills/1`, `read_skill/2`, `load_skills/1`, `enable_skill/3`, `disable_skill/3`, `hierarchical_skill_names/2`, `where_enabled/2` and `remove_skill_from_all_contexts/2`. The skill tools pass the agent's WORKTREE root (`Process.get(:repo_path)` = `<repo_root>/.genesis/workers/worker_T*`), so skill files and enablement edits land inside the worktree and are covered by the agent's commit / auto-commit fallback / review diff / branch merge like any other worktree file.
- `EvoGit.Skills.CRUD` performs **no git operation at all** — only `File.mkdir_p!`/`File.write`/`File.rm` (`crud.ex:64`, `:99`, `:125`, `:197`); committing is left to the caller.
- The 5 mutating skill tools (`skill_add`, `skill_edit`, `skill_remove`, `skill_enable`, `skill_disable`) commit their touched files via the shared `EvoGit.Agent.Tools.Shared.commit_files/4` helper (`repo_path`, `repo_root`, files, message), gated by a default-on `commit` option — exactly the files they wrote, never `git add --all`.
- `load_skills/1` reads ONLY `<repo_root>/.agents/skills/` (`skills.ex:76-77`) — there is no global/config-dir skills path — so skills are read from the same checkout root they are written to.
- `where_enabled/2` reports enablement **relative to the given checkout root** and works for a worktree root: `find_all_context_files/1` applies its `.genesis` worktree exclusion to the path RELATIVE to the scan root, so a worktree-rooted scan sees that worktree's own CONTEXT.md chain while worktrees nested below a normal repo root stay excluded.
- `EvoGit.Agents.SkillExtractor` (write scope stated in its prompt only), reached via `EvoGit.Runtime.SkillExtraction.run/1` ← task type `:extract_skills` (dashboard Review → "Extract Skills", `apps/evo_dash/.../review_live.ex:926`), writes through the same `skill_add` tools.

## CONTEXT.md Rewrite Semantics (data-safety notes)

- `enable_skill/3` / `disable_skill/3` REGENERATE a node's whole file rather than editing it surgically: the body is re-emitted from `parse_frontmatter/1`'s `String.trim`ed body, and non-`skill` keys are re-serialized by the naive `yaml_kv/2` (`"#{key}: #{value}"`, list values `"key:" <> "  - item"` lines). Nested maps, multi-line strings, or values containing `:`/`#`/quotes can therefore be re-emitted as invalid or lossy YAML (an unparseable frontmatter afterwards makes `extract_context_skill_names/1` return `[]`, silently losing enablement).
- `remove_skill_from_all_contexts/2` is the ONLY batch entry point (`context_integration.ex:232-252`): it rewrites every matching CONTEXT.md under the passed checkout root. `find_all_context_files/1` skips `.git/_build/deps/node_modules` and `.genesis` worktrees (judged on the path RELATIVE to the scan root) but relies on `Path.wildcard` without `match_dot: true`, so CONTEXT.md files under hidden directories (e.g. `.github/`) are never found or cleaned.

## Constraints

- Skill names use `^[a-z][a-z0-9_-]*$` (case-insensitive); files named `{name}.md`
- Skills reload on every `load_skills/1` call (no caching); case-insensitive fallback lookup
- YAML frontmatter parsed with `yaml_elixir`; bash scripts run in repo root
- Skill tool calls are dispatched dynamically: `EvoGit.Agent.Tools.execute_tool/5` has a catch-all clause that reloads skills via `load_skills/1` and calls `execute/4` when the tool name matches a skill. The statically-named `skill_*` management tools (skill_add, skill_edit, etc.) are dispatched by name first.
- Skill management tools live in `./lib/evo_git/agent/tools/skill/` (SkillAdd, SkillEdit, SkillRemove, SkillRead, SkillList, SkillEnable, SkillDisable, SkillWhere)

## Skill File Format

YAML frontmatter delimited by `---`, containing `name` (required), `description`, and `parameters` list. Body is free-form markdown; the first ```bash fenced block is the executable script. `{{param_name}}` placeholders are substituted with argument values at runtime.

## Execution Model

1. **Find** the skill by name in the loaded list
2. **Extract** the first ```bash code block from the body
3. **Substitute** `{{param_name}}` with positional references (`"$N"`), passing the values as bash argv — values never enter the script text (see Security Design)
4. **Execute** via `EvoGit.sandbox_run/4` (Unix; systemd-run on Linux, sandbox-exec on macOS) or direct `System.cmd` argv (Windows) in the repo directory
5. **Return** stdout/stderr; if no bash block found, return body text as-is
