defmodule EvoGit.TaskControl.Tools do
  @moduledoc "Shared task tool catalog and transport-independent TaskControl dispatch."
  alias EvoGit.TaskControl

  @path %{type: "string", description: "Absolute project directory on the Genesis host."}
  @id %{type: "string", description: "Task ID returned by Genesis."}
  @tools [
    {"genesis_check", :check,
     "Check Genesis version, model readiness, configuration file paths on the Genesis host and optional project path. Does not test provider connectivity or apply file edits.",
     %{path: @path}, [], true},
    {"genesis_reload_config", :reload_config,
     "Reload Genesis configuration through the existing scheduler API, then return configuration readiness. Takes no secrets or file contents. Does not restart existing agents or test provider connectivity; node distribution changes require a service restart.",
     %{}, [], false},
    {"genesis_start_task", :start,
     "Start background development; returns a task ID immediately. Existing Genesis Git behavior applies. Poll genesis_get_task for the actual result. To continue a finished task, use evolve with resume_from in the same project.",
     %{
       path: @path,
       objective: %{
         type: "string",
         description: "Development goal, context, constraints and acceptance criteria."
       },
       task_type: %{type: "string", enum: ["evolve", "genesis"], default: "evolve"},
       mode: %{
         type: "string",
         enum: ["simple", "new", "existing"],
         description:
           "Allowed pairs: evolve/simple, genesis/new, genesis/existing. Omit mode to use simple for evolve or new for genesis."
       },
       resume_from: @id,
       model_id: %{type: "string", description: "Optional configured Genesis model profile ID."}
     }, ["path", "objective"], false},
    {"genesis_get_task", :get,
     "Read saved task status, bounded scheduler observations and saved results. Full objectives are opt-in. Running is not completed; reports are not independent verification.",
     %{
       task_id: @id,
       since: %{
         type: "string",
         description: "Previous progress.change_token; unchanged active tasks may wait."
       },
       wait_seconds: %{type: "integer", minimum: 0, maximum: 20, default: 0},
       include_result: %{type: "boolean", default: true},
       include_objective: %{type: "boolean", default: false}
     }, ["task_id"], true},
    {"genesis_list_tasks", :list,
     "Find recent tasks, optionally filtered by absolute project path. Use after reconnecting instead of submitting duplicate work.",
     %{
       path: @path,
       limit: %{type: "integer", minimum: 1, maximum: 50, default: 20},
       offset: %{type: "integer", minimum: 0, maximum: 1_000_000, default: 0},
       status: %{
         type: "string",
         enum: ~w(pending running finalizing completed failed cancelled cancelling)
       },
       search: %{type: "string", description: "Search task goals, IDs and project paths."}
     }, [], true},
    {"genesis_list_models", :models,
     "List configured model profiles without credentials; use IDs with genesis_start_task.model_id.",
     %{}, [], true},
    {"genesis_get_result", :result,
     "Read a finished task's saved report, errors and result commits. Reports not_ready for active tasks. Test claims are backend-reported, not independently verified.",
     %{task_id: @id}, ["task_id"], true},
    {"genesis_send_message", :message,
     "Queue instructions to a running task's root or optional agent_id through the existing message API. Acceptance is not proof of delivery or adoption. The target must belong to this task.",
     %{task_id: @id, message: %{type: "string"}, agent_id: %{type: "integer", minimum: 1}},
     ["task_id", "message"], false},
    {"genesis_cancel_task", :cancel,
     "Request cancellation through the existing task API, optionally using its force-kill operation. Returns request acceptance and saved task state, not confirmation that all processes or cleanup have stopped. Does not undo Git changes.",
     %{
       task_id: @id,
       force: %{type: "boolean", default: false}
     }, ["task_id"], false}
  ]

  def list do
    Enum.map(@tools, fn {name, _, description, properties, required, readonly} ->
      %{
        name: name,
        description: description,
        inputSchema: %{
          type: "object",
          properties: properties,
          required: required,
          additionalProperties: false
        },
        annotations: %{
          readOnlyHint: readonly,
          destructiveHint: not readonly,
          openWorldHint: false
        }
      }
    end)
  end

  def names, do: Enum.map(@tools, &elem(&1, 0))
  def mutation?(name), do: Enum.any?(@tools, &(elem(&1, 0) == name and not elem(&1, 5)))

  def call(name, args) when is_binary(name) and is_map(args) do
    case Enum.find(@tools, &(elem(&1, 0) == name)) do
      nil -> {:invalid, "Unknown tool: #{name}"}
      {_, function, _, _, _, _} -> apply(TaskControl, function, [args])
    end
  end

  def call(_, _), do: {:invalid, "Tool name must be a string and arguments must be an object."}

  @doc "Validates and normalizes the exact assistant approval payload, without side effects."
  def prepare(name, args) when is_map(args) do
    with %{inputSchema: schema} <- Enum.find(list(), &(&1.name == name)),
         allowed = Enum.map(Map.keys(schema.properties), &Atom.to_string/1),
         true <- Enum.all?(Map.keys(args), &(&1 in allowed)),
         true <- Enum.all?(schema.required, &Map.has_key?(args, &1)),
         true <-
           Enum.all?(args, fn {key, value} ->
             property =
               Enum.find_value(schema.properties, fn {k, v} ->
                 if Atom.to_string(k) == key, do: v
               end)

             valid_value?(value, property)
           end),
         :ok <- absolute_path(args) do
      normalized =
        Enum.reduce(schema.properties, args, fn {key, property}, acc ->
          if Map.has_key?(property, :default),
            do: Map.put_new(acc, Atom.to_string(key), property.default),
            else: acc
        end)

      normalized =
        if Map.has_key?(normalized, "path"),
          do: Map.update!(normalized, "path", &Path.expand/1),
          else: normalized

      normalized =
        if name == "genesis_start_task",
          do:
            Map.put_new(
              normalized,
              "mode",
              if(normalized["task_type"] == "genesis", do: "new", else: "simple")
            ),
          else: normalized

      if name == "genesis_start_task" and
           {normalized["task_type"], normalized["mode"]} not in [
             {"evolve", "simple"},
             {"genesis", "new"},
             {"genesis", "existing"}
           ],
         do: {:error, "Use evolve/simple or genesis/new or genesis/existing."},
         else: {:ok, normalized}
    else
      _ ->
        {:error, "Invalid tool arguments; use the declared schema and an absolute project path."}
    end
  end

  def prepare(_, _), do: {:error, "Tool arguments must be an object."}

  defp absolute_path(%{"path" => path}) do
    if is_binary(path) and Path.type(path) == :absolute, do: :ok, else: :error
  end

  defp absolute_path(_), do: :ok

  defp valid_value?(value, schema) do
    type_ok =
      case schema.type do
        "string" ->
          is_binary(value) and String.valid?(value) and String.trim(value) != "" and
            not String.contains?(value, <<0>>)

        "integer" ->
          is_integer(value)

        "boolean" ->
          is_boolean(value)
      end

    type_ok and (not Map.has_key?(schema, :enum) or value in schema.enum) and
      (not Map.has_key?(schema, :minimum) or value >= schema.minimum) and
      (not Map.has_key?(schema, :maximum) or value <= schema.maximum)
  end
end
