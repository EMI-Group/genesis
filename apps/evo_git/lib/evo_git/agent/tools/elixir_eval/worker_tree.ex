defmodule EvoGit.Agent.Tools.ElixirEval.WorkerTree do
  @moduledoc """
  An unlinked, monitored guardian for one evaluation and all of its BEAM descendants.

  Spawn tracing belongs to an independent custodian, installed on the waiting
  guardian BEFORE it can spawn any evaluation code. It is inherited across Dune's
  Task/proc_lib children, including unlinked helpers, and survives guardian death.
  Cleanup kills descendants and confirms their deaths plus a trace-delivery barrier
  within its own 1s budget; an incomplete cleanup is an error, never success.
  The guardian monitors both the tool caller and optional context owner_pid/agent_pid.
  The caller has an absolute result deadline and bounded finalization (at most the
  execution budget plus 6,350 ms of scheduled waiting, not a real-time guarantee).

  Reduction/memory limits are sampled every 5 ms, not OS resource isolation: a native
  BIF can transiently overshoot a sample, and an approved sudo program has full VM
  authority, including the ability to interfere with this guardian or tracing.
  """
  alias EvoGit.Agent.Tools.ElixirEval.{Broker, Custodian, Render}
  @max_heap_words 2_000_000
  @max_tree_bytes 64 * 1_024 * 1_024
  @max_reductions 20_000_000
  @max_processes 64
  @sample_ms 5
  @overhead_ms 5_000
  @broker_call_ms 1_200
  @broker_stop_ms 250

  def run(context, tier, limits, fun) do
    caller = self()
    ref = make_ref()
    deadline = now() + limits.timeout_ms + @overhead_ms

    {pid, monitor} =
      spawn_monitor(fn -> guard(caller, ref, limits, fun, context) end)

    {custodian, custody_monitor} = Custodian.start(pid, caller, ref, deadline)

    # Only the original authorized tool creates the broker. It explicitly hands
    # control to this waiting guardian without replacing tool_pid/owner_pid or
    # pretending the unlinked guardian is a Task descendant of the tool.
    try do
      case Broker.start(context, tier, pid, @broker_call_ms) do
        {:ok, broker} ->
          try do
            send(pid, {ref, :broker, broker})

            receive do
              {^ref, result} -> result
              {:DOWN, ^monitor, :process, ^pid, _} -> {:error, "Evaluation guardian failed."}
            after
              max(deadline - now(), 0) -> {:error, "Evaluation infrastructure timed out."}
            end
          after
            stop_broker(broker)
          end

        _ ->
          {:error, "Evaluation broker unavailable."}
      end
    rescue
      # Trusted lifecycle failures must not expose context, exceptions or exits.
      _ -> {:error, "Evaluation infrastructure failed."}
    catch
      _, _ -> {:error, "Evaluation infrastructure failed."}
    after
      Process.exit(pid, :kill)
      # Do not kill the independent custodian with the guardian: it owns the
      # unlinked descendants, including spawn events the guardian never consumed.
      send(custodian, {ref, :cleanup, self()})

      receive do
        {:DOWN, ^custody_monitor, :process, ^custodian, _} -> :ok
      after
        Custodian.cleanup_ms() + 100 -> :ok
      end

      Process.demonitor(custody_monitor, [:flush])
      Process.demonitor(monitor, [:flush])
    end
  end

  defp stop_broker(broker) do
    Broker.stop(broker, @broker_stop_ms)
    # A suspended/unresponsive broker cannot extend the caller's wait. Its linked
    # pending Task dies with this kill; unlinked evaluation workers belong to custody.
    Process.exit(broker, :kill)
  end

  defp guard(caller, ref, limits, fun, context) do
    receive do
      {^ref, :custodian, custodian} ->
        guard_broker(caller, ref, limits, fun, context, custodian)
    after
      @overhead_ms -> :ok
    end
  end

  defp guard_broker(caller, ref, limits, fun, context, custodian) do
    owners =
      [caller, Map.get(context, :owner_pid), Map.get(context, :agent_pid)]
      |> Enum.filter(&is_pid/1)
      |> Enum.uniq()
      |> Map.new(&{Process.monitor(&1), &1})

    receive do
      {^ref, :broker, broker} when is_pid(broker) ->
        # Central boundary for trusted broker/worker lifecycle failures. Never
        # inspect an exception, exit reason, context or stacktrace into a reply.
        result =
          try do
            execute(broker, owners, limits, fun, custodian, ref)
          rescue
            _ -> {:error, "Evaluation infrastructure failed."}
          catch
            _, _ -> {:error, "Evaluation infrastructure failed."}
          after
            stop_broker(broker)
          end

        send(caller, {ref, result})

      {:DOWN, monitor, :process, _, _} when is_map_key(owners, monitor) ->
        :ok
    after
      @overhead_ms -> :ok
    end
  end

  defp execute(broker, owners, limits, fun, custodian, custody_token) do
    guardian = self()
    token = make_ref()
    broker_ref = Process.monitor(broker)
    custody_ref = Process.monitor(custodian)

    {worker, monitor} =
      :erlang.spawn_opt(
        fn ->
          # Raw spawn_opt deliberately creates NO links. Seed ancestry only here,
          # in trusted code, before any evaluated code or Dune process can run.
          # Dune's nested proc_lib/Task children discover this root via their own
          # runtime-maintained ancestry; no broker token is copied into user code.
          Process.put(:"$ancestors", [guardian])
          Process.put(:evogit_eval_broker, broker)
          send(guardian, {:worker_ready, token, self()})

          receive do
            {:execute, ^token} ->
              result = safe_evaluate(fn -> fun.(broker) end)
              send(guardian, {:evaluated, token, self(), result})
          end
        end,
        [
          :monitor,
          max_heap_size: %{
            size: @max_heap_words,
            kill: true,
            error_logger: false,
            include_shared_binaries: true
          }
        ]
      )

    state = %{
      worker: worker,
      workers: %{worker => monitor},
      owners: owners,
      broker_ref: broker_ref,
      custody_ref: custody_ref,
      token: token,
      deadline: now() + limits.timeout_ms,
      spawned: 1,
      reductions: %{},
      total_reductions: 0
    }

    # Nothing can run until both tracing and the broker ancestry fence are ready.
    # Even attach/trace failure must reap the already spawned (waiting) worker.
    result =
      try do
        with :ok <- await_ready(state),
             :ok <- Broker.attach(broker, worker, @broker_call_ms) do
          send(worker, {:execute, token})
          watch(state)
        else
          _ -> {:error, "Evaluation worker authorization failed."}
        end
      after
        # Covers exceptions before normal custody handoff. Guardian death also
        # activates the independent custodian, even if this after never runs.
        Process.exit(worker, :kill)
        Enum.each(state.workers, fn {_, monitor} -> Process.demonitor(monitor, [:flush]) end)
        Process.demonitor(broker_ref, [:flush])
        Process.demonitor(custody_ref, [:flush])
      end

    case Custodian.finish(custodian, custody_token) do
      :ok ->
        output = Render.text(Broker.output(broker, @broker_call_ms), limits.max_output_bytes)

        case result do
          {:ok, text} -> {:ok, Render.text(output <> text, limits.max_output_bytes)}
          {:error, text} -> {:error, Render.text(output <> text, limits.max_output_bytes)}
        end

      :error ->
        {:error, "Evaluation cleanup did not complete within its budget."}
    end
  end

  # Wait for the trusted dictionary seed, not a Task.async startup race or link.
  # No user function runs until this handshake AND Broker.attach have succeeded.
  defp await_ready(state) do
    receive do
      {:worker_ready, token, worker} when token == state.token and worker == state.worker ->
        :ok

      {:DOWN, _, :process, _, _} ->
        :error
    after
      max(state.deadline - now(), 0) -> :error
    end
  end

  defp safe_evaluate(fun) do
    # Evaluated exceptions may contain credentials in their messages/terms.
    try do
      fun.()
    rescue
      _ -> {:error, "Evaluation raised an exception."}
    catch
      _, _ -> {:error, "Evaluation exited or threw a value."}
    end
  end

  defp watch(state) do
    # A permanently nonempty trace mailbox must not starve the execution timer.
    if now() >= state.deadline,
      do: {:error, "Evaluation timed out."},
      else: watch_until_deadline(state)
  end

  defp watch_until_deadline(state) do
    remaining = max(state.deadline - now(), 0)

    receive do
      {:evaluated, token, worker, result} when token == state.token and worker == state.worker ->
        result

      {:trace, _, :spawn, child, _} ->
        state = add_worker(state, child)

        if state.spawned > @max_processes,
          do: {:error, "Evaluation process limit exceeded."},
          else: watch(state)

      {:DOWN, ref, :process, _, _} when is_map_key(state.owners, ref) ->
        {:error, "Evaluation owner stopped."}

      {:DOWN, ref, :process, _, _} when ref == state.broker_ref ->
        {:error, "Evaluation broker stopped."}

      {:DOWN, ref, :process, _, _} when ref == state.custody_ref ->
        {:error, "Evaluation custodian stopped."}

      {:DOWN, _, :process, worker, _} when worker == state.worker ->
        {:error, "Evaluation worker stopped (memory limit or runtime failure)."}

      {:DOWN, _, :process, pid, _} ->
        watch(%{state | workers: Map.delete(state.workers, pid)})

      _ ->
        watch(state)
    after
      min(remaining, @sample_ms) ->
        cond do
          now() >= state.deadline ->
            {:error, "Evaluation timed out."}

          true ->
            {bytes, reductions, total} = sample(state)
            state = %{state | reductions: reductions, total_reductions: total}

            cond do
              bytes > @max_tree_bytes -> {:error, "Evaluation memory limit exceeded."}
              total > @max_reductions -> {:error, "Evaluation reductions limit exceeded."}
              true -> watch(state)
            end
        end
    end
  end

  defp add_worker(state, child) do
    if Map.has_key?(state.workers, child) do
      state
    else
      monitor = Process.monitor(child)
      %{state | workers: Map.put(state.workers, child, monitor), spawned: state.spawned + 1}
    end
  end

  defp sample(state) do
    Enum.reduce(state.workers, {0, %{}, state.total_reductions}, fn {pid, _},
                                                                    {bytes, reds, total} ->
      case Process.info(pid, [:memory, :binary, :reductions]) do
        nil ->
          {bytes, reds, total}

        info ->
          count = Keyword.fetch!(info, :reductions)
          binary_bytes = Enum.reduce(info[:binary], 0, fn {_, size, _}, sum -> sum + size end)
          delta = max(count - Map.get(state.reductions, pid, 0), 0)
          {bytes + info[:memory] + binary_bytes, Map.put(reds, pid, count), total + delta}
      end
    end)
  end

  defp now, do: System.monotonic_time(:millisecond)
end
