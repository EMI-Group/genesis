defmodule EvoGit.Agent.Tools.SkillRemove do
  @moduledoc """
  Tool for removing a skill file from `.agents/skills/` by name.
  Only skills available at the current context level can be removed.
  """

  alias EvoGit.Agent.Tools.Shared

  @doc """
  Returns the tool schema for ReqLLM.
  """
  def schema do
    ReqLLM.tool(
      name: "skill_remove",
      description:
        "Removes a skill file from `.agents/skills/` by name. " <>
          "Use with caution — this permanently deletes the skill file. " <>
          "Only skills available at your current context level can be removed.",
      parameter_schema: %{
        "type" => "object",
        "properties" => %{
          "name" => %{
            "type" => "string",
            "description" => "The name of the skill to remove"
          }
        },
        "required" => ["name"]
      },
      callback: fn _ -> {:ok, nil} end
    )
  end

  @doc """
  Executes the skill_remove tool.
  """
  def execute(args, _repo_path, repo_root, node_path) do
    case Shared.fetch_string_arg(args, "name") do
      {:ok, name} ->
        skills = EvoGit.Skills.load_hierarchical_skills(repo_root, node_path)

        if EvoGit.Skills.find_skill(skills, name) do
          case EvoGit.Skills.remove_skill(repo_root, name) do
            :ok -> "Skill '#{name}' removed successfully."
            {:error, reason} -> "Error removing skill: #{reason}"
          end
        else
          "Error: Skill '#{name}' is not available at your current context level."
        end

      {:error, message} ->
        message
    end
  end
end
