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

  # The two grace-turn budgets (`@cancel_grace_turns` / `@turn_limit_grace_turns`),
  # the recovery message, the auto-commit safety net and the grace-period entry
  # points live in `EvoGit.Agent.Exchange.Grace`; the delegations below keep the
  # old call sites working until the Runner becomes a shim.

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
    result =
      try do
        do_run(agent_module, objective)
      after
        EvoGit.AgentScheduler.Dispatch.commit_pending_in_worktree()

        # After the fallback committed, advance the agent's foreign repo's
        # PERSISTENT worktree to the agent's final HEAD — so the worktree other
        # agents read reflects the newest committed state (last-writer-wins).
        # Best-effort and a no-op for primary-repo / repo-less agents.
        EvoGit.AgentScheduler.ForeignWorktree.sync_from_agent()
      end

    # The `after` fallback above may have created the ONLY commit of this run,
    # while `Result.commit_sha` was captured earlier (on the completion path,
    # before the fallback committed) — i.e. it may still point at the
    # pre-fallback worktree HEAD. `Runtime.Helpers.merge_and_report/3,4`
    # compares that sha against the live HEAD of the repo root and treats a
    # match (or nil) as "no changes", so a stale pre-fallback sha would leave
    # the fallback-only commit unreviewable (no `genesis/agent_*` branch, and
    # the commit dies with the worktree on reclaim). Re-read the worktree HEAD
    # AFTER the fallback ran and refresh the returned result.
    refresh_commit_sha(result)
  end

  # Refreshes the `commit_sha` of a successful agent result with the current
  # worktree HEAD. Public (@doc false) solely so it can be tested directly
  # against a real temporary git repository.
  #
  # Repo-less agents are returned COMPLETELY unchanged (their `:repo_path` may
  # point at the real Genesis source root — git must never run there). Success
  # shapes carrying a commit sha (`%EvoGit.Agent.Result{}`, a plain map with a
  # `:commit_sha` key, or either of those wrapped in `{:ok, inner}`) are
  # refreshed; `{:error, ...}` and every other shape are returned untouched, so
  # a successful result is never turned into a failure. When the HEAD cannot be
  # re-read (missing/vanished worktree, non-git directory, unset `:repo_path`),
  # the input is returned unchanged.
  @doc false
  def refresh_commit_sha(result) do
    if Process.get(:repo_less) == true do
      result
    else
      refresh_success_shape(result)
    end
  end

  defp refresh_success_shape({:ok, inner}), do: {:ok, refresh_success_shape(inner)}

  defp refresh_success_shape(%EvoGit.Agent.Result{} = result) do
    case current_worktree_sha() do
      {:ok, sha} -> %{result | commit_sha: sha}
      :error -> result
    end
  end

  # Defensive: Genesis Mode B merges sub-results with `Map.put/3`, which keeps
  # the struct type for `%Result{}` — this clause covers plain maps that carry
  # a `:commit_sha` key.
  defp refresh_success_shape(%{commit_sha: _} = map) do
    case current_worktree_sha() do
      {:ok, sha} -> Map.put(map, :commit_sha, sha)
      :error -> map
    end
  end

  defp refresh_success_shape(other), do: other

  # Reads the worktree HEAD. Never raises: `Git.rev_parse/2` pre-checks the
  # path and returns `{:error, {:enoent, _}}` for a missing directory and
  # `{:error, {code, output}}` for a non-git directory.
  defp current_worktree_sha do
    case Process.get(:repo_path) do
      path when is_binary(path) and path != "" ->
        case Git.rev_parse(path) do
          {:ok, sha} when is_binary(sha) and sha != "" -> {:ok, sha}
          _ -> :error
        end

      _ ->
        :error
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
      # All of the above are the fields the LoopState carries so the refresh can
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
      # This exact value is retained on the LoopState so a mid-run compression
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
        repo_notes: agent_state.repo_notes,
        parent_id: agent_state.parent_id,
        repo_less: repo_less,
        quality_level: Process.get(:quality_level),
        objective: objective,
        attachments: attachments,
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

    # Expose the agent's foreign repos to the tool layer: the dispatch-level
    # write gate (`EvoGit.Agent.Tools.maybe_block_read_only_foreign_repo/5`)
    # and the path-level scope check
    # (`EvoGit.Agent.Tools.Shared.validate_file_scope/3`) read this key to
    # determine whether the agent operates inside a read-only foreign repo.
    Process.put(:foreign_repos, spec.foreign_repos || [])

    # Custom agents (EvoGit.Agents.Custom) resolve their definition at runtime
    # from this process-dict key, set from the spec before the agent loop starts
    # (their callbacks are zero-arity, so the spec cannot be passed directly).
    Process.put(:custom_agent_id, Keyword.get(spec.opts, :custom_agent_id))

    # Media attachments (images/audio) for the initial objective — surfaced
    # from the spec opts exactly like :custom_agent_id. The Runner's do_run/2
    # materializes them into the ROOT agent's first user message (root-only
    # gate); subagent specs never carry the key, so this is nil for them.
    Process.put(:attachments, Keyword.get(spec.opts, :attachments))

    # Quality-level (`:quality_level`) — a SPEED ↔ QUALITY trade-off surfaced
    # from the spec opts exactly like :attachments. Only the ROOT agent's
    # prompt gains the guidance block (the do_run/2 root gate); subagent specs
    # never carry the key, so their prompts stay unchanged.
    Process.put(:quality_level, Keyword.get(spec.opts, :quality_level))

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

    # Resolve the managed per-task scratch directory (EvoGit.TaskTmpdir) once
    # and install it on THIS agent process, so `EvoGit.Sandbox.resolve_tmpdir/0`
    # — and therefore every backend's `TMPDIR` injection plus the framework's own
    # temp files (commit-message files, skill scripts, partial outputs) — targets
    # the per-task dir instead of a host-wide `/tmp`.
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
    task_tmpdir =
      case Keyword.get(spec.opts, :task_tmpdir) do
        path when is_binary(path) ->
          path

        _ ->
          primary_repo_path = if repo_less, do: nil, else: Process.get(:genesis_repo_root)
          EvoGit.TaskTmpdir.ensure(meta.task_id, primary_repo_path)
      end

    EvoGit.TaskTmpdir.put_current(task_tmpdir)
  end

  # --- Internal Execution Logic ---

  # Checks and sends turn-limit warnings via the adaptive TurnWarning module.
  # See EvoGit.Agent.TurnWarning for threshold logic and message generation.
  defdelegate check_limit_warnings(state),
    to: EvoGit.Agent.Exchange.Warnings,
    as: :check_limit_warnings

  # Drains the agent's pending user-message queue and appends each message to
  # the context as a turn-tagged user-role message. The implementation (and its
  # full rationale, including attachment materialization and the NO-root-gate
  # rule for injected media) lives in `EvoGit.Agent.Exchange.Pending`.
  #
  # Public (@doc false) solely so it can be tested directly — same convention as
  # `refresh_commit_sha/1` / `maybe_enter_cancel_grace/1`.
  @doc false
  defdelegate drain_and_inject_user_messages(state),
    to: EvoGit.Agent.Exchange.Pending,
    as: :drain_and_inject_user_messages

  # Claims this agent's finished-but-unannounced background shell jobs and, when
  # there are any, appends ONE combined `[NOTICE]` user message. Moved verbatim
  # (exactly-once claim, grace-period skip) to `EvoGit.Agent.Exchange.Pending`.
  #
  # Public (@doc false) solely so it can be tested directly.
  @doc false
  defdelegate inject_background_job_notices(state),
    to: EvoGit.Agent.Exchange.Pending,
    as: :inject_background_job_notices

  defp loop(%LoopState{} = state) do
    context_before = state.context

    case EvoGit.Agent.ContextCompression.compress_if_needed(state,
           agent_id: state.agent_id,
           llm_model: EvoGit.Agent.ToolDispatch.current_model(),
           llm_context_window: EvoGit.Agent.ToolDispatch.current_context_window(),
           llm_generation_params: EvoGit.Agent.ToolDispatch.current_generation_params()
         ) do
      %LoopState{} = state ->
        continue_loop(state, context_before)

      {:error, {:llm_request_rejected, _message} = terminal} ->
        # The compression call hit a NON-RETRYABLE provider rejection (the
        # fail-fast exception in `ContextCompression.compress_if_needed/2`).
        # Propagate the terminal error out of `loop/1` UNCHANGED so it reaches
        # `Runner.run/3`'s return value — `refresh_commit_sha/1` passes
        # `{:error, _}` through untouched — and the task is persisted `:failed`
        # with the actionable message instead of being crash-retried through the
        # same doomed request.
        {:error, terminal}
    end
  end

  # The remainder of the turn, after compression returned a `%LoopState{}`
  # (compressed or unchanged — byte-identical to the pre-existing flow).
  defp continue_loop(%LoopState{} = state, context_before) do
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

    # Turn top, right after the drain: a background shell job that finished
    # since the previous turn is announced with ONE `[NOTICE]` user message.
    # Placed HERE (not earlier) because compression has already run for this
    # turn, so a fresh notice can never be compressed away immediately; and not
    # later because it must precede the LLM call and never interrupt an
    # in-flight tool batch.
    state = inject_background_job_notices(state)

    # Immediately after the drain: check whether a graceful cancellation was
    # requested for this agent (ETS `cancel_requested` flag, set by the
    # scheduler when the task is cancelled). If set, the flag is cleared and
    # the agent enters cancel-grace (the cancel-grace turn budget, NO extra
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

  # Transitions an agent into a grace period WITHOUT re-entering the loop.
  # Moved verbatim (recovery auto-commit FIRST, `:message` / `:grace_turns`
  # semantics, recovery-message construction from the agent's objective) to
  # `EvoGit.Agent.Exchange.Grace`.
  @doc false
  defdelegate enter_grace(state, reason), to: EvoGit.Agent.Exchange.Grace, as: :enter_grace

  defdelegate enter_grace(state, reason, opts),
    to: EvoGit.Agent.Exchange.Grace,
    as: :enter_grace

  # Checks whether a graceful cancellation was requested for this agent and, if
  # so, clears the flag and enters the cancel grace period (`:no_cancel`
  # otherwise). Moved verbatim to `EvoGit.Agent.Exchange.Grace`.
  @doc false
  defdelegate maybe_enter_cancel_grace(state),
    to: EvoGit.Agent.Exchange.Grace,
    as: :maybe_enter_cancel_grace

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
