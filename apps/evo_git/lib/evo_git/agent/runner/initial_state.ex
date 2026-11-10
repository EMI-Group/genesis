defmodule EvoGit.Agent.Runner.InitialState do
  @moduledoc """
  Gathers the inputs for one agent run's initial `%EvoGit.Agent.State{}` from the
  scheduler/process dictionary, then delegates the state construction itself to
  `EvoGit.Agent.Session.Setup.build_initial_state/3`.

  The construction (initial `<context>`/`<objective>` prompt, hierarchical skill
  schemas, every struct field) lives in `EvoGit.Agent.Session.Setup` — the ONE
  shared implementation used by both this Runner driver and the future
  `EvoGit.Agent.Session` process.

  What stays HERE is Runner-only plumbing: reading the agent's scheduler row and
  the process dictionary, plus the ETS syncs the exchange engine expects
  (`EvoGit.AgentScheduler.update_agent_context/2` and
  `EvoGit.Agent.ContextBuilder.sync_turn_to_ets/2`).
  """

  alias EvoGit.Agent.Session.Setup

  @doc """
  Builds the initial state for `agent_module` running `objective`.

  Returns `{:error, :path_not_exist}` (after logging) when the agent's assigned
  node path does not exist and the agent is not repo-less.
  """
  def build(agent_module, objective) do
    agent_id = EvoGit.AgentScheduler.current_agent_id()

    # REGISTRATION SEEDING ONLY: this is the ONE-TIME read the owned
    # `%EvoGit.Agent.State{}` is built FROM; the exchange loop never reads the
    # row for a conversation/loop value.
    {:ok, agent_state} = EvoGit.AgentScheduler.get_agent_state(agent_id)

    ctx = [
      agent_id: agent_id,
      depth: EvoGit.AgentScheduler.current_depth(),
      repo_path: Process.get(:repo_path),
      repo_root: Process.get(:genesis_repo_root),
      repo_less: Process.get(:repo_less) == true,
      task_id: EvoGit.AgentScheduler.task_id_for_agent(agent_id),
      parent_id: agent_state.parent_id,
      context_node: agent_state.context_node,
      repo_id: agent_state.repo_id,
      archive: agent_state.archive,
      foreign_repos: agent_state.foreign_repos,
      repo_notes: agent_state.repo_notes,
      max_turns: agent_state.max_turns,
      max_depth: agent_state.max_depth,
      max_retries: agent_state.max_retries,
      compression_count: agent_state.compression_count,
      llm_context_window: agent_state.llm_context_window,
      llm_model: agent_state.llm_model,
      llm_generation_params: agent_state.llm_generation_params,
      model_spec: agent_state.model_spec,
      provider_profile_id: agent_state.provider_profile_id,
      model_id: agent_state.model_id,
      model_id_locked: agent_state.model_id_locked,
      # Not a field on the scheduler row yet — `Map.get/2` keeps this
      # forward-compatible (nil today, the row value once it exists).
      prompt_cache_key: Map.get(agent_state, :prompt_cache_key),
      attachments: Process.get(:attachments),
      quality_level: Process.get(:quality_level),
      custom_agent_id: Process.get(:custom_agent_id)
    ]

    case Setup.build_initial_state(agent_module, objective, ctx) do
      {:ok, state} ->
        # Sync initial context to ETS for dashboard. The in-memory context is
        # already stamped at creation (tag_context_messages_with_turn inside
        # the shared builder); update_agent_context returns :ok, so it is
        # called for the side effect.
        EvoGit.AgentScheduler.update_agent_context(agent_id, state.context)

        EvoGit.Agent.ContextBuilder.sync_turn_to_ets(agent_id, 0)

        {:ok, state}

      {:error, reason} ->
        {:error, reason}
    end
  end
end
