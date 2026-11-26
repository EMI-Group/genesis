# core — Test Tree

## Intent

ExUnit suites for the `:evo_git` core domain: `EvoGit.Core.ContextNode` (spatial), `EvoGit.Core.ContextScope` (Shared/Local `CONTEXT.md` divider), `EvoGit.Core.PhyloGraphNode` (temporal), and `EvoGit.Core.ForeignRepo` (multi-repo descriptor).
Per-file detail lives one level up in `../CONTEXT.md`.

## Async-Safety Map

All four modules are `async: true` (verified to mutate no BEAM-global observable state):

- **`context_node_test.exs`** — pure helpers (`normalize_relpath/1`, `load/2,3`, `hierarchy_nodes/2,3`) plus `@moduletag :tmp_dir` fixtures and the `build_context/2` render assertions (stage order, labels, skipping, sharing AND the two-scope Shared/Local rules). No git, no app env; every `build_context/2` case starts its OWN uniquely-named `EvoGit.VCT` (`start_vct/2`, isolated `:store` + `data_dir: tmp_dir`) and points the calling process at it through the `:evogit_vct_server` pdict seam, so the app-global VCT is never read or mutated.
- **`context_scope_test.exs`** — PURE: every case drives `split/1`, `scope_content/2`, `splice/3`, `has_local?/1`, `marker/0` and `parse_scope/1` on in-memory binaries. No filesystem, git, env, `:persistent_term` or app-env write.
- **`phylo_graph_node_test.exs`** — real `git` in a per-test `@moduletag :tmp_dir` repo through `EvoGit.Adapters.Git`. Its only caching is the deterministic `:persistent_term` identity memoization in `EvoGit.GitEnv` (keyed by the unique repo path) and `EvoGit.Config`'s mtime/size-validated file cache — both reflect immutable external state, so no reader ever observes a differing value.
- **`foreign_repo_test.exs`** — in-memory data only (constructors/normalizers/resolvers); no filesystem, git, env, or `:persistent_term` writes.

## Coverage Map — Two-scope `CONTEXT.md` (`context_scope_test.exs` + `context_node_test.exs`)

The divider primitive (`EvoGit.Core.ContextScope`) is pinned by `EvoGit.Core.ContextScopeTest` (24 tests): `marker/0` returns the literal `<!-- genesis:local -->`; a divider-less file is `%{shared: content, local: ""}` with `has_local?/1 == false`; a divider as the FIRST line leaves Shared empty; leading/trailing spaces and tabs are tolerated; a CRLF file keeps `\r\n` in both scopes and `:all` drops ONLY the divider line (byte-exact); a divider as the FINAL line with no trailing newline yields an empty Local; the FIRST occurrence wins (a second marker line stays ordinary Local text); a marker line inside a fenced code block STILL splits (deliberate no-fence-awareness, commented in-file); `:all == shared <> local` and is the input with only the divider line removed.
`splice/3` pins: editing `:shared` preserves the divider line + Local byte-for-byte, editing `:local` preserves Shared + divider, a CRLF divider is re-emitted with its exact ending, a final divider with no ending stays ending-less, `:all` replaces the whole body, and a divider-less file makes `:shared`/`:all` replace everything while `:local` is an identity no-op.
`parse_scope/1` accepts `"shared"`/`"local"`/`"all"` and the matching atoms and answers `{:error, message}` (never raising) for anything else, the message naming all three values.

`build_context/2` rendering rules are pinned in `context_node_test.exs`'s `"build_context/2 scopes (Shared vs Local)"` describe (8 tests):
- a divider-less chain renders BYTE-IDENTICALLY to the pre-scope renderer (whole-output `==` literal, the backward-compatibility invariant);
- an ANCESTOR renders its Shared scope only (its Local text absent, the divider literal never rendered);
- the ASSIGNED node renders BOTH scopes;
- the VCT global stage renders Shared only;
- an ancestor blank after scope selection is skipped entirely (no stage, no extra fence block);
- an all-Local ASSIGNED node still renders exactly ONE stage;
- `build_context("./", repo)` renders the root's FULL file (both scopes, because the root IS the assigned node);
- front matter belongs to the Shared part (scope selection runs on RAW content first) and is stripped from it.

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

- Keep these `async: true` unless a future change makes one touch shared app singletons (`EvoGit.AgentScheduler`, `EvoGit.Store`/`TaskRegistry`, `EvoGit.SystemSampler`), global ETS, or `System`/`Application` env — then revert that file to `async: false` and name the forcing global in its `@moduledoc`.
- A new `build_context/2` case MUST call `start_vct/2` first and use the per-test `build_repo!/2` tree: without an isolated VCT instance the render reads the APP-GLOBAL `EvoGit.VCT` (and the developer's real global context), and a shared fixture repo would be rewritten by a concurrent case.
- The divider literal in a test is spelled through a module attribute (`@local_marker` / `@marker`) so a suite-wide grep for `<!-- genesis:local -->` finds the production literal and every pin together.
- `strip_front_matter/1` TRIMS its parsed body, which is why the byte-identical render pin expects the body text followed by exactly one newline before the closing fence, never a doubled one.
