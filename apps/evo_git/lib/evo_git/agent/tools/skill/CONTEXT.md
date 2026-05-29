# EvoGit.Agent.Tools.Skill — Skill Management Tools

## Intent

Contains LLM tool modules that allow agents to **manage skills** stored in the `.agents/skills/`
directory at runtime. Skills are YAML-frontmatter markdown files that encode reusable agent
behaviors, instructions, or bash commands. These tools provide full CRUD (create, read, update,
delete, list) operations on the skills directory.

## API Surface

### Tool Modules (3-arity)

| Module | File | Tool Name | Type | Purpose |
|--------|------|-----------|------|---------|
| `SkillAdd` | `skill_add.ex` | `skill_add` | Write | Creates a new skill file in `.agents/skills/`. Takes `content` (full markdown with YAML frontmatter). |
| `SkillEdit` | `skill_edit.ex` | `skill_edit` | Write | Replaces an existing skill's full content. Takes `name` + `content`. Frontmatter name must match. |
| `SkillRemove` | `skill_remove.ex` | `skill_remove` | Write | Deletes a skill file by `name`. Permanently removes the `.md` file. |
| `SkillList` | `skill_list.ex` | `skill_list` | Read | Lists all available skills with names, descriptions, and parameters. No arguments. |
| `SkillRead` | `skill_read.ex` | `skill_read` | Read | Reads the full raw markdown content of a skill by `name`. |

### Common Pattern

All tools follow the standard EvoGit tool pattern:
- `schema/0` returns a `ReqLLM.tool()` schema with `name`, `description`, `parameter_schema`, and a no-op `callback`
- `execute/3(args, repo_path, repo_root)` — **3-arity** (no `node_path`) because skills operate on `.agents/skills/`, not the spatial codebase tree
- Write tools (`SkillAdd`, `SkillEdit`) use `Shared.fetch_string_arg/2` for argument validation
- Read tools (`SkillRead`, `SkillRemove`) use `Shared.fetch_string_arg/2` for the `name` parameter

### Dependency

All tools depend on `EvoGit.Skills` (at `../../skills.ex`) which provides:
- `add_skill/4` — create skill, validates frontmatter, writes `.md` file
- `edit_skill/3` — replace skill content, validates name match in frontmatter
- `remove_skill/2` — delete skill file by name (case-insensitive fallback)
- `list_skills/1` — formatted string of all skills with parameters
- `read_skill/2` — raw markdown content by name

## Constraints

- **All execute functions are 3-arity** — no `node_path` scope validation. The `.agents/skills/` directory is a metadata directory at the repo root, not part of the spatial codebase tree. Tools receive `(args, repo_path, repo_root)` instead of the standard 4-arity `(args, node_path, repo_path, repo_root)`.
- **The `EvoGit.Skills` module** must exist and be functional for these tools to work at runtime
- **Tools return string results** suitable for LLM consumption (success messages or error strings)
- **Skill names use lowercase letters, numbers, hyphens, and underscores** — validated by `EvoGit.Skills.validate_skill_text/1`
- **Skill files live in `.agents/skills/`** — this path is hardcoded in `EvoGit.Skills` and not configurable by the tool layer

## Routing Table

This is a leaf module — no child subdirectories.
