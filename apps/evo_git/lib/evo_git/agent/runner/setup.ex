defmodule EvoGit.Agent.Runner.Setup do
  @moduledoc """
  The dispatch-context installation an agent's `run/2` performs BEFORE its first
  turn — moved verbatim out of `EvoGit.Agent.Runner`.

  `setup/1` installs the agent's identity on the process dictionary, provisions
  the agent's worktree (skipped entirely for a repo-less agent), applies the
  crash-retry sleep and resolves/installs the managed per-task scratch directory.
  `EvoGit.Agent.Runner.setup_dispatch_context/1` delegates here; the runtime
  state itself is `EvoGit.Agent.Runner.InitialState`'s job.
  """

  require Logger

  @doc """
  Installs the dispatch context for THIS agent process.

  The `ctx` keyword list is the scheduler's `dispatch_ctx`: it drives process-dict
  initialization, worktree setup and retry handling before the agent loop.
  """
  def setup(ctx) do
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
end
