defmodule EvoGit.Runtime.SkillExtraction do
  @moduledoc "Skill Extraction Phase: analyzes a completed PR and distills findings into EvoGit skills"
  alias EvoGit.Core.PhyloGraphNode
  alias EvoGit.Core.ContextNode
  alias EvoGit.AgentScheduler
  alias EvoGit.AgentSpec
  alias EvoGit.Runtime
  alias EvoGit.Agent.Result
  alias EvoGit.Runtime.Helpers
  require Logger

  def run(opts \\ []) do
    repo_path = Keyword.get(opts, :repo_path, File.cwd!()) |> Path.expand()

    Logger.info("SkillExtraction: Starting skill extraction from completed PR")

    with :ok <- Runtime.ensure_repo(repo_path),
         {:ok, current_sha} <- PhyloGraphNode.current_head(repo_path) do
      objective = build_objective(opts)
      phylo_node = PhyloGraphNode.new(repo_path, current_sha)
      context_node = ContextNode.load("./", repo_path)
      foreign_repos = Helpers.load_foreign_repos(repo_path, opts)

      case AgentSpec.new(context_node, phylo_node, EvoGit.Agents.SkillExtractor, objective,
             foreign_repos: foreign_repos,
             archive: Keyword.get(opts, :archive, false),
             task_id: Keyword.get(opts, :task_id)
           )
           |> AgentScheduler.run_agent() do
        {:ok, %Result{} = agent_output} ->
          Helpers.notify_finalizing(Keyword.get(opts, :task_id))
          Helpers.merge_and_report(repo_path, agent_output, "skill")

        error ->
          Logger.error("SkillExtraction failed: #{inspect(error)}")
          error
      end
    else
      error ->
        Logger.error("SkillExtraction failed to initialize: #{inspect(error)}")
        error
    end
  end

  defp build_objective(opts) do
    pr_title = Keyword.get(opts, :pr_title)
    pr_objective = Keyword.get(opts, :pr_objective)
    pr_summary = Keyword.get(opts, :pr_summary)
    pr_commit_history = Keyword.get(opts, :pr_commit_history)
    base_sha = Keyword.get(opts, :base_sha)
    commit_sha = Keyword.get(opts, :commit_sha)
    user_note = Keyword.get(opts, :user_note)

    sections = [
      {"PR Title", pr_title},
      {"Original Objective", pr_objective},
      {"Agent Summary", pr_summary},
      {"Commit History", pr_commit_history},
      {"User Note", user_note}
    ]

    context_body =
      sections
      |> Enum.reject(fn {_label, value} -> is_nil(value) or value == "" end)
      |> Enum.map(fn {label, value} -> "## #{label}\n\n#{value}" end)
      |> Enum.join("\n\n")

    diff_instruction =
      cond do
        base_sha && commit_sha ->
          "Examine the code changes by running: `git diff #{base_sha} #{commit_sha}`. " <>
            "You can also review the commit progression with: `git log --oneline #{base_sha}..#{commit_sha}`."

        commit_sha ->
          "Examine the code changes at commit #{commit_sha} and the surrounding history to understand what was done."

        true ->
          "Examine the code changes using git diff and git log to understand what was done in this PR."
      end

    """
    Extract reusable knowledge from this completed PR and distill it into EvoGit skills.

    #{diff_instruction}

    ## PR Context

    #{context_body}
    """
    |> String.trim()
  end
end
