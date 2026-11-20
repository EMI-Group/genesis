# EvoGit.Util — Shared Pure Helpers

## Intent

One home for small pure helpers that were previously copy-pasted across the application (blank/present predicates, string truncation, slugs, key stringification, positive-integer coercion, clock reads).
These modules sit at the BOTTOM of the dependency graph so any layer can use them without pulling in Agent, Scheduler or Store code.

## API Surface

| Module | File | Functions |
|---|---|---|
| `EvoGit.Util.Strings` | `strings.ex` | `blank?/1`, `present?/1`, `truncate/2,3`, `truncate_bytes/2`, `slugify/1`, `content_text/1,2`, `human_size/1` |
| `EvoGit.Util.Coerce` | `coerce.ex` | `positive_integer/2`, `to_non_empty_string/1` |
| `EvoGit.Util.Time` | `time.ex` | `now_ms/0`, `now_iso8601/0` |
| `EvoGit.Util.Map` | `map.ex` | `stringify_keys/1,2` |

`stringify_keys/2` takes ONE option, `:drop_nil` (default `false`), which drops nil-VALUED map entries at every map level; `stringify_keys/1` is `stringify_keys(value, [])`, and a caller that needs the nil-dropping policy passes the option instead of keeping a copy (model-tuple handling stays a caller policy).
`truncate/2` is CHARACTER based and appends the house marker `...[truncated]`; `truncate/3` takes an explicit marker for callers with a different house style.
`truncate_bytes/2` is BYTE based and keeps a head and a tail with an omitted-bytes notice — it is a different semantic, not a variant of `truncate/2`.
`content_text/2` takes the part joiner because callers legitimately join differently (`""` for prompt text, `"\n"` for recency inspection).

## Constraints

- Pure functions only: no I/O beyond reading the system clock (`EvoGit.Util.Time`), no processes, no ETS, no `try/rescue`.
- These modules must NEVER depend on other `EvoGit` modules — dependencies point inwards to `EvoGit.Util`, never out.
- Every public function carries `@doc` and a `@spec`; specs use precise unions (Elixir 1.18 set-theoretic types), with `term()` reserved for genuinely total predicates.
- A helper moves here only when there is more than one caller or an obvious second caller; a single-use helper stays private next to its use.

## Routing Table

Leaf module directory — no child nodes.
