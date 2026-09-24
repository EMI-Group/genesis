# EvoGit.Agent.Tools.Skill — Skill Management Tools

## Intent
Contains LLM tool modules that allow agents to **manage skills** stored in the `.agents/skills/` directory at runtime. Skills are YAML-frontmatter markdown files that encode reusable agent behaviors, instructions, or bash commands. These tools provide full CRUD (create, read, update, delete, list) operations on the skills directory.

## Routing Table
Leaf module — no child subdirectories.

## API Surface

### Tool Modules (3-arity)

| Module | File | Tool Name | Type | Purpose |
|--------|------|-----------|------|---------|
| `SkillAdd` | `skill_add.ex` | `skill_add` | Write | Creates a new skill file in `.agents/skills/`. Takes `content` (full markdown with YAML frontmatter). |
| `SkillEdit` | `skill_edit.ex` | `skill_edit` | Write | Replaces an existing skill's full content. Takes `name` + `content`. Frontmatter name must match. |
| `SkillRemove` | `skill_remove.ex` | `skill_remove` | Write | Deletes a skill file by `name`. Permanently removes the `.md` file and cleans its CONTEXT.md enablement entries. |
| `SkillList` | `skill_list.ex` | `skill_list` | Read | Lists all available skills with names, descriptions, and parameters. No arguments. |
| `SkillRead` | `skill_read.ex` | `skill_read` | Read | Reads the full raw markdown content of a skill by `name`. |
| `SkillEnable` | `skill_enable.ex` | `skill_enable` | Write | Adds the skill to a node's CONTEXT.md front matter. |
| `SkillDisable` | `skill_disable.ex` | `skill_disable` | Write | Removes the skill from a node's CONTEXT.md front matter. |
| `SkillWhere` | `skill_where.ex` | `skill_where` | Read | Lists the node paths where a skill is enabled. |

### Common Pattern
- `schema/0` returns a `ReqLLM.tool()` schema with `name`, `description`, `parameter_schema`, and a no-op `callback`
- `execute/3(args, repo_path, repo_root)` — **3-arity** (no `node_path`) because skills operate on `.agents/skills/`, not the spatial codebase tree. `SkillEnable.execute/4` / `SkillDisable.execute/4` additionally take the agent's default `node_path`.
- Write tools (`SkillAdd`, `SkillEdit`, `SkillRemove`, `SkillEnable`, `SkillDisable`) and `SkillRead` use `Shared.fetch_string_arg/2` for argument validation

### Dependency
All tools depend on `EvoGit.Skills` (at `../../skills.ex`):
- `add_skill/4` — create skill, validates frontmatter, writes `.md` file
- `edit_skill/3` — replace skill content, validates name match in frontmatter
- `remove_skill/2` — delete skill file by name (case-insensitive fallback)
- `remove_skill_from_all_contexts/2` — strip the skill from every CONTEXT.md front matter
- `enable_skill/3` / `disable_skill/3` — per-node CONTEXT.md front-matter enablement (`EvoGit.Skills.ContextIntegration`)
- `list_skills/1` — formatted string of all skills with parameters
- `read_skill/2` — raw markdown content by name
- `where_enabled/2` — node paths that enable a skill

## Same-Path Mutation Serialization

Parallel standard tool calls from ONE assistant message each run in their OWN process (`EvoGit.Agent.ToolDispatch.batch_execute_tools/4`), so a non-atomic read-modify-write on the same path would silently lose all but the last write (every call still reports success).

Every MUTATING skill tool therefore wraps its read-modify-write in `EvoGit.Agent.Tools.Shared.with_file_lock/2` — `:global.trans` keyed on the mutated file's canonical (expanded absolute) path, released on success/error/raise:

| Tool | Lock key (mutated file) |
|------|-------------------------|
| `SkillAdd` | the skill file it will create — `<repo_root>/.agents/skills/<frontmatter name>.md` (`EvoGit.Skills.skills_dir/0` + `EvoGit.Skills.CRUD.skill_filename/1`); unparseable content (no name) falls back to the skills directory, and `add_skill/4` then rejects it without writing |
| `SkillEdit` | the skill file resolved from `name` (`<repo_root>/.agents/skills/<name>.md`) |
| `SkillRemove` | the skill file, PLUS each CONTEXT.md the reference cleanup may rewrite (`EvoGit.Skills.ContextIntegration.find_all_context_files/1`, locked in sorted order so concurrent removals stay deadlock-free) |
| `SkillEnable` | the target `CONTEXT.md` (`EvoGit.Platform.safe_expand(node_path, repo_path)` + `CONTEXT.md`) |
| `SkillDisable` | the target `CONTEXT.md` (same resolution as `SkillEnable`) |

The read-only tools `SkillList`, `SkillRead`, and `SkillWhere` perform NO file mutation (they only read skill files / CONTEXT.md front matter) and take no lock.

## Constraints
- **All execute functions are 3-arity** — no `node_path` scope validation. `.agents/skills/` is a metadata directory at the repo root, not part of the spatial codebase tree. Tools receive `(args, repo_path, repo_root)` instead of the standard 4-arity `(args, node_path, repo_path, repo_root)`. (`SkillEnable`/`SkillDisable` are the exception: 4-arity, taking the agent's default node path as the last argument.)
- **`EvoGit.Skills`** must exist and be functional for these tools to work at runtime
- **Tools return string results** suitable for LLM consumption (success messages or error strings) — locking changes no user-visible message, error string, scope check, or validation
- **Skill names use lowercase letters, numbers, hyphens, and underscores** — validated by `EvoGit.Skills.validate_skill_text/1`
- **Skill files live in `.agents/skills/`** — path hardcoded in `EvoGit.Skills`, not configurable by the tool layer
- **Locking reuses `EvoGit.Agent.Tools.Shared.with_file_lock/2`** — never re-implement lock logic here; the same helper is what serializes `write_file`/`edit_file`/`write_context`/`edit_context` (so an `edit_file` on a CONTEXT.md and a `skill_enable` on that same CONTEXT.md are mutually exclusive too)
