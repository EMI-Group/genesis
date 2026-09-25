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
          },
          "commit" => %{
            "type" => "boolean",
            "description" =>
              "Whether to create a git commit after removing the skill file and " <>
                "cleaning up its CONTEXT.md references. Defaults to true.",
            "default" => true
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
  def execute(args, repo_path, repo_root) do
    with {:ok, name} <- Shared.fetch_string_arg(args, "name"),
         {:ok, commit} <- Shared.validate_commit(Map.get(args, "commit", true)) do
      # Collect every path this removal will touch BEFORE mutating anything:
      # the skill file itself plus every CONTEXT.md currently enabling the skill.
      files = [skill_file(repo_path, name) | context_files(repo_path, name)]
      message = "Remove skill #{name}"

      # First remove the skill file
      case EvoGit.Skills.remove_skill(repo_path, name) do
        :ok ->
          # Then clean up references in all CONTEXT.md files
          case EvoGit.Skills.remove_skill_from_all_contexts(name, repo_path) do
            {:ok, 0} ->
              result =
                "Skill '#{name}' removed successfully. No CONTEXT.md references needed cleanup."

              Shared.maybe_commit_result(result, commit, repo_path, repo_root, files, message)

            {:ok, count} ->
              result =
                "Skill '#{name}' removed successfully. " <>
                  "Cleaned up references in #{count} CONTEXT.md file(s)."

              Shared.maybe_commit_result(result, commit, repo_path, repo_root, files, message)
          end

        {:error, reason} ->
          "Error removing skill: #{reason}"
      end
    else
      {:error, message} -> message
    end
  end

  # The skill file path (relative to the worktree), resolved via the same
  # exact-then-case-insensitive filename lookup the deletion itself uses, so a
  # case-differing filename is staged correctly.
  defp skill_file(repo_path, name) do
    skills_path = Path.join(repo_path, EvoGit.Skills.skills_dir())

    case EvoGit.Skills.CRUD.find_skill_file(skills_path, name) do
      nil -> Path.join(EvoGit.Skills.skills_dir(), "#{name}.md")
      file_path -> Path.relative_to(file_path, repo_path)
    end
  end

  # Every CONTEXT.md that currently enables the skill, as paths relative to the
  # worktree.
  defp context_files(repo_path, name) do
    Enum.map(EvoGit.Skills.where_enabled(name, repo_path), &Path.join(&1, "CONTEXT.md"))
  end
end
