defmodule EvoGit.Agent.TurnWarning do
  @moduledoc """
  Adaptive turn-budget warning system for the agent loop.

  Uses a hybrid model combining **relative progress thresholds** (for early-stage
  guidance) and **absolute countdown thresholds** (for near-limit urgency), plus a
  **periodic middle reminder** that scales naturally with any budget size.

  ## Warning Categories

  Two independent tracks:

  ### Positional (monotonic — each fires at most once per agent run)

  | Level | Purpose | Trigger |
  |-------|---------|---------|
  | `:beginning` | Early-stage delegation guidance | ~25% of budget (min 6 turns) |
  | `:end` | Wrap up and prepare to complete | ≤ N turns remaining (adaptive) |
  | `:critical` | Call complete_task immediately | ≤ M turns remaining (adaptive) |

  ### Periodic (fires repeatedly)

  | Level | Purpose | Trigger |
  |-------|---------|---------|
  | `:middle` | Periodic delegation reminder | `turns_since_subagent` ≥ 15 |

  The `:middle` warning is NOT monotonic — it fires repeatedly. It only fires when
  no positional warning fires that turn (positional warnings take priority). The
  counter resets to 0 each time it fires, and also resets when a subagent call is made.

  The end and critical countdowns scale with `max_turns`:
  - Large budgets (≥ ~60 turns): 10-turn end, 3-turn critical.
  - Smaller budgets: proportionally shorter countdowns with minimum floors
    (3 turns for end, 1 turn for critical).
  """

  @min_beginning_turn 6
  @near_limit_turns 10
  @near_limit_floor 3
  @critical_turns 3
  @critical_floor 1
  @middle_interval 15
  @middle_interval_low 45   # for :low agents (3x less frequent)

  defstruct [:level, :turn, :turns_remaining, :max_turns, :percent_used, :turns_since_subagent]

  @type level :: :beginning | :middle | :end | :critical
  @type t :: %__MODULE__{
          level: level(),
          turn: non_neg_integer(),
          turns_remaining: non_neg_integer(),
          max_turns: pos_integer(),
          percent_used: non_neg_integer(),
          turns_since_subagent: non_neg_integer() | nil
        }

  @doc """
  Determines the highest applicable positional warning level for the current turn.

  Only checks `:beginning`, `:end`, and `:critical` (NOT `:middle`, which is
  handled separately via `check_middle/4`).

  Returns `:none` if no positional warning level applies yet.

  ## Examples

      iex> EvoGit.Agent.TurnWarning.current_positional_level(0, 128)
      :none

      iex> EvoGit.Agent.TurnWarning.current_positional_level(32, 128)
      :beginning

      iex> EvoGit.Agent.TurnWarning.current_positional_level(125, 128)
      :critical
  """
  @spec current_positional_level(non_neg_integer(), pos_integer(), :high | :low) :: level() | :none
  def current_positional_level(turn, max_turns, delegation_level \\ :high) do
    turns_remaining = max_turns - turn
    percent_used = div(turn * 100, max_turns)

    near_remaining = end_remaining(max_turns)
    critical_remaining = critical_remaining(max_turns)

    cond do
      turns_remaining <= critical_remaining -> :critical
      turns_remaining <= near_remaining -> :end
      delegation_level == :high and percent_used >= 25 and turn >= @min_beginning_turn -> :beginning
      true -> :none
    end
  end

  @doc """
  Checks whether a **new** (escalated) positional warning should fire at this turn.

  Returns `{:ok, %__MODULE__{}}` if the current positional level is higher than the
  last warned level, or `:none` otherwise. Each positional level fires at most once
  per agent run — the caller tracks `last_warned_level` to prevent duplicates.
  """
  @spec check_positional(non_neg_integer(), pos_integer(), level() | :none, :high | :low) ::
          {:ok, t()} | :none
  def check_positional(turn, max_turns, last_level, delegation_level \\ :high) do
    level = current_positional_level(turn, max_turns, delegation_level)

    if level != :none and level_index(level) > level_index(last_level) do
      {:ok, build(level, turn, max_turns)}
    else
      :none
    end
  end

  @doc """
  Checks whether the periodic middle warning should fire.

  The middle warning is NOT monotonic — it fires every time `turns_since_subagent`
  reaches the interval threshold. It does not fire if `turn` is less than 1, or if
  there is not enough budget remaining for delegation to be meaningful.

  Returns `{:ok, %__MODULE__{}}` if the warning should fire, or `:none`.
  """
  @spec check_middle(non_neg_integer(), pos_integer(), non_neg_integer(), :high | :low) ::
          {:ok, t()} | :none
  def check_middle(turn, max_turns, turns_since_subagent, delegation_level \\ :high) do
    if turn < 1 do
      :none
    else
      interval = middle_interval(delegation_level)
      if turns_since_subagent >= interval do
        {:ok, build_middle(turn, max_turns, turns_since_subagent)}
      else
        :none
      end
    end
  end

  @doc """
  Returns the warning message string for the given warning struct.
  """
  @spec message(t()) :: String.t()
  def message(%__MODULE__{} = warning), do: message_for_level(warning)

  # --- Internals ---

  # Adaptive end countdown: 10 turns for large budgets, scales down
  # for smaller ones, with a floor of 3 turns remaining.
  defp end_remaining(max_turns) do
    min(@near_limit_turns, max(@near_limit_floor, div(max_turns, 6)))
  end

  # Adaptive critical countdown: 3 turns for large budgets, scales down
  # for smaller ones, with a floor of 1 turn remaining.
  defp critical_remaining(max_turns) do
    min(@critical_turns, max(@critical_floor, div(max_turns, 30)))
  end

  @level_order %{:none => 0, :beginning => 1, :end => 2, :critical => 3}

  defp level_index(level), do: Map.fetch!(@level_order, level)

  defp middle_interval(:high), do: @middle_interval
  defp middle_interval(:low), do: @middle_interval_low

  defp build(level, turn, max_turns) do
    %__MODULE__{
      level: level,
      turn: turn,
      turns_remaining: max_turns - turn,
      max_turns: max_turns,
      percent_used: div(turn * 100, max_turns),
      turns_since_subagent: nil
    }
  end

  defp build_middle(turn, max_turns, turns_since_subagent) do
    %__MODULE__{
      level: :middle,
      turn: turn,
      turns_remaining: max_turns - turn,
      max_turns: max_turns,
      percent_used: div(turn * 100, max_turns),
      turns_since_subagent: turns_since_subagent
    }
  end

  defp message_for_level(%__MODULE__{level: :beginning} = w) do
    """
    [NOTICE] Turn #{w.turn}/#{w.max_turns} (#{w.percent_used}% used). #{w.turns_remaining} turns remaining.

    You are a high-level agent in EvoGit's recursive hierarchy. Your role is to ORGANIZE, not to do the work yourself:
    1. Check your routing table — where does the objective belong? Identify the deepest correct child node.
    2. Delegate IMMEDIATELY to a subagent at that node. Do NOT investigate the child subtree yourself first — the subagent has its own routing table and will navigate faster than you.
    3. Reserve your own turns for coordination, review, and integration. Subagent work runs in isolated worktrees and does NOT count against your turn budget.

    Remember: delegating is an investment that always pays off. If the target turns out wrong, the subagent returns early — you lose nothing.
    """
  end

  defp message_for_level(%__MODULE__{level: :middle} = w) do
    """
    [NOTICE] Turn #{w.turn}/#{w.max_turns}. #{w.turns_since_subagent} turns have passed since your last subagent delegation.

    #{if w.turns_since_subagent >= 10, do: "You've been working solo for a while — if you're doing investigation or implementation that a subagent could handle, you may be over-investing your own budget. ", else: ""}
    If you have unblocked work that belongs in a child subtree, delegate it now — the subagent works at a more correct level with its own context. Spawning a subagent resets this reminder.
    """
  end

  defp message_for_level(%__MODULE__{level: :end} = w) do
    """
    [WARNING] Turn #{w.turn}/#{w.max_turns} — only #{w.turns_remaining} #{turn_word(w.turns_remaining)} remaining.

    You are approaching the end of your turn budget. Shift focus to wrapping up:
    1. Commit any uncommitted changes you have made
    2. If critical work remains, delegate it to subagents for parallel completion
    3. Prepare to call complete_task with a clear status report

    A partial completion with a clear explanation of what remains is perfectly acceptable.
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
