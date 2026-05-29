# EvoGit.Agent.Tools.Skill — Skill Management Tools

## Intent
Contains LLM tool modules for managing reusable skills stored in the `.agents/skills/` directory. Skills are YAML-frontmatter markdown files that encode reusable agent behaviors, instructions, or bash commands. These tools allow agents to discover, read, create, edit, and remove skills at runtime.

## API Surface

### Tool Modules
| Module | File | Tool Name | Purpose | Type |
|--------|------|-----------|---------|------|
| `SkillList` | `skill_list.ex` | `skill_list` | Lists all available skills (name, description, parameters) | Read |
| `SkillRead` | `skill_read.ex` | `skill_read` | Reads the full content of a skill file by name | Read |
| `SkillAdd` | `skill_add.ex` | `skill_add` | Creates a new skill in `.agents/skills/` | Write |
| `SkillEdit` | `skill_edit.ex` | `skill_edit` | Replaces an existing skill's full content | Write |
| `SkillRemove` | `skill_remove.ex` | `skill_remove` | Deletes a skill file by name | Write |

### Dependency
All tools depend on `EvoGit.Skills` (at `../../skills.ex`) which provides:
- `list_skills(repo_root)` — formatted string of all skills
- `read_skill(repo_root, name)` — raw markdown content
- `add_skill(repo_root, content, description, params)` — `{:ok, file_path}` or `{:error, reason}`
- `edit_skill(repo_root, name, new_content)` — `{:ok, file_path}` or `{:error, reason}`
- `remove_skill(repo_root, name)` — `:ok` or `{:error, reason}`

### Pattern
All tools follow the standard EvoGit tool pattern:
- `schema/0` returns a `ReqLLM.tool()` schema with `name`, `description`, `parameter_schema`, and no-op `callback`
- `execute/3` (args, repo_path, repo_root) — 3-arity because these tools operate on `.agents/skills/` rather than the codebase tree, so they don't need `node_path` scope validation
- Argument validation uses `EvoGit.Agent.Tools.Shared`

## Constraints
- All execute functions are 3-arity (no `node_path` scope validation) since `.agents/skills/` is a metadata directory, not part of the spatial codebase tree
- The `EvoGit.Skills` module must exist and be functional for these tools to work at runtime
- Tools return string results suitable for LLM consumption
