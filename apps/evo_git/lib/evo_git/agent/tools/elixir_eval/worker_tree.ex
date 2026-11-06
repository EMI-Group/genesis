defmodule EvoGit.Agent.Tools.ElixirEval.WorkerTree do
  @moduledoc """
  An unlinked, monitored guardian for one evaluation and all of its BEAM descendants.

  Spawn tracing is enabled BEFORE execution and inherited across Dune's Task/proc_lib
  children (including its unlinked reductions checker). Cleanup kills descendants,
  drains spawn events and waits for a trace-delivery barrier before replying.
  The guardian monitors both the tool caller and optional context owner_pid/agent_pid.

  Reduction/memory limits are sampled every 5 ms, not OS resource isolation: a native
  BIF can transiently overshoot a sample, and an approved sudo program has full VM
  authority, including the ability to interfere with this guardian or tracing.
  """
  alias EvoGit.Agent.Tools.ElixirEval.{Broker, Render}
  @max_heap_words 2_000_000
  @max_tree_bytes 64 * 1_024 * 1_024
  @max_reductions 20_000_000
  @max_processes 64
  @sample_ms 5

  def run(context, tier, limits, fun) do
    caller = self()
    ref = make_ref()

    {pid, monitor} =
      spawn_monitor(fn -> guard(caller, ref, context, tier, limits, fun) end)

    receive do
      {^ref, result} ->
        Process.demonitor(monitor, [:flush])
        result

      {:DOWN, ^monitor, :process, ^pid, _} ->
        {:error, "Evaluation guardian failed."}
    end
  end

  defp guard(caller, ref, context, tier, limits, fun) do
    owners =
      [caller, Map.get(context, :owner_pid), Map.get(context, :agent_pid)]
      |> Enum.filter(&is_pid/1)
      |> Enum.uniq()
      |> Map.new(&{Process.monitor(&1), &1})

    # This is the central boundary for trusted broker lifecycle failures: never
    # inspect an exception, exit reason, context or stacktrace into a tool reply.
    result =
      try do
        case Broker.start(context, tier) do
          {:ok, broker} ->
            try do
              execute(broker, owners, limits, fun)
            after
              Broker.stop(broker)
            end

          _ ->
            {:error, "Evaluation broker unavailable."}
        end
      rescue
        _ -> {:error, "Evaluation infrastructure failed."}
      catch
        _, _ -> {:error, "Evaluation infrastructure failed."}
      end

    send(caller, {ref, result})
  end

  defp execute(broker, owners, limits, fun) do
    guardian = self()
    token = make_ref()
    broker_ref = Process.monitor(broker)

    {worker, monitor} =
      :erlang.spawn_opt(
        fn ->
          receive do
            {:execute, ^token} ->
              Process.put(:evogit_eval_broker, broker)
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
        :erlang.trace(worker, true, [:procs, :set_on_spawn, {:tracer, self()}])

        case Broker.attach(broker, worker) do
          :ok ->
            send(worker, {:execute, token})
            watch(state)

          {:ok, _} ->
            send(worker, {:execute, token})
            watch(state)

          _ ->
            {:error, "Evaluation worker authorization failed."}
        end
      after
        cleanup(state.workers)
        Process.demonitor(broker_ref, [:flush])
      end

    output = Render.text(Broker.output(broker), limits.max_output_bytes)

    case result do
      {:ok, text} -> {:ok, Render.text(output <> text, limits.max_output_bytes)}
      {:error, text} -> {:error, Render.text(output <> text, limits.max_output_bytes)}
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
      known = Process.get(:evogit_eval_descendants, %{})
      Process.put(:evogit_eval_descendants, Map.put(known, child, monitor))
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

  defp cleanup(workers) do
    Enum.each(workers, fn {pid, _} -> Process.exit(pid, :kill) end)
    # The initial map only contains the root. Re-discover EVERY descendant via
    # inherited trace messages, even if watch/1 consumed its spawn notification.
    # Tracees are retained separately in the guardian's dictionary for this purpose.
    known = Process.delete(:evogit_eval_descendants) || %{}

    workers =
      Map.merge(workers, known)
      |> Map.new(fn {pid, old_monitor} ->
        Process.demonitor(old_monitor, [:flush])
        {pid, Process.monitor(pid)}
      end)

    Enum.each(workers, fn {pid, _} -> Process.exit(pid, :kill) end)
    drain(workers, nil)
  end

  defp drain(workers, barrier) do
    barrier =
      if map_size(workers) == 0 and is_nil(barrier),
        do: :erlang.trace_delivered(:all),
        else: barrier

    receive do
      {:trace, _, :spawn, child, _} ->
        monitor = Process.monitor(child)
        Process.exit(child, :kill)
        drain(Map.put(workers, child, monitor), nil)

      {:DOWN, _, :process, pid, _} ->
        drain(Map.delete(workers, pid), barrier)

      {:trace_delivered, :all, ref} when ref == barrier ->
        if map_size(workers) == 0, do: :ok, else: drain(workers, nil)

      _ ->
        drain(workers, barrier)
    end
  end

  defp now, do: System.monotonic_time(:millisecond)
end
