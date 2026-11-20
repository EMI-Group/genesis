defmodule EvoGit.Agent.Session.Pause do
  @moduledoc """
  The ONE pause finalizer of an agent session: everything a PAUSED run must make
  durable before its session stops.

  A task-level pause is honoured at a TURN BOUNDARY by the exchange engine
  (`EvoGit.Agent.Exchange`), which returns `{:pause, %State{}}` with the whole
  conversation already checkpointed through the session's `:checkpoint` seam.
  The remaining work is expensive — a git checkpoint commit, the durable
  pause marker, a writer flush — and it must never run inside the session
  process: a hanging or crashing finalizer would make the session unanswerable
  (`inspect/2`, `history/2`, `cancel/2`) exactly like a hanging completion.

  `start/3` therefore runs it in a short-lived MONITORED process whose
  `:evogit_agent_pid` is the SESSION pid (the durable owner), and reports back
  as `{:session_paused, finalizer_pid, info}` with

      %{agent_id: pos_integer(), task_id: String.t(),
        checkpoint: String.t() | nil, branch: String.t() | nil,
        durable: boolean(), reason: :task_pause}

  **The `checkpoint` key IS the run's persisted `pause_commit`** — the very sha
  `EvoGit.AgentState.put_pause_commit/3` writes to `agent_states.pause_commit`
  and the one the scheduler later reads as `worktree_resume_from` to base a
  resumed run's worktree. The key spelling is kept because consumers outside
  this module read it (`agent_scheduler/subagents.ex`), so only the LOCAL step
  and variable names call it `pause_commit`.

  ## The ordered steps (each one total)

    1. `EvoGit.Agent.Session.Setup.install_process_context/3` — the OWNER stays
       the session pid, so every tool background job and completion-style
       bookkeeping is still keyed on the durable agent process;
    2. reap the agent's background jobs (`EvoGit.BackgroundJobs.list/1` +
       `kill/3` for every live one) — a paused run must not leave an orphaned
       detached job behind;
    3. `EvoGit.AgentScheduler.WorktreeManager.checkpoint_for_pause/1` — commits
       the worktree (a CLEAN tree still yields its current HEAD sha) and anchors
       the commit under `refs/genesis/salvage/<branch>`, so reclaim cannot lose
       the resume base;
    4. `EvoGit.AgentState.put_pause_commit/3` — the PAUSE COMMIT sha (returned
       here as `info.checkpoint`) is persisted on the run's durable row.
       `{:error, :not_found}` / `{:error,
       :not_persistent_state_disabled}` are tolerated: a non-durable run still
       pauses, it simply cannot resume (the caller-side validation refuses such a
       pause before it starts);
    5. `EvoGit.AgentState.flush/1` — the explicit, HONEST durability barrier: a
       synchronous writer round-trip. It MUST return before the outcome is
       delivered, and only an `:ok` reply proves the paused run's whole
       conversation AND its `pause_commit` marker were committed. `{:error,
       :timeout}` still pauses (a pause is never worth a session crash) but the
       outcome reports `durable: false`, so nothing downstream can overstate it;
    6. report `{:session_paused, self(), info}` to the session, which owns the
       single terminal delivery.

  Any raise/exit/throw anywhere in that sequence degrades to
  `{:session_paused, pid, %{… checkpoint: nil, branch: nil, durable: false}}` —
  a pause is never worth a session crash, and a nil `checkpoint` only means the
  pause commit (the resume base) is missing, so the resume falls back to the task
  base.

  ## Delivery is still exactly ONCE

  This module only builds `info`; it never delivers a session result. The
  session's ONE terminal path (`finalize/1`) publishes the summary and sends
  `{:agent_session_result, agent_id, session_pid, {:paused, info}}`, exactly like
  every other terminal outcome — so a pause can never double-send.
  """

  require Logger

  alias EvoGit.Agent.Session.Durable
  alias EvoGit.Agent.Session.Setup
  alias EvoGit.Agent.State
  alias EvoGit.AgentState
  alias EvoGit.AgentScheduler.WorktreeManager
  alias EvoGit.BackgroundJobs

  @type handle :: {pid(), reference()}

  @typedoc """
  The paused outcome payload (see the moduledoc).

  `checkpoint` is the PAUSE COMMIT sha — the value persisted in
  `agent_states.pause_commit` and the one the scheduler names
  `worktree_resume_from`.
  """
  @type info :: %{
          agent_id: pos_integer() | nil,
          task_id: String.t() | nil,
          checkpoint: String.t() | nil,
          branch: String.t() | nil,
          durable: boolean(),
          reason: :task_pause
        }

  @doc """
  Starts the pause finalizer for `state`, reporting `{:session_paused, pid, info}`
  to the calling SESSION process.

  Returns the monitored `{pid, reference}` handle the session keeps (and can
  `stop/1`).
  """
  @spec start(pid(), State.t(), String.t() | nil) :: handle()
  def start(session_pid, %State{} = state, tmpdir) when is_pid(session_pid) do
    owner = self()

    spawn_monitor(fn ->
      # The OWNER must stay the session pid: background-job ownership and every
      # completion-style bookkeeping key are bound to the durable agent process,
      # never to this short-lived one.
      Setup.install_process_context(state, tmpdir, session_pid)
      send(owner, {:session_paused, self(), run(state, session_pid)})
    end)
  end

  @doc "True when `pid`/`ref` are this data's current pause finalizer."
  @spec current?(handle() | nil, pid(), reference()) :: boolean()
  def current?({pid, ref}, pid, ref), do: true
  def current?(_handle, _pid, _ref), do: false

  @doc "True when `pid` is the process of this data's current pause finalizer."
  @spec current?(handle() | nil, pid()) :: boolean()
  def current?({pid, _ref}, pid), do: true
  def current?(_handle, _pid), do: false

  @doc """
  Kills a pause finalizer that is no longer wanted (a force kill / close) and
  flushes its monitor message, so the session never sees a stale `:DOWN` for it.

  Mirrors `EvoGit.Agent.Session.Finalize.stop/1`: the finalizer owns nothing the
  session does not already own (the worktree lease is the session's), so a kill
  is safe — it is only mid-git/mid-store when it is being abandoned.
  """
  @spec stop(handle() | nil) :: :ok
  def stop({pid, ref}) do
    Process.demonitor(ref, [:flush])
    Process.exit(pid, :kill)
    :ok
  end

  def stop(nil), do: :ok

  @doc """
  Builds the paused outcome payload from a state and the PAUSE COMMIT it produced
  (if any), reporting `durable: false`.

  Public so the session can build the same shape for the belt-and-braces paths
  (a killed finalizer, an exchange worker aborted by the pause purge): those
  paths never flush, so they honestly cannot claim a durable checkpoint.
  """
  @spec info(State.t(), String.t() | nil, String.t() | nil) :: info()
  def info(%State{} = state, pause_commit, branch),
    do: info(state, pause_commit, branch, false)

  @doc """
  The same payload with an explicit durability verdict — `true` ONLY when the
  writer's `flush/1` answered `:ok`.
  """
  @spec info(State.t(), String.t() | nil, String.t() | nil, boolean()) :: info()
  def info(%State{} = state, pause_commit, branch, durable) do
    %{
      agent_id: state.agent_id,
      task_id: state.task_id,
      # The map KEY stays `checkpoint` (read by `agent_scheduler/subagents.ex`);
      # the VALUE is the pause commit.
      checkpoint: pause_commit,
      branch: branch,
      durable: durable == true,
      reason: :task_pause
    }
  end

  # --- the finalizer body ---

  # The whole sequence, converted into `info` in EVERY case: a raise/throw/exit
  # answers the same payload with a nil pause commit (the caller-side validation
  # refuses a resume that cannot be based, never a pause that could not be
  # checkpointed).
  defp run(%State{} = state, session_pid) do
    reap_background_jobs(session_pid)
    {pause_commit, branch} = commit_pause_checkpoint(state)
    persist(state, pause_commit)
    durable = flush(state) == :ok
    info(state, pause_commit, branch, durable)
  rescue
    error ->
      Logger.warning(
        "AgentSession #{Kernel.inspect(Map.get(state, :agent_id))}: pause finalizer failed " <>
          "(#{Exception.message(error)}); delivering a paused outcome with no checkpoint"
      )

      info(state, nil, nil)
  catch
    kind, reason ->
      Logger.warning(
        "AgentSession #{Kernel.inspect(Map.get(state, :agent_id))}: pause finalizer " <>
          "#{kind} (#{Kernel.inspect(reason)}); delivering a paused outcome with no checkpoint"
      )

      info(state, nil, nil)
  end

  # Reaps every LIVE background job the agent still owns. `owner_pid:` fences the
  # list, so a concurrent agent's jobs are untouchable; a registry that is down
  # answers `[]`/`{:error, …}` and this stays a no-op.
  defp reap_background_jobs(session_pid) do
    Enum.each(BackgroundJobs.list(owner_pid: session_pid), fn job ->
      if Map.get(job, :status) in [:running, :stopping] do
        BackgroundJobs.kill(Map.get(job, :id), "task paused",
          owner_pid: session_pid,
          actor: :pause
        )
      end
    end)

    :ok
  rescue
    error ->
      Logger.warning("Pause: failed to reap background jobs: #{inspect(error)}")
      :ok
  catch
    kind, reason ->
      Logger.warning("Pause: failed to reap background jobs: #{inspect({kind, reason})}")
      :ok
  end

  # The worktree checkpoint commit that becomes the PAUSE COMMIT (total,
  # `{:ok, sha} | {:ok, nil}` — and `{:ok, nil}` for a repo-less agent, which
  # never has a worktree).
  defp commit_pause_checkpoint(%State{} = state) do
    case WorktreeManager.checkpoint_for_pause(state.agent_id) do
      {:ok, %{commit: sha, branch: branch}} when is_binary(sha) -> {sha, branch}
      _other -> {nil, nil}
    end
  rescue
    error ->
      Logger.warning("Pause: checkpoint commit failed: #{inspect(error)}")
      {nil, nil}
  catch
    kind, reason ->
      Logger.warning("Pause: checkpoint commit failed: #{inspect({kind, reason})}")
      {nil, nil}
  end

  # The durable marker: `agent_states.pause_commit`. Skipped (never cleared) when
  # there is no pause commit or no identity to write it to; a non-durable run's
  # `{:error, …}` is tolerated.
  defp persist(%State{} = state, pause_commit) when is_binary(pause_commit) do
    if Durable.valid_identity?(state) do
      case AgentState.put_pause_commit(state.task_id, state.agent_id, pause_commit) do
        :ok ->
          :ok

        {:error, reason} ->
          Logger.debug(fn ->
            "Agent #{state.agent_id}: pause commit not persisted (#{inspect(reason)})"
          end)

          :ok
      end
    else
      :ok
    end
  end

  defp persist(_state, _pause_commit), do: :ok

  # The explicit durability barrier: a synchronous writer round-trip. It MUST
  # complete before the paused outcome is delivered, and its verdict decides
  # whether the outcome may claim `durable: true`.
  defp flush(%State{agent_id: agent_id}) when is_integer(agent_id),
    do: AgentState.flush(agent_id)

  defp flush(_state), do: AgentState.flush()
end
