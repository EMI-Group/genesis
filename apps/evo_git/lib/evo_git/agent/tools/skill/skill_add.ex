defmodule EvoGit.Agent.Tools.SkillAdd do
  @moduledoc """
  Tool for creating a new skill in the `.agents/skills/` directory.
  """

  alias EvoGit.Agent.Tools.Shared

  @doc """
  Returns the tool schema for ReqLLM.
  """
  def schema do
    ReqLLM.tool(
      name: "skill_add",
      description:
        "Creates a new skill in `.agents/skills/`. " <>
          "The content must be valid markdown with YAML frontmatter " <>
          "(name, description, optional parameters). Example frontmatter:\n" <>
          "```\n" <>
          "---\n" <>
          "name: my-skill\n" <>
          "description: Does something useful\n" <>
          "parameters:\n" <>
          "  - name: input\n" <>
          "    type: string\n" <>
          "    description: The input file\n" <>
          "    required: true\n" <>
          "---\n" <>
          "# Skill body with instructions and/or bash command\n" <>
          "```",
      parameter_schema: %{
        "type" => "object",
        "properties" => %{
          "content" => %{
            "type" => "string",
            "description" => "The full skill content (markdown with YAML frontmatter)"
          },
          "commit" => %{
            "type" => "boolean",
            "description" =>
              "Whether to create a git commit after creating the skill file. Defaults to true.",
            "default" => true
          }
        },
        "required" => ["content"]
      },
      callback: fn _ -> {:ok, nil} end
    )
  end

  @doc """
  Executes the skill_add tool.
  """
  def execute(args, repo_path, repo_root) do
    with {:ok, content} <- Shared.fetch_string_arg(args, "content"),
         {:ok, commit} <- Shared.validate_commit(Map.get(args, "commit", true)) do
      case EvoGit.Skills.add_skill(repo_path, content, "", %{}) do
        {:ok, file_path} ->
          result = "Skill created successfully: #{file_path}"
          files = [Path.relative_to(file_path, repo_path)]
          message = "Add skill #{skill_name(file_path)}"
          Shared.maybe_commit_result(result, commit, repo_path, repo_root, files, message)

        {:error, reason} ->
          "Error creating skill: #{reason}"
      end
    else
      {:error, message} -> message
    end
  end

  defp skill_name(file_path), do: Path.basename(file_path, ".md")
end
