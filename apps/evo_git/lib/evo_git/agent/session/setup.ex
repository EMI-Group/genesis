defmodule EvoGit.Agent.Session.Setup do
  @moduledoc """
  The ONE durable/per-process setup implementation used by the
  `EvoGit.Agent.Session` process and its per-exchange worker.

  Two halves with different lifetimes:

    * `bind_worktree/2` + `ensure_tmpdir/1` are the DURABLE half — allocate the
      agent's worktree (skipped entirely for a repo-less agent), apply the
      crash-retry sleep and resolve the managed per-task scratch directory. They
      run once per agent run/session.
    * `install_process_context/3` is the PER-PROCESS half — it installs the
      identity/role/conversation-lifetime values on the process dictionary of
      whichever process is about to execute an exchange (today's agent Task, or
      a session's per-exchange worker, which starts with an EMPTY dictionary).

  The process dictionary installed here is a DERIVED projection of
  `%EvoGit.Agent.State{}`, never authoritative: the struct is the single source
  of truth and is threaded through the exchange engine, while these keys exist
  only because tools, background jobs and the completion path read them.

  `build_initial_state/3` is the state-construction half: it reads NOTHING from
  the scheduler row or the process dictionary — every value arrives in the
  supplied context — and returns the initial `%EvoGit.Agent.State{}` a run
  starts from.
  """

  require Logger

  alias EvoGit.Agent.State

  @doc """
  Installs the identity prefix and provisions the agent's worktree.

  `owner_pid` is the process `EvoGit.AgentScheduler.WorktreeManager` monitors —
  the process whose death reclaims the worktree. It defaults to `self()` (the
  Runner path, where the agent IS this process); a session passes its own pid.
  """
  def bind_worktree(ctx, owner_pid \\ self()) do
    agent_id = fetch_field!(ctx, :agent_id)
    depth = fetch_field!(ctx, :depth)
    repo_root = fetch_field!(ctx, :repo_root)
    repo_id = fetch_field!(ctx, :repo_id)
    worktree_path = fetch_field!(ctx, :worktree_path)
    retries = fetch_field!(ctx, :retries)
    spec = fetch_field!(ctx, :spec)
    meta = fetch_field!(ctx, :meta)

    Process.put(:evogit_agent_id, agent_id)
    Process.put(:evogit_agent_depth, depth)
    Process.put(:evogit_started_at, DateTime.utc_now() |> DateTime.to_iso8601())
    Process.put(:genesis_repo_root, repo_root)
    Process.put(:evogit_repo_id, repo_id)

    repo_less = get_field(ctx, :repo_less)

    if repo_less do
      # Repo-less ("system") mode: the agent runs WITHOUT a git worktree
      # (chatbot-style). WorktreeManager is never involved — it does not
      # monitor this agent, so there is no worktree to reclaim/prune on exit.
      # The repo path is the real Genesis source root or a placeholder binary
      # (e.g. "[system]"); git is never touched and files are never written
      # (cardinal rule). Skills loading is gated on `is_binary`, so the
      # placeholder is fine.
      repo_less_path = get_field(ctx, :repo_less_repo_path) || repo_root

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

      # Request a FRESH worktree from WorktreeManager (indefinite wait — the
      # create call never times out, so a slow copy is waited for; a genuine
      # failure inside the create pipeline replies {:error, reason} promptly
      # instead. Creation I/O runs offloaded in WorktreeManager, which monitors
      # THIS process: if we die for any reason, the worktree is reclaimed). If
      # this fails, the task crashes (caught by the :DOWN handler / crash
      # recovery) rather than the GenServer — which is the desired behaviour:
      # setup failure triggers scheduler crash-retry, and the retry's Runner
      # requests another fresh worktree.
      case EvoGit.AgentScheduler.WorktreeManager.create_worktree_for_agent(
             agent_id,
             repo_root,
             worktree_path,
             spec,
             meta,
             owner_pid
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

    :ok
  end

  @doc """
  Resolves the managed per-task scratch directory (`EvoGit.TaskTmpdir`) and
  returns its path. Does NOT install it on the process dictionary — that is
  `install_process_context/3`'s job.
  """
  def ensure_tmpdir(ctx) do
    spec = fetch_field!(ctx, :spec)
    repo_less = get_field(ctx, :repo_less)

    # Resolve the managed per-task scratch directory (EvoGit.TaskTmpdir) once,
    # so `EvoGit.Sandbox.resolve_tmpdir/0` — and therefore every backend's
    # `TMPDIR` injection plus the framework's own temp files (commit-message
    # files, skill scripts, partial outputs) — targets the per-task dir instead
    # of a host-wide `/tmp`.
    #
    # Sharing across the task's agents:
    #   * `:system`/`:custom` modes depend ONLY on `task_id`, so every agent of
    #     the task computes the identical dir regardless of which repo it runs in.
    #   * `:per_repo` depends on the TASK's PRIMARY repo. The root agent computes
    #     it rooted at the primary repo and threads it down via
    #     `spec.opts[:task_tmpdir]` (see `SubagentProcessing.build_subagent_specs/3`),
    #     so foreign-repo subagents inherit the SAME dir instead of rooting it at
    #     their own repo.
    #
    # `:genesis_repo_root` is the agent's ORIGINAL repo root (for the root agent
    # it is the task's primary repo) — NOT `:repo_path`, which is the transient
    # worktree. It is passed as `nil` for repo-less agents so `:per_repo` falls
    # back to `:system`: the Genesis source root must NEVER receive a
    # `.genesis/tmp` dir.
    case Keyword.get(spec.opts, :task_tmpdir) do
      path when is_binary(path) ->
        path

      _ ->
        primary_repo_path = if repo_less, do: nil, else: Process.get(:genesis_repo_root)
        EvoGit.TaskTmpdir.ensure(meta_task_id(ctx), primary_repo_path)
    end
  end

  @doc """
  Installs the per-exchange process-dictionary values.

  Accepts EITHER the scheduler's `dispatch_ctx` keyword list (the Runner path,
  where `bind_worktree/2` already ran in this process) OR a
  `%EvoGit.Agent.State{}` (a session's per-exchange worker, which inherits an
  EMPTY dictionary and therefore derives every value from the struct).

  `owner_pid` is the AGENT/session pid a background job's lifetime is bound to —
  never a tool-task pid.
  """
  def install_process_context(source, task_tmpdir \\ nil, owner_pid \\ self()) do
    ctx = process_context(source)

    Process.put(:evogit_agent_id, ctx.agent_id)
    Process.put(:evogit_agent_depth, ctx.depth)
    Process.put(:evogit_started_at, started_at())
    Process.put(:genesis_repo_root, ctx.genesis_repo_root)
    Process.put(:evogit_repo_id, ctx.repo_id)

    # Expose the agent's foreign repos to the tool layer: the dispatch-level
    # write gate (`EvoGit.Agent.Tools.maybe_block_read_only_foreign_repo/5`)
    # and the path-level scope check
    # (`EvoGit.Agent.Tools.Shared.validate_file_scope/3`) read this key to
    # determine whether the agent operates inside a read-only foreign repo.
    Process.put(:foreign_repos, ctx.foreign_repos)

    # Custom agents (EvoGit.Agents.Custom) resolve their definition at runtime
    # from this process-dict key, set before the agent loop starts (their
    # callbacks are zero-arity, so the spec cannot be passed directly).
    Process.put(:custom_agent_id, ctx.custom_agent_id)

    # Media attachments (images/audio) for the initial objective — materialized
    # into the ROOT agent's first user message (root-only gate); subagent specs
    # never carry the value, so this is nil for them.
    Process.put(:attachments, ctx.attachments)

    # Quality-level (`:quality_level`) — a SPEED ↔ QUALITY trade-off read from
    # the spec opts exactly like :attachments. Only the ROOT agent's prompt
    # gains the guidance block (the root gate); subagent specs never carry the
    # key, so their prompts stay unchanged.
    Process.put(:quality_level, ctx.quality_level)

    Process.put(:repo_path, ctx.repo_path)
    if ctx.repo_less, do: Process.put(:repo_less, true)

    Process.put(:evogit_agent_pid, owner_pid)
    Process.put(:evogit_task_id, ctx.task_id)

    # Per-dir delegation counters — per-exchange bookkeeping, so a fresh
    # exchange always starts from empty maps.
    Process.put(:delegation_hints, %{})
    Process.put(:read_delegation_hints, %{})

    if is_binary(task_tmpdir), do: EvoGit.TaskTmpdir.put_current(task_tmpdir)

    :ok
  end

  @doc """
  Builds the initial `%EvoGit.Agent.State{}` for `agent_module` running
  `objective`, reading every value from `ctx` (a keyword list or a map).

  Returns `{:error, :path_not_exist}` (after logging) when the agent's assigned
  node path does not exist and the agent is not repo-less. Performs NO ETS
  writes and installs nothing on the process dictionary — the caller owns those
  side effects.
  """
  def build_initial_state(agent_module, objective, ctx) do
    agent_id = fetch_field!(ctx, :agent_id)
    repo_less = get_field(ctx, :repo_less) == true

    # Validate that the assigned node path exists
    node_path = fetch_field!(ctx, :context_node).path
    repo_path = fetch_field!(ctx, :repo_path)
    full_path = Path.join(repo_path, node_path)

    # Repo-less agents run without a git worktree (chatbot-style) — their
    # repo_path points at the real Genesis source root or a placeholder binary
    # (e.g. "[system]"), which is not a node directory, so the existence check
    # is skipped entirely (the placeholder dir would kill the agent before it
    # starts).
    unless repo_less or File.exists?(full_path) do
      Logger.error(
        "Agent #{agent_id}: Assigned node path does not exist: #{full_path} (node_path=#{node_path})"
      )

      {:error, :path_not_exist}
    else
      parent_id = fetch_field!(ctx, :parent_id)
      foreign_repos = fetch_field!(ctx, :foreign_repos)
      repo_notes = fetch_field!(ctx, :repo_notes)
      quality_level = get_field(ctx, :quality_level)
      repo_root = fetch_field!(ctx, :repo_root)

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
      context_block =
        EvoGit.Agent.ContextBuilder.build_context_block(%{
          node_path: node_path,
          repo_path: repo_path,
          parent_id: parent_id,
          repo_less: repo_less,
          foreign_repos: foreign_repos,
          repo_notes: repo_notes,
          quality_level: quality_level
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
      attachments = if repo_less, do: nil, else: get_field(ctx, :attachments)

      messages =
        EvoGit.Agent.ContextBuilder.build_initial_messages(
          agent_module.system_prompt(),
          combined_prompt,
          parent_id,
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

      max_turns = fetch_field!(ctx, :max_turns)

      # `llm_model` / `llm_generation_params` / `llm_context_window` are
      # LOAD-BEARING: the engine's compression step reads them from this struct
      # instead of ETS, so a missing or blank value would silently change
      # behaviour.
      state = %State{
        agent_id: agent_id,
        agent_module: agent_module,
        depth: fetch_field!(ctx, :depth),
        node_path: node_path,
        repo_path: repo_path,
        context: context,
        max_turns: max_turns,
        skill_schemas: skill_schemas,
        foreign_repos: foreign_repos,
        repo_notes: repo_notes,
        parent_id: parent_id,
        repo_less: repo_less,
        quality_level: quality_level,
        objective: objective,
        attachments: attachments,
        delegation_level: agent_module.delegation_level(),
        # identity fields the old ETS reads supplied (same scheduler row)
        task_id: fetch_field!(ctx, :task_id),
        context_node: fetch_field!(ctx, :context_node),
        repo_id: fetch_field!(ctx, :repo_id),
        repo_root: repo_root,
        custom_agent_id: get_field(ctx, :custom_agent_id),
        mode: :oneshot,
        archive: fetch_field!(ctx, :archive),
        worktree: repo_path,
        # conversation fields the old ETS reads supplied (same scheduler row)
        compression_count: fetch_field!(ctx, :compression_count),
        llm_context_window: fetch_field!(ctx, :llm_context_window),
        llm_model: fetch_field!(ctx, :llm_model),
        llm_generation_params: fetch_field!(ctx, :llm_generation_params),
        model_spec: fetch_field!(ctx, :model_spec),
        provider_profile_id: fetch_field!(ctx, :provider_profile_id),
        model_id: fetch_field!(ctx, :model_id),
        model_id_locked: fetch_field!(ctx, :model_id_locked),
        prompt_cache_key: get_field(ctx, :prompt_cache_key),
        # budget fields the old ETS reads supplied (same scheduler row), plus
        # the phase: this state is the RUNNING state of a one-shot exchange.
        max_depth: fetch_field!(ctx, :max_depth),
        max_retries: fetch_field!(ctx, :max_retries),
        phase: :running
      }

      {:ok, state}
    end
  end

  # --- derived per-process projection ---

  # The scheduler's `dispatch_ctx` keyword list (Runner path).
  defp process_context(source) when is_list(source) do
    spec = fetch_field!(source, :spec)
    repo_root = fetch_field!(source, :repo_root)
    repo_less = get_field(source, :repo_less) == true
    repo_less_path = get_field(source, :repo_less_repo_path) || repo_root

    {repo_path, genesis_repo_root} =
      if repo_less do
        {repo_less_path, repo_less_path}
      else
        {fetch_field!(source, :worktree_path), repo_root}
      end

    %{
      agent_id: fetch_field!(source, :agent_id),
      depth: fetch_field!(source, :depth),
      repo_id: fetch_field!(source, :repo_id),
      repo_path: repo_path,
      genesis_repo_root: genesis_repo_root,
      repo_less: repo_less,
      foreign_repos: spec.foreign_repos || [],
      custom_agent_id: Keyword.get(spec.opts, :custom_agent_id),
      attachments: Keyword.get(spec.opts, :attachments),
      quality_level: Keyword.get(spec.opts, :quality_level),
      task_id: fetch_field!(source, :meta).task_id
    }
  end

  # A `%EvoGit.Agent.State{}` (session-worker path) — every value derived from
  # the struct, because the worker starts with an empty process dictionary.
  defp process_context(%State{} = state) do
    repo_less = state.repo_less == true

    %{
      agent_id: state.agent_id,
      depth: state.depth,
      repo_id: state.repo_id,
      repo_path: state.repo_path,
      genesis_repo_root: if(repo_less, do: state.repo_path, else: state.repo_root),
      repo_less: repo_less,
      foreign_repos: state.foreign_repos || [],
      custom_agent_id: state.custom_agent_id,
      attachments: state.attachments,
      quality_level: state.quality_level,
      task_id: state.task_id
    }
  end

  # The started-at stamp `bind_worktree/2` already installed in THIS process is
  # reused; a fresh exchange worker (empty dictionary) stamps its own.
  defp started_at do
    Process.get(:evogit_started_at) || DateTime.utc_now() |> DateTime.to_iso8601()
  end

  defp meta_task_id(ctx), do: fetch_field!(ctx, :meta).task_id

  # --- plain-data field accessors (keyword list OR map/struct source) ---

  defp fetch_field!(source, key) when is_list(source), do: Keyword.fetch!(source, key)
  defp fetch_field!(source, key), do: Map.fetch!(source, key)

  defp get_field(source, key, default \\ nil)
  defp get_field(source, key, default) when is_list(source), do: Keyword.get(source, key, default)
  defp get_field(source, key, default), do: Map.get(source, key, default)
end
