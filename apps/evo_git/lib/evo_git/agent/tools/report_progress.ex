defmodule EvoGit.Agent.Tools.ReportProgress do
  @moduledoc "Internal progress reporting; does not finish the agent run."
  def schema do
    fields =
      Map.new(~w(current_work completed remaining blockers next_steps evidence), fn key ->
        {key,
         %{
           "type" => "array",
           "maxItems" => 12,
           "items" => %{"type" => "string", "maxLength" => 400}
         }}
      end)

    ReqLLM.tool(
      name: "report_progress",
      description:
        "Update the user's task progress without ending your run. Report current work, completed outcomes, remaining work, blockers and next steps after meaningful changes. Use concise user-facing language. Completed items are your report, not independent verification. Do not include secrets or private reasoning.",
      parameter_schema: %{
        "type" => "object",
        "additionalProperties" => false,
        "properties" => Map.put(fields, "summary", %{"type" => "string", "maxLength" => 2400})
      },
      callback: fn _ -> {:ok, nil} end
    )
  end

  def execute(args) do
    case EvoGit.TaskProgress.note_agent(Process.get(:evogit_agent_id), args) do
      {:ok, report} -> Jason.encode!(%{status: "recorded", revision: report["revision"]})
      {:error, reason} -> "Error: progress was not recorded (#{reason})."
    end
  end
end
