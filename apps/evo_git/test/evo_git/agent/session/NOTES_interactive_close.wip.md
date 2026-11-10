WIP DRAFT — NOT COMPILED BY EXUNIT (.wip suffix).
Both invariants (c) and (g) currently FAIL right after the yield arrives:
they reach {:agent_session_yield, ...} and then await_phase(pid, :awaiting_input) returns nil,
with a "WorktreeManager: Failed to delete branch evogit-agent-T1-A1" warning in the log, i.e. the
session leaves :awaiting_input (and the worktree is reclaimed) before the bounded inspect poll sees it.
