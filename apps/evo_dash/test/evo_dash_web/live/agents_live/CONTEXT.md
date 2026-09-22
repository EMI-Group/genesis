# Test Directory — AgentsLive Support Modules

## Intent

Pure unit tests for the `EvoDashWeb.AgentsLive.*` support modules (mirrors
`apps/evo_dash/lib/evo_dash_web/live/agents_live/`). Everything here is
`async: true` and free of LiveView/Phoenix/store/app-env dependencies — the
stateful AgentsLive page integration tests live in `../agents_live_test.exs`
(parent directory, owned elsewhere).

## API Surface

| File | Module | Covers |
|------|--------|--------|
| `optimistic_messages_test.exs` | `EvoDashWeb.AgentsLive.OptimisticMessagesTest` | `EvoDashWeb.AgentsLive.OptimisticMessages` — optimistic user-message append/merge/latest-turn helpers. |
| `commit_graph_test.exs` | `EvoDashWeb.AgentsLive.CommitGraphTest` (12 describes, 56 tests) | `EvoDashWeb.AgentsLive.CommitGraph` — the temporal (git commit history) graph assembler: geometry getters (`dot_r/0`/`ring_r/0`), `grouping_key/1`, `repo_display_name/1` (localized: tests run in the default `:en` locale, so English msgids are asserted), and `build/2` (per-repo grouping + `{repo_name, repo_dom_id}` sorting, deterministic DOM-safe `repo_dom_id`, first-available-lane assignment with merge folding (oldest-at-top, lane_count never shrinks), dot geometry/dimension formulas, child→parent edge paths (straight same-lane / bezier cross-lane), depth→hue overlay colors (exact hex pins), status RINGS on TIP commits only, the two-tier dot click-target mapping (tip vs path-covering), commit view fields incl. `short_sha` fallback / first-line message / refs, and total/defensive degradation for odd input shapes). All fixtures are hand-crafted agent + `%{commits, refs}` maps — no repo I/O, no LLM, no sockets. |

## Constraints

- Pure unit tests only: `use ExUnit.Case, async: true`, no `ConnCase`, no
  `EvoDash.TaskSupervisor`, no app-env seams, no global hub resets.
- Fixtures are built with file-local helpers (`agent/3`, `commit/2`,
  `chain/1`, `raw/2`) deliberately mirroring the shapes the module reads.
- Assertion styles follow the sibling convention: one-sentence explanatory
  comments above non-obvious expectations.
