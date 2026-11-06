defmodule EvoGit.Agent.Tools.ElixirEval.Custodian do
  @moduledoc false
  # Independent trace ownership is essential: the unlinked guardian can die at
  # any instruction, including between spawning the root and broker attachment.
  # Trace the waiting guardian BEFORE acknowledging readiness, so its root and
  # every inherited descendant are already in our custody when they can execute.
  @cleanup_ms 1_000

  def cleanup_ms, do: @cleanup_ms

  def start(guardian, caller, token, deadline) do
    spawn_monitor(fn ->
      owners = %{Process.monitor(guardian) => guardian, Process.monitor(caller) => caller}

      # Trusted tracing boundary: a disappearing guardian or conflicting tracer
      # must fail closed without leaking runtime exception terms.
      try do
        1 = :erlang.trace(guardian, true, [:procs, :set_on_spawn, {:tracer, self()}])
        send(guardian, {token, :custodian, self()})

        watch(%{
          guardian: guardian,
          caller: caller,
          token: token,
          owners: owners,
          workers: %{},
          deadline: deadline
        })
      rescue
        _ -> Process.exit(guardian, :kill)
      catch
        _, _ -> Process.exit(guardian, :kill)
      after
        # Also reap known unlinked workers on an unexpected trusted-code failure;
        # killing only the guardian would not transfer ownership to its children.
        Enum.each(Process.get(:evogit_eval_custody_workers, %{}), fn {pid, _} ->
          Process.exit(pid, :kill)
        end)
      end
    end)
  end

  def finish(pid, token) do
    monitor = Process.monitor(pid)
    send(pid, {token, :cleanup, self()})

    result =
      receive do
        {^token, :cleaned, result} -> result
        {:DOWN, ^monitor, :process, ^pid, _} -> :error
      after
        @cleanup_ms + 100 -> :error
      end

    Process.demonitor(monitor, [:flush])
    result
  end

  defp watch(state) do
    Process.put(:evogit_eval_custody_workers, state.workers)

    if now() >= state.deadline do
      Process.exit(state.guardian, :kill)
      cleanup(state, nil)
    else
      receive do
        {:trace, _, :spawn, child, _} = event ->
          send(state.guardian, event)

          watch(%{
            state
            | workers: Map.put_new_lazy(state.workers, child, fn -> Process.monitor(child) end)
          })

        {:DOWN, ref, :process, _, _} when is_map_key(state.owners, ref) ->
          Process.exit(state.guardian, :kill)
          cleanup(state, nil)

        {:DOWN, _, :process, pid, _} ->
          watch(%{state | workers: Map.delete(state.workers, pid)})

        {token, :cleanup, requester}
        when token == state.token and requester in [state.guardian, state.caller] ->
          cleanup(state, requester)

        _ ->
          watch(state)
      after
        max(state.deadline - now(), 0) ->
          Process.exit(state.guardian, :kill)
          cleanup(state, nil)
      end
    end
  end

  defp cleanup(state, requester) do
    Enum.each(state.workers, fn {pid, _} -> Process.exit(pid, :kill) end)
    result = drain(state.workers, nil, now() + @cleanup_ms)
    if requester, do: send(requester, {state.token, :cleaned, result})
  end

  defp drain(workers, barrier, deadline) do
    Process.put(:evogit_eval_custody_workers, workers)

    if now() >= deadline do
      # Never report success with unconfirmed deaths/barrier delivery. A kill is
      # sent to EVERY known pid even on expiry, but a stuck native BIF may defer it.
      Enum.each(workers, fn {pid, _} -> Process.exit(pid, :kill) end)
      :error
    else
      barrier =
        if map_size(workers) == 0 and is_nil(barrier),
          do: :erlang.trace_delivered(:all),
          else: barrier

      receive do
        {:trace, _, :spawn, child, _} ->
          monitor = Map.get_lazy(workers, child, fn -> Process.monitor(child) end)
          Process.exit(child, :kill)
          drain(Map.put(workers, child, monitor), nil, deadline)

        {:DOWN, _, :process, pid, _} ->
          drain(Map.delete(workers, pid), barrier, deadline)

        {:trace_delivered, :all, ref} when ref == barrier ->
          if map_size(workers) == 0, do: :ok, else: drain(workers, nil, deadline)

        _ ->
          drain(workers, barrier, deadline)
      after
        max(deadline - now(), 0) ->
          Enum.each(workers, fn {pid, _} -> Process.exit(pid, :kill) end)
          :error
      end
    end
  end

  defp now, do: System.monotonic_time(:millisecond)
end
