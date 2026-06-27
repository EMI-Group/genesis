defmodule EvoGit.Agent.SubagentProcessing do
  @moduledoc """
  Subagent call processing for the agent loop.

  Handles building subagent specs from tool calls, spawning subagents
  through the scheduler, merging results back (including octopus merges),
  and formatting the output for the LLM context.

  ## Usage

  Called from the agent loop when processing subagent tool calls:

      {indexed_subagent_results, merge_message} =
        EvoGit.Agent.SubagentProcessing.process_subagent_calls(
          indexed_subagent_calls,
          state,
          sync_commit_fn: &sync_current_commit_after_tools/1
        )
  """

  require Logger

  alias EvoGit.Agent.LoopState
  alias EvoGit.Agent.Result
  alias EvoGit.AgentScheduler
  alias EvoGit.AgentSpec
  alias EvoGit.Core.ForeignRepo
  alias EvoGit.Core.ContextNode
  alias EvoGit.Core.PhyloGraphNode
  alias EvoGit.Adapters.Git

  @doc """
  Processes subagent tool calls: spawns subagents, merges results.
  Returns `{indexed_results, merge_message}`.

  ## Options

    * `:sync_commit_fn` — callback `fn(state)` for syncing commit after tool execution (required)
  """
  @spec process_subagent_calls(
          indexed_calls :: [{map(), non_neg_integer()}],
          state :: LoopState.t(),
          opts :: keyword()
        ) :: {list(), String.t() | nil}
  def process_subagent_calls([], _state, _opts), do: {[], nil}

  def process_subagent_calls(indexed_calls, state, opts) do
    sync_commit_fn = Keyword.fetch!(opts, :sync_commit_fn)

    # Validate calls: separate valid from those missing required 'path' argument.
    # Invalid calls get immediate error results fed back to the LLM so it can correct them.
    {valid_calls, invalid_results} = split_valid_subagent_calls(indexed_calls)

    foreign_repo_commits = AgentScheduler.get_foreign_repo_commits(state.agent_id)
    spec_results = build_subagent_specs(valid_calls, state, foreign_repo_commits)

    # Separate valid AgentSpecs from path-resolution errors
    {subagent_specs, path_errors} =
      Enum.split_with(spec_results, &is_struct(&1, AgentSpec))

    # Convert path-resolution errors to invalid result format for LLM feedback
    path_error_results =
      Enum.map(path_errors, fn {:error, {call, index, error_msg}} ->
        tool_call_id = Map.get(call, :id) || call.name || "unknown"
        {index, tool_call_id, call.name, "Error: #{error_msg}"}
      end)

    # The parent agent commits its pending changes before spawning subagents.
    # Runs in the agent process (this process), using Process.get(:repo_path).
    EvoGit.AgentScheduler.Dispatch.commit_pending_in_worktree()

    results = AgentScheduler.spawn_sub_agents(subagent_specs)

    {:ok, agent_state} = AgentScheduler.get_agent_state(state.agent_id)
    parent_commit = agent_state.phylo_node.current_commit

    # Separate same-repo and cross-repo results
    # Cross-repo subagents commit to their own repo, no merge needed into parent
    {same_repo_shas, cross_repo_details} =
      Enum.reduce(Enum.zip(subagent_specs, results), {[], []}, fn {spec, result},
                                                                  {shas, details} ->
        case result do
          {:ok, %Result{commit_sha: sha}} when is_binary(sha) ->
            if spec.repo_id == :primary do
              {[sha | shas], details}
            else
              {shas, [{spec.repo_id, sha} | details]}
            end

          _ ->
            {shas, details}
        end
      end)

    successful_shas = Enum.reverse(same_repo_shas)
    cross_repo_details = Enum.reverse(cross_repo_details)

    repo_path = Process.get(:repo_path) || raise "Missing repo_path in process dictionary"

    cross_repo_note =
      if cross_repo_details != [] do
        details_str =
          cross_repo_details
          |> Enum.map(fn {repo_id, sha} -> "  - #{repo_id}: #{sha}" end)
          |> Enum.join("\n")

        "\nSystem Note: #{length(cross_repo_details)} cross-repo subagent(s) completed in foreign repositories:\n#{details_str}"
      else
        ""
      end

    # Skip merge if no same-repo subagents returned successful commits
    merge_message =
      if successful_shas == [] do
        if cross_repo_details != [] do
          cross_repo_note
        else
          nil
        end
      else
        perform_merge(repo_path, successful_shas, parent_commit, cross_repo_note)
      end

    # Only delete branches for same-repo subagents
    same_repo_branches =
      Enum.zip(subagent_specs, results)
      |> Enum.filter(fn {spec, result} ->
        spec.repo_id == :primary and match?({:ok, %Result{branch: _}}, result)
      end)
      |> Enum.map(fn {_, {:ok, %Result{branch: branch}}} -> branch end)

    Enum.each(same_repo_branches, fn branch ->
      Git.delete_branch(repo_path, branch)
    end)

    # Sync current_commit after subagents complete (parent worktree state may have changed)
    sync_commit_fn.(state)

    indexed_results =
      Enum.zip(valid_calls, results)
      |> Enum.map(fn {{call, index}, result} ->
        process_subagent_result(call, index, result, state)
      end)

    all_results = indexed_results ++ path_error_results ++ Enum.reverse(invalid_results)

    {all_results, merge_message}
  end

  @doc """
  Builds AgentSpec structs from subagent tool calls.

  Resolves paths (absolute for cross-repo, relative for same-repo), loads
  context nodes, and creates specs suitable for the scheduler.

  Returns a list where each element is either an `%AgentSpec{}` (for valid calls)
  or `{:error, {call, index, error_message}}` (for calls with unresolvable paths).
  """
  @spec build_subagent_specs(
          indexed_calls :: [{map(), non_neg_integer()}],
          state :: LoopState.t(),
          foreign_repo_commits :: %{atom() => String.t()}
        ) :: [AgentSpec.t() | {:error, {map(), non_neg_integer(), String.t()}}]
  def build_subagent_specs(indexed_calls, state, foreign_repo_commits \\ %{}) do
    {:ok, parent_state} = AgentScheduler.get_agent_state(state.agent_id)

    # Get foreign repos from the agent's inherited state (per-task, not global)
    foreign_repos = state.foreign_repos

    Enum.map(indexed_calls, fn {call, index} ->
      mod = subagent_module_for(call.name, state)
      raw_path = Map.get(call.arguments, "path")
      objective = Map.get(call.arguments, "objective")
      commit_id = Map.get(call.arguments, "commit_id")

      # Determine if this is a cross-repo delegation (absolute path) or same-repo (relative)
      case resolve_subagent_path(raw_path, parent_state, foreign_repos) do
        {:ok, target_repo_id, target_repo_root, resolved_rel_path} ->
          # If the LLM passed a file path, use its parent directory instead
          path =
            if File.regular?(Path.join(target_repo_root, resolved_rel_path)) do
              resolved_rel_path
              |> Path.dirname()
              |> ContextNode.normalize_relpath()
            else
              resolved_rel_path
            end

          # Load context node with the target repo_id
          sub_context_node =
            if target_repo_id == :primary do
              ContextNode.load(path, parent_state.phylo_node.repo)
            else
              # For foreign repos, use the foreign repo root as the base
              ContextNode.load(path, target_repo_root, target_repo_id)
            end

          # For foreign repo subagents, we need the foreign repo's HEAD commit (the primary
          # repo's commit SHA doesn't exist in the foreign repo's git database).
          sub_phylo_node =
            if target_repo_id == :primary do
              # Same-repo subagent: inherit parent's commit chain
              base_commit = commit_id || parent_state.phylo_node.current_commit

              %PhyloGraphNode{
                repo: parent_state.phylo_node.repo,
                base_commit: base_commit,
                current_commit: base_commit
              }
            else
              # Foreign repo subagent: use tracked commit from previous subagent completions,
              # falling back to the foreign repo's HEAD if no tracked commit exists.
              tracked_commit = Map.get(foreign_repo_commits, target_repo_id)

              {base, current} =
                if tracked_commit do
                  {tracked_commit, tracked_commit}
                else
                  {:ok, foreign_head} = Git.rev_parse(target_repo_root)
                  {foreign_head, foreign_head}
                end

              %PhyloGraphNode{
                repo: target_repo_root,
                base_commit: base,
                current_commit: current
              }
            end

          AgentSpec.new(sub_context_node, sub_phylo_node, mod, objective,
            repo_id: target_repo_id,
            foreign_repos: foreign_repos
          )

        {:error, error_msg} ->
          {:error, {call, index, error_msg}}
      end
    end)
  end

  @doc """
  Resolves a raw path to a tuple of `{:ok, repo_id, repo_root, relative_path}` or
  `{:error, error_message}`.

  Absolute paths are resolved against foreign repos first, then the primary repo.
  Relative paths stay within the parent agent's repo.

  For foreign repos, agents are encouraged to use the repository root path
  so subagents can discover the codebase layout via CONTEXT.md routing tables.

  Returns `{:error, message}` when an absolute path cannot be resolved to any known
  repo, providing a clear error message for the LLM to self-correct.
  """
  @spec resolve_subagent_path(
          raw_path :: String.t() | nil,
          parent_state :: map(),
          foreign_repos :: [ForeignRepo.t()]
        ) :: {:ok, atom(), String.t(), String.t()} | {:error, String.t()}
  def resolve_subagent_path(raw_path, parent_state, foreign_repos) do
    if ForeignRepo.absolute_path?(raw_path) do
      # Absolute path — resolve to the correct foreign repo, falling back to primary
      case ForeignRepo.resolve_path(foreign_repos, raw_path) do
        {:ok, repo_id, rel_path} ->
          repo = Enum.find(foreign_repos, &(&1.id == repo_id))
          {:ok, repo_id, repo.root, rel_path}

        {:error, :not_in_any_repo} ->
          # Not in any registered foreign repo. Try the primary repo root directly,
          # since it may not be in the foreign_repos list.
          primary_root = parent_state.phylo_node.repo

          case foreign_repo_match_root(primary_root, raw_path) do
            {:ok, rel_path} ->
              Logger.warning(
                "Agent: Absolute path '#{raw_path}' resolved in primary repo as '#{rel_path}'"
              )

              {:ok, :primary, primary_root, rel_path}

            :not_in_repo ->
              available =
                foreign_repos
                |> Enum.map(& &1.root)
                |> Enum.join(", ")

              msg =
                "Absolute path '#{raw_path}' is not within the primary repo (#{primary_root})" <>
                  " or any configured foreign repo" <>
                  if(available != "", do: " (#{available})", else: "") <>
                  " Hint: verify the path is correct, or use the `-R <id:>path` flag to register foreign repos."

              {:error, msg}
          end
      end
    else
      # Relative path — same repo as parent
      normalized = ContextNode.normalize_relpath(raw_path)
      {:ok, :primary, parent_state.phylo_node.repo, normalized}
    end
  end

  # Checks if an absolute path is under a given repo root.
  # Returns {:ok, relative_path} or :not_in_repo.
  defp foreign_repo_match_root(root, abs_path) when is_binary(root) and is_binary(abs_path) do
    root = String.trim_trailing(root, "/")
    expanded = Path.expand(abs_path)

    if String.starts_with?(expanded, root <> "/") or expanded == root do
      relative =
        expanded
        |> Path.relative_to(root)
        |> then(fn
          "" -> "./"
          "." -> "./"
          p -> if String.starts_with?(p, "./"), do: p, else: "./" <> p
        end)

      {:ok, relative}
    else
      :not_in_repo
    end
  end

  @doc """
  Processes an individual subagent result into an indexed result tuple.

  Returns `{index, tool_call_id, tool_name, output}`.
  """
  @spec process_subagent_result(
          call :: map(),
          index :: non_neg_integer(),
          result :: term(),
          state :: LoopState.t()
        ) :: {non_neg_integer(), String.t(), String.t(), String.t()}
  def process_subagent_result(call, index, result, _state) do
    output = format_subagent_result(result)

    tool_call_id = Map.get(call, :id) || call.name || call.id || "unknown"
    {index, tool_call_id, call.name, output}
  end

  @doc """
  Formats a subagent result for inclusion in the LLM context.
  """
  @spec format_subagent_result(term()) :: String.t()
  def format_subagent_result({:error, :path_ignored}) do
    "Error: Cannot spawn subagent in an ignored folder. The current working directory is ignored by git. Hint: the path must not be gitignored — if the folder is needed, ensure it is tracked by git (not listed in .gitignore)."
  end

  def format_subagent_result({:error, {:foreign_repo_read_only, msg}}) do
    "Error: #{msg}"
  end

  def format_subagent_result({:error, {:spatial_contract_violation, msg}}) do
    "Error: #{msg}"
  end

  def format_subagent_result({:error, :path_not_exist}) do
    """
    Error: The assigned node path does not exist in the repository.
    Please verify that the path is correct and is in the repository.
    Note: git does not track empty directories,
    - If the path is a directory, ensure that the path contains at least one tracked file (empty CONTEXT.md or .gitkeep is a common choice), you can use the `make_dir` tool to create a directory and auto create a tracked file within and commit it.
    - If the path is a file, ensure that the file is tracked by git. You can use the `create_files` tool to create the file and commit it.
    """
  end

  def format_subagent_result({:error, :max_depth_exceeded}) do
    "Error: Maximum subagent recursion depth reached. Hint: complete the work at the current level instead of spawning further subagents, or report back to the parent agent."
  end

  def format_subagent_result({:error, reason})
      when reason in [:worktree_creation_failed, :agent_max_retries_exceeded] do
    "Error: Subagent failed due to an infrastructure/runtime issue (#{reason}). Hint: this may be a transient system error — retry the spawn once, and if it persists report the issue to the user."
  end

  def format_subagent_result({:error, :unknown_error}) do
    "Error: An unexpected error occurred while running the subagent. Hint: please retry the spawn once, and if it persists report the issue to the user."
  end

  def format_subagent_result({:error, reason}) do
    "Error: Subagent failed due to an unexpected error (#{inspect(reason)}). Please retry the spawn or report this issue to the user if it persists."
  end

  def format_subagent_result({:ok, %Result{result: result, commit_sha: commit_sha}}) do
    """
    # Result
    #{result}

    # Final Commit
    #{commit_sha}
    """
    |> String.trim()
  end

  def format_subagent_result(text) when is_binary(text), do: text
  def format_subagent_result(other), do: inspect(other)

  # --- Private Helpers ---

  # Separates indexed subagent calls into valid (have a path) and invalid (missing path).
  # Invalid calls get immediate error results to feed back to the LLM.
  defp split_valid_subagent_calls(indexed_calls) do
    Enum.reduce(indexed_calls, {[], []}, fn {call, index} = indexed_call,
                                            {valid_acc, invalid_acc} ->
      raw_path = Map.get(call.arguments, "path")

      if is_nil(raw_path) or raw_path == "" do
        tool_call_id = Map.get(call, :id) || call.name || "unknown"

        error_msg =
          "Error: Missing required 'path' argument for subagent tool '#{call.name}'. Please specify a relative or absolute path for the subagent to operate in."

        {valid_acc, [{index, tool_call_id, call.name, error_msg} | invalid_acc]}
      else
        {[indexed_call | valid_acc], invalid_acc}
      end
    end)
  end

  defp perform_merge(repo_path, successful_shas, parent_commit, cross_repo_note) do
    case Git.merge_octopus(repo_path, successful_shas) do
      {:ok, output} ->
        # Check if any actual changes were made by comparing commits
        case Git.rev_parse(repo_path) do
          {:ok, ^parent_commit} ->
            # No changes - all subagents returned the same commit
            nil

          {:ok, _new_commit} ->
            """
            System Note: Successfully auto-merged changes from subagents.#{cross_repo_note}
            Merge output:
            #{output}
            """

          _error ->
            """
            System Note: Successfully auto-merged changes from subagents.#{cross_repo_note}
            Merge output:
            #{output}
            """
        end

      {:conflict, output} ->
        {:ok, files} = Git.conflict_files(repo_path)

        conflict_files_list = Enum.join(files, "\n")

        """
        System Note: Auto-merging subagent changes resulted in conflicts.#{cross_repo_note}
        Merge output:
        #{output}

        Conflicting files:
        #{conflict_files_list}
        """

      {:error, code, output} ->
        """
        System Note: Failed to auto-merge subagent changes (exit code #{code}).#{cross_repo_note}
        Merge output:
        #{output}
        """
    end
  end

  # Looks up the agent module for a given subagent tool name.
  # Accesses the agent's `subagent_modules/0` via state.
  defp subagent_module_for(tool_name, state) do
    Enum.find(state.agent_module.subagent_modules(), fn mod ->
      mod.subagent_tool_name() == tool_name
    end)
  end
end
