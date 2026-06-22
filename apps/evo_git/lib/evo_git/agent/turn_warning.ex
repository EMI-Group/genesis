defmodule EvoGit.Agent.TurnWarning do
  @moduledoc """
  Adaptive turn-budget warning system for the agent loop.

  Unlike pure percentage-based thresholds, this module uses a hybrid model that
  combines **relative progress thresholds** (for early/mid-budget behavioural
  guidance) and **absolute countdown thresholds** (for near-limit urgency).
  This ensures warning behaviour is consistent and useful regardless of the
  `max_turns` setting.

  ## Warning Levels

  Levels escalate monotonically — each fires at most once per agent run:

  | Level | Purpose | Trigger |
  |-------|---------|---------|
  | `:nudge` | Encourage delegation | ~25% of budget (min 6 turns) |
  | `:accelerate` | Focus on critical work | ~50% of budget (min 8 turns) |
  | `:near_limit` | Wrap up and prepare to complete | ≤ N turns remaining (adaptive) |
  | `:critical` | Call complete_task immediately | ≤ M turns remaining (adaptive) |

  The near-limit and critical countdowns scale with `max_turns`:
  - Large budgets (≥ ~60 turns): 10-turn near-limit, 3-turn critical.
  - Smaller budgets: proportionally shorter countdowns with minimum floors
    (3 turns for near-limit, 1 turn for critical).

  This means a 128-turn agent gets the same 10-turn countdown as a 64-turn
  agent, while a 16-turn agent gets a compressed 3-turn countdown — preventing
  the near-limit warning from firing before behavioural warnings.
  """

  @min_nudge_turn 6
  @min_accelerate_turn 8
  @near_limit_turns 10
  @near_limit_floor 3
  @critical_turns 3
  @critical_floor 1

  defstruct [:level, :turn, :turns_remaining, :max_turns, :percent_used]

  @type level :: :nudge | :accelerate | :near_limit | :critical
  @type t :: %__MODULE__{
          level: level(),
          turn: non_neg_integer(),
          turns_remaining: non_neg_integer(),
          max_turns: pos_integer(),
          percent_used: non_neg_integer()
        }

  @doc """
  Determines the highest applicable warning level for the current turn.

  Returns `:none` if no warning level applies yet.

  ## Examples

      iex> EvoGit.Agent.TurnWarning.current_level(0, 128)
      :none

      iex> EvoGit.Agent.TurnWarning.current_level(32, 128)
      :nudge

      iex> EvoGit.Agent.TurnWarning.current_level(125, 128)
      :critical
  """
  @spec current_level(non_neg_integer(), pos_integer()) :: level() | :none
  def current_level(turn, max_turns) do
    turns_remaining = max_turns - turn
    percent_used = div(turn * 100, max_turns)

    near_remaining = near_limit_remaining(max_turns)
    critical_remaining = critical_remaining(max_turns)

    cond do
      turns_remaining <= critical_remaining -> :critical
      turns_remaining <= near_remaining -> :near_limit
      percent_used >= 50 and turn >= @min_accelerate_turn -> :accelerate
      percent_used >= 25 and turn >= @min_nudge_turn -> :nudge
      true -> :none
    end
  end

  @doc """
  Checks whether a **new** (escalated) warning should fire at this turn.

  Returns `{:ok, %__MODULE__{}}` if the current level is higher than the last
  warned level, or `:none` otherwise. Each level fires at most once per agent
  run — the caller tracks `last_warned_level` to prevent duplicates.
  """
  @spec check(non_neg_integer(), pos_integer(), level() | :none) ::
          {:ok, t()} | :none
  def check(turn, max_turns, last_level) do
    level = current_level(turn, max_turns)

    if level != :none and level_index(level) > level_index(last_level) do
      {:ok, build(level, turn, max_turns)}
    else
      :none
    end
  end

  @doc """
  Returns the warning message string for the given warning struct.
  """
  @spec message(t()) :: String.t()
  def message(%__MODULE__{} = warning), do: message_for_level(warning)

  # --- Internals ---

  # Adaptive near-limit countdown: 10 turns for large budgets, scales down
  # for smaller ones, with a floor of 3 turns remaining.
  defp near_limit_remaining(max_turns) do
    min(@near_limit_turns, max(@near_limit_floor, div(max_turns, 6)))
  end

  # Adaptive critical countdown: 3 turns for large budgets, scales down
  # for smaller ones, with a floor of 1 turn remaining.
  defp critical_remaining(max_turns) do
    min(@critical_turns, max(@critical_floor, div(max_turns, 30)))
  end

  @level_order %{:none => 0, :nudge => 1, :accelerate => 2, :near_limit => 3, :critical => 4}

  defp level_index(level), do: Map.fetch!(@level_order, level)

  defp build(level, turn, max_turns) do
    %__MODULE__{
      level: level,
      turn: turn,
      turns_remaining: max_turns - turn,
      max_turns: max_turns,
      percent_used: div(turn * 100, max_turns)
    }
  end

  defp message_for_level(%__MODULE__{level: :nudge} = w) do
    """
    [NOTICE] Turn #{w.turn}/#{w.max_turns} (#{w.percent_used}% used). #{w.turns_remaining} turns remaining.

    You are starting to use a significant portion of your turn budget. \
    If you haven't already, consider delegating independent subtasks to subagents — \
    they run concurrently, keep your context lean, and their costs do not count \
    against your turn budget.
    """
  end

  defp message_for_level(%__MODULE__{level: :accelerate} = w) do
    """
    [NOTICE] Turn #{w.turn}/#{w.max_turns} (#{w.percent_used}% used). #{w.turns_remaining} turns remaining.

    You are past the halfway point of your turn budget. Prioritize the most \
    critical aspects of your objective and delegate aggressively to subagents. \
    It is acceptable to complete only the most important parts and report the \
    situation in your completion message.
    """
  end

  defp message_for_level(%__MODULE__{level: :near_limit} = w) do
    """
    [WARNING] Turn #{w.turn}/#{w.max_turns} — only #{w.turns_remaining} #{turn_word(w.turns_remaining)} remaining.

    You are approaching the turn limit. STOP starting new work and focus on \
    wrapping up:
    1. Commit any uncommitted changes you have made
    2. Call complete_task as soon as possible with a clear status report

    A partial completion with a clear explanation of what remains is perfectly \
    acceptable.
    """
  end

  defp message_for_level(%__MODULE__{level: :critical} = w) do
    """
    [URGENT] Turn #{w.turn}/#{w.max_turns} — only #{w.turns_remaining} #{turn_word(w.turns_remaining)} remaining!

    You are about to hit the turn limit. Call complete_task IMMEDIATELY.
    Do not start any new work. Commit if needed, then complete with your best answer.
    """
  end

  defp turn_word(1), do: "turn"
  defp turn_word(_), do: "turns"
end
