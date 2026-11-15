defmodule EvoGit.Agent.Tools.GenesisTools do
  @moduledoc "Assistant adapter for shared task tools, bound to actual runtime ownership."

  alias EvoGit.Agent.Tools.ElixirEval.Authorization
  alias EvoGit.Agent.Tools.Failure
  alias EvoGit.TaskControl.Tools, as: Catalog

  @follow "genesis_follow_task"
  @ui_actions ~w(genesis_send_message genesis_cancel_task)
  @task_mutations @ui_actions ++ ~w(genesis_pause_task genesis_resume_task)

  def schemas do
    Enum.map(Catalog.list(), fn tool ->
      ReqLLM.tool(
        name: tool.name,
        description: tool.description,
        parameter_schema: tool.inputSchema |> Jason.encode!() |> Jason.decode!(),
        callback: fn _ -> {:ok, nil} end
      )
    end) ++ [follow_schema()]
  end

  def names, do: Catalog.names() ++ [@follow]
  def mutation?(name), do: Catalog.mutation?(name)

  def execute(name, args, _repo_path, _repo_root) do
    result =
      with {:ok, authority} <- Authorization.authorize(),
           {:ok, context} <- assistant_context(authority),
           {:ok, prepared} <- prepare(name, args, context),
           :ok <- forbid_self_target(name, prepared, authority),
           :ok <- approve(name, prepared, context),
           :ok <- Authorization.revalidate(authority) do
        dispatch(name, prepared, context)
      end

    render(result)
  rescue
    _ -> Failure.error("Task tool failed; inspect task status before retrying a submission.")
  catch
    :exit, _ ->
      Failure.error(
        "Task tool result is uncertain; inspect task status before retrying. Do not resubmit automatically."
      )
  end

  @doc "Card actions use a server-owned conversation scope and survive the assistant session."
  def request_action(
        name,
        args,
        %{conversation_id: conversation, target_node: target, operation_id: operation} = context
      )
      when name in @ui_actions and is_binary(operation) and byte_size(operation) in 1..128 and
             ((is_binary(conversation) and conversation != "") or
                (is_integer(conversation) and conversation > 0)) do
    with true <- target == node(),
         {:ok, prepared} <- Catalog.prepare(name, args),
         {:ok, task} <- linked_task(conversation, prepared["task_id"]) do
      context =
        Map.merge(context, %{agent_id: nil, task_id: nil, project_path: task[:project_path]})

      case EvoGit.AssistantTaskLinks.claim_action(conversation, operation, {name, prepared}) do
        :claimed ->
          result = with :ok <- approve(name, prepared, context), do: Catalog.call(name, prepared)

          case result do
            {:error, %{code: "unavailable"}} ->
              :ok = EvoGit.AssistantTaskLinks.uncertain_action(conversation, operation)
              action_waiting(:unknown, operation)

            _ ->
              :ok = EvoGit.AssistantTaskLinks.finish_action(conversation, operation, result)
              result
          end

        {:done, result} ->
          result

        :pending ->
          action_waiting(:pending, operation)

        :unknown ->
          action_waiting(:unknown, operation)

        {status, existing_id} when status in [:pending, :unknown] ->
          action_waiting(status, existing_id)

        {:error, reason} ->
          {:error, reason}
      end
    else
      false -> {:error, "Task actions must run on their owning runtime node."}
      other -> other
    end
  end

  def request_action(_, _, _),
    do: {:error, "Invalid task action, operation ID or conversation scope."}

  defp action_waiting(status, operation) do
    code = if status == :pending, do: "action_pending", else: "action_uncertain"

    {:error,
     %{
       code: code,
       operation_id: operation,
       message:
         "Task action is awaiting approval or its outcome is uncertain; check this operation and task state before retrying."
     }}
  end

  defp follow_schema do
    ReqLLM.tool(
      name: @follow,
      description:
        "Follow an existing task in this conversation. Read-only task status is authoritative; this changes no task lifecycle. Regular list/get calls do not follow tasks.",
      parameter_schema: %{
        "type" => "object",
        "properties" => %{"task_id" => %{"type" => "string"}},
        "required" => ["task_id"],
        "additionalProperties" => false
      },
      callback: fn _ -> {:ok, nil} end
    )
  end

  defp assistant_context(authority) do
    case :ets.lookup(:evogit_sched_meta, authority.agent_id) do
      [{_, %{spec: %{opts: opts}}}] ->
        {:ok,
         Map.merge(authority, %{
           conversation_id: Keyword.get(opts, :assistant_conversation_id),
           workspace: Keyword.get(opts, :assistant_workspace)
         })}

      _ ->
        {:error, "Assistant session is unavailable."}
    end
  end

  defp prepare(@follow, args, _context), do: Catalog.prepare("genesis_get_result", args)

  defp prepare(name, args, context) when is_map(args) do
    # The source checkout and repo_path are never implicit execution targets.
    # An explicit absolute model argument remains visible in the approval.
    args =
      case {name, Map.has_key?(args, "path"), context.workspace} do
        {"genesis_start_task", false, %{path: path, node: target}} when target == node() ->
          Map.put(args, "path", path)

        {"genesis_list_tasks", false, %{path: path, node: target}} when target == node() ->
          Map.put(args, "path", path)

        _ ->
          args
      end

    Catalog.prepare(name, args)
  end

  defp prepare(_, _, _), do: {:error, "Tool arguments must be an object."}

  defp forbid_self_target(name, %{"task_id" => id}, %{task_id: id}) when name in @task_mutations,
    do: {:error, "The assistant cannot mutate its own task through task tools."}

  defp forbid_self_target(_, _, _), do: :ok

  defp approve(name, args, context) do
    if Catalog.mutation?(name) do
      details =
        Map.merge(context, %{
          project_path: args["path"] || context[:project_path] || task_project(args["task_id"]),
          summary: args["objective"] || args["message"] || "",
          target_task_id: args["task_id"]
        })

      case EvoGit.CommandApproval.request_action(name, args, details) do
        :approved -> :ok
        :denied -> {:error, "Task action denied by the user; it was not executed."}
        :timeout -> {:error, "Task action approval timed out; it was not executed."}
      end
    else
      :ok
    end
  end

  defp task_project(nil), do: nil

  defp task_project(id) do
    case EvoGit.TaskControl.get(%{"task_id" => id, "include_result" => false}) do
      {:ok, task} -> task[:project_path]
      _ -> nil
    end
  end

  defp dispatch(@follow, args, context) do
    with {:ok, data} <- Catalog.call("genesis_get_task", Map.put(args, "include_result", false)),
         :ok <- link(context, data) do
      {:ok, Map.put(data, :followed, true)}
    end
  end

  defp dispatch(name, args, context) do
    case Catalog.call(name, args) do
      {:ok, data} = success when name == "genesis_start_task" ->
        # A successful task start must remain successful even if UI tracking is
        # temporarily unavailable; never tell the model to submit it twice.
        case link(context, data) do
          :ok ->
            success

          _ ->
            {:ok,
             Map.put(
               data,
               :tracking_warning,
               "Task accepted; follow it by its returned ID if the conversation card is unavailable."
             )}
        end

      {:error, %{code: "unavailable"} = error} ->
        if Catalog.mutation?(name),
          do:
            {:error,
             %{
               error
               | message:
                   "Task action outcome is uncertain. Query task status or list tasks before retrying; do not submit it again automatically."
             }},
          else: {:error, error}

      other ->
        other
    end
  end

  defp link(%{conversation_id: id}, data)
       when (is_binary(id) and id != "") or (is_integer(id) and id > 0),
       do: EvoGit.AssistantTaskLinks.follow(node(), id, data)

  defp link(_, _), do: {:error, "This assistant has no conversation tracking scope."}

  defp linked_task(conversation, id) do
    case Enum.find(EvoGit.AssistantTaskLinks.list(node(), conversation), &(&1.id == id)) do
      nil -> {:error, "Task is not followed by this conversation."}
      task -> {:ok, task}
    end
  end

  defp render({:ok, data}), do: Jason.encode!(data)
  defp render({:error, %{code: code, message: message}}), do: Failure.error("#{code}: #{message}")
  defp render({:error, reason}), do: Failure.error(reason)
  defp render({:invalid, reason}), do: Failure.error(reason)
end
