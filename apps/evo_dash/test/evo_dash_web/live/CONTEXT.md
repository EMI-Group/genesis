# Test Directory — EvoDashWeb Live Tests

## Intent

ExUnit suites for the EvoDash LiveView pages and their support modules, mirroring `apps/evo_dash/lib/evo_dash_web/live/`.
Page suites are split by MODULE for parallelism, so "is this page suite async?" has no per-file answer — check the module (module census and forcing globals: `apps/evo_dash/test/CONTEXT.md`).
This node owns the cross-suite mechanics: deterministic-wait cadences, the ReviewLive suite, async mount loads and exit-safety seams.
Per-suite detail is pushed into the child docs: `./projects_live/CONTEXT.md`, `./settings_live/CONTEXT.md`, `./home_live/CONTEXT.md`, `./agents_live/CONTEXT.md`.
No page or unit suite writes the config dir BEAM-globally: it is isolated per process through `EvoDash.Test.ConfigDir.isolate!/1` (proof: `../support/config_dir_test.exs`).

## Routing Table

- `./projects_live_test.exs` (157 tests: 134 async `ProjectsLiveTest` + 23 sync `ProjectsLiveSyncTest`) → Projects page suite: project form/palette/settings (VCT-backed identity: a palette row's primary line is the mount display `name` with the OS `path` secondary, while search still matches the VCT `point`), task notifications, the exit-safe async mount batch, remote-node contexts via a fake `ConnectionManager` in `EvoGit.RemoteConnection.Registry`, directory picker, file attach, cross-OS remote paths, foreign repos, custom agents, model selection, GitHub issues, speed ↔ quality.
- `./projects_live/` → pure Projects support units and the mounted page's selection/async-load contracts — `./projects_live/CONTEXT.md`.
- `./review_live_test.exs` (44 describes / 113 tests, 9 case modules) → review page against the PER-REPOSITORY CARD design; see "ReviewLive suite" below.
- `./settings_live_test.exs` (134 declared tests: 3 async `SettingsLiveParentAdapterTest` + 105 async `SettingsLiveTest` + 26 sync `SettingsLiveGlobalStateTest`) → Settings parent adapter and page: canonical provider CRUD/default/legacy editing, nested generation and reasoning inheritance, model/schedule row actions, Quick Setup, connection options, search, custom providers, whitelist safety, sandbox/nix gating, remote connections and appearance.
- `./settings_live_agents_test.exs` (12, `async: true`) → Settings **Agents** category: custom-agent CRUD, model-selection script, custom-tools panel, remote degradation.
- `./settings_live/` → pure and focused page units (`provider_profiles_contract_test.exs`, `model_profile_helpers_test.exs`, `config_io_test.exs`, `auth_status_test.exs`, `model_ids_test.exs`) — `./settings_live/CONTEXT.md`.
- `./system_live_test.exs` (56: 26 async `SystemLiveTest` + 30 sync `SystemLiveSyncTest`) → System page: scheduler/system controls, platform gating, bwrap helpers, self-check, scheduler charts, software-update card, genesis-source card.
- `./system_live/` → `charts_test.exs` (13 — ring buffer, series builders, scale helpers, `chart_card/1`).
- `./tasks_live_test.exs` (81, `async: false`) → cross-project task list: search/filter, pagination, cancel/force-kill modals, `:cancelling` display, debounced reloads, exit-safe page loads, lazy per-card detail + archive, server-side `session_mode` filter.
- `./agents_live_test.exs` (50, `async: true`) → agent tree (node-aware async loads, push-driven refresh), the left-panel view switcher + TEMPORAL commit-history view, the compression threshold, the context meter and `LoadData`.
- `./agents_live/` → `commit_graph_test.exs` (63), `commit_graph_refresh_test.exs` (11), `context_meter_test.exs` (13) and `tool_call_display_test.exs` (10) — `./agents_live/CONTEXT.md`.
- `./processes_live_test.exs` (17, `async: false` `EvoDashWeb.ProcessesLiveTest`) → the managed-process `/processes` page: status/kind/free-text/agent-id/task-id URL filters, the five node-tagged `"processes"` PubSub events applied without refetching, pause/resume, the reason-required Terminate/Kill modal, control-error flashes, the load-error + Retry state, and row expansion with the control log.
- `./home_live_render_test.exs` → nine `async: true` pure page-template contracts via `render_component(&HomeLive.render/1, assigns)` covering empty/restored conversations, actionable suggestions, composer accessibility/keyboard wiring, Send/Stop states, local-source gating and the fused-capsule drill-down DOM without a `/help` mount or global ChatHistory writes.
- `./approval_card_render_test.exs` → seven `async: true` pure ApprovalCard render contracts covering exact evaluator code/target, write versus sudo authority and warnings, request-id-only decisions, busy controls, and legacy command presentation.
- `./home_live_test.exs` (`async: false`) → mounted Genesis Assistant page (`GET /help`, `:reflect` self-reflective agent), interactive sessions, evaluator/legacy approval presentation and asynchronous recovery/response integration — `./home_live/CONTEXT.md`.
- `./home_live/` → `async: true` support-module units (assistant message, chat state, messages, transcript, session actions/list, model select, approval workflow) — `./home_live/CONTEXT.md`.
- `./welcome_live_test.exs` (26: 25 async + 1 sync `TaskBroadcast`) / `./welcome_complete_live_test.exs` (3: 2 async + 1 sync `TaskBroadcast`) → onboarding pages: canonical multi-model/default/reasoning setup, API-key and OAuth branches, concurrent config preservation, malformed-file protection and deterministic generation-guarded connection results (WelcomeComplete pins the full example/clipboard objective).
- `./platform_info_test.exs` (10, `async: true`) → pure `EvoDashWeb.PlatformInfo` platform/nix gating.
- `../components/`, `../live_hooks/`, `../controllers/` → sibling suites documented in their own CONTEXT.md (read-only from this node).

## Notes for Agents — deterministic waits (the single rule future edits must not break)

The app-wide wait, capture-log and mount-funnel rules live in `apps/evo_dash/test/CONTEXT.md`; this section only pins the live-page cadences.
Every wait is deterministic: a synchronous `assigns/1` read (`:sys.get_state/2` with an EXPLICIT 30 s timeout — never the 5 s default), a monotonic seq/counter written inside the handler, or a bounded poll at a 1–2 ms cadence.
Every async-load deadline/poll budget in this tree is `@async_wait_budget_ms` (or an equivalent module attribute) = 30 s, sized for this shared host's 10–30× load swings; the budgets stay bounded and assertions keep their full strength, so real breakage still fails loudly.

- `tasks_live_test.exs` — `@wait_poll_ms` = 2 ms via `wait_until/3`; `flush_tasks_load/2` drains a load chain `flush_loading` → `tasks_loading == false` (30 s `:sys.get_state/2`) → `drain_async_loads/2` (a leading socket read, then wait out an armed `tasks_reload_pending` debounce, then `await_view_async_loads/2`) → `render/1`.
- `review_live_test.exs` — `@wait_poll_ms` = 2 ms inside `wait_until/2`.
- `home_live_test.exs` — `@poll_interval_ms` = 2 ms inside `wait_until/2` (30 s budget); `await_source_available/3` 30 s.
- `welcome_live_test.exs` — `@runner_start_timeout` and `@async_wait_budget_ms` = 30 s (`assert_receive {:welcome_test_started, …}`, `await_status`).
- `projects_live_test.exs` — `wait_assigns/3`, `wait_for_fake_callers/3`, `await_async_loads/1` and the GitHub describe's `wait_until/3` poll at 2 ms under 30 s budgets; `wait_for_task_terminal/2` polls `TaskRegistry.get_task/1` every 2 ms with a 10 s budget and is best-effort (it only keeps a still-spawning git port from racing a temp-dir teardown).
- `agents_live_test.exs` — `wait_until/2` and `await_latch/2` poll at 10 ms / 1 ms under 30 s budgets (`await_latch/2` never raises); `render_until/3` + `submit_until_pending_hint/3` poll `render/1` for out-of-band async applies and always return the LAST render so a persistent failure still fails with the real output.
- `settings_live_test.exs` / `settings_live_agents_test.exs` / `system_live_test.exs` — 1–2 ms cadence under 30 s budgets (`@settle_timeout_ms`, `wait_settings`, `await_mount_async_loads`, the system awaits).

**The 0 ms rule**: zero-length `refute_receive` / `refute_push_event` probes are allowed ONLY after the mailbox has provably drained — i.e. after a synchronous `:sys.get_state` round-trip, a completed drain helper, or a dead-helper-process await has ALREADY proved the preceding work finished.
Then the 0 ms probe is conclusive and strictly stronger than any timed window; without such a precedent, use a bounded backstop (a monotonic counter assertion) plus a small margin.
Examples in force: `tasks_live_test`'s `refute_receive :page_load_spawned, 0` (preceded by `page_load_seq == 1/2` and by the synchronous `:sys.get_state`), `agents_live_test`'s `refute_receive {:commit_graph_call, …}, 0` after asserting both commit-graph assigns false, and the seven `refute_push_event(view, "task_notification", %{}, 0)` probes in `ProjectsLiveSyncTest` (never in the async module — the scan is store-global) after `drain_task_reload/1`.
No fixed `Process.sleep` is a mechanism anywhere; the only fixed waits are deliberate and documented per suite.

## Notes for Agents — ReviewLive suite (`review_live_test.exs`)

**The file is ONE file with ELEVEN modules, split for parallelism**: the file-local `EvoDashWeb.ReviewLiveTest.Helpers` (shared helpers + fixtures, no tests), nine `use EvoDashWeb.ConnCase` suites — `ReviewLiveArchiveTest` (21 tests, async), `ReviewLiveMergeCheckTest` (2, async), `ReviewLiveLoadTest` (14, async), `ReviewLiveMultiRepoTest` (13, async), `ReviewLiveChromeTest` (16, async), `ReviewLiveRemoteAutoResolveTest` (1, async), `ReviewLiveMergeTest` (24, sync), `ReviewLiveAutoResolveTest` (3, sync), `ReviewLiveSyncTest` (19, sync) — and a `ConnectionManager` fake.
ExUnit parallelises across MODULES, never within one, so carving one long file into several modules is what actually shortens the run.
Which module a test lands in is decided by two PROCESS-GLOBAL hazards, both symmetric (a writer and a reader must not overlap): app env (`Application.put_env/2` seams) + the `EvoDash.ActiveTasks` hub + `PATH`, and the `"tasks"` PubSub topic — `EvoGit.TaskRegistry` broadcasts on every mutation, which arms `NodeAware`'s reload debounce on EVERY mounted page in the BEAM, so a module that CLICKS a task-mutating review action is a publisher and must stay sync.
Fixture SEEDS go through `EvoGit.Store.put_task` and cleanup goes through `delete_seeded_task!/1` (a direct Store delete, no broadcast) for exactly that reason.

**Every review action runs OFF-PROCESS.** `ReviewLive.spawn_action/4` starts an `EvoDash.TaskSupervisor` child behind `EvoDash.SafeCall.run/1` that always reports `{:review_action_result, task_id, node, action, action_ref, result}`, applied by `apply_action_result/4` after the in-progress marker (`@review_action`, nil | `%{kind:, repo_id:, seq:}`) is cleared.
Consequence for tests: `render_click`/`render_submit` only prove DISPATCH.
Any assertion on action-derived state — `local_repo_resolutions` / a repo's `resolution`, `review_status`, the completion banner, the `EvoDash.ActiveTasks` hub snapshot, a flash from an action — or on an injected runner-seam message MUST call the file-local `await_review_action_settled/1` after the click (it polls for `review_action == nil` and returns a fresh render; a STOPPED view counts as settled and yields `""`, which is why it tolerates `:noproc`).
`settle_debounced_task_reload/1,2` is still required before the NEXT mutation click and before durable reads: it syncs on `TaskRegistry.list_tasks/0`, drains the debounce via `assigns/1`, waits `:tasks_reload_pending → false`, then flushes a landing async review load.
Transient post-action state (`branch_exists == false`) is read BEFORE settling; durable state (`:resolution`, banner, `review_status`, hub snapshot, card DOM) AFTER.
The suite does NOT depend on a wide `:node_aware_reload_debounce_ms` window.

Helper inventory (all public on the shared `EvoDashWeb.ReviewLiveTest.Helpers` module and imported by every suite module — verify before naming anything new; `target_branch_selection/1` never existed, it is `target_branch_select/1` + `selected_option_value/1`):
`await_review_action_settled/1`, `settle_debounced_task_reload/1,2`, `flush_review_load/2` (delegates to `EvoDashWeb.TestHelpers.flush_loading/4` after `await_mount_async_loads/1`), `await_mount_async_loads/1`, `mount_async_task_pids/1`, `wait_hub_warm/1`, `assert_hub_excludes_task/1`, `wait_until/2`, `repo_resolution/2`, `mount_with_repos/3` (injects a `{:review_data_loaded, …}` at the CURRENT `load_generation`), `repo_card_html/2`, `overflow_menu/1`, `repo_select_state/1`, `repo_target_selection/2`, `completion_back_href/1`, `target_branch_select/1`, `selected_option_value/1`, `merge_submit_state/2`, `reject_button_state/2`, `task_action_state/2`, `control_state/2`, `install_blocking_merge_runner/2`, `install_blocking_reject_runner/1`, `install_failing_gh_cli/0`, and the seeding/git-fixture helpers below.
The blocking runners signal `{tag, runner_pid, repo_path}` and block on `receive :release` — a deterministic "still in flight" window with no sleeps.
The suite is organised around FOLDED multi-scenario tests (one mount drives a whole state machine), which is why describes carry few `test` blocks.

**Module setup (identical in all eight suites)**: `EvoDash.Test.IsolatedTaskStore.assert_production!()`; `install_canonical_merge_check_runner()` in `setup_all` — ONE canonical `Helpers.canonical_merge_check_runner/4` stub installed for the whole file family and NEVER deleted (an unstubbed runner does real `merge-tree` work that races ExUnit's temp-repo teardown, and a per-test DELETE would punch a hole a concurrently mounting sibling could fall into).
The merge-check module's BLOCKING stubs therefore do NOT replace the app-env value: they register their own fixture repos in a per-test `:persistent_term` set consulted by that one canonical function, and every other repo resolves to `:clean` immediately.
The six `async: true` suites clear ONLY the local `{nil, node()}` context (`EvoDash.ActiveTasks.invalidate(nil, node())`, on entry AND in `on_exit`); the three `async: false` suites keep the whole-table `EvoDash.ActiveTasks.reset()`.

**Per-repo card contract**: one card per repo (`RepoCards.repo_cards/1`; the primary-scoped Continue-task + "…" overflow menu live in `Actions.task_actions/1`).
Merge/reject are per-repo and never navigate — `render_submit` on `#merge-form-<repo_id>` (hidden `name="repo_id"` + its own `<select name="target_branch">`) or `render_click(view, "reject", %{"repo_id" => id})`; the runner seam is invoked ONCE per call.
Ids: `#review-repo-cards`, `#review-completion-banner` / `#review-completion-back` (only when completion != nil), `#repo-card-<repo_id>`, `#repo-resolution-<repo_id>` (ALWAYS present, empty when unresolved), `#merge-form-<repo_id>`, plus the unchanged `#diff-repo-switch-form` / `#commits-repo-switch-form` (each repo `<select phx-change="switch_repo">` must live inside its OWN form).
Resolution states: `nil` (actions rendered iff `branch_exists`), TERMINAL `:merged`(`target`) / `:rejected` / `:handled` (load-time seed: non-blank `branch_name` ∧ NOT `branch_exists`), non-terminal `:error` / `:conflict`(`detail`).
Merge targets travel in `:review_merge_runner` / `:review_reject_runner`; the async merge check in `:merge_check_runner` (results injected as a 6-tuple `:merge_check_result`).
Archive seams: `:review_archive_runner` (3-arity `(node, task_id, opts) -> %{entries: [map()], total: non_neg_integer()}`) and `:review_archive_agent_runner` (3-arity `(node, task_id, agent_id) -> map() | nil`), resolved INSIDE the spawned child at CALL time.
Result messages: `{:review_archive_loaded, task_id, node, seq, offset, result}` (`offset == 0` REPLACES, larger APPENDS deduped by `agent_id`) and `{:review_archive_agent_loaded, task_id, node, agent_id, seq, result}`; both are stale-dropped on a task/node mismatch or an older `seq`.
`NodeContext.get_task_lite/2` is the page load (LITE — no archive key); `ArchiveLoad.sync_context/1` is unit-tested on a hand-built `%Phoenix.LiveView.Socket{}` (`archive_socket/1` must carry `__changed__: nil` because `force_assign/3` reads it).

**Git fixtures**: the suite needs REAL repos (a base commit, a primary branch renamed from the machine's `init.defaultBranch`, an optional secondary branch, an agent `task-branch` with a change commit).
- Module templates (PER module, never shared): each suite module's `setup_all` pre-builds ONE repo per required `{primary, secondary}` shape via `build_templates!/1` → `build_repo_with_task_branch!/3` and passes it into each test through `Process.put(:review_templates, templates)` in a `setup` block.
- Why the process dictionary: the helpers live on a module shared by eight suites, so they must not key fixtures on `__MODULE__`; `review_template!/2` reads `Process.get(:review_templates)` and every `on_exit` closure captures the map instead of reading it.
- Per-test copy: `create_review_task_with_repo!/3` and `create_multi_repo_review_task!/2` call `copy_review_template!/3`, which `File.cp_r!/2`s the template into a unique `System.tmp_dir!()` dir; the copy is a plain recursive BYTE copy — never `cp -l`/hard links, never `git clone --shared` — so a test may freely mutate its copy.
- `review_template!/2` RAISES when asked for a pair this module's `setup_all` did not pre-build — add the pair to that module's `build_templates!/1` list.

## Notes for Agents — async mount loads & exit-safety seams

`ProjectsLive`, `TasksLive` and `SettingsLive` do ZERO task-store work in `mount/3`: loads run through app-env RUNNER seams resolved AT SPAWN TIME inside `EvoDash.SafeCall.run/1`, so a runner that exits/raises becomes an error VALUE (or sends nothing) instead of crashing the page.
Install seams with `Application.put_env` before `live/3` and delete them in `on_exit`.
Mount results must be funnelled before a test drives events (owner-aware `$callers` funnels — see `apps/evo_dash/test/CONTEXT.md`).

- **ProjectsLive** — `:projects_async_load_runner` batch shape, the `{:async_project_load, node, prev_node_id, path, results}` message, `wait_for_projects/2` / `wait_notified_ids_ready/1` / `await_async_loads/1`, the frozen-registry off-process proof and the blocked-batch pattern: `./projects_live/CONTEXT.md`.
  The `?resume_from=` foreign-repo restore is ASYNC too (`{:foreign_repos_restored, task_id, node, result}`); read `assigns(view)[:foreign_repos]` only after waiting.
- **TasksLive page load** — `:tasks_page_load_runner` is a 4-arity `(node, page, page_size, filters)` fun resolved inside `PageLoad.run/6`; `{:tasks_page_loaded, seq, node, result}` is ALWAYS sent, so `exit(:boom)` / `raise "boom"` runners leave the LiveView alive with `tasks_loading == false` and `tasks_error != nil`.
  `:tasks_page_load_hook` (installed by `install_page_load_hook/0`) observes every spawn; `:page_load_seq` is bumped only by `start_async_page_load/3` — the hook's only caller — so it is the deterministic witness for "a load was spawned", paired with a 0 ms `refute_receive`.
  Error UI: a load that never succeeded with no rows renders `#tasks-load-error` ("Could not load tasks.") INSIDE `#tasks-list`; a failed BACKGROUND reload keeps the rows and renders `#tasks-refresh-error` ("Could not refresh tasks.") ABOVE `#tasks-list` (assert the strip via `render(view)`, rows via `render_tasks_list(view)`); recovery: delete the seam, `render_click(view, "retry_load")`, wait `tasks_error == nil`.
  `flush_tasks_load/2` must be the LAST statement of every test that mounts `~p"/tasks"`.
- **SettingsLive mount funnel** — `mount_settings/2` funnels every mount in the file: `live/3`, then `await_mount_async_loads/1`, and only then hands the view to the test, so a late node-data apply can never clobber test-driven state; the ORIGINAL mount HTML is returned unchanged.
  `settings_live_agents_test.exs` uses its OWN owner-aware variant (`mount_settings/1` → `await_view_async_loads/1`, reused at the `reload_custom_tools` click).
  Seeding and the canonical provider fixtures: `./settings_live/CONTEXT.md`.

## Notes for Agents — Agents-page commit-history view (temporal) tests

`@left_view` (`:tree` default | `:commits`) is toggled by `handle_event("switch_left_view", %{"view" => "tree"|"commits"})`; the segmented buttons are `#left-view-tree` / `#left-view-commits`.
Switching to `:commits` lazily fetches the TEMPORAL graph through `:agents_commit_graph_runner` (default `&EvoDash.NodeContext.list_task_commit_graph/5`), resolved AT SPAWN TIME inside an `EvoDash.TaskSupervisor` child — stub it BEFORE `live/3` and never let a test reach the real RPC/core (`EvoGit.CommitGraph` may be absent).
The fetch is TASK-SCOPED and stale-guarded on the viewed node plus `seq < commit_graph_seq`; `{:error, reason}` KEEPS the last good graph and only sets `commit_graph_error`.
`@retained_agents` keeps an ended agent's last-known map (`ended: true`) so its graph entry, rows and START/END annotations survive removal while the agent TREE shows only `@agents`.
Page-level ids, the lane/edge/row contract, the partial-success + fingerprint-gate wiring and the two production behaviours the tests work around: `./agents_live/CONTEXT.md`.

## Notes for Agents — Home chat suite (`home_live_test.exs`)

The mounted `/help` suite is `async: false` and owns the process-global `EvoDash.ChatHistory`, `EvoDash.ActiveTasks`, the isolated Store/TaskRegistry pair and the per-test `:home_session_*` / `:approval_*` / `:source_*` app-env seams.
Chat state is SEEDED (never driven by a real send) except ONE canonical real-send pin; interactive sessions, approval recovery and the genesis-source gate are documented in `./home_live/CONTEXT.md`.

## Notes for Agents

- **NO real LLM/exec in dashboard live tests** (suite policy): a test must never be able to reach `AgentScheduler.run_agent` or the network.
  - Home chat: `model_profiles: []` pushed into the AgentScheduler in setup (restored in `on_exit`) so every spawn is rejected synchronously with `{:error, :llm_not_configured}`; the one real-send pin asserts that path.
  - Projects page: the ~10 task-form/GitHub-fix launches pin the dashboard→TaskRegistry opts-threading contract on the persisted `EvoGit.TaskInfo` row and stay real for exactly that contract, but structurally cannot reach the LLM — 9 fail fast at `validate_node_path` via the `node_path: "./nonexistent-dir"` lever, and the GitHub-fix test dies at `resolve_starting_commit` on an unborn-HEAD repo seed. In-body `cancel` calls were dropped and `stub_github_upstream_check!/0` keeps the async GitHub-upstream `git remote get-url` from racing setup teardown.
  - `ExUnit.start(capture_log: true)` hides the side effects for passing tests, which is WHY the policy is structural (no path to the LLM), not output-grep-based.
- **Async log noise — capture the emitting work IN-window**: wrap the TRIGGERING ACTION plus an AWAIT of the emitting work's completion in `ExUnit.CaptureLog.capture_log/2` (or `with_log/2` when the action's return value is needed), await with the file's poll idiom, and assert a deterministic log fragment as proof the capture holds.
  Sites: `home_live_test` `with_log/2` around `render_submit` + await the persisted reflect row's terminal status → `assert log =~ "SelfReflective failed"`; `review_live_test` `capture_log/2` around the auto-resolve click + `await_merge_task_terminal/1` → `assert log =~ "TaskRegistry"`; `projects_live_test` `with_log/2` around `retry_remote_connection` + await the fake manager's connect → `refute log =~ "No distribution cookie configured"`.
- **`test_llm` handlers spawn REAL provider requests**: `SettingsLive.handle_event("test_llm", …)` and `WelcomeLive.handle_event("test_llm", …)` each start a DETACHED `EvoDash.TaskSupervisor` child running `EvoGit.SystemCheck.llm_test/1,2` → `ReqLLM.stream_text/3`; when a provider key is resolvable it makes a real streaming request whose failure line can land outside the capture window.
  The settings handler contracts select a canonical persisted provider/model but use an unreachable BEAM node and await `{:llm_test_result, {:error, _}}`, so they cannot reach a provider or the local `SystemCheck`.
  The parent resolver-options contract and mounted map-model render contract use isolated loopback endpoints with custom fixture credentials.
  The three `welcome_live_test` "LLM connection test" tests that trigger `test_llm` are noise-free: each wraps the trigger PLUS a bounded in-window await in `with_log/2`, and the two needing no real credential first call `scrub_anthropic_credential!/0` (deletes the `:req_llm` app-env key AND `ANTHROPIC_API_KEY`).
- **SystemLive chart tests must stub the seed runner**: any test asserting on `chart_samples` MUST set `:system_samples_runner` before mounting — the default runner reads the real `EvoGit.SystemSampler` ring buffer. `config/test.exs` disables the tick, but that is an accident of config, not a guarantee; the file-level setup snapshot-restores the update/source/`:system_samples_runner` / `:system_samples_seed_retry_ms` seams in `on_exit`.
  The two "failed seed retries" tests set `:system_samples_seed_retry_ms` to 5 ms (production default 3000 ms).
  The update card's "Check now flow" test makes `:update_check_runner` signal its start and BLOCK until the test has observed `:checking` (bounded 5 s handshake), then terminates the click's own `EvoDash.TaskSupervisor` children.
  Genesis-source `:source_clone_runner` / `:source_update_runner` need NO delay (busy state assigned synchronously).
- **Remote-node test pattern**: save a unique target via `EvoGit.RemoteConnections.save/1` in a per-test config dir (`EvoDash.Test.ConfigDir.isolate!/1`), then `start_supervised!` a fake `ConnectionManager` GenServer registered in `EvoGit.RemoteConnection.Registry` with `%{phase: :connected, node: "genesis_remote@127.0.0.1", last_error: nil}`.
  Unstubbed `:erpc` calls to a fake node fail fast; positive URL/resume activation uses explicit target-owned supervised runner fixtures, not the local node as a fake remote.
  The fake's `:connect_delay_ms` option is UNUSED: the "sidebar select_node … connects off-process" test proves off-process execution via the caller pid.
- **`normalize_remote_project_path/2` tilde seam**: `:remote_path_expand_runner` is read at CALL time; tests inject fakes (`project_flow_test.exs` `install_expand_runner/1`).
- **Foreign-repo raw storage in remote contexts**: `EvoGit.Core.ForeignRepo.new/3` runs `Path.expand/1`, so EvoDash remote contexts bypass it via `ProjectFlow.build_foreign_repo/4`; tests assert raw-verbatim roots (POSIX and Windows, host-OS independent) — `./projects_live/CONTEXT.md`.
- **`EvoDash.ActiveTasks` sidebar-hub pollution**: every full-page mount seeds `:running_tasks`/`:pending_tasks` from the shared hub (local key `{nil, node()}`, remote `{node_param, remote_node}`) via `LiveHooks.NodeAware.on_mount`; every applied fetch writes the hub (`{[], []}` IS a valid snapshot).
  EVERY page suite in this subtree clears the hub per test in setup — `invalidate(nil, node())` (local context only) in the `async: true` modules, whole-table `reset()` in the `async: false` ones. Reason: suites that insert sidebar-visible rows leave them in the shared store, and per-test Store/TaskRegistry isolation does NOT clear the hub.
  Contract: any NEW suite that mounts whole pages through `Layouts.app` must reset the hub in setup.
- **Push_patch from a self-message needs a render flush**: `{:node_selected, _}` → `push_patch` is asynchronous, so insert ONE `render(view)` between the triggering click and `assert_patch`.
- **Store-offloaded reads must be drained before the isolated Store stops**: a read still in flight when the per-test `IsolatedTaskStore` stops the Store hits a vanished ETS table and prints an `[error]` crash report in the between-test gap.
  `tasks_live_test.exs` therefore calls `flush_tasks_load(view)` as the LAST statement of every test that mounts `~p"/tasks"`; mirror this in any new `/tasks`-mounting test. `IsolatedTaskStore` shuts down in ORDER (registry first, bounded read-worker drain, then the Store).
- **Tear-down safety nets on the isolated `EvoGit.TaskRegistry` must catch `:noproc`**: the isolated registry is linked to the test process, so it can die between a `Process.whereis/1` check and `:sys.resume/1`'s own name lookup (TOCTOU) — `tasks_live_test.exs`'s safety-net `on_exit` wraps the resume in `try/catch :exit, _ -> :ok` (teardown-only, never around an assertion).

## Notes for Agents — async policy (live-page deltas)

ExUnit runs ALL `async: true` modules first, then `async: false` modules one at a time — so a flip is unsafe only when another `async: true` module touches the same global state; the census, the forcing globals and the remaining production levers live in `apps/evo_dash/test/CONTEXT.md`.
Live-page deltas:

- **The page suites are split by module, not by file** — `agents_live_test.exs` and `settings_live_agents_test.exs` are fully async; `review_live_test.exs` is 6 async + 3 sync; `projects_live_test`, `settings_live_test`, `system_live_test`, `welcome_live_test` and `welcome_complete_live_test` each pair one async page module with a trailing sync module; `tasks_live_test`, `home_live_test` and `processes_live_test` remain one sync module each.
  The pure support-module units are all `async: true`.
- **Sync reasons are process-global resources with no per-test seam**: the `EvoGit.Store`/`EvoGit.TaskRegistry` singleton (isolation or fixture rows), `EvoGit.AgentScheduler` state (`pause`/`resume`, `update_config`), app-owned ETS `:evogit_sched_meta` / `:evogit_agent_summary`, the `EvoDash.ActiveTasks` / `EvoDash.UpdateStatus` / `EvoDash.ChatHistory` hubs, shared app-env seams (`:platform_os_override`, `:directory_picker`, `:remote_path_expand_runner`), the `"tasks"` and `"processes"` PubSub topics, and the process-global `EvoGit.VCT` mount table.
- **A module that CLICKS a task-mutating action is a publisher** and must stay sync (the `"tasks"` broadcast arms every mounted page's reload debounce).
- **The notification scan is store-global**: `EvoDashWeb.ProjectsLive.Notifications` diffs terminal ids read from the RUN-WIDE `EvoGit.Store` against the view's mount seed, so a zero-timeout `refute_push_event(view, "task_notification", %{}, 0)` is a GLOBAL-quiet claim and MUST live in the sync module; content-pinned positive `assert_push_event`s stay async.
- **Project mounts are global too**: opening a project calls `EvoDash.NodeContext.mount_project/3` → `EvoGit.VCT`, whose one mount table is shared by every suite, so a suite that mounts projects must clean up with `EvoGit.VCT.forget/1`.
- **Per-process config isolation is NOT itself a sync reason**: `EvoGit.Platform.config_dir/1` resolves through the `:config_dir_fun` seam per process (own dictionary, then the `$callers` chain), so a config-writing test isolates with `EvoDash.Test.ConfigDir.isolate!/1` and stays async.
  The mounted-only config-dir proof runs sync because async Projects tests own the global `:projects_async_load_runner`.
- **`agents_live_test.exs` is `async: true`**: it seeds the global `:evogit_sched_meta` / `:evogit_agent_summary` rows under a UNIQUE per-test agent id (`System.unique_integer([:positive]) + 10_000_000`, via `agent_id/0` reading the process dictionary), so no two concurrent modules collide.
- **`agents_live_test.exs` fixed waits (by design, seam-less)**: THREE `Process.sleep(250)` sites, each followed by `flush_agent_events(view)` to keep a real core write's THROTTLED `{:agents_updated, node}` bulk signal (core `@throttle_ms` ≈ 200 ms) on THIS socket; plus one sampled negative poll with a 40 ms deadline (4× the 10 ms debounce seam) asserting `tasks_reload_pending` never becomes true. The duplicated page load is freed with a shared `:atomics` release latch (`await_latch/2`, 5 s non-raising fallback).

## Notes for Agents — running these suites

Use `mix test apps/evo_dash/test` (or an explicit file path).
The directory form `mix test apps/evo_dash` silently produces NO output and runs nothing in this repo.
App-wide/umbrella runs are ORDER- AND TIMING-SENSITIVE by design: the `async: false` suites here repeatedly terminate/restart the GLOBAL `EvoGit.Store`/`EvoGit.TaskRegistry`, and a leaked shared-hub snapshot can break an unrelated later mount. An occasional single failure in a DIFFERENT suite is therefore not necessarily caused by the file under test — re-run the failing file standalone (and with a couple of seeds) before suspecting a regression.
