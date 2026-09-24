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

  The file deletion runs under `EvoGit.Agent.Tools.Shared.with_file_lock/2`
  keyed on the skill file path, and the CONTEXT.md reference cleanup runs under
  the same wrapper keyed on EACH CONTEXT.md it may rewrite (acquired in a stable
  sorted order) — so parallel skill mutations of the same skill file or the same
  CONTEXT.md are serialized instead of silently clobbering each other.
  """
  def execute(args, _repo_path, repo_root) do
    case Shared.fetch_string_arg(args, "name") do
      {:ok, name} ->
        skill_file =
          Path.join([
            repo_root,
            EvoGit.Skills.skills_dir(),
            EvoGit.Skills.CRUD.skill_filename(name)
          ])

        Shared.with_file_lock(skill_file, fn -> do_remove(name, repo_root) end)

      {:error, message} ->
        message
    end
  end

  defp do_remove(name, repo_root) do
    # First remove the skill file
    case EvoGit.Skills.remove_skill(repo_root, name) do
      :ok ->
        # Then clean up references in all CONTEXT.md files
        case remove_references(name, repo_root) do
          {:ok, 0} ->
            "Skill '#{name}' removed successfully. No CONTEXT.md references needed cleanup."

          {:ok, count} ->
            "Skill '#{name}' removed successfully. " <>
              "Cleaned up references in #{count} CONTEXT.md file(s)."
        end

      {:error, reason} ->
        "Error removing skill: #{reason}"
    end
  end

  # The cleanup rewrites every CONTEXT.md that carries the skill, so hold the
  # `with_file_lock/2` for each one while it runs. Sorted acquisition order
  # keeps two concurrent removals deadlock-free.
  defp remove_references(name, repo_root) do
    repo_root
    |> EvoGit.Skills.ContextIntegration.find_all_context_files()
    |> Enum.map(fn {abs_dir, _content} -> Path.join(abs_dir, "CONTEXT.md") end)
    |> Enum.uniq()
    |> Enum.sort()
    |> lock_context_files(fn ->
      EvoGit.Skills.remove_skill_from_all_contexts(name, repo_root)
    end)
  end

  defp lock_context_files([], fun), do: fun.()

  defp lock_context_files([path | rest], fun) do
    Shared.with_file_lock(path, fn -> lock_context_files(rest, fun) end)
  end
end
