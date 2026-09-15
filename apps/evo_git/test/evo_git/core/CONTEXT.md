# core — Test Tree

## Intent

ExUnit suites for the `:evo_git` core domain: `EvoGit.Core.ContextNode` (spatial),
`EvoGit.Core.PhyloGraphNode` (temporal), and `EvoGit.Core.ForeignRepo` (multi-repo
descriptor). Per-file detail lives one level up in `../CONTEXT.md`.

## Async-Safety Map

All three modules are `async: true` (verified to mutate no BEAM-global observable
state):

- **`context_node_test.exs`** — pure helpers (`normalize_relpath/1`, `load/2,3`,
  `hierarchy_nodes/2,3`) + `@moduletag :tmp_dir` fixtures. No git, no app env.
- **`phylo_graph_node_test.exs`** — real `git` in a per-test `@moduletag :tmp_dir`
  repo through `EvoGit.Adapters.Git`. Its only caching is the deterministic
  `:persistent_term` identity memoization in `EvoGit.GitEnv` (keyed by the unique
  repo path) and `EvoGit.Config`'s mtime/size-validated file cache — both reflect
  immutable external state, so no reader ever observes a differing value.
- **`foreign_repo_test.exs`** — in-memory data only (constructors/normalizers/
  resolvers); no filesystem, git, env, or `:persistent_term` writes.

## Notes for Agents

- Keep these `async: true` unless a future change makes one touch shared app
  singletons (`EvoGit.AgentScheduler`, `EvoGit.Store`/`TaskRegistry`,
  `EvoGit.SystemSampler`), global ETS, or `System`/`Application` env — then revert
  that file to `async: false` and name the forcing global in its `@moduledoc`.
