defmodule EvoGit.Agent.Tools.SkillEdit do
  @moduledoc """
  Tool for editing an existing skill file by replacing its content.
  Only skills available at the current context level can be edited.
  """

  alias EvoGit.Agent.Tools.Shared

  @doc """
  Returns the tool schema for ReqLLM.
  """
  def schema do
    ReqLLM.tool(
      name: "skill_edit",
      description:
        "Edits an existing skill file by replacing its full content. " <>
          "The name in the YAML frontmatter must match the name being edited. " <>
          "Use `skill_read` first to see the current content before editing. " <>
          "Only skills available at your current context level can be edited.",
      parameter_schema: %{
        "type" => "object",
        "properties" => %{
          "name" => %{
            "type" => "string",
            "description" => "The name of the skill to edit"
          },
          "content" => %{
            "type" => "string",
            "description" => "The new full skill content (markdown with YAML frontmatter)"
          }
        },
        "required" => ["name", "content"]
      },
      callback: fn _ -> {:ok, nil} end
    )
  end

  @doc """
  Executes the skill_edit tool.
  """
  def execute(args, _repo_path, repo_root, node_path) do
    with {:ok, name} <- Shared.fetch_string_arg(args, "name"),
         {:ok, content} <- Shared.fetch_string_arg(args, "content") do
      skills = EvoGit.Skills.load_hierarchical_skills(repo_root, node_path)

      if EvoGit.Skills.find_skill(skills, name) do
        case EvoGit.Skills.edit_skill(repo_root, name, content) do
          {:ok, file_path} -> "Skill edited successfully: #{file_path}"
          {:error, reason} -> "Error editing skill: #{reason}"
        end
      else
        "Error: Skill '#{name}' is not available at your current context level."
      end
    else
      {:error, message} -> message
    end
  end
end
