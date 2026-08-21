defmodule EvoDashWeb.HomeLive.AgentStream do
  @moduledoc """
  Pure helpers for tracking the reflect task's root agent stream and extracting
  the final result.
  """

  @doc """
  Returns the first agent summary whose `:task_id` matches `task_id`,
  preferring `EvoGit.Agents.SelfReflective` summaries when several match.
  `nil` when nothing matches. Never raises.
  """
  @spec find_root_agent([map()] | nil, String.t() | nil) :: map() | nil
  def find_root_agent(agents, task_id) when is_list(agents) do
    matching =
      Enum.filter(agents, fn agent ->
        is_map(agent) and Map.get(agent, :task_id) == task_id
      end)

    case Enum.find(matching, &(Map.get(&1, :agent_module) == EvoGit.Agents.SelfReflective)) do
      nil -> List.first(matching)
      agent -> agent
    end
  end

  def find_root_agent(_agents, _task_id), do: nil

  @doc "Returns the agent's `:message_count` as a non-negative integer (0 when absent)."
  @spec message_count(map() | nil) :: non_neg_integer()
  def message_count(agent) when is_map(agent), do: Map.get(agent, :message_count, 0) || 0
  def message_count(_agent), do: 0

  @doc """
  HistoryGate-style gating: returns `true` when the agent's message count moved
  from `prev_count`. Only refetch history when the count changed.
  """
  @spec changed?(non_neg_integer() | nil, map() | nil) :: boolean()
  def changed?(prev_count, agent), do: message_count(agent) != (prev_count || 0)

  @doc """
  Extracts the task id from the `{:ok, map}` returned by
  `EvoDash.NodeContext.start_task/3`. Accepts both `:id` and `"id"` key shapes;
  the map may also be nil. Never raises.
  """
  @spec task_id_from_start({:ok, map()} | any()) :: {:ok, String.t()} | {:error, :no_task_id}
  def task_id_from_start({:ok, map}) when is_map(map) do
    case Map.get(map, :id) || Map.get(map, "id") do
      id when is_binary(id) and id != "" -> {:ok, id}
      _ -> {:error, :no_task_id}
    end
  end

  def task_id_from_start(_result), do: {:error, :no_task_id}

  @doc """
  Extracts the final assistant text from a decoded `%EvoGit.TaskInfo{}` result
  field (the Store codec reconstructs native tuples with atom keys, e.g.
  `{:ok, %{result: <text>, commit_sha: nil, ...}}`). Handles both `:result` and
  `"result"` key shapes; returns `:empty` when the task succeeded without a
  text result and `:error` for failures and anything else. Never raises.
  """
  @spec extract_final_text(term()) :: {:ok, String.t()} | :empty | :error
  def extract_final_text({:ok, %{result: text}}) when is_binary(text) and text != "",
    do: {:ok, text}

  def extract_final_text({:ok, %{"result" => text}}) when is_binary(text) and text != "",
    do: {:ok, text}

  def extract_final_text({:ok, _result}), do: :empty
  def extract_final_text({:error, _reason}), do: :error
  def extract_final_text({:exit, _reason}), do: :error
  def extract_final_text(_result), do: :error
end
