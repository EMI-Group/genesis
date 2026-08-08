# EvoGit.Skills — Dynamic Skill Tools System

## Intent

Skills are **custom tools defined as markdown files** in `<repo_root>/.agents/skills/`.
Each file has YAML frontmatter (name, description, parameters) and a markdown body
(typically a bash code block). Skills are loaded at runtime as LLM-callable tools,
enabling project-specific automation without modifying EvoGit source.

## Routing Table

None — leaf directory (modules: `skills.ex`, `skill.ex`, `executor.ex`, `crud.ex`, `context_integration.ex`).

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

### Execution (delegates to `EvoGit.Skills.Executor`)

| Function | Purpose |
|----------|---------|
| `execute/4` | Find a skill by name, build positional refs, run its bash block (sandboxed), return output |
| `extract_bash_block/1` | Extract the first ```bash fenced block from markdown |
| `build_positional_script/3` | **Injection-safe substitution** — replaces `{{param}}` with `"$N"` refs, returns `{script_with_refs, values}` (values passed as argv, never inlined) |
| `substitute_params/3` | ⚠️ LEGACY raw `String.replace` — kept byte-for-byte for API/test compatibility, **NOT safe for shell execution** (runtime path does not use it) |
| `run_script/3` | Writes script to a `resolve_tmpdir` temp file, executes via `EvoGit.sandbox_run/4` (Unix) or direct `System.cmd` argv (Windows) with values as positional args |

### CRUD Operations (delegates to `EvoGit.Skills.CRUD`)

| Function | Purpose |
|----------|---------|
| `add_skill/4`, `edit_skill/3`, `remove_skill/2` | Create / update / delete skill files |
| `list_skills/1`, `read_skill/2` | List all skills or read raw markdown |
| `validate_skill_text/1` | Validate skill text will produce a valid skill |

### Hierarchical Enablement (delegates to `EvoGit.Skills.ContextIntegration`)

Skills are **globally defined** in `.agents/skills/` but **hierarchically enabled** per Context Tree node. Each `CONTEXT.md` may carry a YAML frontmatter `skill:` list naming skills active at that node. Skills are **inherited downward**: enabling at a parent node makes the skill available to all agents in that subtree.

| Function | Purpose |
|----------|---------|
| `enable_skill/3` | Add a skill name to a node's CONTEXT.md frontmatter (avoids redundant entries if already enabled here/above) |
| `disable_skill/3` | Remove a skill name from a node's CONTEXT.md frontmatter |
| `hierarchical_skill_names/2` | Walk root→node, collecting all inherited skill names (used by agent loop to filter available skills) |
| `where_enabled/2` | Search all CONTEXT.md files to find which nodes have a skill enabled |
| `extract_context_skill_names/1` | Parse a CONTEXT.md's `skill:` frontmatter field |
| `remove_skill_from_all_contexts/2` | Clean up all CONTEXT.md references (used when deleting a skill) |

The agent loop (`EvoGit.Agent`, lines ~120-131) loads skills at startup: `load_skills/1` → `hierarchical_skill_names/2` → `filter_skills/2` → `to_tool_schemas/1`. Only skills enabled at/above the agent's node become LLM-callable tools.

### Skill Struct (`EvoGit.Skills.Skill`)

Fields: `name`, `description`, `parameters` (list of `{name, type, description, required, default}` maps), `body`, `file_path`.

## Security Design

### Positional substitution — values NEVER enter the script text

Text-level quoting is provably unsafe in all bash contexts (a `"`-containing value placed
inside a double-quoted placeholder region can break out of any quoting wrapper). The runtime
execution path therefore uses a **positional-parameter scheme** instead:

- `EvoGit.Skills.Executor.build_positional_script/3` iterates `parameters` in list order and
  replaces ALL occurrences of each `{{param}}` in the script with a **double-quoted positional
  reference** `"$N"` (N = 1-indexed parameter position). It returns `{script_with_refs, values}`
  where `values` is the list of resolved values (`get_param_value/2`: provided arg → default →
  empty string) in the same order.
- `execute_skill/3` passes `values` to bash as **argv** (`$1..$N`) — via
  `EvoGit.sandbox_run(repo_path, "bash", [tmp_file | values], nil)` on Unix and
  `System.cmd(bash_path, [tmp_file | values], ...)` on Windows. Both arg-list forms are
  injection-safe: no metacharacter in a value (`;`, backticks, `$(...)`, quotes) can execute,
  and values are echoed literally.
- The `{{param}}` contract still works for skill scripts: bare tokens (`DEBUG={{debug}}` →
  `DEBUG="$1"`), inside double quotes (`echo "{{name}}"` → `echo ""$1""`), and partial-token
  concatenation all resolve correctly.
- **Caveat**: a placeholder inside SINGLE quotes (`'{{name}}'`) now renders literally (the
  quoted string contains `"$N"` verbatim) — only bare and double-quoted contexts are supported.

### Sandbox routing

`run_script/3` (Unix branch) writes the script to
`Path.join(EvoGit.Sandbox.resolve_tmpdir(), "evogit_skill_<unique>.sh")` — NOT
`System.tmp_dir!()`: `resolve_tmpdir/0` guarantees a dir under `/tmp` or `/var/tmp`, which the
Linux systemd-run backend explicitly grants via `ReadWritePaths=-<...>` (sandbox/linux.ex) and
the macOS sandbox-exec profile allows via tmp write rules (sandbox/macos.ex). The script is
chmod 0o755, then executed via `EvoGit.sandbox_run(repo_path, "bash", [tmp_file | values], nil)`
→ `{output, exit_code}`. On Linux this yields systemd-run isolation (values arrive as
positional params through the sandbox's own per-arg shell-escaping wrapper); in test env the
`Linux.enabled?/0` `@mix_env == :test` gate routes to the disabled plain-bash path, so tests
stay hermetic. Output formatting is unchanged:
`"Skill executed successfully:\n#{String.trim(output)}"` (exit 0) /
`"Skill failed with exit code N:\n#{String.trim(output)}"` (non-zero). The tmp file is removed
best-effort (`File.rm/1` result ignored). Windows keeps its status quo: bash-not-found error
branch unchanged, direct `System.cmd(bash_path, [tmp_file | values], ...)` (no sandbox on
Windows; argv execution is injection-safe).

### `substitute_params/3` — legacy warning

`substitute_params/3` is a **raw `String.replace`** that inlines values verbatim into the
script text — LLM-controlled argument values containing shell metacharacters would execute.
It is **NOT safe for execution** and is no longer used by the runtime path; it is kept
byte-for-byte for API and test compatibility (pinned by `skills_test.exs`). Its `@doc` carries
an explicit warning.

### Security tests

`executor_security_test.exs` in this node covers: pinned `substitute_params/3` raw behavior,
`build_positional_script/3` refs/values/fallbacks, and end-to-end injection resistance through
the FULL `Executor.execute/4` path (real bash; payloads `; rm -rf <sentinel>; #`, backtick
`touch <marker>`, `$(touch <marker>)` — sentinel must survive, marker must not be created, and
the literal payload must appear in the output). The file currently lives in the lib tree
because the app test tree is outside this node's write scope — it is a normal ExUnit test file
(`async: false`) awaiting relocation to `apps/evo_git/test/evo_git/`.

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
3. **Substitute** `{{param_name}}` placeholders with positional references (`"$N"`) and pass
   the values as bash argv — values never enter the script text (see Security Design)
4. **Execute** the script via `EvoGit.sandbox_run/4` (Unix; systemd-run on Linux,
   sandbox-exec on macOS) or direct `System.cmd` argv (Windows) in the repo directory
5. **Return** stdout/stderr; if no bash block found, return body text as-is
