# Skills Tests

## Intent
ExUnit tests for the skills subsystem (`EvoGit.Skills` — executor, CRUD, context integration, skill definition). Covers injection safety and sandbox routing of skill execution.

## Routing Table

None — leaf directory.

## API Surface

- `executor_security_test.exs` — `EvoGit.Skills.ExecutorSecurityTest` (`async: false`): 13 tests for skill-executor injection safety (argument escaping, shell-command injection attempts) and sandbox routing (skill commands go through `EvoGit.Sandbox`). Moved here from `lib/evo_git/skills/` so it runs in the default `mix test` suite.

## Notes for Agents

- The skills security test was moved from `lib/evo_git/skills/executor_security_test.exs` (where it was NOT part of `mix test`) into the test tree. `git log --follow` tracks its history.
