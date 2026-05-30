defmodule EvoGit.Agent.Tools.SkillRead do
  @moduledoc """
  Tool for reading the full content of a skill file by name, if available at the current context level.
  """

  alias EvoGit.Agent.Tools.Shared

  @doc """
  Returns the tool schema for ReqLLM.
  """
  def schema do
    ReqLLM.tool(
      name: "skill_read",
      description:
        "Reads the full content of a skill file by name. " <>
          "Returns the raw markdown including YAML frontmatter. " <>
          "Use `skill_list` first to discover available skill names. " <>
          "Only skills available at your current context level can be read.",
      parameter_schema: %{
        "type" => "object",
        "properties" => %{
          "name" => %{
            "type" => "string",
            "description" => "The name of the skill to read"
          }
        },
        "required" => ["name"]
      },
      callback: fn _ -> {:ok, nil} end
    )
  end

  @doc """
  Executes the skill_read tool.
  """
  def execute(args, _repo_path, repo_root, node_path) do
    case Shared.fetch_string_arg(args, "name") do
      {:ok, name} ->
        skills = EvoGit.Skills.load_hierarchical_skills(repo_root, node_path)
        EvoGit.Skills.read_skill_from(skills, name)

      {:error, message} ->
        message
    end
  end
end
