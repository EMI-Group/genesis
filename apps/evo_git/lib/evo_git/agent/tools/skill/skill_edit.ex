defmodule EvoGit.Agent.Tools.SkillEdit do
  @moduledoc """
  Tool for editing an existing skill file by replacing its content.
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
          "Use `skill_read` first to see the current content before editing.",
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

  The read-modify-write (locate the file, validate, overwrite) runs under
  `EvoGit.Agent.Tools.Shared.with_file_lock/2` keyed on the skill file path, so
  parallel edits of the same skill are serialized instead of the later write
  silently dropping the earlier one.
  """
  def execute(args, _repo_path, repo_root) do
    with {:ok, name} <- Shared.fetch_string_arg(args, "name"),
         {:ok, content} <- Shared.fetch_string_arg(args, "content"),
         skill_file =
           Path.join([
             repo_root,
             EvoGit.Skills.skills_dir(),
             EvoGit.Skills.CRUD.skill_filename(name)
           ]) do
      Shared.with_file_lock(skill_file, fn ->
        case EvoGit.Skills.edit_skill(repo_root, name, content) do
          {:ok, file_path} -> "Skill edited successfully: #{file_path}"
          {:error, reason} -> "Error editing skill: #{reason}"
        end
      end)
    else
      {:error, message} -> message
    end
  end
end
