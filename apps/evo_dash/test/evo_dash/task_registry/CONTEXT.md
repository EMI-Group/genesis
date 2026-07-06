# TaskRegistry Test Support

## Intent

Shared test support (`EvoDash.TaskRegistryCase`) providing isolated Store + TaskRegistry setup and common helpers for task registry tests.

## Test Files

- `cleanup_test.exs` — Age/count-based task cleanup
- `lease_heartbeat_test.exs` — Lease & heartbeat pattern
- `persistence_test.exs` — CRUD, resilience, archive metadata, status recovery
- `reconciliation_test.exs` — Restart reconciliation and liveness detection
- `store_integrity_test.exs` — Store.integrity_check with corrupt rows
