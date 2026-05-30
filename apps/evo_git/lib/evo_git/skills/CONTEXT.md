# EvoGit.Skills — Dynamic Skill Tools System

## Intent

Skills are **custom tools defined as markdown files** in `<repo_root>/.agents/skills/`.
Each skill file uses **YAML frontmatter** to declare metadata (name, description, parameters),
and a **markdown body** that defines what the skill does (typically a bash command block).

Skills are parsed and loaded at runtime as **dynamically-generated tools** that agents can
call alongside built-in tools. This allows project-specific, reusable automation without
modifying EvoGit source code.

## API Surface

### Main Module: `EvoGit.Skills`
| Function | Signature | Purpose |
|----------|-----------|---------|
| `load_skills/1` | `(repo_root) -> [Skill.t()]` | Load and parse all `.md` files from `.agents/skills/`. Returns empty list if dir missing. |
| `parse_skill_file/1` | `(file_path) -> Skill.t() \| nil` | Parse a single skill markdown file |
| `parse_frontmatter/1` | `(content) -> {:ok, metadata, body} \| {:error, reason}` | Parse YAML frontmatter from markdown content |
| `parse_yaml_simple/1` | `(yaml_str) -> {:ok, map} \| {:error, reason}` | Parse a simplified YAML subset (string scalars + parameters lists) |
| `validate_skill_text/1` | `(content) -> {:ok, name} \| {:error, reason}` | Validate that skill text will produce a valid skill |
| `to_tool_schemas/1` | `([Skill.t()]) -> [ReqLLM.Tool.t()]` | Convert skills to `ReqLLM` tool schemas for LLM consumption |
| `execute/4` | `(skills, name, args, repo_path) -> String.t()` | Execute a skill by name with arguments |
| `extract_bash_block/1` | `(markdown) -> String.t() \| nil` | Extract first ```bash code block from markdown |
| `substitute_params/3` | `(script, parameters, args) -> String.t()` | Substitute `{{param}}` placeholders with argument values |
| `find_skill/2` | `([Skill.t()], name) -> Skill.t() \| nil` | Find a skill by name |
| `skill_names/1` | `([Skill.t()]) -> [String.t()]` | Get all skill names |

### CRUD Management Functions
| Function | Signature | Purpose |
|----------|-----------|---------|
| `add_skill/4` | `(repo_root, content, description, params) -> {:ok, path} \| {:error, reason}` | Create a new skill file |
| `edit_skill/3` | `(repo_root, name, new_content) -> {:ok, path} \| {:error, reason}` | Replace an existing skill's content |
| `remove_skill/2` | `(repo_root, name) -> :ok \| {:error, reason}` | Delete a skill file by name |
| `list_skills/1` | `(repo_root) -> String.t()` | List all skills with names, descriptions, and parameters |
| `read_skill/2` | `(repo_root, name) -> String.t()` | Read raw markdown content of a skill by name |

### Skill Struct: `EvoGit.Skills.Skill`
| Field | Type | Description |
|-------|------|-------------|
| `name` | `String.t()` | Skill name (from frontmatter or derived from filename) |
| `description` | `String.t()` | Human-readable description |
| `parameters` | `[param()]` | List of parameter maps (`name`, `type`, `description`, `required`, `default`) |
| `body` | `String.t()` | Markdown body (below frontmatter) |
| `file_path` | `String.t()` | Absolute path to the `.md` file |

## Skill File Format

```
---
name: my-skill
description: Does something useful with the project
parameters:
  - name: input_file
    type: string
    description: Path to the input file
    required: true
  - name: output_format
    type: string
    description: Output format (json, yaml, text)
    required: false
    default: json
---

# My Skill

Description of what this skill does...

## Command
```bash
#!/bin/bash
INPUT="{{input_file}}"
FORMAT="{{output_format}}"
echo "Processing $INPUT in $FORMAT format..."
```
```

## Execution Model

When a skill is called by an agent:

1. **Find** the skill by name in the loaded skill list
2. **Extract** the first ```bash code block from the skill body
3. **Substitute** `{{param_name}}` placeholders with actual argument values
4. **Execute** the resulting script via bash in the repo directory
5. **Return** stdout/stderr to the agent

If **no bash code block** is found, the skill's body text is returned as-is,
allowing the agent to use it as instructions with its other tools.

## Constraints

- **Skill files must use YAML frontmatter** (`---` delimiters at top)
- **Every skill must have a `name`** in frontmatter (validated: `^[a-z][a-z0-9_-]*$` case-insensitive)
- **Skills directory**: `<repo_root>/.agents/skills/` (created automatically if missing)
- **Skill filenames**: derived from name as `{name}.md`
- **Bash execution**: Scripts run in the repo root directory, output is captured
- **YAML parsing**: Uses `yaml_elixir` (`~> 2.11`) for frontmatter parsing via `parse_yaml_simple/1`
- **Parameter substitution**: `{{param_name}}` placeholders in bash blocks; missing params use default values or empty strings
- **Skill lookup**: Case-insensitive filename matching as fallback
- **Dynamically loaded**: Skills are reloaded on each `load_skills/1` call (no caching)

## Routing Table

This is a leaf module — no child subdirectories.
