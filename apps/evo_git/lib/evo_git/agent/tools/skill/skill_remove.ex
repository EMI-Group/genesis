defmodule EvoGit.Agent.Tools.SkillRemove do
  @moduledoc """
  Tool for removing a skill file from `.agents/skills/` by name.

  When a skill is removed, all references to it in CONTEXT.md front matter
  across the repository are also cleaned up automatically.
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
          "Also cleans up all references to the skill from CONTEXT.md files " <>
          "across the repository. Use with caution — this permanently deletes " <>
          "the skill file and all its enablement entries.",
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
        # First remove the skill file
        case EvoGit.Skills.remove_skill(repo_root, name) do
          :ok ->
            # Then clean up references in all CONTEXT.md files
            case EvoGit.Skills.remove_skill_from_all_contexts(name, repo_root) do
              {:ok, 0} ->
                "Skill '#{name}' removed successfully. No CONTEXT.md references needed cleanup."

              {:ok, count} ->
                "Skill '#{name}' removed successfully. " <>
                  "Cleaned up references in #{count} CONTEXT.md file(s)."
            end

          {:error, reason} ->
            "Error removing skill: #{reason}"
        end

      {:error, message} ->
        message
    end
  end
end
