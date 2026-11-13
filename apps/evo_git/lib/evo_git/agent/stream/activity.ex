defmodule EvoGit.Agent.Stream.Activity do
  @moduledoc """
  Pure, replaceable live activity projection, independent of publication and batching.

  A call keeps only its current text and thinking, never a replay of earlier attempts.
  Phase changes publish a replacement `{:activity, projection}`; matching chunks append to
  the projection and publish the existing text/thinking delta vocabulary instead.
  """

  @phases [:idle, :llm_waiting, :llm, :llm_complete, :retry_wait, :tools]

  @type phase :: :idle | :llm_waiting | :llm | :llm_complete | :retry_wait | :tools
  @type call :: %{
          id: String.t(),
          turn: non_neg_integer(),
          attempt: non_neg_integer(),
          text: String.t(),
          thinking: String.t()
        }
  @type t :: %{phase: phase(), current_call: call() | nil}

  @doc "An idle projection with no current call."
  @spec new() :: t()
  def new, do: %{phase: :idle, current_call: nil}

  @doc "Applies an internal event, returning the projection and its public events."
  @spec apply(t(), term()) :: {t(), [term()]}
  def apply(activity, event)

  def apply(activity, {:start_call, id, turn, attempt}) when is_binary(id) do
    replace(%{
      activity
      | phase: :llm_waiting,
        current_call: %{id: id, turn: turn, attempt: attempt, text: "", thinking: ""}
    })
  end

  def apply(%{current_call: %{id: id}} = activity, {:call_phase, id, phase})
      when phase in @phases do
    current_call = if phase in [:retry_wait, :idle], do: nil, else: activity.current_call
    replace(%{activity | phase: phase, current_call: current_call})
  end

  def apply(activity, {:phase, phase}) when phase in @phases do
    current_call = if phase == :idle, do: nil, else: activity.current_call
    replace(%{activity | phase: phase, current_call: current_call})
  end

  def apply(%{current_call: %{id: id} = call} = activity, {:chunk, id, kind, chunk})
      when kind in [:text, :thinking] and is_binary(chunk) do
    call = Map.update!(call, kind, &(&1 <> chunk))
    {%{activity | current_call: call}, [{kind, chunk}]}
  end

  def apply(_activity, :reset), do: replace(new())
  def apply(activity, _event), do: {activity, []}

  defp replace(activity), do: {activity, [{:activity, activity}]}
end
