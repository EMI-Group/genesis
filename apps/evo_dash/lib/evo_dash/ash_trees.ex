defmodule EvoDash.AshTrees do
  @moduledoc """
  Persistent "ash trees" — dimmed snapshots of finished tasks' agent trees.

  A GenServer subscribed to the `"agents"` PubSub topic keeps a mirror of the
  scheduler's agent list. Whenever a task loses its last agent (i.e. the task
  finished), its final tree is appended to an on-disk store
  (`<config_dir>/ash_trees.etf`). Completed trees therefore survive page
  reloads and server restarts, and only disappear when the user explicitly
  closes an ash tab (`dismiss/1`) — never on their own.

  Note: only tasks finished *after* this process runs can be captured; there
  is no historical agent-structure data to reconstruct older trees from.
  """

  use GenServer

  @agents_topic "agents"
  @ash_topic "ash_trees"

  # ── Public API ────────────────────────────────────────────────────────────

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc "All persisted ash trees, oldest first."
  def list do
    case File.read(store_path()) do
      {:ok, bin} ->
        try do
          :erlang.binary_to_term(bin)
        rescue
          _ -> []
        end

      {:error, _} ->
        []
    end
  end

  @doc "Appends or replaces an ash snapshot (used by demo seeding)."
  def put(entry) do
    save(Enum.reject(list(), &(&1.task_id == entry.task_id)) ++ [entry])
    :ok
  end

  @doc "Removes an ash tree from the store (the only sanctioned deletion)."
  def dismiss(task_id) do
    if Process.whereis(__MODULE__) do
      GenServer.call(__MODULE__, {:dismiss, task_id})
    else
      save(Enum.reject(list(), &(&1.task_id == task_id)))
      :ok
    end
  end

  # ── GenServer ─────────────────────────────────────────────────────────────

  @impl true
  def init(_opts) do
    Phoenix.PubSub.subscribe(EvoGit.PubSub, @agents_topic)
    {:ok, %{mirror: union_mirror(current_agents())}}
  end

  @impl true
  def handle_call({:dismiss, task_id}, _from, state) do
    save(Enum.reject(list(), &(&1.task_id == task_id)))
    {:reply, :ok, state}
  end

  @impl true
  def handle_info(_any_agent_event, state) do
    now = current_agents()
    now_task_ids = MapSet.new(now, & &1.task_id)
    known_ash_ids = MapSet.new(list(), & &1.task_id)

    # Merge the current snapshot into the per-task union so nodes that
    # existed at ANY point are retained (not just the final ones).
    mirror =
      Enum.reduce(now, state.mirror, fn a, acc ->
        case a.task_id do
          nil -> acc
          task_id -> put_in(acc, [task_id, a.id], slim(a))
        end
      end)

    {archived_task_ids, mirror} = Map.split(mirror, Map.keys(mirror) -- MapSet.to_list(now_task_ids))

    new_ash =
      archived_task_ids
      |> Enum.reject(fn {task_id, _} -> MapSet.member?(known_ash_ids, task_id) end)
      |> Enum.map(fn {task_id, agents_by_id} ->
        to_ash(task_id, Map.values(agents_by_id))
      end)

    if new_ash != [] do
      save(list() ++ new_ash)
      Phoenix.PubSub.broadcast(EvoGit.PubSub, @ash_topic, {:ash_updated})
    end

    {:noreply, %{state | mirror: mirror}}
  end

  # ── Internals ─────────────────────────────────────────────────────────────

  defp union_mirror(agents) do
    Map.new(agents, fn a -> {a.task_id, %{a.id => slim(a)}} end)
    |> Map.delete(nil)
  end

  defp current_agents do
    EvoGit.AgentScheduler.RemoteAPI.list_agents()
  rescue
    _ -> []
  catch
    :exit, _ -> []
  end

  defp to_ash(task_id, members) do
    root = Enum.find(members, &is_nil(&1.parent_id)) || hd(members)

    %{
      task_id: task_id,
      task_number: Map.get(root, :task_number) || task_id,
      label: ash_label(root),
      size: length(members),
      agents:
        Enum.map(members, fn a ->
          a |> Map.put(:live_status, a.status) |> Map.put(:status, "ash")
        end)
    }
  end

  defp ash_label(agent) do
    objective = (Map.get(agent, :objective) || "") |> String.trim()

    cond do
      objective == "" -> to_string(Map.get(agent, :task_local_id) || Map.get(agent, :id))
      String.length(objective) > 18 -> String.slice(objective, 0, 18) <> "…"
      true -> objective
    end
  end

  # Keep only what the graph payload needs.
  defp slim(a) do
    Map.take(a, [
      :id,
      :parent_id,
      :task_id,
      :task_number,
      :task_local_id,
      :status,
      :depth,
      :agent_module,
      :objective
    ])
  end

  defp store_path do
    Application.get_env(:evo_dash, :ash_trees_path) ||
      Path.join(EvoGit.Config.config_dir(), "ash_trees.etf")
  end

  defp save(ash_trees) do
    path = store_path()
    File.mkdir_p!(Path.dirname(path))
    File.write!(path, :erlang.term_to_binary(ash_trees))
  end
end
