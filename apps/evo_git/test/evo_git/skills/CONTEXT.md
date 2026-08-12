# Skills Tests

## Intent
ExUnit tests for the skills subsystem (`EvoGit.Skills` — executor, CRUD, context integration, skill definition). Covers injection safety and sandbox routing of skill execution.

## Routing Table

None — leaf directory.

## API Surface

- `executor_security_test.exs` — `EvoGit.Skills.ExecutorSecurityTest` (`async: false`): 13 tests for skill-executor injection safety (argument escaping, shell-command injection attempts) and sandbox routing (skill commands go through `EvoGit.Sandbox`). Runs as part of the default `mix test` suite.
