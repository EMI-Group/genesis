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
  def execute(args, _repo_path, repo_root, _node_path) do
    case Shared.fetch_string_arg(args, "content") do
      {:ok, content} ->
        case EvoGit.Skills.add_skill(repo_root, content, "", %{}) do
          {:ok, file_path} ->
            "Skill created successfully: #{file_path}. " <>
              "Note: This skill will not be available to agents until you add it " <>
              "to the `skills` field in a CONTEXT.md file (e.g., using `edit_context` or `write_context`)."

          {:error, reason} -> "Error creating skill: #{reason}"
        end

      {:error, message} ->
        message
    end
  end
end
