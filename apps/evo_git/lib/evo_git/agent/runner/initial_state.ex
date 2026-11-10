defmodule EvoGit.Agent.Runner.InitialState do
  @moduledoc """
  Builds the initial `%EvoGit.Agent.State{}` of one agent run — moved verbatim out
  of `EvoGit.Agent.Runner.do_run/2`.

  `build/2` reads the agent's scheduler row, validates the assigned node path,
  assembles the framed `<context>` / `<objective>` first user prompt, loads the
  agent's hierarchical skill schemas and returns the state the engine
  (`EvoGit.Agent.Exchange`) threads through every turn.

  The struct carries BOTH the fields the old loop struct owned and the fields
  that used to be read back from the `:evogit_agent_state` ETS row this builds
  from, so the engine's struct-based reads are value-identical to those reads.
  """

  require Logger

  alias EvoGit.Agent.State

  @doc """
  Builds the initial state for `agent_module` running `objective`.

  Returns `{:error, :path_not_exist}` (after logging) when the agent's assigned
  node path does not exist and the agent is not repo-less.
  """
  def build(agent_module, objective) do
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
    unless Process.get(:repo_less) == true or File.exists?(full_path) do
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
      #
      # The `<context>` block is assembled by the ONE shared helper
      # `ContextBuilder.build_context_block/1` — the same helper the mid-run
      # compression refresh uses (`ContextBuilder.refresh_first_user_message/2`
      # via `ContextCompression.compress_if_needed/2`), so the two can never
      # drift. The helper reads the current CONTEXT.md chain from disk plus:
      #
      #   * the delegation-authority statement — authoritatively tells THIS
      #     agent whether it is the ROOT agent (parent_id nil == depth 0) or a
      #     NESTED agent and which foreign-repo spawn authority that role
      #     carries (never the process-dict depth, which may not be populated
      #     at assembly time; skipped for repo-less agents and single-repo
      #     tasks);
      #   * the foreign-repos markdown section ("" when no non-primary repos);
      #   * the rendered repo-notes block (git-submodules awareness — "" when
      #     the repo has no gitlinks / detection failed);
      #   * the quality-level guidance (a SPEED ↔ QUALITY block for the ROOT
      #     agent ONLY — "" for subagents and repo-less agents).
      #
      # All of the above are the fields the state carries so the refresh can
      # reproduce them verbatim.
      repo_less = Process.get(:repo_less) == true

      context_block =
        EvoGit.Agent.ContextBuilder.build_context_block(%{
          node_path: node_path,
          repo_path: repo_path,
          parent_id: agent_state.parent_id,
          repo_less: repo_less,
          foreign_repos: agent_state.foreign_repos,
          repo_notes: agent_state.repo_notes,
          quality_level: Process.get(:quality_level)
        })

      objective_body =
        if EvoGit.Agent.ContextBuilder.blank?(objective), do: "", else: to_string(objective)

      combined_prompt =
        [
          context_block,
          EvoGit.Agent.ContextBuilder.objective_block(objective_body)
        ]
        |> Enum.reject(&EvoGit.Agent.ContextBuilder.blank?/1)
        |> Enum.join("\n\n---\n\n")

      # Media attachments (images/audio) ride on the ROOT agent's first user
      # message ONLY — the helper gates on `parent_id == nil`; repo-less agents
      # (self-reflective chat) never get them even with a stray spec opt, so
      # the plain-text path is preserved (no reflect entry point sends the key).
      # This exact value is retained on the state so a mid-run compression
      # can reproduce the same media content parts.
      attachments =
        if repo_less, do: nil, else: Process.get(:attachments)

      messages =
        EvoGit.Agent.ContextBuilder.build_initial_messages(
          agent_module.system_prompt(),
          combined_prompt,
          agent_state.parent_id,
          attachments
        )

      context = ReqLLM.Context.new(messages)
      # Tag initial messages (system + user prompt) with turn 0
      context = EvoGit.Agent.ContextBuilder.tag_context_messages_with_turn(context, 0)

      # Load skill schemas hierarchically — only skills enabled in the
      # Context Tree (from root to this agent's node) are available.
      # Skills are read from the agent's WORKTREE (`:repo_path`), not the real
      # repo root, so a skill an agent adds/edits is visible to it immediately
      # and gets committed on its `evogit-agent-*` branch.
      repo_root = Process.get(:genesis_repo_root)

      skill_schemas =
        if repo_root && is_binary(repo_root) do
          all_skills = EvoGit.Skills.load_skills(repo_path)
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

      # `llm_model` / `llm_generation_params` / `llm_context_window` are
      # LOAD-BEARING: the engine's compression step reads them from this struct
      # instead of ETS, so a missing or blank value would silently change
      # behaviour.
      state = %State{
        agent_id: agent_id,
        agent_module: agent_module,
        depth: EvoGit.AgentScheduler.current_depth(),
        node_path: node_path,
        repo_path: repo_path,
        context: context,
        max_turns: max_turns,
        skill_schemas: skill_schemas,
        foreign_repos: agent_state.foreign_repos,
        repo_notes: agent_state.repo_notes,
        parent_id: agent_state.parent_id,
        repo_less: repo_less,
        quality_level: Process.get(:quality_level),
        objective: objective,
        attachments: attachments,
        delegation_level: agent_module.delegation_level(),
        # identity fields the old ETS reads supplied (same scheduler row)
        task_id: EvoGit.AgentScheduler.task_id_for_agent(agent_id),
        context_node: agent_state.context_node,
        repo_id: agent_state.repo_id,
        repo_root: repo_root,
        custom_agent_id: Process.get(:custom_agent_id),
        mode: :oneshot,
        archive: agent_state.archive,
        worktree: repo_path,
        # conversation fields the old ETS reads supplied (same scheduler row)
        compression_count: agent_state.compression_count,
        llm_context_window: agent_state.llm_context_window,
        llm_model: agent_state.llm_model,
        llm_generation_params: agent_state.llm_generation_params,
        model_spec: agent_state.model_spec,
        provider_profile_id: agent_state.provider_profile_id,
        model_id: agent_state.model_id,
        model_id_locked: agent_state.model_id_locked,
        # budget fields the old ETS reads supplied (same scheduler row), plus
        # the phase: this state is the RUNNING state of a one-shot exchange.
        max_depth: agent_state.max_depth,
        max_retries: agent_state.max_retries,
        phase: :running
      }

      EvoGit.Agent.ContextBuilder.sync_turn_to_ets(agent_id, 0)

      Process.put(:delegation_hints, %{})
      Process.put(:read_delegation_hints, %{})

      {:ok, state}
    end
  end
end
