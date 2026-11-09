defmodule EvoGit.ProcessManagerTest do
  # async-safe: every test starts its OWN named registry (never the app-global
  # `EvoGit.ProcessManager`), so no app-env seam is touched here. The
  # `"processes"` topic itself IS shared — the app-global manager (fed by
  # `EvoGit.BackgroundJobs` in other modules) publishes the same message shapes
  # — so every assertion, including the negative ones, is scoped to an
  # execution id THIS registry created (`"proc-404"` for the unknown-id cases).
  use ExUnit.Case, async: true

  alias EvoGit.ProcessManager
  alias EvoGit.ProcessManager.{Execution, Handle, Stats}

  setup do
    name = :"process_manager_#{System.unique_integer([:positive])}"
    start_supervised!({ProcessManager, name: name})
    :ok = ProcessManager.subscribe()
    flush()
    %{srv: [server: name]}
  end

  ## Recording

  test "track/get/list and monotonic proc-<n> ids", %{srv: srv} do
    {:ok, first} = ProcessManager.track(:tool_call, %{tool: "bash"}, srv)
    {:ok, second} = ProcessManager.track(:background_job, %{"tool" => "bash"}, srv)

    assert first == "proc-1"
    assert second == "proc-2"

    assert {:ok, %Execution{} = execution} = ProcessManager.get(second, srv)
    assert execution.id == second
    assert execution.kind == :background_job
    assert execution.tool == "bash"
    assert execution.status == :starting
    assert execution.runtime == :foreground
    assert execution.backend == :none
    assert execution.inserted_at != nil
    assert execution.stats == Stats.empty()

    assert ProcessManager.list(srv) |> Enum.map(& &1.id) == [second, first]
    assert ProcessManager.list([kind: :tool_call] ++ srv) |> Enum.map(& &1.id) == [first]
    assert ProcessManager.list([status: :starting] ++ srv) |> length() == 2
    assert ProcessManager.list([status: :completed] ++ srv) == []

    assert {:error, :not_found} = ProcessManager.get("proc-404", srv)
    assert ProcessManager.server() == EvoGit.ProcessManager
  end

  test "track honours the documented metadata and defaults", %{srv: srv} do
    {:ok, id} =
      ProcessManager.track(
        "tool_call",
        %{
          tool: "bash",
          command: "npm test",
          label: "unit tests",
          agent_id: "agent-7",
          task_id: 42,
          cwd: "/tmp",
          repo_root: "/repo",
          backend: :systemd,
          runtime: :detached,
          job_id: "job-1",
          unknown_key: :ignored
        },
        srv
      )

    assert {:ok, execution} = ProcessManager.get(id, srv)
    assert execution.kind == :tool_call
    assert execution.tool == "bash"
    assert execution.command == "npm test"
    assert execution.label == "unit tests"
    assert execution.agent_id == "agent-7"
    assert execution.task_id == 42
    assert execution.cwd == "/tmp"
    assert execution.repo_root == "/repo"
    assert execution.backend == :systemd
    assert execution.runtime == :detached
    assert execution.job_id == "job-1"
    assert execution.owner_pid == nil
  end

  ## Attach

  test "attach records the handle, transitions to :running and broadcasts once", %{srv: srv} do
    {:ok, id} = ProcessManager.track(:tool_call, %{tool: "bash"}, srv)
    flush()

    assert :ok = ProcessManager.attach(id, %Handle{kind: :posix, os_pid: 424_242}, srv)

    assert_receive {:process_started, %Execution{id: ^id, status: :running} = started, node}, 500
    assert node == node()
    assert started.os_pid == 424_242
    assert started.started_at != nil

    {:ok, execution} = ProcessManager.get(id, srv)
    assert execution.status == :running
    assert execution.os_pid == 424_242

    # A re-attach does not move started_at and does not broadcast again.
    assert :ok = ProcessManager.attach(id, %Handle{kind: :posix, os_pid: 424_242}, srv)
    refute_receive {:process_started, %Execution{id: ^id}, _}, 100
    assert {:ok, %Execution{started_at: started_at}} = ProcessManager.get(id, srv)
    assert started_at == started.started_at
  end

  test "attach normalizes a legacy sandbox handle map", %{srv: srv} do
    {:ok, id} = ProcessManager.track(:background_job, %{tool: "bash"}, srv)
    flush()

    assert :ok = ProcessManager.attach(id, %{kind: :unit, unit: "genesis-job-1.service"}, srv)
    assert_receive {:process_started, %Execution{unit: "genesis-job-1.service"}, _}, 500

    {:ok, second} = ProcessManager.track(:background_job, %{tool: "bash"}, srv)
    assert :ok = ProcessManager.attach(second, %{kind: :port, os_pid: 4242}, srv)
    assert {:ok, %Execution{os_pid: 4242}} = ProcessManager.get(second, srv)
  end

  test "attach on an unknown id is a total no-op", %{srv: srv} do
    assert :ok = ProcessManager.attach("proc-404", %Handle{kind: :posix, os_pid: 1}, srv)
    refute_receive {:process_started, %Execution{id: "proc-404"}, _}, 50
  end

  ## Finish

  test "finish is terminal, idempotent and broadcasts exactly once", %{srv: srv} do
    {:ok, id} = ProcessManager.track(:tool_call, %{tool: "bash"}, srv)
    :ok = ProcessManager.attach(id, %Handle{kind: :posix, os_pid: 424_242}, srv)
    flush()

    assert :ok = ProcessManager.finish(id, :completed, srv ++ [exit_code: 0, reason: :ok])
    assert_receive {:process_exited, %Execution{id: ^id, status: :completed}, node}, 500
    assert node == node()

    {:ok, execution} = ProcessManager.get(id, srv)
    assert execution.status == :completed
    assert execution.exit_code == 0
    assert execution.reason == :ok
    assert execution.ended_at != nil

    # A second terminal write and a NON-terminal status are both no-ops.
    assert :ok = ProcessManager.finish(id, :failed, srv)
    assert :ok = ProcessManager.finish(id, :starting, srv)
    refute_receive {:process_exited, %Execution{id: ^id}, _}, 100

    assert {:ok, %Execution{status: :completed}} = ProcessManager.get(id, srv)
  end

  test "finish on an unknown id is :ok and silent", %{srv: srv} do
    assert :ok = ProcessManager.finish("proc-404", :completed, srv)
    refute_receive {:process_exited, %Execution{id: "proc-404"}, _}, 50
  end

  ## Sampling without a live handle

  test "sample on a terminal or handle-less execution is an error, never a raise", %{srv: srv} do
    {:ok, id} = ProcessManager.track(:tool_call, %{tool: "bash"}, srv)
    assert {:error, :not_running} = ProcessManager.sample(id, srv)
    assert {:error, :not_found} = ProcessManager.sample("proc-404", srv)

    ProcessManager.finish(id, :completed, srv)
    assert {:error, :not_running} = ProcessManager.sample(id, srv)

    assert ProcessManager.sample_all(srv) == %{}
  end

  ## Owner lifetime

  test "an owner death kills and fails every execution it owned", %{srv: srv} do
    owner = spawn(fn -> receive do: (:stop -> :ok) end)
    {:ok, owned} = ProcessManager.track(:tool_call, %{tool: "bash", owner_pid: owner}, srv)
    {:ok, other} = ProcessManager.track(:tool_call, %{tool: "bash"}, srv)
    flush()

    reference = Process.monitor(owner)
    send(owner, :stop)

    assert_receive {:DOWN, ^reference, :process, ^owner, _}, 500
    assert_receive {:process_exited, %Execution{id: ^owned, status: :failed}, _}, 1_000

    assert {:ok, %Execution{status: :failed, reason: :owner_died, ended_at: ended_at}} =
             ProcessManager.get(owned, srv)

    assert ended_at != nil
    assert {:ok, %Execution{status: :starting}} = ProcessManager.get(other, srv)
  end

  ## POSIX round trip (Linux/macOS only)

  test "POSIX round trip: sample, pause, resume, kill", %{srv: srv} do
    if EvoGit.Platform.windows?() do
      :ok
    else
      {:ok, id} = ProcessManager.track(:tool_call, %{tool: "bash", command: "sleep 60"}, srv)
      port = open_sleep()
      {:os_pid, os_pid} = Port.info(port, :os_pid)

      try do
        flush()
        assert :ok = ProcessManager.attach(id, %Handle{kind: :posix, os_pid: os_pid}, srv)
        assert_receive {:process_started, _, _}, 500

        assert {:ok, stats} = ProcessManager.sample(id, srv)
        assert is_integer(stats.rss_bytes) and stats.rss_bytes > 0
        assert is_integer(stats.memory_bytes) and stats.memory_bytes >= stats.rss_bytes
        assert os_pid in stats.pids
        assert stats.sampled_at != nil
        assert {:ok, %Execution{stats: stored}} = ProcessManager.get(id, srv)
        assert stored.rss_bytes == stats.rss_bytes

        assert :ok = ProcessManager.pause(id, srv ++ [reason: :test_pause, actor: :suite])
        assert_receive {:process_control, ^id, %{action: :pause, signal: "STOP"}, _}, 500
        assert process_alive?(os_pid), "a paused process must still exist"
        assert {:ok, %Execution{status: :paused} = paused} = ProcessManager.get(id, srv)

        assert [
                 %{action: :pause, signal: "STOP", reason: :test_pause, actor: :suite}
               ] = paused.control_log

        assert :ok = ProcessManager.resume(id, srv)
        assert_receive {:process_control, ^id, %{action: :resume, signal: "CONT"}, _}, 500
        assert {:ok, %Execution{status: :running, control_log: log}} = ProcessManager.get(id, srv)
        assert length(log) == 2

        assert :ok = ProcessManager.kill(id, srv ++ [reason: :test_kill])

        assert {:ok, %Execution{status: :killed, reason: :test_kill}} =
                 ProcessManager.get(id, srv)

        refute process_alive?(os_pid), "a killed process must be gone"
      after
        close_port(port)
      end
    end
  end

  test "signal/pause/resume on an unknown or handle-less execution is an error", %{srv: srv} do
    {:ok, id} = ProcessManager.track(:tool_call, %{tool: "bash"}, srv)
    assert {:error, :not_found} = ProcessManager.signal("proc-404", :term, srv)
    assert {:error, :no_handle} = ProcessManager.pause(id, srv)

    ProcessManager.finish(id, :completed, srv)
    assert {:error, :terminal} = ProcessManager.resume(id, srv)
  end

  test "kill records :killed even without a handle", %{srv: srv} do
    {:ok, id} = ProcessManager.track(:background_job, %{tool: "bash"}, srv)
    flush()

    assert :ok = ProcessManager.kill(id, srv)
    assert_receive {:process_exited, %Execution{id: ^id, status: :killed}, _}, 500

    assert {:ok, %Execution{status: :killed, reason: :killed_by_operator}} =
             ProcessManager.get(id, srv)

    # Idempotent: a second kill of a terminal execution is :ok and silent.
    assert :ok = ProcessManager.kill(id, srv)
    refute_receive {:process_exited, %Execution{id: ^id}, _}, 100
    assert {:error, :not_found} = ProcessManager.kill("proc-404", srv)
  end

  ## Helpers

  defp open_sleep do
    Port.open({:spawn_executable, System.find_executable("sleep")}, [
      :binary,
      :exit_status,
      args: ["60"]
    ])
  end

  defp close_port(port) do
    if Port.info(port), do: Port.close(port), else: :ok
  catch
    :error, :badarg -> :ok
  end

  defp process_alive?(pid) do
    case System.cmd("kill", ["-0", Integer.to_string(pid)], stderr_to_stdout: true) do
      {_output, 0} -> true
      {_output, _code} -> false
    end
  end

  defp flush do
    receive do
      _message -> flush()
    after
      0 -> :ok
    end
  end
end

defmodule EvoGit.ProcessManagerSeamsTest do
  # sync: these tests mutate the SHARED app-env seams
  # (`:process_finished_retention_ms`, `:process_stats_enabled`,
  # `:process_manager_sample_interval_ms`) that a concurrently running module
  # could observe. Every seam is restored in `on_exit`.
  use ExUnit.Case, async: false

  alias EvoGit.ProcessManager
  alias EvoGit.ProcessManager.{Execution, Handle, Stats}

  setup do
    name = :"process_manager_seams_#{System.unique_integer([:positive])}"
    start_supervised!({ProcessManager, name: name})
    :ok = ProcessManager.subscribe()
    flush()
    on_exit(fn -> restore_seams() end)
    %{srv: [server: name]}
  end

  test "retention prunes terminal records older than the window, never live ones", %{srv: srv} do
    Application.put_env(:evo_git, :process_finished_retention_ms, 0)

    {:ok, finished} = ProcessManager.track(:tool_call, %{tool: "bash"}, srv)
    ProcessManager.finish(finished, :completed, srv)
    {:ok, live} = ProcessManager.track(:tool_call, %{tool: "bash"}, srv)

    assert {:ok, 0} = ProcessManager.prune(srv)
    assert {:error, :not_found} = ProcessManager.get(finished, srv)
    assert {:ok, %Execution{status: :starting}} = ProcessManager.get(live, srv)
  end

  test "the retention cap keeps only the newest 200 terminal records", %{srv: srv} do
    Application.put_env(:evo_git, :process_finished_retention_ms, 60_000)

    ids =
      for _ <- 1..205 do
        {:ok, id} = ProcessManager.track(:tool_call, %{tool: "bash"}, srv)
        ProcessManager.finish(id, :completed, srv)
        id
      end

    {:ok, live} = ProcessManager.track(:tool_call, %{tool: "bash"}, srv)

    retained = ProcessManager.list(srv)
    assert length(retained) == 201
    assert hd(retained).id == live
    assert List.last(retained).id == Enum.at(ids, 5)
    assert {:error, :not_found} = ProcessManager.get(Enum.at(ids, 0), srv)
    assert {:ok, _} = ProcessManager.get(Enum.at(ids, 5), srv)
  end

  test ":process_stats_enabled false skips every OS probe and sample broadcast", %{srv: srv} do
    Application.put_env(:evo_git, :process_stats_enabled, false)
    Application.put_env(:evo_git, :process_manager_sample_interval_ms, 50)

    {:ok, id} = ProcessManager.track(:tool_call, %{tool: "bash"}, srv)
    port = open_sleep()
    {:os_pid, os_pid} = Port.info(port, :os_pid)

    try do
      flush()
      :ok = ProcessManager.attach(id, %Handle{kind: :posix, os_pid: os_pid}, srv)
      Process.sleep(300)

      refute_received {:process_sample, _node, _seq, _entries}
      assert {:ok, %Execution{stats: stats}} = ProcessManager.get(id, srv)
      assert stats == Stats.empty()
    after
      if Port.info(port), do: Port.close(port)
    end
  end

  test "the sampling timer probes running executions and broadcasts monotonic samples", %{
    srv: srv
  } do
    Application.put_env(:evo_git, :process_manager_sample_interval_ms, 50)

    {:ok, id} = ProcessManager.track(:tool_call, %{tool: "bash"}, srv)
    port = open_sleep()
    {:os_pid, os_pid} = Port.info(port, :os_pid)

    try do
      flush()
      :ok = ProcessManager.attach(id, %Handle{kind: :posix, os_pid: os_pid}, srv)

      assert_receive {:process_sample, node, first_seq, entries}, 2_000
      assert node == node()
      assert is_integer(first_seq)
      assert Enum.any?(entries, &(&1.id == id and &1.status == :running))

      assert_receive {:process_sample, _node, second_seq, _entries}, 2_000
      assert second_seq > first_seq

      assert_receive {:process_updated, ^id, %{stats: %{rss_bytes: rss}}, _}, 2_000
      assert is_integer(rss) and rss > 0

      assert {:ok, %Execution{stats: %{rss_bytes: stored}}} = ProcessManager.get(id, srv)
      assert stored == rss
    after
      ProcessManager.kill(id, srv ++ [reason: :cleanup])
      if Port.info(port), do: Port.close(port)
    end
  end

  defp open_sleep do
    Port.open({:spawn_executable, System.find_executable("sleep")}, [
      :binary,
      :exit_status,
      args: ["60"]
    ])
  end

  defp restore_seams do
    Application.delete_env(:evo_git, :process_finished_retention_ms)
    Application.delete_env(:evo_git, :process_stats_enabled)
    Application.delete_env(:evo_git, :process_manager_sample_interval_ms)
  end

  defp flush do
    receive do
      _message -> flush()
    after
      0 -> :ok
    end
  end
end
