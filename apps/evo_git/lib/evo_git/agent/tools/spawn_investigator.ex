defmodule EvoGit.Agent.Tools.SpawnInvestigator do
  @moduledoc """
  Command handler for the `task.investigate` command, invoked by
  `EvoGit.CommandShell` via the `run_command` tool. Placeholder for spawning an
  investigator subagent.

  v1: `execute/3` does NOT spawn anything — it explains that investigator
  subagent spawning ships with the bundled Genesis source (LSP-style) in a
  future release and points the agent at its own read-only investigation
  tools.
  """

  alias EvoGit.Agent.Tools.Shared

  @doc """
  Executes the subagent_investigator tool (placeholder).

  Does NOT spawn anything. Validates the required `path`/`objective` args
  minimally (returning a descriptive error string when missing) and otherwise
  returns a message explaining that investigator subagent spawning ships with
  the bundled Genesis source in a future release, and that the agent should
  use its own read-only tools to investigate the Genesis source directly.
  """
  def execute(args, _repo_path, _repo_root) do
    with {:ok, _path} <- Shared.fetch_string_arg(args, "path"),
         {:ok, _objective} <- Shared.fetch_string_arg(args, "objective") do
      placeholder_message()
    end
  end

  defp placeholder_message do
    "Investigator subagent spawning is not available in this release — it ships " <>
      "with the bundled Genesis source (LSP-style) in a future release. " <>
      "Use your own read-only investigation tools instead — read_file, read_context, " <>
      "rg, glob, search_context, and search_history — to investigate the Genesis " <>
      "source directly (your repo_path points at the Genesis source root)."
  end
end
