# Live Hooks Test Directory

## Intent

ExUnit suites for the global on-mount hooks.
The `live_view/0` macro (`apps/evo_dash/lib/evo_dash_web.ex`) registers them in order SetLocale → **NodeAware** → Appearance → DesktopQuit → UpdateStatus → **Guide**, so EVERY real LiveView mount (dead render AND connected) runs the full chain — including the NodeAware sidebar hub seed (`on_mount/4` → `hub_snapshot/2` → `EvoDash.ActiveTasks.get` + the `assign_new` seed chain).
Two styles: pure unit/socket tests (no LiveView boot, split into `*_pure_test.exs` so they can be `async: true`) and full LiveView integration through `Layouts.app`.

`async:` split — 118 tests total: `async: false` for `node_aware_test`, `guide_test`, `update_status_test`, `appearance_test`; `async: true` for `node_aware_pure_test`, `guide_pure_test`, `desktop_quit_test`.
Rationale per suite: "Notes for Agents — async policy".

## Routing Table

| File | Hook | Style | Lines / tests |
|------|------|-------|---------------|
| `node_aware_test.exs` | NodeAware | DIRECT `NodeAware.on_mount/4` calls on dead + connected boot-shaped sockets, plus tests needing the isolated Store/TaskRegistry, per-test `XDG_CONFIG_HOME`, or fake ConnectionManagers. **No real LiveViews.** `async: false`. | 1632 / 51 |
| `node_aware_pure_test.exs` | NodeAware | Pure socket/function tests: `handle_connection_status/2`, `partition_active_tasks/1`, `handle_task_info/2` debounce, `event_from_current_node?/2` on hand-built `%Phoenix.LiveView.Socket{}` (`socket/1` + `patch_to/1`). `async: true`. | 466 / 26 |
| `guide_test.exs` | Guide | 8 real `/tasks` mounts against an isolated Store/TaskRegistry. `async: false`. | 235 / 8 |
| `guide_pure_test.exs` | Guide | Pure `normalize_guide/2` + `relevant?/2`. `async: true`. | 49 / 2 |
| `desktop_quit_test.exs` | DesktopQuit | 2 folded tests covering the whole dialog state machine over real `/system` + `/welcome` mounts. `async: true`. | 105 / 2 |
| `update_status_test.exs` | UpdateStatus | Pure handler units (`handle_check_result/1`, `handle_download_result/1`, `handle_apply_failed/1`, `stop_backend/0`, `initial_assign/2`). No mounts, no direct `on_mount` calls. `async: false`. | 153 / 11 |
| `appearance_test.exs` | Appearance | Pure seams + DIRECT `Appearance.on_mount/4` + real `/welcome` / `/system` mounts asserting `#app-layout`'s `data-accent-color`. `async: false`. | 422 / 18 |

## Per-suite facts

- **`node_aware_test.exs`** — `use ExUnit.Case, async: false`; module setup resets `EvoDash.ActiveTasks`.
  Helpers: `socket/1` (assign defaults incl. `current_node_id: "gpu-server"`, `remote_targets: []`, `remote_context_seq: 0`, `tasks_load_seq: 0`, `tasks_reload_pending: false`), `mount_socket/1` (dead render: `transport_pid: nil`), `connected_mount_socket/1` (`transport_pid: self()` makes `connected?/1` true), `assert_remote_context_loaded/0` (consumes the connected-mount `{:node_aware_remote_context, 1, _, _, result}` and returns `result`), `save_target!/2`, `insert_fixture!/2`, `setup_isolated_registry/1` (`EvoDash.Test.IsolatedTaskStore.isolate!("node_aware")`), `isolate_config_dir/1`, `await_until/2` (bounded poll), `spawned_view_tasks/1`.
  The socket shape needs `router: EvoDashWeb.Router` + `private.lifecycle` + `live_temp` and NO pre-set `:running_tasks`/`:pending_tasks` (so `on_mount`'s `assign_new` seeds from the hub).
  Describes: `handle_connection_status/2 — recomputes :remote_status`, `load_running_and_pending_tasks/1 — node-aware source`, `assign_node/2 — reloads sidebar tasks on node switch`, `async sidebar delivery + stale-guard`, `assign_node/2 — :remote_status assign`, `on_mount/4 — hub-seeded sidebar: no-blink / no-leak / no-remote-mount-fetch`, `on_mount/4 — connected-mount LOCAL fetch is unconditional`, `on_mount/4 — node-context load`, `exit-safety — a failed fetch never crashes the hook or wedges the sidebar`, `exit-safety — an EXITing sidebar fetch (unregistered store) reports back`, `handle_tasks_result/2 — applied results write the hub; stale never do`, `assign_node/2 — node switch to an unseen (cold-hub) connected remote still fetches`, `initiate_remote_connect/2 — shared async connect helper`.
  Leaves the hub EMPTY at module end.
- **`node_aware_pure_test.exs`** — `use ExUnit.Case, async: true`; local `socket/1` builder, no registry/Store/XDG/hub.
- **`guide_test.exs`** — one describe, 8 real `live(conn, ~p"/tasks")` mounts.
  Setup isolates Store/TaskRegistry under the FIXED name `EvoGit.TaskRegistry` and resets `EvoDash.ActiveTasks`; the helpers are `mount_tasks!/1` and `broadcast_guide!/2`.
  `broadcast_guide!/2` sends `{:guide_updated, "g1", payload, node()}` and then does a `:sys.get_state/1` round-trip, so the broadcast AND its `push_event` are handled before it returns — that synchronization is what makes the 0 ms `refute_push_event(view, "guide_highlight", …)` conclusive.
  `mount_tasks!/1` also registers an `on_exit` `await_view_async_loads/2` drain; it is NOT load-bearing for suite silence any more (ordered `IsolatedTaskStore` shutdown — registry first, bounded read-worker drain, then the Store — already prevents the between-test `[error]` crash report), and because ExUnit kills the test supervisor BEFORE any `on_exit` runs, such a drain can only monitor spawned children, never the view.
  Assert on the unique panel class `fixed top-4 right-4 z-50`, never the literal "Genesis Guide" (the layout's always-rendered HTML comment contains it).
- **`guide_pure_test.exs`** — `use ExUnit.Case, async: true`. `normalize_guide/2` canonicalizes atom- and string-keyed payloads to the same map and defaults missing fields; `relevant?/2` matches the current node and falls back to the local node when the assign is missing.
- **`desktop_quit_test.exs`** — `use EvoDashWeb.ConnCase, async: true`.
  Setup saves the prior `:desktop_quit_stop_fun`, injects a fake that messages the setup-captured test pid, resets `EvoDash.ActiveTasks`, and RESTORES the seam in `on_exit` (a blind `delete_env` could leave the VM-killing default in place).
  Does NOT isolate TaskRegistry/Store or `XDG_CONFIG_HOME` — mounts run against the real global registry and the real config dir (assertions are config-independent).
  Test 1 pins the full cycle on `/system`: hidden initially → open ("Quit Genesis?", the interrupted-tasks warning, `DesktopQuitConfirm` hook) → a second `desktop_quit_requested` does not error → cancel closes and re-arms (`desktop_quit_closed` push) → re-open → confirm runs the FAKE stop (`:desktop_stopped` received; the real `System.stop/0` would kill the VM) and pushes `desktop_quit_closed` again.
  Test 2 pins event pass-through (the System page's own `request_stop` → "Stop System?" without a quit dialog and without the stop fake) and that the dialog works on `/welcome` too.
- **`update_status_test.exs`** — `use ExUnit.Case, async: false`. Setup resets the `EvoDash.UpdateStatus` hub and forces `:update_notify_only_override` to `false` (restored via a `restore_env_value/2` helper that handles a stored `false` correctly); the single `stop_backend/0` test installs its own `:desktop_quit_stop_fun` and deletes it in `on_exit`.
- **`appearance_test.exs`** — `use EvoDashWeb.ConnCase, async: false`. Per-test `XDG_CONFIG_HOME` isolation plus dual-hub resets (`EvoDash.ActiveTasks.reset()` + `EvoDash.AccentCache.reset()` — both boot-created named ETS tables shared across suites).
  Direct `Appearance.on_mount/4` on boot-shaped sockets (dead render or `transport_pid: self()`), remote-accent `handle_params`/`handle_info` applies, then whole-page mounts asserting only `#app-layout`'s `data-accent-color`.
  Remote-target tests save a target via `EvoGit.RemoteConnections.save/1` and register the suite-local fake `EvoDashWeb.AppearanceTest.ConnectionManager` in `EvoGit.RemoteConnection.Registry` (a fake whose `:node` is the LOCAL BEAM node → deterministic success; a nonexistent node → fail-fast no-op).

## Notes for Agents

- **The NodeAware hub seed runs on every real mount**: `EvoDash.ActiveTasks` is a boot-created named public ETS table (`:evo_dash_active_tasks`, owned by the long-lived application process — the module is a pure ETS helper with no process), alive for the whole `mix test` run, and its `{nil, node()}` local key is shared across ALL evo_dash suites.
  Every mounting suite here calls `EvoDash.ActiveTasks.reset()` in setup (appearance_test additionally resets `EvoDash.AccentCache`), otherwise a warm non-empty local hub would seed sidebar tasks into a later suite's dead-render html.
- **Connected-mount fetch side effect**: every mounting suite with a LOCAL page spawns a fire-and-forget sidebar fetch on each connected mount against the TaskRegistry in force at mount time (the local fetch is unconditional), and EVERY connected mount (local, remote or pending) also spawns the ONE node-context load (`:remote_targets` + `:connection_statuses`).
  guide_test isolates its registry (empty → harmless); desktop_quit_test and appearance_test run against the REAL global registry.
- **Fragility of HTML assertions**: no suite here asserts on "Active Tasks" sidebar content/absence. Asserted strings are modal/guide-specific. Layout gate: `layouts.ex` renders the Active Tasks section when `@running_tasks != [] or @pending_tasks != []`.
- **Direct `on_mount` calls DO read the hub**: `node_context_from_params` + `hub_snapshot` run unconditionally on both dead and connected paths — the connected-mount SIDEBAR fetch is gated on `connected?(socket)` AND a LOCAL context (`seed_node_id == nil`), while the connected-mount node-context load runs for EVERY context.
  Direct-call tests therefore observe: reset-cold hub → seeds `[]` via `assign_new`; pre-warmed hub → seeds the snapshot synchronously (then the connected local fetch still fires); dead-render sockets never receive a fetch message; connected local sockets receive `{:node_aware_active_tasks, 1, nil, node(), {:ok, {running, pending}}}`; connected remote/pending sockets receive only `{:node_aware_remote_context, 1, _node_id, _node, {:ok, {targets, statuses}}}`.
- **`use ExUnit.Case` vs `use EvoDashWeb.ConnCase`**: node_aware_test, node_aware_pure_test, guide_pure_test and update_status_test use plain `ExUnit.Case` (no conn fixtures); guide_test, desktop_quit_test and appearance_test use `EvoDashWeb.ConnCase` + `import Phoenix.LiveViewTest`.

## Notes for Agents — async policy (per-suite, verified)

**Scheduling model**: ExUnit runs ALL `async: true` modules first (concurrently, up to `max_cases`), then `async: false` modules one at a time — a sync module never overlaps another module, and an async module's only concurrency partners are the other async modules.
A flip is only unsafe when another `async: true` module touches the same global state.

- **`node_aware_pure_test`, `guide_pure_test`, `desktop_quit_test` → `async: true`.** They touch no global Store/TaskRegistry, `XDG_CONFIG_HOME` or ETS hub. desktop_quit_test is the SOLE async owner of `:desktop_quit_stop_fun` (it saves/restores the seam; `update_status_test`, the other user, is `async: false`) and writes only the `ActiveTasks` hub, via ConnCase's reset.
- **`node_aware_test`, `guide_test` → MUST-STAY-SYNC**: both integration setups terminate + restart the production `EvoGit.TaskRegistry`/`EvoGit.Store` GLOBAL singleton under the fixed registered name; node_aware_test additionally swaps `XDG_CONFIG_HOME` and registers fake ConnectionManagers in the global unique `EvoGit.RemoteConnection.Registry`.
- **`appearance_test` → MUST-STAY-SYNC**: `System.put_env("XDG_CONFIG_HOME", ...)` mutates a process-global env var (no per-test or per-process seam exists — an app-env override would itself be global), and it writes the `AccentCache` hub.
- **`update_status_test` → MUST-STAY-SYNC**: shares `:desktop_quit_stop_fun` + the `EvoDash.UpdateStatus` hub with the `async: true` `desktop_quit_test`.
- **Cross-suite hazard for ANY async fake-manager suite**: `EvoGit.RemoteConnection.Registry` is `keys: :unique` and fakes call non-bang `Registry.register/3` whose error tuple is ignored — two suites using the SAME target id concurrently would silently route lookups to the first-registered manager (assertion failures, not a crash). Keep new async fake ids unique.

## Notes for Agents — deterministic negative waits (do not re-grow these windows)

Every "nothing was fetched / nothing was scheduled" assertion here is backed by an observable side effect, so the receive windows are either 0 ms (the backstop is proof in itself) or a small belt-and-braces margin — never the evidence.

- **Sidebar-fetch backstop — `:tasks_load_seq`**: `NodeAware.request_tasks_load/1` (the single spawner behind `on_mount/4`'s connected-LOCAL fetch, `assign_node/2`'s context-change reload and `reload_tasks/1`) bumps the socket's `:tasks_load_seq` assign BEFORE spawning on `EvoDash.TaskSupervisor`, and `on_mount/4` seeds it to 0 — so `assigns[:tasks_load_seq] == 0` DETERMINISTICALLY proves no fetch was spawned, and an unchanged seq proves the `:tasks_node_loaded` dedup guard suppressed a re-spawn.
  Every `refute_receive {:node_aware_active_tasks, _, _, _, _}, 0` in `node_aware_test.exs` sits next to its `tasks_load_seq` assertion.
- **0 ms windows that replaced timed ones**: the `initiate_remote_connect/2` "no `{:remote_connect_result, ...}` self-message" tests first await `not Process.alive?(caller)` for the spawned connect Task (its `{:error, reason}` arm is its LAST expression, so a dead Task proves any send is already in the mailbox); the `nil target_id → no spawn` test asserts `spawned_view_tasks(self()) == []` (a synchronous `start_child/2` means an empty child list proves no spawn) plus `GenServer.call(manager, :calls) == []`.
- **Debounce backstop (pure suite)**: the `handle_task_info/2` drop/coalescing negatives use 20 ms (`2×` the 10 ms `:node_aware_reload_debounce_ms` test seam), each proven by the unchanged-socket / `tasks_reload_pending == false` / already-consumed-`assert_receive` assertions — any path reaching `debounce_task_reload/1` would have returned a CHANGED socket with `tasks_reload_pending: true`. The scheduling positives use a generous 2000 ms budget (a 500 ms budget reproducibly flaked under CPU load).
- `await_until/2` is a bounded poll (2000 ms budget), not a fixed wait. The `Process.sleep(state.delay_ms)` in the `ConnectionManager` fake is deliberate test choreography.

## Notes for Agents — exit-safe async loader results (current message shapes + guards)

Both async loads are exit-safe: the fetch/registry reads run inside `EvoDash.SafeCall.run/1`, so a `GenServer.call` timeout or a dead store/RPC target (an EXIT, which a `rescue` cannot catch) becomes an `{:error, reason}` VALUE and a result message is ALWAYS sent.
Sidebar shape: `{:node_aware_active_tasks, seq, node_id, node, {:ok, {running, pending}} | {:error, reason}}` (`handle_tasks_result/2` also still accepts the legacy bare `{running, pending}` payload — pinned by its own test).
Node-context shape: `{:node_aware_remote_context, seq, node_id, node, {:ok, {targets, statuses}} | {:error, reason}}`, spawned by `on_mount/4` on EVERY connected mount (never on a dead render, where `:remote_context_seq` stays 0).
Both are intercepted by the attached `:handle_info` hook (`handle_info/2` → `{:halt, ...}`); every other message passes through with `{:cont, socket}`.
`handle_tasks_result/2` guard: `node_id`/`node`/`seq` must all match the socket assigns, else the result is dropped wholesale — a stale result never writes `EvoDash.ActiveTasks` AND never clears `:tasks_reload_pending` (that flag belongs to the NEWER in-flight request).
An APPLIED result (ok OR error) always clears `:tasks_reload_pending`; `{:ok, {running, pending}}` assigns + writes the hub (sanitized to maps only), while `{:error, _}` keeps the last-known lists and hub snapshot untouched.
`handle_remote_context_result/2` guard: only `seq` (targets/statuses are node-INDEPENDENT, so a mid-flight node switch must not throw the target list away); `{:error, _}` and malformed payloads keep the last-known `:remote_targets`/`:connection_statuses`.
Test patterns: drive failures with explicit tagged messages (`{:error, {:exit, :timeout}}`) through `handle_info/2` (hook path) or `handle_tasks_result/2` (pure seam) instead of sleeping or killing processes.
Deterministic end-to-end EXIT: `Process.unregister(EvoGit.TaskRegistry)` on the ISOLATED registry makes a `GenServer.call` to the name exit with `:noproc` (no kill/restart race) — the spawned fetch then sends `{:error, {:exit, _}}`; the test re-registers the captured pid immediately (plus an `on_exit` backstop) before further store work.
