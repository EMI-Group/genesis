defmodule EvoGit.BackgroundJobs.StatusProbe do
  @moduledoc """
  The OFF-PROCESS OS status probe for detached background jobs.

  A `:unit`-handled job's status is answered by `systemctl --user show`, which forks a subprocess (measured at ~12 ms on an idle host, far more on a loaded one).
  Running that inside the single GLOBAL job registry blocked every other agent's `job/2`, `read/2`, `list/1` and periodic reconcile for the duration, so every such probe now runs in its own unlinked task and reports back with a `{:probe_result, job_id, result}` message.
  The registry keeps a per-job CACHE of the last probed result, so a read answers immediately from the cache and never invents a status it has not observed.
  A `:port` handle is deliberately NOT offloaded: its probe is `Port.info/2`, a cheap in-VM BIF with no subprocess.
  """

  require Logger

  @doc """
  Runs the backend status probe for ONE handle, total: `{:running, nil}`, `{:exited, exit_code | nil}` or `{:unknown, nil}`.

  The probe function is resolved at CALL time from the app env `:background_status_probe_fun` (a test seam in the style of `:background_unit_stop_notify` / `:kill_grace_ms`); a non-function value falls back to `EvoGit.Sandbox.detached_status/1`, so production behaviour is unchanged.
  A raise or exit inside the backend is logged at debug and answered `{:unknown, nil}` — the caller's `{:unknown, _}` grace floor is what keeps that honest.
  """
  @spec run(map() | nil) :: {:running, nil} | {:exited, integer() | nil} | {:unknown, nil}
  def run(handle) do
    probe_fun().(handle)
  rescue
    exception ->
      Logger.debug(
        "BackgroundJobs: status check failed (#{Exception.message(exception)}); treating as running"
      )

      {:unknown, nil}
  catch
    kind, reason ->
      Logger.debug(
        "BackgroundJobs: status check failed (#{kind}: #{describe(reason)}); treating as running"
      )

      {:unknown, nil}
  end

  @doc """
  TRUE only for handle shapes whose status probe forks a subprocess — i.e. `%{kind: :unit}` (`systemctl --user show`).

  A `:port` handle's probe is `Port.info/2`, so it stays synchronous and unchanged.
  """
  @spec offprocess?(map() | nil) :: boolean()
  def offprocess?(%{kind: :unit}), do: true
  def offprocess?(_handle), do: false

  @doc """
  Starts ONE unlinked `Task.start/1` that probes `job`'s handle and sends `{:probe_result, job.id, result}` to `registry_pid`.

  Never linked to the registry and never awaited, so a slow or wedged probe costs nothing but a late cache refresh.
  """
  @spec start(pid(), map()) :: {:ok, pid()} | {:error, term()}
  def start(registry_pid, job) when is_pid(registry_pid) and is_map(job) do
    id = Map.get(job, :id)
    handle = Map.get(job, :handle)

    Task.start(fn -> send(registry_pid, {:probe_result, id, run(handle)}) end)
  rescue
    # Justified boundary: a probe that cannot be started must never take the shared registry down; the caller keeps the job's last known status and retries after the interval.
    exception -> {:error, {:probe_start_failed, Exception.message(exception)}}
  end

  defp probe_fun do
    case Application.get_env(:evo_git, :background_status_probe_fun) do
      fun when is_function(fun, 1) -> fun
      _other -> &EvoGit.Sandbox.detached_status/1
    end
  end

  defp describe(reason) when is_binary(reason), do: reason
  defp describe(reason) when is_atom(reason), do: Atom.to_string(reason)
  defp describe(reason), do: inspect(reason)
end
