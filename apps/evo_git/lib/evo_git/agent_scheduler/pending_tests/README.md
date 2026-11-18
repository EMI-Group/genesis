# Pending test artifacts (hand-off, not source)

These four ExUnit files are the P2-B scheduler-half test layer, authored and verified green against the committed source of this node (69 tests, 0 failures).
They live here only because `apps/evo_git/test/**` is a SIBLING node: the writing agent's scope was this directory, so the files could not be installed in place.
Nothing under `lib/` compiles `.exs`, so their presence here is inert for `mix compile` and `mix format` (they are formatted).

Install them with:

```
git mv apps/evo_git/lib/evo_git/agent_scheduler/pending_tests/resume_plan_test.exs apps/evo_git/test/evo_git/agent_scheduler/resume_plan_test.exs
cp apps/evo_git/lib/evo_git/agent_scheduler/pending_tests/pause_resume_dispatch_test.exs apps/evo_git/test/evo_git/agent_scheduler/pause_resume_dispatch_test.exs
cp apps/evo_git/lib/evo_git/agent_scheduler/pending_tests/agent_identity_test.exs apps/evo_git/test/evo_git/agent_scheduler/agent_identity_test.exs
cp apps/evo_git/lib/evo_git/agent_scheduler/pending_tests/worktrees_test.exs apps/evo_git/test/evo_git/agent_scheduler/worktrees_test.exs
```

`resume_plan_test.exs` is NEW; the other three REPLACE the existing files of the same name (they encode the previous behaviour and fail against the current source).
Delete this directory once the four files are installed.
