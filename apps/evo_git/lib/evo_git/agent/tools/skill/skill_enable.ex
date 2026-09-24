defmodule EvoGit.Agent.Tools.SkillEnable do
  @moduledoc """
  Tool for enabling a skill at a specific Context Tree node level.

  Skills are enabled hierarchically: enabling a skill at a parent node makes it
  available to all subagents in that subtree. The tool checks if the skill is
  already enabled at this level or a higher level to avoid redundant entries.
  """

  alias EvoGit.Agent.Tools.Shared

  @doc """
  Returns the tool schema for ReqLLM.
  """
  def schema do
    ReqLLM.tool(
      name: "skill_enable",
      description:
        "Enables a skill at a specific Context Tree node level. " <>
          "Skills are inherited hierarchically: enabling at a parent node makes it " <>
          "available to all agents in that subtree. " <>
          "Checks if the skill is already enabled at this or a higher level to avoid redundancy. " <>
          "After enabling, agents in the affected subtree will have access to the skill.",
      parameter_schema: %{
        "type" => "object",
        "properties" => %{
          "skill_name" => %{
            "type" => "string",
            "description" => "The name of the skill to enable"
          },
          "node_path" => %{
            "type" => "string",
            "description" =>
              "The relative path to the directory where the skill should be enabled. " <>
                "Defaults to the agent's current node if not specified."
          }
        },
        "required" => ["skill_name"]
      },
      callback: fn _ -> {:ok, nil} end
    )
  end

  @doc """
  Executes the skill_enable tool.
  """
  def execute(args, repo_path, repo_root, default_node_path) do
    with {:ok, skill_name} <- Shared.fetch_string_arg(args, "skill_name") do
      node_path = Map.get(args, "node_path") || default_node_path || "./"

      # Verify the skill file exists
      skills_path = Path.join(repo_root, ".agents/skills")
      skill_file = Path.join(skills_path, "#{skill_name}.md")

      unless File.exists?(skill_file) do
        "Error: Skill '#{skill_name}' does not exist in .agents/skills/. " <>
          "Use skill_add to create it first, or use skill_list to see available skills."
      else
        case EvoGit.Skills.enable_skill(skill_name, node_path, repo_path) do
          {:ok, :already_enabled_here} ->
            "Skill '#{skill_name}' is already enabled at '#{node_path}'."

          {:ok, :already_enabled_above, higher_path} ->
            "Skill '#{skill_name}' is already enabled at a higher level ('#{higher_path}'), " <>
              "which covers '#{node_path}'. No changes needed."

          {:ok, :enabled, path} ->
            "Skill '#{skill_name}' enabled at '#{path}'. " <>
              "It will be available to agents assigned to this node and its children."

          {:error, reason} ->
            "Error enabling skill: #{reason}"
        end
      end
    else
      {:error, message} -> message
    end
  end
end
