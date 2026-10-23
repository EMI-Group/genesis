defmodule EvoGit.Agent.Compression.Recency do
  @moduledoc """
  Single source of truth for "which messages belong to the last K turns".

  Both compression stages need the SAME recency boundary — the model-free
  tool-result pruner (`EvoGit.Agent.Compression.ToolResultPruner`) may only
  touch messages OLDER than it, and the LLM checkpoint
  (`EvoGit.Agent.Compression.Checkpoint`) may only replace the span OLDER than
  it. Keeping the rule in one module guarantees the two stages can never
  disagree about what "recent work" means.

  ## The rule

  Messages carry their turn number in `metadata[:turn]` (stamped by
  `EvoGit.Agent.ContextBuilder.tag_message_turn/2`). The last `keep` DISTINCT
  turns are protected: every message whose turn is greater than
  `max_turn - keep` is recent.

  Because some messages legitimately carry no turn tag (tool results appended
  mid-turn, timestamp-only nudges), the turn-based boundary is combined with a
  positional floor of the last `2 * keep` messages: `boundary/2` always returns
  the SMALLER (earlier) of the two indexes, i.e. it protects MORE, never less.
  When no message carries a turn tag at all, the positional floor alone
  applies.

  The boundary is a single index, so the protected region is a contiguous
  suffix — a pruner/checkpoint can never punch a hole in the middle of the
  conversation.
  """

  alias ReqLLM.Message

  @default_keep_recent_turns 4

  @doc """
  The default recency window (in turns) kept intact by both stages.
  """
  @spec default_keep_recent_turns() :: pos_integer()
  def default_keep_recent_turns, do: @default_keep_recent_turns

  @doc """
  The turn number stamped into a message's metadata, or `nil` when the message
  carries no usable integer turn tag. Total — never raises.
  """
  @spec turn_of(term()) :: non_neg_integer() | nil
  def turn_of(%Message{metadata: metadata}) when is_map(metadata) do
    case Map.get(metadata, :turn) do
      turn when is_integer(turn) and turn >= 0 -> turn
      _ -> nil
    end
  end

  def turn_of(%Message{}), do: nil
  def turn_of(_), do: nil

  @doc """
  Index of the FIRST message in the protected (recent) suffix.

  Everything at an index `>= boundary/2` is recent and must be left untouched;
  everything below it is "old" and fair game for pruning/span replacement.
  Returns the list length when the whole list is recent (nothing is old).
  """
  @spec boundary([Message.t()] | list(), pos_integer()) :: non_neg_integer()
  def boundary(messages, keep \\ @default_keep_recent_turns)

  def boundary(messages, keep) when is_list(messages) and is_integer(keep) and keep > 0 do
    count = length(messages)

    by_turn =
      case messages |> Enum.map(&turn_of/1) |> Enum.reject(&is_nil/1) do
        [] ->
          count

        turns ->
          cutoff = Enum.max(turns) - keep

          messages
          |> Enum.with_index()
          |> Enum.find_value(count, fn {message, index} ->
            case turn_of(message) do
              turn when is_integer(turn) and turn > cutoff -> index
              _ -> nil
            end
          end)
      end

    positional = max(count - 2 * keep, 0)
    min(by_turn, positional)
  end
end
