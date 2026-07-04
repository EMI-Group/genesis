defmodule EvoGit.Agent.Tools.SkillWhere do
  @moduledoc """
  Tool for querying which Context Tree nodes have a given skill enabled.

  Searches all CONTEXT.md files in the repository (excluding .genesis/, _build/,
  deps/, .git/, node_modules/) and returns the node paths where the skill
  appears in the YAML front matter's `skill` list.
  """

  alias EvoGit.Agent.Tools.Shared

  @doc """
  Returns the tool schema for ReqLLM.
  """
  def schema do
    ReqLLM.tool(
      name: "skill_where",
      description:
        "Queries which Context Tree nodes have a given skill enabled. " <>
          "Searches all CONTEXT.md files for the skill name in their YAML front matter. " <>
          "Returns a list of node paths (e.g., './', './lib', './apps/evo_git'). " <>
          "Use this to understand where a skill is currently available.",
      parameter_schema: %{
        "type" => "object",
        "properties" => %{
          "skill_name" => %{
            "type" => "string",
            "description" => "The name of the skill to query"
          }
        },
        "required" => ["skill_name"]
      },
      callback: fn _ -> {:ok, nil} end
    )
  end

  @doc """
  Executes the skill_where tool.
  """
  def execute(args, _repo_path, repo_root) do
    case Shared.fetch_string_arg(args, "skill_name") do
      {:ok, skill_name} ->
        nodes = EvoGit.Skills.where_enabled(skill_name, repo_root)

        if Enum.empty?(nodes) do
          "Skill '#{skill_name}' is not enabled at any node."
        else
          "Skill '#{skill_name}' is enabled at the following nodes:\n" <>
            Enum.map(nodes, fn p -> "  - #{p}" end) |> Enum.join("\n")
        end

      {:error, message} ->
        message
    end
  end
end
