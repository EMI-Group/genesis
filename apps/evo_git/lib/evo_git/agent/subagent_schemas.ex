defmodule EvoGit.Agent.SubagentSchemas do
  @moduledoc """
  Shared subagent tool schema generation.

  Generates LLM tool schemas for an agent's declared subagent modules.
  Extracted from the agent macro so it is defined ONCE instead of being
  macro-injected into every agent module.
  """

  @doc """
  Returns the list of subagent tool names for an agent module.
  """
  def tools(agent_module) do
    Enum.map(agent_module.subagent_modules(), & &1.subagent_tool_name())
  end

  @doc """
  Generates ReqLLM tool schemas for each subagent module declared by the agent.
  """
  def schemas(agent_module) do
    Enum.map(agent_module.subagent_modules(), fn mod ->
      ReqLLM.tool(
        name: mod.subagent_tool_name(),
        description: mod.subagent_tool_description(),
        parameter_schema: %{
          "type" => "object",
          "properties" => %{
            "path" => %{
              "type" => "string",
              "description" =>
                "The path to a DIRECTORY where the subagent should operate. " <>
                  "Use a RELATIVE path from the repository root for the current project (e.g., './src/auth', './lib/utils'). " <>
                  "Use an ABSOLUTE path to delegate to a FOREIGN REPOSITORY configured in genesis.toml " <>
                  "(e.g., '/Source/original-proj'). MUST be a directory node, NOT a file path.\n\n" <>
                  "IMPORTANT: Delegate at the DEEPEST correct node you know — if your routing table shows work belongs in `./src/auth/oauth/`, " <>
                  "delegate there directly, not at the higher-level `./src/auth/`. The subagent has its own routing table and will navigate further.\n\n" <>
                  "IMPORTANT: When delegating to a foreign repo, prefer using the repository ROOT path " <>
                  "(e.g., '/Source/original-proj' rather than '/Source/original-proj/src'). " <>
                  "Since you have no prior knowledge of the foreign repo's structure, starting at the root " <>
                  "allows the subagent to discover the codebase layout via its CONTEXT.md routing table. " <>
                  "Spawning at a non-root path is allowed but discouraged unless you have specific knowledge of that path.\n\n" <>
                  "IMPORTANT: Delegating work to child directories is more efficient than editing files there yourself. " <>
                  "When you find yourself repeatedly editing files in the same child directory, spawn a subagent at that path to handle the work autonomously."
            },
            "objective" => %{
              "type" => "string",
              "description" =>
                "A clear, self-contained objective for the subagent. " <>
                  "Include any relevant context since it starts with a fresh context. " <>
                  "IMPORTANT: The subagent's working directory is automatically set correctly. " <>
                  "Do NOT include worktree paths or `cd` commands in the objective — just describe what to do (e.g., 'run `mix test`'). " <>
                  "Include all relevant context, findings, and file paths so the subagent can start working immediately without re-investigating."
            },
            "commit_id" => %{
              "type" => "string",
              "description" =>
                "Optional: The commit SHA to spawn the subagent on. " <>
                  "Defaults to HEAD if not specified or if set to an empty string."
            }
          },
          "required" => ["path", "objective"]
        },
        callback: fn _args -> {:ok, nil} end
      )
    end)
  end
end
