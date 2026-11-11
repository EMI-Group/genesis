defmodule EvoGit.TaskProgress do
  @moduledoc """
  Shared, durable task progress for the dashboard and structured callers.
  Agent reports describe work, never decide the task's lifecycle or certify
  verification. Writes use the Store's existing serialized writer.
  """
  @lists ~w(current_work completed remaining blockers next_steps evidence)
  @plan_lists ~w(remaining blockers next_steps)

  def publish(task_id, agent_id, attributes, opts \\ []) do
    with {:ok, clean} <- validate(attributes) do
      meta = Map.new(Keyword.take(opts, [:parent_id, :sequence, :source]))

      EvoGit.Store.publish_task_progress(
        Keyword.get(opts, :store, EvoGit.TaskRegistry.task_store()),
        task_id,
        agent_id,
        clean,
        meta
      )
    end
  end

  def get(task_id, store \\ nil),
    do: EvoGit.Store.get_task_progress(store || EvoGit.TaskRegistry.task_store(), task_id)

  def record_message(task_id, message_id, agent_id, state) do
    EvoGit.Store.record_task_message(
      EvoGit.TaskRegistry.task_store(),
      task_id,
      message_id,
      agent_id,
      state
    )
  end

  def delivered(messages, agent_id) do
    with {:ok, meta} <- EvoGit.AgentScheduler.Store.get_sched_meta(agent_id) do
      Enum.each(messages, fn
        %{progress_message_id: id} -> record_message(meta.task_id, id, agent_id, "delivered")
        _ -> :ok
      end)
    end

    :ok
  end

  def note_agent(agent_id, attrs) when is_integer(agent_id) do
    with {:ok, %{task_id: task_id} = meta} when is_binary(task_id) <-
           EvoGit.AgentScheduler.Store.get_sched_meta(agent_id) do
      publish(task_id, agent_id, attrs, parent_id: meta.parent_id)
    else
      _ -> {:error, :no_task}
    end
  catch
    :exit, _ -> {:error, :progress_unavailable}
  end

  def note_agent(_, _), do: {:error, :no_task}

  def instruction do
    "Report task progress with report_progress when you form a plan, finish a meaningful step, encounter a blocker, or finish verification. " <>
      "Keep it brief: what is complete, what you are doing, what remains, and the next step. Do not repeatedly report unchanged work. " <>
      "Report only your scope; the root owns the overall plan. A commit is not proof that tests passed. " <>
      "As root, update remaining work, blockers and next steps as you integrate child results; use empty lists to clear resolved items. " <>
      "Before ending, update remaining work and blockers to reflect the final outcome. Before delegation, include established findings, interfaces and acceptance checks in the child objective. " <>
      "Use report_progress for intermediate updates; a plain response without tool calls ends your run."
  end

  def validate(attrs) when is_map(attrs) do
    attrs = Map.new(attrs, fn {key, value} -> {to_string(key), value} end)

    valid =
      map_size(attrs) > 0 and
        Enum.all?(attrs, fn
          {"summary", text} ->
            is_binary(text) and String.length(text) <= 2400

          {key, list} when key in @lists ->
            is_list(list) and length(list) <= 12 and
              Enum.all?(list, &(is_binary(&1) and String.length(&1) <= 400))

          _ ->
            false
        end)

    if valid, do: {:ok, attrs}, else: {:error, :invalid_progress}
  end

  def validate(_), do: {:error, :invalid_progress}

  @doc false
  def merge(previous, agent_id, attrs, meta) do
    agents = Map.get(previous, "agents", %{})
    key = to_string(agent_id)
    old = Map.get(agents, key, %{})
    sequence = Map.get(meta, :sequence, Map.get(old, "sequence", 0) + 1)

    cond do
      not is_integer(sequence) or sequence < 0 ->
        {:error, :invalid_sequence}

      sequence <= Map.get(old, "sequence", -1) ->
        {:unchanged, previous}

      true ->
        report = Map.merge(Map.get(old, "report", %{}), attrs)

        acknowledges_children =
          is_nil(Map.get(meta, :parent_id)) and
            Enum.any?(@plan_lists, fn field ->
              Map.has_key?(attrs, field) and
                Enum.any?(agents, fn {id, entry} ->
                  id != key and not is_nil(entry["parent_id"]) and
                    Map.get(entry["report"], field, []) != [] and
                    field_revision(entry, field) > field_revision(old, field)
                end)
            end)

        if report == old["report"] and not acknowledges_children do
          entry = Map.put(old, "sequence", sequence)
          {:metadata_only, Map.put(previous, "agents", Map.put(agents, key, entry))}
        else
          revision = Map.get(previous, "revision", 0) + 1

          field_revisions =
            Enum.reduce(Map.keys(attrs), Map.get(old, "field_revisions", %{}), fn field,
                                                                                  revisions ->
              Map.put(revisions, field, revision)
            end)

          entry = %{
            "report" => report,
            "sequence" => sequence,
            "parent_id" => Map.get(meta, :parent_id),
            "revision" => revision,
            "field_revisions" => field_revisions,
            "source" => to_string(Map.get(meta, :source, :agent_report))
          }

          agents = Map.put(agents, key, entry)
          root_id = if is_nil(Map.get(meta, :parent_id)), do: key, else: previous["root_agent_id"]
          snapshot(previous, agents, root_id, key, revision)
        end
    end
  end

  defp snapshot(previous, agents, root_id, current_id, revision) do
    ordered =
      Enum.sort_by(agents, fn {id, entry} ->
        {if(id == root_id, do: 0, else: 1), -Map.get(entry, "revision", 0)}
      end)

    sources =
      Map.new(@lists, fn field ->
        values =
          Enum.flat_map(ordered, fn {id, entry} ->
            root = Map.get(agents, root_id, %{})

            applicable =
              field in ~w(completed evidence) or id == root_id or
                (not is_nil(entry["parent_id"]) and
                   (field not in @plan_lists or
                      field_revision(entry, field) > field_revision(root, field)))

            if applicable do
              Enum.map(Map.get(entry["report"], field, []), fn text ->
                %{"text" => text, "agent_id" => id, "source" => entry["source"]}
              end)
            else
              []
            end
          end)
          |> Enum.uniq_by(& &1["text"])

        {field, values}
      end)

    lists_truncated = Enum.any?(sources, fn {_, items} -> length(items) > 24 end)
    sources = Map.new(sources, fn {field, items} -> {field, Enum.take(items, 24)} end)
    root_report = get_in(agents, [root_id, "report"]) || %{}
    fallback = Enum.find_value(ordered, fn {_, entry} -> entry["report"]["summary"] end)
    omitted = Map.get(previous, "omitted_agent_reports", 0)

    next =
      previous
      |> Map.merge(
        Map.new(sources, fn {field, items} -> {field, Enum.map(items, & &1["text"])} end)
      )
      |> Map.merge(%{
        "summary" => root_report["summary"] || fallback,
        "summary_scope" => if(root_report["summary"], do: "task", else: "agent"),
        "revision" => revision,
        "updated_at" => DateTime.to_iso8601(DateTime.utc_now()),
        "evidence_sources" => sources,
        "agents" => agents,
        "root_agent_id" => root_id,
        "verification" => "reported_not_independently_verified",
        "truncated" => lists_truncated or omitted > 0,
        "omitted_agent_reports" => omitted
      })

    if map_size(agents) <= 32 and byte_size(Jason.encode!(next)) <= 131_072 do
      {:changed, next}
    else
      case Enum.reject(ordered, fn {id, _} -> id in [root_id, current_id] end) |> List.last() do
        nil ->
          {:error, :progress_capacity}

        {id, _} ->
          snapshot(
            Map.put(previous, "omitted_agent_reports", omitted + 1),
            Map.delete(agents, id),
            root_id,
            current_id,
            revision
          )
      end
    end
  end

  defp field_revision(entry, field) do
    case entry["field_revisions"] do
      nil -> Map.get(entry, "revision", 0)
      revisions -> Map.get(revisions, field, 0)
    end
  end

  @doc false
  def public(nil), do: nil
  def public(report), do: Map.drop(report, ["agents"])
end
