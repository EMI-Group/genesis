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

  The existence check plus the file write run under
  `EvoGit.Agent.Tools.Shared.with_file_lock/2` keyed on the skill file path, so
  two concurrent adds of the same skill are serialized instead of both seeing
  "does not exist" and silently clobbering each other's content.
  """
  def execute(args, _repo_path, repo_root) do
    case Shared.fetch_string_arg(args, "content") do
      {:ok, content} ->
        Shared.with_file_lock(skill_file_path(repo_root, content), fn ->
          case EvoGit.Skills.add_skill(repo_root, content, "", %{}) do
            {:ok, file_path} -> "Skill created successfully: #{file_path}"
            {:error, reason} -> "Error creating skill: #{reason}"
          end
        end)

      {:error, message} ->
        message
    end
  end

  # The file `EvoGit.Skills.add_skill/4` will create, derived from the
  # frontmatter name so concurrent adds of the same skill share ONE lock key.
  # Malformed content (no name) falls back to the skills directory: add_skill/4
  # then rejects it without touching the filesystem.
  defp skill_file_path(repo_root, content) do
    metadata =
      case EvoGit.Skills.parse_frontmatter(content) do
        {:ok, metadata, _body} -> metadata
        {:error, _reason} -> %{}
      end

    case Map.get(metadata, "name") do
      name when is_binary(name) and name != "" ->
        Path.join([
          repo_root,
          EvoGit.Skills.skills_dir(),
          EvoGit.Skills.CRUD.skill_filename(name)
        ])

      _ ->
        Path.join(repo_root, EvoGit.Skills.skills_dir())
    end
  end
end
