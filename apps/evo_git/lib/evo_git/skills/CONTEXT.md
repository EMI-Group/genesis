# EvoGit.Skills — Dynamic Skill Tools System

## Intent

Skills are **custom tools defined as markdown files** in `<repo_root>/.agents/skills/`.
Each file has YAML frontmatter (name, description, parameters) and a markdown body
(typically a bash code block). Skills are loaded at runtime as LLM-callable tools,
enabling project-specific automation without modifying EvoGit source.

## API Surface

### `EvoGit.Skills` — Key Functions

| Function | Purpose |
|----------|---------|
| `load_skills/1` | Parse all `.md` files from `.agents/skills/` into `[Skill.t()]` |
| `to_tool_schemas/1` | Convert skills to `ReqLLM` tool schemas for the LLM |
| `execute/4` | Find a skill by name, substitute `{{params}}`, run its bash block, return output |
| `validate_skill_text/1` | Validate skill text will produce a valid skill |
| `skill_names/1`, `find_skill/2` | Query loaded skills by name |

### CRUD Operations

| Function | Purpose |
|----------|---------|
| `add_skill/4`, `edit_skill/3`, `remove_skill/2` | Create / update / delete skill files |
| `list_skills/1`, `read_skill/2` | List all skills or read raw markdown |

### Hierarchical Enablement (Spatial Dimension)

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

## Skill File Format

YAML frontmatter delimited by `---`, containing `name` (required), `description`, and `parameters` list. Body is free-form markdown; the first ```bash fenced block is the executable script. `{{param_name}}` placeholders are substituted with argument values at runtime.

## Execution Model

1. **Find** the skill by name in the loaded list
2. **Extract** the first ```bash code block from the body
3. **Substitute** `{{param_name}}` placeholders with actual arguments
4. **Execute** the script via bash in the repo directory
5. **Return** stdout/stderr; if no bash block found, return body text as-is

## Constraints

- Skill names use `^[a-z][a-z0-9_-]*$` (case-insensitive); files named `{name}.md`
- Skills reload on every `load_skills/1` call (no caching); case-insensitive fallback lookup
- YAML frontmatter parsed with `yaml_elixir`; bash scripts run in repo root
- Skill tool calls are dispatched dynamically: `EvoGit.Agent.Tools.execute_tool/5` has a catch-all clause that reloads skills via `load_skills/1` and calls `execute/4` when the tool name matches a skill. The statically-named `skill_*` management tools (skill_add, skill_edit, etc.) are dispatched by name first.
- Skill management tools live in `./lib/evo_git/agent/tools/skill/` (SkillAdd, SkillEdit, SkillRemove, SkillRead, SkillList, SkillEnable, SkillDisable, SkillWhere)

## Routing Table

Leaf module — no child subdirectories.
