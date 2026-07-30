defmodule EvoGit.Agent.Runner do
  @moduledoc """
  Shared agent loop runner — extracted from `EvoGit.Agent.__using__/1`.

  Contains the agent turn loop logic ONCE, instead of macro-injecting it into
  every agent module. Agent-specific behavior is accessed via callbacks on
  `state.agent_module` (system_prompt, available_tools, subagent_modules, etc.).

  The agent module's `run/2` delegates here: `Runner.run(__MODULE__, objective, dispatch_ctx)`.
  """

  require Logger
  use Retry

  alias EvoGit.Adapters.Git
  alias EvoGit.Agent.LoopState
  import ReqLLM.Context, only: [user: 1, system: 1]

  @complete_tool "complete_task"

  @doc """
  Runs the agent synchronously, blocking until it completes.

  The agent's worktree path is set once at startup via
  `Process.get(:repo_path)` and stored in `LoopState.repo_path`.
  Agent state is synced to ETS every turn for dashboard visibility.
  The dashboard reads the `context` field from `evogit_agent_state` table.

  The `dispatch_ctx` keyword list is required: it drives worktree setup,
  retry handling, and process-dict initialization before the agent loop.
  """
  def run(agent_module, objective, dispatch_ctx) do
    setup_dispatch_context(dispatch_ctx)

    # The agent process owns git operations. After the agent finishes
    # (any exit path), commit any pending changes as a best-effort
    # fallback so the worktree is clean before the scheduler processes
    # the result. The scheduler never touches git directly.
    try do
      do_run(agent_module, objective)
    after
      EvoGit.AgentScheduler.Dispatch.commit_pending_in_worktree()
    end
  end

  defp do_run(agent_module, objective) do
    agent_id = EvoGit.AgentScheduler.current_agent_id()

    {:ok, agent_state} = EvoGit.AgentScheduler.get_agent_state(agent_id)

    # Validate that the assigned node path exists
    node_path = agent_state.context_node.path
    repo_path = Process.get(:repo_path)
    full_path = Path.join(repo_path, node_path)

    unless File.exists?(full_path) do
      Logger.error(
        "Agent #{agent_id}: Assigned node path does not exist: #{full_path} (node_path=#{node_path})"
      )

      {:error, :path_not_exist}
    else
      # Build context tree and merge into first user prompt.
      # Use :repo_path (set by scheduler to worktree path).
      #
      # The first user prompt is framed as two distinct blocks so the LLM
      # can unambiguously tell where the descriptive context/environment
      # ends and the actionable objective begins:
      #
      #   <context>...</context>
      #   ---
      #   <objective>...</objective>
      #
      # Empty/blank sections are dropped so we never emit dangling rules,
      # empty blocks, or doubled delimiters.
      context_tree =
        EvoGit.Agent.ContextBuilder.build_dynamic_context(%{
          node_path: node_path,
          repo_path: repo_path
        })

      foreign_repos_section =
        EvoGit.Agent.ContextBuilder.build_foreign_repos_section(agent_state.foreign_repos)

      context_body =
        [context_tree, foreign_repos_section]
        |> Enum.reject(&EvoGit.Agent.ContextBuilder.blank?/1)
        |> Enum.join("\n\n")

      objective_body =
        if EvoGit.Agent.ContextBuilder.blank?(objective), do: "", else: to_string(objective)

      combined_prompt =
        [
          EvoGit.Agent.ContextBuilder.context_block(context_body),
          EvoGit.Agent.ContextBuilder.objective_block(objective_body)
        ]
        |> Enum.reject(&EvoGit.Agent.ContextBuilder.blank?/1)
        |> Enum.join("\n\n---\n\n")

      context = ReqLLM.Context.new([system(agent_module.system_prompt()), user(combined_prompt)])
      # Tag initial messages (system + user prompt) with turn 0
      context = EvoGit.Agent.ContextBuilder.tag_context_messages_with_turn(context, 0)

      # Load skill schemas hierarchically — only skills enabled in the
      # Context Tree (from root to this agent's node) are available.
      repo_root = Process.get(:evogit_repo_root)

      skill_schemas =
        if repo_root && is_binary(repo_root) do
          all_skills = EvoGit.Skills.load_skills(repo_root)
          skill_names = EvoGit.Skills.hierarchical_skill_names(node_path, repo_path)

          all_skills
          |> EvoGit.Skills.filter_skills(skill_names)
          |> EvoGit.Skills.to_tool_schemas()
        else
          []
        end

      max_turns = agent_state.max_turns

      state = %LoopState{
        agent_id: agent_id,
        agent_module: agent_module,
        depth: EvoGit.AgentScheduler.current_depth(),
        node_path: node_path,
        repo_path: repo_path,
        context: context,
        max_turns: max_turns,
        skill_schemas: skill_schemas,
        foreign_repos: agent_state.foreign_repos,
        delegation_level: agent_module.delegation_level()
      }

      # Sync initial context to ETS for dashboard
      EvoGit.AgentScheduler.update_agent_context(agent_id, context)
      EvoGit.Agent.ContextBuilder.sync_turn_to_ets(agent_id, 0)

      Process.put(:delegation_hints, %{})
      Process.put(:read_delegation_hints, %{})
      loop(state)
    end
  end

  defp setup_dispatch_context(ctx) do
    agent_id = Keyword.fetch!(ctx, :agent_id)
    depth = Keyword.fetch!(ctx, :depth)
    repo_root = Keyword.fetch!(ctx, :repo_root)
    repo_id = Keyword.fetch!(ctx, :repo_id)
    worktree_path = Keyword.fetch!(ctx, :worktree_path)
    retries = Keyword.fetch!(ctx, :retries)
    spec = Keyword.fetch!(ctx, :spec)
    meta = Keyword.fetch!(ctx, :meta)

    Process.put(:evogit_agent_id, agent_id)
    Process.put(:evogit_agent_depth, depth)
    Process.put(:evogit_started_at, DateTime.utc_now() |> DateTime.to_iso8601())
    Process.put(:evogit_repo_root, repo_root)
    Process.put(:evogit_repo_id, repo_id)
    Process.put(:repo_path, worktree_path)

    # Create/prepare worktree and run init script (blocking I/O, runs
    # concurrently across subagents). If this fails, the task crashes
    # (caught by the :DOWN handler / crash recovery) rather than the
    # GenServer — which is the desired behaviour.
    EvoGit.AgentScheduler.Dispatch.setup_worktree(
      agent_id,
      repo_root,
      worktree_path,
      spec,
      meta
    )

    if retries > 0 do
      Logger.info("AgentScheduler: Retrying agent #{agent_id}, attempt #{retries}")
      Process.sleep(30_000 * retries)
    else
      Logger.info(
        "AgentScheduler: Agent #{agent_id} starting execution in worktree #{worktree_path}"
      )
    end
  end

  # --- Internal Execution Logic ---

  # Checks and sends turn-limit warnings via the adaptive TurnWarning module.
  # See EvoGit.Agent.TurnWarning for threshold logic and message generation.
  defp check_limit_warnings(%LoopState{} = state) do
    case EvoGit.Agent.TurnWarning.check_positional(
           state.turn,
           state.max_turns,
           state.last_warned_level,
           state.delegation_level
         ) do
      {:ok, warning} ->
        msg = EvoGit.Agent.TurnWarning.message(warning)
        warning_msg = EvoGit.Agent.ContextBuilder.tag_message_turn(user(msg), state.turn)
        new_context = ReqLLM.Context.append(state.context, warning_msg)
        %{state | context: new_context, last_warned_level: warning.level}

      :none ->
        case EvoGit.Agent.TurnWarning.check_middle(
               state.turn,
               state.max_turns,
               state.turns_since_subagent,
               state.delegation_level
             ) do
          {:ok, warning} ->
            msg = EvoGit.Agent.TurnWarning.message(warning)
            warning_msg = EvoGit.Agent.ContextBuilder.tag_message_turn(user(msg), state.turn)
            new_context = ReqLLM.Context.append(state.context, warning_msg)
            %{state | context: new_context, turns_since_subagent: 0}

          :none ->
            state
        end
    end
  end

  defp drain_and_inject_user_messages(%LoopState{agent_id: agent_id, context: context} = state) do
    messages = EvoGit.AgentScheduler.Store.drain_pending_user_messages(agent_id)

    case messages do
      [] ->
        state

      _ ->
        new_context =
          Enum.reduce(messages, context, fn msg, ctx ->
            tagged = EvoGit.Agent.ContextBuilder.tag_message_turn(user(msg), state.turn)
            ReqLLM.Context.append(ctx, tagged)
          end)

        # Sync updated context to ETS for dashboard visibility
        EvoGit.Agent.ContextBuilder.sync_context_to_ets(agent_id, new_context)

        %{state | context: new_context}
    end
  end

  defp loop(%LoopState{} = state) do
    context_before = state.context

    state =
      EvoGit.Agent.ContextCompression.compress_if_needed(state,
        agent_id: state.agent_id,
        llm_model: EvoGit.Agent.ToolDispatch.current_model(),
        llm_generation_params: EvoGit.Agent.ToolDispatch.current_generation_params()
      )

    state = check_limit_warnings(state)

    # Sync context to ETS after any updates (compression, warnings)
    if context_before != state.context do
      EvoGit.Agent.ContextBuilder.sync_context_to_ets(state.agent_id, state.context)
      EvoGit.Agent.ContextBuilder.sync_total_tokens_to_ets(state.agent_id, state.total_tokens)
    end

    # Drain any pending user messages (injected externally via dashboard/RPC)
    # and append them to the context as user-role messages before the next LLM call.
    state = drain_and_inject_user_messages(state)

    cond do
      EvoGit.Agent.trigger_turn_limit_recovery?(state) ->
        trigger_recovery(state, "max turns (#{state.max_turns}) exceeded")

      true ->
        do_turn(state)
    end
  end

  defp trigger_recovery(%LoopState{} = state, reason) do
    objective =
      case EvoGit.AgentScheduler.get_agent_state(state.agent_id) do
        {:ok, agent_state}
        when is_binary(agent_state.objective) and
               agent_state.objective != "" ->
          agent_state.objective

        _ ->
          nil
      end

    # Safety net: auto-commit any uncommitted work before entering the grace
    # period, so it is preserved even if the agent fails to commit during its
    # single recovery turn. We only commit when there are actually changes
    # (non-empty porcelain status); a clean workspace is a no-op. Git errors
    # are allowed to propagate (crash) — this is best-effort salvage, not
    # error-masking.
    maybe_recovery_auto_commit(state)

    warning_msg =
      if objective do
        """
        You have exceeded the execution limit (#{reason}).
        Your priority is to call `#{@complete_tool}` NOW with your best answer.

        If you have critical uncommitted changes, commit them first, then immediately call `#{@complete_tool}`. Your already-committed work is safe.

        Your original objective was:
        #{objective}

        Your report MUST summarize the status of this ENTIRE objective, not just your most recent sub-task.
        """
      else
        """
        You have exceeded the execution limit (#{reason}).
        Your priority is to call `#{@complete_tool}` NOW with your best answer explaining the situation.

        If you have critical uncommitted changes, commit them first, then immediately call `#{@complete_tool}`. Your already-committed work is safe.
        """
      end

    recovery_msg = EvoGit.Agent.ContextBuilder.tag_message_turn(user(warning_msg), state.turn)
    new_context = ReqLLM.Context.append(state.context, recovery_msg)

    state = %{state | context: new_context, in_grace_period: true}
    loop(state)
  end

  # Best-effort auto-commit of any uncommitted work just before the grace
  # period, as a safety net so work is not lost if the agent fails to commit
  # during its single recovery turn. Only commits when the workspace is dirty
  # (non-empty porcelain status); a clean workspace is a silent no-op. Git
  # errors propagate (crash) rather than being swallowed — this is salvage,
  # not error-masking. No try/rescue per repo conventions.
  defp maybe_recovery_auto_commit(%LoopState{}) do
    repo_path = Process.get(:repo_path)

    if repo_path do
      case Git.status(repo_path) do
        {:ok, ""} ->
          :ok

        {:ok, _status_output} ->
          {:ok, _} = Git.add(repo_path, ".")
          {:ok, _} = Git.commit(repo_path, "auto-commit: turn-limit recovery")
          :ok
      end
    else
      :ok
    end
  end

  defp do_turn(%LoopState{} = state) do
    EvoGit.Agent.ToolDispatch.do_turn(
      state,
      &effective_tools/1,
      state.agent_module.subagent_modules(),
      &loop/1,
      &trigger_recovery/2
    )
  end

  defp effective_tools(%LoopState{} = state) do
    skill_schemas = Map.get(state, :skill_schemas, [])
    all_tools = state.agent_module.available_tools() ++ skill_schemas

    if at_max_depth?(state) do
      excluded = MapSet.new(EvoGit.Agent.SubagentSchemas.tools(state.agent_module))

      all_tools
      |> Enum.reject(fn tool ->
        name = EvoGit.Agent.tool_name(tool)
        name && MapSet.member?(excluded, name)
      end)
    else
      all_tools
    end
  end

  defp at_max_depth?(%LoopState{} = state) do
    {:ok, agent_state} = EvoGit.AgentScheduler.get_agent_state(state.agent_id)
    state.depth >= agent_state.max_depth
  end
end
