defmodule EvoGit.Agent.Tools.SkillDisable do
  @moduledoc """
  Tool for disabling a skill at a specific Context Tree node level.

  Removing a skill from a node's front matter means agents at that level
  (and below, unless re-enabled at a lower level) will no longer have access.
  """

  alias EvoGit.Agent.Tools.Shared

  @doc """
  Returns the tool schema for ReqLLM.
  """
  def schema do
    ReqLLM.tool(
      name: "skill_disable",
      description:
        "Disables a skill at a specific Context Tree node level by removing it " <>
          "from that node's CONTEXT.md front matter. " <>
          "The skill may still be available if inherited from a higher level. " <>
          "Use skill_where to find all nodes where a skill is enabled.",
      parameter_schema: %{
        "type" => "object",
        "properties" => %{
          "skill_name" => %{
            "type" => "string",
            "description" => "The name of the skill to disable"
          },
          "node_path" => %{
            "type" => "string",
            "description" =>
              "The relative path to the directory where the skill should be disabled. " <>
                "Defaults to the agent's current node if not specified."
          }
        },
        "required" => ["skill_name"]
      },
      callback: fn _ -> {:ok, nil} end
    )
  end

  @doc """
  Executes the skill_disable tool.
  """
  def execute(args, repo_path, _repo_root, default_node_path) do
    with {:ok, skill_name} <- Shared.fetch_string_arg(args, "skill_name") do
      node_path = Map.get(args, "node_path") || default_node_path || "./"

      case EvoGit.Skills.disable_skill(skill_name, node_path, repo_path) do
        {:ok, :disabled, path} ->
          "Skill '#{skill_name}' disabled at '#{path}'."

        {:ok, :not_enabled} ->
          "Skill '#{skill_name}' was not enabled at '#{node_path}'. " <>
            "Use skill_where to find where it is enabled."

        {:error, reason} ->
          "Error disabling skill: #{reason}"
      end
    else
      {:error, message} -> message
    end
  end
end
