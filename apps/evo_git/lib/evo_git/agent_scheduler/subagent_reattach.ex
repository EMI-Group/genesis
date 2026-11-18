defmodule EvoGit.AgentScheduler.SubagentReattach do
  @moduledoc """
  Re-attach half of "crash-resume after a tool call" for a pending subagent batch.

  A parent agent's exchange worker BLOCKS inside
  `EvoGit.AgentScheduler.spawn_sub_agents/2` while its children run. The whole
  batch lives on the parent's `%SchedMeta{}` row: `sub_agent_from` (the blocked
  `GenServer.from()`), `total_sub_specs`, `pending_sub_agents`,
  `sub_agent_results` (`%{index => result}`) and `sub_agent_indices`
  (`%{child_agent_id => index}`). Every child is an INDEPENDENT session, so a
  child survives the parent's abnormal death.

  When that parent session dies abnormally, the scheduler retries it under the
  SAME `agent_id` and `EvoGit.AgentScheduler.Lifecycle.retry_agent/3`
  deliberately keeps those batch fields — but the blocked `from` belongs to the
  DEAD worker, so `Subagents.dispatch_ready_parent/3` could neither deliver the
  results nor tell that they had arrived, and the retried parent would re-spawn
  duplicate children at duplicate cost.

  This module closes that hole:

    * `Subagents.maybe_resume_parent/2` + `Subagents.dispatch_ready_parent/3`
      RETAIN a completed batch whose waiter is `nil` or DEAD (setting
      `sub_agent_from: nil` as the retained marker and `status: :running`) and
      never `GenServer.reply/2` a `nil`/dead `from`.
    * `EvoGit.AgentScheduler.reattach_sub_agents/3` hands such a batch to the
      resumed parent: a fully resolved batch answers `{:ok, ordered_results}`
      immediately, while a partially resolved one installs a NEW waiter that the
      last in-flight child resumes through the ordinary
      `maybe_resume_parent → dispatch_ready_parent` path, guarded by a bounded
      timer whose expiry answers the still-missing slots as
      `{:error, :subagent_result_lost}` so the parent is never left stuck
      `:waiting`.

  ## The batch is ETS-only — a restart needs the durable rebuild

  The retained batch lives ONLY in the `:evogit_sched_meta` ETS row: nothing is
  written to SQLite, the task store or the archive. A scheduler (or BEAM)
  restart therefore LOSES it, and this module then refuses with
  `{:error, :no_pending_batch}`.

  That refusal is no longer the end of the story: the resumed parent answers it
  by rebuilding the same batch from its children's DURABLE rows
  (`EvoGit.Agent.Resume.RosterBatch` → `EvoGit.AgentScheduler.rebuild_subagent_batch/3`
  → `EvoGit.AgentScheduler.SubagentRebuild`), which installs the done results, the
  indices and a waiter exactly like a live batch, and re-spawns the still-running
  children under their persisted ids. The batch then resolves through THIS
  module's timer path if a re-spawned child never lands, so the parent still
  never hangs.

  ## Waiter bookkeeping (scheduler state)

  `%EvoGit.AgentScheduler.State{}` carries the installed waiter and its timer:

    * `reattach_waiters` — `%{agent_id => GenServer.from()}`
    * `reattach_timers` — `%{agent_id => {token, timer_ref}}`

  `token` is the identity carried in the timer message
  (`{:reattach_timeout, agent_id, token}`), so a timer whose waiter was already
  claimed by the normal resume path is ignored instead of clearing a NEWER
  batch. Both maps are carried across `State.do_update_config/2`'s non-LLM merge
  exactly like `close_waiters`, so a config reload never drops a waiting parent.

  Every function here runs INSIDE the scheduler process (from a `handle_call` /
  `handle_info` body, and `Subagents` runs inside it too), so
  `Process.send_after(self(), ...)` targets the scheduler.
  """

  require Logger

  alias EvoGit.AgentScheduler.State
  alias EvoGit.AgentScheduler.Store
  alias EvoGit.AgentScheduler.Subagents

  # Default re-attach wait budget (30 minutes). The resumed parent's OWN first
  # turn can legitimately take a long time, so the default must be generous; a
  # caller overrides it with `opts[:timeout]`, and an operator with the app env
  # `:agent_resume_reattach_timeout_ms`.
  @default_timeout_ms 1_800_000

  # The placeholder a slot resolves to when its result can never arrive: the
  # owning child's `%SchedMeta{}` row is gone and no result was stored, i.e. the
  # batch was lost (a scheduler/BEAM restart, or a child recycled without a
  # terminal result). A child that fails permanently DOES store its failure
  # term, so "no row AND no result" is genuinely lost.
  @lost_result {:error, :subagent_result_lost}

  @typedoc """
  Answer of `EvoGit.AgentScheduler.reattach_sub_agents/3`:

  - `{:ok, results}` — the ordered batch, one element per subagent spec (a
    still-missing slot is `{:error, :subagent_result_lost}`)
  - `{:error, :no_pending_batch}` — no batch, a different `expected_count`, or a
    batch already handed out (exactly once)
  - `{:error, :unavailable}` — the scheduler is not running
  """
  @type reattach_reply :: {:ok, [term()]} | {:error, :no_pending_batch | :unavailable}

  @doc """
  The default re-attach wait budget in milliseconds (30 minutes).
  """
  @spec default_timeout_ms() :: pos_integer()
  def default_timeout_ms, do: @default_timeout_ms

  @doc """
  The placeholder used for a subagent slot whose result can never arrive.
  """
  @spec lost_result() :: {:error, :subagent_result_lost}
  def lost_result, do: @lost_result

  # --- Scheduler-side handler bodies ---

  @doc """
  Handles `{:reattach_sub_agents, agent_id, expected_count, timeout}`: gives the
  caller the parent's pending subagent batch, or refuses without touching it.

  Refusals (all leave the batch untouched and install NO waiter):

  - no `%SchedMeta{}` row for `agent_id`;
  - `total_sub_specs == 0` (no batch in flight);
  - a non-nil `expected_count` that differs from `total_sub_specs` (the caller's
    view of "how many subagent calls I had in flight" does not match this row).

  When every slot is resolvable — a stored result, or a genuinely lost slot —
  the ordered results are answered ONCE and the batch is cleared, so a second
  re-attach answers `{:error, :no_pending_batch}`.

  When some slots are still PENDING (their child's `%SchedMeta{}` row exists and
  no result has been stored), the caller's `from` becomes the parent's waiter:
  `status` stays `:waiting`, the still-known-lost slots are materialized as
  `{:error, :subagent_result_lost}` (so the ordinary
  `maybe_resume_parent/2` completion test resolves the batch when the last child
  lands), `session_pid`/slots/worktree are untouched, and one bounded timer is
  armed for `timeout` ms.
  """
  @spec handle_reattach(
          term(),
          non_neg_integer() | nil,
          pos_integer(),
          GenServer.from(),
          State.t()
        ) :: {:reply, reattach_reply(), State.t()} | {:noreply, State.t()}
  def handle_reattach(agent_id, expected_count, timeout, from, %State{} = state) do
    with true <- is_integer(agent_id),
         {:ok, meta} when is_map(meta) <- Store.get_sched_meta(agent_id),
         total when is_integer(total) and total > 0 <- Map.get(meta, :total_sub_specs),
         true <- is_nil(expected_count) or expected_count == total do
      install_or_reply(agent_id, meta, timeout, from, state)
    else
      _ -> {:reply, {:error, :no_pending_batch}, state}
    end
  end

  @doc """
  Handles a `{:reattach_timeout, agent_id, token}` timer pop.

  The token identifies the waiter the timer was armed for: a timer whose waiter
  was already claimed (the batch resolved through
  `Subagents.dispatch_ready_parent/3`) does not match and is a no-op, so it can
  never clear a newer batch.
  """
  @spec handle_timeout(term(), reference() | term(), State.t()) :: {:noreply, State.t()}
  def handle_timeout(agent_id, token, %State{} = state) do
    case Map.fetch(state.reattach_timers, agent_id) do
      {:ok, {^token, _timer_ref}} ->
        from = Map.get(state.reattach_waiters, agent_id)

        state = %{
          state
          | reattach_waiters: Map.delete(state.reattach_waiters, agent_id),
            reattach_timers: Map.delete(state.reattach_timers, agent_id)
        }

        {:noreply, expire(agent_id, from, state)}

      _other ->
        {:noreply, state}
    end
  end

  # --- Waiter bookkeeping (shared with Subagents) ---

  @doc """
  Removes and cancels an installed re-attach waiter.

  Returns the updated scheduler state plus the waiter's `from`, or `nil` when no
  waiter was installed for `agent_id`. Its TWO callers are the normal resume
  path (`Subagents.dispatch_ready_parent/3`, which is about to answer the batch
  itself) and a FRESH batch (`Subagents.spawn_validated_subagents/5`, which
  overwrites the retained fields). Total: a missing entry, a missing timer or an
  already-fired timer are all no-ops.
  """
  @spec claim_waiter(State.t(), term()) :: {State.t(), GenServer.from() | nil}
  def claim_waiter(%State{} = state, agent_id) do
    {from, waiters} = Map.pop(state.reattach_waiters, agent_id)
    {timer, timers} = Map.pop(state.reattach_timers, agent_id)
    cancel_timer(timer)
    {%{state | reattach_waiters: waiters, reattach_timers: timers}, from}
  end

  @doc """
  Drops an installed waiter WITHOUT answering it.

  Used when a fresh batch replaces a retained one: a parent blocked in
  `spawn_sub_agents/2` cannot also be blocked in `reattach_sub_agents/3`, so the
  stale waiter's caller is already gone and its timer must not fire against the
  new batch.
  """
  @spec discard_waiter(State.t(), term()) :: State.t()
  def discard_waiter(%State{} = state, agent_id) do
    {state, _from} = claim_waiter(state, agent_id)
    state
  end

  # --- Internals ---

  defp install_or_reply(agent_id, meta, timeout, from, %State{} = state) do
    pending = pending_indices(meta)
    results = with_lost_placeholders(meta, pending)
    ordered = Subagents.build_ordered_results(results, meta.total_sub_specs)

    if pending == [] do
      clear_batch(agent_id, meta)

      Logger.info(
        "AgentScheduler: Agent #{agent_id} re-attached to its subagent batch " <>
          "(#{length(ordered)} slot(s), #{map_size(results) - map_size(sub_agent_results(meta))} lost)"
      )

      {:reply, {:ok, ordered}, state}
    else
      state = put_waiter(state, agent_id, from, timeout)

      # The still-known-lost slots are written into the retained results so the
      # batch's completion test (`map_size(sub_agent_results) == total_sub_specs`)
      # resolves when the LAST in-flight child lands. `pending_sub_agents` is a
      # spawn-time snapshot and is deliberately left alone.
      Store.put_sched_meta(agent_id, %{
        meta
        | status: :waiting,
          sub_agent_from: from,
          sub_agent_results: results
      })

      Logger.info(
        "AgentScheduler: Agent #{agent_id} re-attached to a pending subagent batch " <>
          "(#{length(pending)} of #{meta.total_sub_specs} still running)"
      )

      {:noreply, state}
    end
  end

  @doc """
  Installs (or replaces) `from` as the parent's waiter and arms the ONE bounded
  timer.

  Shared by BOTH batch install paths — the re-attach above and
  `EvoGit.AgentScheduler.SubagentRebuild` (which rebuilds a batch from the
  children's durable rows after a restart) — so a superseded waiter is answered
  rather than left blocked on an `:infinity` call: from ITS point of view the
  batch it was waiting for is no longer pending.
  """
  @spec put_waiter(State.t(), pos_integer(), GenServer.from() | nil, pos_integer()) :: State.t()
  def put_waiter(%State{} = state, agent_id, from, timeout) do
    {state, superseded} = claim_waiter(state, agent_id)

    if superseded do
      GenServer.reply(superseded, {:error, :no_pending_batch})

      Logger.warning(
        "AgentScheduler: Agent #{agent_id} re-attached twice; the earlier waiter was released"
      )
    end

    token = make_ref()
    timer_ref = Process.send_after(self(), {:reattach_timeout, agent_id, token}, timeout)

    %{
      state
      | reattach_waiters: Map.put(state.reattach_waiters, agent_id, from),
        reattach_timers: Map.put(state.reattach_timers, agent_id, {token, timer_ref})
    }
  end

  # The timeout answer: the still-missing slots are LOST, the batch is cleared
  # and the parent is left `:running` (never stuck `:waiting`).
  defp expire(agent_id, from, %State{} = state) do
    case Store.get_sched_meta(agent_id) do
      {:ok, meta} when is_map(meta) ->
        # On expiry EVERY still-missing slot is lost — including the ones whose
        # child was still live a moment ago: `with_lost_placeholders/2` is given
        # an empty pending set on purpose.
        ordered =
          Subagents.build_ordered_results(with_lost_placeholders(meta, []), meta.total_sub_specs)

        pending = pending_indices(meta)

        clear_batch(agent_id, meta)
        reply(from, {:ok, ordered})

        Logger.warning(
          "AgentScheduler: Agent #{agent_id} subagent re-attach timed out; " <>
            "#{length(pending)} result(s) reported as lost"
        )

        state

      _other ->
        reply(from, {:error, :no_pending_batch})

        Logger.warning(
          "AgentScheduler: Agent #{agent_id} subagent re-attach timed out with no batch left"
        )

        state
    end
  end

  # A `nil` waiter is the retained marker; a dead pid is a crashed worker.
  # `GenServer.reply/2` needs a `{pid, tag}` whose pid may already be gone (a
  # send to a dead pid is a safe no-op), but never `nil`.
  defp reply(nil, _term), do: :ok
  defp reply(from, term), do: GenServer.reply(from, term)

  defp cancel_timer({_token, timer_ref}), do: Process.cancel_timer(timer_ref)
  defp cancel_timer(_timer), do: :ok

  # Clears the whole batch exactly once: the results, the index map, the spec
  # count, the waiter and the pending set. The agent is left `:running` so no
  # gate reads it as `:waiting`. `foreign_repo_commits` is deliberately kept —
  # it is the subtree's tracked per-repo working commits, not batch state.
  defp clear_batch(agent_id, meta) do
    Store.put_sched_meta(agent_id, %{
      meta
      | status: :running,
        sub_agent_from: nil,
        pending_sub_agents: MapSet.new(),
        sub_agent_results: %{},
        sub_agent_indices: %{},
        total_sub_specs: 0
    })
  end

  # Indices with neither a stored result nor a live owning child, i.e. slots
  # whose result can never arrive. A result stored by a child that has since
  # been recycled still counts (it is in `sub_agent_results`).
  defp pending_indices(meta) do
    meta
    |> total_indices()
    |> Enum.reject(fn idx ->
      Map.has_key?(sub_agent_results(meta), idx) or not live_child?(meta, idx)
    end)
  end

  # Fills every non-pending gap with the LOST placeholder. Materializing it (and
  # writing it to the row when a waiter is installed) is what lets the ordinary
  # `map_size(sub_agent_results) == total_sub_specs` completion test resolve the
  # batch when the last in-flight child lands.
  defp with_lost_placeholders(meta, pending) do
    pending = MapSet.new(pending)

    Enum.reduce(total_indices(meta), sub_agent_results(meta), fn idx, acc ->
      if Map.has_key?(acc, idx) or MapSet.member?(pending, idx) do
        acc
      else
        Map.put(acc, idx, @lost_result)
      end
    end)
  end

  # The owning child of `idx` must still have a `%SchedMeta{}` row: a recycled
  # child can no longer deliver a result. Its ids are reused by nothing, so a
  # missing row is authoritative.
  defp live_child?(meta, idx) do
    Enum.any?(sub_agent_indices(meta), fn {child_id, child_idx} ->
      child_idx == idx and match?({:ok, _meta}, Store.get_sched_meta(child_id))
    end)
  end

  defp total_indices(%{total_sub_specs: total}) when is_integer(total) and total > 0,
    do: Enum.to_list(0..(total - 1)//1)

  defp total_indices(_meta), do: []

  defp sub_agent_results(meta), do: Map.get(meta, :sub_agent_results) || %{}
  defp sub_agent_indices(meta), do: Map.get(meta, :sub_agent_indices) || %{}
end
