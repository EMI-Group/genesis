defmodule EvoGit.Agent.Genesis.Directory do
  @moduledoc """
  A dedicated agent for the Genesis creation phase of a directory.
  """
  use EvoGit.Agent

  def available_tools do
    EvoGit.Agent.Tools.schemas() ++ [genesis_completion_schema()]
  end

  def system_prompt do
    """
    You are an EvoGit Genesis Agent responsible for planning and realizing the codebase skeleton.
    Your task is to create the required files and directories according to the architectural plan.
    When you are completely finished, you MUST call 'complete_task'.
    The 'result' parameter MUST be a list of strings representing the names of the newly created subdirectories and files that the system should recurse into for further processing. Both directories and files need to be included in this list if they need to be fully realized by the system.
    Do not include files/directories that shouldn't be recursed into (like empty terminal files or static assets).
    If there are no children to recurse into, pass an empty list.
    """
  end

  defp genesis_completion_schema do
    ReqLLM.tool(
      name: "complete_task",
      description:
        "Call this tool to finish the task. You MUST explicitly return a list of folder or file paths to recurse down to.",
      parameter_schema: %{
        "type" => "object",
        "properties" => %{
          "result" => %{
            "type" => "array",
            "items" => %{"type" => "string"},
            "description" =>
              "List of relative paths of the newly created subdirectories or files that the system should recurse into for further processing. If there are none, return an empty array."
          }
        },
        "required" => ["result"]
      },
      callback: fn _args -> {:ok, "Task finished"} end
    )
  end
end
