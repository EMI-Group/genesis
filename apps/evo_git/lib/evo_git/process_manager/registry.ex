defmodule EvoGit.ProcessManager.Registry do
  @moduledoc """
  The GenServer behind `EvoGit.ProcessManager`: ONE in-memory table of the live
  OS executions this node's agents and tasks hold.

  Started unconditionally by `EvoGit.Application`, BEFORE
  `EvoGit.BackgroundJobs` (which registers its detached jobs here) and before
  the scheduler's agents can run a tool. `EvoGit.ProcessManager` is the public
  facade; this module is the state owner and is never called directly by
  application code.

  ## State

    * `executions` — `%{id => %Execution{}}`, the live records.
    * `handles` — `%{id => %Handle{}}`, the OS addressing for an execution
      (kept OUT of the record because `Execution` models identity, not OS
      mechanics).
    * `owner_refs` — `%{monitor_ref => owner_pid}`: one monitor per distinct
      `:owner_pid`, so an agent's death fails every execution it owned.
    * `next_id`, `sample_seq` — the `"proc-<n>"` counter and the monotonic
      sample sequence (both reset on restart).
    * `sample_timer`, `sample_ref` — the ONE sampling timer and the monitor of
      the in-flight probe worker.

  ## Why the OS work never runs here

  Every `handle_call` is a pure state operation it can answer immediately. The
  probes themselves run in the CALLER (`sample/2`, `signal/3`, `kill/2` on the
  facade) or in an unlinked, monitored worker spawned by the sampling tick, so a
  hung `ps`/`systemctl`/`/proc` read can never block `get/2`, `list/1` or the
  dashboard.

  ## Sampling

  While at least one `:running`/`:paused` execution exists AND stats are enabled
  (`Application.get_env(:evo_git, :process_stats_enabled, true)`, read at CALL
  time), ONE self-timer fires every `sample_interval_ms/0` (app env
  `:process_manager_sample_interval_ms`, default `#{3_000}`). A tick spawns a
  monitored probe worker; when its results arrive the registry updates each
  record's `:stats` (broadcasting `{:process_updated, id, %{stats: stats}, node}`
  only when the numbers changed meaningfully) and then broadcasts ONE
  `{:process_sample, node, seq, summaries}`. Ticks that arrive while a worker is
  still in flight are dropped — sampling is incremental, never queued. The timer
  is disarmed as soon as no live execution remains, so an idle Genesis burns no
  OS calls.

  ## Owner lifetime

  `track/4` installs ONE `Process.monitor/1` per owner pid. When that process
  dies, every non-terminal execution it owned is best-effort killed (the OS call
  happens in a throwaway process, never here) and marked `:failed` with
  `reason: :owner_died`, so a ghost handle is never left `:running`.

  ## Retention

  `finish/4` and `prune/1` drop terminal records older than
  `finished_retention_ms/0` (app env `:process_finished_retention_ms`, default
  `#{300_000}`) and cap the retained terminal records at the newest
  `#{200}`. Live records are NEVER pruned.

  ## Totality

  Every handler is total: an unknown id is `{:ok, :ok}`, a re-`finish` is a
  no-op, a probe failure is data. A crashing GenServer would lose the whole
  node's execution view, so nothing here raises on bad input.
  """

  use GenServer
  require Logger

  alias EvoGit.ProcessManager.{Control, Execution, Handle, Stats}

  @topic "processes"
  @call_timeout 5_000
  @terminal Execution.terminal_statuses()
  @live Execution.live_statuses()
  # Retained terminal records (live ones are never pruned).
  @max_terminal 200
  # Bounded history per execution — a pause/resume hammer must not grow a record.
  @max_control_log 50

  @default_sample_interval_ms 3_000
  @default_finished_retention_ms 300_000

  @meta_keys %{
    "tool" => :tool,
    "command" => :command,
    "label" => :label,
    "agent_id" => :agent_id,
    "task_id" => :task_id,
    "owner_pid" => :owner_pid,
    "cwd" => :cwd,
    "repo_root" => :repo_root,
    "backend" => :backend,
    "runtime" => :runtime,
    "job_id" => :job_id
  }
  @known_meta_keys Map.values(@meta_keys) |> Enum.uniq()

  ## Client-side helpers (called by the facade, never by application code)

  @doc "Starts the registry. Honours `:name` (default `EvoGit.ProcessManager`)."
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    name = Keyword.get(opts, :name, EvoGit.ProcessManager)
    GenServer.start_link(__MODULE__, opts, name: name)
  end

  @doc "Records a new execution; returns its `\"proc-<n>\"` id."
  @spec track(GenServer.server(), Execution.kind(), map()) ::
          {:ok, String.t()} | {:error, :process_manager_unavailable}
  def track(server, kind, meta) do
    call(server, {:track, kind, meta}, {:error, :process_manager_unavailable})
  end

  @doc "Records the OS handle that became known for an execution."
  @spec attach(GenServer.server(), String.t(), term()) :: :ok
  def attach(server, id, handle), do: call(server, {:attach, id, handle}, :ok)

  @doc "Records a terminal status (idempotent)."
  @spec finish(GenServer.server(), String.t(), Execution.status(), keyword()) :: :ok
  def finish(server, id, status, opts \\ []), do: call(server, {:finish, id, status, opts}, :ok)

  @doc "Lists executions (newest first), filtered by the given keys."
  @spec list(GenServer.server(), keyword()) :: [Execution.t()]
  def list(server, filters \\ []) do
    case call(server, {:list, filters}, []) do
      list when is_list(list) -> list
      _ -> []
    end
  end

  @doc "Fetches one execution."
  @spec get(GenServer.server(), String.t()) :: {:ok, Execution.t()} | {:error, :not_found}
  def get(server, id), do: call(server, {:get, id}, {:error, :not_found})

  @doc """
  Resolves one execution TOGETHER with its OS handle — the read the facade needs
  before probing/signalling outside the registry.
  Returns `{:ok, execution, handle_or_nil}` or `{:error, :not_found}`.
  """
  @spec lookup(GenServer.server(), String.t()) ::
          {:ok, Execution.t(), Handle.t() | nil} | {:error, :not_found}
  def lookup(server, id), do: call(server, {:lookup, id}, {:error, :not_found})

  @doc "Every `:running`/`:paused` execution as `[{id, status, handle}]`, oldest first."
  @spec live(GenServer.server()) :: [{String.t(), Execution.status(), Handle.t() | nil}]
  def live(server) do
    case call(server, :live, []) do
      list when is_list(list) -> list
      _ -> []
    end
  end

  @doc false
  # Records a caller-probed stats map (an on-demand `sample/2`). A cast: the
  # caller never waits for its own observation to be stored.
  @spec record_stats(GenServer.server(), String.t(), Stats.t()) :: :ok
  def record_stats(server, id, stats) when is_map(stats) do
    cast(server, {:record_stats, id, stats})
  end

  @doc false
  # Records an accepted control action: appends to the execution's log,
  # broadcasts `{:process_control, …}` and applies any implied status change.
  @spec record_control(GenServer.server(), String.t(), Execution.control_entry(), atom() | nil) ::
          :ok
  def record_control(server, id, entry, new_status \\ nil) do
    cast(server, {:record_control, id, entry, new_status})
  end

  @doc """
  Runs retention now and returns `{:ok, removed_count}`.
  Normally called internally on every `finish` and every sampling tick; exposed
  so an operator (or a suite testing retention) can force a pass.
  """
  @spec prune(GenServer.server()) :: {:ok, non_neg_integer()}
  def prune(server), do: call(server, :prune, {:ok, 0})

  ## Call-time seams (app env only — deliberately no TOML keys)

  @doc "Sampling interval (ms) — app env `:process_manager_sample_interval_ms`."
  @spec sample_interval_ms() :: pos_integer()
  def sample_interval_ms do
    case Application.get_env(
           :evo_git,
           :process_manager_sample_interval_ms,
           @default_sample_interval_ms
         ) do
      ms when is_integer(ms) and ms > 0 -> ms
      _other -> @default_sample_interval_ms
    end
  end

  @doc "Whether stats sampling is enabled — app env `:process_stats_enabled`."
  @spec stats_enabled?() :: boolean()
  def stats_enabled? do
    Application.get_env(:evo_git, :process_stats_enabled, true) == true
  end

  @doc "Retention window (ms) for terminal records — app env `:process_finished_retention_ms`."
  @spec finished_retention_ms() :: non_neg_integer()
  def finished_retention_ms do
    case Application.get_env(
           :evo_git,
           :process_finished_retention_ms,
           @default_finished_retention_ms
         ) do
      ms when is_integer(ms) and ms >= 0 -> ms
      _other -> @default_finished_retention_ms
    end
  end

  ## GenServer callbacks

  @impl true
  def init(_opts) do
    {:ok,
     %{
       executions: %{},
       handles: %{},
       owner_refs: %{},
       next_id: 0,
       sample_seq: 0,
       sample_timer: nil,
       sample_ref: nil
     }}
  end

  @impl true
  def handle_call({:track, kind, meta}, _from, state) do
    id = next_id(state)
    now = DateTime.utc_now()
    execution = build_execution(id, kind, meta, now)

    state = %{
      state
      | executions: Map.put(state.executions, id, execution),
        next_id: state.next_id + 1
    }

    state = monitor_owner(state, id, execution.owner_pid)

    {:reply, {:ok, id}, arm_sampling(state)}
  end

  def handle_call({:attach, id, raw_handle}, _from, state) do
    {:reply, :ok, do_attach(state, id, raw_handle)}
  end

  def handle_call({:finish, id, status, opts}, _from, state) do
    {:reply, :ok, do_finish(state, id, status, opts)}
  end

  def handle_call({:list, filters}, _from, state) do
    executions =
      state.executions
      |> Map.values()
      |> apply_filters(filters)
      |> sort_newest_first()

    {:reply, executions, state}
  end

  def handle_call({:get, id}, _from, state) do
    case Map.fetch(state.executions, id) do
      {:ok, execution} -> {:reply, {:ok, execution}, state}
      :error -> {:reply, {:error, :not_found}, state}
    end
  end

  def handle_call({:lookup, id}, _from, state) do
    case Map.fetch(state.executions, id) do
      {:ok, execution} -> {:reply, {:ok, execution, Map.get(state.handles, id)}, state}
      :error -> {:reply, {:error, :not_found}, state}
    end
  end

  def handle_call(:live, _from, state) do
    live =
      state.executions
      |> Map.values()
      |> Enum.filter(&Execution.live?(&1.status))
      |> sort_oldest_first()
      |> Enum.map(&{&1.id, &1.status, Map.get(state.handles, &1.id)})

    {:reply, live, state}
  end

  def handle_call(:prune, _from, state) do
    {state, removed} = prune_state(state)
    {:reply, {:ok, removed}, arm_sampling(state)}
  end

  def handle_call(_request, _from, state), do: {:reply, :ok, state}

  @impl true
  def handle_cast({:record_stats, id, stats}, state) do
    {:noreply, update_execution(state, id, fn execution -> %{execution | stats: stats} end)}
  end

  def handle_cast({:record_control, id, entry, new_status}, state) do
    {:noreply, do_record_control(state, id, entry, new_status)}
  end

  def handle_cast(_message, state), do: {:noreply, state}

  @impl true
  def handle_info(:sample_tick, state) do
    state = %{state | sample_timer: nil}
    state = maybe_start_sample(state)
    {:noreply, arm_sampling(state)}
  end

  def handle_info({:process_sample_results, seq, results}, state) do
    if seq == state.sample_seq do
      {:noreply, apply_sample_results(%{state | sample_ref: nil}, seq, results)}
    else
      # A stale worker (a tick raced a disarm): its numbers belong to no sample.
      {:noreply, state}
    end
  end

  def handle_info({:DOWN, ref, :process, _pid, _reason}, state) do
    cond do
      ref == state.sample_ref ->
        {:noreply, %{state | sample_ref: nil}}

      Map.has_key?(state.owner_refs, ref) ->
        {owner_pid, owner_refs} = Map.pop(state.owner_refs, ref)
        state = %{state | owner_refs: owner_refs}
        {:noreply, fail_owned(state, owner_pid)}

      true ->
        {:noreply, state}
    end
  end

  def handle_info(_message, state), do: {:noreply, state}

  ## Track / attach / finish internals

  defp build_execution(id, kind, meta, now) do
    %Execution{
      id: id,
      kind: kind,
      tool: string_or_nil(meta[:tool]),
      command: string_or_nil(meta[:command]),
      label: string_or_nil(meta[:label]),
      agent_id: meta[:agent_id],
      task_id: meta[:task_id],
      owner_pid: pid_or_nil(meta[:owner_pid]),
      cwd: string_or_nil(meta[:cwd]),
      repo_root: string_or_nil(meta[:repo_root]),
      backend: backend(meta[:backend]),
      runtime: runtime(meta[:runtime]),
      job_id: string_or_nil(meta[:job_id]),
      status: :starting,
      inserted_at: now,
      stats: Stats.empty(),
      control_log: []
    }
  end

  defp monitor_owner(state, _id, owner_pid) when not is_pid(owner_pid), do: state

  defp monitor_owner(state, _id, owner_pid) do
    if Enum.any?(state.owner_refs, fn {_ref, pid} -> pid == owner_pid end) do
      state
    else
      %{state | owner_refs: Map.put(state.owner_refs, Process.monitor(owner_pid), owner_pid)}
    end
  end

  defp do_attach(state, id, raw_handle) do
    with {:ok, execution} <- Map.fetch(state.executions, id),
         false <- Execution.terminal?(execution.status),
         {:ok, handle} <- Handle.normalize(raw_handle) do
      previously = execution.status

      execution = %{
        execution
        | status: :running,
          started_at: execution.started_at || DateTime.utc_now(),
          os_pid: handle.os_pid || execution.os_pid,
          unit: handle.unit || execution.unit,
          backend: attach_backend(execution.backend, handle)
      }

      state = %{
        state
        | executions: Map.put(state.executions, id, execution),
          handles: Map.put(state.handles, id, handle)
      }

      state =
        case previously do
          :starting ->
            broadcast({:process_started, execution, node()})
            state

          :running ->
            state

          _other ->
            broadcast({:process_updated, id, %{status: :running}, node()})
            state
        end

      arm_sampling(state)
    else
      {:error, :invalid_handle} ->
        Logger.debug("ProcessManager: ignoring an unrecognized handle for #{inspect(id)}")
        state

      _ ->
        state
    end
  end

  # A caller that already recorded a backend keeps it; `:none` (the default) is
  # upgraded from the handle, so phase 2 shows the real sandbox backend.
  defp attach_backend(current, handle) when current in [nil, :none] do
    Handle.execution_backend(handle) || current || :none
  end

  defp attach_backend(current, _handle), do: current

  defp do_finish(state, id, status, opts) do
    with true <- status in @terminal,
         {:ok, execution} <- Map.fetch(state.executions, id),
         false <- Execution.terminal?(execution.status) do
      execution = %{
        execution
        | status: status,
          ended_at: DateTime.utc_now(),
          exit_code: int_or_keep(Keyword.get(opts, :exit_code), execution.exit_code),
          reason: Keyword.get(opts, :reason, execution.reason)
      }

      state = %{state | executions: Map.put(state.executions, id, execution)}
      broadcast({:process_exited, execution, node()})
      {state, _removed} = prune_state(state)
      arm_sampling(state)
    else
      _ -> state
    end
  end

  defp do_record_control(state, id, entry, new_status) do
    case Map.fetch(state.executions, id) do
      :error ->
        state

      {:ok, execution} ->
        execution = %{
          execution
          | control_log: Enum.take(execution.control_log ++ [entry], -@max_control_log)
        }

        broadcast({:process_control, id, entry, node()})

        execution =
          if new_status in @live and new_status != execution.status and
               not Execution.terminal?(execution.status) do
            broadcast({:process_updated, id, %{status: new_status}, node()})
            %{execution | status: new_status}
          else
            execution
          end

        %{state | executions: Map.put(state.executions, id, execution)}
    end
  end

  ## Owner death

  defp fail_owned(state, owner_pid) when not is_pid(owner_pid), do: state

  defp fail_owned(state, owner_pid) do
    now = DateTime.utc_now()

    {executions, exited} =
      Enum.reduce(state.executions, {state.executions, []}, fn
        {id, %Execution{owner_pid: ^owner_pid} = execution}, {acc, exited} ->
          if Execution.terminal?(execution.status) do
            {acc, exited}
          else
            # The OS call runs in a throwaway process: the registry must answer
            # `get`/`list` immediately even while `kill` waits out its grace.
            kill_async(Map.get(state.handles, id))
            failed = %{execution | status: :failed, reason: :owner_died, ended_at: now}
            {Map.put(acc, id, failed), [failed | exited]}
          end

        _other, acc ->
          acc
      end)

    Enum.each(Enum.reverse(exited), fn execution ->
      broadcast({:process_exited, execution, node()})
    end)

    {state, _removed} = prune_state(%{state | executions: executions})
    arm_sampling(state)
  end

  defp kill_async(nil), do: :ok

  defp kill_async(handle) do
    # Unlinked and unsupervised on purpose: a backend that hangs must not keep a
    # dead owner's handle alive, and this process has no state to lose.
    spawn(fn ->
      try do
        Control.kill(handle)
      rescue
        _ -> :ok
      catch
        _, _ -> :ok
      end
    end)

    :ok
  end

  ## Sampling

  defp arm_sampling(state) do
    cond do
      not stats_enabled?() ->
        disarm_sampling(state)

      not any_live?(state) ->
        disarm_sampling(state)

      state.sample_timer != nil ->
        state

      true ->
        %{state | sample_timer: Process.send_after(self(), :sample_tick, sample_interval_ms())}
    end
  end

  defp disarm_sampling(state) do
    if state.sample_timer, do: Process.cancel_timer(state.sample_timer)
    %{state | sample_timer: nil}
  end

  defp any_live?(state) do
    Enum.any?(state.executions, fn {_id, execution} -> Execution.live?(execution.status) end)
  end

  defp maybe_start_sample(state) do
    cond do
      not stats_enabled?() ->
        state

      state.sample_ref != nil ->
        # The previous probe worker is still running — skip this tick instead of
        # queueing a second one (sampling stays incremental).
        state

      not any_live?(state) ->
        state

      true ->
        entries =
          state.executions
          |> Map.values()
          |> Enum.filter(&Execution.live?(&1.status))
          |> Enum.map(&{&1.id, Map.get(state.handles, &1.id)})
          |> Enum.reject(fn {_id, handle} -> is_nil(handle) end)

        case entries do
          [] ->
            state

          entries ->
            registry = self()
            seq = state.sample_seq + 1

            {_pid, ref} =
              spawn_monitor(fn ->
                send(registry, {:process_sample_results, seq, probe_all(entries)})
              end)

            %{state | sample_seq: seq, sample_ref: ref}
        end
    end
  end

  # Runs in the probe worker — ONE stats call per live execution, failures
  # omitted (a dead handle is reconciled by the caller's next action, not here).
  defp probe_all(entries) do
    Enum.flat_map(entries, fn {id, handle} ->
      try do
        case Control.stats(handle) do
          {:ok, stats} when is_map(stats) -> [{id, stats}]
          _ -> []
        end
      rescue
        _ -> []
      catch
        _, _ -> []
      end
    end)
  end

  defp apply_sample_results(state, seq, results) when is_list(results) do
    {state, summaries} =
      Enum.reduce(results, {state, []}, fn {id, stats}, {state, summaries} ->
        case Map.fetch(state.executions, id) do
          {:ok, execution} ->
            if Execution.live?(execution.status) do
              previous = execution.stats
              stats = merge_stats(previous, stats)
              execution = %{execution | stats: stats}

              if Stats.changed?(previous, stats) do
                broadcast({:process_updated, id, %{stats: stats}, node()})
              end

              summary = %{id: id, status: execution.status, stats: stats}

              {%{state | executions: Map.put(state.executions, id, execution)},
               [summary | summaries]}
            else
              # It finished while the worker was probing — nothing to sample.
              {state, summaries}
            end

          :error ->
            {state, summaries}
        end
      end)

    broadcast({:process_sample, node(), seq, Enum.reverse(summaries)})

    {state, _removed} = prune_state(state)
    state
  end

  defp apply_sample_results(state, _seq, _results), do: state

  # A backend that reports cumulative CPU only (Linux `/proc`) has no
  # percentage; derive it from the delta against the previous sample of the SAME
  # tree, which is exactly what makes the dashboard chart meaningful.
  defp merge_stats(previous, stats) when is_map(previous) and is_map(stats) do
    cond do
      is_number(stats[:cpu_percent]) ->
        stats

      true ->
        percent =
          Stats.cpu_percent(
            previous[:cpu_time_ms],
            previous[:sampled_at],
            stats[:cpu_time_ms],
            stats[:sampled_at]
          )

        Map.put(stats, :cpu_percent, percent)
    end
  end

  defp merge_stats(_previous, stats), do: stats

  ## Retention

  defp prune_state(state) do
    now = DateTime.utc_now()
    retention = finished_retention_ms()

    terminal =
      state.executions
      |> Map.values()
      |> Enum.filter(&Execution.terminal?(&1.status))

    expired =
      Enum.filter(terminal, fn execution ->
        case execution.ended_at do
          %DateTime{} = ended_at ->
            DateTime.diff(now, ended_at, :millisecond) >= retention

          _ ->
            # A terminal record with no end time cannot age; keep it (it will be
            # capped by the terminal count below).
            false
        end
      end)

    keep_newest =
      terminal
      |> Enum.reject(&(&1 in expired))
      |> Enum.sort_by(&sort_key/1, :desc)
      |> Enum.take(@max_terminal)

    doomed = MapSet.new(expired ++ (terminal -- keep_newest))
    doomed_ids = doomed |> Enum.map(& &1.id) |> Enum.reject(&is_nil/1)

    if doomed_ids == [] do
      {state, 0}
    else
      %{
        state
        | executions: Map.drop(state.executions, doomed_ids),
          handles: Map.drop(state.handles, doomed_ids)
      }
      |> then(&{&1, length(doomed_ids)})
    end
  end

  ## Small helpers

  defp update_execution(state, id, fun) do
    case Map.fetch(state.executions, id) do
      {:ok, execution} -> %{state | executions: Map.put(state.executions, id, fun.(execution))}
      :error -> state
    end
  end

  defp apply_filters(executions, filters) do
    Enum.filter(executions, fn execution ->
      Enum.all?([:agent_id, :task_id, :kind, :status, :backend], fn key ->
        case Keyword.fetch(filters, key) do
          {:ok, value} -> Map.get(execution, key) == value
          :error -> true
        end
      end)
    end)
  end

  defp sort_newest_first(executions) do
    Enum.sort_by(executions, &sort_key/1, :desc)
  end

  defp sort_oldest_first(executions) do
    Enum.sort_by(executions, &sort_key/1, :asc)
  end

  # `inserted_at` first, then the numeric id — so two records created inside the
  # same microsecond still order by their monotonic id.
  defp sort_key(%Execution{} = execution) do
    {inserted, id} = {execution.inserted_at, execution.id}
    {unix(inserted), id_number(id)}
  end

  defp sort_key(_execution), do: {0, 0}

  defp unix(%DateTime{} = datetime), do: DateTime.to_unix(datetime, :microsecond)
  defp unix(_datetime), do: 0

  defp id_number(id) when is_binary(id) do
    case Integer.parse(String.replace_prefix(id, "proc-", "")) do
      {number, _} -> number
      _ -> 0
    end
  end

  defp id_number(id) when is_integer(id), do: id
  defp id_number(_id), do: 0

  defp next_id(state), do: "proc-#{state.next_id + 1}"

  defp backend(value) when value in [:systemd, :bwrap, :sandbox_exec, :none], do: value
  defp backend(_value), do: :none

  defp runtime(value) when value in [:foreground, :detached], do: value
  defp runtime("detached"), do: :detached
  defp runtime("foreground"), do: :foreground
  defp runtime(_value), do: :foreground

  defp pid_or_nil(pid) when is_pid(pid), do: pid
  defp pid_or_nil(_pid), do: nil

  defp string_or_nil(value) when is_binary(value) and value != "", do: value
  defp string_or_nil(_value), do: nil

  defp int_or_keep(value, _current) when is_integer(value), do: value
  defp int_or_keep(_value, current), do: current

  @doc false
  # Tolerant meta normalization: atom keys win, the documented string keys are
  # mapped, anything else is dropped (never `String.to_atom/1`).
  @spec normalize_meta(term()) :: map()
  def normalize_meta(meta) when is_list(meta), do: normalize_meta(Map.new(meta))

  def normalize_meta(meta) when is_map(meta) do
    Enum.reduce(meta, %{}, fn {key, value}, acc ->
      case meta_key(key) do
        nil -> acc
        atom -> Map.put(acc, atom, value)
      end
    end)
  end

  def normalize_meta(_meta), do: %{}

  defp meta_key(key) when key in @known_meta_keys, do: key
  defp meta_key(key) when is_binary(key), do: Map.get(@meta_keys, key)
  defp meta_key(_key), do: nil

  defp broadcast(message) do
    Phoenix.PubSub.broadcast(EvoGit.PubSub, @topic, message)
  rescue
    _ -> :ok
  catch
    _, _ -> :ok
  end

  defp call(server, message, fallback) do
    GenServer.call(server, message, @call_timeout)
  catch
    :exit, _reason -> fallback
  end

  defp cast(server, message) do
    GenServer.cast(server, message)
  rescue
    _ -> :ok
  catch
    _, _ -> :ok
  end
end
