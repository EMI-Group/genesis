# EvoGit Core Library — `lib/evo_git/`

## Intent
Core source of the `:evo_git` OTP application: the Agent system (LLM-powered tool-calling loops), AgentScheduler (GenServer for worktree pools, ETS state, slot management), Core domain types (ContextNode, PhyloGraphNode, ForeignRepo), Git adapter, and Runtime phases (Genesis, Evolution). Supports multi-repo operation — foreign repos configured via `evogit.toml` or CLI flags enable cross-repo subagent spawning into isolated worktrees.

## Routing Table
- `./agent/` → Agent behaviour, tool library, context compression, subagent processing
- `./agents/` → Agent implementations (Generalist, Manager, Executor, TaskScheduler, Investigator, Architect, Extractor, Evaluator)
- `./agent_scheduler/` → AgentState, SchedMeta, Slots, Worktrees — ETS schemas and helpers
- `./core/` → ContextNode, PhyloGraphNode, ForeignRepo data structures
- `./adapters/` → Git CLI adapter — all git operations go through this module
- `./runtime/` → Genesis, Evolution, Prompts (LLM templates)

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
| `EvoGit.ProjectConfig` | Reads `evogit.toml` from repo root |
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

## Constraints
- All git operations must go through `EvoGit.Adapters.Git` — no direct `System.cmd("git", ...)` outside adapters.
- Agents are stateless modules using `EvoGit.Agent` behaviour; persistent state lives in ETS.
- System prompts MUST NOT contain dynamic state, objectives, or context trees.
- Worktrees are persistent per-agent (created on dispatch, reused on retry, deleted on recycle).
- Agents commit before delegating subagents (auto-commit fallback enforced by scheduler).
- Tool outputs truncated at 128KB; agent loop has 30-min LLM budget with graduated warnings.
- Cross-repo subagents commit to their foreign repo's worktree — changes are NOT merged into the primary repo.
- 3-level configuration: `EvoGit.Config` merges defaults → user TOML → runtime overrides.
