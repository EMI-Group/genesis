defmodule EvoGit.Runtime.Genesis do
  @moduledoc "Stage 1: Creation Phase (EvoGit 1.0 Spatial Architecture)"
  alias EvoGit.Core.PhyloGraphNode
  alias EvoGit.Core.ContextNode
  alias EvoGit.AgentScheduler
  alias EvoGit.AgentSpec
  alias EvoGit.Agents.CodebaseLead
  alias EvoGit.Agents.Manager
  alias EvoGit.Agents.ContextExtractor
  alias EvoGit.Agent.Usage
  alias EvoGit.Agent.Result
  alias EvoGit.ProjectConfig
  alias EvoGit.Runtime
  alias EvoGit.Runtime.Helpers
  alias EvoGit.Runtime.WorktreeInitScript
  require Logger

  def run(objective, opts \\ []) when is_list(opts) do
    Logger.info("Genesis: Starting with objective: #{objective}")
    repo_path = Keyword.get(opts, :repo_path, File.cwd!()) |> Path.expand()

    with :ok <- Runtime.ensure_repo(repo_path),
         {:ok, head_sha} <- PhyloGraphNode.current_head(repo_path) do
      mode = resolve_mode(repo_path, opts)

      if mode == :new do
        run_new_codebase(objective, repo_path, head_sha, opts)
      else
        run_existing_codebase(objective, repo_path, head_sha, opts)
      end
    else
      error ->
        Logger.error("Genesis failed to initialize: #{inspect(error)}")
        error
    end
  end

  # Mode A: Existing Codebase
  defp run_existing_codebase(objective, repo_path, current_sha, opts) do
    Logger.info("Genesis: Running Mode A (Existing Codebase)")
    phylo_node = PhyloGraphNode.new(repo_path, current_sha)
    context_node = ContextNode.load("./", repo_path)

    # Load foreign repos: genesis.toml defaults merged with CLI-provided repos (CLI takes precedence)
    toml_repos = EvoGit.ProjectConfig.foreign_repos(repo_path)
    cli_repos = Keyword.get(opts, :foreign_repos, [])
    foreign_repos = Helpers.merge_foreign_repos(toml_repos, cli_repos)

    case AgentSpec.new(context_node, phylo_node, ContextExtractor, objective,
           foreign_repos: foreign_repos,
           archive: Keyword.get(opts, :archive, false),
           task_id: Keyword.get(opts, :task_id),
           model_id: Keyword.get(opts, :model_id)
         )
         |> AgentScheduler.run_agent() do
      {:ok, agent_output} ->
        Helpers.notify_finalizing(Keyword.get(opts, :task_id))
        Helpers.merge_and_report(repo_path, agent_output, "genesis")

      error ->
        Logger.error("Genesis Mode A failed: #{inspect(error)}")
        error
    end
  end

  # Mode B: New Codebase — two-phase: Architecture (CodebaseLead) then Implementation (Manager)
  defp run_new_codebase(objective, repo_path, current_sha, opts) do
    Logger.info("Genesis: Running Mode B (New Codebase)")

    # Generate task_id upfront so both root agents share it
    task_id =
      Keyword.get(opts, :task_id) ||
        :crypto.strong_rand_bytes(8) |> Base.encode16(case: :lower)

    opts = Keyword.put(opts, :task_id, task_id)

    # Write a predefined worktree init script to genesis.toml so the existing
    # per-worktree init-script infrastructure copies deps/build cache into new
    # worktrees. Skipped when no build system is selected or :none is chosen.
    build_system_id = Keyword.get(opts, :build_system)

    scripts =
      cond do
        is_nil(build_system_id) ->
          Logger.info("Genesis: No build system selected, skipping worktree init script")
          nil

        build_system_id == :none ->
          Logger.info("Genesis: Build system 'none' selected, skipping worktree init script")
          nil

        true ->
          scripts = WorktreeInitScript.scripts_for(build_system_id)
          ProjectConfig.write_worktree_script(repo_path, scripts)
          Logger.info("Genesis: Saved worktree init script for #{build_system_id}")
          scripts
      end

    # Load foreign repos: genesis.toml defaults merged with CLI-provided repos (CLI takes precedence)
    toml_repos = EvoGit.ProjectConfig.foreign_repos(repo_path)
    cli_repos = Keyword.get(opts, :foreign_repos, [])
    foreign_repos = Helpers.merge_foreign_repos(toml_repos, cli_repos)

    # --- Phase 1: Architecture (CodebaseLead as root agent) ---
    phylo_node = PhyloGraphNode.new(repo_path, current_sha)
    context_node = ContextNode.load("./", repo_path)

    architect_spec =
      AgentSpec.new(context_node, phylo_node, CodebaseLead, objective,
        foreign_repos: foreign_repos,
        archive: Keyword.get(opts, :archive, false),
        task_id: task_id,
        model_id: Keyword.get(opts, :model_id)
      )

    case AgentScheduler.run_agent(architect_spec) do
      {:ok, architect_output} ->
        # Validate genesis.toml integrity in case the CodebaseLead agent modified it.
        if scripts != nil do
          case ProjectConfig.read(repo_path) do
            nil ->
              Logger.warning(
                "Genesis: genesis.toml corrupted after architecture phase, re-writing worktree script"
              )

              ProjectConfig.write_worktree_script(repo_path, scripts)

            _ ->
              :ok
          end
        end

        run_implementation_phase(
          objective,
          repo_path,
          current_sha,
          architect_output,
          opts,
          foreign_repos,
          task_id,
          scripts
        )

      error ->
        Logger.error("Genesis Mode B architecture phase failed: #{inspect(error)}")
        error
    end
  end

  # --- Phase 2: Implementation (Manager as second root agent) ---
  defp run_implementation_phase(
         objective,
         repo_path,
         base_sha,
         architect_output,
         opts,
         foreign_repos,
         task_id,
         scripts
       ) do
    # Start the Manager from the architect's final commit (or original base if no commit)
    architect_commit = architect_output.commit_sha || base_sha
    phylo_node = PhyloGraphNode.new(repo_path, architect_commit)
    context_node = ContextNode.load("./", repo_path)

    architect_report = architect_output.result || "(No report provided by the architect)"

    impl_objective = """
    CRITICAL: You are the final agent responsible for delivering a COMPLETE, WORKING codebase. You must drive this to 100% completion — do NOT stop halfway or settle for partial work.

    Original objective (this is YOUR objective now — own it completely):
    #{objective}

    The architecture phase is complete. The architect established the following structure, design, and handoff notes:
    #{architect_report}

    Your single mandate: FULLY COMPLETE the original objective. The architecture, directory structure, CONTEXT.md routing tables, and public APIs are already in place — your job is pure implementation execution. Do not redesign the architecture; build on what exists.

    Work methodically:
    1. Survey the entire codebase to understand what the architect built and what the original objective requires.
    2. Identify EVERYTHING that remains unimplemented — stubs, TODOs, missing modules, incomplete features, broken builds. Build a complete inventory of the gap between what exists and what the original objective demands.
    3. Delegate implementation aggressively to subagents at the correct child nodes. Drive each area to completion in parallel where possible.
    4. Iterate until the codebase is FULLY functional: it must build successfully, tests must pass, and every feature demanded by the original objective must be implemented with real, working code — not stubs or placeholders.
    5. Polish: review for code quality, consistency, and completeness. The end product should be a finished, professional codebase.

    Do NOT treat this as "finish the architect's current task." Treat this as "deliver the complete codebase that the original objective asked for." You OWN the outcome. If something is incomplete, implement it. If something is broken, fix it. If something is missing, create it. Keep going until the original objective is fully and completely realized.

    Call complete_task only when the codebase is complete, functional, and polished — when you can confidently say the original objective has been 100% delivered.
    """

    manager_spec =
      AgentSpec.new(context_node, phylo_node, Manager, impl_objective,
        foreign_repos: foreign_repos,
        archive: Keyword.get(opts, :archive, false),
        task_id: task_id,
        model_id: Keyword.get(opts, :model_id)
      )

    case AgentScheduler.run_agent(manager_spec) do
      {:ok, manager_output} ->
        # Validate genesis.toml integrity in case the Manager agent modified it.
        if scripts != nil do
          case ProjectConfig.read(repo_path) do
            nil ->
              Logger.warning(
                "Genesis: genesis.toml corrupted after implementation phase, re-writing worktree script"
              )

              ProjectConfig.write_worktree_script(repo_path, scripts)

            _ ->
              :ok
          end
        end

        Helpers.notify_finalizing(task_id)

        # Combine usage, agent_count, and archive_records from both agents
        combined_usage =
          Usage.add(architect_output.usage || Usage.zero(), manager_output.usage || Usage.zero())

        combined_agent_count =
          (architect_output.agent_count || 0) + (manager_output.agent_count || 0)

        combined_archive_records =
          (architect_output.archive_records || []) ++ (manager_output.archive_records || [])

        merged_result = %Result{
          result:
            "## Architecture Phase\n#{architect_report}\n\n## Implementation Phase\n#{manager_output.result || "(No report)"}",
          commit_sha: manager_output.commit_sha,
          tag: manager_output.tag || architect_output.tag,
          usage: combined_usage,
          agent_count: combined_agent_count,
          archive_records: combined_archive_records
        }

        Helpers.merge_and_report(repo_path, merged_result, "genesis")

      error ->
        Logger.warning(
          "Genesis Mode B implementation phase failed: #{inspect(error)}. " <>
            "Returning architecture phase result as partial success."
        )

        Helpers.notify_finalizing(task_id)
        Helpers.merge_and_report(repo_path, architect_output, "genesis")
    end
  end

  # Use the explicitly-specified mode if provided; otherwise auto-detect.
  defp resolve_mode(repo_path, opts) do
    case Keyword.get(opts, :mode) do
      :new -> :new
      :existing -> :existing
      _ -> if Helpers.new_codebase?(repo_path), do: :new, else: :existing
    end
  end
end
