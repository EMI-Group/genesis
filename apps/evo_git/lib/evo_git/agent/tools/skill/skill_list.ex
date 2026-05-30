defmodule EvoGit.Agent.Tools.SkillList do
  @moduledoc """
  Tool for listing available skills at the current context level.
  """

  @doc """
  Returns the tool schema for ReqLLM.
  """
  def schema do
    ReqLLM.tool(
      name: "skill_list",
      description:
        "Lists all available skills at your current context level. " <>
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
  def execute(_args, _repo_path, repo_root, node_path) do
    skills = EvoGit.Skills.load_hierarchical_skills(repo_root, node_path)
    EvoGit.Skills.list_skills_from(skills)
  end
end
