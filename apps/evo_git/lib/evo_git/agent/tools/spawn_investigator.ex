defmodule EvoGit.Agent.Tools.SpawnInvestigator do
  @moduledoc """
  Command handler for the `SpawnInvestigator.spawn_investigator` command, invoked by
  `EvoGit.CommandShell` via the `run_command` tool.

  Runs a deterministic, bounded, strictly read-only investigation probe over an
  arbitrary codebase path — `EvoGit.Agent.Tools.SpawnInvestigatorProbe` — and
  returns the resulting report as a plain string. The command stays security
  level 1 (executes immediately, no user-approval gate) precisely because it is
  strictly read-only with ZERO side effects on the target repo: no files
  written (no `.genesis` creation, no worktree, no branch), no config
  mutation, no mutating git subprocess — pure filesystem reads only.

  ## Residual limitation (future design "a")

  `spawn_investigator` does NOT spawn a real `EvoGit.Agents.Investigator`
  subagent — it runs a deterministic bounded read-only probe instead (no LLM,
  no subagent run). A full read-only Investigator agent run remains the
  documented future path, blocked this release by the level-1 tool timeout (a
  ~10s cap would orphan a mid-run LLM subagent), the worktree/`.genesis`/
  branch footprint of an agent run in an arbitrary user repo, and the need for
  a dispatch-level repo-less path-threading change plus an LLM test seam.
  """

  alias EvoGit.Agent.Tools.Shared
  alias EvoGit.Agent.Tools.SpawnInvestigatorProbe

  @doc """
  Executes the spawn_investigator command (read-only investigation probe).

  Validates the required `path`/`objective` arguments — a missing or non-string
  argument returns the shared descriptive `{:error, "Missing required argument
  '...'..."}` tuple. Then spec-error-style path validation: the path must
  exist, must be a directory, and must be an existing git repository (a `.git`
  directory or a `.git` `gitdir:` pointer file); a violation returns a
  descriptive `{:error, message}` tuple naming the path and the problem. On
  success dispatches to the bounded read-only probe and returns its report as a
  plain String.
  """
  def execute(args, _repo_path, _repo_root) do
    with {:ok, path} <- Shared.fetch_string_arg(args, "path"),
         {:ok, objective} <- Shared.fetch_string_arg(args, "objective"),
         :ok <- validate_path(path) do
      SpawnInvestigatorProbe.investigate(path, objective)
    end
  end

  # Pure filesystem check (no git subprocess): a repository is a `.git`
  # directory or a `.git` gitdir-pointer file (git worktree).
  defp validate_path(path) do
    cond do
      not File.exists?(path) ->
        {:error, "Path does not exist: #{path}"}

      not File.dir?(path) ->
        {:error, "Path is not a directory: #{path}"}

      not git_repo?(path) ->
        {:error, "Path is not a git repository (no .git directory or gitdir pointer): #{path}"}

      true ->
        :ok
    end
  end

  defp git_repo?(path) do
    git_path = Path.join(path, ".git")
    File.dir?(git_path) or File.regular?(git_path)
  end
end
