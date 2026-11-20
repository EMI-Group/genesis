defmodule EvoDashWeb.AgentsLive.AgentList do
  @moduledoc """
  Pure agent-list primitives for the Agents page.
  It exists so the inspector path and (later) the merge path stop repeating
  O(n) id scans over the same agent list.
  The per-flush index used by the merge machinery comes from `by_id/1` plus
  `positions/1`.
  Every function is TOTAL: a `nil` or non-list `agents` value is handled
  without raising, and rows whose `:id` is not an integer are skipped.
  """

  @doc """
  Maps each integer agent id to its agent row.
  """
  @spec by_id([map()] | term()) :: %{optional(integer()) => map()}
  def by_id(agents) when is_list(agents) do
    Enum.reduce(agents, %{}, fn
      %{id: id} = agent, acc when is_integer(id) -> Map.put(acc, id, agent)
      _row, acc -> acc
    end)
  end

  def by_id(_agents), do: %{}

  @doc """
  Maps each integer agent id to its 0-based position in the list.
  """
  @spec positions([map()] | term()) :: %{optional(integer()) => non_neg_integer()}
  def positions(agents) when is_list(agents) do
    agents
    |> Enum.with_index()
    |> Enum.reduce(%{}, fn
      {%{id: id}, index}, acc when is_integer(id) -> Map.put(acc, id, index)
      {_row, _index}, acc -> acc
    end)
  end

  def positions(_agents), do: %{}

  @doc """
  The agent row whose id equals `id`, else `nil`.
  """
  @spec find([map()] | term(), term()) :: map() | nil
  def find(agents, id) when is_list(agents), do: Enum.find(agents, &(&1.id == id))

  def find(_agents, _id), do: nil

  @doc """
  Replaces the FIRST row whose id equals `id` with `fun.(row)`, leaving an
  unknown id (and any non-list input) unchanged.
  """
  @spec update([map()] | term(), term(), (map() -> map())) :: [map()] | term()
  def update(agents, id, updater_fn) when is_list(agents) do
    idx = Enum.find_index(agents, fn a -> a.id == id end)

    if idx do
      List.replace_at(agents, idx, updater_fn.(Enum.at(agents, idx)))
    else
      agents
    end
  end

  def update(agents, _id, _updater_fn), do: agents
end
