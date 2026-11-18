defmodule EvoGit.AgentState.Server do
  @moduledoc """
  The SINGLE serialized writer for the durable agent-state database.

  Every checkpoint is a cast handled here, so the agent session never touches
  the database: `:erlang.term_to_binary/2` compression and JSON encoding happen
  in this process, and one checkpoint is one transaction (scalar-row UPSERT +
  chunk INSERT) in strict arrival order.

  The dynamic repo pid is published in `:persistent_term` at init under
  `{EvoGit.AgentState, :repo, server_pid}` so `EvoGit.AgentState.repo/1` can
  answer without a `GenServer.call` (a call would queue behind pending
  checkpoint casts) and erased whenever the repo stops being usable.

  ## Coalescing

  A queued checkpoint cast for the SAME run is SUPERSEDED work: when a
  checkpoint is handled, every checkpoint cast already queued for that
  `(task_id, agent_id)` is drained with a selective `receive … after 0` (other
  runs' messages, `:sync` calls and everything else stay in the mailbox
  untouched), folded by `EvoGit.AgentState.Entry.fold/1` and persisted as ONE
  `EvoGit.AgentState.Store.checkpoint_batch/4` transaction. A stalled disk
  therefore costs one commit per drained batch instead of one per message, and
  the fold keeps the semantics of the whole queue (a later `:rewrite`
  supersedes, chained appends concatenate, a continuity gap stays its own
  operation).

  ## Bounded writer

  The writer's own mailbox is bounded, so a stalled disk can never OOM the VM:

    * OVER the backlog cap (`:max_backlog` start option, else app env
      `:agent_state_max_backlog`, default 200) the arriving checkpoint is
      DROPPED and NOT drained, and its `owner` is notified with
      `{:agent_state_resync, task_id, agent_id}` — the session answers that by
      rewriting its full transcript, so the loss self-heals;
    * a checkpoint whose measured payload exceeds `:max_payload_bytes`
      (`:agent_state_max_payload_bytes`, default 8 MiB) is skipped WITHOUT a
      resync (the owner would only re-send the same oversized payload);
    * both cases log ONE warning per run per failure streak — never one line
      per checkpoint — and the streak entry is dropped when a checkpoint for
      that run is accepted (so the bookkeeping is bounded by the runs
      currently skipping writes).

  Every one of those rules is a per-instance start option (with the app env as
  its default), so tests never mutate a BEAM-global.

  ## Degraded operation

  `init/1` NEVER fails. A broken/unwritable database, a repo that will not start
  or a failing migration leaves the server DEGRADED (`repo: nil`) — it logs ONE
  warning and schedules a retry with bounded exponential backoff (1 s doubling
  to a 60 s cap; `:boot_retry_base`/`:boot_retry_max` override it for tests).
  While degraded every public API stays total: a checkpoint is dropped, a read
  answers its documented error value, `prune` answers `{:ok, 0}` and the prune
  timer keeps rescheduling.

  A repo death (`{:EXIT, repo, reason}` / `{:DOWN, ...}`) is handled explicitly:
  the published repo is cleared, ONE warning is logged, the server stays alive
  and the same backoff path boots a fresh repo. A failed CHECKPOINT is never
  fatal — it is logged and dropped.
  """

  use GenServer

  require Logger

  alias EvoGit.AgentState.{Boot, Entry, Retention, Store}

  @default_retry_base 1_000
  @default_retry_max 60_000
  @default_max_backlog 200
  @default_max_payload_bytes 8 * 1024 * 1024

  @doc """
  Starts the server.

  ## Options

    * `:database` — the SQLite file (default `<data_dir>/agent_state.sqlite`)
    * `:data_dir` — data dir used when `:database` is absent
    * `:name` — registered name; defaults to `EvoGit.AgentState.Server`,
      `nil` starts an unnamed instance
    * `:retention_days` — retention window override (see
      `EvoGit.AgentState.Retention.configured_days/1`)
    * `:prune_interval` — prune timer cadence in ms
    * `:supervisor` — the pid of the owning `EvoGit.AgentState.Supervisor`,
      published so `EvoGit.AgentState` can resolve that pid to this server
    * `:boot_retry_base` / `:boot_retry_max` — degraded-boot retry backoff
      bounds in ms (default `1_000` / `60_000`)
    * `:max_backlog` — the writer's mailbox cap: over it a checkpoint is
      dropped, its owner resynced and ONE warning logged (default: app env
      `:agent_state_max_backlog`, else 200; `0` is a real cap)
    * `:max_payload_bytes` — the cap on one folded checkpoint's measured
      payload: above it the checkpoint is skipped with ONE warning and NO
      resync (default: app env `:agent_state_max_payload_bytes`, else 8 MiB)
  """
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    {name, opts} = Keyword.pop(opts, :name, __MODULE__)
    gen_opts = if is_nil(name), do: [], else: [name: name]
    GenServer.start_link(__MODULE__, opts, gen_opts)
  end

  @impl true
  def init(opts) do
    # The repo is `start_link`ed and this server must SURVIVE its death (see
    # "Degraded operation"), so the linked exit has to arrive as a message.
    Process.flag(:trap_exit, true)

    base = positive_integer(Keyword.get(opts, :boot_retry_base), @default_retry_base)
    max = positive_integer(Keyword.get(opts, :boot_retry_max), @default_retry_max)

    publish_server_for(Keyword.get(opts, :supervisor))

    state = %{
      repo: nil,
      repo_ref: nil,
      supervisor: Keyword.get(opts, :supervisor),
      database: database_path(opts),
      retention_days: Retention.configured_days(opts),
      prune_interval: Retention.prune_interval(opts),
      max_backlog: configured(opts, :max_backlog, :agent_state_max_backlog, @default_max_backlog),
      max_payload_bytes:
        configured(
          opts,
          :max_payload_bytes,
          :agent_state_max_payload_bytes,
          @default_max_payload_bytes
        ),
      warnings: %{},
      backoff: base,
      backoff_base: base,
      backoff_max: max,
      retry_scheduled?: false
    }

    state = boot(state)
    schedule_prune(state.prune_interval)

    {:ok, state}
  end

  ## Checkpoint writes (casts)

  @impl true
  def handle_cast({:checkpoint, task_id, agent_id, entry}, state) do
    {:noreply, checkpoint(state, task_id, agent_id, entry)}
  end

  ## Bookkeeping writes (casts: never a synchronous barrier for the caller)

  @impl true
  def handle_cast({:mark_completed, task_id, agent_id}, state) do
    with repo when is_pid(repo) <- state.repo do
      report("mark_completed", task_id, Store.mark_completed(repo, task_id, agent_id))
    end

    {:noreply, state}
  end

  def handle_cast({:delete, task_id, agent_id}, state) do
    with repo when is_pid(repo) <- state.repo do
      report("delete", task_id, Store.delete(repo, task_id, agent_id))
    end

    {:noreply, state}
  end

  def handle_cast({:delete_task, task_id}, state) do
    with repo when is_pid(repo) <- state.repo do
      report("delete_task", task_id, Store.delete_task(repo, task_id))
    end

    {:noreply, state}
  end

  # ONE message for a bulk cleanup (the registry clearing many finished tasks):
  # every task of the list is deleted in ONE transaction.
  def handle_cast({:delete_tasks, task_ids}, state) do
    with repo when is_pid(repo) <- state.repo,
         true <- is_list(task_ids) do
      report("delete_tasks", nil, Store.delete_tasks(repo, task_ids))
    end

    {:noreply, state}
  end

  def handle_cast(_message, state), do: {:noreply, state}

  ## Calls

  @impl true
  def handle_call({:put_pause_commit, _task_id, _agent_id, _sha}, _from, %{repo: nil} = state) do
    {:reply, {:error, :not_persistent_state_disabled}, state}
  end

  def handle_call({:put_pause_commit, task_id, agent_id, sha}, _from, state) do
    # Serialized with every checkpoint CAST in this same mailbox: a pause
    # marker can never reorder against, or race, a conversation write.
    {:reply, Store.put_pause_commit(state.repo, task_id, agent_id, sha), state}
  end

  def handle_call(:sync, _from, state) do
    # The durability barrier: OTP processes this call only after every earlier
    # checkpoint cast has been handled (and committed), so replying `:ok` here
    # means those checkpoints ARE durable. Never a cast, never fire-and-forget.
    # It is HONEST: a degraded writer can commit nothing, and a large queued
    # backlog means this reply no longer describes the state at the head of the
    # mailbox.
    reply =
      cond do
        is_nil(state.repo) -> {:error, :timeout}
        over_backlog?(state) -> {:error, :timeout}
        true -> :ok
      end

    {:reply, reply, state}
  end

  def handle_call(:prune, _from, %{repo: nil} = state), do: {:reply, {:ok, 0}, state}

  def handle_call(:prune, _from, state) do
    reply =
      case Store.prune(state.repo, state.retention_days) do
        {:ok, count} -> {:ok, count}
        {:error, reason} -> log_store_error("prune", nil, reason)
      end

    {:reply, reply, state}
  end

  def handle_call(_message, _from, state), do: {:reply, :ok, state}

  ## Timers & repo lifecycle

  @impl true
  def handle_info(:prune, %{repo: nil} = state) do
    schedule_prune(state.prune_interval)
    {:noreply, state}
  end

  def handle_info(:prune, state) do
    case Store.prune(state.repo, state.retention_days) do
      {:ok, 0} ->
        :ok

      {:ok, count} ->
        Logger.info("[AgentState] pruned #{count} expired run(s)")

      {:error, reason} ->
        log_store_error("prune", nil, reason)
    end

    schedule_prune(state.prune_interval)
    {:noreply, state}
  end

  # The degraded-boot retry tick: try again with the next backoff step.
  def handle_info(:boot_retry, state) do
    {:noreply, boot(%{state | retry_scheduled?: false})}
  end

  # The repo is linked AND monitored, so its death arrives as one of these two.
  # Handling it here (instead of a catch-all) is what keeps a live server from
  # sitting forever on a dead repo.
  def handle_info({:EXIT, repo, reason}, %{repo: repo} = state) do
    {:noreply, handle_repo_death(state, reason)}
  end

  def handle_info({:DOWN, ref, :process, repo, reason}, %{repo: repo, repo_ref: ref} = state) do
    {:noreply, handle_repo_death(state, reason)}
  end

  def handle_info(_message, state), do: {:noreply, state}

  @impl true
  def terminate(_reason, state) do
    :persistent_term.erase({EvoGit.AgentState, :repo, self()})

    if is_pid(state.supervisor) do
      :persistent_term.erase({EvoGit.AgentState, :server_for, state.supervisor})
    end

    # Justified catch: terminate/2 cleanup must never raise out of an OTP
    # shutdown, and `Supervisor.stop/3` exits when the repo is already gone.
    if is_pid(state.repo) do
      try do
        Boot.stop(state.repo)
      catch
        _kind, _reason -> :ok
      end
    end

    :ok
  end

  ## Boot / degraded operation

  defp boot(state) do
    case Boot.start_dynamic(state.database, pool_size: 2) do
      {:ok, repo} ->
        :persistent_term.put({EvoGit.AgentState, :repo, self()}, repo)

        %{
          state
          | repo: repo,
            repo_ref: Process.monitor(repo),
            backoff: state.backoff_base,
            retry_scheduled?: false
        }

      {:error, reason} ->
        Logger.warning(
          "[AgentState] durable store unavailable (#{describe(reason)}) for " <>
            "#{state.database}; starting DEGRADED, retrying in #{state.backoff} ms"
        )

        schedule_retry(state)
    end
  end

  defp schedule_retry(%{retry_scheduled?: true} = state), do: state

  defp schedule_retry(state) do
    Process.send_after(self(), :boot_retry, state.backoff)
    %{state | retry_scheduled?: true, backoff: min(state.backoff * 2, state.backoff_max)}
  end

  defp handle_repo_death(state, reason) do
    :persistent_term.erase({EvoGit.AgentState, :repo, self()})

    Logger.warning(
      "[AgentState] durable store stopped (#{describe(reason)}); degrading and " <>
        "scheduling a reboot"
    )

    state = %{state | repo: nil, repo_ref: nil}

    # An abnormal repo exit should not inherit an already-doubled delay from a
    # boot-failure streak: restart the backoff ladder so the reboot is prompt.
    schedule_retry(%{state | backoff: state.backoff_base})
  end

  ## Checkpoint handling: coalesce, bound, cap

  # A DEGRADED writer drops checkpoints SILENTLY: there is no store to write
  # them to, the boot warning already told the operator, and one log line per
  # checkpoint would be worse than the outage.
  defp checkpoint(%{repo: nil} = state, _task_id, _agent_id, _entry), do: state

  defp checkpoint(state, task_id, agent_id, entry) do
    case Entry.normalize(entry) do
      :error ->
        Logger.warning(
          "[AgentState] ignoring malformed checkpoint for task #{inspect(task_id)} " <>
            "agent #{inspect(agent_id)}"
        )

        state

      {:ok, entry} ->
        if over_backlog?(state) do
          # THE WRITER MUST NOT GROW ITS OWN QUEUE: drop the arriving
          # checkpoint (do NOT drain), let the owner resync the whole
          # transcript, and keep the queue where it is.
          drop(state, task_id, agent_id, entry.owner, backlog_detail(state))
        else
          write(state, task_id, agent_id, [entry | drain_checkpoints(task_id, agent_id)])
        end
    end
  end

  # Drain EVERY checkpoint cast already queued for this SAME run with a
  # selective receive: another agent's checkpoint, a `:sync` call and every
  # other message stay in the mailbox, untouched and in order.
  defp drain_checkpoints(task_id, agent_id, acc \\ []) do
    receive do
      {:"$gen_cast", {:checkpoint, ^task_id, ^agent_id, entry}} ->
        drain_checkpoints(task_id, agent_id, [entry | acc])
    after
      0 -> Enum.reverse(acc)
    end
  end

  defp write(state, task_id, agent_id, entries) do
    ops = Entry.fold(entries)
    key = {task_id, agent_id}

    cond do
      ops == [] ->
        clear_warning(state, key)

      true ->
        case payload_bytes(ops) do
          bytes when bytes > state.max_payload_bytes ->
            # NO resync here: a resync rebuilds the SAME oversized transcript,
            # so it could never succeed — the owner is not asked to retry it.
            drop(state, task_id, agent_id, owner_of(ops), payload_detail(state, bytes))

          _bytes ->
            persist(state, task_id, agent_id, ops, key)
        end
    end
  end

  defp persist(state, task_id, agent_id, ops, key) do
    case Store.checkpoint_batch(state.repo, task_id, agent_id, ops) do
      :ok ->
        clear_warning(state, key)

      :resync ->
        notify_resync(owner_of(ops), task_id, agent_id)
        state

      {:error, reason} ->
        Logger.warning(
          "[AgentState] checkpoint failed for task #{inspect(task_id)} " <>
            "agent #{inspect(agent_id)}: #{inspect(reason)}"
        )

        state
    end
  end

  # One DROPPED checkpoint: notify its owner (the session answers by rewriting
  # its full transcript, so the loss self-heals) and log at most one line per
  # run per failure streak.
  defp drop(state, task_id, agent_id, owner, detail) do
    notify_resync(owner, task_id, agent_id)
    warn_once(state, {task_id, agent_id}, detail)
  end

  defp owner_of(ops) do
    ops
    |> Enum.reverse()
    |> Enum.find_value(fn op -> Map.get(op, :owner) end)
  end

  # The payload cap is measured on `:erlang.external_size/1` of each operation's
  # messages — the UNCOMPRESSED external term size of exactly the term
  # `EvoGit.AgentState.Record.encode_messages/1` will hand to
  # `:erlang.term_to_binary/2` in the store. It is a cheap upper bound (no
  # compression pass, no binary allocated) and it is deterministic, unlike the
  # compressed blob size.
  defp payload_bytes(ops) do
    Enum.reduce(ops, 0, fn op, acc -> acc + :erlang.external_size(Map.get(op, :messages, [])) end)
  rescue
    # Justified rescue: `:erlang.external_size/1` raises on a term it cannot
    # externalize (the same one `term_to_binary` would reject) and a checkpoint
    # must never crash the writer. An unmeasurable payload is treated as
    # "within the cap" and then fails, totally, inside the store.
    _error -> 0
  end

  # ONE warning per run per failure streak: the first skipped checkpoint of a
  # run logs, every further one only counts. The entry is removed when a
  # checkpoint for that run is accepted, so the map is bounded by the runs
  # currently skipping writes — it never grows with traffic.
  defp warn_once(state, key, detail) do
    case Map.fetch(state.warnings, key) do
      {:ok, {^detail, count}} ->
        %{state | warnings: Map.put(state.warnings, key, {detail, count + 1})}

      {:ok, {_changed, count}} ->
        log_skip(key, detail)
        %{state | warnings: Map.put(state.warnings, key, {detail, count + 1})}

      :error ->
        log_skip(key, detail)
        %{state | warnings: Map.put(state.warnings, key, {detail, 1})}
    end
  end

  defp clear_warning(%{warnings: warnings} = state, key) do
    case Map.pop(warnings, key) do
      {nil, _remaining} ->
        state

      {{detail, count}, remaining} ->
        # The run recovered: ONE informational line closes the streak.
        Logger.info(
          "[AgentState] durable checkpoints resumed for #{describe_key(key)} " <>
            "after #{count} skipped checkpoint(s) (#{detail})"
        )

        %{state | warnings: remaining}
    end
  end

  defp log_skip(key, detail) do
    Logger.warning("[AgentState] skipping durable checkpoint for #{describe_key(key)}: #{detail}")
  end

  defp describe_key({task_id, agent_id}),
    do: "task #{inspect(task_id)} agent #{inspect(agent_id)}"

  # A continuity gap means the session's in-memory tail diverged from what is
  # stored (an earlier checkpoint failed or a restart lost it): the session
  # must resync, never append on top of a gap. `owner` may be dead — `send/2`
  # to a dead pid is a silent no-op.
  defp notify_resync(owner, task_id, agent_id) when is_pid(owner) do
    send(owner, {:agent_state_resync, task_id, agent_id})
    :ok
  end

  defp notify_resync(_owner, _task_id, _agent_id), do: :ok

  ## The bounded mailbox

  defp over_backlog?(state) do
    queue_length() > state.max_backlog
  end

  defp queue_length do
    case Process.info(self(), :message_queue_len) do
      {:message_queue_len, length} -> length
      _other -> 0
    end
  end

  defp backlog_detail(state),
    do: "writer backlog over its #{state.max_backlog}-message cap"

  defp payload_detail(state, bytes),
    do: "payload of #{bytes} bytes above the #{state.max_payload_bytes}-byte cap"

  ## Helpers

  defp report(_action, _task_id, :ok), do: :ok

  defp report(action, task_id, {:error, reason}) do
    log_store_error(action, task_id, reason)
  end

  defp log_store_error(action, task_id, reason) do
    Logger.warning(
      "[AgentState] #{action} failed#{if task_id, do: " for task #{inspect(task_id)}", else: ""}: " <>
        inspect(reason)
    )

    :ok
  end

  defp publish_server_for(supervisor) when is_pid(supervisor) do
    :persistent_term.put({EvoGit.AgentState, :server_for, supervisor}, self())
  end

  defp publish_server_for(_supervisor), do: :ok

  defp database_path(opts) do
    case Keyword.get(opts, :database) do
      database when is_binary(database) ->
        database

      _other ->
        data_dir =
          Keyword.get(opts, :data_dir) ||
            Application.get_env(:evo_git, :data_dir, EvoGit.Platform.data_dir())

        Path.join(data_dir, "agent_state.sqlite")
    end
  end

  defp schedule_prune(interval) do
    Process.send_after(self(), :prune, interval)
  end

  defp positive_integer(value, _default) when is_integer(value) and value > 0, do: value
  defp positive_integer(_value, default), do: default

  # A per-instance start option wins; the app env is only the DEFAULT (read at
  # init, so tests never mutate a BEAM-global to exercise a cap).
  defp configured(opts, option, env_key, default) do
    first_valid([Keyword.get(opts, option), Application.get_env(:evo_git, env_key)], default)
  end

  defp first_valid([value | rest], default) do
    if is_integer(value) and value >= 0, do: value, else: first_valid(rest, default)
  end

  defp first_valid([], default), do: default

  defp describe(reason) when is_binary(reason), do: reason
  defp describe(reason), do: inspect(reason)
end
