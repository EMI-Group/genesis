defmodule EvoGit.AssistantTaskLinks do
  @moduledoc "Volatile conversation task references and recent, single-execution card actions."
  use GenServer

  @max_conversations 100
  @max_tasks 20
  @max_finished_actions 100
  @max_open_actions 20
  @task_fields ~w(id type status project_path objective_summary started_at finished_at branch_name commit_sha review_status progress)a

  def start_link(opts),
    do: GenServer.start_link(__MODULE__, %{}, Keyword.put(opts, :name, __MODULE__))

  def follow(target, conversation, task)
      when target == node() and not is_nil(conversation) and is_map(task) do
    case Map.get(task, :id) || Map.get(task, "id") do
      id when is_binary(id) and id != "" ->
        GenServer.call(__MODULE__, {:follow, conversation, id, task})

      _ ->
        {:error, :invalid_task}
    end
  end

  def follow(_, _, _), do: {:error, :invalid_scope}

  def list(target, conversation) when target == node(),
    do: GenServer.call(__MODULE__, {:list, conversation})

  def list(_, _), do: {:error, :wrong_node}

  def claim_action(conversation, operation_id, payload),
    do:
      GenServer.call(
        __MODULE__,
        {:claim_action, conversation, operation_id, fingerprint(payload)}
      )

  def uncertain_action(conversation, operation_id),
    do: GenServer.call(__MODULE__, {:uncertain_action, conversation, operation_id})

  def finish_action(conversation, operation_id, result),
    do: GenServer.call(__MODULE__, {:finish_action, conversation, operation_id, result})

  def action_status(conversation, operation_id),
    do: GenServer.call(__MODULE__, {:action_status, conversation, operation_id})

  @impl true
  def init(_), do: {:ok, %{conversations: %{}}}

  @impl true
  def handle_call({:follow, conversation, id, task}, from, state) do
    if capacity?(state, conversation),
      do: follow_call(conversation, id, task, from, state),
      else: {:reply, {:error, :tracking_capacity}, state}
  end

  def handle_call({:list, conversation}, _, state),
    do: {:reply, entry(state, conversation).tasks, state}

  def handle_call({:claim_action, conversation, id, digest}, {caller, _}, state) do
    if capacity?(state, conversation),
      do: claim_call(conversation, id, digest, caller, state),
      else: {:reply, {:error, :tracking_capacity}, state}
  end

  def handle_call({:finish_action, conversation, id, result}, {caller, _}, state) do
    entry = entry(state, conversation)

    case Map.get(entry.actions, id) do
      %{owner: ^caller, status: :pending} = operation ->
        Process.demonitor(operation.monitor, [:flush])

        operation =
          operation
          |> Map.put(:status, :done)
          |> Map.put(:result, result)
          |> Map.drop([:owner, :monitor])

        actions = Map.put(entry.actions, id, operation) |> trim_actions()
        {:reply, :ok, put_entry(state, conversation, %{entry | actions: actions})}

      _ ->
        {:reply, {:error, :not_owner}, state}
    end
  end

  def handle_call({:uncertain_action, conversation, id}, {caller, _}, state) do
    entry = entry(state, conversation)

    case Map.get(entry.actions, id) do
      %{owner: ^caller, status: :pending} = operation ->
        Process.demonitor(operation.monitor, [:flush])
        operation = operation |> Map.put(:status, :unknown) |> Map.drop([:owner, :monitor])

        {:reply, :ok,
         put_entry(state, conversation, %{entry | actions: Map.put(entry.actions, id, operation)})}

      _ ->
        {:reply, {:error, :not_owner}, state}
    end
  end

  def handle_call({:action_status, conversation, id}, _, state) do
    status =
      case get_in(state, [:conversations, conversation, :actions, id]) do
        nil -> {:error, :not_found}
        %{status: :done, result: result} -> {:done, result}
        %{status: status} -> status
      end

    {:reply, status, state}
  end

  @impl true
  def handle_info({:DOWN, monitor, :process, _, _}, state) do
    conversations =
      Map.new(state.conversations, fn {id, entry} ->
        actions =
          Map.new(entry.actions, fn
            {operation_id, %{monitor: ^monitor} = operation} ->
              {operation_id,
               operation |> Map.put(:status, :unknown) |> Map.drop([:owner, :monitor])}

            pair ->
              pair
          end)

        {id, %{entry | actions: actions}}
      end)

    {:noreply, %{state | conversations: conversations}}
  end

  defp follow_call(conversation, id, task, _, state) do
    entry = entry(state, conversation)
    task = project_task(task, id)

    tasks =
      if Enum.any?(entry.tasks, &(&1.id == id)),
        do:
          Enum.map(entry.tasks, fn existing -> if existing.id == id, do: task, else: existing end),
        else: Enum.take([task | entry.tasks], @max_tasks)

    {:reply, :ok, put_entry(state, conversation, %{entry | tasks: tasks})}
  end

  defp claim_call(conversation, id, digest, caller, state) do
    entry = entry(state, conversation)

    case Map.get(entry.actions, id) do
      nil ->
        case Enum.find(entry.actions, fn {_, operation} ->
               operation.fingerprint == digest and operation.status in [:pending, :unknown]
             end) do
          {existing_id, %{status: status}} ->
            {:reply, {status, existing_id}, state}

          nil ->
            if Enum.count(entry.actions, fn {_, action} ->
                 action.status in [:pending, :unknown]
               end) >= @max_open_actions do
              {:reply, {:error, :action_capacity}, state}
            else
              operation = %{
                fingerprint: digest,
                status: :pending,
                owner: caller,
                monitor: Process.monitor(caller),
                sequence: System.unique_integer([:positive, :monotonic])
              }

              entry = %{entry | actions: Map.put(entry.actions, id, operation)}
              {:reply, :claimed, put_entry(state, conversation, entry)}
            end
        end

      %{fingerprint: other} when other != digest ->
        {:reply, {:error, :operation_mismatch}, state}

      %{status: :pending} ->
        {:reply, :pending, state}

      %{status: :unknown} ->
        {:reply, :unknown, state}

      %{status: :done, result: result} ->
        {:reply, {:done, result}, state}
    end
  end

  defp capacity?(state, conversation) do
    Map.has_key?(state.conversations, conversation) or
      map_size(state.conversations) < @max_conversations or
      Enum.any?(state.conversations, fn {_, item} -> not pinned?(item) end)
  end

  defp pinned?(entry),
    do: Enum.any?(entry.actions, fn {_, action} -> action.status in [:pending, :unknown] end)

  defp entry(state, conversation),
    do: Map.get(state.conversations, conversation, %{tasks: [], actions: %{}, touched: 0})

  defp put_entry(state, conversation, entry) do
    entry = %{entry | touched: System.unique_integer([:positive, :monotonic])}
    conversations = Map.put(state.conversations, conversation, entry)
    # Keep pending/uncertain executions until their caller settles them; dropping
    # their identity could turn a reconnect into a duplicate side effect.
    removable =
      conversations
      |> Enum.reject(fn {_, item} ->
        pinned?(item)
      end)
      |> Enum.sort_by(fn {_, item} -> item.touched end)

    conversations =
      removable
      |> Enum.take(max(map_size(conversations) - @max_conversations, 0))
      |> Enum.reduce(conversations, fn {id, _}, acc -> Map.delete(acc, id) end)

    %{state | conversations: conversations}
  end

  defp trim_actions(actions) do
    actions
    |> Enum.filter(fn {_, action} -> action.status == :done end)
    |> Enum.sort_by(fn {_, action} -> action.sequence end, :desc)
    |> Enum.drop(@max_finished_actions)
    |> Enum.reduce(actions, fn {id, _}, acc -> Map.delete(acc, id) end)
  end

  defp project_task(task, id) do
    Enum.reduce(@task_fields, %{id: id}, fn key, acc ->
      case Map.fetch(task, key) do
        {:ok, value} ->
          Map.put(acc, key, value)

        :error ->
          case Map.fetch(task, Atom.to_string(key)) do
            {:ok, value} -> Map.put(acc, key, value)
            :error -> acc
          end
      end
    end)
    |> Map.update(:objective_summary, "", fn value ->
      if is_binary(value), do: String.slice(value, 0, 200), else: ""
    end)
    |> Map.update(:progress, %{}, fn progress ->
      if is_map(progress) do
        saved = Map.take(progress[:saved_state] || %{}, [:status, :has_result, :has_error])

        progress
        |> Map.take([:observed_at, :registered_agent_count])
        |> Map.put(:saved_state, saved)
      else
        %{}
      end
    end)
  end

  defp fingerprint(payload),
    do: :crypto.hash(:sha256, :erlang.term_to_binary(payload, [:deterministic]))
end
