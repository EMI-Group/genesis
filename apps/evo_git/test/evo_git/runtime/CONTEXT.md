# runtime — Test Tree

## Intent

ExUnit suites for `EvoGit.Runtime.*` (Genesis, Evolution, SelfReflective, Helpers, PullRequest,
RootAgentHelpers/`Runtime.Helpers`, WorktreeInitScript).
Each file mirrors its source module path under `apps/evo_git/lib/evo_git/runtime/`.
Full per-file inventory lives one level up in `../CONTEXT.md` — do not duplicate it here.

## Async-Safety Map (audited)

Every `async: false` module carries an in-file `@moduledoc` naming the exact BEAM-global that
forces serialization — keep it accurate when the forcing state changes. Do NOT flip these to
`async: true`:

- **`evolution_test.exs`** — `System.put_env("XDG_CONFIG_HOME")` (read by `EvoGit.Config` /
  `EvoGit.CustomAgents`), the live scheduler's `model_profiles` (`AgentScheduler.update_config/1`),
  and the global `Logger` level.
- **`pull_request_test.exs`** — `System.put_env("XDG_CONFIG_HOME")` (read by `EvoGit.Config`).
- **`root_agent_helpers_test.exs`** — `System.put_env("XDG_CONFIG_HOME")` (read by
  `EvoGit.CustomAgents`).
- **`self_reflective_test.exs`** — the `:self_reflective_source_root` / `:self_reflective_source_dir`
  app env and the `GENESIS_SOURCE_ROOT` OS env var (read by production
  `EvoGit.Runtime.SelfReflective.source_root/0` / `EvoGit.SelfReflectiveSource.reference_path/0`),
  plus the live scheduler's `model_profiles`.

Genuinely `async: true` (verified to mutate no BEAM-global state):

- **`genesis_test.exs`** — pure `Helpers.new_codebase?/1` + `AgentSpec.new/5` + the UNC
  `Genesis.run/2` pre-I/O `ArgumentError` guard.
- **`helpers_test.exs`** — pure helpers + real git ops on unique temp repos. It does NOT subscribe
  to any PubSub topic; its `notify_finalizing/1` tests only BROADCAST on the shared `"tasks"`
  topic (no assertion on it). Emitting there is safe because ExUnit runs sync modules in isolation
  after all async modules finish (confirmed by the additive "X s async, Y s sync" timing), so no
  sync subscriber (e.g. `task_registry/persistence_test.exs`'s wildcard `refute_receive`) can be
  polluted by them.
- **`worktree_init_script_test.exs`** — pure data/script-string assertions.

## Known Issues

- **Git `-F` temp message files live in the SHARED host tmp dir**: every `EvoGit.Adapters.Git.commit/2` / `add_note/4` writes `System.tmp_dir!()/genesis_git_msg_<n><ext>` (`adapters/git.ex` `with_temp_msg_file/3` + `temp_file_path/1`) and deletes it in an `after` block. The name is unique only WITHIN one BEAM VM (`System.unique_integer([:positive, :monotonic])`) while `System.tmp_dir!()` reads the VM-global `$TMPDIR`, so a git-commit-based helper (`make_git_repo!/1` here, `setup_primary_with_changes!/1`, plus the adapter/scheduler suites) can fail with `{:error, {128, "fatal: could not read log file '/tmp/genesis_git_msg_N.txt': No such file or directory"}}` → `MatchError` when another concurrently-running `mix test` BEAM (parallel worktree runs sharing `/tmp`) generated the same filename and removed it. Observed once in a full-suite run under CPU load (helpers_test.exs:419). No code in the repo bulk-deletes temp files; treat this as an environment-level path collision, not an assertion bug.

## Notes for Agents
- **No test-side seam for the agent LLM path** (see `../../CONTEXT.md` → "No fake-LLM harness"):
  the custom-evolve and self-reflective `run/2` tests accept ONLY the error paths — an empty
  `model_profiles` (→ `{:error, :llm_not_configured}`) or a scheduler-down `:noproc` exit. The
  `without_model_profiles/1` + `guarded_run/1` + `quiet_error_result/1` helpers are duplicated in
  `evolution_test.exs` and `self_reflective_test.exs`; a shared `test/support/` module is the
  natural home if they grow, but that directory is owned elsewhere.
- Full-suite parallel-run flakiness is documented one level up in `../../CONTEXT.md` →
  "Known Issues & Test Env Notes". The runtime directory itself is stable across seeds.
