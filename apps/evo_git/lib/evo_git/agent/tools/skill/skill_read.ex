defmodule EvoGit.Agent.Tools.SkillRead do
  @moduledoc """
  Tool for reading the full content of a skill file by name.
  """

  alias EvoGit.Agent.Tools.Shared

  @doc """
  Returns the tool schema for ReqLLM.
  """
  def schema do
    ReqLLM.tool(
      name: "skill_read",
      description:
        "Reads the full content of a skill file by name. " <>
          "Returns the raw markdown including YAML frontmatter. " <>
          "Use `skill_list` first to discover available skill names.",
      parameter_schema: %{
        "type" => "object",
        "properties" => %{
          "name" => %{
            "type" => "string",
            "description" => "The name of the skill to read"
          }
        },
        "required" => ["name"]
      },
      callback: fn _ -> {:ok, nil} end
    )
  end

  @doc """
  Executes the skill_read tool.
  """
  def execute(args, _repo_path, repo_root) do
    case Shared.fetch_string_arg(args, "name") do
      {:ok, name} ->
        EvoGit.Skills.read_skill(repo_root, name)

      {:error, message} ->
        message
    end
  end
end
