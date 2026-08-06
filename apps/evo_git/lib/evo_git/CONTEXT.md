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
| `EvoGit.RemoteBootstrap` | Pure platform/asset/download-resolution logic for the SSH remote bootstrap flow (`remote_bootstrap.ex`). `parse_uname/2` (uname output → CI platform `<os>_<arch>`), `parse_platform/1` (validates platform strings), `daemon_os/1` (platform → `"Linux"`/`"Darwin"`), `asset_name/1` + `asset_matches?/2` (release asset matching tolerating the embedded version), `download_url/1` (GitHub latest-release API via Req with direct-URL fallback), `cache_path/2` (local download cache under `EvoGit.Platform.data_dir()`). All command execution (ssh/scp/curl) lives in `EvoGit.RemoteConnection`, not here. |

### SSH Remote Bootstrap — Auto-Download Flow (as of 2b6333d3)
`EvoGit.RemoteConnection.bootstrap/1` no longer requires a local tarball. Sources in priority order: (1) `local_binary_path` set + exists → `scp` upload (unchanged); (2) set-but-missing → `Logger.warning` + fall back to auto-download (VS Code semantics); (3) absent → auto-download. Auto-download stages: `:probing_platform` (uses target's optional `platform` field, else one `uname -s && uname -m` SSH call) → `:downloading` (remote `curl -fL`) → `:downloading_locally` (fallback: local curl into `<data_dir>/remote_binaries/<platform>_<version>.tar.gz` cache + `scp`) → then the existing `:extracting` → `:setting_permissions` → `:copying_config` → `:generating_cookie` → `:starting_daemon`. The probed/overridden OS is threaded through so `:detecting_os` is skipped on the auto path (still broadcast on the local-tarball path). New stage atoms: `:probing_platform | :downloading | :downloading_locally` (evo_dash `settings_live.ex` needs UI labels for these three).
**Error tuples** (for tests): probe → `{:error, {:probe_failed, {:exit_status, n} | :timeout | {:unexpected_output, out}}}` or `{:error, :unsupported_platform}`; download → `{:error, {:download_failed, {:exit_status, n} | :timeout | {:local, detail} | {:local_scp, detail}}}`; platform override → `{:error, {:invalid_platform, p}}` / `{:error, :unsupported_platform}` (e.g. `windows_x64` — daemon launcher only supports Linux/macOS). `download_url/1` returns `{:ok, url, version}`; version (from `tag_name`, else `"latest"`) keys the local cache.
**Notes**: `remote_connection.ex` is ~1300 lines (over the ~1000 baseline) — all pure logic has been extracted to `remote_bootstrap.ex`; the remaining length is the ssh/scp/curl orchestration, stage broadcasting, and state transitions that the module-boundary design deliberately keeps in `RemoteConnection`. `@bootstrap_call_timeout_ms` is 900s (download can be slow); `@download_timeout_ms` is 300s. |

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

- **✅ FIXED — stale `:finalizing` tasks after restart** (detailed in `./task_registry/CONTEXT.md` "Restart Recovery & Status Transitions"): `EvoGit.TaskRegistry.init/1` (`task_registry.ex:159-220`) now performs **startup reconciliation** for orphaned `:finalizing` tasks — after `integrity_check`, it queries `EvoGit.Store.select_running_lease_info/1` (lightweight id+status+lease_expires_at for ALL rows), filters `status == :finalizing`, and synchronously marks each `:failed` via the shared `handle_update_status/6` (`:506`) with result `"Runtime restarted during task finalization"` and `caller_info = {:startup_reconcile, :finalizing}`. This covers the crash window where slow git calls in `merge_and_report/3` hang while the task sits at `:finalizing` and the app dies before the terminal write. `:running` tasks are deliberately untouched — the one-shot `:lease_sweep` (`:896-947`) still handles orphaned `:running` owners after the lease duration (it respects lease validity for the legitimate multi-VM case). Remaining caveats: `:heartbeat` renews leases only for `:running`/`:pending`; `:periodic_cleanup` deletes only rows with `finished_at != nil`; the `{:recheck_task, _}` handler (`:971-990`) is still unreachable dead code (nothing schedules the first recheck). In-process resolution still requires the wrapper process to finish (→ `:completed`/`:failed`) or crash (→ `:DOWN` → `:failed` only if no active sched_meta agents) — lease expiry plays NO role in resolving `:finalizing`.

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
