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
  alias EvoGit.Agent.SubagentSchemas
  alias EvoGit.Agent.Usage
  alias EvoGit.AgentScheduler
  alias EvoGit.AgentSpec
  alias EvoGit.Core.ForeignRepo
  alias EvoGit.Core.ContextNode
  alias EvoGit.Core.PhyloGraphNode
  alias EvoGit.Adapters.Git
  alias EvoGit.Platform

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
        ) :: {list(), String.t() | nil, Usage.t()}
  def process_subagent_calls([], _state, opts) when is_list(opts), do: {[], nil, Usage.zero()}

  def process_subagent_calls(indexed_calls, state, opts) when is_list(opts) do
    sync_commit_fn = Keyword.fetch!(opts, :sync_commit_fn)

    # Validate calls: separate valid from those missing required 'path' argument.
    # Invalid calls get immediate error results fed back to the LLM so it can correct them.
    {valid_calls, invalid_results} = split_valid_subagent_calls(indexed_calls)

    {subagent_specs, path_error_results} = build_specs_and_errors(valid_calls, state)

    # The parent agent commits its pending changes before spawning subagents.
    # Runs in the agent process (this process), using Process.get(:repo_path).
    EvoGit.AgentScheduler.Dispatch.commit_pending_in_worktree()

    results = AgentScheduler.spawn_sub_agents(subagent_specs)

    # Handle scheduler errors (e.g. scheduler paused) — spawn_sub_agents returns
    # {:error, reason} instead of a results list. Convert to per-subagent error
    # results so the parent agent gets a clear message.
    if match?({:error, _}, results) do
      all_results =
        scheduler_error_results(valid_calls, results, path_error_results, invalid_results)

      {all_results, nil, Usage.zero()}
    else
      {:ok, agent_state} = AgentScheduler.get_agent_state(state.agent_id)
      parent_commit = agent_state.phylo_node.current_commit
      parent_repo_id = agent_state.repo_id

      # Separate same-repo and cross-repo results.
      # "Same repo" means the child's repo id equals the parent's repo id — a
      # foreign-repo parent's own children are same-repo too. Cross-repo
      # subagents commit to their own repo, no merge needed into parent.
      {successful_shas, cross_repo_details} =
        collect_mergeable_results(subagent_specs, results, parent_repo_id)

      repo_path = Process.get(:repo_path) || raise "Missing repo_path in process dictionary"

      cross_repo_note = build_cross_repo_note(cross_repo_details)

      merge_message =
        build_merge_message(
          repo_path,
          successful_shas,
          parent_commit,
          cross_repo_note,
          cross_repo_details
        )

      # Only delete branches for same-repo subagents
      delete_same_repo_branches(subagent_specs, results, repo_path, parent_repo_id)

      # Sync current_commit after subagents complete (parent worktree state may have changed)
      sync_commit_fn.(state)

      indexed_results = build_indexed_results(valid_calls, results, state)

      # Accumulate subagent usages for task-level token tracking
      subagent_usage = accumulate_subagent_usages(results)

      all_results = indexed_results ++ path_error_results ++ Enum.reverse(invalid_results)

      {all_results, merge_message, subagent_usage}
    end
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
          foreign_repo_commits :: %{String.t() => String.t()}
        ) :: [AgentSpec.t() | {:error, {map(), non_neg_integer(), String.t()}}]
  def build_subagent_specs(indexed_calls, state, foreign_repo_commits \\ %{})
      when is_list(indexed_calls) and is_map(foreign_repo_commits) do
    {:ok, parent_state} = AgentScheduler.get_agent_state(state.agent_id)
    repo_path = Process.get(:repo_path) || raise "Missing repo_path in process dictionary"
    parent_repo_id = parent_state.repo_id

    # Get foreign repos from the agent's inherited state (per-task, not global)
    foreign_repos = state.foreign_repos

    # Subagents inherit the rendered repo-notes block (markdown text) from the
    # parent — the root agent already rendered it from the primary repo tree,
    # so subagents render it in their own context without re-detection.
    repo_notes = state.repo_notes

    # Thread the parent's resolved per-task tmpdir (set by the parent's Runner
    # via `EvoGit.TaskTmpdir.put_current/1`) into every child spec so the child
    # Runner re-installs the SAME dir instead of computing it from its own repo.
    # This matters for `:per_repo` mode (the dir must stay rooted at the TASK's
    # primary repo, not the child's foreign repo); for `:system`/`:custom` the
    # threaded value is identical at every level. `nil` (e.g. direct/test
    # callers) leaves the child to compute it.
    task_tmpdir = EvoGit.TaskTmpdir.current()

    Enum.map(indexed_calls, fn {call, index} ->
      name = ReqLLM.ToolCall.name(call)
      args = ReqLLM.ToolCall.args_map(call)
      mod = SubagentSchemas.subagent_module_for(name, state.agent_module.subagent_modules())
      raw_path = Map.get(args, "path")
      objective = Map.get(args, "objective")

      commit_id =
        case Map.get(args, "commit_id") do
          "" -> nil
          v -> v
        end

      # Determine if this is a cross-repo delegation (absolute path) or same-repo (relative)
      case resolve_subagent_path(raw_path, repo_path, foreign_repos, parent_repo_id) do
        {:ok, target_repo_id, target_repo_root, resolved_rel_path} ->
          # A child is "same repo" when it targets the PARENT's own repo — a
          # relative path always does, and an absolute path may when the parent
          # itself runs inside a foreign repo.
          same_repo? = target_repo_id == parent_repo_id

          # If the LLM passed a file path, use its parent directory instead
          path =
            if File.regular?(Path.join(target_repo_root, resolved_rel_path)) do
              resolved_rel_path
              |> Path.dirname()
              |> ContextNode.normalize_relpath()
            else
              resolved_rel_path
            end

          # Load context node: same-repo children load against the parent's
          # worktree with the parent's repo id; cross-repo children load against
          # the target repo root with the target repo id.
          sub_context_node =
            if same_repo? do
              ContextNode.load(path, repo_path, parent_repo_id)
            else
              # For foreign repos, use the foreign repo root as the base
              ContextNode.load(path, target_repo_root, target_repo_id)
            end

          # For cross-repo subagents, we need the target repo's starting commit (the
          # primary repo's commit SHA doesn't exist in the foreign repo's git database).
          # The foreign repos list is threaded through so the per-repo `base_sha`
          # starting commit can be honored (see build_subagent_phylo_node/8).
          case build_subagent_phylo_node(
                 target_repo_id,
                 commit_id,
                 repo_path,
                 target_repo_root,
                 foreign_repo_commits,
                 parent_state,
                 foreign_repos,
                 same_repo?
               ) do
            {:ok, sub_phylo_node} ->
              AgentSpec.new(sub_context_node, sub_phylo_node, mod, objective,
                repo_id: target_repo_id,
                foreign_repos: foreign_repos,
                repo_notes: repo_notes,
                archive: parent_state.archive,
                model_id: parent_state.model_id,
                task_tmpdir: task_tmpdir
              )

            {:error, error_msg} ->
              {:error, {call, index, error_msg}}
          end

        {:error, error_msg} ->
          {:error, {call, index, error_msg}}
      end
    end)
  end

  @doc """
  Resolves a raw path to a tuple of `{:ok, repo_id, repo_root, relative_path}` or
  `{:error, error_message}`.

  Absolute paths are resolved against foreign repos first, then the primary repo.
  Relative paths stay within the parent agent's repo — they resolve to the PARENT's
  repo id (`parent_repo_id`), so a parent running inside a foreign repo delegates
  same-repo children with that foreign repo's id rather than `"primary"`.

  For foreign repos, agents are encouraged to use the repository root path
  so subagents can discover the codebase layout via CONTEXT.md routing tables.

  Returns `{:error, message}` when an absolute path cannot be resolved to any known
  repo, providing a clear error message for the LLM to self-correct.
  """
  @spec resolve_subagent_path(
          raw_path :: String.t() | nil,
          repo_path :: String.t(),
          foreign_repos :: [ForeignRepo.t()],
          parent_repo_id :: String.t()
        ) :: {:ok, String.t(), String.t(), String.t()} | {:error, String.t()}
  def resolve_subagent_path(raw_path, repo_path, foreign_repos, parent_repo_id \\ "primary") do
    if ForeignRepo.absolute_path?(raw_path) do
      # Absolute path — resolve to the correct foreign repo, falling back to primary.
      # `resolve/2` returns the base directory the relative path is taken from: a
      # writable foreign repo's persistent worktree when the path lies under it,
      # else the repo root. Using it as the base keeps the node path relative to
      # the worktree (`./src/foo` instead of `./.genesis/foreign_repos/<id>/src/foo`).
      case ForeignRepo.resolve(foreign_repos, raw_path) do
        {:ok, repo, base_dir, rel_path} ->
          {:ok, repo.id, base_dir, rel_path}

        {:error, :not_in_any_repo} ->
          # Not in any registered foreign repo. Try the primary repo root directly,
          # since it may not be in the foreign_repos list.
          primary_root = repo_path

          case foreign_repo_match_root(primary_root, raw_path) do
            {:ok, rel_path} ->
              Logger.warning(
                "Agent: Absolute path '#{raw_path}' resolved in primary repo as '#{rel_path}'"
              )

              {:ok, "primary", primary_root, rel_path}

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
      # Relative path — same repo as parent, so it carries the PARENT's repo id
      normalized = ContextNode.normalize_relpath(raw_path)
      {:ok, parent_repo_id, repo_path, normalized}
    end
  end

  # Checks if an absolute path is under a given repo root.
  # Returns {:ok, relative_path} or :not_in_repo.
  defp foreign_repo_match_root(root, abs_path) when is_binary(root) and is_binary(abs_path) do
    # Normalize separators to `/` so backslash-form UNC roots (the Windows
    # representation of WSL-shared-folder paths) relativize identically on
    # every host (`Path.relative_to/2` treats `\` as a literal character on
    # non-Windows hosts).
    root = root |> Platform.normalize_separators() |> Platform.trim_trailing_separators()
    expanded = abs_path |> Platform.safe_expand() |> Platform.normalize_separators()

    if EvoGit.Platform.path_under?(expanded, root) do
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
    name = ReqLLM.ToolCall.name(call)

    tool_call_id = call.id || name || "unknown"
    {index, tool_call_id, name, output}
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

  def format_subagent_result({:error, {:foreign_repo_write_not_root, msg}}) do
    "Error: #{msg}"
  end

  def format_subagent_result({:error, {:foreign_repo_write_serialized, msg}}) do
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

  def format_subagent_result({:error, :recovery_failed}) do
    "Error: The subagent exceeded its execution limit (ran out of turns) and could not complete its task in time. " <>
      "Hint: the objective was likely too large or complex for a single subagent. Try breaking the work into smaller, more focused sub-tasks, " <>
      "or complete the work directly at the current level instead of delegating."
  end

  def format_subagent_result({:error, :agent_max_retries_exceeded}) do
    "Error: Subagent failed due to an infrastructure/runtime issue (repeated crashes). " <>
      "Hint: this may be a transient system error — retry the spawn once, and if it persists report the issue to the user. "
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

  @doc false
  def accumulate_subagent_usages(results) do
    Enum.reduce(results, Usage.zero(), fn
      {:ok, %Result{usage: %Usage{} = usage}}, acc -> Usage.add(acc, usage)
      _, acc -> acc
    end)
  end

  # --- Private Helpers ---

  # Separates indexed subagent calls into valid (have a path) and invalid (missing path).
  # Invalid calls get immediate error results to feed back to the LLM.
  defp split_valid_subagent_calls(indexed_calls) when is_list(indexed_calls) do
    Enum.reduce(indexed_calls, {[], []}, fn {call, index} = indexed_call,
                                            {valid_acc, invalid_acc} ->
      name = ReqLLM.ToolCall.name(call)
      args = ReqLLM.ToolCall.args_map(call)
      raw_path = Map.get(args, "path")

      if is_nil(raw_path) or raw_path == "" do
        tool_call_id = call.id || name || "unknown"

        error_msg =
          "Error: Missing required 'path' argument for subagent tool '#{name}'. Please specify a relative or absolute path for the subagent to operate in."

        {valid_acc, [{index, tool_call_id, name, error_msg} | invalid_acc]}
      else
        {[indexed_call | valid_acc], invalid_acc}
      end
    end)
  end

  # Builds AgentSpecs for the valid calls and converts any path-resolution
  # errors into indexed error results for LLM feedback.
  # Returns `{subagent_specs, path_error_results}`.
  defp build_specs_and_errors(valid_calls, state) do
    foreign_repo_commits = AgentScheduler.get_foreign_repo_commits(state.agent_id)
    spec_results = build_subagent_specs(valid_calls, state, foreign_repo_commits)

    # Separate valid AgentSpecs from path-resolution errors
    {subagent_specs, path_errors} =
      Enum.split_with(spec_results, &is_struct(&1, AgentSpec))

    # Convert path-resolution errors to invalid result format for LLM feedback
    path_error_results =
      Enum.map(path_errors, fn {:error, {call, index, error_msg}} ->
        name = ReqLLM.ToolCall.name(call)
        tool_call_id = call.id || name || "unknown"
        {index, tool_call_id, name, "Error: #{error_msg}"}
      end)

    {subagent_specs, path_error_results}
  end

  # Converts a scheduler-level error (e.g. scheduler paused) from spawn_sub_agents
  # into per-subagent error results so the parent agent gets a clear message.
  defp scheduler_error_results(valid_calls, results, path_error_results, invalid_results) do
    error_results =
      Enum.map(valid_calls, fn {call, index} ->
        name = ReqLLM.ToolCall.name(call)
        tool_call_id = call.id || name || "unknown"
        {index, tool_call_id, name, format_subagent_result(results)}
      end)

    error_results ++ path_error_results ++ Enum.reverse(invalid_results)
  end

  # Separates subagent results into same-repo commit SHAs (mergeable into the
  # parent) and cross-repo details (committed to their own repo, no merge needed).
  # A child is same-repo when its repo id equals the PARENT's repo id — so a
  # foreign-repo parent's own children are mergeable into its worktree.
  # Returns `{successful_shas, cross_repo_details}`.
  defp collect_mergeable_results(subagent_specs, results, parent_repo_id) do
    {same_repo_shas, cross_repo_details} =
      Enum.reduce(Enum.zip(subagent_specs, results), {[], []}, fn {spec, result},
                                                                  {shas, details} ->
        case result do
          {:ok, %Result{commit_sha: sha}} when is_binary(sha) ->
            if spec.repo_id == parent_repo_id do
              {[sha | shas], details}
            else
              {shas, [{spec.repo_id, sha} | details]}
            end

          _ ->
            {shas, details}
        end
      end)

    {Enum.reverse(same_repo_shas), Enum.reverse(cross_repo_details)}
  end

  # Builds the system note describing cross-repo subagent completions,
  # or an empty string when there are none.
  defp build_cross_repo_note([]), do: ""

  defp build_cross_repo_note(cross_repo_details) do
    details_str =
      cross_repo_details
      |> Enum.map(fn {repo_id, sha} -> "  - #{repo_id}: #{sha}" end)
      |> Enum.join("\n")

    "\nSystem Note: #{length(cross_repo_details)} cross-repo subagent(s) completed in foreign repositories:\n#{details_str}"
  end

  # Skip merge if no same-repo subagents returned successful commits.
  defp build_merge_message(
         repo_path,
         successful_shas,
         parent_commit,
         cross_repo_note,
         cross_repo_details
       ) do
    cond do
      successful_shas == [] and cross_repo_details != [] -> cross_repo_note
      successful_shas == [] -> nil
      true -> perform_merge(repo_path, successful_shas, parent_commit, cross_repo_note)
    end
  end

  # Deletes branches of successful same-repo subagents (repo id == parent's).
  defp delete_same_repo_branches(subagent_specs, results, repo_path, parent_repo_id) do
    same_repo_branches =
      for {spec, {:ok, %Result{branch: branch}}} <- Enum.zip(subagent_specs, results),
          spec.repo_id == parent_repo_id do
        branch
      end

    Enum.each(same_repo_branches, fn branch ->
      Git.delete_branch(repo_path, branch)
    end)
  end

  # Formats each subagent result into an indexed result tuple for the LLM context.
  defp build_indexed_results(valid_calls, results, state) do
    Enum.zip(valid_calls, results)
    |> Enum.map(fn {{call, index}, result} ->
      process_subagent_result(call, index, result, state)
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

          _ ->
            """
            System Note: Successfully auto-merged changes from subagents.#{cross_repo_note}
            Merge output:
            #{output}
            """
        end

      {:error, {:conflict, output}} ->
        {:ok, files} = Git.conflict_files(repo_path)

        conflict_files_list = Enum.join(files, "\n")

        """
        System Note: Auto-merging subagent changes resulted in conflicts.#{cross_repo_note}
        Merge output:
        #{output}

        Conflicting files:
        #{conflict_files_list}

        Normally you have three options to handle this:

        1. **Resolve conflicts manually** — Edit the conflicting files to resolve the merge
           conflicts, then stage the resolved files with `git add <file>` and complete the
           merge with `git commit --no-edit` (or `git merge --continue`).

        2. **Abort the merge** — If the conflicts are too complex or not worth resolving,
           run `git merge --abort` to revert to the pre-merge state. You can then re-plan
           your approach to avoid the conflicting changes.

        3. **Partially accept changes from key branches** — First, run `git merge --abort`
           to revert to the pre-merge state. Then identify and merge only the important
           branches you want to keep with `git merge <branch-name>`. After those are
           successfully merged, you can re-run the remaining tasks or re-delegate work
           to subagents.
        """

      {:error, {code, output}} ->
        """
        System Note: Failed to auto-merge subagent changes (exit code #{code}).#{cross_repo_note}
        Merge output:
        #{output}
        """
    end
  end

  # Builds a PhyloGraphNode for a subagent, validating the commit_id for same-repo
  # subagents. For cross-repo subagents, uses tracked commits or foreign repo HEAD.
  #
  # Returns `{:ok, PhyloGraphNode.t()}` on success, or `{:error, error_message}` when
  # a user-provided commit_id does not exist in the repository (early validation so the
  # LLM gets a clear, actionable error instead of a generic retry-exhausted crash).
  defp build_subagent_phylo_node(
         _target_repo_id,
         commit_id,
         repo_path,
         _target_repo_root,
         _foreign_repo_commits,
         parent_state,
         _foreign_repos,
         true
       ) do
    # Same repo as the parent (a relative-path child, or an absolute-path child
    # pointing back into the parent's own repo): base off the parent's worktree and
    # its live current commit.
    if commit_id do
      case Git.rev_parse(repo_path, commit_id) do
        {:ok, _sha} ->
          {:ok,
           %PhyloGraphNode{
             repo: repo_path,
             base_commit: commit_id,
             current_commit: commit_id
           }}

        {:error, {_code, msg}} ->
          {:error,
           "Error: The specified commit ID '#{commit_id}' does not exist in the repository. Please verify the commit SHA is correct and exists in the current repository's git history. Git error: #{msg}"}
      end
    else
      base = parent_state.phylo_node.current_commit

      {:ok,
       %PhyloGraphNode{
         repo: repo_path,
         base_commit: base,
         current_commit: base
       }}
    end
  end

  defp build_subagent_phylo_node(
         target_repo_id,
         _commit_id,
         _repo_path,
         target_repo_root,
         foreign_repo_commits,
         _parent_state,
         foreign_repos,
         false
       ) do
    # Cross-repo subagent: resolve the phylo node's starting commit with this
    # precedence:
    #   1. The foreign repo entry's per-repo `base_sha` (the task-level starting
    #      commit for this repo, when non-nil) — resolved in the foreign repo.
    #   2. The tracked commit from previous subagent completions in this repo
    #      (the `foreign_repo_commits` map — the previous subagent's latest
    #      commit in this foreign repo).
    #   3. The foreign repo's HEAD (existing behavior).
    #
    # A missing/invalid foreign repo path (a git error or `{:error, {:enoent, _}}`
    # from `Git.run/2`'s pre-check) surfaces as a descriptive `{:error, msg}` so
    # the caller feeds it back to the LLM — never a bare MatchError crash.
    repo_entry =
      foreign_repos
      |> Enum.map(&ForeignRepo.normalize/1)
      |> Enum.find(&(&1 && &1.id == target_repo_id))

    case resolve_foreign_phylo_commit(
           target_repo_id,
           target_repo_root,
           repo_entry,
           foreign_repo_commits
         ) do
      {:ok, commit} ->
        {:ok,
         %PhyloGraphNode{
           repo: target_repo_root,
           base_commit: commit,
           current_commit: commit
         }}

      {:error, msg} ->
        {:error, msg}
    end
  end

  # Resolves the starting commit for a foreign-repo subagent phylo node.
  #
  # Precedence:
  #   1. The foreign repo entry's per-repo `base_sha` (when non-nil) — the
  #      task-level starting commit for this repo, resolved in the foreign repo.
  #   2. The tracked commit from previous subagent completions in this repo.
  #   3. The foreign repo's HEAD.
  #
  # Returns `{:ok, sha}` or `{:error, msg}` — never raises.
  defp resolve_foreign_phylo_commit(
         target_repo_id,
         target_repo_root,
         repo_entry,
         foreign_repo_commits
       ) do
    base_sha = if repo_entry, do: repo_entry.base_sha, else: nil

    if is_binary(base_sha) and base_sha != "" do
      case Git.rev_parse(target_repo_root, base_sha) do
        {:ok, sha} ->
          {:ok, sha}

        {:error, error} ->
          {:error,
           "Error: base commit '#{base_sha}' for foreign repository '#{target_repo_id}' does not exist in that repository's history." <>
             git_error_detail(error)}
      end
    else
      case Map.get(foreign_repo_commits, target_repo_id) do
        nil ->
          case Git.rev_parse(target_repo_root) do
            {:ok, foreign_head} ->
              {:ok, foreign_head}

            {:error, error} ->
              {:error,
               "Error: foreign repository path does not exist or is not a git repository: #{target_repo_root}" <>
                 git_error_detail(error)}
          end

        tracked_commit ->
          {:ok, tracked_commit}
      end
    end
  end

  # Appends git's error detail (the `{code, msg}` / `{:enoent, msg}` shapes from
  # `Git.run/2`) when available; empty string otherwise.
  defp git_error_detail({code, msg}) when is_integer(code) and is_binary(msg),
    do: " Git error: #{code}: #{msg}"

  defp git_error_detail({:enoent, msg}) when is_binary(msg), do: " Git error: #{msg}"
  defp git_error_detail(_other), do: ""
end
