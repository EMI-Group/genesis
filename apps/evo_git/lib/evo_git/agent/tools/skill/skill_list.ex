defmodule EvoGit.Agent.Tools.SkillList do
  @moduledoc """
  Tool for listing all available skills from the `.agents/skills/` directory.
  """

  alias EvoGit.Agent.Tools.Shared

  @doc """
  Returns the tool schema for ReqLLM.
  """
  def schema do
    ReqLLM.tool(
      name: "skill_list",
      description:
        "Lists all available skills from the `.agents/skills/` directory. " <>
          "Shows each skill's name, description, and parameters. " <>
          "Use this to discover what reusable skills are available before reading or editing them.",
      parameter_schema: %{
        "type" => "object",
        "properties" => %{},
        "required" => []
      },
      callback: fn _ -> {:ok, nil} end
    )
  end

  @doc """
  Executes the skill_list tool.
  """
  def execute(args, repo_path, repo_root) do
    EvoGit.Skills.list_skills(repo_root)
  end
end
