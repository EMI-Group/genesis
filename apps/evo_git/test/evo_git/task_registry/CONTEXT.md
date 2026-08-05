# Test Directory — task_registry

## Intent

ExUnit tests for `EvoGit.TaskRegistry` and `EvoGit.Store` persistence/lifecycle behavior: status transitions & guards, lease/heartbeat, cleanup, SQLite integrity/quarantine, archive metadata, restart durability.

## API Surface

| File | Covers |
|------|--------|
| `persistence_test.exs` (739 lines) | `set_review_metadata/3`, `TaskInfo` field backfill (`normalize_tasks` on restart), store CRUD, **registry restart round-trips** (`stop_supervised(EvoGit.TaskRegistry)` + `start_supervised({TaskRegistry, task_store: EvoGit.Store, data_dir: ..., name: EvoGit.TaskRegistry})` — store is KEPT running), recent-project persistence, corruption resilience, `archive_metadata`, and the `describe "status recovery from spurious :failed"` block (lines 618-737) |
| `lease_heartbeat_test.exs` (108 lines) | lease cleared on completion; heartbeat does NOT sweep expired-lease unowned tasks (renewal only); one-shot `:lease_sweep` message sweeps expired-lease `:running` tasks → `:failed` |
| `cleanup_test.exs` (232 lines) | `task_history_config/0` defaults; `cleanup_expired_tasks` age/count limits; never cleans `:running`/`:pending` |
| `store_integrity_test.exs` (165 lines) | `Store.integrity_check/1`: healthy store, hard-delete of undecodable TASKS rows, quarantine of undecodable PROJECTS rows (uses raw `Xqlite.open`/`XqliteNIF.execute` to inject garbage, then `GenServer.stop`/restart store) |

## Key Status-Guard Semantics (pinned by `persistence_test.exs:618-737`)

- **PubSub path** (`handle_info({:task_status, id, status})`, lib `task_registry.ex:658-704`): stale update rejected ONLY when current status is `[:completed, :cancelled]` (lib:662). `:failed` is deliberately NOT in the guard — a `:finalizing` broadcast after a spurious `:failed` is ACCEPTED (`persistence_test.exs:655-682`, "recovery before completion": task seeded `:failed`, `Phoenix.PubSub.broadcast(EvoGit.PubSub, "tasks", {:task_status, task_id, :finalizing})`, assert `status == :finalizing`).
- **Cast path** (`handle_update_status`, lib `task_registry.ex:492-495`): rejects only terminal→terminal transitions where `task.status != status` and `status != :completed` — i.e. `:failed` → `:completed` recovery is allowed (`persistence_test.exs:619-653`); `:completed`/`:cancelled` are never overwritten (`persistence_test.exs:684-709`, `:711-736`).
- **Terminal set is `[:completed, :failed, :cancelled]`** (cast path) but PubSub guard uses only `[:completed, :cancelled]` — `:failed` is recoverable in both paths.
- Runtime emits ONLY `:finalizing` on the `"tasks"` topic (`Helpers.notify_finalizing/1` → `Phoenix.PubSub.broadcast(EvoGit.PubSub, "tasks", {:task_status, task_id, :finalizing})`, lib `runtime/helpers.ex:104`); a `:failed` received on PubSub triggers `Diagnostics.log_failed_transition(..., :task_status_pubsub, ...)` (lib:672-676).

## Known Test Gaps (verified 2025 — no test exists for these)

1. **No restart-recovery test for a `:finalizing` or `:running` row**: no test anywhere in evo_git or evo_dash starts a fresh TaskRegistry/Store against a DB that already contains a task persisted with status `:finalizing` or `:running` and asserts the resulting status. The restart tests in `persistence_test.exs` (`:214-251`, `:255-280`) and the backfill tests (`:104-184`, `:540-581`) only use `:completed` tasks. Closest analogues:
   - `lease_heartbeat_test.exs:74-105` — seeds a `:running` row with an EXPIRED lease + no owner, then sends `:lease_sweep` DIRECTLY to the registry (does NOT restart the registry). This simulates the startup sweep (fires once at `@sweep_after = 150s` after init, lib:42,190-194 — never fires during a test run) and asserts `:failed`.
   - `store_test.exs:1051-1068` — Store put/get round-trip of `:finalizing` status (no registry involved).
   - evo_dash `tasks_live_test.exs:175-182` — LiveView crash-fix regression for the `:finalizing` broadcast; not registry restart recovery.
   - lib behavior with no test: a fresh registry against a `:finalizing` row would leave it untouched (guard only fires on incoming updates; no init-time reconciliation of `:finalizing`); a `:running` row with a valid lease is untouched; expired-lease unowned `:running` rows get swept to `:failed` only by the one-shot sweep 150s after init (or `{:recheck_task, id}` resolution).
2. **`:failed` → `:finalizing` via the CAST path** (`update_task_status/4`) is untested — only the PubSub path is covered (persistence_test.exs:655).

## Harness — `test/support/task_registry_case.ex` (82 lines)

- All 4 test modules `use EvoGit.TaskRegistryCase, async: false`.
- `setup`: `Supervisor.terminate_child(EvoGit.Supervisor, EvoGit.TaskRegistry)` + `(..., EvoGit.Store)` (kills production children so they don't auto-restart); creates a unique temp dir `System.tmp_dir!()/evogit_test_tasks_<unique>`; starts a FRESH `EvoGit.Store` (`start_supervised({EvoGit.Store, data_dir: sqlite_path})`) and FRESH `TaskRegistry` (`start_supervised({TaskRegistry, task_store: EvoGit.Store, data_dir: root, name: EvoGit.TaskRegistry})`) — **fresh empty SQLite DB per test**.
- `on_exit`: `File.rm_rf(root)` + `Supervisor.restart_child` of Store and TaskRegistry.
- Helpers: `trigger_cleanup!/0` (direct `Cleanup.cleanup_expired_tasks(EvoGit.Store)`), `cleanup_process/1`, `old_age_days/0` / `within_age_days/0` (read runtime config, fallback 14).
- NO `XDG_DATA_HOME` redirection here (unlike evo_dash's test_helper) — isolation comes entirely from the terminate-child + fresh-temp-DB pattern. (Note: root CONTEXT.md flags `config/test.exs` still sets `:evo_dash, :data_dir` while `EvoGit.Store` reads `:evo_git, :data_dir` — the app-level guard is broken; only the per-test isolation pattern protects the production DB.)

## Constraints

- `async: false` everywhere in this directory.
- No mocking — real SQLite via xqlite, real `EvoGit.Store`/`TaskRegistry` GenServers; corrupt rows injected via raw `XqliteNIF.execute`.
- Sync idiom: `update_task_status` is a cast → always `TaskRegistry.list_tasks()` (a call) afterwards to flush the mailbox before asserting.
- Restart pattern: `stop_supervised(EvoGit.TaskRegistry)` then `start_supervised({TaskRegistry, task_store: EvoGit.Store, data_dir: data_dir, name: EvoGit.TaskRegistry})` — keep the SAME Store running (it is durable on disk) so data survives the registry restart.
