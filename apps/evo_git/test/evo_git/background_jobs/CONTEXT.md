# Background Jobs — Id Minting Test Suite

## Intent

Covers `EvoGit.BackgroundJobs.JobId`, the PURE minting module behind every background-job id (`bash-<base36 payload>`, e.g. `bash-7f3k2`) — the short token an agent repeats in `job_output`/`job_kill` and reads in notices.
The suite exists because the id is ALSO the job's log-file address (`genesis_job_<id>.log`), so its shape and uniqueness are the guarantee that two registries sharing one scratch dir can never reach each other's files.

## Pinned contracts

- Shape: `valid?/1` accepts exactly `bash-` plus 1..8 chars of `[0-9a-z]` and rejects an empty, over-long or uppercase payload, an inner separator, a missing prefix and non-binaries.
- Attributes: `prefix/0` `"bash-"`, `payload_max/0` 8, `space/0` `36 ** 8`, and the widest encoding of `space() - 1` is exactly `payload_max/0` characters (the regex is derived from the same attributes).
- Encoding bounds: an out-of-range candidate integer (the space itself, `space() - 1`, `10 ** 30`) folds into the payload space by `Integer.mod/2`, so a minted id always satisfies `valid?/1`.
- Uniqueness and non-sequentiality: 2 000 mints into a `MapSet` yield 2 000 distinct ids, and the payload integers of 50 mints are NOT a contiguous counter run — the id is a random token, not a per-registry sequence.
- Collision handling: the three `taken` shapes (a keyed map, a `MapSet`, a 1-arity fun) agree, and a collision advances deterministically by one in payload space, wrapping at the end of the space.
- The bounded scan: `mint/2`'s test-only `:attempts` (default `space/0`) caps the consecutive taken candidates tried, so a suite can pin both the near miss (the LAST free slot of a narrow walk is still found) and `{:error, :id_space_exhausted}` — which terminates instead of looping.
- Input validation: a `taken` value that is not a map/`MapSet`/1-arity fun, and a non-positive or non-integer `:attempts`, raise `ArgumentError`.

## Constraints

- `async: true`: the module under test is pure — no OS process, no scratch directory, no port, no ETS, no app env and no shared registry.
- Every case passes its own `taken` ids and its own `:candidate_source` / `:attempts` seams, so nothing bleeds between cases or modules.
- Registry-level coverage (the file address, truncation, sibling registries, tombstones) lives in `../background_jobs_test.exs` — do not duplicate it here.
