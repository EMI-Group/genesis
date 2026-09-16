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

## Coverage Map — `foreign_repo_test.exs` (53 tests, `async: true`)

`EvoGit.Core.ForeignRepoTest` — describes and line ranges:

- `"new/3"` (L9–72, 10 tests) — expanded root (L10), description (L17/L22), **`writable`/`base_sha` defaults false/nil (L27)**, **`writable: true` + `base_sha: "abc123"` opts (L33)**, **non-boolean `writable` ("yes"/1/nil) coerces to false (L39)**, **blank `base_sha` ("", "   ", nil) coerces to nil (L45)**, UNC roots preserved (L56/L61).
- `"normalize/1"` (L74–172, 14 tests) — struct passthrough (L75), atom-keyed map (L80), string-keyed map (L85), **string-keyed map with `"writable" => true` + `"base_sha" => "abc123"` preserved (L90)**, **atom-keyed map with both preserved (L107)**, **missing keys default to false/nil for BOTH string- and atom-keyed input (L117)**, `"path"`/`:path` root fallback (L125/L130), `"root"` beats `"path"` (L135), description blank→nil (L140), root expanded (L148), nil for non-map (L155) / missing-blank id (L161) / no root (L167).
- `primary_id/0` (L174) · `primary?/1` (L180) · `absolute_path?/1` (L191) · `normalize_path/2` (L217) · `resolve_path/2` (L266) — pure path logic, no `writable`/`base_sha` involvement.
- `"Jason encode/decode round trip (Store codec path)"` (L374–384, 2 tests) — **`Jason.encode! |> Jason.decode! |> normalize/1 == original` for `writable: true` + `base_sha: "abc123"` (L375) and for the all-defaults repo (L380)**; this is the STRING-keyed Codec round-trip guarantee, and it also pins the `@derive Jason.Encoder, only: [...]` list for `writable`/`base_sha`/`id`/`root`.

## Test Gaps — `writable` / `base_sha` (as of this node)

- **`coerce_base_sha/1`'s non-binary clause is untested** (`foreign_repo.ex:162`): no test passes `base_sha: 123` / `base_sha: :ref` and asserts `nil`.
- **Whitespace trimming of a NON-blank `base_sha` is untested** (`foreign_repo.ex:155-159`): only the fully-blank cases (L45–49) exist; `base_sha: " abc123 "` → `"abc123"` is asserted nowhere.
- **`normalize/1`-level coercion of bad values is untested**: coercion is only exercised through `new/3` (L39/L45); e.g. `normalize(%{"id" => "a", "root" => "/abs/a", "writable" => "yes"})` → `writable: false` and `normalize(%{… "base_sha" => 123})` → `nil` have no assertion.
- **Mixed string/atom keying is untested**: `normalize/1` reads `writable` via `Map.get(repo, "writable", Map.get(repo, :writable, false))` (`foreign_repo.ex:130`) and every other field via string-first `fetch/2` (`foreign_repo.ex:144`), so a map with BOTH key forms (string wins) or a string-keyed map carrying an atom-keyed `base_sha` has no coverage.
- **Struct passthrough with `writable: true` / non-nil `base_sha` is not directly asserted** — L75 only passes a defaults struct; the non-default struct path is only reached indirectly via the Jason test L375.
- **Jason encode of a non-nil `description` on a writable repo is untested**: `only: [:id, :root, :description, :writable, :base_sha]` dropping `:description` would not fail any test in this file (the round-trip tests use `description: nil`).
- **No `doctest EvoGit.Core.ForeignRepo`** anywhere in the suite — the ~7 doctests in `foreign_repo.ex` (L54–61, L100–113, L184–190) are never executed (only `peak_hours_test.exs:6` runs a doctest).
- **`base_sha` SEMANTICS (`nil` = foreign HEAD) are NOT covered in this node** — no git fixture exists here; the semantic is asserted one level out in `../runtime/helpers_test.exs:934-951` (`resolve_foreign_repo_starting_commit/2`: base_sha set → sha; nil → repo HEAD) and the TOML→struct mapping in `../project_config_test.exs:157-180`.

## Notes for Agents

- Keep these `async: true` unless a future change makes one touch shared app
  singletons (`EvoGit.AgentScheduler`, `EvoGit.Store`/`TaskRegistry`,
  `EvoGit.SystemSampler`), global ETS, or `System`/`Application` env — then revert
  that file to `async: false` and name the forcing global in its `@moduledoc`.
