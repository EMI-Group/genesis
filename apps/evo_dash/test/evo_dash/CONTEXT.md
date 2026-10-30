# EvoDash Domain-Layer Tests

## Intent

Suites for the `:evo_dash` domain modules in `./apps/evo_dash/lib/evo_dash/`: ActiveTasks, ChatHistory, AttachedFile, NodeContext, DirectoryPicker, SafeCall, DesktopLifetime, UpdateStatus, SettingsUtils, MarkdownRender, ConnectionDiagnostics.
Store/TaskRegistry domain tests live in `:evo_git`; this directory only exercises the dashboard's thin wrappers.
Counts below are statically declared `test` blocks.

## Routing Table

| File | Module | Tests | async |
|------|--------|-------|-------|
| `active_tasks_test.exs` | `EvoDash.ActiveTasksTest` | 9 | false |
| `attached_file_test.exs` | `EvoDash.AttachedFileTest` | 19 | true |
| `chat_history_test.exs` | `EvoDash.ChatHistoryTest` | 13 | true |
| `connection_diagnostics_test.exs` | `EvoDash.ConnectionDiagnosticsTest` | 1 | true |
| `desktop_lifetime_test.exs` | `EvoDash.DesktopLifetimeTest` | 11 | true |
| `directory_picker_test.exs` | `EvoDash.DirectoryPickerTest` | 12 | true |
| `isolated_task_store_test.exs` | `EvoDash.Test.IsolatedTaskStoreTest` | 3 | false |
| `markdown_render_test.exs` | `EvoDash.MarkdownRenderTest` | 3 | true |
| `node_context_test.exs` | `EvoDash.NodeContextTest` (27) + `EvoDash.NodeContextConfigTest` (11) | 38 | both (`ConnCase`): true + false |
| `safe_call_test.exs` | `EvoDash.SafeCallTest` | 25 | true |
| `settings_utils_test.exs` | `EvoDash.SettingsUtilsTest` | 8 | true |
| `update_status_test.exs` | `EvoDash.UpdateStatusTest` | 19 | true |

## API Surface

`active_tasks_test.exs` — the ETS-backed `EvoDash.ActiveTasks` pure-module API (named public table `:evo_dash_active_tasks`, created idempotently in `EvoDash.Application.start/2` and owned by the long-lived application process, so there is NO process to start): `get/2`+`put/4` round-trip and same-context overwrite, per-context isolation (`{nil, node()}` vs `{node_id, remote_node}`), `{[], []}` snapshot semantics (`{:ok, {[], []}}` ≠ `:empty`), `invalidate/2` per-context delete, `reset/0` (idempotent, clears every context).
`attached_file_test.exs` — `EvoDash.AttachedFile`: `read/1` for plain text, `.docx` and `.pdf` (password-protected → `{:invalid, …}`, image-only/scanned → `{:empty, …}`), `read_kind/2` (image/audio extension allowlist → media type, rejections, the 15 MiB per-file cap), `media_type_for/1`, and `describe_error/2`.
`chat_history_test.exs` — the `EvoDash.ChatHistory` GenServer plus its named ETS table `:evo_dash_chat_history`: supervision presence, `new_chat/0` (positive unique integer id, becomes current), `current_chat_id/0`/`set_current_chat/1` (no id validation), `list_chats/0` newest-first by an internal `:monotonic` seq (NOT by id), `put_state/2`/`get_state/1` (opaque state; unknown id upserts as newest), `delete_chat/1` (clears the pointer when it was current), `prune/1` (keeps newest N; `0` clears; non-integer/negative ignored), `reset/0`.
Assertions read the WHOLE global table (e.g. `list_chats() == [id]`), which is valid only because no async peer creates chats.
`connection_diagnostics_test.exs` — the idempotent `[:thousand_island, :connection, :start]` telemetry handler and `handle_connection_start/4` copying `remote_ip`/`remote_port` onto the emitting connection process's Logger metadata.
`desktop_lifetime_test.exs` — the TCP lifetime watcher: gating (missing/empty/invalid `EVOGIT_LIFETIME_PORT` → disabled no-op), connect-budget exhaustion → stop, real-TCP peer close → stop, pure `classify_recv_result/1` branches, and ambiguous-recv retry semantics.
The watcher is driven through the module's `:recv_fun`/`:parent_stop_fun` seams with a BLOCKING handshake (the seam sends `:recv_called` and waits for `:respond_ambiguous`/`:respond_closed`), so it is parked inside `recv_fun` between assertions; real-socket cases OBSERVE via `await_recv_blocked/1` (`Process.info/2` until parked in `:gen_tcp.recv/3`, bounded 1 ms poll), fenced by `assert_disabled/1` and `assert_no_further_stop/1` (`:sys.get_state/1`).
`directory_picker_test.exs` — the pick protocol through `EvoDash.DirectoryPicker.Wx.Fake` injected via `:directory_picker_wx` (with a per-test `enabled: true` override): first/subsequent picks, wx-server-killed-between-picks recovery, mid-pick server death → `:unavailable` + busy cleared, `init_fails` → async `:unavailable` + recovery, busy serialization via `set_gate/1` (second pick → synchronous `{:error, :unavailable}`), disabled-config rejection, plus the `pick/3 :file` mirror (file dialog result, `pick/2` ≡ `pick/3 :directory`, kind-agnostic busy).
Sync fences: `await_pick_idle/1` polls the picker's own `:sys.get_state/1` (a FIFO fence — `run_pick/4` delivers the caller's result BEFORE `{:pick_done, …}`), and every negative `refute_receive {:directory_picker_result, …}` is a zero window backed by that fence or by the synchronous error reply.
No test covers the `:cancelled` result kind, and no path validation/normalization is asserted (the picker only relays the path).
`isolated_task_store_test.exs` — the observable invariants of `EvoDash.Test.IsolatedTaskStore`: every `isolate!/1` gets its own fully migrated private sqlite inside its own `<tmp>/evogit_test_<prefix>_<int>` dir (a module-wide `:persistent_term` witness refutes two isolates sharing a path), a write through the isolated pair lands in that database while the shared template stays byte-identical (main file AND `-wal`/`-shm`/`-journal`), and the isolated pair is NOT linked to the test process (`refute self() in Process.info(sup, :links)` — the structural pin for the ordered teardown).
Its module `setup` registers the post-teardown `on_exit` (reverse-order run) that asserts `assert_production!/0` holds and the isolated dir is gone.
`markdown_render_test.exs` — `EvoDash.MarkdownRender` edges: nil, empty, headings, code blocks, tables, bold.
`node_context_test.exs` — `EvoDash.NodeContext` delegates are thin node-first passthroughs to `EvoGit.RemoteNode.*`; the LOCAL path (`node()`) is exercised throughout, plus one remote transport-failure case.
The file holds TWO modules so most of the suite runs in the async phase: `EvoDash.NodeContextTest` (`async: true`) writes into the RUN-WIDE per-run store under per-test unique ids/`project_path`s, and `EvoDash.NodeContextConfigTest` (`async: false`) owns only the two describes that set `XDG_CONFIG_HOME` (custom agents, `custom_tools_status/1`).
No describe uses `IsolatedTaskStore`; `insert_fixture!/1` registers an `on_exit` that deletes exactly its own id through the direct store (`EvoGit.Store.delete_task/2`, which also drops that task's `task_agent_archives` rows).
Covered: cancel/force-kill (`:not_found`, `:pending` → `:cancelled` store-verified via `insert_fixture!/1`), lightweight reads (`get_task_lite`, nil for a missing task), paged archive reads (`list_task_archives/2,3` + `get_agent_archive/3` arities, `normalize_archive_page/1` totality on atom- and string-keyed pages, `%{entries: [], total: 0}` for a missing id, and `refute function_exported?(NodeContext, :get_task_archive, 2)` — the single-blob read has no deprecation shim), review RPC casts, GitHub delegates (verbatim `{:error, {:enoent, path}}`), `get_resolved_config/1`, `get_recent_system_samples/1`, custom-agents RPC (list/save/duplicate_id/missing_name/delete/script round-trip + reload, under an isolated `XDG_CONFIG_HOME`), `custom_tools_status/1` (hermetic `%{ok: [], errors: []}`, verbatim identity vs `EvoGit.RemoteNode`, a populated status from the `custom_tool_fixture!/1` temp `<config_dir>/tools` file, and the unreachable-remote `{:error, _}` that must NOT degrade to the empty map), and `approval_response/3` (total `{:error, {:invalid_decision, term}}` whitelist pre-dispatch, valid decisions on the local path, remote transport failure to `:"nonexistent-node@nowhere"` normalized to an error tuple and never raising).
`EvoGit.CommandApproval` exists in this tree, so the `Code.ensure_loaded?` guards take the real branch and the assertions are `{:error, _}`.
The remote-`{:erpc, …}` shape depends on whether the local node is distributed: non-distributed → `{:error, {:error, {:erpc, :noconnection}}}`, distributed → `{:error, :nodedown}`.
`safe_call_test.exs` — the exit-safe boundary `EvoDash.SafeCall`: `run/1` success, `raise` → `{:error, {:exception, %RuntimeError{}}}`, `exit(:boom)` and REAL `GenServer.call` dead-process/timeout exits → `{:error, {:exit, _}}`, `throw` → `{:error, {:throw, value}}`, non-function/non-0-arity → `{:error, {:invalid_function, term}}`; `run/2` returns the value (including falsy `nil`/`false`/`[]`) or the fallback; `start/3` delivers `{tag, {:ok, value}}` and every `{tag, {:error, {_}}}` to the parent; `start/4` honors `opts[:supervisor]` (membership checked in `Task.Supervisor.children/1`, not the default `EvoDash.TaskSupervisor`).
An unknown/dead supervisor EXITS via `Task.Supervisor.start_child/2` rather than returning `{:error, _}`, so that test asserts the durable contract only (never `{:ok, pid}`, never a stray result message) through a `catch :exit`-tolerant outcome check.
`settings_utils_test.exs` — `deep_put/3`, `deep_merge/2`, `deep_delete/2`, `parse_int/1`, `parse_float/1`, `parse_atom/2`, `maybe_add_kw/3`; two doctests live here.
`update_status_test.exs` — the `EvoDash.UpdateStatus` hub: initial `:idle` defaults, `check_started/0`, `handle_check_result/1` transitions, `request_download?/0`, `handle_download_result/1`, `applying/0`+`apply_failed/1`, `check_failed/1`, `desktop?/0`/`visible?/1`, and the `"updates"` broadcast.
It is `async: true` because no other async module WRITES the hub or the seams it mutates; the sync `live_hooks/update_status_test` owns `:update_notify_only_override` and `:desktop_quit_stop_fun` for the same reason (both keys have an async writer).
Setup pins `:update_notify_only_override` to `false` (so the download flow is testable on any host) and `reset/0`s the shared hub, snapshot-restoring every seam in `on_exit`.

## Notes for Agents — console-noise capture

ExUnit's suite-wide `capture_log: true` is WINDOW-based, so a line emitted by a process at the test boundary prints; two suites here capture explicitly (never by raising the global Logger level).
`desktop_lifetime_test.exs`: the watcher logs `[desktop] …` warnings from its own process, so each stop-driving action is wrapped in `ExUnit.CaptureLog` (`capture_log/1`, or `with_log/2` when the return value is also needed) AND the expected line is asserted as a log contract ("lifetime connection closed", "lifetime connection could not be established", "lifetime recv kept failing").
`node_context_test.exs`: the real remote-node RPC calls reach real distribution/net-kernel code that can log from global processes at the boundary, so they are wrapped in `with_log/2` — not `capture_log/2`, because the assertions are on the wrapped call's return value.

## Notes for Agents — deterministic waits

Negative assertions are zero-window mailbox scans (`refute_receive …, 0`) backed by a fence proving the unwanted message cannot exist or is already in the mailbox; never (re)introduce a tight numeric window.
`desktop_lifetime_test.exs` fences: the blocking-handshake `:recv_fun` seam (a preceding `assert_receive :recv_called`), `assert_disabled/1`, `assert_no_further_stop/1`, `await_recv_blocked/1`.
`directory_picker_test.exs` fences: `await_pick_idle/1` after an accepted pick, and the synchronous `{:error, :unavailable}` reply itself.
Preference order: drive the collaborator through its seams with a blocking handshake, then observe a real condition (process state, `Process.info/2`) with a bounded 1–2 ms poll; race a sleep-driven timer only when no condition is observable.
Positive assertions stay generous (`:gen_tcp.accept(…, 5000)`, `assert_receive …, 2000`) so real breakage fails loudly.

## Known Issues / Test Gaps

No `NodeContext.start_task/3` test exists here; `:path`, `:foreign_repos`, `:mode`, `:agent` and `:model_id` threading has only LiveView-level coverage (`projects_live_test`, `home_live_test`).
`foreign_repos` appears nowhere in this directory (zero matches), so multi-repo opt threading has no domain-layer regression test.
The remote `:erpc` delegation envelope is exercised ONLY by `approval_response/3`; every other remote delegate is untested here (they run on the local path).
`approval_response/3`'s documented `{:error, :nodedown}` branch is only reachable for a reachable-but-down node; `:"nonexistent-node@nowhere"` has an unresolvable host, so the `:noconnection` raise path is what is asserted.
The picker has no `:cancelled` and no path normalization/existence coverage; downstream path handling is covered in `evo_dash_web/live/projects_live/project_flow_test.exs`.

## Notes for Agents — async policy (per-suite)

Tests inside one module always run serially, so `async:` only decides whether a MODULE runs concurrently with other modules; ExUnit starts `async: false` modules only after every async module finished, so async-vs-sync overlap is impossible.
The 12 files here hold 13 case modules: ten `async: true` and three `async: false`.
The three sync modules, each blocked by a different process-global:
`active_tasks_test.exs` — reads/writes the boot-created `:evo_dash_active_tasks` hub that `ConnCase` resets (a concurrent reset would wipe it) and writes junk sentinel shapes (`[:a, :b]`) that an async whole-page mount's sidebar seed would crash on; it resets the hub in setup + `on_exit`.
`isolated_task_store_test.exs` — terminates and restores the process-global `EvoGit.Store`/`EvoGit.TaskRegistry` singletons and asserts ABSOLUTE properties of the replacement pair, by definition.
`node_context_test.exs`'s `EvoDash.NodeContextConfigTest` — swaps the process-global `XDG_CONFIG_HOME`, the only config-dir seam.
Async-safety facts for the async suites:
`node_context_test.exs`'s async module writes only unique-id rows into the run-wide store, so no isolation is needed and no row can satisfy a "not_found" assertion.
`chat_history_test.exs` — its only other consumer (`home_live_test.exs`) is `async: false`.
`update_status_test.exs` — NO async module writes the `EvoDash.UpdateStatus` hub or the seams it mutates; its only other writers (`live_hooks/update_status_test`, `system_live_test`, `node_aware_test`) are all `async: false`, so ExUnit never runs them concurrently with it. Its peers only READ the hub through the global `LiveHooks.UpdateStatus` on-mount hook (a navigation-dot seed no async suite asserts on) while `desktop?/0` is transiently true, and every seam/env var it mutates is snapshot-restored in `on_exit`.
`desktop_lifetime_test.exs` — snapshots/restores `EVOGIT_LIFETIME_PORT` and `:parent_stop_fun`; no other async module reads them.
`directory_picker_test.exs` — overrides `:directory_picker` + `:directory_picker_wx` and uses the app-started picker's global busy flag; its only other caller (`projects_live_test.exs`) is `async: false`.
`attached_file_test.exs`, `markdown_render_test.exs`, `settings_utils_test.exs`, `connection_diagnostics_test.exs` — pure functions plus, for the last one, an idempotent telemetry handler attach.

## Constraints

Mirror `lib/evo_dash/` under `test/evo_dash/`, one `*_test.exs` per module.
Snapshots/restores every app-env seam and env var the suite touches (`on_exit`), and restore rather than delete so a boot-seeded value survives.
A suite that needs the real store pair uses `EvoDash.Test.IsolatedTaskStore.isolate!/1` (or `assert_production!/0` when it deliberately runs production) — never a private ad-hoc store.
