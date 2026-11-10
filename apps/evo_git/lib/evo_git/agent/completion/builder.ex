defmodule EvoGit.Agent.Completion.Builder do
  @moduledoc """
  The ONE completion entry point: turn an agent's final report text into its
  `%EvoGit.Agent.Result{}` and write the completion side effects exactly once.

  `finalize/2` is the ONLY caller of `EvoGit.Agent.Completion.complete/4`; the
  turn path (`EvoGit.Agent.ToolDispatch`) reaches it for a `:oneshot` agent on
  its tool-free reply, and an `:interactive` session reaches the SAME function
  once, when the session terminates — so a session with many exchanges still
  writes exactly one git note, one archive row and one `%Result{}`.

  ## Side-effect order

    1. commit any pending worktree work
       (`EvoGit.AgentScheduler.Dispatch.commit_pending_in_worktree/0`) so the
       reported sha is reviewable;
    2. read the POST-commit worktree HEAD (repo-less agents have none → `nil`);
    3. refresh that sha against the live worktree HEAD
       (`EvoGit.Agent.Runner.refresh_commit_sha/1`);
    4. build the `%Result{}` and write the completion side effects once.

  ## Failure semantics

  A missing or vanished worktree / a failed `git rev-parse` still RAISES the
  descriptive error (step 2): that is what makes the one-shot crash-retry path
  byte-identical to before. Only a missing SCHEDULER row
  (`AgentScheduler.get_agent_state/1` → `:error`) or missing registration
  metadata (`Store.get_sched_meta/1` → `:error`) is returned as `{:error, reason}`
  — never a raise.

  ## Process context

  `finalize/2` reads the DERIVED per-process identity the exchange installed with
  `EvoGit.Agent.Session.Setup.install_process_context/3` (`:repo_less`,
  `:repo_path`, `:evogit_repo_id`), so it must run in that process — the exchange
  worker, or the process driving a bare engine run.
  """

  alias EvoGit.Adapters.Git
  alias EvoGit.Agent.Completion
  alias EvoGit.Agent.Compression.Threshold
  alias EvoGit.Agent.Result
  alias EvoGit.Agent.Runner
  alias EvoGit.Agent.State
  alias EvoGit.AgentScheduler

  @doc """
  Finalizes `state` with the agent's report `text`.

  Returns `{:ok, %EvoGit.Agent.Result{}}` after writing the completion side
  effects exactly once, or `{:error, reason}` when the agent's scheduler rows are
  gone (nothing can be completed without them).
  """
  @spec finalize(State.t(), String.t()) :: {:ok, Result.t()} | {:error, term()}
  def finalize(%State{} = state, text) do
    # 1. Commit pending work FIRST, so the sha reported to the runtime is
    #    reviewable. `commit_pending_in_worktree/0` is a no-op for a clean
    #    workspace and for repo-less agents, and it never raises (git errors are
    #    logged, not propagated), so it cannot turn a legitimate finish into a
    #    failure.
    AgentScheduler.Dispatch.commit_pending_in_worktree()

    # 2. The POST-commit HEAD. This is the step that still RAISES (descriptive
    #    `rev_parse` error) when the worktree vanished mid-run, preserving the
    #    one-shot crash-retry semantics.
    commit_sha = sync_and_get_current_commit()

    # 3. Re-read the live HEAD so the reported sha never points at a
    #    pre-fallback commit. Never raises; `nil`/repo-less stays unchanged.
    commit_sha = refresh_commit_sha(commit_sha)

    # 4. Build the result and write the completion side effects EXACTLY ONCE.
    with {:ok, agent_state} <- fetch_agent_state(state.agent_id),
         {:ok, meta} <- fetch_sched_meta(state.agent_id) do
      {:ok, complete(state, text, commit_sha, agent_state, meta)}
    end
  end

  # --- steps ---

  # Reads the current commit for the completion payload (no ETS write). Repo-less
  # agents have no worktree and no commit; completion receives a `nil` sha.
  defp sync_and_get_current_commit do
    if Process.get(:repo_less) do
      nil
    else
      repo_path = Process.get(:repo_path) || raise "repo_path not in process dictionary"

      case Git.rev_parse(repo_path) do
        {:ok, sha} -> sha
        {:error, reason} -> raise_rev_parse_error(reason)
      end
    end
  end

  # Raises a clear, diagnosable error for a failed `Git.rev_parse`. A missing
  # repo/worktree directory (`:enoent` — `Git.run/2`'s pre-check returns
  # `{:error, {:enoent, "Repository path does not exist: ..."}}`) means the
  # worktree was removed while the agent was running (e.g. a WorktreeManager
  # crash cascade): the agent cannot continue without its repo, but the operator
  # must be told the retry will start from a fresh worktree. All other error
  # shapes keep the original opaque message.
  defp raise_rev_parse_error({:enoent, msg}) do
    raise(
      "Worktree vanished while agent was running (removed mid-run): #{msg} — " <>
        "the retried agent will get a fresh worktree; uncommitted work is lost by design of the retry"
    )
  end

  defp raise_rev_parse_error({code, msg}) do
    raise "Git rev_parse failed (#{code}): #{msg}"
  end

  # Delegates to the ONE public sha refresh so the completion path and the
  # exchange worker share the same never-raising re-read. A `nil` sha (repo-less)
  # is returned unchanged, as is any sha that cannot be re-read.
  defp refresh_commit_sha(nil), do: nil

  defp refresh_commit_sha(sha) when is_binary(sha) do
    case Runner.refresh_commit_sha(%{commit_sha: sha}) do
      %{commit_sha: refreshed} -> refreshed
      _other -> sha
    end
  end

  defp fetch_agent_state(agent_id) do
    case AgentScheduler.get_agent_state(agent_id) do
      {:ok, agent_state} -> {:ok, agent_state}
      :error -> {:error, {:agent_state_not_found, agent_id}}
    end
  end

  defp fetch_sched_meta(agent_id) do
    case EvoGit.AgentScheduler.Store.get_sched_meta(agent_id) do
      {:ok, meta} -> {:ok, meta}
      :error -> {:error, {:sched_meta_not_found, agent_id}}
    end
  end

  # Builds the `%Result{}` and writes its completion side effects (git note when
  # `base_commit` is set, archive refs/row when archiving), so every downstream
  # consumer is oblivious to how the agent finished.
  #
  # REGISTRATION METADATA ONLY: `base_commit` comes from the spec's phylo node
  # captured at registration, and the archive/model registration metadata from the
  # summary row; the completion side effects (git note, archive refs/row) stay
  # byte-identical. No conversation/loop value is read from ETS here — notably
  # `compression_count` comes from the owned state.
  defp complete(%State{} = state, result_text, commit_sha, agent_state, meta) do
    # Repo-less agents have no spec phylo node — passing nil base_commit is safe:
    # Completion.complete/4 guards git-note/archive writes on base_commit being
    # truthy, so both are skipped for repo-less agents.
    base_commit =
      if Process.get(:repo_less),
        do: nil,
        else: meta.spec.phylo_node && meta.spec.phylo_node.base_commit

    Completion.complete(
      state.agent_id,
      result_text,
      commit_sha,
      base_commit: base_commit,
      parent_id: agent_state.parent_id,
      depth: state.depth,
      objective: state.objective,
      usage: state.usage,
      archive: agent_state.archive,
      compression_count: state.compression_count,
      repo_id: agent_state.repo_id,
      repo_root: agent_state.repo_root,
      llm_model: agent_state.llm_model,
      model_id: agent_state.model_id,
      model_spec: Map.get(agent_state, :model_spec),
      llm_generation_params: agent_state.llm_generation_params,
      max_turns: agent_state.max_turns,
      max_retries: agent_state.max_retries,
      max_agent_depth: agent_state.max_depth,
      foreign_repos: agent_state.foreign_repos,
      compression_threshold:
        Threshold.for_model(agent_state.llm_model,
          context_window: Map.get(agent_state, :llm_context_window)
        ).threshold,
      agent_type: agent_type_from_module(state.agent_module),
      context_node_path: state.node_path
    )
  end

  defp agent_type_from_module(module) when is_atom(module) do
    module |> Module.split() |> List.last() |> Macro.underscore()
  end
end
