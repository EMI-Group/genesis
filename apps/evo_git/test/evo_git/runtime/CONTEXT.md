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

## Notes for Agents

- **No test-side seam for the agent LLM path** (see `../../CONTEXT.md` → "No fake-LLM harness"):
  the custom-evolve and self-reflective `run/2` tests accept ONLY the error paths — an empty
  `model_profiles` (→ `{:error, :llm_not_configured}`) or a scheduler-down `:noproc` exit. The
  `without_model_profiles/1` + `guarded_run/1` + `quiet_error_result/1` helpers are duplicated in
  `evolution_test.exs` and `self_reflective_test.exs`; a shared `test/support/` module is the
  natural home if they grow, but that directory is owned elsewhere.
- Full-suite parallel-run flakiness is documented one level up in `../../CONTEXT.md` →
  "Known Issues & Test Env Notes". The runtime directory itself is stable across seeds.

## Foreign-Repo Test Coverage (`helpers_test.exs`)

All writable-foreign-repo coverage in this node lives in `helpers_test.exs` (`async: true`).
`evolution_test.exs` never passes `:foreign_repos` (covers only `mode_atom/1`, custom-mode agent requirement, simple-mode error path, invalid starting commit); `genesis_test.exs` only touches the empty `foreign_repos: []` default (line 100).
Helper `make_git_repo!/1` (lines 31–48) makes a fresh git repo with one commit at HEAD; `setup_primary_with_changes!/1` (lines 53–68) makes a primary whose HEAD is reset one commit back.

- `describe "load_foreign_repos/2"` (lines 695–929, 10 tests): CLI-only (696) / TOML-only (705) / merge-no-conflict (728) / CLI-precedence (755) / string-keyed-map normalization (780) / missing-path raise (805) / non-git-dir raise (827) / UNC-root raise (852) / unresolvable-base_sha raise (868) / writable+base_sha struct round-trip (895) + TOML parse (912).
- `describe "resolve_foreign_repo_starting_commit/2"` (lines 934–965, 3 tests): base_sha set → base_sha (935); base_sha nil → foreign HEAD (944); non-resolving base_sha → `{:error, {:invalid_starting_commit, ref, root, output}}` (953).
- `describe "merge_and_report/3"` (lines 331–413, 3 tests): nil commit_sha → `no_changes: true` + nil branch (332); commit_sha == base → `no_changes: true` (352); commit_sha != base → `genesis/agent_*` branch (374).
- `describe "merge_and_report/4"` (lines 418–647, 6 tests): ONE shared branch across primary + ONE writable foreign repo, `repos` map asserted exactly (419); foreign branch create does not move the foreign main working-copy HEAD (459); read-only foreign repo → no entry/no branch (526); primary-no-changes-but-foreign-commit → foreign branch + primary `branch_name: nil` (554); 3-arity reports primary only (594); `repos` survives `Store.Codec` round-trip with string keys (613).
- `describe "merge_foreign_repos/2"` (lines 970–1040, 6 tests): struct/atom-map/string-map/mixed shapes, dedupe by id with CLI precedence, unparseable-entry drop.

### Known coverage gaps (writable foreign repos)

- `resolve_foreign_repo_starting_commit/2` base_sha-precedence test (935) sets `base_sha` to the repo's OWN HEAD, so it cannot distinguish base_sha from HEAD — no test with a base_sha ≠ HEAD (older/off-tip commit) proving precedence.
- `load_foreign_repos/2` "validates and returns structs" (895) also uses `Git.rev_parse(root)` (= HEAD) as base_sha — no valid-but-off-tip base_sha fixture, and no test that a FULL 40-hex nonexistent base_sha passes load validation while failing the later `^{commit}` peel at resolve time (that asymmetry is only noted in a comment at lines 873–875).
- `merge_and_report/4` is exercised with at most ONE writable foreign repo — no multi-foreign-repo (2+) case despite the plural `repos` contract.
- No test of a writable foreign repo present in `foreign_repos` but ABSENT from `foreign_repo_commits` (should yield no `repos` entry), nor of a tracked commit for an id NOT in the `foreign_repos` list (should be ignored).
- No test of branch-creation-failure tolerance (`create_foreign_branch` / primary `Git.create_branch` error → entry kept with `branch_name: nil`, helpers.ex:162–181).
- No test of the rev_parse-error outer arm of `merge_and_report/4` (`helpers.ex:87–96`).
- No test of a writable-foreign-repo RUNTIME path (simple/custom evolve advancing a foreign repo's commit and rolling it into `repos`) — the roll-up is covered only in sibling nodes (`agent_scheduler/lifecycle_test.exs`), not end-to-end here.
