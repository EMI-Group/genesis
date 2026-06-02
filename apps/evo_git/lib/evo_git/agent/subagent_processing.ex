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
          stream_event_fn: &stream_event/2,
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

    * `:stream_event_fn` — callback `fn(agent_id, type, data)` for streaming events (required)
    * `:sync_commit_fn` — callback `fn(state)` for syncing commit after tool execution (required)
  """
  @spec process_subagent_calls(
          indexed_calls :: [{map(), non_neg_integer()}],
          state :: LoopState.t(),
          opts :: keyword()
        ) :: {list(), String.t() | nil}
  def process_subagent_calls([], _state, _opts), do: {[], nil}

  def process_subagent_calls(indexed_calls, state, opts) do
    stream_event_fn = Keyword.fetch!(opts, :stream_event_fn)
    sync_commit_fn = Keyword.fetch!(opts, :sync_commit_fn)

    # Validate calls: separate valid from those missing required 'path' argument.
    # Invalid calls get immediate error results fed back to the LLM so it can correct them.
    {valid_calls, invalid_results} = split_valid_subagent_calls(indexed_calls)

    subagent_specs = build_subagent_specs(valid_calls, state)
    results = AgentScheduler.spawn_sub_agents(subagent_specs)

    {:ok, agent_state} = AgentScheduler.get_agent_state(state.agent_id)
    parent_commit = agent_state.phylo_node.current_commit

    # Separate same-repo and cross-repo results
    # Cross-repo subagents commit to their own repo, no merge needed into parent
    {same_repo_shas, cross_repo_count} =
      Enum.reduce(Enum.zip(subagent_specs, results), {[], 0}, fn {spec, result}, {shas, count} ->
        case result do
          {:ok, %Result{commit_sha: sha}} when is_binary(sha) ->
            if spec.repo_id == :primary do
              {[sha | shas], count}
            else
              {shas, count + 1}
            end

          _ ->
            {shas, count}
        end
      end)

    successful_shas = Enum.reverse(same_repo_shas)

    repo_path = Process.get(:repo_path) || raise "Missing repo_path in process dictionary"

    cross_repo_note =
      if cross_repo_count > 0 do
        "\nSystem Note: #{cross_repo_count} read-only cross-repo subagent(s) completed in foreign repositories."
      else
        ""
      end

    # Skip merge if no same-repo subagents returned successful commits
    merge_message =
      if successful_shas == [] do
        if cross_repo_count > 0 do
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
        process_subagent_result(call, index, result, state, stream_event_fn)
      end)

    all_results = indexed_results ++ Enum.reverse(invalid_results)

    {all_results, merge_message}
  end

  @doc """
  Builds AgentSpec structs from subagent tool calls.

  Resolves paths (absolute for cross-repo, relative for same-repo), loads
  context nodes, and creates specs suitable for the scheduler.
  """
  @spec build_subagent_specs(
          indexed_calls :: [{map(), non_neg_integer()}],
          state :: LoopState.t()
        ) :: [AgentSpec.t()]
  def build_subagent_specs(indexed_calls, state) do
    {:ok, parent_state} = AgentScheduler.get_agent_state(state.agent_id)

    # Get all registered repos for path resolution
    foreign_repos = AgentScheduler.get_foreign_repos()

    Enum.map(indexed_calls, fn {call, _index} ->
      mod = subagent_module_for(call.name, state)
      raw_path = Map.get(call.arguments, "path")
      objective = Map.get(call.arguments, "objective")
      commit_id = Map.get(call.arguments, "commit_id")

      # Determine if this is a cross-repo delegation (absolute path) or same-repo (relative)
      {target_repo_id, target_repo_root, resolved_rel_path} =
        resolve_subagent_path(raw_path, parent_state, foreign_repos)

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

      # Use specified commit_id, or default to current commit (only meaningful for primary repo)
      base_commit = commit_id || parent_state.phylo_node.current_commit

      sub_phylo_node = %PhyloGraphNode{
        repo: parent_state.phylo_node.repo,
        base_commit: base_commit,
        current_commit: base_commit
      }

      AgentSpec.new(sub_context_node, sub_phylo_node, mod, objective, repo_id: target_repo_id)
    end)
  end

  @doc """
  Resolves a raw path to a tuple of `{repo_id, repo_root, relative_path}`.

  Absolute paths are resolved against foreign repos first, then the primary repo.
  Relative paths stay within the parent agent's repo.

  For foreign repos, agents are encouraged to use the repository root path
  so subagents can discover the codebase layout via CONTEXT.md routing tables.
  """
  @spec resolve_subagent_path(
          raw_path :: String.t() | nil,
          parent_state :: map(),
          foreign_repos :: [ForeignRepo.t()]
        ) :: {atom(), String.t(), String.t()}
  def resolve_subagent_path(raw_path, parent_state, foreign_repos) do
    if ForeignRepo.absolute_path?(raw_path) do
      # Absolute path — resolve to the correct foreign repo
      case ForeignRepo.resolve_path(foreign_repos, raw_path) do
        {:ok, repo_id, rel_path} ->
          repo = Enum.find(foreign_repos, &(&1.id == repo_id))
          {repo_id, repo.root, rel_path}

        {:error, :not_in_any_repo} ->
          # Not in any known repo — treat as primary, let it fail naturally
          Logger.warning(
            "Agent: Absolute path '#{raw_path}' not in any known repo, treating as primary"
          )

          {:primary, parent_state.phylo_node.repo, ContextNode.normalize_relpath(raw_path)}
      end
    else
      # Relative path — same repo as parent
      normalized = ContextNode.normalize_relpath(raw_path)
      {:primary, parent_state.phylo_node.repo, normalized}
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
          state :: LoopState.t(),
          stream_event_fn :: function()
        ) :: {non_neg_integer(), String.t(), String.t(), String.t()}
  def process_subagent_result(call, index, result, state, stream_event_fn) do
    stream_event_fn.(state.agent_id, "TOOL_CALL_END", %{name: call.name})

    output = format_subagent_result(result)

    tool_call_id = Map.get(call, :id) || call.name || call.id || "unknown"
    {index, tool_call_id, call.name, output}
  end

  @doc """
  Formats a subagent result for inclusion in the LLM context.
  """
  @spec format_subagent_result(term()) :: String.t()
  def format_subagent_result({:error, :path_ignored}) do
    "Error: Cannot spawn subagent in an ignored folder. The current working directory is ignored by git."
  end

  def format_subagent_result({:error, {:foreign_repo_read_only, msg}}) do
    "Error: #{msg}"
  end

  def format_subagent_result({:error, :path_not_exist}) do
    """
    Error: The assigned node path does not exist in the repository.
    Please verify that the path is correct and is in the repository.
    Note: git does not track empty directories,
    - If the path is a directory, ensure that the path contains at least one tracked file (empty CONTEXT.md or .gitkeep is a common choice), you can use the `make_dir` tool to create a directory and auto create a tracked file within and commit it.
    - If the path is a file, ensure that the file is tracked by git. You can use the `touch` tool to create an empty file and auto commit it.
    """
  end

  def format_subagent_result({:error, reason}) do
    "Error: Subagent failed: #{inspect(reason)}"
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
    Enum.reduce(indexed_calls, {[], []}, fn {call, index} = indexed_call, {valid_acc, invalid_acc} ->
      raw_path = Map.get(call.arguments, "path")

      if is_nil(raw_path) or raw_path == "" do
        tool_call_id = Map.get(call, :id) || call.name || "unknown"
        error_msg = "Error: Missing required 'path' argument for subagent tool '#{call.name}'. Please specify a relative or absolute path for the subagent to operate in."
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
