defmodule EvoGit.Agent.Exchange.Warnings do
  @moduledoc """
  The adaptive turn-limit warning cadence.

  Pure: no scheduler, no ETS and no seams. `check_limit_warnings/1` only reads
  the struct and appends a turn-tagged warning message to the conversation —
  exactly one warning per turn boundary, positional first and the periodic
  middle reminder second (see `EvoGit.Agent.TurnWarning` for the thresholds and
  message text).
  """

  alias EvoGit.Agent.State

  import ReqLLM.Context, only: [user: 1]

  @doc """
  Checks and sends turn-limit warnings via the adaptive TurnWarning module.

  See `EvoGit.Agent.TurnWarning` for threshold logic and message generation.
  """
  @spec check_limit_warnings(State.t()) :: State.t()
  def check_limit_warnings(%State{} = state) do
    # Pure process-dictionary read (no git call): the snapshot is refreshed at the
    # END of every turn by `EvoGit.Agent.ConflictState`.
    in_conflict = EvoGit.Agent.ConflictState.in_conflict?()

    case EvoGit.Agent.TurnWarning.check_positional(
           state.turn,
           state.max_turns,
           state.last_warned_level,
           state.delegation_level,
           in_conflict: in_conflict
         ) do
      {:ok, warning} ->
        msg = EvoGit.Agent.TurnWarning.message(warning)
        warning_msg = EvoGit.Agent.ContextBuilder.tag_message_turn(user(msg), state.turn)
        new_context = ReqLLM.Context.append(state.context, warning_msg)
        %{state | context: new_context, last_warned_level: warning.level}

      :none ->
        case EvoGit.Agent.TurnWarning.check_middle(
               state.turn,
               state.max_turns,
               state.turns_since_subagent,
               state.delegation_level,
               in_conflict: in_conflict
             ) do
          {:ok, warning} ->
            msg = EvoGit.Agent.TurnWarning.message(warning)
            warning_msg = EvoGit.Agent.ContextBuilder.tag_message_turn(user(msg), state.turn)
            new_context = ReqLLM.Context.append(state.context, warning_msg)
            %{state | context: new_context, turns_since_subagent: 0}

          :none ->
            state
        end
    end
  end
end
