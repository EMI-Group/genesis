# EvoGit Core Library — `lib/evo_git/`

## Intent
Core source of the `:evo_git` OTP application: the Agent system (LLM-powered tool-calling loops), AgentScheduler (GenServer for worktree pools, ETS state, slot management), Core domain types (ContextNode, PhyloGraphNode, ForeignRepo), Git adapter, and Runtime phases (Genesis, Evolution). Supports multi-repo operation — foreign repos configured via `genesis.toml` or CLI flags enable cross-repo subagent spawning into isolated worktrees.

## Routing Table
- `./agent/` → Agent behaviour, tool library, context compression, subagent processing
- `./agents/` → Agent implementations (Manager, Executor, TaskScheduler, CodebaseInvestigator, CodebaseLead, ContextExtractor, SkillExtractor, GenesisPlanner)
- `./agent_scheduler/` → AgentState, SchedMeta, Slots, Worktrees — ETS schemas and helpers
- `./core/` → ContextNode, PhyloGraphNode, ForeignRepo data structures
- `./adapters/` → Git CLI adapter — all git operations go through this module
- `./runtime/` → Genesis, Evolution, PR helpers, Skill Extraction
- `./config/` → Unified 3-level configuration resolver (defaults → user TOML → runtime overrides), schema definitions, LLM catalog, platform detection, project config
- `./sandbox/` → Multi-platform sandbox backends (Linux systemd-run, macOS sandbox-exec, passthrough)
- `./skills/` → Dynamic skill tools system — YAML-frontmatter markdown skills as LLM-callable tools
- `./store/` → SQLite persistence codec — pure serialization for `EvoGit.Store`
- `./task_registry/` → TaskRegistry support modules — Cleanup, Diagnostics, Lease, ResumeContext, RuntimeOpts, TaskExecutor

## API Surface

### Top-Level Modules
| Module | Description |
|---|---|
| `EvoGit` | Sandboxing utilities, safe shell command execution |
| `EvoGit.Application` | OTP application callback — starts AgentScheduler |
| `EvoGit.Agent` | Behaviour module — `use EvoGit.Agent` injects agent loop, tool dispatch, subagent management |
| `EvoGit.AgentSpec` | Structured spec for spawning agents (context_node, agent_module, objective, repo_id) |
| `EvoGit.AgentScheduler` | GenServer — worktree pool, agent lifecycle, subagent spawning, ETS state, foreign repo registry |
| `EvoGit.Task` | High-level orchestration: `mutate/3`, `diagnose/3`, `resolve_conflict/3` |
| `EvoGit.Runtime` | Top-level coordinator: Genesis and Evolution phases |
| `EvoGit.ProjectConfig` | Reads `genesis.toml` from repo root |
| `EvoGit.Config` | Unified 3-level configuration resolver (defaults → user TOML → runtime overrides) |
| `EvoGit.Review` | Code review context — diff loading (`--numstat` for accurate counts), commit listing, SHA-based review (post-merge), expandable context diffs, single-commit inspection, branch merge/reject, GitHub PR creation |
| `EvoGit.Platform` | Cross-platform OS detection, config/data directory resolution |

### Key Overridable Callbacks (via `use EvoGit.Agent`)
| Callback | Default | Purpose |
|---|---|---|
| `system_prompt/0` | `""` | Agent behavior and rules (MUST NOT contain objective or context) |
| `available_tools/0` | All standard tools + subagent schemas + CompleteTask | LLM tool schemas for this agent |
| `subagent_modules/0` | `[]` | Agent modules spawnable as subagents |
| `subagent_tool_name/0` | `nil` | Tool name when this agent appears as a subagent |
| `subagent_tool_description/0` | `""` | Tool description when this agent appears as a subagent |
| `agent_type/0` | `:read_write` | `:read` or `:read_write` — controls spatial contract validation |
| `delegation_level/0` | `:high` | `:high` or `:low` — controls turn-budget warning frequency for delegation reminders |

## Known Issues

- **Stale `:finalizing` tasks stick forever after restart** (detailed in `./task_registry/CONTEXT.md` "Restart Recovery & Status Transitions"): `EvoGit.TaskRegistry.init/1` (`task_registry.ex:158-200`) performs NO task-status reconciliation — only `EvoGit.Store.integrity_check/1` (quarantine of corrupt rows, never touches valid statuses). All terminal-status writers key off the in-memory `task_refs` map — `{ref, result}` handler (`task_registry.ex:707-782`), `:DOWN` handler (`:785-843`) — which is EMPTY after restart, so pre-restart tasks can never be resolved by them. Post-restart: `:heartbeat` renews leases only for `:running`/`:pending` (`:858`); the one-shot `:lease_sweep` re-marks only `:running` tasks (`:881-886` — `:finalizing` excluded even in-process); `:periodic_cleanup` deletes only rows with `finished_at != nil` (`:finalizing` never has it); the `{:recheck_task, _}` handler (`:948-967`) WOULD resolve a `:finalizing` task but is never scheduled (dead code — the init comment at `:190-192` mentioning "via reconcile" is stale; no `handle_continue`/reconcile exists). The only exits from a stuck `:finalizing` task: explicit user action — `clear_finished_tasks/0` (`:372-380`, SQL `status NOT IN ('running','pending')` at `store.ex:521` matches `:finalizing`) or `delete_task/1` (`:441-444`). In-process resolution requires the wrapper process to finish (→ `:completed`/`:failed`) or crash (→ `:DOWN` → `:failed` only if no active sched_meta agents) — lease expiry plays NO role.

## Constraints
- All git operations must go through `EvoGit.Adapters.Git` — no direct `System.cmd("git", ...)` outside adapters.
- Agents are transient modules using `EvoGit.Agent` behaviour; persistent state lives in ETS.
- System prompts MUST NOT contain dynamic state, objectives, or context trees.
- Worktrees are persistent per-agent (created on dispatch, reused on retry, deleted on recycle).
- Agents commit before delegating subagents (auto-commit fallback enforced by scheduler).
- Tool outputs truncated at 128KB; agent loop has 30-min LLM budget with graduated warnings.
- Cross-repo subagents commit to their foreign repo's worktree — changes are NOT merged into the primary repo.
- 3-level configuration: `EvoGit.Config` merges defaults → user TOML → runtime overrides.

## First User Prompt Assembly
The `run/1` callback (injected by `use EvoGit.Agent`) assembles the agent's first user message as two distinct, XML-delimited blocks separated by a markdown horizontal rule, so the LLM can cleanly distinguish environment from objective:

```
<context>
{context_tree}

{foreign_repos_section}  ← omitted when blank
</context>

---

<objective>
{objective}  ← entire block omitted when there is no objective
</objective>
```

- **`build_dynamic_context/1`** and **`build_foreign_repos_section/1`** produce the section bodies (unchanged by framing); only how the sections are delimited relative to each other is structured.
- Blank sections (e.g. no foreign repos, or no objective) are dropped entirely — no dangling rules, empty headers, or empty XML blocks are ever emitted. The `---` delimiter appears only between two non-blank blocks.
