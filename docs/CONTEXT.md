# ./docs — Design Records & Reference Documentation

## Intent
Long-form design records and reference documentation for Genesis: rationale, verified external facts, and implementation details too granular for the CONTEXT.md tree.

## API Surface
- `auto-update.md` — full design record for the desktop auto-update / push-update system (tauri-plugin-updater v2): two-phase check/download/apply model, the genesis.evox.group `/dl/` update feed, CI signing, platform matrix, and remaining blockers.
- `experiments.md` — results/reference document: the per-regime experimental results (formation, continuation, redevelopment, Terminal-Bench) and their figures, moved out of the top-level README; figures live under `images/experiments/`.
- `images/` — figures referenced by the design records and reference documents (`images/experiments/` for the experimental plots), plus the promo-film poster `promo-poster.jpg`.

## Constraints
- These are design records, not CONTEXT.md nodes: they may carry rationale and sequencing that CONTEXT.md deliberately must not.
- Keep external-fact claims accurate (Cloudflare worker behaviour, GitHub release redirect chains, CI mechanics) — other agents cite these instead of re-investigating.
- Design records describe the CURRENT design; edit them in place as the design changes rather than appending change history.
- The numbers in `experiments.md` mirror the published Genesis paper — keep them verbatim; they are observed system-level results, not normalized benchmarks.

## Notes for Agents
- The `/dl/` Cloudflare Worker download proxy referenced throughout `auto-update.md` is implemented in the separate `genesis-doc` repository (`src/worker.ts` + `wrangler.jsonc`), not in this repo.
- Behaviour of that proxy is documented in `genesis-doc`'s `CONTEXT.md`; do not duplicate it here.
- `images/promo-poster.jpg` is a verbatim copy of an asset owned by the `genesis-doc` repo (its video directory); copy it again rather than regenerating or resizing it.

## Routing Table
- `auto-update.md` — desktop auto-update / push-update design record.
- `experiments.md` — experimental results and figures (regime-by-regime).
