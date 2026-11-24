defmodule EvoGit.ProcessManagerTest do
  # async-safe: every test starts its OWN named registry (never the app-global
  # `EvoGit.ProcessManager`), so no app-env seam is touched here. The one
  # production timer a test needs to shrink (the TERM→KILL grace) has a
  # PER-PROCESS form (`:process_kill_grace_ms` in the calling process
  # dictionary), so it stays async-safe too.
  # `"processes"` topic itself IS shared — the app-global manager (fed by
  # `EvoGit.BackgroundJobs` in other modules) AND any other module's isolated
  # registry publish the same message shapes.
  # Execution ids are PER-REGISTRY counters (`proc-1`, `proc-2`, …), so the
  # shared topic can legitimately carry a `%Execution{id: "proc-1"}` minted by a
  # CONCURRENTLY running registry — an id-only negative assertion would be
  # falsified by that foreign execution, never by this registry's own.
  # Every id-scoped NEGATIVE assertion therefore ALSO pins a per-execution unique
  # value, the execution's `inserted_at` (a microsecond `DateTime`, unique per
  # execution), so it can only ever match an execution this registry created.
  # `"proc-404"` is the unknown-id case — an id this registry never mints, so
  # there is nothing to pin — and `:process_control` refutes stay id-only.
  use ExUnit.Case, async: true

  alias EvoGit.ProcessManager
  alias EvoGit.ProcessManager.{Execution, Handle, Registry, Stats}

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
          runtime: :background,
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
    assert execution.runtime == :background
    assert execution.job_id == "job-1"
    assert execution.owner_pid == nil
    # Terminal facts stay UNSET while the execution never started an OS process.
    assert execution.exit_code == nil
    assert execution.reason == nil
  end

  test "the runtime is normalized to :foreground | :background", %{srv: srv} do
    {:ok, background} =
      ProcessManager.track(:tool_call, %{tool: "bash", runtime: :background}, srv)

    {:ok, from_string} =
      ProcessManager.track(:tool_call, %{tool: "bash", runtime: "background"}, srv)

    {:ok, unknown} =
      ProcessManager.track(:tool_call, %{tool: "bash", runtime: :never_heard_of}, srv)

    assert {:ok, %Execution{runtime: :foreground}} = ProcessManager.get(unknown, srv)
    assert {:ok, %Execution{runtime: :background}} = ProcessManager.get(background, srv)
    assert {:ok, %Execution{runtime: :background}} = ProcessManager.get(from_string, srv)
  end

  ## Builtin (in-BEAM) executions
  test "a builtin execution has no OS process and refuses every control call", %{srv: srv} do
    {:ok, id} = ProcessManager.track(:tool_call, %{tool: "read", backend: :builtin}, srv)
    server = Keyword.fetch!(srv, :server)
    assert {:ok, %Execution{backend: :builtin} = builtin} = ProcessManager.get(id, srv)
    assert Execution.builtin?(builtin)
    refute Execution.external?(builtin)
    # Nothing to sample: a builtin record is live but NOT sampleable.
    refute Execution.sampleable?(builtin)
    assert builtin.stats == Stats.empty()
    assert builtin.os_pid == nil
    assert builtin.unit == nil
    flush()
    # A (defensive) real handle never downgrades the backend: the call still ran
    # inside the BEAM, so it has no OS process to control.
    assert :ok =
             ProcessManager.attach(
               id,
               %Handle{kind: :posix, os_pid: 424_242, backend: EvoGit.Sandbox.Linux},
               srv
             )

    assert {:ok, %Execution{backend: :builtin} = attached} = ProcessManager.get(id, srv)
    assert Execution.builtin?(attached)
    refute Execution.external?(attached)
    refute Execution.sampleable?(attached)
    assert {:error, :no_os_process} = ProcessManager.sample(id, srv)
    assert {:error, :no_os_process} = ProcessManager.signal(id, :term, srv)
    assert {:error, :no_os_process} = ProcessManager.pause(id, srv)
    assert {:error, :no_os_process} = ProcessManager.resume(id, srv)

    assert {:error, :no_os_process} =
             ProcessManager.kill(id, srv ++ [reason: :operator_kill, actor: :operator])

    # `kill` leaves the record untouched — it is still observably live.
    assert {:ok, %Execution{status: :running, reason: nil, ended_at: nil}} =
             ProcessManager.get(id, srv)

    # Sampling skips builtin records entirely.
    assert ProcessManager.sample_all(srv) == %{}
    assert Enum.any?(ProcessManager.list(srv), &(&1.id == id))
    refute Enum.any?(EvoGit.ProcessManager.Registry.live(server), &(&1.id == id))
    refute_received {:process_sample, _node, _seq, _entries}
    refute_received {:process_control, ^id, _control, _node}
  end

  test "finish stores the terminal facts and later terminal writes are no-ops", %{srv: srv} do
    {:ok, id} = ProcessManager.track(:tool_call, %{tool: "bash"}, srv)
    :ok = ProcessManager.attach(id, %Handle{kind: :posix, os_pid: 424_242}, srv)
    flush()
    assert :ok = ProcessManager.finish(id, :completed, srv ++ [exit_code: 7, reason: :exited])
    assert_receive {:process_exited, %Execution{id: ^id, status: :completed}, _}, 500

    assert {:ok,
            %Execution{
              status: :completed,
              exit_code: 7,
              reason: :exited,
              inserted_at: inserted_at
            } = finished} = ProcessManager.get(id, srv)

    refute Execution.sampleable?(finished)
    # The FIRST terminal write wins: a later settle cannot rewrite the facts.
    assert :ok = ProcessManager.finish(id, :failed, srv ++ [reason: :timeout])
    assert :ok = ProcessManager.finish(id, :killed, srv ++ [reason: {:killed_by, :operator}])

    assert {:ok, %Execution{status: :completed, exit_code: 7, reason: :exited}} =
             ProcessManager.get(id, srv)

    refute_receive {:process_exited, %Execution{id: ^id, inserted_at: ^inserted_at}, _}, 100
  end

  ## Attach

  test "attach records the handle, transitions to :running and broadcasts once", %{srv: srv} do
    {:ok, id} = ProcessManager.track(:tool_call, %{tool: "bash"}, srv)
    flush()

    assert :ok = ProcessManager.attach(id, %Handle{kind: :posix, os_pid: 424_242}, srv)

    assert_receive {:process_started,
                    %Execution{id: ^id, status: :running, inserted_at: inserted_at} = started,
                    node},
                   500

    assert node == node()
    assert started.os_pid == 424_242
    assert started.started_at != nil

    {:ok, execution} = ProcessManager.get(id, srv)
    assert execution.status == :running
    assert execution.os_pid == 424_242

    # A re-attach does not move started_at and does not broadcast again.
    assert :ok = ProcessManager.attach(id, %Handle{kind: :posix, os_pid: 424_242}, srv)
    refute_receive {:process_started, %Execution{id: ^id, inserted_at: ^inserted_at}, _}, 100
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

    assert :ok = ProcessManager.finish(id, :completed, srv ++ [exit_code: 0, reason: :exited])
    assert_receive {:process_exited, %Execution{id: ^id, status: :completed}, node}, 500
    assert node == node()

    assert {:ok, %Execution{inserted_at: inserted_at} = execution} =
             ProcessManager.get(id, srv)

    assert execution.status == :completed
    assert execution.exit_code == 0
    assert execution.reason == :exited
    assert execution.ended_at != nil

    # A second terminal write and a NON-terminal status are both no-ops.
    assert :ok = ProcessManager.finish(id, :failed, srv)
    assert :ok = ProcessManager.finish(id, :starting, srv)
    refute_receive {:process_exited, %Execution{id: ^id, inserted_at: ^inserted_at}, _}, 100

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
    # Per-PROCESS shrink of the TERM→KILL grace (the control layer's own seam,
    # `EvoGit.ProcessManager.Control.kill_grace_ms/0`): the kill does its OS work
    # in THIS calling process, so the production 1 500 ms flush window would
    # dominate the round trip. Nothing BEAM-global is touched (the entry dies
    # with the test process) and the escalation itself is unchanged.
    Process.put(:process_kill_grace_ms, 0)

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

        assert {:ok, %Execution{status: :killed, reason: {:killed_by, :operator}}} =
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

    assert {:ok,
            %Execution{
              status: :killed,
              reason: {:killed_by, :operator},
              inserted_at: inserted_at
            }} = ProcessManager.get(id, srv)

    # Idempotent: a second kill of a terminal execution is :ok and silent.
    assert :ok = ProcessManager.kill(id, srv)
    refute_receive {:process_exited, %Execution{id: ^id, inserted_at: ^inserted_at}, _}, 100
    assert {:error, :not_found} = ProcessManager.kill("proc-404", srv)
  end

  test "a FAILED kill leaves the record live and logs the failure", %{srv: srv} do
    {:ok, id} =
      ProcessManager.track(
        :tool_call,
        %{tool: "bash", command: "kill-no-pid-marker"},
        srv
      )

    # A posix handle without any pid/pgid makes the backend answer `:no_pid`
    # BEFORE it attempts any OS call — a fast, host-safe failing kill.
    :ok = ProcessManager.attach(id, %Handle{kind: :posix}, srv)
    flush()

    assert {:ok, %Execution{inserted_at: inserted_at}} = ProcessManager.get(id, srv)

    assert {:error, :no_pid} =
             ProcessManager.kill(id, srv ++ [reason: :operator_kill, actor: :operator])

    assert_receive {:process_control, ^id,
                    %{
                      action: :kill,
                      signal: nil,
                      reason: {:kill_failed, :no_pid},
                      actor: :operator
                    }, _},
                   500

    # No terminal transition was broadcast, and the record is untouched.
    refute_receive {:process_exited,
                    %Execution{id: ^id, command: "kill-no-pid-marker", inserted_at: ^inserted_at},
                    _},
                   200

    assert {:ok, %Execution{status: :running, reason: nil, ended_at: nil, control_log: log}} =
             ProcessManager.get(id, srv)

    assert [
             %{action: :kill, signal: nil, reason: {:kill_failed, :no_pid}, actor: :operator}
           ] = log

    # Still observable and controllable: never aged out of the roster.
    assert Enum.any?(ProcessManager.list(srv), &(&1.id == id))
  end

  test "a SUCCEEDING kill records :killed and keeps the human reason in control_log",
       %{srv: srv} do
    {:ok, id} =
      ProcessManager.track(
        :background_job,
        %{tool: "bash", command: "kill-ok-marker"},
        srv
      )

    flush()

    assert :ok = ProcessManager.kill(id, srv ++ [reason: :operator_killed, actor: :operator])

    assert_receive {:process_exited,
                    %Execution{id: ^id, status: :killed, command: "kill-ok-marker"}, _},
                   500

    assert {:ok, execution} = ProcessManager.get(id, srv)
    # The TERMINAL FACT carries the actor identity, never free text; the
    # human-supplied reason is audit data and lives only in `control_log`.
    assert %Execution{status: :killed, reason: {:killed_by, :operator}} = execution
    assert [entry] = execution.control_log
    assert entry.action == :kill
    assert entry.reason == :operator_killed
    assert entry.actor == :operator
    assert execution.ended_at != nil
    refute_receive {:process_control, ^id, %{reason: {:kill_failed, _}}, _}, 100
  end

  test "failed pause/resume/signal never change status or record an entry", %{srv: srv} do
    {:ok, id} =
      ProcessManager.track(:tool_call, %{tool: "bash", command: "control-no-pid-marker"}, srv)

    :ok = ProcessManager.attach(id, %Handle{kind: :posix}, srv)
    flush()

    assert {:error, :no_pid} =
             ProcessManager.pause(id, srv ++ [reason: :denied_pause, actor: :denied_suite])

    assert {:error, :no_pid} =
             ProcessManager.resume(id, srv ++ [reason: :denied_resume, actor: :denied_suite])

    assert {:error, :no_pid} =
             ProcessManager.signal(
               id,
               :term,
               srv ++ [reason: :denied_signal, actor: :denied_suite]
             )

    refute_receive {:process_control, ^id, %{reason: :denied_pause}, _}, 75
    refute_receive {:process_control, ^id, %{reason: :denied_resume}, _}, 75
    refute_receive {:process_control, ^id, %{reason: :denied_signal}, _}, 75

    assert {:ok, %Execution{status: :running, reason: nil, ended_at: nil, control_log: []}} =
             ProcessManager.get(id, srv)
  end

  ## Retention bounds + totality

  test "a burst of terminal records keeps only the newest 200 and never drops live ones", %{
    srv: srv
  } do
    ids =
      for index <- 1..210 do
        {:ok, id} = ProcessManager.track(:tool_call, %{tool: "bash"}, srv)

        # Give the OLDEST record (the first to be pruned) a real OS handle while
        # it is still live — `attach` on a terminal record is a documented no-op.
        if index == 1 do
          :ok =
            ProcessManager.attach(
              id,
              %Handle{kind: :unit, unit: "genesis-retention-1.service"},
              srv
            )
        end

        ProcessManager.finish(id, :completed, srv)
        id
      end

    oldest = Enum.at(ids, 0)

    {:ok, live_one} = ProcessManager.track(:tool_call, %{tool: "bash"}, srv)
    {:ok, live_two} = ProcessManager.track(:tool_call, %{tool: "bash"}, srv)

    :ok =
      ProcessManager.attach(
        live_two,
        %Handle{kind: :unit, unit: "genesis-retention-2.service"},
        srv
      )

    retained = ProcessManager.list(srv)
    retained_ids = Enum.map(retained, & &1.id)

    # The payload is BOUNDED: live records + the terminal cap, nothing else.
    assert length(retained) == 202
    assert length(retained) <= 2 + 200

    assert live_one in retained_ids
    assert live_two in retained_ids

    # The 10 oldest terminal records fell out; the newest 200 stay.
    for id <- Enum.take(ids, 10) do
      assert {:error, :not_found} = ProcessManager.get(id, srv)
      refute id in retained_ids
    end

    for id <- Enum.drop(ids, 10) do
      assert {:ok, %Execution{status: :completed}} = ProcessManager.get(id, srv)
    end

    handles = :sys.get_state(Keyword.fetch!(srv, :server)).handles
    refute Map.has_key?(handles, oldest)
    assert Map.has_key?(handles, live_two)
  end

  test "every direct API answers a degraded value when the registry is absent" do
    Process.put(:evogit_process_manager_server, :process_manager_absent_for_test)

    try do
      assert ProcessManager.list() == []
      assert {:error, :not_found} = ProcessManager.get("proc-1")
      assert {:error, :not_found} = ProcessManager.sample("proc-1")
      assert ProcessManager.sample_all() == %{}
      assert {:error, :not_found} = ProcessManager.signal("proc-1", :term)
      assert {:error, :not_found} = ProcessManager.pause("proc-1")
      assert {:error, :not_found} = ProcessManager.resume("proc-1")
      assert {:error, :not_found} = ProcessManager.kill("proc-1")
      assert {:ok, 0} = ProcessManager.prune()
    after
      Process.delete(:evogit_process_manager_server)
    end
  end

  test "an owner monitor is dropped once all of its records are pruned and re-installed on the next track",
       %{srv: srv} do
    server = Keyword.fetch!(srv, :server)
    owner = spawn(fn -> receive do: (:stop -> :ok) end)

    {:ok, owned} = ProcessManager.track(:tool_call, %{tool: "bash", owner_pid: owner}, srv)
    ProcessManager.finish(owned, :completed, srv)

    # The owned record is the oldest terminal record: enough later terminal
    # records push it out of the cap, and its owner then holds no record.
    for _ <- 1..200 do
      {:ok, id} = ProcessManager.track(:tool_call, %{tool: "bash"}, srv)
      ProcessManager.finish(id, :completed, srv)
    end

    assert :sys.get_state(server).owner_refs == %{}

    # Re-tracking for the SAME owner re-installs the monitor, so its death still
    # fails the execution.
    {:ok, again} = ProcessManager.track(:tool_call, %{tool: "bash", owner_pid: owner}, srv)
    assert map_size(:sys.get_state(server).owner_refs) == 1

    Process.exit(owner, :kill)

    assert_receive {:process_exited, %Execution{id: ^again, status: :failed}, _}, 1_000

    assert {:ok, %Execution{status: :failed, reason: :owner_died}} =
             ProcessManager.get(again, srv)
  end

  ## Registry boundary (unavailable vs wedged vs unknown call)

  test "a non-map stats answer is dropped instead of crashing the caller", %{srv: srv} do
    server = Keyword.fetch!(srv, :server)
    {:ok, id} = ProcessManager.track(:tool_call, %{tool: "bash"}, srv)

    # A probe answer the caller could not parse must never raise here.
    assert :ok = Registry.record_stats(server, id, nil)
    assert :ok = Registry.record_stats(server, id, {:error, :malformed})
    assert :ok = Registry.record_stats(server, id, "not a map")
    assert :ok = Registry.record_stats(server, "proc-404", %{rss_bytes: 1})

    # Nothing was stored, and the registry is still alive and answering.
    assert {:ok, %Execution{stats: stats}} = ProcessManager.get(id, srv)
    assert stats == Stats.empty()
  end

  test "an unavailable (never started / stopped) registry keeps every documented fallback" do
    dead = :"process_manager_gone_#{System.unique_integer([:positive])}"

    assert Registry.track(dead, :tool_call, %{}) == {:error, :process_manager_unavailable}
    assert Registry.attach(dead, "proc-1", nil) == :ok
    assert Registry.finish(dead, "proc-1", :completed) == :ok
    assert Registry.get(dead, "proc-1") == {:error, :not_found}
    assert Registry.lookup(dead, "proc-1") == {:error, :not_found}
    assert Registry.list(dead, []) == []
    assert Registry.live(dead) == []
    assert Registry.prune(dead) == {:ok, 0}
    assert Registry.put_kill_intent(dead, "proc-1", :operator) == :ok
    assert Registry.clear_kill_intent(dead, "proc-1") == :ok
    assert Registry.record_stats(dead, "proc-1", %{rss_bytes: 1}) == :ok
  end

  test "a wedged registry is a timeout, while a dead one stays the caller's fallback" do
    # The branch decision behind the call helper, unit-tested instead of waiting
    # out a real 5 s call.
    call = {GenServer, :call, [EvoGit.ProcessManager, :live, 5_000]}

    assert Registry.classify_exit({:timeout, call}) == {:error, :timeout}
    assert Registry.classify_exit({:noproc, call}) == :unavailable
    assert Registry.classify_exit({:normal, call}) == :unavailable
    assert Registry.classify_exit({:shutdown, call}) == :unavailable
    assert Registry.classify_exit({{:shutdown, :bye}, call}) == :unavailable
    assert Registry.classify_exit({:killed, call}) == :unavailable
    assert Registry.classify_exit(:noproc) == :unavailable

    # A registry that CRASHED while answering is never "unavailable": the reason
    # survives for the caller instead of being folded into "not found".
    crash = {{%RuntimeError{message: "boom"}, []}, call}
    assert Registry.classify_exit(crash) == {:error, {:registry_exit, crash}}
  end

  @tag capture_log: true
  test "a registry that crashes while answering is reported as an exit, not as not_found" do
    # ONE crashing server per assertion: the crashed one is restarted by its
    # supervisor, so a second call could race that restart (`:noproc`).
    direct = :"process_manager_crashing_#{System.unique_integer([:positive])}"
    through_facade = :"process_manager_crashing_#{System.unique_integer([:positive])}"

    for name <- [direct, through_facade] do
      start_supervised!(%{id: name, start: {__MODULE__.CrashingRegistry, :start_link, [name]}})
    end

    assert {:error, {:registry_exit, _reason}} = Registry.get(direct, "proc-1")
    # The facade forwards it instead of degrading to `:not_found`.
    assert {:error, {:registry_exit, _reason}} =
             ProcessManager.get("proc-1", server: through_facade)
  end

  test "a mistyped call on a live registry answers an explicit unknown-call error", %{srv: srv} do
    server = Keyword.fetch!(srv, :server)

    assert GenServer.call(server, :bogus) == {:error, {:unknown_call, :bogus}}

    assert GenServer.call(server, {:bogus, "proc-1"}) ==
             {:error, {:unknown_call, {:bogus, "proc-1"}}}
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

defmodule EvoGit.ProcessManagerTest.CrashingRegistry do
  # A registry stand-in whose EVERY request crashes: the caller's `GenServer.call`
  # exits with the crash reason, which is exactly the `{:registry_exit, reason}`
  # branch `EvoGit.ProcessManager.Registry` must report instead of "not found".
  use GenServer

  @spec start_link(atom()) :: GenServer.on_start()
  def start_link(name), do: GenServer.start_link(__MODULE__, nil, name: name)

  @impl true
  def init(_state), do: {:ok, nil}

  @impl true
  def handle_call(request, _from, _state), do: raise("crashing registry: #{inspect(request)}")
end

defmodule EvoGit.ProcessManagerSeamsTest do
  # sync: these tests mutate the SHARED app-env seams
  # (`:process_finished_retention_ms`, `:process_finished_max_records`,
  # `:process_background_max_per_owner`, `:process_stats_enabled`,
  # `:process_manager_sample_interval_ms`, `:process_kill_grace_ms`) that a
  # concurrently running module could observe.
  # Every seam is restored in `on_exit`.
  use ExUnit.Case, async: false

  alias EvoGit.ProcessManager
  alias EvoGit.ProcessManager.{Execution, Handle, Stats}

  setup do
    name = :"process_manager_seams_#{System.unique_integer([:positive])}"

    # Test-only CALL-TIME seam (`EvoGit.ProcessManager.Control.kill_grace_ms/0`):
    # every test here kills a real POSIX child, and a production 1500 ms
    # TERM→KILL flush window would cost more than the behaviour under test. The
    # escalation itself is unchanged (TERM, grace, KILL, post-KILL verdict).
    previous_grace_ms = Application.get_env(:evo_git, :process_kill_grace_ms)
    Application.put_env(:evo_git, :process_kill_grace_ms, 0)

    start_supervised!({ProcessManager, name: name})
    :ok = ProcessManager.subscribe()
    flush()

    on_exit(fn ->
      restore_seams()
      restore_seam(:process_kill_grace_ms, previous_grace_ms)
    end)

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

  test ":process_finished_max_records caps retained terminal records", %{srv: srv} do
    Application.put_env(:evo_git, :process_finished_max_records, 5)

    ids =
      for _ <- 1..8 do
        {:ok, id} = ProcessManager.track(:tool_call, %{tool: "bash"}, srv)
        ProcessManager.finish(id, :completed, srv)
        id
      end

    {:ok, live} = ProcessManager.track(:tool_call, %{tool: "bash"}, srv)

    retained_ids = ProcessManager.list(srv) |> Enum.map(& &1.id)

    assert length(retained_ids) == 6
    assert live in retained_ids

    for id <- Enum.drop(ids, 3) do
      assert {:ok, %Execution{status: :completed}} = ProcessManager.get(id, srv)
    end

    for id <- Enum.take(ids, 3) do
      assert {:error, :not_found} = ProcessManager.get(id, srv)
    end
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

  ## Owner-aware retention
  #
  # A terminal `:background_job` whose `owner_pid` is STILL ALIVE is PROTECTED:
  # neither the age window nor the GLOBAL `:process_finished_max_records` cap
  # touches it, and it is bounded per owner instead (newest
  # `:process_background_max_per_owner` of THAT owner survive, oldest of that
  # owner first dropped). Every other terminal record — EVERY `:tool_call`, and a
  # dead/nil owner's background job — keeps the historical age window plus the
  # global cap. The policy lives in `EvoGit.ProcessManager.Retention.doomed_ids/2`;
  # these tests pin it through the registry's public surface alone.
  #
  # Retention ALSO runs on every `finish/3` and on every sampling tick, and those
  # passes discard their count — so each test asserts STATE (`get/2`, `list/1`),
  # and a test whose subject IS the returned count creates its records while the
  # bounds still permit retention and shrinks them only immediately before ONE
  # explicit `prune/1`. The sampling seam is pinned to an hour wherever records
  # are counted, so no tick can consume them mid-test.
  describe "owner-aware retention" do
    test "a live owner's terminal background job survives the age window while its tool calls age out",
         %{srv: srv} do
      pin_counting_seams()
      Application.put_env(:evo_git, :process_finished_retention_ms, 300_000)

      job = finished_background_job(srv, self())
      tool = finished_tool_call(srv, self())
      {:ok, live_tool} = ProcessManager.track(:tool_call, %{tool: "bash", owner_pid: self()}, srv)

      Application.put_env(:evo_git, :process_finished_retention_ms, 0)

      # Exactly ONE record ages out: the tool call. The protected background job
      # is exempt from the age window and the live record is never terminal.
      assert {:ok, 1} = ProcessManager.prune(srv)

      assert {:ok, %Execution{status: :completed, kind: :background_job}} =
               ProcessManager.get(job, srv)

      assert {:error, :not_found} = ProcessManager.get(tool, srv)
      assert {:ok, %Execution{status: :starting}} = ProcessManager.get(live_tool, srv)
    end

    test ":process_background_max_per_owner keeps the newest N of ONE live owner and leaves another owner alone",
         %{srv: srv} do
      pin_counting_seams()
      Application.put_env(:evo_git, :process_finished_retention_ms, 300_000)
      Application.put_env(:evo_git, :process_background_max_per_owner, 2)

      owner_b = start_owner()
      on_exit(fn -> Process.exit(owner_b, :kill) end)

      jobs_a = Enum.map(1..4, fn _ -> finished_background_job(srv, self()) end)
      jobs_b = Enum.map(1..3, fn _ -> finished_background_job(srv, owner_b) end)

      [a_oldest, a_older, a_newer, a_newest] = jobs_a
      [b_oldest, b_older, b_newest] = jobs_b

      # Owner A's own overflow is trimmed oldest-first; the newest 2 survive even
      # though they are identical in age terms to the ones dropped.
      assert {:error, :not_found} = ProcessManager.get(a_oldest, srv)
      assert {:error, :not_found} = ProcessManager.get(a_older, srv)

      for id <- [a_newer, a_newest] do
        assert {:ok, %Execution{status: :completed, kind: :background_job}} =
                 ProcessManager.get(id, srv)
      end

      # The per-owner cap is applied PER OWNER, so owner B's roster is trimmed by
      # its OWN overflow only (3 records > 2) — never by A's, and A's records are
      # never trimmed on B's account.
      assert {:error, :not_found} = ProcessManager.get(b_oldest, srv)

      for id <- [b_older, b_newest] do
        assert {:ok, %Execution{status: :completed, kind: :background_job}} =
                 ProcessManager.get(id, srv)
      end

      listed = ProcessManager.list(srv) |> Enum.map(& &1.id)
      assert listed == Enum.reverse([a_newer, a_newest] ++ [b_older, b_newest])
      refute a_oldest in listed
      refute a_older in listed
      refute b_oldest in listed
    end

    test "protected records do not consume the global :process_finished_max_records", %{srv: srv} do
      pin_counting_seams()
      Application.put_env(:evo_git, :process_finished_retention_ms, 300_000)
      Application.put_env(:evo_git, :process_finished_max_records, 3)

      jobs = Enum.map(1..2, fn _ -> finished_background_job(srv, self()) end)
      tool_calls = Enum.map(1..5, fn _ -> finished_tool_call(srv, self()) end)

      # `finish/3` already ran the retention pass: the two protected background
      # jobs neither age out nor count against the global cap, so all five tool
      # calls compete for the cap of 3 on their own.
      for id <- jobs do
        assert {:ok, %Execution{status: :completed, kind: :background_job}} =
                 ProcessManager.get(id, srv)
      end

      for id <- Enum.drop(tool_calls, 3) do
        assert {:ok, %Execution{status: :completed, kind: :tool_call}} =
                 ProcessManager.get(id, srv)
      end

      for id <- Enum.take(tool_calls, 2) do
        assert {:error, :not_found} = ProcessManager.get(id, srv)
      end

      # Stable: the roster is already at its documented shape.
      assert {:ok, 0} = ProcessManager.prune(srv)
    end

    test "a dead owner and a nil owner still age out", %{srv: srv} do
      pin_counting_seams()
      Application.put_env(:evo_git, :process_finished_retention_ms, 300_000)

      dead_job = finished_background_job(srv, dead_owner())
      nil_owner_job = finished_background_job(srv, nil)
      live_job = finished_background_job(srv, self())

      Application.put_env(:evo_git, :process_finished_retention_ms, 0)

      # Only the two unprotected records age out; an owner that cannot vouch for
      # its record any more puts it back on the ordinary path.
      assert {:ok, 2} = ProcessManager.prune(srv)

      assert {:error, :not_found} = ProcessManager.get(dead_job, srv)
      assert {:error, :not_found} = ProcessManager.get(nil_owner_job, srv)

      assert {:ok, %Execution{status: :completed, kind: :background_job}} =
               ProcessManager.get(live_job, srv)
    end

    test "prune/1 reports the removed total on a mixed roster", %{srv: srv} do
      pin_counting_seams()
      Application.put_env(:evo_git, :process_finished_retention_ms, 300_000)

      # Created while BOTH bounds still permit retention: `finish/3` runs its own
      # pass (and discards the count), so the per-owner cap is shrunk only
      # immediately before the ONE explicit prune whose count is the subject.
      jobs = Enum.map(1..3, fn _ -> finished_background_job(srv, self()) end)
      tool_calls = Enum.map(1..2, fn _ -> finished_tool_call(srv, self()) end)
      dead_tool_call = finished_tool_call(srv, dead_owner())

      Application.put_env(:evo_git, :process_background_max_per_owner, 2)
      Application.put_env(:evo_git, :process_finished_retention_ms, 0)

      # 1 protected-owner overflow + 2 aged tool calls + 1 aged dead-owner tool call.
      assert {:ok, 4} = ProcessManager.prune(srv)

      [oldest_job, newer_job, newest_job] = jobs

      assert ProcessManager.list(srv) |> Enum.map(& &1.id) == [newest_job, newer_job]

      for id <- [oldest_job | tool_calls] ++ [dead_tool_call] do
        assert {:error, :not_found} = ProcessManager.get(id, srv)
      end
    end
  end

  defp open_sleep do
    Port.open({:spawn_executable, System.find_executable("sleep")}, [
      :binary,
      :exit_status,
      args: ["60"]
    ])
  end

  # The counting tests must not let a sampling tick run (and discard) a
  # retention pass mid-test; the age window itself is set per test.
  defp pin_counting_seams do
    Application.put_env(:evo_git, :process_manager_sample_interval_ms, 3_600_000)
  end

  # A terminal `:background_job` owned by `owner_pid` (`nil`/dead = unprotected).
  defp finished_background_job(srv, owner_pid) do
    {:ok, id} =
      ProcessManager.track(:background_job, %{tool: "bash", owner_pid: owner_pid}, srv)

    :ok = ProcessManager.finish(id, :completed, srv)
    id
  end

  defp finished_tool_call(srv, owner_pid) do
    {:ok, id} = ProcessManager.track(:tool_call, %{tool: "bash", owner_pid: owner_pid}, srv)
    :ok = ProcessManager.finish(id, :completed, srv)
    id
  end

  # An owner that is genuinely DEAD once this returns: the `:DOWN` reply is the
  # ordering proof (never a sleep).
  defp dead_owner do
    pid = spawn(fn -> :ok end)
    ref = Process.monitor(pid)

    receive do
      {:DOWN, ^ref, :process, ^pid, _reason} -> pid
    after
      1_000 -> flunk("the throwaway owner did not die")
    end
  end

  # An owner that stays ALIVE for the whole test (killed by the caller's on_exit).
  defp start_owner, do: spawn(fn -> Process.sleep(:infinity) end)

  defp restore_seams do
    Application.delete_env(:evo_git, :process_finished_retention_ms)
    Application.delete_env(:evo_git, :process_finished_max_records)
    Application.delete_env(:evo_git, :process_stats_enabled)
    Application.delete_env(:evo_git, :process_manager_sample_interval_ms)
    Application.delete_env(:evo_git, :process_background_max_per_owner)
  end

  # Nil-aware restore for a seam whose ambient value is captured in `setup/0`
  # (an absent key must stay absent so the production default applies again).
  defp restore_seam(key, nil), do: Application.delete_env(:evo_git, key)
  defp restore_seam(key, value), do: Application.put_env(:evo_git, key, value)

  defp flush do
    receive do
      _message -> flush()
    after
      0 -> :ok
    end
  end
end
