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

## Routing Table

Leaf module — no child subdirectories.
