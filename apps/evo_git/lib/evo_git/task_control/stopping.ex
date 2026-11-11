defmodule EvoGit.TaskControl.Stopping do
  @moduledoc "Bounded stop observation. A terminal row alone does not prove cleanup finished."
  @terminal ~w(completed failed cancelled)
  def await(id, seconds) do
    deadline = System.monotonic_time(:millisecond) + seconds * 1000
    observe(id, deadline)
  end

  defp observe(id, deadline) do
    with {:ok, data} <- EvoGit.TaskControl.get(%{"task_id" => id, "include_result" => false}) do
      agents = data.progress.registered_agent_count
      cleanup = pending_cleanup(id)
      jobs = EvoGit.BackgroundJobs.active_for_task(id)
      known = data.progress.scheduler_available and is_integer(cleanup) and is_integer(jobs)

      stopped =
        if known,
          do: data.status in @terminal and agents == 0 and cleanup == 0 and jobs == 0,
          else: nil

      data =
        Map.merge(data, %{
          stop_requested: true,
          stopped: stopped,
          remaining_agents: agents,
          pending_cleanup: cleanup,
          active_jobs: jobs,
          force_available: data.status in ~w(running cancelling finalizing)
        })

      if stopped == true or System.monotonic_time(:millisecond) >= deadline do
        {:ok, data}
      else
        Process.sleep(100)
        observe(id, deadline)
      end
    end
  end

  defp pending_cleanup(id) do
    EvoGit.AgentScheduler.WorktreeManager.pending_for_task(id)
  catch
    :exit, _ -> nil
  end
end
