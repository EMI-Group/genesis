# Adapters Test Suite

## Intent

ExUnit tests for the `EvoGit.Adapters.*` modules (thin CLI wrappers).
Exercises real `git` / `gh` subprocesses against temp-dir repos — no mocks, no Mox/Meck.
Full per-file inventory and shared helpers: parent `../CONTEXT.md`.

## API Surface

| File | Module | Purpose |
|------|--------|---------|
| `git_test.exs` | `EvoGit.Adapters.GitTest` | Git CLI adapter — `ls_tree_gitlinks/2`, `add_worktree/4` (gitlink submodules), failed-add leftover-dir + free-branch cleanup, `remove_leftover_worktree_dir/1`, `{:ok, v} \| {:error, {tag, output}}` contract |
| `github_test.exs` | `EvoGit.Adapters.GitHubTest` | `gh` CLI adapter — upstream parsing, issue listing JSON normalization, issue markdown (`async: false` + `EvoGit.FakeGh`, POSIX-gated) |
| `cow_worktree_test.exs` | `EvoGit.Adapters.CowWorktreeTest` | CoW worktree creation + feature-gate/fallback classification (see below) |

## `cow_worktree_test.exs` — CoW worktree coverage

Covers `Git.ls_tree_names/2` + `Git.diff_name_only/3`, `flag/0`/`enable/0`/`disable/0`, `enabled?/0`,
the happy paths (content parity with a standard `git worktree add`, dirty-file exclusion, nested dirs,
deep paths, gitlink submodule placeholder), the `{:fallback, :worktree_add_failed}` leftover-cleanup block,
and the **permanent-vs-transient fallback classification** (see Design Decisions).

## Design Decisions

- `async: false` is REQUIRED — `EvoGit.Adapters.CowWorktree` keeps VM-global state in `:persistent_term` key `:evogit_cow_worktree_enabled` (`@flag_key`), and `github_test.exs` mutates the global process `PATH`. Concurrent flag/PATH mutations would race.
- `setup_all` (not `setup`) redirects `XDG_CONFIG_HOME` to a temp dir for the WHOLE module, so `Config.resolve([:git, :cow_worktree_creation])` returns the schema default `:auto` with no user TOML interference and `EvoGit.Config`'s mtime+size cache stays warm across the module's tests; `on_exit` restores it and removes the dir.
  Per TEST, `setup` still `:persistent_term.erase(@flag_key)` for a known start state and erases it again in `on_exit`.
- **Fixture repos are copies of ONE per-module template.** `setup_all` runs `git init -q --template=<empty dir> -b main` (no hook samples), pins a repo-local identity (`user.name`/`user.email`), `commit.gpgsign=false` (a developer's global `gpgsign = true` cannot fail fixture commits) and `core.abbrev=40`; each test `File.cp_r!`s it into a unique dir. `EvoGit.GitEnv.prime_config_identity_cache/3` is called for that copy path AND for every worktree path created under it — byte-identical to what the first `git config` lookup would resolve, minus the two forks.
  `git commit`'s own summary provides the new sha; tests that need HEAD read the loose `.git/refs/heads/*` file the commit just wrote (no `git rev-parse` fork) and fall back to `rev-parse` for a detached HEAD or a non-loose ref layout.
- **`cleanup_worktree/2` does NOT run `git worktree remove --force`**: the fixture repo (and with it the worktree registration) is deleted wholesale by `make_repo/1`'s `on_exit`, so deregistering first would only add one git subprocess per test.
- **`github_test.exs` builds TWO templates in `setup_all`** — a bare `git init` and one that already carries the common `origin` remote — and `setup` selects by `@tag :no_origin`.
  `add_origin/2` resets a fixture's URL by writing `remote.origin.url` through `git config` (a no-op for the template's own URL) because `git remote add` cannot re-add a remote that already exists.
- **Only `:unsupported_platform` is permanent** (it is the only reason that calls `disable/0`); the seven transient reasons (`:no_source_head`, `:no_source_status`, `:no_changed_files`, `:no_target_tree`, `:worktree_add_failed`, `:cp_failed`, `:checkout_failed`) return `{:fallback, reason}` for that creation only and leave CoW ENABLED so the next creation retries.
- `:unsupported_platform` is unreachable through the public `create_worktree/5` on Linux, so the permanent path is asserted at unit level via the `@doc false` helpers `CowWorktree.permanent_reason?/1` and `CowWorktree.handle_fallback/1,2` (the helpers emit an expected `Logger.warning`; it is intentionally not silenced).

## Notes for Agents

- There is **no cooldown timer** in the adapter — transient reasons never disable and the retry simply happens on the next creation. Do NOT add a cooldown test.
- Transient-fallback tests must trigger a real failure through the public API (e.g. a source repo with `git init` and no commits → `:no_source_head`; a non-existent 40-hex `target_commit` → `:no_changed_files`). The step order is source HEAD → source status → diff → target tree, so an unresolvable target commit fails at the diff step, not the target-tree step.
- A `:ok` return from `create_worktree/5` is what proves the CoW path was actually attempted — a disabled flag short-circuits upstream in `EvoGit.AgentScheduler.Worktrees` and this function is never reached.
- Keep the existing helpers (`make_repo/1`, `write_file/3`, `commit_all/2`, `make_worktree_path/1`, `cleanup_worktree/2`) and route every created worktree through `on_exit(fn -> cleanup_worktree(repo, path) end)` so temp dirs do not leak.
- Fixture repos carry their identity in the TEMPLATE's repo-local `.git/config` (`Test User <test@example.com>`) and each copy's memo is primed for it — do not add per-test `git config user.name`/`user.email` calls, and do not prime a pair the template does not hold (a mismatch would only make the memo wrong).
- `make_repo/1` and `make_worktree_path/1` both `File.rm_rf!` their target path first, since `System.unique_integer/1` repeats across VM runs and stale leftovers would break branch assertions or silently force a `create_worktree/5` fallback.

## Constraints

- Real git operations on temp dirs only; no mocking libraries.
- Test module names mirror the source module path under test.
- No `try/rescue` in these files.
