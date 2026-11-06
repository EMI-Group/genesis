defmodule EvoGit.Agent.Tools.ElixirEval.Projection do
  @moduledoc false

  @statuses [:pending, :running, :finalizing, :cancelling, :completed, :failed, :cancelled]
  @types [:genesis, :evolve, :reflect, :extract_skills]
  @reviews [:open, :merged, :rejected, :continued, :ignored, :no_changes]
  @agent_statuses [:pending, :running, :waiting, :ready, :blocked]
  @timeout 1_000

  # Explicit scalar projections ONLY. Never return a raw struct or a nested
  # runtime/config map; opts, errors, histories and generation params are absent.
  def task(row) when is_map(row) do
    %{
      id: text(Map.get(row, :id), 128),
      type: enum(Map.get(row, :type), @types),
      status: enum(Map.get(row, :status), @statuses),
      review_status: enum(Map.get(row, :review_status), @reviews),
      started_at: timestamp(Map.get(row, :started_at)),
      finished_at: timestamp(Map.get(row, :finished_at)),
      updated_at: timestamp(Map.get(row, :updated_at)),
      agent_count: count(Map.get(row, :agent_count))
    }
  end

  def task(_), do: nil

  def tasks(context, options) do
    with {:ok, opts} <- page_options(options),
         %{rows: rows, total: total} when is_list(rows) <-
           GenServer.call(context.registry, {:list_tasks_page, opts}, @timeout) do
      %{
        rows: rows |> Enum.take(opts[:limit]) |> Enum.map(&task/1),
        total: count(total),
        limit: opts[:limit],
        offset: opts[:offset]
      }
    else
      {:error, _} = error -> error
      _ -> {:error, "Task page unavailable."}
    end
  end

  def get_task(context, id) do
    with :ok <- task_id(id) do
      context.registry |> GenServer.call({:get_task_lite, id}, @timeout) |> task()
    end
  end

  def agents do
    # ETS select projects in the table, so no conversation is copied to this
    # process. One bounded page, never tab2list or a full-table sort.
    match = [
      {{:"$1", :"$2"}, [],
       [
         {{:"$1", {:map_get, :parent_id, :"$2"}, {:map_get, :depth, :"$2"},
           {:map_get, :status, :"$2"}, {:map_get, :task_id, :"$2"}}}
       ]}
    ]

    case :ets.select(:evogit_sched_meta, match, 100) do
      {rows, continuation} ->
        %{
          agents:
            Enum.map(rows, fn {id, parent_id, depth, status, task_id} ->
              %{
                id: count(id),
                parent_id: count(parent_id),
                depth: count(depth),
                status: enum(status, @agent_statuses),
                task_id: text(task_id, 128)
              }
            end),
          truncated: continuation != :"$end_of_table"
        }

      :"$end_of_table" ->
        %{agents: [], truncated: false}
    end
  end

  def scheduler_status do
    slots = GenServer.call(EvoGit.AgentScheduler, :get_llm_slot_status, @timeout)
    paused = GenServer.call(EvoGit.AgentScheduler, {:get_config, :paused}, @timeout)

    if is_map(slots) and map_size(slots) <= 100 do
      totals =
        Enum.reduce(slots, %{used: 0, waiting: 0, capacity: 0}, fn {_id, slot}, acc ->
          Map.new(acc, fn {key, value} -> {key, value + (count(Map.get(slot, key)) || 0)} end)
        end)

      Map.put(totals, :paused, paused == true)
    else
      {:error, "Scheduler status exceeds the inspection limit."}
    end
  end

  def configuration_status do
    # Fetch only individual scalar keys, never :get_config (which includes
    # generation parameters/credentials) or persisted user configuration.
    Map.new(
      [:default_llm_max_concurrency, :max_tool_concurrency, :max_turns, :max_turns_root, :paused],
      fn key ->
        value = GenServer.call(EvoGit.AgentScheduler, {:get_config, key}, @timeout)
        {key, if(key == :paused, do: enum(value, [true, false]), else: count(value))}
      end
    )
  end

  def model_profiles do
    case GenServer.call(EvoGit.AgentScheduler, {:get_config, :model_profiles}, @timeout) do
      profiles when is_list(profiles) ->
        profiles
        |> Enum.take(100)
        |> Enum.map(fn profile ->
          %{
            id: text(Map.get(profile, :id), 128),
            model: text(Map.get(profile, :model), 256),
            concurrency: count(Map.get(profile, :concurrency))
          }
        end)

      _ ->
        {:error, "Model profiles unavailable."}
    end
  end

  def system_info do
    %{
      os: enum(EvoGit.Platform.os(), [:linux, :macos, :windows]),
      elixir: System.version(),
      otp: System.otp_release(),
      utc_time: DateTime.utc_now() |> DateTime.to_iso8601(),
      schedulers: :erlang.system_info(:schedulers_online)
    }
  end

  def page_options(options) when is_map(options) and map_size(options) <= 3 do
    with true <-
           Enum.all?(
             Map.keys(options),
             &(&1 in [:limit, :offset, :status, "limit", "offset", "status"])
           ),
         limit <- option(options, :limit, 25),
         offset <- option(options, :offset, 0),
         status <- option(options, :status, "all"),
         true <- is_integer(limit) and limit in 1..50,
         true <- is_integer(offset) and offset in 0..10_000,
         true <-
           status == "all" or status in @statuses or
             status in Enum.map(@statuses, &Atom.to_string/1) do
      {:ok,
       [
         limit: limit,
         offset: offset,
         status: if(is_atom(status), do: Atom.to_string(status), else: status)
       ]}
    else
      _ -> {:error, "Expected limit 1..50, offset 0..10000 and an allowlisted status."}
    end
  end

  def page_options(_), do: {:error, "Task list options must be a small map."}

  def task_id(id) when is_binary(id) and byte_size(id) in 1..128 do
    if String.valid?(id) and Regex.match?(~r/\A[a-zA-Z0-9_-]+\z/, id),
      do: :ok,
      else: {:error, "Invalid task id."}
  end

  def task_id(_), do: {:error, "Invalid task id."}

  def option(map, key, default \\ nil),
    do: Map.get(map, key, Map.get(map, Atom.to_string(key), default))

  def text(value, max) when is_binary(value) do
    if String.valid?(value), do: String.slice(value, 0, max), else: nil
  end

  def text(_, _), do: nil
  def count(value) when is_integer(value) and value >= 0, do: value
  def count(_), do: nil
  def enum(value, allowed), do: if(value in allowed, do: value, else: nil)
  defp timestamp(%DateTime{} = value), do: DateTime.to_iso8601(value)
  defp timestamp(%NaiveDateTime{} = value), do: NaiveDateTime.to_iso8601(value)
  defp timestamp(value), do: text(value, 40)
end
