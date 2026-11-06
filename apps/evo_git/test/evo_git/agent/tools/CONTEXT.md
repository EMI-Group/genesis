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
| `reflect_tools_test.exs` | the self-reflective task-control command handlers |
| `spawn_investigator_probe_test.exs` | `Tools.SpawnInvestigatorProbe.investigate/2` |

## Async-Safety Rationale

Every module carries an `@moduledoc` naming why it is `async: true` / `async: false` — keep it accurate when the forcing state changes.

- `async: false` — `web_search_test.exs` (mutates the `:web_search_http_runner` app-env seam and the shared `:req_llm` API-key store).
- `async: false` — `web_fetch_test.exs` (mutates the app-env `:web_fetch_allow_private_hosts` key AND runs against one fixed repo path, `/tmp/web-fetch-test-repo`; the FLIP BLOCKER is that fixed path — it needs a per-test `@moduletag :tmp_dir` dir before this module can ever be `async: true`).
- `async: false` — `reflect_tools_test.exs` (`without_model_profiles/1` rewrites the GLOBAL `EvoGit.AgentScheduler` `model_profiles` config via `AgentScheduler.update_config/1`, a BEAM-global read by every other agent/task module).
- `async: false` — `job_tools_test.exs` (every test starts its OWN isolated `EvoGit.BackgroundJobs` registry under a unique name, reached through the `:evogit_background_jobs_server` pdict seam with `:evogit_agent_pid` as the job owner, and spawns REAL detached OS children whose `genesis_job_*.log` output files land in the SHARED `EvoGit.Sandbox.resolve_tmpdir/0` scratch dir — an isolated GenServer, real host children and a shared scratch dir all rule out concurrent modules; per-job log cleanup deletes each record's own `:output_path` and never lists that shared dir).
- `async: true` — `web_fetch_lsp_registration_test.exs` and `commit_files_test.exs` (each isolates its config dir PER PROCESS through `EvoGit.TestSupport.ConfigDir`, so the `[lsp]` schema gate / repo template is pinned independent of the developer's real `~/.config/genesis/config.toml` without touching a process-wide env var).
- `async: true` — `lsp_test.exs` (nothing global: every execute-level test spawns its own fake language server escript in a UNIQUE temp dir and every `Lsp.execute/4,5` call passes `enabled:`/`command:` explicitly, the unconfigured cases included).
- `async: true` — every other file: pure helpers, per-test `:tmp_dir` fixtures, or process-local `Process.put` state only.

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
