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

  # Grace-turn budget for a user-requested graceful cancellation (cancel-grace).
  # The agent may wrap up and call `complete_task` for up to this many turns
  # before the run hard-stops with `{:error, :recovery_failed}`.
  @cancel_grace_turns 3

  # Grace-turn budget for turn-limit recovery — exactly 1, preserving the
  # pre-budget behavior (enter grace, one continue attempt → hard-stop).
  @turn_limit_grace_turns 1

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

    # Repo-less agents run without a git worktree (chatbot-style) — their
    # repo_path points at the real Genesis source root or a placeholder binary
    # (e.g. "[system]"), which is not a node directory, so the existence check
    # is skipped entirely (the placeholder dir would kill the agent before it
    # starts).
    unless Process.get(:repo_less) or File.exists?(full_path) do
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
      repo_root = Process.get(:genesis_repo_root)

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

      # Sync initial context to ETS for dashboard. The in-memory context is
      # already stamped at creation (tag_context_messages_with_turn above);
      # update_agent_context returns :ok, so it is called for the side effect.
      EvoGit.AgentScheduler.update_agent_context(agent_id, context)

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
    Process.put(:genesis_repo_root, repo_root)
    Process.put(:evogit_repo_id, repo_id)

    # Custom agents (EvoGit.Agents.Custom) resolve their definition at runtime
    # from this process-dict key, set from the spec before the agent loop starts
    # (their callbacks are zero-arity, so the spec cannot be passed directly).
    Process.put(:custom_agent_id, Keyword.get(spec.opts, :custom_agent_id))

    repo_less = Keyword.get(ctx, :repo_less)

    if repo_less do
      # Repo-less ("system") mode: the agent runs WITHOUT a git worktree
      # (chatbot-style). WorktreeManager is never involved — it does not
      # monitor this agent, so there is no worktree to reclaim/prune on exit.
      # The repo path is the real Genesis source root or a placeholder binary
      # (e.g. "[system]"); git is never touched and files are never written
      # (cardinal rule). Skills loading is gated on `is_binary`, so the
      # placeholder is fine.
      repo_less_path = Keyword.get(ctx, :repo_less_repo_path) || repo_root

      Process.put(:repo_path, repo_less_path)
      Process.put(:genesis_repo_root, repo_less_path)
      Process.put(:repo_less, true)

      Logger.info("AgentScheduler: Agent #{agent_id} starting in repo-less (system) mode")

      if retries > 0 do
        Logger.info("AgentScheduler: Retrying agent #{agent_id}, attempt #{retries}")
        Process.sleep(30_000 * retries)
      end
    else
      Process.put(:repo_path, worktree_path)

      # Request a FRESH worktree from WorktreeManager (1h call timeout —
      # creation I/O runs offloaded in WorktreeManager, which monitors THIS
      # process: if we die for any reason, the worktree is reclaimed). If this
      # fails, the task crashes (caught by the :DOWN handler / crash recovery)
      # rather than the GenServer — which is the desired behaviour: setup
      # failure triggers scheduler crash-retry, and the retry's Runner requests
      # another fresh worktree.
      case EvoGit.AgentScheduler.WorktreeManager.create_worktree_for_agent(
             agent_id,
             repo_root,
             worktree_path,
             spec,
             meta,
             self()
           ) do
        {:ok, ^worktree_path} ->
          :ok

        {:error, reason} ->
          raise "Failed to create worktree for agent #{agent_id}: #{inspect(reason)}"
      end

      if retries > 0 do
        Logger.info("AgentScheduler: Retrying agent #{agent_id}, attempt #{retries}")
        Process.sleep(30_000 * retries)
      else
        Logger.info(
          "AgentScheduler: Agent #{agent_id} starting execution in worktree #{worktree_path}"
        )
      end
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

        # Sync updated context to ETS for dashboard visibility (returns :ok).
        # The in-memory new_context is already stamped at creation
        # (tag_message_turn above) — no rebind needed.
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

    # Sync context to ETS after any updates (compression, warnings). The
    # in-memory context is already stamped at creation; sync_context_to_ets
    # returns :ok, so it is called for the side effect only.
    if context_before != state.context do
      EvoGit.Agent.ContextBuilder.sync_context_to_ets(state.agent_id, state.context)
      EvoGit.Agent.ContextBuilder.sync_total_tokens_to_ets(state.agent_id, state.total_tokens)
    end

    # Drain any pending user messages (injected externally via dashboard/RPC)
    # and append them to the context as user-role messages before the next LLM call.
    state = drain_and_inject_user_messages(state)

    # Immediately after the drain: check whether a graceful cancellation was
    # requested for this agent (ETS `cancel_requested` flag, set by the
    # scheduler when the task is cancelled). If set, the flag is cleared and
    # the agent enters cancel-grace (budget @cancel_grace_turns, NO extra
    # recovery message — the cancel message was already injected via the
    # pending_user_messages drain above).
    case maybe_enter_cancel_grace(state) do
      {:cancel_grace, grace_state} ->
        loop(grace_state)

      :no_cancel ->
        cond do
          EvoGit.Agent.trigger_turn_limit_recovery?(state) ->
            trigger_recovery(state, "max turns (#{state.max_turns}) exceeded")

          true ->
            do_turn(state)
        end
    end
  end

  defp trigger_recovery(%LoopState{} = state, reason) do
    trigger_recovery(state, reason, [])
  end

  defp trigger_recovery(%LoopState{} = state, reason, opts) do
    loop(enter_grace(state, reason, opts))
  end

  @doc false
  # Transitions an agent into a grace period WITHOUT re-entering the loop.
  #
  # Runs the best-effort recovery auto-commit FIRST (safety net so uncommitted
  # work is preserved — fires for BOTH grace kinds; for cancel-grace this is
  # exactly "save the changes"), then optionally appends a recovery message to
  # the context, then sets `in_grace_period: true` with the given grace-turn
  # budget. Returns the updated `%LoopState{}`.
  #
  # `opts`:
  #   - `:message` — `:default` (or omitted) appends the standard hardcoded
  #     "exceeded the execution limit" recovery message built from `reason` and
  #     the agent's objective (byte-for-byte identical to the pre-budget
  #     behavior); `nil` skips the append (cancel-grace — the cancel message
  #     was already injected via the `pending_user_messages` drain in
  #     `loop/1`, so a second message would be redundant); a binary appends
  #     that custom message instead.
  #   - `:grace_turns` — the grace-turn budget (default `@turn_limit_grace_turns`).
  def enter_grace(%LoopState{} = state, reason, opts \\ []) do
    message = Keyword.get(opts, :message, :default)
    grace_turns = Keyword.get(opts, :grace_turns, @turn_limit_grace_turns)

    # Safety net: auto-commit any uncommitted work before entering the grace
    # period, so it is preserved even if the agent fails to commit during its
    # recovery turns. We only commit when there are actually changes
    # (non-empty porcelain status); a clean workspace is a no-op. Git errors
    # are allowed to propagate (crash) — this is best-effort salvage, not
    # error-masking.
    maybe_recovery_auto_commit(state)

    new_context =
      case message do
        :default ->
          objective =
            case EvoGit.AgentScheduler.get_agent_state(state.agent_id) do
              {:ok, agent_state}
              when is_binary(agent_state.objective) and
                     agent_state.objective != "" ->
                agent_state.objective

              _ ->
                nil
            end

          warning_msg = recovery_warning_message(reason, objective)

          recovery_msg =
            EvoGit.Agent.ContextBuilder.tag_message_turn(user(warning_msg), state.turn)

          ReqLLM.Context.append(state.context, recovery_msg)

        nil ->
          # Cancel-grace: the cancel message was already injected via the
          # pending_user_messages drain in `loop/1` — do not append a second
          # recovery message.
          state.context

        custom when is_binary(custom) ->
          recovery_msg = EvoGit.Agent.ContextBuilder.tag_message_turn(user(custom), state.turn)
          ReqLLM.Context.append(state.context, recovery_msg)
      end

    %{
      state
      | context: new_context,
        in_grace_period: true,
        grace_turns_remaining: grace_turns
    }
  end

  @doc false
  # Checks whether a graceful cancellation was requested for this agent via the
  # ETS `cancel_requested` flag (set by the scheduler when the task is
  # cancelled).
  #
  # If set: clears the flag in ETS and returns `{:cancel_grace, grace_state}`
  # where `grace_state` has `in_grace_period: true` and
  # `grace_turns_remaining: @cancel_grace_turns`. No recovery message is
  # appended — the cancel message was already injected into the context by the
  # `pending_user_messages` drain at the top of `loop/1`.
  #
  # If not set: returns `:no_cancel`.
  def maybe_enter_cancel_grace(%LoopState{} = state) do
    if EvoGit.AgentScheduler.Store.cancel_requested?(state.agent_id) do
      EvoGit.AgentScheduler.Store.clear_cancel_requested(state.agent_id)

      {:cancel_grace,
       enter_grace(state, "task cancelled", message: nil, grace_turns: @cancel_grace_turns)}
    else
      :no_cancel
    end
  end

  # The hardcoded "exceeded the execution limit" recovery message appended when
  # entering a grace period with `message: :default` (turn-limit recovery).
  defp recovery_warning_message(reason, objective) do
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
  end

  # Best-effort auto-commit of any uncommitted work just before the grace
  # period, as a safety net so work is not lost if the agent fails to commit
  # during its single recovery turn. Only commits when the workspace is dirty
  # (non-empty porcelain status); a clean workspace is a silent no-op. Git
  # errors propagate (crash) rather than being swallowed — this is salvage,
  # not error-masking. No try/rescue per repo conventions.
  defp maybe_recovery_auto_commit(%LoopState{}) do
    # Repo-less agents never touch git (cardinal rule) — their repo_path is a
    # placeholder or the real source root, neither of which should be
    # status'd/committed.
    if Process.get(:repo_less) do
      :ok
    else
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
