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
          },
          "commit" => %{
            "type" => "boolean",
            "description" =>
              "Whether to create a git commit after enabling the skill. Defaults to true.",
            "default" => true
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
    with {:ok, skill_name} <- Shared.fetch_string_arg(args, "skill_name"),
         {:ok, commit} <- Shared.validate_commit(Map.get(args, "commit", true)) do
      node_path = Map.get(args, "node_path") || default_node_path || "./"

      # Verify the skill file exists in the agent's worktree
      skills_path = Path.join(repo_path, ".agents/skills")
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
            result =
              "Skill '#{skill_name}' enabled at '#{path}'. " <>
                "It will be available to agents assigned to this node and its children."

            files = [Path.join(path, "CONTEXT.md")]
            message = "Enable skill #{skill_name} at #{node_path}"
            Shared.maybe_commit_result(result, commit, repo_path, repo_root, files, message)

          {:error, reason} ->
            "Error enabling skill: #{reason}"
        end
      end
    else
      {:error, message} -> message
    end
  end
end
