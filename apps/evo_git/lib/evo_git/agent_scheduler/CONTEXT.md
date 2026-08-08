# Agent Scheduler Data Structures and Helper Modules

## Intent

Contains data structs and extracted helper modules used internally by `EvoGit.AgentScheduler` GenServer. The data structs back two ETS tables (`:evogit_agent_state` and `:evogit_sched_meta`) tracking agent execution state and scheduling metadata. Helper modules encapsulate slot management, worktree lifecycle, agent dispatching, subagent management, and agent lifecycle logic.

## Routing Table

None — leaf directory (modules: `state.ex`, `agent_state.ex`, `sched_meta.ex`, `slots.ex`, `store.ex`, `worktrees.ex`, `worktree_manager.ex`, `dispatch.ex`, `subagents.ex`, `lifecycle.ex`, `pubsub.ex`, `throttle.ex`, `remote_api.ex`).

## Throttled PubSub (PubSub module + throttle.ex)

`EvoGit.AgentScheduler.PubSub` provides the throttled `{:agents_updated}` bulk broadcast plus enriched delta broadcasts (`:agent_registered` / `:agent_updated` / `:agent_removed`). The throttle is **supervised**:

- `EvoGit.AgentScheduler.PubSub.Throttle` (throttle.ex — a small GenServer) is a **standard child of the application supervision tree**: declared in `EvoGit.Application`'s `children` (application.ex) immediately after `{Phoenix.PubSub, name: EvoGit.PubSub}`, it runs under `EvoGit.Supervisor` (one_for_one) with the default `:permanent` restart — a crash restarts it instead of silently degrading to unthrottled broadcasts forever. (Formerly wired as a self-contained named supervisor started from `EvoGit.Application.start/2`; now plain supervision.)
- `broadcast_agents_updated/0` casts `:schedule` to the Throttle (coalesces rapid calls into one flush `@throttle_ms` = 200ms after the last schedule). `Process.whereis(EvoGit.AgentScheduler.PubSub.Throttle)` → nil (tests, supervisor restart window, contexts where the app isn't started) keeps the **immediate-broadcast fallback** — the old bare-spawn loop is gone, so a crash no longer permanently degrades to unthrottled broadcasts.
- If the Throttle exhausts the supervisor's max_restarts, `EvoGit.Supervisor` dies and takes the app down — standard OTP; the 200ms timer loop is not a realistic crash source.

## Defensive ETS lookups in Subagents (since 8666258a)

`Store.get_sched_meta/1` / `Store.get_agent_state/1` return `{:ok, x} | :error`. Four sites in `subagents.ex` previously used **bare `{:ok, x} = Store.get_*(id)` matches** that crashed the scheduler GenServer with `MatchError` when a parent's ETS entries were reaped by `cancel_agent/2` while a subagent spawn/result was in flight. All four are now `case`-guarded with graceful fallbacks (log warning + safe return):

1. `spawn_validated_subagents/5` — missing parent agent_state → replies `[{:error, :parent_recycled}]` per spec to the blocked `from`, spawns nothing, returns `{:noreply, state}` (bails BEFORE the `:waiting` status mutation).
2. `store_sub_result/3` — missing parent sched_meta → `:ok` (result dropped; parent is gone).
3. `maybe_resume_parent/2` — missing parent sched_meta → state unchanged.
4. `dispatch_ready_parent/3` — missing agent_state (only needed for the resume log's commit SHA) → still replies/resets meta, logs `"unknown"` SHA.

Normal-path behavior is preserved exactly. ⚠️ No tests cover the `:error` paths yet — test additions were blocked by node scope (test dir is a sibling); a parent agent should route them to `./apps/evo_git/test/evo_git/agent_scheduler/` (subagents_test.exs error-path tests + a new pubsub_test.exs for the Throttle).

## CoW worktree batching — pending in sibling node (escalate to parent)

The actual CoW copy code is **NOT** in this node — it lives in `./apps/evo_git/lib/evo_git/adapters/cow_worktree.ex` (sibling node, read-only from here). Known issue: `copy_files_macos/3` (cow_worktree.ex:263-296) runs **one `System.cmd("cp", ["-c", file, dest])` per file** (O(n) process spawns) while `copy_files_linux/3` batches ~1000 files per `cp --reflink=auto --parents` invocation (`@batch_size` = 1000). Fix (grouped invocations): within each batch, `Enum.group_by(&Path.dirname/1)` and run one `cp -c <files...> <worktree>/<dir>/` per directory group (BSD cp allows multiple sources with an existing directory destination; `-c`/clonefile CoW semantics apply per file; `dir == "."` → dest `<worktree>/`). Dirs are already pre-created by `create_dirs/2`. Reduces spawns from N files to D distinct dirs. Flagged by code review but NOT fixed in this node — the parent agent must route it to the adapters node.

## API Surface

| Module | Description |
|---|---|
| `EvoGit.AgentScheduler.State` | GenServer state struct — configuration, agent lifecycle queues, slot holder sets |
| `EvoGit.AgentScheduler.AgentState` | Live agent state in `:evogit_agent_state` ETS — context_node, phylo_node, objective, repo_id |
| `EvoGit.AgentScheduler.SchedMeta` | Scheduler-private metadata in `:evogit_sched_meta` ETS — status, depth, worktree, subagent tracking |
| `EvoGit.AgentScheduler.Slots` | Pure-function LLM/tool slot management using holder MapSets with FIFO queuing and rate-limit backoff |
| `EvoGit.AgentScheduler.Worktrees` | Pure-function worktree lifecycle: init, assign, prepare, sync, delete, teardown. Delegates filesystem I/O to `WorktreeManager`. |
| `EvoGit.AgentScheduler.WorktreeManager` | GenServer for async worktree I/O — init, delete (cast), teardown |
| `EvoGit.AgentScheduler.Dispatch` | Agent registration, dispatching, agent-process git commit, repo root resolution, queue processing |
| `EvoGit.AgentScheduler.Subagents` | Subagent validation/spawning, spatial contract checks, result tracking, parent resumption |
| `EvoGit.AgentScheduler.Lifecycle` | Agent recycling (cleanup) and crash handling (retry logic, permanent failure) |
| `EvoGit.AgentScheduler.PubSub` | Centralized broadcast helpers — throttled `{:agents_updated}` (via `Throttle` GenServer supervised under `EvoGit.Supervisor`, see "Throttled PubSub" below) plus enriched delta broadcasts |
| `EvoGit.AgentScheduler.PubSub.Throttle` | GenServer (throttle.ex) — coalesces `:schedule` casts into one flush broadcast 200ms after the last schedule; supervised child of `EvoGit.Supervisor` (`:permanent` restart), declared in `EvoGit.Application`'s children after `Phoenix.PubSub` |

### Slot Management (Slots module)

Two independent slot pools tracked as `MapSet`s of agent IDs. Available capacity is derived: `capacity - map_size(holders)`. This makes slot leaks impossible by construction — when an agent dies, `release_agent_slots/2` removes it from both holder sets, restoring the slot automatically.

| Pool | State Keys | Capacity | Backoff |
|------|-----------|----------|---------|
| LLM slots | `llm_holders`, `llm_waiting`, `llm_backoff_until` | `max_concurrency` (3) | 60s global cooldown on `:rate_limit` errors |
| Tool slots | `tool_holders`, `tool_waiting` | `max_tool_concurrency` (2) | None |

Key functions:
- `handle_request_llm_slot/3`, `handle_request_tool_slot/3` — Grant if capacity available, else enqueue
- `handle_release_llm_slot/2`, `handle_release_tool_slot/2` — Remove from holder set, grant pending. Called via `handle_cast` (fire-and-forget); return `{state, status_updates}`.
- `release_agent_slots/2` — Called on agent death (`:DOWN` handler): removes from both holder sets, purges from queues, grants pending slots
- `purge_agents_from_queues/2` — Removes agents from waiting queues, replies `{:error, :cancelled}` to each
- `grant_pending_on_resume/1` — Grants all available slots when resuming from pause

Slot functions return `{:reply, :ok, state, status_updates}` or `{:noreply, state, status_updates}` for synchronous operations, and `{state, status_updates}` for asynchronous release operations (`handle_cast`). The `status_updates` list contains `{agent_id, :blocked | :running}` tuples applied to ETS SchedMeta for dashboard visibility.

### Running Count

There is no `running_count` field. The running count is always derived as `map_size(state.ref_to_agent)`. Every agent lifecycle transition (dispatch, completion, crash) pops or puts from `ref_to_agent`, keeping the count authoritative at all times.

### Multi-Task Repo Root Resolution

The scheduler supports multiple concurrent tasks targeting different repos. Repo root resolution follows this priority:

1. **Per-agent ETS** (`AgentState.repo_root`) — set at registration via `Dispatch.resolve_agent_repo_root/2`, derived from spec data. Used by `Lifecycle` for worktree cleanup.
2. **Process dictionary** (`Process.get(:genesis_repo_root)`) — set at dispatch time in `try_dispatch/2`. Preferred by `current_repo_root/0` for runtime lookups.

There is no global `state.repo_root` fallback — repo root resolution is always per-agent. The scheduler tracks which repos have been initialized via the `initialized_repos` map (`%{String.t() => true}`).

`resolve_agent_repo_root/2` in Dispatch is self-contained for primary repos (strips worktree suffix from `spec.phylo_node.repo`). For foreign repos, it looks up the repo root from the agent's own `spec.foreign_repos` list by `spec.repo_id` — foreign repos are carried per-agent, not stored in global scheduler state.

### Worktree Lifecycle (Worktrees module)

Worktrees are **persistent per-agent** (created on dispatch, reused on retry, deleted on recycle):

1. `ensure_initialized/2` — Creates `.genesis/workers/`, prunes stale worktrees and orphaned branches. Tracks initialized repos in `state.initialized_repos` (`%{String.t() => true}`) to support multiple concurrent tasks targeting different repos. When agents are already running and a new repo comes in, registers it additively in `initialized_repos` without tearing down existing worktrees.
2. `assign_and_prepare_worktree/2` — Cleans worktree, checks out agent branch, binds repo path
3. `run_init_script/3` — Runs optional init script from `genesis.toml` (primary repo only). Accepts `opts` keyword list with `:source_worktree_path` (parent agent's worktree or repo root for top-level). Sets env vars: `SOURCE_REPO_PATH`, `TARGET_WORKTREE_PATH`, `SOURCE_WORKTREE_PATH`.
4. `sync_current_commit/2` — Reads HEAD SHA and updates both ETS tables if changed
5. `delete/2` — Removes worktree directory, prunes, deletes branch (delegates to `WorktreeManager.delete_worktree/2` via `cast` — fire and forget)
6. `teardown_worktrees/2` — Removes entire worker base directory for a given repo root (delegates to `WorktreeManager.teardown_worktrees/1` via `call` — synchronous)
7. `teardown_worktrees/1` — Resets the `initialized` flag without filesystem cleanup (for when repo root is unknown)

All filesystem operations (rm_rf, prune_worktrees, delete_branch, mkdir_p) are handled by the dedicated `WorktreeManager` GenServer process, called synchronously for init/teardown (`call`) and asynchronously for deletion (`cast`).

### Agent Dispatching (Dispatch module)

Handles the mechanics of registering and dispatching agents:

1. `register_agent/6` — Assigns agent IDs, computes task-local IDs, resolves event sink inheritance, writes both ETS tables
2. `try_dispatch/2` — **Two-phase dispatch** for parallel subagent startup. Uses `with` guard to bail cleanly if ETS entries are missing (genuine race).
   - **Phase 1 (GenServer, fast):** Computes worktree path, stores it in sched_meta **before** spawning the task (so `cancel_agent` can find the worktree), spawns the task immediately via the 4-arity `Task.Supervisor.async_nolink/4` **named-function** form (`spec.agent_module, :run, [spec.objective, dispatch_ctx]`), updates `ref_to_agent`. **NO git commands or init scripts run here** — the GenServer never does blocking I/O. The named-function form (instead of an anonymous fn) means the spawned process shows up as a meaningful `module.run/2` in process inspection (observer/Process.info).
   - **Phase 2 (Task process, slow/concurrent):** `setup_worktree/5` runs inside the agent's `run/2` (the single true entry point for an agent), before the agent loop: creates the worktree (tries CoW-optimized creation via `EvoGit.Adapters.CowWorktree` first, falls back to `Git.add_worktree`), prepares it (`assign_and_prepare_worktree`), and runs the init script on first creation (primary repo only). The CoW optimization copies unchanged files from a source working tree (parent's worktree for subagents, repo root for top-level) using `cp --reflink=auto` (Linux) or `cp -c` (macOS), avoiding full git object extraction. Controlled by `[:git, :cow_worktree_creation]` config (`:auto` default). All of this runs concurrently across subagents, so `spawn_validated_subagents`' `Enum.reduce` over `try_dispatch` spawns all tasks immediately.
3. `commit_pending_in_worktree/0` — Best-effort git commit of pending changes, designed to run in the **agent process** (not the scheduler). Uses `Process.get(:repo_path)` for the worktree path. Handles all git adapter error tuples (`{:ok, _}`, `{:error, _}`, `{:conflict, _}`) explicitly via a `with` block rather than a broad `try/rescue`, so failures are logged but never crash. Called via `try/after` in the agent's `run/2` (the dispatch entry point) after the agent loop. **The scheduler process NEVER calls git directly.**
4. `resolve_agent_repo_root/2` — Resolves repo root from spec (primary vs foreign repo)
5. `dispatch_queued_agents/1` — Drains queue dispatching agents (used after resume)
6. `process_queue/1` — Processes queue with ready-parent detection (delegates to Subagents)

### Subagent Management (Subagents module)

Handles subagent validation, spawning, and result collection:

1. `spawn_validated_subagents/5` — Validates all specs, registers valid ones, replies immediately if all invalid. The parent agent commits its pending changes BEFORE calling `spawn_sub_agents` (done in the agent process via `Dispatch.commit_pending_in_worktree/0`), so the scheduler does not perform git operations.
2. `validate_single_subagent/5` — Per-spec validation chain (depth, ignored, spatial)
3. `validate_subagent_depth/3`, `validate_subagent_not_ignored/1` — Individual validation checks
4. `validate_spatial_contract_for_spec/3`, `validate_spawn_spatiality/4` — Spatial contract enforcement
5. `store_sub_result/3` — Stores subagent result at correct index in parent's results map. Also tracks foreign repo commit SHAs in `SchedMeta.foreign_repo_commits` — when a foreign-repo subagent completes successfully, its `commit_sha` is recorded under the `repo_id` key so subsequent subagents targeting the same foreign repo start from that commit instead of HEAD.
6. `maybe_resume_parent/2` — Checks if all subagents done, resumes parent if so
7. `dispatch_ready_parent/3` — Replies to parent's GenServer.call with ordered results
8. `build_ordered_results/2` — Builds final results list in original spec order

### Agent Lifecycle (Lifecycle module)

Handles agent completion and crash recovery:

1. `recycle_agent/2` — Deletes worktree and both ETS entries on normal completion. Uses `with` guard to return state unchanged if ETS entry is already gone (genuine race between `:DOWN` completion and another cleanup path). Resolves `repo_root` from the agent's own `AgentState` ETS entry (not global state).
2. `cancel_agent/2` — Kills the agent's Task process via `Task.shutdown(meta.task_ref, :brutal_kill)`. The `task_ref` field stores a full `%Task{}` struct (not a bare reference), enabling proper shutdown. Replies to blocked callers, deletes worktree and ETS entries. Uses `case` to skip worktree deletion if agent_state is missing.
3. `handle_agent_crash/3` — Retry logic (keep worktree, re-dispatch) or permanent failure (cleanup, notify parent/reply error). Both paths resolve `repo_root` from per-agent ETS state.

## Constraints

- Data structs are plain data with no behaviour or callbacks.
- `Slots`, `Worktrees`, `Dispatch`, `Subagents`, and `Lifecycle` are pure-function modules operating on `State.t()`; they don't maintain their own state.
- `AgentState` is shared (scheduler + agent processes); `SchedMeta` is scheduler-exclusive.
- Both ETS tables are created by **`EvoGit.Application`** (the application process), NOT by the `AgentScheduler` GenServer (see `application.ex:13-15`). This is deliberate: the tables have **no heir**, so ownership must outlive a scheduler crash. Because they are owned by the long-lived application process, the tables **SURVIVE an `AgentScheduler` restart** — stale `SchedMeta` entries from the crashed instance remain. (Restart semantics: `AgentGroupSupervisor` is `strategy: :one_for_all`, so a scheduler crash also kills `EvoGit.TaskSupervisor` and all running agent Tasks. The GenServer `%State{}` is reset fresh on restart, but the ETS tables persist.)
- GenServer state must always be `%State{}`; use struct update syntax, not `Map.put/3`.
- The scheduler process NEVER calls git or does blocking filesystem I/O directly — all git operations (auto-commit, sync) happen in the agent (Task) process, and all worktree filesystem operations (rm_rf, mkdir_p, prune_worktrees, delete_branch) are offloaded to the dedicated `WorktreeManager` GenServer (synchronous `call` for init/teardown, asynchronous `cast` for deletion).
- Slot availability is derived from holder MapSets, never stored as a counter — this eliminates leak/deadlock bugs by construction.
- `SchedMeta.task_ref` stores a `%Task{}` struct (for `Task.shutdown/2`), NOT a bare reference. The `ref_to_agent` map still keys on `task.ref` (the monitor reference).
- `case`/`with` guards on ETS lookups are used ONLY where a genuine race can cause the entry to be absent (recycle_agent, try_dispatch, cancel_agent). Not used defensively everywhere.
- Cross-module calls: `Dispatch.process_queue/1` calls `Subagents.dispatch_ready_parent/3` for ready parents. `Lifecycle.handle_agent_crash/3` calls `Dispatch.try_dispatch/2`, `Dispatch.process_queue/1`, `Subagents.store_sub_result/3`, and `Subagents.maybe_resume_parent/2`.
- **Task archive table**: `:evogit_archive_records` is a **`:set` keyed by `{task_id, agent_id}`** (at most one record per agent per task — idempotent writes via `EvoGit.AgentScheduler.Store.put_archive_record/3` fix the crash-retry double-write race). Records are written at agent exit, consumed (collected into `Result.archive_records`) **AND** cleared at successful root completion in `Lifecycle.handle_task_result/3`, and reset defensively at task start in the `run_agent` call. The old "clear between Mode B phases" mechanism (`genesis.ex`) is gone — the architect root's records are already consumed+cleared at its own completion.

### Per-message timestamp metadata convention
Every message in an agent's session memory (the `%ReqLLM.Message{}` list inside `%ReqLLM.Context{}.messages`, held in `AgentState.context` / `:evogit_agent_state` ETS) carries `metadata[:timestamp]` — **Unix seconds** (`System.system_time(:second)`), an atom-keyed integer consistent with the existing `:turn` metadata convention. Timestamps are stamped **at message-CREATION time in the agent code** — never in the Store.

**Single choke point — `ContextBuilder.tag_message_turn/2` (agent/context_builder.ex)**: every message produced by the agent loop passes through it, and it sets BOTH `metadata[:turn]` AND `metadata[:timestamp]` in one place. Idempotent via `Map.put_new` — an already-stamped message keeps its original `:turn` and `:timestamp`. `ContextBuilder.tag_message_timestamp/1` stamps just the timestamp (used at the nudge and compression-summary append sites). The agent subtree owns all stamping; see `apps/evo_git/lib/evo_git/agent/CONTEXT.md` for the full inventory of creation sites.

**`Store` is a dumb pass-through.** `batch_update_agent/2` (store.ex) writes the fields verbatim into ETS and broadcasts; `update_agent_context/2` delegates to it. Both return `:ok`. **No read-back exists anywhere** — data flows one way: agent → ETS/pubsub → frontend. The dashboard reads `msg.metadata[:timestamp]` (Unix seconds) directly from `RemoteAPI.get_agent_history/1` (raw structs, unchanged).

`DateTime` was deliberately avoided (struct — heavier, and Jason-encodes to ISO-8601 strings elsewhere in the codebase); an integer is timezone-agnostic and trivial for the dashboard to convert to local display time. **The dashboard interprets integer timestamps as Unix SECONDS** (`EvoDashWeb.Helpers.format_history_timestamp/1`) — do NOT switch granularity without updating evo_dash. Second-granularity means messages produced within the same second share a stamp — acceptable by design. Compression (`context_compression.ex:85-86`) rebuilds context as `[system, initial_user, summary]` — the fresh summary is stamped via `tag_message_timestamp/1` at creation (history collapse is by design, not a bug).

### ⚠️ REVERTED — store-side timestamp stamping (commits 942bbb72 / 4e91a68e / 1c7ef9c8 / 1310b9bb / c2d2f6d5)
An earlier design stamped timestamps in the Store on every ETS write: `batch_update_agent/2` ran a private context-stamping helper (since deleted) before the insert, and `update_agent_context/2` returned the stamped `%ReqLLM.Context{}` so the loop could adopt it in-memory (keeping the idempotence guard engaged across turns). That design was **REVERTED** in favor of creation-time stamping in the agent code — restoring one-way data flow (agent → ETS/pubsub → frontend) with NO reading back. The revert restored `batch_update_agent/2` and `update_agent_context/2` to plain `:: :ok` writes. The dashboard contract is unchanged: read `msg.metadata[:timestamp]` as Unix seconds.

### ⚠️ Sending a user message to a running agent — no existing mechanism
There is **NO existing mechanism to send/queue a user message to a running agent**. The RPC surface (`EvoGit.AgentScheduler.RemoteAPI` + `EvoGit.RemoteNode`) is strictly **read-only**. Agents run as plain synchronous `Task` processes (`Task.Supervisor.async_nolink/5` in `Dispatch.try_dispatch/2`, dispatch.ex:201-207) — they are **NOT GenServers**, have **no `receive`/`handle_info`**, and never check a mailbox. The agent loop (`EvoGit.Agent.Runner.loop/1` → `ToolDispatch.do_turn/5`) is a tight tail-recursive function that does not poll for messages.

**Agent PID is available but not published:** `SchedMeta.task_ref` holds the full `%Task{}` struct, whose `.pid` is the live agent process PID. However, no function in `RemoteAPI`, `RemoteNode`, or `AgentScheduler` exposes `task_ref` or the PID to callers — `list_agents/0` omits it (the summary map has no `pid`/`task_ref` field), and `get_agent_state/1` reads the `:evogit_agent_state` table (which has no PID field). So there is no agent_id → pid lookup in the public RPC API. An internal caller could read `task_ref.pid` via `Store.get_sched_meta/1`, but this is not accessible over RPC.

**To add "send a message to a running agent" capability, new infrastructure is required:**
1. **Natural injection point — ETS message queue:** Because the agent loop reads `:evogit_agent_state` ETS at the start of every turn (`ToolDispatch.do_turn/5`, tool_dispatch.ex:101 — `AgentScheduler.get_agent_state(state.agent_id)`), a per-agent message could be stored in a new ETS field (e.g. `AgentState.pending_user_message`) or a new ETS table, and drained/merged into the conversation `context` at the top of `loop/1` or `do_turn/5`. This is the lowest-friction approach and works naturally over the existing `:erpc` + ETS architecture (dashboard writes the ETS field via a new `RemoteAPI` write function; agent picks it up on its next turn). Delay: up to one turn (the agent is mid-LLM-call until the current turn completes).
2. **PID-based messaging (harder, not recommended):** Add `task_ref`/`pid` to the `list_agents` summary map and `RemoteAPI`, then `send(pid, {:user_message, text})`. But the agent loop has no `receive` block, so this message would sit in the mailbox until the process exits — **useless** unless the loop is modified to flush the mailbox (`receive do ... after 0 -> ... end`) at a turn boundary.
3. **Turn-boundary mailbox flush:** Modify `loop/1` (runner.ex:218) or `do_turn/5` to `receive` any `{:user_message, text}` tuples with an `after 0` guard, then append them as user messages to `state.context`. This enables true async messaging but requires the loop change in addition to PID exposure.

The **ETS-queue approach (#1)** is recommended: it requires no PID exposure, works over the existing read-only ETS + `:erpc` pattern, and the dashboard can write messages via a new `RemoteAPI.send_agent_message/2` (a write function, breaking the current read-only invariant) or via direct `:erpc`-routed `AgentScheduler` cast.