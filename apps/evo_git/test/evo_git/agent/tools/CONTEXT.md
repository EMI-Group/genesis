# Test — Agent Tools

## Intent

ExUnit suites for the per-tool implementations dispatched through `EvoGit.Agent.Tools.execute/5` (one file per tool / subsystem).
Tests use real git repos and ExUnit `:tmp_dir` fixtures — no mocking libraries.

## Routing Table

- Parent: `../` → the agent test tree (Runner, context building, tool dispatch).

## Contents

| File | Module under test |
|------|-------------------|
| `shared_test.exs` | `EvoGit.Agent.Tools.Shared` (pure arg/path helpers) |
| `commit_files_test.exs` | `Tools.Shared.commit_files/4` (the shared stage+commit helper) |
| `file_read_test.exs` | `Tools` `"read_file"` (incl. its OUTPUT shape) |
| `file_edit_test.exs` | `Tools` `"edit_file"` (model-facing `edit`; owns the edit OUTPUT shape) |
| `glob_test.exs` | `Tools` `"glob"` |
| `ripgrep_test.exs` | `Tools` `"rg"` |
| `search_context_test.exs` | `Tools` `"search_context"` |
| `search_history_test.exs` | `Tools` `"search_history"` |
| `make_dir_test.exs` | `EvoGit.Agent.Tools.MakeDir` (owns the make_dir OUTPUT shape) |
| `skill_tools_worktree_test.exs` | the 8 skill tools (`SkillAdd`/`SkillEdit`/`SkillRemove`/`SkillList`/`SkillRead`/`SkillWhere`/`SkillEnable`/`SkillDisable`) — worktree (`repo_path`) read/write routing + self-committing writes via `Shared.maybe_commit_result/6` |
| `shell_tool_test.exs` | `EvoGit.Agent.Tools.ShellTool` |
| `job_tools_test.exs` | the background-job tools (`JobOutput`/`JobList`/`JobKill`) + `ShellTool`'s `run_in_background` mode + the classification/guards that mode depends on (`Tools.write_call?/2`, `Tools.background_start?/1`, `Tools.serial_tool?/1`) |
| `web_search_test.exs` | `EvoGit.Agent.Tools.WebSearch` + `WebSearchProviders` |
| `web_fetch_test.exs` | `EvoGit.Agent.Tools.WebFetch` (end-to-end against an in-test HTTP/1.1 server on `127.0.0.1`) |
| `html_to_markdown_test.exs` | `EvoGit.Agent.Tools.HtmlToMarkdown` |
| `lsp_test.exs` | `EvoGit.Agent.Tools.Lsp` (config-gated `lsp` tool, driven with per-call `opts` overrides against the fake language server) |
| `web_fetch_lsp_registration_test.exs` | the schema-registration / dispatch contract for `web_fetch` and `lsp` |
| `reflect_tools_test.exs` | Direct self-reflective task-control handlers, repo-less file-read/write guards and three unconditional legacy `run_command` refusals |
| `spawn_investigator_probe_test.exs` | `Tools.SpawnInvestigatorProbe.investigate/2` |
| `elixir_eval_engine_test.exs` | Real-Dune `ElixirEval.Engine` integration/security, genuine live authority, tier separation, fresh bindings, bounded UTF-8 output and inspection |
| `elixir_eval_fixture.ex` | Explicitly required `EvoGit.TestSupport.ElixirEvalFixture`, providing genuine owner/tool Tasks and isolated running reflect authority without an LLM |
| `elixir_eval_authorization_test.exs` | Genuine and forged owner/spec/task/state identities, immutable revalidation, registry failure, bounded ancestry and fixture cleanup |
| `elixir_eval_worker_tree_test.exs` + `elixir_eval_engine_cleanup_test.exs` | Root/child/grandchild custody on success/error/timeout and abrupt guardian/owner/tool loss, including real-Dune helper cleanup |
| `elixir_eval_projection_test.exs` + `elixir_eval_validation_test.exs` | Privacy projections, literal read/start/guide validation and exact caps |
| `elixir_eval_render_test.exs` | UTF-8 byte-bounded text/term rendering and native BoundedIO protocol, cap and lifecycle |
| `elixir_eval_wrapper_test.exs` | Actual public wrapper exact-code read/write/sudo approval, no-effect denial/timeout, lifecycle revalidation and argument validation |

## Async-Safety Rationale

Every module carries an `@moduledoc` naming why it is `async: true` / `async: false` — keep it accurate when the forcing state changes.

- `async: false` — `web_search_test.exs` (mutates the `:web_search_http_runner` app-env seam and the shared `:req_llm` API-key store).
- `async: false` — `web_fetch_test.exs` (mutates the app-env `:web_fetch_allow_private_hosts` key AND runs against one fixed repo path, `/tmp/web-fetch-test-repo`; the FLIP BLOCKER is that fixed path — it needs a per-test `@moduletag :tmp_dir` dir before this module can ever be `async: true`).
- `async: false` — `reflect_tools_test.exs` (`without_model_profiles/1` rewrites the GLOBAL `EvoGit.AgentScheduler` `model_profiles` config via `AgentScheduler.update_config/1`, a BEAM-global read by every other agent/task module).
- `async: false` — `job_tools_test.exs` (every test starts its OWN isolated `EvoGit.BackgroundJobs` registry under a unique name, reached through the `:evogit_background_jobs_server` pdict seam with `:evogit_agent_pid` as the job owner, and spawns REAL detached OS children whose `genesis_job_*.log` output files land in the SHARED `EvoGit.Sandbox.resolve_tmpdir/0` scratch dir — an isolated GenServer, real host children and a shared scratch dir all rule out concurrent modules; per-job log cleanup deletes each record's own `:output_path` and never lists that shared dir).
- `async: true` — `web_fetch_lsp_registration_test.exs` and `commit_files_test.exs` (each isolates its config dir PER PROCESS through `EvoGit.TestSupport.ConfigDir`, so the `[lsp]` schema gate / repo template is pinned independent of the developer's real `~/.config/genesis/config.toml` without touching a process-wide env var).
- `async: true` — `lsp_test.exs` (nothing global: every execute-level test spawns its own fake language server escript in a UNIQUE temp dir and every `Lsp.execute/4,5` call passes `enabled:`/`command:` explicitly, the unconfigured cases included).
- `async: false` — `elixir_eval_wrapper_test.exs` uses the app-global `EvoGit.CommandApproval` service and mutates its shared `:command_approval_timeout` app-env key, with id-pinned approval matching and restored settings.
- `async: true` — every other file: pure helpers, per-test `:tmp_dir` fixtures, process-local state, or uniquely keyed evaluator ETS authority rows backed by isolated Store/TaskRegistry instances.

## Reflect / Command Dispatch Coverage and Gaps

`reflect_tools_test.exs` calls the ten control handlers directly through `execute/3`; its only `run_command` dispatch cases are `ListRecentProjects.list_recent_projects`, `SystemInfo.system_info`, and `ListTasks.list_tasks`, all under the process-local `:repo_less` flag.
These dispatch cases pin the `%{"command" => <legacy command string>}` argument and unconditional `Error: use elixir_eval exact-code approval path` refusal, even with a forged repo-less flag.
The direct legacy handler tests remain distinct compatibility coverage and do not prove authorization of the new evaluator facades.
The repo-less guard cases pin blocked `write_file` / `edit_file` / `skill_add`, JSON-string write arguments, a permitted file read, and restoration of writes after deleting `:repo_less`.
The suite has no `RunCommand` schema tests, direct `CommandShell` calls, restricted-evaluation allowlist tests, sudo/approval interactions, evaluator context/binding isolation, evaluator cancellation/timeout cleanup, or audit assertions.
Control-handler cancellation coverage is only a pending task becoming `:cancelled`; the force-kill case asserts the seeded running task becomes `:failed`, but does not assert the wrapper pid has died.
`StartTask` coverage enqueues a real reflect task with global scheduler profiles temporarily emptied and waits for an id-pinned terminal PubSub event inside that profile override before restoring profiles.
That test asserts a nonempty returned task id and persisted `type: :reflect`, but not terminal outcome, evaluated code, returned result, or runtime context propagation.
Current test seams are `EvoGit.TaskRegistryCase`'s isolated Store/TaskRegistry and `store()` / `TaskRegistry.server()`, direct Store task seeding, temporary unregister/re-register of the isolated registry name for unavailable-system errors, `:sys.replace_state` of the isolated registry's `task_refs` with a live wrapper, and process-local `:repo_less`.
There is no config-dir isolation helper in `reflect_tools_test.exs`; its SystemInfo case compares the reported data directory with the live `EvoGit.Platform.data_dir/0`.
`spawn_investigator_probe_test.exs` tests the deterministic read-only filesystem report over unique temp git fixtures, including nested CONTEXT.md excerpts and malformed/nonexistent inputs, not assistant evaluation-context isolation or permission enforcement.
Sibling parser/approval suites route to `test/evo_git/{command_shell,command_approval}_test.exs`, the runtime suite routes to `test/evo_git/runtime/`, and production command-handler/evaluator architecture routes to `lib/evo_git/agent/tools/` and the core runtime's CONTEXT.md.

## Evaluator Test Ownership and Fixture Constraints
`elixir_eval_engine_test.exs` uses the genuine fixture and real Dune for Engine-only contracts: fully qualified Read discovery through interpreted callbacks, captured-registry projections, read/write/native separation, restricted runtime APIs, generic exception handling, fresh bindings and cumulative UTF-8 byte/output/inspection bounds.
Its direct write/sudo calls model an already-approved tier and are explicitly not evidence that the public wrapper enforces manual approval.
The nested Read discovery case intentionally performs no facade/allowlist warm-up and exposes a cold-BEAM alias-resolution failure: running it alone returns the generic runtime error instead of the expected system-info projection, while an earlier evaluation can hide the failure.
The production contract is documented at `apps/evo_git/lib/evo_git/agent/tools/elixir_eval/CONTEXT.md`.
Keep pure projection/validation/render/ancestry tests separate from real-Dune engine, authorization/broker, process-cleanup and public-wrapper approval integration suites.
A valid evaluator fixture needs production-shaped AgentState/SchedMeta rows with unique integer ids, an isolated running reflect task, a live SelfReflective owner Task/spec and an actual descendant tool process; `Process.put(:repo_less, true)` alone must never authorize it.
Fixture cleanup stops its private supervisor directly and tolerates only the expected `:noproc`/`:normal` GenServer-stop exit races before removing its own records.
Authorization tests cover repeated cleanup of live descendants and cleanup after asynchronous private-supervisor death, including another cleanup from `on_exit`.
Capture the isolated registry identity explicitly when entering independently spawned processes, because TaskRegistryCase's test-process dictionary is not inherited by raw spawn or ExUnit on_exit.
The tool process must set `:evogit_agent_id`, `:evogit_task_id`, `:evogit_agent_pid` and `:evogit_task_registry_server`; Authorization captures that registry and the original tool pid at entry.
SchedMeta must carry the actual live owner `%Task{}` in `task_ref`, status running or blocked, depth zero, nil parent, result_sent false and a SelfReflective AgentSpec with matching task_id and repo_less true.
A held owner Task that starts a descendant tool Task supplies genuine runtime-maintained ancestry without running an LLM; install its unique ETS rows and isolated running reflect task before releasing the descendant to authorize.
Exact-code approval broadcasts normalize integer agent ids to strings and preserve code bytes in both args and code, so responder matching must compare the normalized id plus task id, tier and exact code.
Real-Dune tests must exercise fully qualified facade names through Dune's own nested helper ancestry, rather than mocking authorization or relying on interpreted alias declarations.
Public-wrapper write and sudo tests must drive exact-code `CommandApproval.request_eval/5`; direct Engine execution is not evidence that approval is enforced.
Use id-pinned approval responders and monitored, handshake-held descendants for lifecycle assertions, never unconditional approvers, artificial CPU-load generators or quiet-window timing races.
Prefer async modules for pure/local fixtures; modules changing scheduler profiles, the global approval service or shared timeout settings must explicitly name that forcing global and remain synchronous.
`elixir_eval_wrapper_test.exs` exercises actual `ElixirEval.execute/3` in descendant tools: reads open no approval, write and sudo preserve exact code and carry distinct level/warning metadata, denial/timeout leave effects absent, and held approvals revalidate original task/state/spec/owner/tool authority.
`elixir_eval_authorization_test.exs` and the wrapper suite retain a refusal regression for mismatched embedded `SchedMeta.id`; production currently accepts any integer there instead of binding it to the captured ETS lookup id.
Dependency installation belongs to the parent app; tests require genuine Dune 0.3.18 or compatible and do not stub its parser, allowlists or execution.
Directory-targeted Mix runs may warn about the explicitly required non-test fixture filename; app-level test-ignore configuration is outside this node.
Parent-owned ToolDispatch tests should establish identity handoff, serial evaluator batches and approval-aware outer timeout rather than duplicating those concerns here.
## Notes for Agents

- `reflect_tools_test.exs` spawns a live `Process.sleep(:infinity)` "wrapper" process on purpose — it is NOT a wait to reduce.
- `web_fetch_lsp_registration_test.exs` pins the tool-offering contract: `web_fetch` is always in `Tools.schemas/0` and `Tools.read_only_schemas/0`, while `lsp` is appended to both only when `EvoGit.Config.lsp_enabled?/0` is true (`[lsp] enabled = true` plus a non-empty `command`), so a stock config offers `lsp` to no agent.
  Its dispatch assertions are deliberately ungated: `Tools.execute/5` still routes `lsp` into `EvoGit.Agent.Tools.Lsp` on an unconfigured server (the tool answers with its own `Error:`), which is how the routing coverage survives the schema gate.
- `EvoGit.Agent.Completion` (the completion side-effect writer: git note, archive refs + `task_agent_archives` row) lives at `lib/evo_git/agent/completion.ex` and is tested by the parent node's `../completion_test.exs` (`EvoGit.Agent.CompletionTest`).
- `skill_tools_worktree_test.exs` builds a real repo + LINKED WORKTREE per test (`git worktree add`) and drives the skill tools' `execute/N` directly; the worktree must live OUTSIDE `repo_root` (both under `System.tmp_dir!()`) because the sandbox grants write access to the command `cwd` (= `repo_path`) plus `<repo_root>/.git` (where a linked worktree's gitdir lives). Skill-file commits therefore only work when the tool is handed the WORKTREE as `repo_path` and the MAIN repo as `repo_root`.
- `skill_tools_worktree_test.exs` exercises BOTH `SkillWhere.execute/3` branches: the non-empty one (renders `Skill '<name>' is enabled at the following nodes:` + one `  - <node>` line per node) and the empty one (`Skill '<name>' is not enabled at any node.`).
- `skill_tools_worktree_test.exs` also pins `SkillRemove` staging a CASE-DIFFERING filename (the `name` argument differs only in case from the on-disk file, e.g. remove `"deploy"` for `Deploy.md`) — resolution goes through `EvoGit.Skills.CRUD.find_skill_file/2` (exact-then-case-insensitive), so the commit carries the real filename's deletion.
- `EvoGit.Skills.where_enabled/2` renders a ROOT-level enablement as `"./."` (`Path.relative_to(base, base) == "."`), pinned by `test/evo_git/skills_hierarchical_test.exs`.
- `job_tools_test.exs` is a CHARACTERISATION suite, not a design: it pins the shipped `job_output`/`job_list`/`job_kill` schemas and result strings (including the `[status: …]` line and the `Error: …` failure shape, plus every `max_bytes`/`timeout_ms`/`wait: true` arm), the shell tool's `run_in_background` contract (`started background job bash-<16 hex>`, the first-line label, "no timeout applies", the main-copy mutation hard block), and the guard surface the mode depends on — `Tools.schemas/0` / `Tools.read_only_schemas/0` membership, `write_call?/2`, `background_start?/1`, `serial_tool?/1`, and the repo-less guard blocking a background start while leaving the `job_*` tools callable.
- `lsp_test.exs` is 20 tests: 8 execute-level tests over the distinct fixture modes (default, `clean`, `crash`, `silent`, `malformed`) plus the schema/config/validation describes.
  The fixture is the compiled support module `EvoGit.FakeLspServer` (`test/support/fake_lsp_server.ex`), packed into ONE throwaway `escript` per module by `setup_all` (`:escript.create/2` on the beam from `:code.which/1`, temp dir removed `on_exit`), and every execute-level test execs that escript as a real OS child — ~120 ms of boot per spawn instead of ~300 ms for `elixir <script>.exs`.
  Because an escript boots a bare Erlang node, the fixture takes the Elixir `ebin` as its first argument and calls `:code.add_patha/1` before any Elixir function, and its stdio setup keeps `encoding: :latin1, binary: true` (a bare node returns charlists otherwise).
  The process-hygiene `pgrep -f <escript path>` assertion lives INSIDE the handshake test ("runs the full handshake, renders one line per diagnostic, and reaps the server") — a separate fixture spawn would only duplicate that call.
  The "server never answers initialize" case uses a 400 ms budget, which the asserted message interpolates (`… within 400 ms`).
- `job_tools_test.exs` is 44 tests. Its `describe "JobOutput.execute/3 — wait budget and marker"` block owns the wait-budget/marker contract: an explicit `timeout_ms`, the generic `timeout` spelling, the accepted value shapes (`300.0`, `"300"`, `"300ms"`, `timeoutMs: 300`), the default budget with its hint, a present-but-unusable value, the early-return completion marker, the cancel-abort marker, the marker-less non-wait read, a unit-string budget clamped to the derived cap, a full-budget wait surviving the dispatch ceiling, and the pure `next_poll_delay/2` backoff curve (growth from the base, the 3 000 ms cap, a 0 base floored to 1).
  The live-job kill test also covers the caller-supplied-reason case, so one test pins all three: the default reason, the repeat-kill "had already finished" message, and the custom reason landing on the job's detail.
  Its `JobList` ordering test uses two SHORT-LIVED jobs awaited to completion (no kill, so no kill grace), and the `wait: true` timeout case passes `timeout_ms: 30` — several poll cycles of the call-time `:background_poll_interval_ms` seam, which the suite sets to 5 ms against a production default of 100 ms — while still asserting the job is `:running`.
  The suite's own `wait_until/2` polls at a 1 ms floor and relaxes from there (30 µs registry read per poll, so the awaited condition is the only real cost).
  Every kill runs with the call-time `:kill_grace_ms` seam at 0 ms (production default 100 ms); the post-kill assertion is a poll for a genuinely-dead pid, so the shorter grace cannot mask a live child.
  Job-log hygiene registers `on_exit` cleanup for each job record's own `:output_path` at START time, so a test that flunks before its own final assertions still removes its file.
- A `wait: true` `job_output` call legitimately blocks INSIDE the tool up to `EvoGit.BackgroundJobs.wait_max_ms/0` (the configured `[:scheduler, :max_tool_timeout]` minus the dispatcher headroom, i.e. 1_775_000 ms by default), so the dispatcher's `Tools.default_timeout_ms("job_output")` is DERIVED at call time as `BackgroundJobs.wait_max_ms() + BackgroundJobs.dispatch_headroom_ms()` (= 1_800_000 ms by default) and the suite's `@job_output_default_timeout_ms` mirrors that expression — it is a CEILING for the real block, NOT a latency race.
- No test ever waits out that ceiling: every wait pins a SMALL budget (300/350 ms) through the call-time seams `Application.get_env(:evo_git, :background_wait_default_ms, 120_000)` (the default budget) and `:background_poll_interval_ms` (5 ms, the BASE of the poll backoff), and proves WHICH budget was used from `elapsed >= budget - 50` plus `elapsed < 5_000`; `:background_wait_max_ms` is set to 60_000 / 8_000 where a test needs a small cap.
- What the suite pins is the ONE marker line after the byte-identical `[status: …]` line: `[wait: finished after <n> ms, status: <status>]` when the job finished during the wait, `[wait: aborted after <n> ms — cancellation requested, status: <status>]` when the owning agent's graceful-cancel flag aborts it, `[wait: <budget> ms budget expired, status: <status>]` for an EXPLICIT budget, and the same line plus `; pass timeout_ms (or timeout) to wait up to <cap> ms ("<human>")` for the DEFAULT budget — `<human>` pinned in all three arms: `<n>m<n>s` for the default 1 775 000 ms cap (`"29m35s"`), `<n>m` for a whole 60 000 ms cap (`"1m"`) and `<n>s` for an 8 000 ms cap (`"8s"`) — while `wait: false` and every `Error: …` reply render no marker at all.
- `shell_tool_test.exs` pins the generated `bash` description's background paragraph: a `run_in_background: true` start "has NO timeout", and a job expected to take a while gets ONE long `job_output` wait (`timeout: "30m"`, up to the ~30 min cap) instead of re-polling with short budgets.
- The `JobOutput cancel probe totality` block pins that probe as TOTAL — an absent/unusable agent id, an absent `:evogit_agent_state` table and another agent's flag all read as "not cancelled" — plus a wait with no agent id running its budget instead of raising; the cancel flag is installed by writing `%{cancel_requested: …}` straight into the app-owned ETS table, mirroring what `TaskRegistry.cancel_task/1` leaves behind.
- The honoured budget spellings (`timeout_ms`, then `timeout`, then `timeoutMs`) and their coercion (integer/float/numeric string with an optional `ms`/`s`/`m` unit) live in `Shared.fetch_duration_ms/2` / `Shared.get_duration_ms/3` and are unit-tested in `shared_test.exs`; neither helper clamps, so clamping to `[0, wait_max_ms()]` is the tool's job.
- `shared_test.exs` pins that shared reader directly (its `fetch_duration_ms/2` + `get_duration_ms/3` describes): key ORDER, a present-but-unusable key falling through to a later one, float truncation, unit suffixes, `""`/`"1h30m"`/non-scalar values as unusable, non-map args as `:error`, the `default` fallback, and the absence of clamping.
- The job tools' extra accepted spellings (`bash_output`/`background_output`/`job_status`, `jobs`/`background_jobs`, `kill_job`/`job_stop`/`stop_job`) are pinned by the `describe "background job aliases"` block in `../tool_names_test.exs` (pure `EvoGit.Agent.ToolNames.normalize/1`, so that module stays `async: true`).
