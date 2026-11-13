# Core Test Support

## Intent
Reusable ExUnit fixture modules for the core runtime live here, including directly started agent sessions, isolated persistence stacks, configuration isolation and local protocol servers.

## API Surface
`EvoGit.Agent.StreamCase` is a CaseTemplate whose setup returns `%{agent_id: id, tmp_dir: dir}` after registering unique production-shaped scheduler rows and arranging row/directory cleanup.
`StreamCase.register_agent/3`, `unregister_agent/2`, `dispatch_ctx/3` and `start_session/1` are public fixture functions, and `start_session/1` returns `{:ok, pid, monitor_ref}` for an unlinked directly started `EvoGit.Agent.Session` killed on test exit.
`dispatch_ctx(agent_id, tmp_dir, exchange_opts \\ [])` builds a repo-less dispatch keyword list, extracts `:agent_module` and `:repo_less_opts`, forwards every remaining option as `:exchange_opts`, and sends session notifications to the calling test through `notify: self()` and `scheduler: self()`.
`InteractiveAgent` yields tool-free replies and `OneshotAgent` completes them, and both expose no tools.
`yielding_llm_call/1`, `scripted_llm_call/1`, `driver_llm_call/1` and `response/2` provide scripted LLM replies and stream-event emission rather than a real HTTP exchange.
`driver_llm_call(test_pid)` reports `{:llm_call, worker_pid, context}` on each attempt and waits for `{:reply, text}`, `{:emit, events, text}` or `{:emit_waves, waves, text}`; wave boundaries wait for `:next_wave` but auto-advance after 5 seconds, so that mode is not an indefinite chunk gate.
`await_phase/3` polls `Session.inspect(pid, 200)` every 5 ms with a default 2-second deadline, `await_yield/3` defaults to 2 seconds, `await_terminal/3` defaults to 5 seconds and returns `:no_terminal_result` on timeout, and `collect_deltas/3` defaults to a 2-second first-event window plus a 250-ms quiet tail.
`EvoGit.TestLlmServer.start!(status, body)` returns `%{port: port, url: url, counters: counter}` for an ephemeral loopback fixed-JSON HTTP server, and `request_count/1` counts served requests.
`EvoGit.TaskRegistryCase` creates isolated Store/VCT/TaskRegistry processes and exposes `%{data_dir: root, sqlite_path: path, store: name, vct: name, registry: name}` plus `store/0`.
`EvoGit.VCTTest.Helpers.start_stack/2` creates isolated Store/VCT/PubSub processes and returns their names, pid and directories.
`EvoGit.TestSupport.ConfigDir.resolve/0`, `activate/1`, `isolate_module!/1` and `isolate!/1` implement per-process configuration-directory overrides when the surrounding suite installs the resolver seam.

## Constraints and Gotchas
StreamCase is not a complete real-LLM or scheduler-admission fixture: its private `agent_state/2` hardcodes `llm_model: nil`, `model_id: "stream-case-test"` and generation parameters containing only temperature and a cache key.
`register_agent/3` accepts role/cache-key/mode options but does not consume model, endpoint, generation-parameter or slot-pool overrides.
Omitting `:llm_call` is syntactically accepted by `dispatch_ctx/3`, but the helper supplies neither a selected endpoint model nor scheduler slot configuration, so a real-request test must arrange those independently and verify production worker/LLMPrompting behavior outside this directory.
`agent_state/2` and `sched_meta/3` are private and cannot be imported by dashboard suites, whereas the direct-session public functions can be reused once this support module is loaded.
The support files do not install their own cross-app compilation or loading path, so dashboard helper visibility must be checked in the owning applications' Mix/test configuration.
TestLlmServer serves one fixed status/body with `application/json` and closes each connection; it has no successful SSE stream, request-body capture, routing or per-request response script API.
StreamCase uses per-agent global ETS rows and the app-global PubSub and ControlPlane rather than starting isolated scheduler infrastructure.
StreamCase supplies synthetic `task_id: "task-<agent_id>"` metadata but creates no TaskRegistry task row; mounted Assistant tests that resolve a conversation through persisted task state must arrange that state separately.
`start_session/1` exit cleanup sends an untrappable kill to a surviving session without waiting for its monitor, while `unregister_agent/2` drains the inbox, deletes only the fixture summary/meta/cancel state and tolerantly removes its directory.
Only `:agent_module` and `:repo_less_opts` are extracted by `dispatch_ctx/3`; every other supplied option, including a putative `:session_mode`, goes inside `:exchange_opts`, not the top-level dispatch context.
StreamCase temporary directory names include a per-BEAM unique agent id but not an OS pid, so separate concurrent test BEAMs can produce colliding paths.
`await_yield/3` falls back to observing `:awaiting_input`, which does not itself prove that the requested reply text was emitted.
ConfigDir overrides do not reach app-booted singleton processes, and `setup_all` activation is not inherited by each test process.

## Routing Table
There are no child subdirectories.
