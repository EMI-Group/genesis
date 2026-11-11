defmodule EvoDash.MCP.Tools do
  @moduledoc "MCP tool descriptions and dispatch to the shared task-control boundary."
  alias EvoGit.TaskControl

  @path %{type: "string", description: "Absolute project directory on the Genesis host."}
  @id %{type: "string", description: "Task ID returned by Genesis."}
  @tools [
    {"genesis_check", :check,
     "Check Genesis version, model readiness, configuration file paths on the Genesis host and optional project path. Does not test provider connectivity or apply file edits.",
     %{path: @path}, [], true},
    {"genesis_reload_config", :reload_config,
     "Validate and load edited Genesis configuration/credential files into the running scheduler, then return readiness. Takes no secrets or file contents. Does not restart existing agents or test provider connectivity; node distribution changes require a service restart.",
     %{}, [], false},
    {"genesis_start_task", :start,
     "Start background development; returns a task ID immediately. Existing Genesis Git behavior applies. Poll genesis_get_task for the actual result. To continue a finished task, use evolve with resume_from in the same project.",
     %{
       path: @path,
       budget: %{
         type: "object",
         additionalProperties: false,
         properties:
           Map.new(
             ~w(max_agents max_depth max_turns_root max_turns max_duration_seconds),
             &{&1, %{type: "integer", minimum: 1}}
           )
       },
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
     "Read shared task progress (current work, reported outcomes, remaining work, blockers, next steps), activity and saved results. Full objectives are opt-in. Running is not completed; reports are not independent verification.",
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
     "Queue instructions to a running task's root or optional agent_id. Follow the message receipt: queued is not delivered, and delivered is not proof of adoption. The target must belong to this task.",
     %{task_id: @id, message: %{type: "string"}, agent_id: %{type: "integer", minimum: 1}},
     ["task_id", "message"], false},
    {"genesis_cancel_task", :cancel,
     "Request stopping, optionally wait up to 20 seconds or force escalation. Inspect stopped and recoverable_work; a terminal row alone does not confirm process cleanup. Does not undo Git changes.",
     %{
       task_id: @id,
       force: %{type: "boolean", default: false},
       wait_seconds: %{type: "integer", minimum: 0, maximum: 20, default: 0}
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

  def call(name, args) when is_binary(name) and is_map(args) do
    case Enum.find(@tools, &(elem(&1, 0) == name)) do
      nil ->
        {:invalid, "Unknown tool: #{name}"}

      {_, function, _, _, _, _} ->
        case apply(TaskControl, function, [args]) do
          {:ok, data} -> {:ok, result(EvoDash.MCP.Links.enrich(data), false)}
          {:error, %{code: "invalid_arguments", message: message}} -> {:invalid, message}
          {:error, error} -> {:ok, result(%{error: error}, true)}
        end
    end
  end

  def call(_, _), do: {:invalid, "Tool name must be a string and arguments must be an object."}

  defp result(data, failed) do
    %{
      content: [%{type: "text", text: Jason.encode!(data)}],
      structuredContent: data,
      isError: failed
    }
  end
end
