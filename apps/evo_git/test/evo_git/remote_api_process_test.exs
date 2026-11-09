defmodule EvoGit.RemoteAPIProcessTest do
  @moduledoc """
  Tests for the managed-process RPC surface on
  `EvoGit.AgentScheduler.RemoteAPI`:

    * `list_processes/1`, `get_process/1`, `process_stats/1` and
      `process_control/3` — the `:erpc` targets the dashboard calls.

  `async: true` — nothing here mutates BEAM-global state: each test points the
  manager's own call-time seam (`:evogit_process_manager_server` in the CALLING
  process dictionary) at an isolated named `EvoGit.ProcessManager` instance,
  or at a name that does not exist for the degraded paths. The app-global
  manager is never touched.

  The live-process cases spawn a real `sleep` child and address it through a
  POSIX handle, so they are skipped on Windows (there is no Windows CI runner);
  the degraded and unknown-id cases are platform-neutral and still run there.
  """

  use ExUnit.Case, async: true

  # Only the live-process case needs a POSIX host; `skip: false` is a no-op for
  # ExUnit, so every other case runs everywhere.
  @posix_skip if EvoGit.Platform.windows?(),
                do: "POSIX process control is not exercised on Windows",
                else: false

  alias EvoGit.AgentScheduler.RemoteAPI
  alias EvoGit.ProcessManager
  alias EvoGit.ProcessManager.Execution
  alias EvoGit.ProcessManager.Handle

  # How long the spawned child lives — plenty for a pause/resume/kill cycle.
  @sleep_seconds 30

  defp uniq, do: System.unique_integer([:positive])

  # Starts an ISOLATED manager and points the calling process at it (the
  # manager's documented call-time seam), so the app-global instance is never
  # read or mutated by these tests.
  defp isolated_manager! do
    name = :"remote_api_process_manager_#{uniq()}"
    start_supervised!({ProcessManager, name: name})
    Process.put(:evogit_process_manager_server, name)
    name
  end

  # Points the manager seam at a name that is definitely not running, for the
  # degraded paths.
  defp absent_manager! do
    Process.put(:evogit_process_manager_server, :"remote_api_absent_manager_#{uniq()}")
  end

  # Spawns a real, long-lived child and returns its port plus OS pid.
  defp spawn_sleep! do
    port =
      Port.open({:spawn_executable, System.find_executable("sleep")}, [
        :binary,
        :exit_status,
        args: [Integer.to_string(@sleep_seconds)]
      ])

    {:os_pid, os_pid} = Port.info(port, :os_pid)
    {port, os_pid}
  end

  defp close_port(port) do
    if Port.info(port), do: Port.close(port)
    :ok
  end

  # `on_exit` runs in a DIFFERENT process, which does not own the port, so the
  # child is signalled directly (`-KILL` on an already-dead pid is a non-zero
  # exit, never a raise). The test process's own death closes the port.
  defp kill_child(os_pid) do
    System.cmd("kill", ["-KILL", Integer.to_string(os_pid)], stderr_to_stdout: true)
    :ok
  end

  describe "degraded manager" do
    test "every read and control degrades instead of raising" do
      absent_manager!()

      assert RemoteAPI.list_processes() == []
      assert RemoteAPI.get_process("proc-1") == {:error, :process_manager_unavailable}
      assert RemoteAPI.process_stats("proc-1") == {:error, :process_manager_unavailable}

      assert RemoteAPI.process_control("proc-1", :pause, "test") ==
               {:error, :process_manager_unavailable}

      assert RemoteAPI.process_control("proc-1", {:signal, :term}, "test") ==
               {:error, :process_manager_unavailable}
    end

    test "an unknown action is rejected BEFORE the manager is consulted" do
      # The manager is absent: if the action were forwarded first, the answer
      # would be :process_manager_unavailable instead of :unknown_action.
      absent_manager!()

      assert RemoteAPI.process_control("proc-1", :explode, "test") ==
               {:error, {:unknown_action, :explode}}

      assert RemoteAPI.process_control("proc-1", {:signal, :stop, :extra}, "test") ==
               {:error, {:unknown_action, {:signal, :stop, :extra}}}
    end
  end

  describe "running manager" do
    test "unknown ids are :not_found" do
      isolated_manager!()

      assert RemoteAPI.get_process("proc-999") == {:error, :not_found}
      assert RemoteAPI.process_stats("proc-999") == {:error, :not_found}
      assert RemoteAPI.process_control("proc-999", :pause, "test") == {:error, :not_found}
      assert RemoteAPI.process_control("proc-999", :kill, "test") == {:error, :not_found}
    end

    test "a tracked (but not yet attached) execution passes manager errors through" do
      isolated_manager!()

      {:ok, id} = ProcessManager.track(:tool_call, %{tool: "bash", command: "sleep 30"})
      assert {:ok, %Execution{status: :starting}} = RemoteAPI.get_process(id)
      # No OS handle yet: a probe has nothing to read and a signal nothing to hit.
      assert RemoteAPI.process_stats(id) == {:error, :not_running}
      assert RemoteAPI.process_control(id, :pause, "test") == {:error, :no_handle}
      # The handle check comes first, so an unusable signal is still :no_handle.
      assert RemoteAPI.process_control(id, {:signal, :nonsense}, "test") ==
               {:error, :no_handle}
    end

    @tag skip: @posix_skip
    test "list/get/stats/pause/resume read and mutate one tracked execution" do
      isolated_manager!()
      {port, os_pid} = spawn_sleep!()
      on_exit(fn -> kill_child(os_pid) end)

      {:ok, id} =
        ProcessManager.track(:tool_call, %{
          tool: "bash",
          command: "sleep #{@sleep_seconds}",
          agent_id: 42,
          task_id: "7"
        })

      :ok = ProcessManager.attach(id, Handle.posix(os_pid))

      # An unknown signal name is the backend's own error, passed through verbatim.
      assert RemoteAPI.process_control(id, {:signal, :nonsense}, "test") ==
               {:error, :invalid_signal}

      assert [%Execution{id: ^id, kind: :tool_call, status: :running}] =
               RemoteAPI.list_processes()

      assert [%Execution{id: ^id}] = RemoteAPI.list_processes(agent_id: 42)
      assert RemoteAPI.list_processes(agent_id: 43) == []

      assert {:ok, %Execution{id: ^id, status: :running} = execution} =
               RemoteAPI.get_process(id)

      assert execution.command == "sleep #{@sleep_seconds}"

      assert {:ok, stats} = RemoteAPI.process_stats(id)
      assert is_map(stats)

      assert :ok = RemoteAPI.process_control(id, :pause, "paused from the dashboard")

      assert {:ok, %Execution{status: :paused} = paused} = RemoteAPI.get_process(id)

      assert [
               %{
                 action: :pause,
                 signal: "STOP",
                 reason: "paused from the dashboard",
                 actor: :remote
               }
             ] = paused.control_log

      assert :ok = RemoteAPI.process_control(id, :resume, "resumed from the dashboard")
      assert {:ok, %Execution{status: :running}} = RemoteAPI.get_process(id)

      # Cleanup through the frozen kill action (TERM → grace → KILL).
      assert :ok = RemoteAPI.process_control(id, :kill, "test cleanup")
      assert {:ok, %Execution{status: :killed}} = RemoteAPI.get_process(id)
      close_port(port)
    end
  end
end
