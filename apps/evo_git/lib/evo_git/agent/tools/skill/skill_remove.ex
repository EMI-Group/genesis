defmodule EvoGit.Agent.Tools.SkillRemove do
  @moduledoc """
  Tool for removing a skill file from `.agents/skills/` by name.
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
          "Use with caution — this permanently deletes the skill file.",
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
  def execute(args, _repo_path, repo_root) do
    case Shared.fetch_string_arg(args, "name") do
      {:ok, name} ->
        case EvoGit.Skills.remove_skill(repo_root, name) do
          :ok -> "Skill '#{name}' removed successfully."
          {:error, reason} -> "Error removing skill: #{reason}"
        end

      {:error, message} ->
        message
    end
  end
end
