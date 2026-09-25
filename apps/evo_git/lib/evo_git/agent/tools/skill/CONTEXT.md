# EvoGit.Agent.Tools.Skill — Skill Management Tools

## Intent
LLM tool modules for managing **skills** — markdown files with YAML frontmatter under `<repo_root>/.agents/skills/<name>.md` whose body may carry a ```bash block (executed by `EvoGit.Skills.Executor`). Eight tools cover file CRUD plus hierarchical enable/disable via a `skill:` list in per-node `CONTEXT.md` frontmatter.
None of these tools performs ANY git operation — see "No Git Operations" below (this is the reason skill files can end up uncommitted).

## Routing Table
Leaf module — no child subdirectories.
Backing API layer (read these for semantics): `../../skills.ex` (`EvoGit.Skills`, pure delegator), `../../skills/crud.ex` (`CRUD` — file create/read/edit/remove), `../../skills/context_integration.ex` (`ContextIntegration` — CONTEXT.md frontmatter enable/disable/query), `../../skills/executor.ex` (`Executor` — runtime execution of a skill's bash block, NOT used by these tools), `../../skills/skill.ex` (`%Skill{}`).

## API Surface

| Module | File | Tool name | Arity | Write? | Path it touches |
|---|---|---|---|---|---|
| `SkillAdd` | `skill_add.ex` | `skill_add` | 3 (`args, _repo_path, repo_root`) | write | `<repo_root>/.agents/skills/<name>.md` |
| `SkillEdit` | `skill_edit.ex` | `skill_edit` | 3 | write | `<repo_root>/.agents/skills/<name>.md` |
| `SkillRemove` | `skill_remove.ex` | `skill_remove` | 3 | write | deletes `<repo_root>/.agents/skills/<name>.md` + rewrites every `CONTEXT.md` under `repo_root` |
| `SkillEnable` | `skill_enable.ex` | `skill_enable` | 4 (`args, repo_path, repo_root, node_path`) | write | `<safe_expand(node_path, repo_path)>/CONTEXT.md` (**worktree**) |
| `SkillDisable` | `skill_disable.ex` | `skill_disable` | 4 (last arg unused `_repo_root`) | write | `<safe_expand(node_path, repo_path)>/CONTEXT.md` (**worktree**) |
| `SkillList` | `skill_list.ex` | `skill_list` | 3 | read | reads `<repo_root>/.agents/skills/`; hierarchical mode reads the CONTEXT.md chain under `repo_path` |
| `SkillRead` | `skill_read.ex` | `skill_read` | 3 | read | reads `<repo_root>/.agents/skills/<name>.md` |
| `SkillWhere` | `skill_where.ex` | `skill_where` | 3 | read | scans every `CONTEXT.md` under `repo_root` |

All `schema/0` use `ReqLLM.tool/2` with a no-op `callback`. Read/validate args via `Shared.fetch_string_arg/2`.

## Tool Repo-Path Contract (repo_path vs repo_root — the crux)

Tool dispatch passes TWO different roots (`tool_dispatch.ex:959-980`, call at `:1169-1175`):
- `repo_path` = `Process.get(:repo_path)` (`tool_dispatch.ex:961`, set at `runner.ex:256`) = the agent's transient **WORKTREE** `<repo_root>/.genesis/workers/worker_T<n>_A<m>` (`dispatch.ex:198-203`).
- `repo_root` = `Process.get(:genesis_repo_root)` (`tool_dispatch.ex:941-942`, set at `runner.ex:212`) = the agent's **REAL repo root** — the main working copy (`resolve_agent_repo_root/2`, `dispatch.ex:522-558`; worktree suffix stripped for subagents).
- For repo-less agents both are the Genesis source root / placeholder (`runner.ex:243-247`) and write tools are blocked entirely.

Consequence: `skill_add`/`skill_edit`/`skill_remove`/`skill_list`/`skill_read`/`skill_where` act on the **MAIN repo working copy**, while `skill_enable`/`skill_disable` act on the **WORKTREE**. See "Known Issues".

## No Git Operations (definitive)

Grep-verified: no `git`, `Git.*`, `System.cmd`, `Port.open`, `rev_parse`, or `do_git_commit` anywhere in this directory, nor in `skills/crud.ex` / `skills/context_integration.ex`. The only side effects are `File.write/2`, `File.rm/1`, `File.mkdir_p!/1` (`crud.ex:64,99,125,197`; `context_integration.ex:311,322,340`).
`Shared.do_git_commit/3` (the shared stage+commit helper) is called ONLY by `file_create.ex:138` and `make_dir.ex:192` — never by a skill tool. The agent-exit auto-commit fallback commits only `Process.get(:repo_path)` (the worktree) — `dispatch.ex:286-288`.

## Write-Tool Classification

`tools.ex:42-58` `@write_tools` includes `skill_add skill_edit skill_remove skill_enable skill_disable` (NOT `skill_list`/`skill_read`/`skill_where`). `serial_tool?/1` (`tools.ex:249-276`) derives `@serial_tools = @write_tools -- ["run_bash","run_powershell","run_git","curl"]`, so all five skill writers are SERIAL (executed one-at-a-time in the parent agent process by `ToolDispatch.batch_execute_tools/4`). Classification only drives the repo-less / read-only-foreign-repo write gates (`tools.ex:224-232,284-330`) and serialization — it has NO bearing on committing.

## Constraints
- Skill files live in `.agents/skills/` — hardcoded in `EvoGit.Skills.skills_dir/0` (`skills.ex:63`), not configurable by the tool layer.
- Skill names: letters, numbers, hyphens, underscores, must start with a letter (`crud.ex:26-28`); filenames are `<name>.md` with an exact-then-case-insensitive lookup (`crud.ex:225-245`).
- None of these tools call `Shared.validate_file_scope/3` (no spatial scope check — same as the read tools).
- Tools return plain strings suitable for LLM consumption; they never raise.

## Known Issues / Notes for Agents

- **Skill-file writes land in the MAIN repo copy, not the agent worktree** — `SkillAdd.execute` → `Skills.add_skill(repo_root, ...)` (`skill_add.ex:50` → `crud.ex:50-76` → `File.write`); likewise `SkillEdit` (`skill_edit.ex:42`) and `SkillRemove` (`skill_remove.ex:43,46`). Because an agent's commits (and the auto-commit fallback) target `Process.get(:repo_path)` = the worktree (`dispatch.ex:286-288`), these files are left UNTRACKED/UNCOMMITTED in the main repo and never enter the agent's `evogit-agent-*` branch. `skill_remove`'s CONTEXT.md cleanup (`context_integration.ex:232-252` → `find_all_context_files/1`) also rewrites only main-copy `CONTEXT.md` files.
- **Enable/disable write to the WORKTREE**: `SkillEnable` (`skill_enable.ex:59`) and `SkillDisable` (`skill_disable.ex:49`) pass `repo_path` (not `repo_root`) into `enable_skill/3` / `disable_skill/3`, which write `<Platform.safe_expand(node_path, repo_path)>/CONTEXT.md` (`context_integration.ex:162,206,305-345`). They ARE committable, but only into the transient worktree's branch (deleted on worktree reclaim unless committed + merged).
- **Read/write asymmetry**: reads (`skill_list`/`skill_read`/`skill_where`, and the runner's skill-schema load at `runner.ex:156-165`) use `repo_root`; enable/disable write into `repo_path`. `ContextIntegration.where_enabled/2` filters out every path containing `/.genesis/` (`context_integration.ex:266-272`), so `skill_where` can report "not enabled at any node" right after a successful `skill_enable`. `enable_skill`'s "already enabled above" check instead walks the worktree chain via `hierarchical_skill_names/2` (`context_integration.ex:174,289-299`).
- **`skill_enable` existence check vs write path mismatch**: the `.agents/skills/<name>.md` existence check reads `repo_root` (`skill_enable.ex:52-57`) while the frontmatter write targets `repo_path`.
- **Return values carry no commit instruction** — e.g. "Skill created successfully: <path>", "Skill '<n>' enabled at '<path>'. It will be available to agents assigned to this node and its children." None mentions `git add`/commit.
- **No writes outside the repo tree**: no config-dir (`~/.config/genesis`), temp-dir, or `<data_dir>` writes — every path is derived from `repo_root` / `repo_path`.
- **Test gap**: no test exercises these tool modules' `execute` with a distinct `repo_path` ≠ `repo_root` (the API is tested directly on tmp dirs in `test/evo_git/skills_test.exs` / `skills_hierarchical_test.exs`; `tools_test.exs:121-160` pins only the write/serial classification; `reflect_tools_test.exs:396-419` covers the repo-less block).
