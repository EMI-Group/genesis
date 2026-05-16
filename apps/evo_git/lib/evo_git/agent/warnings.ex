defmodule EvoGit.Agent.Warnings do
  @moduledoc """
  Budget warning thresholds and messages for the agent loop.

  Each threshold is a `{percent, message_fn}` tuple where `message_fn.(pct, state)`
  returns the warning string to inject into the agent's context.
  """

  @doc """
  Returns the ordered list of `{threshold_percent, message_fn}` pairs for time-budget warnings.
  `timeout_ms` is the configured time limit for the agent session.
  """
  def time_thresholds(timeout_ms) do
    [
      {25,
       fn pct, state ->
         time_used_min = Float.round(state.llm_time_ms / 60_000, 1)
         time_limit_min = Float.round(timeout_ms / 60_000, 1)

         """
         [NOTICE] You have used approximately #{pct}% of your time budget \
         (#{time_used_min} / #{time_limit_min} minutes).
         Are you doing all the work yourself? Consider delegating to subagents instead — \
         spawning subagents for independent subtasks lets them run concurrently and keeps \
         your own context lean.
         """
       end},
      {50,
       fn pct, state ->
         time_used_min = Float.round(state.llm_time_ms / 60_000, 1)
         time_limit_min = Float.round(timeout_ms / 60_000, 1)

         """
         [NOTICE] You have used approximately #{pct}% of your time budget \
         (#{time_used_min} / #{time_limit_min} minutes).
         Consider accelerating your work by focusing on the most critical aspects of the task, \
         and make good use of subagents to let them do the work for you.
         You don't need to complete everything, it's ok to complete only the most important parts and report the situation.
         """
       end},
      {80,
       fn pct, state ->
         time_used_min = Float.round(state.llm_time_ms / 60_000, 1)
         time_limit_min = Float.round(timeout_ms / 60_000, 1)

         """
         [URGENT] You have used approximately #{pct}% of your time budget \
         (#{time_used_min} / #{time_limit_min} minutes).

         STOP working on new tasks. Focus on finishing what you have at hand:
         1. Commit any file changes you have made
         2. Call complete_task as soon as possible

         In your completion message, explain:
         - What has been accomplished
         - What hasn't been done due to the time limit

         You do NOT need to complete everything. A partial completion with clear report is acceptable.
         """
       end}
    ]
  end

  @doc """
  Returns the ordered list of `{threshold_percent, message_fn}` pairs for turn-budget warnings.
  """
  def turn_thresholds(max_turns) do
    [
      {25,
       fn pct, state ->
         """
         [NOTICE] You have used approximately #{pct}% of your available turns \
         (#{state.turn} / #{max_turns}).
         Are you doing all the work yourself? Consider delegating to subagents instead — \
         spawning subagents for independent subtasks lets them run concurrently and keeps \
         your own context lean.
         """
       end},
      {50,
       fn pct, state ->
         """
         [NOTICE] You have used approximately #{pct}% of your available turns \
         (#{state.turn} / #{max_turns}).
         Consider accelerating your work by focusing on the most critical aspects of the task, \
         and make good use of subagents to let them do the work for you.
         You don't need to complete everything, it's ok to complete only the most important parts and report the situation.
         """
       end},
      {80,
       fn pct, state ->
         """
         [URGENT] You have used approximately #{pct}% of your available turns \
         (#{state.turn} / #{max_turns}).

         STOP working on new tasks. Focus on finishing what you have at hand:
         1. Commit any file changes you have made
         2. Call complete_task as soon as possible

         In your completion message, explain:
         - What has been accomplished
         - What hasn't been done due to the turn limit

         You do NOT need to complete everything. A partial completion with clear report is acceptable.
         """
       end}
    ]
  end
end
