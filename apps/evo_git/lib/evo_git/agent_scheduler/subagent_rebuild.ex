defmodule EvoGit.AgentScheduler.SubagentRebuild do
  @moduledoc """
  Rebuild half of whole-tree resume: install a durable subagent batch the way a
  live spawn would have.

  `EvoGit.AgentScheduler.reattach_sub_agents/3` can only hand a parent the batch
  that still lives on its `%SchedMeta{}` row — ETS, wiped by a scheduler/BEAM
  restart. When it refuses with `{:error, :no_pending_batch}`, the resumed parent
  builds a plan from the children's DURABLE rows
  (`EvoGit.Agent.Resume.RosterBatch`) and hands it here in ONE call:

      EvoGit.AgentScheduler.rebuild_subagent_batch(parent_id, plan, opts)

  The plan carries one slot per expected subagent call, in model call order, and
  this module turns it into exactly the scheduler state a live batch would have:

    * `status: "done"` rows CONTRIBUTE their stored result — no registration, no
      re-spawn, no cost paid twice — and land at their slot in
      `sub_agent_results`;
    * `status: "running"` rows are RE-SPAWNED through the ordinary
      `EvoGit.AgentScheduler.Dispatch.register_agent/8` + `try_dispatch/2` path,
      with the plan's resume opts (persisted `agent_id`, own base/branch/anchor,
      `restore_agent_state: true`), so each child continues its own run instead
      of restarting;
    * a slot with no usable row answers `{:error, :subagent_result_lost}` —
      honest, never invented.

  A child whose registration fails permanently stores a terminal `{:error,
  reason}` for its slot, and a child whose session start fails routes through the
  ordinary crash path (`EvoGit.AgentScheduler.Lifecycle` stores the failure term
  for the parent), so the batch always resolves — never a hang, never a silent
  drop.

  ## Same shape as a live batch

  The parent's row gets `total_sub_specs`, `sub_agent_results`,
  `sub_agent_indices` and `pending_sub_agents`, and the caller becomes the
  waiter (`SubagentReattach.put_waiter/4`, the SAME bookkeeping the re-attach
  path uses, including its supersede rules). The still-running children then
  resume the parent through the ordinary
  `Subagents.maybe_resume_parent/2 → dispatch_ready_parent/3` path, and the
  bounded `{:reattach_timeout, agent_id, token}` timer stays armed as the
  last-resort backstop: a child that never lands reports lost instead of
  blocking the parent forever.

  Nothing here reads durable state: the plan was built in the AGENT WORKER
  process (see `EvoGit.Agent.Resume.RosterBatch`), so this handler mutates only
  ETS and scheduler state.
  """

  require Logger

  alias EvoGit.AgentScheduler.Dispatch
  alias EvoGit.AgentScheduler.SchedMeta
  alias EvoGit.AgentScheduler.State
  alias EvoGit.AgentScheduler.Store
  alias EvoGit.AgentScheduler.SubagentReattach
  alias EvoGit.AgentScheduler.Subagents

  @statuses [:done, :running, :missing]

  @typedoc """
  Answer of one rebuild: the ordered batch (one element per subagent call, a
  slot that can never resolve being `{:error, :subagent_result_lost}`), or a
  refusal that leaves the parent's row untouched.
  """
  @type rebuild_reply ::
          {:ok, [term()]}
          | {:error, :no_pending_batch | :batch_in_flight | :invalid_plan | :unavailable}

  @doc """
  Handles `{:rebuild_subagent_batch, parent_id, plan, timeout}`.

  Refusals (all leave the parent's row untouched and install NO waiter):

  - no `%SchedMeta{}` row for `parent_id`;
  - a batch ALREADY in flight on that row (`total_sub_specs > 0`) — the caller
    should have re-attached instead, so nothing is clobbered;
  - a malformed plan (non-integer turn, a non-positive/mismatched
    `expected_count`, or an entry outside the slot/status vocabulary).

  When no slot is left pending the ordered results are answered immediately and
  the row is cleared. Otherwise the caller becomes the parent's waiter, the
  spawned children are dispatched, and the batch resolves through the ordinary
  completion path (or the bounded timer).

  Options:

    * `:spawn_fun` — `fn state, parent_meta, entry, registration_opts ->
      {:ok, child_id, state} | {:error, reason, state}`, the ONE injection point
      for the spawn half (an explicit option, never app env). The default
      registers the child and dispatches it.
  """
  @spec handle_rebuild(
          term(),
          term(),
          pos_integer(),
          GenServer.from(),
          keyword(),
          State.t()
        ) :: {:reply, rebuild_reply(), State.t()} | {:noreply, State.t()}
  def handle_rebuild(parent_id, plan, timeout, from, opts, %State{} = state) do
    with true <- is_integer(parent_id),
         {:ok, meta} when is_map(meta) <- Store.get_sched_meta(parent_id),
         :ok <- batch_idle(meta),
         {:ok, entries, expected, turn} <- normalize_plan(plan) do
      {results, pending} = classify(entries)
      spawn_fun = spawn_fun(opts)

      {results, indices, child_ids, state} =
        spawn_pending(pending, results, meta, turn, spawn_fun, state)

      finish(parent_id, meta, results, indices, child_ids, expected, timeout, from, state)
    else
      {:error, reason} -> {:reply, {:error, reason}, state}
      _absent -> {:reply, {:error, :no_pending_batch}, state}
    end
  end

  # --- Plan ---

  # A batch already in flight means a LIVE spawn (or an earlier rebuild) owns the
  # row: clobbering it would drop results and duplicate children.
  defp batch_idle(meta) do
    case Map.get(meta, :total_sub_specs, 0) do
      0 -> :ok
      nil -> :ok
      _in_flight -> {:error, :batch_in_flight}
    end
  end

  defp normalize_plan(%{turn: turn, expected_count: expected, entries: entries})
       when is_integer(turn) and is_integer(expected) and expected > 0 and is_list(entries) do
    if length(entries) == expected and Enum.all?(entries, &valid_entry?/1) do
      {:ok, Enum.sort_by(entries, & &1.index), expected, turn}
    else
      {:error, :invalid_plan}
    end
  end

  defp normalize_plan(_plan), do: {:error, :invalid_plan}

  defp valid_entry?(%{status: status, index: index} = entry) when status in @statuses do
    is_integer(index) and index >= 0 and
      case status do
        :done -> match?({:ok, %EvoGit.Agent.Result{}}, Map.get(entry, :result))
        :running -> match?(%EvoGit.AgentSpec{}, Map.get(entry, :spec))
        :missing -> true
      end
  end

  defp valid_entry?(_entry), do: false

  # `:done` keeps its stored result, `:missing` is the honest lost answer and
  # `:running` is what is left to spawn.
  defp classify(entries) do
    Enum.reduce(entries, {%{}, []}, fn entry, {results, pending} ->
      case entry.status do
        :done -> {Map.put(results, entry.index, entry.result), pending}
        :missing -> {Map.put(results, entry.index, SubagentReattach.lost_result()), pending}
        :running -> {results, [entry | pending]}
      end
    end)
    |> then(fn {results, pending} -> {results, Enum.sort_by(pending, & &1.index)} end)
  end

  # --- Spawn ---

  defp spawn_pending(pending, results, meta, turn, spawn_fun, state) do
    Enum.reduce(pending, {results, %{}, [], state}, fn entry, {results, indices, ids, state_acc} ->
      case safe_spawn(spawn_fun, state_acc, meta, entry, turn) do
        {:ok, child_id, state_acc} when is_integer(child_id) ->
          Logger.info(
            "AgentScheduler: rebuilt subagent slot #{entry.index} of agent #{meta.id} " <>
              "as agent #{child_id} (resumed from its durable row)"
          )

          {results, Map.put(indices, child_id, entry.index), [child_id | ids], state_acc}

        {:error, reason, state_acc} ->
          Logger.warning(
            "AgentScheduler: could not re-spawn subagent slot #{entry.index} of agent " <>
              "#{meta.id} (#{inspect(reason)}); storing a terminal error for that slot"
          )

          {Map.put(results, entry.index, {:error, reason}), indices, ids, state_acc}

        other ->
          Logger.warning(
            "AgentScheduler: subagent rebuild seam answered #{inspect(other)} for slot " <>
              "#{entry.index} of agent #{meta.id}; storing a terminal error for that slot"
          )

          {Map.put(results, entry.index, {:error, :subagent_rebuild_failed}), indices, ids,
           state_acc}
      end
    end)
    |> then(fn {results, indices, ids, state} -> {results, indices, Enum.reverse(ids), state} end)
  end

  # The seam is TOTAL: a raising default spawn must become a terminal error for
  # the slot, never take the shared scheduler down.
  defp safe_spawn(spawn_fun, state, meta, entry, turn) do
    spawn_fun.(state, meta, entry, registration_opts(entry, turn))
  rescue
    error ->
      {:error, {:spawn_failed, Exception.message(error)}, state}
  catch
    kind, reason -> {:error, {:spawn_failed, inspect({kind, reason})}, state}
  end

  defp spawn_fun(opts) do
    case Keyword.get(opts, :spawn_fun) do
      fun when is_function(fun, 4) -> fun
      _absent -> &default_spawn/4
    end
  end

  # The ordinary dispatch path: register under the child's PERSISTED id (the
  # registration fails closed when a live run still holds it), then dispatch.
  defp default_spawn(state, %SchedMeta{} = parent, entry, registration_opts) do
    case Dispatch.register_agent(
           state,
           entry.spec,
           nil,
           parent.id,
           parent.depth + 1,
           parent.task_id,
           parent.task_number,
           registration_opts
         ) do
      {:error, reason} ->
        {:error, reason, state}

      {child_id, state} ->
        {:ok, child_id, Dispatch.try_dispatch(state, child_id)}
    end
  end

  defp registration_opts(entry, turn) do
    [agent_id: entry.agent_id, spawn_index: entry.index, spawn_turn: turn]
    |> Enum.reject(fn {_key, value} -> is_nil(value) end)
  end

  # --- Finish ---

  defp finish(parent_id, meta, results, _indices, [], expected, _timeout, from, state) do
    ordered = Subagents.build_ordered_results(results, expected)

    Logger.info(
      "AgentScheduler: rebuilt subagent batch of agent #{parent_id} resolved immediately " <>
        "(#{map_size(results)}/#{expected} slot(s), nothing left running)"
    )

    clear_batch(parent_id, meta)
    reply(from, {:ok, ordered})

    {:reply, {:ok, ordered}, state}
  end

  defp finish(parent_id, meta, results, indices, child_ids, expected, timeout, from, state) do
    # The batch is written BEFORE the children are dispatched: a child can
    # complete in the same instant, and its `store_sub_result/3` must find the
    # index map and the expected count already in place.
    Store.put_sched_meta(parent_id, %{
      meta
      | status: :waiting,
        sub_agent_from: from,
        total_sub_specs: expected,
        sub_agent_results: results,
        sub_agent_indices: indices,
        pending_sub_agents: MapSet.new(child_ids)
    })

    state = SubagentReattach.put_waiter(state, parent_id, from, timeout)

    Logger.info(
      "AgentScheduler: rebuilt subagent batch of agent #{parent_id} " <>
        "(#{map_size(results)}/#{expected} slot(s) resolved, #{length(child_ids)} re-spawned)"
    )

    {:noreply, state}
  end

  # Leaves the parent `:running` with no batch, exactly like a batch that
  # resolved through the ordinary completion path.
  defp clear_batch(parent_id, %SchedMeta{} = meta) do
    Store.put_sched_meta(parent_id, %{
      meta
      | status: :running,
        sub_agent_from: nil,
        pending_sub_agents: MapSet.new(),
        sub_agent_results: %{},
        sub_agent_indices: %{},
        total_sub_specs: 0
    })
  end

  # A `nil` waiter (a caller that went away) is not a reply target; a dead pid is
  # a safe no-op send. `GenServer.reply/2` would raise on `nil`.
  defp reply(nil, _term), do: :ok
  defp reply(from, term), do: GenServer.reply(from, term)
end
