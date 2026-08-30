# Test Directory

## Intent
ExUnit test suite for the `:evo_git` OTP application. Validates core domain logic, git adapter operations, agent tooling, and context node handling using real git operations on temporary filesystem sandboxes — no mocks. Test module names mirror the source module path under test. Full inventory: 118 `*_test.exs` files under this directory (incl. `evo_git_test.exs` and `mix/tasks/*`).

## Routing Table
- `evo_git/` → Test files mirroring source structure (full inventory in API Surface)
- `evo_git/skills/` → Skills subsystem tests (executor injection safety + sandbox routing) — own CONTEXT.md
- `evo_git/task_registry/` → TaskRegistry/Store lifecycle tests (persistence, lease/heartbeat, cleanup, skip-and-log, merge/resume/runtime-opts builders, `:reflect` executor, diagnostics) — own CONTEXT.md
- `support/` → Shared test helpers (`EvoGit.FakeGh`, `EvoGit.TestSupport.Submodule`, `EvoGit.TaskRegistryCase`)

## API Surface

### Top-level files
- **`test_helper.exs`** — Minimal bootstrap: calls `ExUnit.start()`.
- **`evo_git_test.exs`** — `EvoGitTest`: `EvoGit.sandbox_args/4` and `sandbox_run/4` (direct exec in test env). Lib `sandbox_args` arities: 2/3/4.
- **`mix/tasks/bump_version_test.exs`** — `Mix.Tasks.Bump.VersionTest` (`async: false`): `mix bump.version` bumps `VERSION`/desktop manifests, commits exactly the touched files when confirmed, no-op when current, warns (no crash) when commit fails, changelog generation on confirm.
- **`mix/tasks/changelog_test.exs`** — `Mix.Tasks.ChangelogTest` (`async: false`, stubbed summarizer/aggregator via the `:changelog_summarizer`/`:changelog_pr_summarizer`/`:changelog_aggregator` app-env seams): creates/replaces CHANGELOG.md sections, defaults range to last tag, merge→one-PR stage-1 grouping, version-bump/mechanical-commit exclusion.

### `support/`
- **`fake_gh.ex`** — `EvoGit.FakeGh`: puts a fake `gh` POSIX script on PATH — canned issue JSON, `GH_FAKE_MODE` `fail`/`badjson`, argv logged one-per-line to `GH_FAKE_LOG`. API: `with_fake_gh/1`, `read_argv_log/1`. Only usable from `async: false` modules (PATH is BEAM-global), POSIX-gated.
- **`submodule_helper.ex`** — module is **`EvoGit.TestSupport.Submodule`** (name differs from filename — grepping `SubmoduleHelper` finds nothing): creates gitlink/submodule entries WITHOUT cloning; verifies gitlinks are excluded from CoW file lists and arrive as empty placeholder dirs.
- **`task_registry_case.ex`** — `EvoGit.TaskRegistryCase` (82 lines): isolated TaskRegistry + Store on a fresh temp SQLite DB per test (terminate-child + start_supervised pattern); helpers `trigger_cleanup!/0`, `cleanup_process/1`, `old_age_days/0`/`within_age_days/0`. Used by 8 files (reflect_tools, store_disk_full, task_registry/{cleanup,lease_heartbeat,merge_context,persistence,store_skip_and_log,task_executor_reflect}).

### `evo_git/core/`
- **`context_node_test.exs`** — `EvoGit.Core.ContextNodeTest`: `normalize_relpath/1`, `load/2` (hierarchy traversal, `.gitignore` handling, absolute-path errors).
- **`phylo_graph_node_test.exs`** — `EvoGit.Core.PhyloGraphNodeTest`: `new/0`, `crossover/2`, `add_and_commit/3` via real git repos (find_merge_base, merge clean/conflict, list_immediate_children).
- **`foreign_repo_test.exs`** — `EvoGit.Core.ForeignRepoTest` (41 tests): `new/3`, `normalize/1` (struct/atom-keyed/string-keyed maps, root/path fallback), `primary_id/0`, `primary?/1`, `absolute_path?/1`, `normalize_path/2`, `resolve_path/2`.

### `evo_git/adapters/`
- **`cow_worktree_test.exs`** — `EvoGit.Adapters.CowWorktreeTest` (`async: false` — the `:persistent_term` `:evogit_cow_worktree_enabled` is global): CoW worktree creation via `Git.ls_tree_names/2`/`Git.diff_name_only/3`, `flag/0,enable/0,disable/0`, `create_worktree/5` (dirty-file, nested-dir, fallback, git-validity cases), failed-add leftover cleanup (`{:fallback, :worktree_add_failed}` deletes the free branch + leftover dir; a live registered worktree at the target path is kept).
- **`git_test.exs`** — `EvoGit.Adapters.GitTest` (uses `EvoGit.TestSupport.Submodule`): full integration on real git repos — `get_note/3`, `update_ref/3`/`delete_ref/2`, GIT_EDITOR config, clone/fetch/merge_ff_only/rev_parse_short/remote_url, `ls_tree_gitlinks/2`, `add_worktree/4` with gitlink submodules, **leftover-dir removal + failed-add free-branch cleanup + registered-worktree preservation, `remove_leftover_worktree_dir/1` semantics**. Error shapes follow the uniform `{:ok, value} | {:error, {tag, output}}` adapter contract (e.g. `show_note` conflict → `{:error, {:conflict, _}}`, `get_note` invalid JSON → `{:error, {:invalid_json, _}}`).
- **`github_test.exs`** — `EvoGit.Adapters.GitHubTest` (`async: false`, `EvoGit.FakeGh`, POSIX-gated): gh-CLI contract — `github_upstream/1` origin parsing, `list_github_issues/2` JSON normalization + argv, `github_issue_markdown/2` exact markdown, RemoteAPI delegation.

### `evo_git/agent/`
- **`tools_test.exs`** — `EvoGit.Agent.ToolsTest` (58 tests): `Tools.schemas/0`; agent `available_tools/0` uniqueness; `execute/4` per tool (read/write/context tools).
- **`coder_test.exs`** / **`coder_2_test.exs`** — `EvoGit.Agent.CoderTest` / `CoderTest2` (inline `DummyAgent`): `build_dynamic_context/1` across CONTEXT.md setups; root node path, nil inputs, `ArgumentError` recovery.
- **`context_builder_test.exs`** — `EvoGit.Agent.ContextBuilderTest`: turn/timestamp tagging helpers + `build_repo_notes_section/1`.
- **`context_compression_test.exs`** — `EvoGit.Agent.ContextCompressionTest`: `compression_instruction/0`, `compress_if_needed/2` threshold gating, compression usage accumulation.
- **`delegation_hints_test.exs`** — `EvoGit.Agent.DelegationHintsTest` (90 tests, `HintAgent`): delegation-hint threshold config, child-dir detection, path normalization, `extract_child_paths/4`.
- **`output_sanitizer_test.exs`** — `EvoGit.Agent.OutputSanitizerTest` (37 tests): `strip_ansi/1`, `strip_progress_bars/1`, `truncate/3`, `sanitize_and_truncate/3`.
- **`result_test.exs`** — `EvoGit.Agent.ResultTest`: `Result.new/3`.
- **`subagent_processing_test.exs`** — `EvoGit.Agent.SubagentProcessingTest` (`DummyAgentModule`): `resolve_subagent_path/3`, `build_subagent_specs/3` model_id inheritance, `format_subagent_result/1`, `accumulate_subagent_usages/1`.
- **`tool_dispatch_test.exs`** — `EvoGit.Agent.ToolDispatchTest`: `ensure_tool_calls/2`, `process_tool_calls/3`, dedupe, `batch_execute_tools/4` parallel, repo-less `sync_current_commit_after_tools/1`.
- **`tool_dispatch_retry_slot_test.exs`** — `EvoGit.Agent.ToolDispatchRetrySlotTest`: per-attempt LLM slot acquisition in `call_llm_with_retry/5` — slot released between retries (during backoff), `AgentScheduler.pause/0` takes effect at next re-acquisition. (Known flaky under full-suite parallel load — see Known Issues.)
- **`truncation_feedback_test.exs`** — `EvoGit.Agent.TruncationFeedbackTest`: `is_rate_limit_error?/1`, `append_truncation_feedback/3`, `tool_truncation_suggestion/1`, `format_truncation_reason/1`.
- **`turn_limit_test.exs`** / **`turn_warning_test.exs`** — `EvoGit.Agent.TurnLimitTest` / `TurnWarningTest`: turn-limit recovery triggers + grace budget; positional/middle turn warnings + adaptive countdown.
- **`usage_test.exs`** — `EvoGit.Agent.UsageTest`: `Usage.zero/0`, `from_response_usage/1`, `add/2`, `cache_hit_rate/1`.
- **`cancel_grace_test.exs`** — `EvoGit.Agent.CancelGraceTest`: graceful-cancel machinery — 3-turn grace budget, `cancel_requested` flag → cancel-grace entry, recovery auto-commit on cancel-grace entry.

### `evo_git/agent/tools/`
- **`complete_task_test.exs`** — `EvoGit.Agent.Tools.CompleteTaskTest` (36 tests): schema, `check_workspace_dirty/1`, `format_git_status_porcelain/1`, `complete/5`, archive.
- **`file_read_test.exs`** / **`glob_test.exs`** / **`make_dir_test.exs`** / **`ripgrep_test.exs`** / **`search_context_test.exs`** / **`search_history_test.exs`** — per-tool `execute/3,4`: normal paths, malformed patterns, offset-beyond-EOF crash regression, double-encoded-array recovery, schemas.
- **`shared_test.exs`** — `EvoGit.Agent.Tools.SharedTest` (46 tests): `normalize_relpath/1`, `is_child_or_same_node?/2`, `validate_file_scope/3`, `fetch_array_arg/2`, optional-arg fetchers.
- **`shell_tool_test.exs`** — `EvoGit.Agent.Tools.ShellToolTest` (51 tests): `format_duration/1`, `detect_cd_warnings/3` (incl. relative-cd detection — `cd ../../../` reaching the root, `cd ../worker_T*` into another agent's worktree), `redundant_cd?/3`, `describe_exit_code/1`, execute result formatting, **main-copy mutation hard block** (a command that `cd`s into the repo ROOT and runs a mutating git subcommand — checkout/switch/reset/merge/pull — is blocked with a clear "MAIN working copy ... blocked" error and never executed; `cd .` / partway cds / non-mutating commands are NOT blocked).
- **`command_shell_test.exs`** — `EvoGit.CommandShellTest` (44 tests, `EvoGit.TaskRegistryCase`): the command-shell dispatcher behind the self-reflective agent's `run_command` tool — pure parser/validation/guardrail unit tests (positional + key=value + quoted tokens, unknown-key-as-positional, duplicate-key/extra-positional/missing-required errors, unknown command, empty command, command-length/token-count/token-length caps, non-string input, unterminated quote), help (`help`/`help <cmd>`/`list_commands/0`/`help/1`), security (eval/dynamic-dispatch-looking paths rejected, enum/bool validation listing valid values), and registry-backed dispatch for every command (`task.list`/`task.get`/`task.start reflect`/`task.cancel`/`task.force_kill`/`task.delete`/`guide.show`/`task.investigate`/`project.list`/`system.info`) asserting the same handler outputs the old per-tool tests asserted.
- **`reflect_tools_test.exs`** — `EvoGit.Agent.Tools.ReflectToolsTest` (32 tests, `EvoGit.TaskRegistryCase`): the 10 task-control command-handler modules (`ListTasks`/`GetTask`/`StartTask`/`CancelTask`/`ForceKillTask`/`DeleteTask`/`GuideUser`/`SpawnInvestigator`/`ListRecentProjects`/`SystemInfo`) invoked directly via `execute/3` + the repo-less write guard in `Tools.execute/5` (the old `list_tasks`/`system_info`/`list_recent_projects` dispatch-path tests now route through the `run_command` shell tool, which is deliberately NOT in `@write_tools`).

### `evo_git/agent_scheduler/`
- **`dispatch_test.exs`** — `EvoGit.AgentScheduler.DispatchTest`: `resolve_agent_repo_root/2` (primary/foreign/repo-less), repo-less `commit_pending_in_worktree/0` no-op, `resolve_model_for_agent/2`, `AgentSpec.new/5` model_id extraction.
- **`dispatch_custom_agents_test.exs`** — `EvoGit.AgentScheduler.DispatchCustomAgentsTest`: model selection via user script; custom-agent max_turns override.
- **`subagents_test.exs`** — `EvoGit.AgentScheduler.SubagentsTest`: spatial contract validation (cross-repo read-only, same-repo hierarchy), `store_sub_result/3` foreign-repo commit tracking, recycled-parent error paths (missing ETS rows).
- **`store_test.exs`** — `EvoGit.AgentScheduler.StoreTest` (`async: false`, global ETS `:evogit_agent_state`/`:evogit_sched_meta`): `update_agent_context/2` pass-through (pre-stamped timestamps stored verbatim), `batch_update_agent/2` one-way writes, `cancel_requested` lifecycle, broadcast payload hygiene (`:context` stripped, `message_count` prepended, trailing node).
- **`lifecycle_test.exs`** — `EvoGit.AgentScheduler.LifecycleTest` (26 tests, `async: false`, global ETS): `handle_agent_crash/3` retry/permanent/missing-ETS, `cancel_agent/2`, worktree ownership (lifecycle cleanup does NOT delete worktrees), force-kill, graceful cancel.
- **`slots_test.exs`** — `EvoGit.AgentScheduler.SlotsTest`: LLM/tool slot grant/block/release, hard-pause 0-capacity, per-model pool isolation + backoff, priority selection, `release_agent_slots/2`, ghost-model pool release.
- **`pubsub_test.exs`** — `EvoGit.AgentScheduler.PubSubTest` (`async: false`): supervised broadcast Throttle — 3 casts collapse to exactly 1 `{:agents_updated, node}`, kill → restart, supervision-tree assertion, no-throttle immediate-fallback path.
- **`agent_scheduler_test.exs`** — `EvoGit.AgentSchedulerTest` (`async: false`): `run_agent/2` does NOT do worktree init (WorktreeManager's job); LLM hard-pause.
- **`state_test.exs`** — `EvoGit.AgentScheduler.StateTest`: slot-pool regression tests — `do_update_config/2` preserves live pools, `apply_default_llm_concurrency_override/2` floor semantics, hard-pause 0.
- **`remote_api_test.exs`** — `EvoGit.AgentScheduler.RemoteAPITest` (48 tests, `async: false`, global ETS): RPC surface — `list_agents/0`, `get_agent_history/1`, `get_agent_state/1`, `get_config_status/0`, `list_task_ids/1`, `get_task/1`, `set_review_status/2`, `set_review_metadata/3`, review delegates.
- **`worktrees_test.exs`** — `EvoGit.AgentScheduler.WorktreesTest` (23 tests): `create_worktree_for_agent/6`, WorktreeManager crash-restart, **`assign_and_prepare_worktree/3` linked-worktree guard** (a plain unregistered dir or the repo root itself as the wt path → `{:worktree_prepare_failed, :not_a_linked_worktree}`, HEAD unmoved, agent branch not created, phylo_node nil; a real registered worktree binds phylo_node), `delete_branch_tolerant/2` (stale-registration prune+retry recovery; a live checked-out branch still errors), `prepare_new_worktree/5` leftover cleanup + rm_rf-failure escalation (`{:worktree_create_failed, "could not remove leftover worktree ..."}`), re-preparing over a leftover registered worktree destroys it with the main copy untouched, `branch_name/2`.
- **`worktree_retry_test.exs`** — `EvoGit.AgentScheduler.WorktreeRetryTest` (`async: true`, hermetic): `retry_on_transient/2`, `rm_rf_retry/2`, `mkdir_p_retry/2`, `retryable_reason?/1`, `repo_gone_output?/1`.

### `evo_git/agents/`
- **`custom_test.exs`** — `EvoGit.Agents.CustomTest`: definition resolution via `Process.get(:custom_agent_id)`, `available_tools/0` filtering, `subagent_tool_name/0` nil (root-only agents).

### `evo_git/config/`
- **`schema_test.exs`** — `EvoGit.Config.SchemaTest` (127 tests, largest file): `validate/1` over all schemas, model_spec type/extra/tuple formats, model_profiles type, peak_concurrency/peak_hours fields.
- **`llm_catalog_test.exs`** — `EvoGit.Config.LLMCatalogTest` (37 tests): `providers/0`, `resolve_model/2`, `provider_models/2`, `resolve_model_spec/2,3`, `requires_base_url?/1`, `credential_key_for_atom/1`.
- **`version_state_test.exs`** — `EvoGit.Config.VersionStateTest`: `get_version/0`, `save_version/1,0`, `upgraded?/0`, `onboarding_needed?/0`, caching.

### `evo_git/custom_agents/`
- **`model_selector_test.exs`** — `EvoGit.CustomAgents.ModelSelectorTest` (`async: false`, mutates XDG_CONFIG_HOME): script compile/eval contract, `select_model/1`, `status/0`, `invalidate/0`, never-raises behavior.

### `evo_git/runtime/`
- **`helpers_test.exs`** — `EvoGit.Runtime.HelpersTest` (46 tests): `generate_branch_name/1`, `new_codebase?/1` edges, `validate_node_path/2`, `resolve_starting_commit/2`, `notify_finalizing/1`, `merge_and_report/3`, **`merge_and_report/4` writable-foreign-repo branch creation (`Git.create_branch` — non-checking-out — leaves the foreign main copy's HEAD/branch/working tree untouched while the `genesis/agent_*` branch exists and points at the foreign commit)**, `load_foreign_repos/2`, `merge_foreign_repos/2`, `load_repo_notes/2`.
- **`evolution_test.exs`** — `EvoGit.Runtime.EvolutionTest` (`async: false`, XDG-isolated): custom evolve mode — `mode_atom/1` normalization, missing `:agent` raises before any repo I/O, unknown id raises, valid id routes custom flow, Genesis rejects `:custom` mode. **Note:** the valid-agent routing tests temporarily push `model_profiles: []` to the global scheduler (restored after) so `run_agent` replies `{:error, :llm_not_configured}`, and raise the logger level to `:info` (test-env default `:warning` filters `Logger.info`) — keep both techniques when extending.
- **`genesis_test.exs`** — `EvoGit.Runtime.GenesisTest`: `new_codebase?/1` auto-detection, model_id threading through AgentSpec.
- **`pull_request_test.exs`** — `EvoGit.Runtime.PullRequestTest`: `format_body/2`, `generate_title/2` (nil-model path).
- **`root_agent_helpers_test.exs`** — `EvoGit.Runtime.RootAgentHelpersTest`: `resolve_root_agent/2`, `model_id_locked?/1`.
- **`self_reflective_test.exs`** — `EvoGit.Runtime.SelfReflectiveTest`: `source_root/0`, `build_spec/2`, repo-less spec building.
- **`worktree_init_script_test.exs`** — `EvoGit.Runtime.WorktreeInitScriptTest` (42 tests): `build_systems/0`, `get_build_system/1`, `scripts_for/1`.

### `evo_git/sandbox/`
- **`bwrap_test.exs`** — `EvoGit.Sandbox.BwrapTest` (`async: false`, 42 tests): pure `args/4` generation for the bwrap backend — NO real bwrap execution (`Bwrap.enabled?/0` false in test env via the `@mix_env == :test` gate). Pins namespace flags, tmp/writable binds (defaults/configured/`[]`/`~`), git-metadata binds (linked-worktree `gitdir:` pointer → COMMON dir), 12-entry deny list, chdir + `--`, nix integration, TMPDIR setenv, git identity env, bash `-c` tail.
- **`linux_test.exs`** — `EvoGit.Sandbox.LinuxTest`: systemd-run backend `args/4` — TMPDIR forwarding, ReadWritePaths, PATH/HOME, nix, GIT_EDITOR injection, bash wrapping for stdin.
- **`macos_test.exs`** — `EvoGit.Sandbox.MacOSTest` (`async: false`): hardened `sandbox-exec` profile — deny-by-default + root-wide read allow, sensitive-dir deny rules in both symlink spellings, `(limit number 200)` + fail-safe stripping wiring, `resolve_tmpdir/0`. XDG_CONFIG_HOME redirected in setup. (Known flaky under full-suite parallel load — see Known Issues.)
- **`none_test.exs`** — `EvoGit.Sandbox.NoneTest`: passthrough backend (run/4, resolve_executable, stdin redirection, GIT_EDITOR).
- **`behaviour_test.exs`** — `EvoGit.Sandbox.BehaviourTest`: behaviour conformance of backend modules.
- **`helpers_test.exs`** — `EvoGit.Sandbox.HelpersTest`: `shell_escape/1`, `truncate_output/2`, `read_tempfile/2`, `system_cmd/2`.
- **`nix_test.exs`** — `EvoGit.NixTest`: `dev_env_state/0`, `active?/0`, `wrap_command/2` (shell escaping + graceful fallback), `reset_state/0`, `nix_env_vars/0`.
- **`truncation_test.exs`** — `EvoGit.Sandbox.TruncationTest`: `run_with_partial/6` — file vs max_bytes, temp file cleanup, nil max_bytes. (Known flaky under full-suite parallel load — see Known Issues.)
- **`sandbox_process_registry_test.exs`** — `EvoGit.SandboxProcessRegistryTest`: `register/0`, `unregister/1`, `release/1`, DOWN handler (systemd unit cleanup).
- **`sandbox_slice_test.exs`** — `EvoGit.SandboxSliceTest`: `ensure_slice/0` (systemd user slice).

### `evo_git/store/`
- **`errors_test.exs`** — `EvoGit.Store.ErrorsTest`: `disk_full_error?/1` classifier shapes.
- **`queries_test.exs`** — `EvoGit.Store.QueriesTest` (75 tests): `task_select_sql/0`, `project_select_sql/0`, `build_update_set/2`, `encode_column_value/2`, `clamp_limit/1`, `clamp_offset/1`, `build_where/1`, `escape_like/1`.

### `evo_git/` (misc — store/review/sampler/infra)
- **`store_test.exs`** — `EvoGit.StoreTest` (`async: false`, 69 tests): Store GenServer contract — encode/decode round-trips, **skip-and-log** for undecodable rows (bad rows SKIPPED + `Logger.warning`, retained untouched in the live table; `*_quarantine` tables never created — asserted via `sqlite_master`), `updated_at` write semantics (put_task/update_task_columns bump it, `update_lease_expires_at` does NOT), `select_tasks_changed_since/2` (15-key, strict `>`), Codec result/opts round-trips (string-tagged results; `decode_result/1`/`decode_opts/1` raise on ANY non-canonical input — raw strings, untagged JSON, pair-array opts), `:cancelling` in lease reads, safe_select_paginated variants.
- **`store_summary_test.exs`** — `EvoGit.StoreSummaryTest` (`async: false`, 31 tests): exact **15-key** summary projection (`result` deliberately absent), `[]` = all statuses, status-atom SQL pushdown, strict `updated_at > since` filter, skip-and-log in summary reads, chunked `delete_tasks/2` (1005 ids — 500/chunk boundary), narrow reads (`select_task_logs/2`, `select_task_update_info/2`), SQL pushdown (`select_running_lease_info/0`, `select_cleanup_info/0`). Deterministic `updated_at` control via raw `UPDATE tasks SET updated_at = ...` (schema has no default; NULL fails `>` comparisons).
- **`store_schema_migration_test.exs`** — `EvoGit.StoreSchemaMigrationTest` (`async: false`): `Schema.normalize_timestamps/1` (6-digit → 3-digit fractions, whole-second → `.000Z`, idempotent), `Codec.encode_datetime/1` millisecond precision, `Store.init/1` does **NOT** auto-migrate pre-existing rows — manual upgrade via `mix migrate.store`/direct `Schema.normalize_timestamps/1` required.
- **`store_disk_full_test.exs`** — `EvoGit.StoreDiskFullTest` (`async: false`, `EvoGit.TaskRegistryCase`): disk-full write boundary via **`PRAGMA query_only = ON` on the Store's own connection** (genuine `{:error, {:read_only_database, 8, ...}}`; SET pragmas must go through `XqliteNIF.query`, not `execute`). Classifier unit tests (`disk_full_error?/1` codes 13/10/8 + message-text fallback), Store survives + reads keep working + retried write succeeds, TaskRegistry degrades in-memory. Alternatives rejected: chmod 0444 (doesn't block WAL), chmod 555 on the dir (root bypasses), RAISE triggers (code-19 `constraint_trigger` — classifier deliberately doesn't match; see lib `EvoGit.Store.Errors` moduledoc). Not CI-testable: a real `SQLITE_FULL` and the non-disk-full crash path.
- **`migrate_store_test.exs`** — `EvoGit.MigrateStoreTest` (`async: false`): **`mix migrate.store`** end-to-end (standalone task — never starts the `:evo_git` app): legacy 18-column DB full upgrade (19 cols + indexes, timestamp normalization, raw results wrapped as string-tagged JSON, opts converted to objects, branch_name/updated_at backfills, quarantine drops), idempotent (byte-identical second run), fresh-DB no-op, malformed rows skipped.
- **`review_test.exs`** — `EvoGit.ReviewTest` (`async: true`): full review API on real git repos — `load_review_metadata/2`(+`_from_shas`), `load_file_diff/5` (context 10 vs `:all`), `list_commits_from_shas/3`, `load_commit_files/2`(+`_diff`), `merge_branch/2,3` (default/non-default target, conflict keeps agent branch + restores original), `default_merge_target/1`, `list_branches/1`, and the `check_merge/3` block — a **non-mutating `git merge-tree --write-tree` dry-run**: clean → `{:ok, :clean}`, conflict → `{:ok, {:conflict, files}}`, identical SHAs → clean, missing refs → `{:error, _}`; no-filesystem-trace assertions (no `.genesis` dir created, no extra worktrees, HEAD/status untouched). Also: **pre-merge review reads (`load_review_data`/`load_file_diff`/`check_merge`) yield a non-empty diff + `:clean` while HEAD is on the original branch and never mutate the main copy**.
- **`remote_bootstrap_test.exs`** — `EvoGit.RemoteBootstrapTest` (60 tests, no network): `parse_uname/2`, `parse_platform/1`, `daemon_os/1`, `asset_name/1` (never-suffixed glibc), `direct_url/1`/`download_url/1` (deterministic Cloudflare-worker URL, version `"latest"`), `cache_path/2`, `nixos_detect_command/0`, `nixos_patch_script/1`, `bash_wrap/1`, `parse_unit_environment/1`.
- **`remote_connections_test.exs`** — `EvoGit.RemoteConnectionsTest` (`async: false`): TOML store CRUD (`list/0`, `save/1`, `get/1`, `delete/1`, `touch/1`), platform field, old-field rejection, persistence round-trip.
- **`remote_connection_test.exs`** — `EvoGit.RemoteConnectionTest` (`async: false`): lifecycle + bootstrap using **real ssh against fake targets** (`testN@example.com` — connection refused, exit 255, fail fast). Covers auto-download/probe/platform-override/local-tarball bootstrap paths, `find_free_port/0`, `wait_for_tunnel/4` readiness poll, `build_tunnel_command/1`, `run_ssh_command/3` (argv arrays). `download_url/1` resolves deterministically then fails at the download — assertion kept broad (`{:error, {:download_failed, _}}`).
- **`remote_node_test.exs`** — `EvoGit.RemoteNodeTest` (`async: true`, 38 tests): local/remote branching RPC wrappers — task history (`list_tasks/1`, `list_tasks_paginated/2`, `get_unique_paths/1`, `list_tasks_summary/2`, `list_tasks_changed_since/2`), cancel/delete/clear/`force_kill_task/2`, `list_path_suggestions/2`, `dir?/2`, `get_task/2`, `set_review_status/3`, `set_review_metadata/4`, review delegates; unreachable `@fake_remote` → safe defaults, local → RemoteAPI.
- **`remote_node_github_test.exs`** — `EvoGit.RemoteNodeGitHubTest` (`async: false`): GitHub RPC wrappers (`github_upstream/2`, `list_github_issues/3`, `github_issue_markdown/3`) — unreachable-remote fallbacks + local RemoteAPI delegation with FakeGh. Kept in a SEPARATE file from `remote_node_test.exs` because PATH manipulation requires `async: false` while the existing module stays `async: true`.
- **`system_sampler_test.exs`** — `EvoGit.SystemSamplerTest` (`async: false`, 14 tests): exact 12-key sample map (sorted-key assertion), `{:system_sample, node, seq, sample}` broadcasts with proxy semantics, 60-sample ring buffer (65 manual ticks), 10-tick capacity-cache rule (tick 1 loads, tick 11 refreshes — the only test mutating global scheduler config, restored in `on_exit`), dead-scheduler pure helpers, registered-instance API, `RemoteAPI.get_recent_system_samples/0`. Seeding idiom: `:ets.insert(:evogit_sched_meta, {id, %SchedMeta{}})` (`delete_all_objects` only, never `:ets.delete`). Env gotchas below.
- **`application_test.exs`** — `EvoGit.ApplicationTest`: ETS table ownership — `:evogit_agent_state`/`:evogit_sched_meta`/`:evogit_archive_records` created by `Application.start/2`, survive scheduler crash/restart.
- **`cli_test.exs`** — `EvoGit.CLITest` (33 tests): foreign repo parsing, `--agent` flag, `-m`/`--model`, setup wizard model profile writing, evolve custom-mode dispatch.
- **`cli_agent_flag_test.exs`** — `EvoGit.CLI.AgentFlagTest`: `validate_custom_agent/1`, genesis/evolve dispatch with `--agent`, `--mode custom`.
- **`config_test.exs`** — `EvoGit.ConfigTest` (74 tests): defaults, sandbox backend config, `resolve/0,1`, credentials, config_dir/path, `save_user_config/1` validation, `config_status/0`, `api_key_present?/1`.
- **`custom_agents_test.exs`** — `EvoGit.CustomAgentsTest` (34 tests): agents.toml store — `path/0`, `list/0`, `save/1` (validation errors), `get/1`, `delete/1`, model_selection_script save, `reload/0`, id derivation, persistence round-trip.
- **`custom_agents_rpc_test.exs`** — `EvoGit.CustomAgentsRPCTest`: custom-agents RPC surface — RemoteAPI per-node fns + RemoteNode wrappers (local delegate + unreachable-remote error fallbacks).
- **`distribution_test.exs`** — `EvoGit.DistributionTest`: `distributed?/0`, `maybe_enable/0`, `enable_for_remote/1`, `start_epmd_if_configured/1`, `set_cookie/1` (+ nil cookie), kernel params.
- **`epmd_dist_test.exs`** — `EvoGit.EpmdDistTest`: `port_please/2` + `register_target/2` round-trip, `unregister_target/1`, `names/1`, `start_link/0`.
- **`executable_test.exs`** — `EvoGit.ExecutableTest`: `resolve/1` system-first/bundled-fallback strategy.
- **`git_env_test.exs`** — `EvoGit.GitEnvTest`: `git_env/0,1` (commit identity resolution), `git_env_list/0`, `git_command?/1`, `resolve_true_executable/0`.
- **`path_suggestions_test.exs`** — `EvoGit.PathSuggestionsTest`: `suggest/1`.
- **`peak_hours_test.exs`** — `EvoGit.PeakHoursTest` (60 tests): `parse_time/1`, `parse_window/1`, `validate_windows/1`, `in_peak?/2`, `next_transition/2`, `effective_concurrency/2,3` (tz-aware), `validate_timezone/1,2`, `wall_clock_in/2`.
- **`peak_hour_engine_test.exs`** — `EvoGit.PeakHourEngineTest`: engine against the live scheduler with injected clocks (`check/0`, pubsub broadcast path), pure `effective_map/3,4` (floor rule, peak_concurrency 0), `next_wakeup_ms/2,3`.
- **`platform_test.exs`** — `EvoGit.PlatformTest` (48 tests): `absolute_path?/1`, `path_under?/2`, separators, `bwrap_available?/0`, `sandbox_backend/0`.
- **`powershell_test.exs`** — `EvoGit.PowershellTest`: `powershell_executable?/1`, `wrap_script/1`, `encode_command/1`, `invoke_args/1`, `transform_args/2`, `decode_output/1`.
- **`project_config_test.exs`** — `EvoGit.ProjectConfigTest` (36 tests): `read/1`, `worktree_script/1,2` (OS variants), `foreign_repos/1`, `commands/1`, `write_worktree_script/2` (create/merge/round-trip, `'''` edge case).
- **`prompt_file_test.exs`** — `EvoGit.PromptFileTest`: `read/1` — plain text vs binary guard (`{:not_text, ext}`), `describe_error/2`.
- **`req_llm_pool_test.exs`** — `EvoGit.ReqLLMPoolTest`: `desired_count/1`, `error_target_count/1`, `effective_concurrency/2`, `excess_queuing_error?/1`, `reconcile/2` + `bump_for_excess_queuing/3` against a real Finch.
- **`self_reflective_source_test.exs`** — `EvoGit.SelfReflectiveSourceTest`: `status/0` (pure local read), `clone/0`, `update/0`, `reference_path/0` chain precedence.
- **`skills_test.exs`** — `EvoGit.SkillsTest` (57 tests): skills subsystem — frontmatter/YAML parsing, `substitute_params/3`, `validate_skill_text/1`, `to_tool_schemas/1`, `find_skill/2`, `skill_names/1`, `execute/4`, `load_skills/1`, CRUD.
- **`skills_hierarchical_test.exs`** — `EvoGit.SkillsHierarchicalTest`: `extract_context_skill_names/1`, `strip_front_matter/1`, `filter_skills/2`, `skill_names_at_dir/1`, `where_enabled/2`, `enable_skill/3`, `disable_skill/3`, hierarchical inheritance.
- **`system_check_test.exs`** — `EvoGit.SystemCheckTest` (45 tests): `tool_check/0`, `config_check/0`, `sandbox_check/0`, `supervisor_check/0`, `nix_check/0`, `run_all_checks/0`.
- **`utf8_test.exs`** — `EvoGit.UTF8Test`: `ensure_utf8/1` (em-dash truncation bug scenario).
- **`worktree_main_head_safety_test.exs`** — `EvoGit.WorktreeMainHeadSafetyTest` (`async: false`): end-to-end **writable-foreign-repo main-HEAD safety** through the full worktree lifecycle (worktree create → `assign_and_prepare_worktree/3` + phylo_node bind → agent commit inside the worktree → destroy → `merge_and_report/4` per-repo branch create → review pre-merge reads): the foreign main copy stays on its original branch with a clean tree throughout, the `genesis/agent_*` branch exists but is never checked out, and `load_review_data`/`check_merge` report a non-empty diff + `:clean` while HEAD is on the original branch.

### `evo_git/task_registry/`
(Full details: `evo_git/task_registry/CONTEXT.md`.)
- **`persistence_test.exs`** — `EvoGit.TaskRegistry.PersistenceTest` (`async: false`, 47 tests, isolated Store+TaskRegistry): restart durability, recent projects, status recovery from spurious `:failed`, cross-node PubSub filtering, startup reconciliation of orphaned `:finalizing`/`:cancelling`, `set_review_metadata/3`, recheck_task resolution (pins the unreachable-result-branch lib quirk — see the dir CONTEXT.md), nil `last_opened_at`.
- **`cleanup_test.exs`** / **`lease_heartbeat_test.exs`** / **`store_skip_and_log_test.exs`** / **`merge_context_test.exs`** / **`resume_context_test.exs`** / **`runtime_opts_test.exs`** / **`diagnostics_test.exs`** / **`task_executor_reflect_test.exs`** — see the directory's CONTEXT.md.

### `evo_git/skills/`
- **`executor_security_test.exs`** — `EvoGit.Skills.ExecutorSecurityTest` (`async: false`, 13 tests): skill-executor injection safety + sandbox routing. Details: `evo_git/skills/CONTEXT.md`.

## Known Issues & Test Env Notes

### Bootstrap test notes
- The `"platform override skips the probe and fails at download"` test resolves the deterministic Cloudflare-worker URL (`download_url/1`, network-free) then the download fails at the ssh level (fake target unreachable); the local curl fallback also fails. Assertion deliberately broad. Emits a downloader error line (`curl: (22) ... 404`) — harmless.
- The `connect/1` test emits a `Failed to enable distribution` warning (`:net_kernel` can't start in test env) — harmless; the test only asserts the error is NOT `:local_node_not_distributed`.

### SystemSampler test env
- The `:evo_git` app — incl. the REGISTERED `EvoGit.SystemSampler` (3000 ms tick default via `:system_sample_interval_ms` app env, read at init) — starts BEFORE `test_helper.exs`; `Application.put_env` in test_helper is too late. A test subscribing to `"system"` must silence it: set the env, then `Supervisor.terminate_child(EvoGit.Supervisor, EvoGit.SystemSampler)` + explicit `Supervisor.restart_child/2` so `init/1` re-reads it (`system_sampler_test.exs` does this in `setup_all`). Canonical fix (needs umbrella-root approval — `config/` is outside this node): `config :evo_git, :system_sample_interval_ms, 86_400_000` in `config/test.exs`.
- `Supervisor.terminate_child/2` does NOT auto-restart permanent children — the child stays `:undefined` until an explicit `Supervisor.restart_child/2`.

### Full-suite parallel-run flakiness (pre-existing, verified)
Running `mix test apps/evo_git/test` (parallel, max_cases 16) intermittently fails 1-3 timing-sensitive tests that ALL pass in isolation — observed: `EvoGit.Sandbox.TruncationTest` ("temp file cleanup does not leave temp files behind after completion"), `EvoGit.Sandbox.MacOSTest` ("resolve_tmpdir/0 falls back when TMPDIR points outside every tmp path"), `EvoGit.Agent.ToolDispatchRetrySlotTest` (slot release between retries / paused-scheduler blocks). The failing set varies run-to-run and reproduces on a feature-free base commit — pollution/timing under parallel load, NOT a regression. Guidance: re-run the suspect file(s) in isolation before treating full-suite failures as regressions.

## Constraints
- Tests use `@moduletag :tmp_dir` which provides a temporary directory via ExUnit's built-in fixture mechanism.
- No mocking libraries — all git tests use real `git` operations on temporary filesystem repos.
- Test module names mirror the source module path under test (e.g., `EvoGit.Core.ContextNodeTest` tests `EvoGit.Core.ContextNode`).
- Each test file is self-contained; `DummyAgent`/`HintAgent`/`DummyAgentModule` modules are defined inline where needed.
