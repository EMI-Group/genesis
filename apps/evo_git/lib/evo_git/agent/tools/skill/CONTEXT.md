# EvoGit.Agent.Tools.Skill — Skill Management Tools

## Intent
LLM tool modules for managing **skills** — markdown files with YAML frontmatter under `<worktree>/.agents/skills/<name>.md` whose body may carry a ```bash block (executed by `EvoGit.Skills.Executor`). Eight tools cover file CRUD plus hierarchical enable/disable via a `skill:` list in per-node `CONTEXT.md` frontmatter.
All eight read AND write the agent's **worktree** (`repo_path`), and the five file-mutating ones commit their own writes.

## Routing Table
Leaf module — no child subdirectories.
Backing API layer (read these for semantics): `../../skills.ex` (`EvoGit.Skills`, pure delegator), `../../skills/crud.ex` (`CRUD` — file create/read/edit/remove), `../../skills/context_integration.ex` (`ContextIntegration` — CONTEXT.md frontmatter enable/disable/query), `../../skills/executor.ex` (`Executor` — runtime execution of a skill's bash block, NOT used by these tools), `../../skills/skill.ex` (`%Skill{}`).

## API Surface

| Module | File | Tool name | Arity | Write? | Commits? | Path it touches |
|---|---|---|---|---|---|---|
| `SkillAdd` | `skill_add.ex` | `skill_add` | 3 (`args, repo_path, repo_root`) | write | yes | `<repo_path>/.agents/skills/<name>.md` |
| `SkillEdit` | `skill_edit.ex` | `skill_edit` | 3 | write | yes | `<repo_path>/.agents/skills/<name>.md` |
| `SkillRemove` | `skill_remove.ex` | `skill_remove` | 3 | write | yes | deletes `<repo_path>/.agents/skills/<name>.md` + rewrites every `CONTEXT.md` under `repo_path` that enabled it (ONE commit with all touched paths) |
| `SkillEnable` | `skill_enable.ex` | `skill_enable` | 4 (`args, repo_path, repo_root, node_path`) | write | yes | `<Platform.safe_expand(node_path, repo_path)>/CONTEXT.md` |
| `SkillDisable` | `skill_disable.ex` | `skill_disable` | 4 | write | yes | `<Platform.safe_expand(node_path, repo_path)>/CONTEXT.md` |
| `SkillList` | `skill_list.ex` | `skill_list` | 3 | read | no | reads `<repo_path>/.agents/skills/`; hierarchical mode (`node_path`) reads the worktree CONTEXT.md chain |
| `SkillRead` | `skill_read.ex` | `skill_read` | 3 | read | no | reads `<repo_path>/.agents/skills/<name>.md` |
| `SkillWhere` | `skill_where.ex` | `skill_where` | 3 | read | no | scans `CONTEXT.md` files under `repo_path` |

All `schema/0` use `ReqLLM.tool/2` with a no-op `callback`. Read/validate args via `Shared.fetch_string_arg/2`. The five writers additionally declare a `commit` boolean (default true) and validate it via `Shared.validate_commit/1`.

## Tool Repo-Path Contract (repo_path vs repo_root)

Tool dispatch passes TWO roots (`tool_dispatch.ex:959-980`, call at `:1169-1175`):
- `repo_path` = `Process.get(:repo_path)` (`tool_dispatch.ex:961`, set at `runner.ex:256`) = the agent's transient **WORKTREE** `<repo_root>/.genesis/workers/worker_T<n>_A<m>` (`dispatch.ex:198-203`).
- `repo_root` = `Process.get(:genesis_repo_root)` (`tool_dispatch.ex:941-942`, set at `runner.ex:212`) = the agent's **REAL repo root** — the main working copy (`resolve_agent_repo_root/2`, `dispatch.ex:522-558`; worktree suffix stripped for subagents).
- For repo-less agents both are the Genesis source root / placeholder (`runner.ex:243-247`) and write tools are blocked entirely.

**All eight skill tools pass `repo_path` (the WORKTREE) to every `EvoGit.Skills` call** — skill files therefore live in the same tree the agent commits from, and are reviewable on the agent's `evogit-agent-*` branch. `repo_root` is only forwarded to `Shared.commit_files/4` (the sandbox repo root).
`skill_enable`'s `.agents/skills/<name>.md` existence pre-check also resolves against `repo_path`.

## Commit Behaviour (the five mutating writers)

`skill_add`, `skill_edit`, `skill_remove`, `skill_enable`, `skill_disable` accept a `commit` argument (boolean, default `true`; non-booleans are rejected with `"Argument 'commit' must be a boolean, got: ..."`). On a successful mutation they stage and commit exactly the paths they touched via the single shared helper `Shared.commit_files/4` (never `git add --all`; `git commit -F <tmpfile>`; co-author trailer config-gated), formatted by `Shared.maybe_commit_result/6` — which appends `"\n\nCommitted:\n" <> output` to the result string on `{:ok, output}`, returns the descriptive error message on `{:error, reason}`, and returns the result unchanged when `commit` is false.

Commit messages: `Add skill <name>`, `Edit skill <name>`, `Remove skill <name>`, `Enable skill <name> at <node_path>`, `Disable skill <name> at <node_path>`.

**No commit on a non-mutating outcome**: `skill_enable`'s `:already_enabled_here` / `:already_enabled_above` and `skill_disable`'s `:not_enabled` return their informational message without touching git; every error path returns its error string.

**Touched-path collection**: `skill_add`/`skill_edit` stage the absolute path the skills API returned, made relative via `Path.relative_to(file_path, repo_path)`. `skill_enable`/`skill_disable` stage `Path.join(<node_path>, "CONTEXT.md")`. `skill_remove` collects its paths **before** mutating anything — the skill file (resolved through the parsed skill list so a case-insensitively matched filename is staged correctly: `EvoGit.Skills.load_skills/1` + `EvoGit.Skills.find_skill/2`, falling back to `EvoGit.Skills.skills_dir()/<name>.md`) plus every `CONTEXT.md` that currently enables the skill (`Enum.map(EvoGit.Skills.where_enabled(name, repo_path), &Path.join(&1, "CONTEXT.md"))`) — then stages them all in ONE commit after `remove_skill/2` + `remove_skill_from_all_contexts/2` have run. The tool layer duplicates no scan logic: whatever `where_enabled/2` enumerates is what the commit stages.

## Write-Tool Classification

`tools.ex:42-58` `@write_tools` includes `skill_add skill_edit skill_remove skill_enable skill_disable` (NOT `skill_list`/`skill_read`/`skill_where`). `serial_tool?/1` (`tools.ex:249-276`) derives `@serial_tools = @write_tools -- ["run_bash","run_powershell","run_git","curl"]`, so all five skill writers are SERIAL (executed one-at-a-time in the parent agent process by `ToolDispatch.batch_execute_tools/4`) — which is also what makes their read-modify-write-then-commit sequences safe within a batch. Classification drives the repo-less / read-only-foreign-repo write gates (`tools.ex:224-232,284-330`) and serialization.

## Known Issues

- **`skill_where` and `skill_remove`'s CONTEXT.md cleanup enumerate nothing inside a real worktree.** `EvoGit.Skills.ContextIntegration.find_all_context_files/1` (`lib/evo_git/skills/context_integration.ex:262-282`) rejects every path containing `/.genesis/`, but a real agent worktree IS `<repo_root>/.genesis/workers/worker_T<n>_A<m>` — so its `Path.wildcard(<repo_path>/**/CONTEXT.md)` (and therefore `where_enabled/2` and `remove_skill_from_all_contexts/2`) returns `[]` at runtime: `skill_where` reports "not enabled at any node" and `skill_remove` deletes the skill file but cleans up no CONTEXT.md reference (its commit then stages only the skill file). The same helper omits `match_dot: true`, so CONTEXT.md files under hidden directories (e.g. `.github/`) are never found either. This exclusion lives in the backing layer under `lib/evo_git/skills/` — these tools deliberately reuse `where_enabled/2` rather than duplicate the scan.

## Constraints
- Skill files live in `.agents/skills/` — hardcoded in `EvoGit.Skills.skills_dir/0` (`skills.ex:63`), not configurable by the tool layer.
- Skill names: letters, numbers, hyphens, underscores, must start with a letter (`crud.ex:26-28`); filenames are `<name>.md` with an exact-then-case-insensitive lookup (`crud.ex:225-245`).
- None of these tools call `Shared.validate_file_scope/3` (no spatial scope check — same as the read tools), and none of them writes outside the repo tree (no config-dir / temp-dir / `<data_dir>` writes).
- Tools return plain strings suitable for LLM consumption; they never raise.
