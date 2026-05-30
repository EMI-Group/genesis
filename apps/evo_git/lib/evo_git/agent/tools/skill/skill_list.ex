defmodule EvoGit.Agent.Tools.SkillList do
  @moduledoc """
  Tool for listing skills.

  By default, lists all skills defined in `.agents/skills/`.
  When `node_path` is provided, lists only the skills available at that level
  (inherited hierarchically from root to that node).
  """

  @doc """
  Returns the tool schema for ReqLLM.
  """
  def schema do
    ReqLLM.tool(
      name: "skill_list",
      description:
        "Lists all available skills from the `.agents/skills/` directory. " <>
          "Shows each skill's name, description, and parameters. " <>
          "Optionally, provide `node_path` to list only skills available at " <>
          "a specific Context Tree level (hierarchically inherited). " <>
          "Use this to discover what reusable skills are available before reading or editing them.",
      parameter_schema: %{
        "type" => "object",
        "properties" => %{
          "node_path" => %{
            "type" => "string",
            "description" =>
              "Optional: The relative path to list skills for. " <>
                "If provided, only skills enabled at this node level (including inherited) are shown. " <>
                "If omitted, all skills in .agents/skills/ are listed."
          }
        },
        "required" => []
      },
      callback: fn _ -> {:ok, nil} end
    )
  end

  @doc """
  Executes the skill_list tool.
  """
  def execute(args, repo_path, repo_root) do
    node_path = Map.get(args, "node_path")

    if node_path && is_binary(node_path) do
      # Hierarchical listing: only skills enabled at this level
      all_skills = EvoGit.Skills.load_skills(repo_root)
      skill_names = EvoGit.Skills.hierarchical_skill_names(node_path, repo_path)
      filtered = EvoGit.Skills.filter_skills(all_skills, skill_names)

      if Enum.empty?(filtered) do
        "No skills enabled at '#{node_path}' (hierarchically). " <>
          "Use skill_enable to add skills, or skill_list without a node_path to see all defined skills."
      else
        format_skill_list(filtered, "Skills available at '#{node_path}' (hierarchically):")
      end
    else
      # List all skills in .agents/skills/
      EvoGit.Skills.list_skills(repo_root)
    end
  end

  defp format_skill_list(skills, header) do
    lines =
      Enum.map(skills, fn skill ->
        param_str =
          if Enum.empty?(skill.parameters) do
            "no parameters"
          else
            params =
              Enum.map(skill.parameters, fn p ->
                req = if p.required, do: " (required)", else: " (optional)"
                "    - #{p.name}: #{p.type}#{req} — #{p.description}"
              end)

            "\n#{Enum.join(params, "\n")}"
          end

        "* **#{skill.name}** — #{skill.description}#{param_str}"
      end)

    "#{header}\n\n#{Enum.join(lines, "\n\n")}"
  end
end
