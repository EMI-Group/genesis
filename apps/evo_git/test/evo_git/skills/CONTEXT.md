# Skills Tests

## Intent
ExUnit tests for the skills executor's injection safety and sandbox routing. Covers positional-parameter substitution (values passed as argv, never inlined into shell scripts) and the full `EvoGit.Skills.Executor.execute/4` path (skill commands route through `EvoGit.Sandbox`; in test env the sandbox is disabled → plain bash).

## Routing Table

None — leaf directory.

## API Surface

- `executor_security_test.exs` — `EvoGit.Skills.ExecutorSecurityTest` (`async: false`, 13 tests): skill-executor injection safety + sandbox routing. Three describe blocks:
  - `substitute_params/3 (legacy raw substitution)` — pins the legacy behavior: values inlined verbatim (byte-for-byte, NOT execution-safe, shell metacharacters pass through).
  - `build_positional_script/3` — the injection-safe substitution scheme: double-quoted positional `$1`-style references, 1-indexed in parameters order, all placeholder occurrences replaced, defaults / empty-string fallbacks.
  - `Executor.execute/4 injection resistance (full path)` — end-to-end through real bash: semicolon / backtick / `$()` / quote+metacharacter payloads pass through as literal data and cannot delete sentinel files or create marker files.

  Runs as part of the default `mix test` suite.
