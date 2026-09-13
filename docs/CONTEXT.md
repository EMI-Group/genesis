# ./docs — Design Records & Reference Documentation

## Intent
Long-form design records for Genesis subsystems: rationale, verified external facts, and implementation details too granular for the CONTEXT.md tree.

## API Surface
- `auto-update.md` — full design record for the desktop auto-update / push-update system (tauri-plugin-updater v2): two-phase check/download/apply model, the genesis.evox.group `/dl/` update feed, CI signing, platform matrix, and remaining blockers.
- `images/` — images referenced by the design records.

## Constraints
- These are design records, not CONTEXT.md nodes: they may carry rationale and sequencing that CONTEXT.md deliberately must not.
- Keep external-fact claims accurate (Cloudflare worker behaviour, GitHub release redirect chains, CI mechanics) — other agents cite these instead of re-investigating.
- Design records describe the CURRENT design; edit them in place as the design changes rather than appending change history.

## Notes for Agents
- The `/dl/` Cloudflare Worker download proxy referenced throughout `auto-update.md` is implemented in the separate `genesis-doc` repository (`src/worker.ts` + `wrangler.jsonc`), not in this repo.
- Behaviour of that proxy is documented in `genesis-doc`'s `CONTEXT.md`; do not duplicate it here.

## Routing Table
- No sub-areas — `auto-update.md` is the single design record in this directory.
