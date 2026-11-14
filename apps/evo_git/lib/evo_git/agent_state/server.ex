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
  checkpoint casts) and erased in `terminate/2`.

  Boot is FATAL on a broken/unwritable database: `EvoGit.AgentState.Boot`'s
  raises (`File.mkdir_p!/1`, the `{:ok, repo} = ...` match) propagate out of
  `init/1` so a non-persisting server is impossible. A failed CHECKPOINT is
  not fatal — it is logged and dropped.
  """

  use GenServer

  require Logger

  alias EvoGit.AgentState.{Boot, Retention, Store}

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
  """
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    {name, opts} = Keyword.pop(opts, :name, __MODULE__)
    gen_opts = if is_nil(name), do: [], else: [name: name]
    GenServer.start_link(__MODULE__, opts, gen_opts)
  end

  @impl true
  def init(opts) do
    database = database_path(opts)

    # FATAL by design: a broken or unwritable database must fail the boot
    # rather than degrade into a silently non-persisting server.
    {:ok, repo} = Boot.start_dynamic(database, pool_size: 2)

    :persistent_term.put({EvoGit.AgentState, :repo, self()}, repo)

    retention_days = Retention.configured_days(opts)
    prune_interval = Retention.prune_interval(opts)
    schedule_prune(prune_interval)

    {:ok,
     %{
       repo: repo,
       database: database,
       retention_days: retention_days,
       prune_interval: prune_interval
     }}
  end

  @impl true
  def handle_cast({:checkpoint, task_id, agent_id, entry}, state) do
    case normalize_entry(entry) do
      {:ok, entry, owner} ->
        persist(task_id, agent_id, entry, owner, state)

      :error ->
        Logger.warning(
          "[AgentState] ignoring malformed checkpoint for task #{inspect(task_id)} " <>
            "agent #{inspect(agent_id)}"
        )
    end

    {:noreply, state}
  end

  def handle_cast(_message, state), do: {:noreply, state}

  @impl true
  def handle_call({:mark_completed, task_id, agent_id}, _from, state) do
    :ok = report("mark_completed", task_id, Store.mark_completed(state.repo, task_id, agent_id))
    {:reply, :ok, state}
  end

  def handle_call({:delete, task_id, agent_id}, _from, state) do
    :ok = report("delete", task_id, Store.delete(state.repo, task_id, agent_id))
    {:reply, :ok, state}
  end

  def handle_call({:delete_task, task_id}, _from, state) do
    :ok = report("delete_task", task_id, Store.delete_task(state.repo, task_id))
    {:reply, :ok, state}
  end

  def handle_call({:put_pause_commit, task_id, agent_id, sha}, _from, state) do
    # Serialized with every checkpoint CAST in this same mailbox: a pause
    # marker can never reorder against, or race, a conversation write.
    {:reply, Store.put_pause_commit(state.repo, task_id, agent_id, sha), state}
  end

  def handle_call(:sync, _from, state) do
    # The durability barrier: OTP processes this call only after every earlier
    # checkpoint cast has been handled (and committed), so replying here means
    # those checkpoints ARE durable. Never a cast, never a fire-and-forget.
    {:reply, :ok, state}
  end

  def handle_call(:prune, _from, state) do
    reply =
      case Store.prune(state.repo, state.retention_days) do
        {:ok, count} -> {:ok, count}
        {:error, reason} -> log_store_error("prune", nil, reason)
      end

    {:reply, reply, state}
  end

  def handle_call(_message, _from, state), do: {:reply, :ok, state}

  @impl true
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

  def handle_info(_message, state), do: {:noreply, state}

  @impl true
  def terminate(_reason, state) do
    :persistent_term.erase({EvoGit.AgentState, :repo, self()})

    # Justified catch: terminate/2 cleanup must never raise out of an OTP
    # shutdown, and `Supervisor.stop/3` exits when the repo is already gone.
    try do
      Boot.stop(state.repo)
    catch
      _kind, _reason -> :ok
    end

    :ok
  end

  ## Checkpoint handling

  defp persist(task_id, agent_id, entry, owner, state) do
    case Store.checkpoint(state.repo, task_id, agent_id, entry) do
      :ok ->
        :ok

      :resync ->
        notify_resync(owner, task_id, agent_id)

      {:error, reason} ->
        Logger.warning(
          "[AgentState] checkpoint failed for task #{inspect(task_id)} " <>
            "agent #{inspect(agent_id)}: #{inspect(reason)}"
        )
    end
  end

  defp normalize_entry(%{kind: kind, messages: messages} = entry)
       when kind in [:append, :rewrite] and is_list(messages) do
    fields = Map.get(entry, :fields, %{})
    base_seq = Map.get(entry, :base_seq)

    cond do
      not valid_base_seq?(kind, base_seq) ->
        :error

      not is_map(fields) ->
        :error

      not valid_messages?(messages) ->
        :error

      true ->
        {:ok, %{kind: kind, messages: messages, fields: fields, base_seq: base_seq},
         Map.get(entry, :owner)}
    end
  end

  defp normalize_entry(_entry), do: :error

  defp valid_base_seq?(:append, nil), do: true
  defp valid_base_seq?(:append, base_seq), do: is_integer(base_seq) and base_seq >= 0
  defp valid_base_seq?(:rewrite, _base_seq), do: true

  defp valid_messages?(messages) do
    Enum.all?(messages, fn message -> is_struct(message, ReqLLM.Message) end)
  end

  # A continuity gap means the session's in-memory tail diverged from what is
  # stored (an earlier checkpoint failed or a restart lost it): the session
  # must resync, never append on top of a gap. `owner` may be dead — `send/2`
  # to a dead pid is a silent no-op.
  defp notify_resync(owner, task_id, agent_id) when is_pid(owner) do
    send(owner, {:agent_state_resync, task_id, agent_id})
    :ok
  end

  defp notify_resync(_owner, _task_id, _agent_id), do: :ok

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
end
