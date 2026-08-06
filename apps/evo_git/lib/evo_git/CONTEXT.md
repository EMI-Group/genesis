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
**Notes**: `remote_connection.ex` is ~1300 lines (over the ~1000 baseline) — all pure logic has been extracted to `remote_bootstrap.ex`; the remaining length is the ssh/scp/curl orchestration, stage broadcasting, and state transitions that the module-boundary design deliberately keeps in `RemoteConnection`. `@bootstrap_call_timeout_ms` is 900s (download can be slow); `@download_timeout_ms` is 300s.

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

### SQLite Store — SQL-Lowering Refactor

- **DETS-era row-recovery machinery removed**: the old recovery tables, the per-start repair routine, and the manual `mix` recovery task are REMOVED — they were DETS-era legacy, and SQLite WAL mode doesn't corrupt rows the way the old DETS store did. `safe_select_all_tasks/1`, `safe_select_all_projects/1`, `safe_select_paginated_tasks/2` now SKIP undecodable rows with a `Logger.warning` ("Store: skipping undecodable row in ...") instead of moving them to a recovery table.
- **NO auto-migration at startup**: `Store.init/1` runs ONLY `Schema.create_tables/1` (fresh DBs get the full schema). `Schema.migrate_schema/1` + `Schema.normalize_timestamps/1` are NOT called at init — existing DBs are upgraded by the manual **`mix migrate.store`** task (`apps/evo_git/lib/mix/tasks/migrate.store.ex`): it applies schema migrations (adds the `updated_at` column to `tasks`, etc.) and normalizes legacy timestamp formats. The `Schema` functions remain available for the mix task and tests.
- **`updated_at` write semantics**: `tasks.updated_at` is store-internal bookkeeping — NOT in `Codec.@task_columns`/`%TaskInfo{}`. `put_task` writes it via the 19-column INSERT (`Codec.encode_datetime(DateTime.utc_now())`); `update_task_columns` automatically appends `{:updated_at, DateTime.utc_now()}` (encoded via `Queries.encode_column_value/2`). `update_lease_expires_at` does NOT bump `updated_at` — the 60s heartbeat must not mark tasks dirty. Rows with NULL `updated_at` (legacy DBs before `mix migrate.store`) never match changed-since queries.
- **Extended summary API**: `EvoGit.Store.select_tasks_summary(store \\ __MODULE__, statuses \\ [], since \\ nil)` and `select_tasks_summary_by_path(store \\ __MODULE__, project_path, statuses \\ [], since \\ nil)` — `statuses` is a list of status atoms, `[]` = all statuses; `since` is an optional fixed-precision ISO-8601 string that pushes `AND updated_at > ?N` into SQL (nil = no filter). The SELECT projection includes scalar columns `branch_name, model_id, agent_count, base_sha, commit_sha, lease_expires_at` plus `updated_at` (raw fixed-precision ISO string, NOT decoded — heavy columns logs/usage/archive_metadata stay out). **Summary map keys (16)**: id, status, review_status, result, started_at, finished_at, type, project_path, opts, branch_name, model_id, agent_count, base_sha, commit_sha, lease_expires_at, updated_at. Pass-throughs: `TaskRegistry.list_tasks_summary(statuses \\ [], since \\ nil)` + `list_tasks_summary_by_path(path, statuses \\ [], since \\ nil)`, `AgentScheduler.RemoteAPI.list_tasks_summary/1` + `list_tasks_summary_by_path/2` (no-arg forms kept for old RPC callers), `EvoGit.RemoteNode.list_tasks_summary/2` + `list_tasks_summary_by_path/3` over `:erpc`. **⚠️ `since` is NOT exposed through RemoteAPI/RemoteNode** — the RPC layers only accept `statuses`; remote callers needing a time filter must use `list_tasks_changed_since` (which accepts no statuses). Only the local `TaskRegistry`/`Store` calls can combine statuses + since.
- **Changed-since API (polling)**: `Store.select_tasks_changed_since(store \\ __MODULE__, since_iso)` returns summary-shaped maps (same 16-key projection incl. `updated_at`) for rows with `updated_at > since_iso` (fixed-precision string comparison — no heavy columns). Chain: `TaskRegistry.list_tasks_changed_since/1` → `AgentScheduler.RemoteAPI.list_tasks_changed_since/1` → `EvoGit.RemoteNode.list_tasks_changed_since/2` (over `:erpc`; `[]` on RPC failure).
- **Narrow-read Store functions**: `select_task_logs(store \\ __MODULE__, task_id)` (SELECT logs, decoded list or nil) and `select_task_update_info(store \\ __MODULE__, task_id)` (SELECT status, opts, finished_at, lease_expires_at → map or nil). TaskRegistry hot paths (`append_log`, `set_review_status`, `set_review_metadata`, `handle_update_status`/`update_task_status_with_caller`, `cancel_task`, `resolve_recheck_task`) now use these narrow reads + `update_task_columns` instead of full `task_get` decodes.
- **Cleanup pushdown**: `Store.select_cleanup_info(store \\ __MODULE__, cutoff_iso, max_tasks)` returns the ids to delete with BOTH filters in SQL: age cutoff (`finished_at IS NOT NULL AND finished_at < ?cutoff` — ALL age-expired rows, no count trim) and count trim (`finished_at >= ?cutoff ORDER BY finished_at DESC LIMIT -1 OFFSET ?max_tasks` — keeps the NEWEST `max_tasks` among non-age-expired finished rows). String comparison is safe on the fixed-precision 24-char ISO format. `TaskRegistry.Cleanup.cleanup_expired_tasks/1` consumes it (reads only ids; semantics unchanged — verified by `cleanup_test.exs`/`persistence_test.exs`). The old `select_cleanup_info/0,1` (`%{id, finished_at}` maps) is KEPT for backward compat (tests pin it).
- **Dead code removed**: `TaskRegistry.Cleanup.cleanup_expired_tasks/2` (pre-loaded variant) and `Lease.set_crash_details/1` are GONE (grep-verified zero callers in lib + test). `Lease.lookup_sched_meta_result/1` REMAINS (used by `resolve_recheck_task/3`). `resolve_recheck_task/3` now persists `branch_name` (extracted from `{:ok, %{branch_name: _}}` results, mirroring `handle_update_status/6`; only written when non-nil so it never clobbers). `trim_recent_projects` was already nil-safe (`sort_projects_by_recency/1` sorts nil `last_opened_at` LAST).
- **Lease/cleanup queries**: `select_running_lease_info` queries `status IN ('running','finalizing')`.
- **Batched delete**: `delete_tasks` uses chunked `DELETE ... WHERE id IN (...)` (~500 ids/chunk) — all-or-nothing per chunk.

## Known Issues

- **✅ FIXED — stale `:finalizing` tasks after restart** (detailed in `./task_registry/CONTEXT.md` "Restart Recovery & Status Transitions"): `EvoGit.TaskRegistry.init/1` (`task_registry.ex:159-220`) now performs **startup reconciliation** for orphaned `:finalizing` tasks — after Store startup (timestamp normalization no longer runs at init — it happens via the manual `mix migrate.store` task), it queries `EvoGit.Store.select_running_lease_info/1` (lightweight id+status+lease_expires_at, SQL-filtered to `status IN ('running','finalizing')`), filters `status == :finalizing`, and synchronously marks each `:failed` via the shared `handle_update_status/6` (`:506`) with result `"Runtime restarted during task finalization"` and `caller_info = {:startup_reconcile, :finalizing}`. This covers the crash window where slow git calls in `merge_and_report/3` hang while the task sits at `:finalizing` and the app dies before the terminal write. `:running` tasks are deliberately untouched — the one-shot `:lease_sweep` (`:896-947`) still handles orphaned `:running` owners after the lease duration (it respects lease validity for the legitimate multi-VM case). Remaining caveats: `:heartbeat` renews leases only for `:running`/`:pending`; `:periodic_cleanup` deletes only rows with `finished_at != nil`; the `{:recheck_task, _}` handler (`:971-990`) is still unreachable dead code (nothing schedules the first recheck). In-process resolution still requires the wrapper process to finish (→ `:completed`/`:failed`) or crash (→ `:DOWN` → `:failed` only if no active sched_meta agents) — lease expiry plays NO role in resolving `:finalizing`.

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
