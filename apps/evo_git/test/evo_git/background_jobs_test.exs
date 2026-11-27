defmodule EvoGit.BackgroundJobsTest do
  # async: false — tests drive REAL OS processes (the sandbox backend is
  # disabled in the test env, so each job is a plain `Port.open/2` child through
  # the platform shell; where only registry bookkeeping is under test, a job is
  # registered through the same production start path with a systemd `:unit`
  # stand-in handle instead). Each job writes
  # `genesis_job_<os-pid>-<vm-unique>_<id>.log` into a scratch directory that is
  # resolved in the CALLING process through the per-task tmpdir seam
  # (`EvoGit.TaskTmpdir.put_current/1` → `EvoGit.Sandbox.resolve_tmpdir/0`), and
  # the detached child inherits that same `TMPDIR`: a job started from an agent
  # tool task lands inside that task's managed scratch dir, so foreground and
  # background execution of one task agree on `TMPDIR`; with no seam installed
  # the host system tmpdir is used. The FILE name still carries a
  # per-REGISTRY-instance token because ids restart at `bash-1` in every registry
  # and several registries (another BEAM, or a concurrent `mix test` VM) can
  # share one scratch dir, so an id alone would not be a unique file address
  # (both would otherwise truncate/delete a live job's log).
  # File hygiene is per JOB, not per directory window: the registry returns the
  # exact `:output_path` it created, so every job start registers an `on_exit`
  # that removes that ONE file — never a `File.ls` of a scratch directory other
  # registries share (thousands of entries = milliseconds per listing). The
  # liveness probes (`kill -0`, real `sleep` children) are host-process global,
  # which is why this module must stay in the sync phase.
  #
  # The suite is POSIX-oriented by construction: `pid_alive?/1` probes with
  # `kill -0` and the fixtures are `sh` command lines (`sleep`, `seq`, `echo`),
  # matching what the disabled-backend port path spawns on this host.
  #
  # A third global: the wait-budget tests write the CALL-TIME seams app env
  # `:background_wait_default_ms` (the default budget) and
  # `:background_wait_max_ms` (the cap), restored per test through
  # `put_test_env/2`, nil-aware. Both are read at call time by
  # `wait_default_ms/0` / `wait_max_ms/0`, i.e. potentially by a concurrent
  # module's `job_output` loop, so they are real BEAM-globals — never write a
  # seam value without an `on_exit` restore in this (sync) module.
  use ExUnit.Case, async: false

  alias EvoGit.BackgroundJobs
  alias EvoGit.ProcessManager

  @moduletag :tmp_dir

  # Appended by `read/2` to the returned text when more output is pending; it is
  # NOT part of the job's output file, so it must be stripped when reassembling.
  @pending_marker "\n[... more output pending; call job_output again]"

  # Generous, bounded deadline for every poll. Nothing here asserts a wall-clock
  # bound — the waits are event-driven and this only absorbs scheduling latency.
  @deadline_ms 5_000
  # Poll cadence for every wait: tight at first — most conditions are either
  # already true or become true within a few ms (a shell child's port exit message
  # lands almost immediately) — then relaxed so a genuinely slow condition does
  # not spin. The floor is 1 ms because each poll is a ~30 µs registry read (or a
  # `Port.info/1` BIF), while the condition itself is the cost. The deadline
  # above stays the only bound.
  @poll_first_ms 1
  @poll_max_ms 20
  # The `unit` kill path's `systemctl --user stop` runs in a fire-and-forget Task
  # with no handle to await (`EvoGit.Sandbox.Background.stop_unit_async/1`), so
  # `quiet_kill/1`'s console-noise capture window waits for the
  # `:background_unit_stop_notify` seam's completion message — sent AFTER the
  # systemctl calls, i.e. after that path's warning line — instead of sleeping a
  # fixed settle margin.
  @quiet_kill_results :background_jobs_test_quiet_kill_results

  # Test-only CALL-TIME seams (production defaults stay 1_000 ms for the periodic
  # reconcile tick and 100 ms for the SIGTERM→SIGKILL grace).
  #
  # The module default DISARMS the tick for every test that does not wait on it:
  # while a live `:unit` job exists the tick reconciles it through
  # `systemctl --user show`, i.e. ONE fork per live unit job per tick, and the
  # per-owner-cap test deliberately holds ten of them. `await_reconcile_tick!/1`'s
  # own test arms a real (short) timer instead, which is what proves the timer
  # fires. The kill grace is zero because every liveness assertion below polls
  # until the child is genuinely gone, so the TERM→KILL margin buys nothing.
  @no_tick_interval_ms 3_600_000
  @tick_interval_ms_override 25
  @kill_grace_ms_override 0

  setup %{tmp_dir: tmp_dir} do
    name = :"bg_jobs_test_#{System.unique_integer([:positive])}"

    put_test_env(:background_tick_interval_ms, @no_tick_interval_ms)
    put_test_env(:kill_grace_ms, @kill_grace_ms_override)
    # Reports the completion of the registry's fire-and-forget systemd stop Task
    # (`EvoGit.Sandbox.Background.stop_unit_async/1`) to THIS process, so
    # `quiet_kill/1` can await the stop instead of sleeping a fixed margin.
    put_test_env(:background_unit_stop_notify, self())

    # An ISOLATED registry per test: the test supervisor guarantees a graceful
    # shutdown, whose `terminate/2` kills every job still live.
    # A per-test ISOLATED process registry: every started job is tracked as ONE
    # `:background_job` execution, and pointing the job registry at a PRIVATE
    # manager keeps that bookkeeping off the app-global instance (whose sampling
    # timer would otherwise probe this module's throw-away `:unit` stand-in
    # handles with `systemctl`/`ps` forks). The manager is started FIRST so the
    # supervisor terminates it LAST — the job registry's `terminate/2` can still
    # settle the executions it is killing. OS resource SAMPLING stays off: this
    # module asserts event-driven job state, never resource numbers.
    put_test_env(:process_stats_enabled, false)
    manager = :"bg_jobs_test_pm_#{System.unique_integer([:positive])}"
    start_supervised!({EvoGit.ProcessManager, name: manager})
    start_supervised!({EvoGit.BackgroundJobs, [name: name, process_manager: manager]})

    Process.put(:evogit_background_jobs_server, name)
    Process.put(:evogit_agent_pid, self())

    on_exit(fn ->
      # `on_exit` runs in a DIFFERENT process, so the process dictionary these
      # deletes touch is not the test process's — the test process's own keys die
      # with it. Kept as belt-and-braces for the seam contract.
      Process.delete(:evogit_agent_pid)
      Process.delete(:evogit_background_jobs_server)
    end)

    %{registry: name, tmp_dir: tmp_dir, process_manager: manager}
  end

  describe "start_job/1" do
    test "starts a detached job and returns its record", %{tmp_dir: tmp_dir} do
      assert {:ok, job} =
               BackgroundJobs.start_job(%{
                 command: "echo hello",
                 cwd: tmp_dir,
                 agent_id: "agent-1",
                 task_id: "42"
               })

      # Short, predictable ids: `@id_prefix` + a per-registry monotonic counter,
      # so an agent can repeat one without copying 16 random hex chars.
      assert job.id == "bash-1"
      assert job.kind == "bash"
      assert job.status == :running
      assert job.cursor == 0
      assert job.lines_read == 0
      assert job.exit_code == nil
      assert job.detail == nil
      assert job.finished_at == nil
      assert %DateTime{} = job.started_at
      assert job.cwd == tmp_dir
      assert job.owner_pid == self()
      assert job.agent_id == "agent-1"
      assert job.task_id == "42"
      assert job.label == "echo hello"

      assert String.contains?(job.output_path, "genesis_job_")
      assert File.exists?(job.output_path)

      # The test env disables the systemd backend (`EvoGit.Sandbox.Linux.enabled?/0`
      # is false in :test), so every job takes the PLAIN PORT path.
      # `os_pid` is NOT asserted here: `port_handle/2` polls `Port.info(port, :os_pid)`
      # only AFTER the spawn returns, so a command that already exited leaves it
      # `nil` (the handle type is `os_pid: integer() | nil`). The integer case is
      # pinned by "records an integer os_pid for a job that is still running".
      assert %{kind: :port, backend: EvoGit.Sandbox.Linux} = job.handle
      assert job.handle.os_pid == nil or is_integer(job.handle.os_pid)
    end

    test "ids are short and sequential, and an id already present is skipped", %{
      tmp_dir: tmp_dir
    } do
      first = start_job!(%{command: "echo one", cwd: tmp_dir})
      second = start_job!(%{command: "echo two", cwd: tmp_dir})

      assert first.id == "bash-1"
      assert second.id == "bash-2"

      # Re-seed the counter to 1: `bash-1` is still held by the first job's
      # retained record, so the collision loop must advance to the next free id
      # instead of reusing it.
      :sys.replace_state(registry(), fn state -> %{state | next_id: 1} end)

      third = start_job!(%{command: "echo three", cwd: tmp_dir})
      assert third.id == "bash-3"
    end

    test "truncates a stale output file at the same per-registry path", %{tmp_dir: tmp_dir} do
      # The output FILE name carries a per-registry-instance token, so no other
      # registry on this host can reach this path at all. What still needs
      # proving is that a job reusing an id INSIDE the same registry truncates
      # its own leftover file instead of leaking those bytes into the new reads.
      first = start_job!(%{command: "echo first", cwd: tmp_dir})
      path = first.output_path
      await_status!(first.id, :completed)
      assert File.read!(path) =~ "first"
      File.write!(path, "STALE OUTPUT\n")
      # Drop the retained record and rewind the counter so the NEXT job reuses
      # id `bash-1` — and therefore, in this same registry, this exact path.
      :sys.replace_state(registry(), fn state -> %{state | jobs: %{}, next_id: 1} end)
      job = start_job!(%{command: "echo fresh", cwd: tmp_dir})
      assert job.id == "bash-1"
      assert job.output_path == path
      # Truncation is deterministic (it happens BEFORE the spawn): the stale
      # bytes are gone even while the child is still writing its own output.
      refute File.read!(job.output_path) =~ "STALE OUTPUT"

      await_status!(job.id, :completed)
      assert {:ok, %{text: text}} = BackgroundJobs.read(job.id)
      refute text =~ "STALE OUTPUT"
      assert text =~ "fresh"
    end

    test "a sibling registry's job with the same id cannot truncate or delete this job's log", %{
      tmp_dir: tmp_dir,
      registry: registry_a,
      process_manager: manager
    } do
      # The reported bug: job ids restart at `bash-1` in EVERY registry and the
      # scratch dir is host-wide, so an id alone used to be a shared file address
      # — a second registry (another BEAM, or a `mix test` VM) truncated a LIVE
      # job's log at start and deleted it at cleanup. The per-registry token in
      # the file name is what makes the two paths disjoint.
      job_a = start_job!(%{command: "echo alpha; sleep 30", cwd: tmp_dir})
      assert job_a.id == "bash-1"
      assert %{kind: :port} = job_a.handle
      assert is_integer(job_a.handle.os_pid)
      path_a = job_a.output_path
      # The child's first write lands asynchronously through the port.
      wait_until(
        fn -> File.read(path_a) == {:ok, "alpha\n"} end,
        @deadline_ms,
        "registry A's log never received the job's output"
      )

      # A SECOND isolated registry in the same test, on the SAME host scratch dir
      # (the `id:` override is required because the module has no custom
      # `child_spec/1`, so two children of one supervisor would share its id).
      registry_b = :"bg_jobs_sibling_#{System.unique_integer([:positive])}"

      start_supervised!(
        Supervisor.child_spec(
          {EvoGit.BackgroundJobs, [name: registry_b, process_manager: manager]},
          id: registry_b
        )
      )

      # `BackgroundJobs.server/0` reads the seam at CALL time, so this switches
      # every call below to registry B.
      Process.put(:evogit_background_jobs_server, registry_b)
      job_b = start_job!(%{command: "echo beta", cwd: tmp_dir})
      assert job_b.id == "bash-1"
      path_b = job_b.output_path
      refute path_a == path_b
      # B's start-time truncation cannot reach A's file.
      assert File.exists?(path_a)
      assert File.read!(path_a) =~ "alpha"

      await_status!(job_b.id, :completed)
      # Simulate the test-harness cleanup that deletes one job's own log, then
      # prove A's live job is untouched and still readable.
      File.rm!(path_b)
      refute File.exists?(path_b)
      Process.put(:evogit_background_jobs_server, registry_a)
      assert File.read!(path_a) =~ "alpha"
      assert {:ok, %{text: text, job: read_job}} = BackgroundJobs.read("bash-1")
      assert text == "alpha\n"
      assert read_job.status == :running
      assert {:ok, %{status: :running}} = BackgroundJobs.job("bash-1")
      # Clean up registry A's still-running child for real.
      assert {:ok, %{status: :killed}} = BackgroundJobs.kill(job_a.id)
      await_status!(job_a.id, :killed)

      wait_until(
        fn -> not pid_alive?(job_a.handle.os_pid) end,
        @deadline_ms,
        "registry A's OS process survived the kill"
      )
    end

    test "records an integer os_pid for a job that is still running", %{tmp_dir: tmp_dir} do
      job = start_job!(%{command: "sleep 30", cwd: tmp_dir})

      assert %{kind: :port, backend: EvoGit.Sandbox.Linux} = job.handle
      assert is_integer(job.handle.os_pid)
      assert pid_alive?(job.handle.os_pid)

      assert {:ok, %{status: :killed}} = BackgroundJobs.kill(job.id)

      wait_until(
        fn -> not pid_alive?(job.handle.os_pid) end,
        @deadline_ms,
        "the job's OS process survived the kill"
      )
    end

    test "defaults the label to the command's first line", %{tmp_dir: tmp_dir} do
      job = start_job!(%{command: "echo one\necho two", cwd: tmp_dir})
      assert job.label == "echo one"
    end

    test "keeps an explicit label and truncates a long one to 200 chars", %{tmp_dir: tmp_dir} do
      job = start_job!(%{command: "echo hi", cwd: tmp_dir, label: "my label"})
      assert job.label == "my label"

      long = String.duplicate("x", 300)
      job = start_job!(%{command: "echo hi", cwd: tmp_dir, label: long})
      assert String.length(job.label) == 200
      assert job.label == String.slice(long, 0, 200)
    end

    test "uses the process-dictionary owner when the spec omits :owner_pid", %{tmp_dir: tmp_dir} do
      job = start_job!(%{command: "echo hi", cwd: tmp_dir})
      assert job.owner_pid == self()
      assert job.owner_pid == BackgroundJobs.current_owner_pid()
    end

    test "prefers an explicit :owner_pid over the process-dictionary owner", %{tmp_dir: tmp_dir} do
      owner = spawn(fn -> Process.sleep(:infinity) end)

      job = start_job!(%{command: "echo hi", cwd: tmp_dir, owner_pid: owner})
      assert job.owner_pid == owner
      refute job.owner_pid == self()

      Process.exit(owner, :kill)
    end
  end

  describe "start_job/1 validation" do
    test "rejects a missing or blank command", %{tmp_dir: tmp_dir} do
      assert {:error, message} = BackgroundJobs.start_job(%{cwd: tmp_dir})
      assert message =~ "command"

      assert {:error, message} = BackgroundJobs.start_job(%{command: "   ", cwd: tmp_dir})
      assert message =~ "command"
    end

    test "rejects a missing cwd" do
      assert {:error, message} = BackgroundJobs.start_job(%{command: "echo hi"})
      assert message =~ "cwd"
    end

    test "rejects a non-existent cwd", %{tmp_dir: tmp_dir} do
      missing = Path.join(tmp_dir, "does-not-exist")

      assert {:error, message} =
               BackgroundJobs.start_job(%{command: "echo hi", cwd: missing})

      assert message =~ "does not exist"
      assert message =~ missing
    end

    test "rejects a bad :cwd type with prose" do
      # A non-binary value is normalized away by `trimmed_binary/1`, so it lands
      # in the missing-`cwd` branch — what matters (and what is pinned here) is
      # that it is ONE actionable prose error, never a raise.
      assert {:error, message} = BackgroundJobs.start_job(%{command: "echo hi", cwd: 123})
      assert is_binary(message)
      assert message =~ "cwd"
    end

    test "rejects a non-pid owner when the caller has no agent pid", %{
      tmp_dir: tmp_dir,
      registry: registry
    } do
      # `:evogit_agent_pid` is per-process: a spawned task starts without it, so
      # `current_owner_pid/0` is nil there.
      assert {:error, message} =
               Task.async(fn ->
                 Process.put(:evogit_background_jobs_server, registry)
                 refute BackgroundJobs.current_owner_pid()
                 BackgroundJobs.start_job(%{command: "echo hi", cwd: tmp_dir})
               end)
               |> Task.await()

      assert message =~ "no owning agent process"

      assert {:error, message} =
               Task.async(fn ->
                 Process.put(:evogit_background_jobs_server, registry)

                 BackgroundJobs.start_job(%{
                   command: "echo hi",
                   cwd: tmp_dir,
                   owner_pid: "not-a-pid"
                 })
               end)
               |> Task.await()

      assert message =~ "no owning agent process"
    end

    test "rejects a spec that is neither a map nor a keyword list" do
      assert {:error, message} = BackgroundJobs.start_job("nope")
      assert message =~ "spec map"

      assert {:error, message} = BackgroundJobs.start_job(42)
      assert message =~ "spec map"
    end

    test "accepts a keyword-list spec", %{tmp_dir: tmp_dir} do
      job = start_job!(command: "echo hi", cwd: tmp_dir)
      assert job.label == "echo hi"
    end
  end

  describe "completion" do
    test "reports a zero-exit job as completed", %{tmp_dir: tmp_dir} do
      job = start_job!(%{command: "echo hello", cwd: tmp_dir})

      job = await_status!(job.id, :completed)
      assert job.exit_code == 0
      assert job.detail == "exit code: 0"
      assert %DateTime{} = job.finished_at
    end

    test "reports a non-zero exit as failed", %{tmp_dir: tmp_dir} do
      job = start_job!(%{command: "exit 3", cwd: tmp_dir})

      job = await_status!(job.id, :failed)
      assert job.exit_code == 3
      assert job.detail == "exit code: 3"
      assert %DateTime{} = job.finished_at
    end
  end

  describe "process registry integration (:background_job executions)" do
    # Every started job is recorded as ONE `:background_job` execution in
    # `EvoGit.ProcessManager`; `setup` points the registry at an ISOLATED
    # manager, so these assertions see only THIS test's executions.
    test "a started job is tracked as ONE running :background_job execution", %{
      tmp_dir: tmp_dir,
      process_manager: manager
    } do
      port = open_observer_port()

      job =
        start_unit_handle_job!(
          tmp_dir,
          "tracked",
          %{command: "echo tracked", agent_id: "agent-7", task_id: "99", repo_root: tmp_dir},
          %{port: port}
        )

      assert is_binary(job.execution_id)

      assert [execution] = ProcessManager.list(server: manager)
      assert execution.id == job.execution_id
      assert execution.kind == :background_job
      assert execution.job_id == job.id
      assert execution.tool == "bash"
      assert execution.command == "echo tracked"
      assert execution.label == "echo tracked"
      assert execution.cwd == tmp_dir
      assert execution.repo_root == tmp_dir
      assert execution.agent_id == "agent-7"
      assert execution.task_id == "99"
      assert execution.owner_pid == self()
      assert execution.runtime == :background
      assert execution.backend == :systemd
      assert execution.status == :running
      # The normalized handle is ATTACHED, so the execution also carries the OS
      # addressing (the observer port + the unit name).
      assert execution.unit == EvoGit.Sandbox.Background.unit_name("bash-tracked")
      assert %DateTime{} = execution.started_at

      # The observer port's exit is the completion signal, and the execution
      # settles through the SAME funnel as the job record.
      send(registry(), {port, {:exit_status, 0}})
      assert %{status: :completed, exit_code: 0} = await_status!(job.id, :completed)

      assert {:ok, execution} = ProcessManager.get(job.execution_id, server: manager)
      assert execution.status == :completed
      assert execution.exit_code == 0
      assert %DateTime{} = execution.ended_at
    end

    test "a NATIVE integer agent/task id lands on the execution unchanged", %{
      tmp_dir: tmp_dir,
      process_manager: manager
    } do
      job =
        start_live_unit_job!(tmp_dir, "native-ids", %{
          command: "echo native",
          agent_id: 42,
          task_id: 7
        })

      assert {:ok, execution} = ProcessManager.get(job.execution_id, server: manager)
      # `:agent_id` / `:task_id` keep their NATIVE term: a job started with the
      # INTEGER id 42 must reach the execution as that same integer, never as its
      # stringification (which would break every agent/task filter downstream).
      assert execution.agent_id == 42
      assert execution.task_id == 7
      assert [listed] = ProcessManager.list(agent_id: 42, server: manager)
      assert listed.id == job.execution_id
    end

    test "a non-zero exit still COMPLETES the execution with its real exit code", %{
      tmp_dir: tmp_dir,
      process_manager: manager
    } do
      {job, port} = start_observed_unit_job!(tmp_dir)
      send(registry(), {port, {:exit_status, 3}})
      assert %{status: :failed, exit_code: 3} = await_status!(job.id, :failed)

      assert {:ok, execution} = ProcessManager.get(job.execution_id, server: manager)
      # The JOB record keeps the failure (`await_status!` above), while the
      # EXECUTION follows the uniform mapping: an OS process that actually
      # exited is `:completed` + `:exited`, whatever its status code.
      assert execution.status == :completed
      assert execution.exit_code == 3
      assert execution.reason == :exited
    end

    test "an exit observed during the spawn itself still leaves a TERMINAL record", %{
      tmp_dir: tmp_dir,
      process_manager: manager
    } do
      # `settle_start_exit/1` runs AFTER the execution is tracked, so a job that
      # is already finished when `start_job/1` returns can never leave a ghost
      # `:running`/`:starting` execution behind.
      job = start_terminal_unit_job!(tmp_dir, "tracked-immediate")
      assert job.status == :completed
      assert is_binary(job.execution_id)

      assert [execution] = ProcessManager.list(server: manager)
      assert execution.job_id == job.id
      assert execution.status == :completed
      assert execution.exit_code == 0
      assert %DateTime{} = execution.ended_at
    end

    test "kill/3 settles the execution as :killed", %{
      tmp_dir: tmp_dir,
      process_manager: manager
    } do
      job = start_live_unit_job!(tmp_dir, "tracked-kill")
      assert {:ok, %{status: :running}} = BackgroundJobs.job(job.id)

      assert {:ok, killed} = quiet_kill(job)
      assert killed.status == :killed

      assert {:ok, execution} = ProcessManager.get(job.execution_id, server: manager)
      assert execution.status == :killed
      assert execution.reason == {:killed_by, :operator}
      assert execution.exit_code == nil
      assert %DateTime{} = execution.ended_at
    end

    test "a kill through the process manager stops the job and settles BOTH records", %{
      tmp_dir: tmp_dir,
      process_manager: manager
    } do
      # `EvoGit.ProcessManager.kill/2` routes a `:background_job` execution with a
      # `job_id` to `EvoGit.BackgroundJobs.kill/3` — the reverse direction must
      # work end to end, and both records must end up terminal.
      job = start_live_unit_job!(tmp_dir, "tracked-manager-kill")

      _log =
        ExUnit.CaptureLog.capture_log([level: :warning], fn ->
          assert :ok =
                   ProcessManager.kill(job.execution_id, server: manager, reason: :operator)
        end)

      # The unit stop is a fire-and-forget Task; wait for its completion report
      # (`setup` installs the notify seam) instead of sleeping a fixed margin.
      receive do
        {:background_unit_stop_finished, _unit} -> :ok
      after
        @deadline_ms -> flunk("the registry's systemd stop task never reported back")
      end

      assert {:ok, %{status: :killed} = killed} = BackgroundJobs.job(job.id)
      assert killed.detail =~ "killed ("

      assert {:ok, execution} = ProcessManager.get(job.execution_id, server: manager)
      assert execution.status == :killed
      # `ProcessManager.kill/2` defaults its actor to `:operator`.
      assert execution.reason == {:killed_by, :operator}
      assert %DateTime{} = execution.ended_at
    end

    test "a registry shutdown settles its live jobs' executions as :killed", %{
      tmp_dir: tmp_dir,
      process_manager: manager
    } do
      job = start_live_unit_job!(tmp_dir, "tracked-shutdown")
      assert {:ok, %{status: :running}} = BackgroundJobs.job(job.id)

      _log =
        ExUnit.CaptureLog.capture_log([level: :warning], fn ->
          assert :ok = stop_supervised(EvoGit.BackgroundJobs)
        end)

      receive do
        {:background_unit_stop_finished, _unit} -> :ok
      after
        @deadline_ms -> flunk("the registry's systemd stop task never reported back")
      end

      assert {:ok, execution} = ProcessManager.get(job.execution_id, server: manager)
      assert execution.status == :killed
      assert execution.reason == {:killed_by, :registry_shutdown}
    end
  end

  describe "systemd unit exit observer (:unit handles)" do
    # These tests drive the REAL registry routing: a `:unit` handle keeps the
    # still-open `systemd-run --wait` client port, and that port's
    # `{port, {:exit_status, code}}` message is the ONLY completion signal for a
    # systemd job (systemd unloads a successfully-exited transient unit
    # immediately, so a post-mortem `systemctl --user show` cannot tell). A REAL
    # local port stands in for the client, because `EvoGit.Sandbox.Linux.enabled?/0`
    # is hard-false in the test env (no systemd user bus).

    test "a zero exit reported by the observer port completes the job", %{tmp_dir: tmp_dir} do
      {job, port} = start_observed_unit_job!(tmp_dir)

      send(registry(), {port, {:exit_status, 0}})

      job = await_status!(job.id, :completed)
      assert job.exit_code == 0
      assert job.detail == "exit code: 0"
      assert %DateTime{} = job.finished_at
      assert job.handle.kind == :unit
      assert job.handle.unit == EvoGit.Sandbox.Background.unit_name("bash-observed")
    end

    test "a non-zero exit reported by the observer port fails the job", %{tmp_dir: tmp_dir} do
      {job, port} = start_observed_unit_job!(tmp_dir)

      send(registry(), {port, {:exit_status, 3}})

      job = await_status!(job.id, :failed)
      assert job.exit_code == 3
      assert job.detail == "exit code: 3"
      assert %DateTime{} = job.finished_at
    end

    test "the observer port carries no job output — its :data is dropped", %{tmp_dir: tmp_dir} do
      {job, port} = start_observed_unit_job!(tmp_dir)

      # A unit writes its OWN output to the `append:` log file; anything arriving
      # on the client port is systemd-run diagnostics and must never be appended.
      send(registry(), {port, {:data, "systemd-run: diagnostic noise"}})
      send(registry(), {port, {:exit_status, 0}})

      job = await_status!(job.id, :completed)
      assert File.read!(job.output_path) == ""
    end

    test "an exit observed during the spawn itself is applied immediately", %{tmp_dir: tmp_dir} do
      # `systemd-run --wait` returns the UNIT's status, so a command that
      # finishes inside the start grace window hands back `pending_exit_code`
      # instead of a live observer port — the job must still be terminal at once.
      for {code, expected} <- [{0, :completed}, {127, :failed}] do
        handle = %{
          kind: :unit,
          unit: EvoGit.Sandbox.Background.unit_name("bash-immediate"),
          backend: EvoGit.Sandbox.Linux,
          port: nil,
          pending_exit_code: code
        }

        assert {:ok, job} =
                 BackgroundJobs.start_job_with_handle(
                   %{command: "echo immediate", cwd: tmp_dir},
                   handle
                 )

        assert job.status == expected
        assert job.exit_code == code
        assert %DateTime{} = job.finished_at

        # And the recorded state — not just the returned record — is terminal.
        assert {:ok, %{status: ^expected}} = BackgroundJobs.job(job.id)
      end
    end

    test "an unreportable unit with no live observer settles as failed after the grace", %{
      tmp_dir: tmp_dir
    } do
      # `{:unknown, _}` (what `systemctl --user show` answers for a unit systemd
      # already unloaded) must NEVER mean "running forever".
      put_unknown_grace(0)

      {job, nil} = start_observed_unit_job!(tmp_dir, :closed)

      job = await_status!(job.id, :failed)
      assert job.exit_code == nil
      assert job.detail =~ "exit status unknown"
      assert %DateTime{} = job.finished_at
    end

    test "a live observer port outranks the floor — the job is not settled early", %{
      tmp_dir: tmp_dir
    } do
      put_unknown_grace(0)
      # `setup` DISARMS the periodic tick (see `@no_tick_interval_ms`); this test
      # arms a real one, which is what `await_reconcile_tick!/1` proves fired.
      put_test_env(:background_tick_interval_ms, @tick_interval_ms_override)

      {job, port} = start_observed_unit_job!(tmp_dir)

      # Lazy reconciles (every `job/2`) and the periodic reconcile tick below run
      # the SAME `settle_unknown/2` floor. The observer port can still deliver the
      # real exit code, so the floor must yield to it.
      assert {:ok, %{status: :running}} = BackgroundJobs.job(job.id)
      assert {:ok, %{status: :running}} = BackgroundJobs.job(job.id)

      # Event-driven proof that a REAL reconcile tick ran: the tick handler
      # re-arms its timer, so the registry's `tick_timer` reference changes on
      # every tick. Waiting for that change replaces the previous fixed 1.5 s
      # sleep (which was only ever budget for "at least one 1 s tick").
      await_reconcile_tick!(registry())
      assert {:ok, %{status: :running}} = BackgroundJobs.job(job.id)

      send(registry(), {port, {:exit_status, 0}})
      assert %{status: :completed} = await_status!(job.id, :completed)
    end
  end

  describe "read/2" do
    test "consumes output as a cursor", %{tmp_dir: tmp_dir} do
      job = start_job!(%{command: "echo hello", cwd: tmp_dir})

      wait_until(
        fn -> File.read(job.output_path) == {:ok, "hello\n"} end,
        @deadline_ms,
        "the job never wrote its output"
      )

      assert {:ok, %{text: "hello\n", job: first}} = BackgroundJobs.read(job.id)
      assert first.lines_read >= 1

      # The cursor advanced by exactly the bytes returned, so nothing is replayed.
      assert {:ok, %{text: "", job: second}} = BackgroundJobs.read(job.id)
      assert second.lines_read == first.lines_read
      assert second.cursor == first.cursor
    end

    test "caps a read at :max_bytes without losing bytes", %{tmp_dir: tmp_dir} do
      job = start_job!(%{command: "seq 1 2000", cwd: tmp_dir})
      # Drain only once the job finished: output data messages always precede the
      # port's exit_status message, so `:completed` means the file is complete.
      completed = await_status!(job.id, :completed, 15_000)
      full = File.read!(completed.output_path)
      assert byte_size(full) > 1_000

      assert {:ok, %{text: first}} = BackgroundJobs.read(job.id, max_bytes: 10)
      assert String.ends_with?(first, @pending_marker)
      assert byte_size(first) == 10 + byte_size(@pending_marker)

      first_chunk = String.replace_suffix(first, @pending_marker, "")
      assert byte_size(first_chunk) == 10

      {chunks, last} = drain(job.id, [first_chunk], 1_000, 500)
      assert Enum.join(chunks) == full
      assert last.cursor == byte_size(full)
    end
  end

  describe "read/2 errors" do
    test "errors when the output file is gone", %{tmp_dir: tmp_dir} do
      job = start_job!(%{command: "echo hello", cwd: tmp_dir})
      _ = await_status!(job.id, :completed)

      assert :ok = File.rm(job.output_path)

      assert {:error, message} = BackgroundJobs.read(job.id)
      assert is_binary(message)
      assert message =~ job.id
      assert message =~ job.output_path
    end

    test "rejects an invalid :max_bytes", %{tmp_dir: tmp_dir} do
      job = start_job!(%{command: "echo hello", cwd: tmp_dir})

      for bad <- [0, -5, "x"] do
        assert {:error, message} = BackgroundJobs.read(job.id, max_bytes: bad)
        assert message =~ "max_bytes"
      end
    end
  end

  describe "per-task tmpdir scoping" do
    test "a job started with a per-task tmpdir writes its log there and the child sees that TMPDIR",
         %{tmp_dir: tmp_dir} do
      # `EvoGit.ToolRuntime` installs this exact seam in every tool task
      # (`EvoGit.TaskTmpdir.put_current/1`), so this is the shape a real
      # background launch from an agent sees.
      put_task_tmpdir(tmp_dir)

      job = start_job!(%{command: "echo \"TMPDIR=$TMPDIR\"", cwd: tmp_dir})

      # The scratch dir is resolved in the CALLING process, so the log lives in
      # THIS task's managed dir — never the host system tmpdir.
      assert Path.dirname(job.output_path) == tmp_dir
      assert String.starts_with?(job.output_path, tmp_dir <> "/")
      assert File.exists?(job.output_path)

      completed = await_status!(job.id, :completed)
      assert Path.dirname(completed.output_path) == tmp_dir
      assert File.exists?(completed.output_path)

      # The detached child inherits the same TMPDIR: the seam is threaded into
      # the spawn, it is not merely the log's directory.
      assert {:ok, %{text: text}} = BackgroundJobs.read(job.id)
      assert text =~ "TMPDIR=#{tmp_dir}"
      assert File.exists?(job.output_path)
      assert String.starts_with?(job.output_path, tmp_dir)
    end

    test "a job started with no per-task tmpdir uses the system tmpdir", %{tmp_dir: tmp_dir} do
      # No seam on the test process: the production path resolves the host
      # system tmpdir, exactly as `EvoGit.Sandbox.resolve_tmpdir/0` does.
      assert EvoGit.TaskTmpdir.current() == nil
      system_tmpdir = EvoGit.Sandbox.resolve_tmpdir()

      job = start_job!(%{command: "echo hello", cwd: tmp_dir})

      assert String.starts_with?(job.output_path, system_tmpdir)
      assert Path.dirname(job.output_path) == system_tmpdir
      assert File.exists?(job.output_path)
    end

    test "foreground and background of one task agree on TMPDIR", %{tmp_dir: tmp_dir} do
      put_task_tmpdir(tmp_dir)

      # Foreground through the normal tool entry point: in the test env the
      # backend is disabled, so this is the plain `bash -c` path with the
      # per-task `TMPDIR`/`TMP`/`TEMP` env injection.
      {foreground, exit_code} =
        EvoGit.sandbox_run(tmp_dir, "bash", ["-c", "echo \"TMPDIR=$TMPDIR\""])

      assert exit_code == 0
      assert String.trim(foreground) == "TMPDIR=#{tmp_dir}"

      job = start_job!(%{command: "echo \"TMPDIR=$TMPDIR\"", cwd: tmp_dir})
      completed = await_status!(job.id, :completed)
      assert Path.dirname(completed.output_path) == tmp_dir

      assert {:ok, %{text: background}} = BackgroundJobs.read(job.id)
      assert String.trim(background) == String.trim(foreground)
      assert background =~ "TMPDIR=#{tmp_dir}"
    end

    test "a reclaimed per-task tmpdir keeps the real terminal status and read names the reclaim",
         %{tmp_dir: tmp_dir} do
      put_task_tmpdir(tmp_dir)

      job = start_job!(%{command: "echo reclaimed", cwd: tmp_dir})
      completed = await_status!(job.id, :completed)
      assert Path.dirname(completed.output_path) == tmp_dir

      # The task ended: its managed scratch dir (holding this job's log) is
      # reclaimed. The RECORD must stay honest about the job that ran.
      assert {:ok, _removed} = File.rm_rf(tmp_dir)
      refute File.exists?(completed.output_path)

      assert {:ok, after_reclaim} = BackgroundJobs.job(job.id)
      assert after_reclaim.id == job.id
      assert after_reclaim.status == :completed
      assert after_reclaim.exit_code == 0
      assert after_reclaim.output_path == completed.output_path

      # One actionable prose answer naming the vanished path and the reason —
      # never a crash, and never the "unknown id" prose reserved for an id the
      # registry never issued.
      assert {:error, message} = BackgroundJobs.read(job.id)
      assert is_binary(message)
      assert message =~ completed.output_path
      assert message =~ ~r/reclaim/i

      # The registry survived the vanished log: it still starts and completes
      # jobs (re-create the reclaimed cwd first — the job validates it).
      File.mkdir_p!(tmp_dir)
      again = start_job!(%{command: "echo alive", cwd: tmp_dir})
      await_status!(again.id, :completed)

      assert {:ok, %{text: text}} = BackgroundJobs.read(again.id)
      assert text =~ "alive"
    end
  end

  describe "kill/3" do
    test "kills a live job and its OS process", %{tmp_dir: tmp_dir} do
      job = start_job!(%{command: "sleep 30", cwd: tmp_dir})
      os_pid = job.handle.os_pid

      assert {:ok, killed} = BackgroundJobs.kill(job.id)
      assert killed.status == :killed
      assert killed.detail == "killed (stopped by request)"
      assert %DateTime{} = killed.finished_at

      # No polling-free assertion here on purpose: `kill_process_tree/1` sends TERM
      # to the process group, waits 100 ms, then KILL, and the BEAM only reaps the
      # child once the port's `{:exit_status, _}` message is handled — so the pid
      # can briefly still answer `kill -0`. The `kill -0` probe on the os_pid is
      # the reliable check here (a pgrep marker match would only re-test the same
      # kernel fact with an extra PATH lookup).
      wait_until(
        fn -> not pid_alive?(os_pid) end,
        @deadline_ms,
        "the job's OS process #{os_pid} survived the kill"
      )

      # The record stays terminal: the port's own exit message must not resurrect it.
      assert {:ok, after_kill} = BackgroundJobs.job(job.id)
      assert after_kill.status == :killed
      assert after_kill.detail == "killed (stopped by request)"
    end

    test "records a custom reason", %{tmp_dir: tmp_dir} do
      job = start_job!(%{command: "sleep 30", cwd: tmp_dir})

      assert {:ok, killed} = BackgroundJobs.kill(job.id, "test reason")
      assert killed.status == :killed
      assert killed.detail == "killed (test reason)"

      wait_until(
        fn -> not pid_alive?(job.handle.os_pid) end,
        @deadline_ms,
        "the job's OS process survived the kill"
      )
    end

    test "errors on an already-finished job", %{tmp_dir: tmp_dir} do
      job = start_job!(%{command: "echo hello", cwd: tmp_dir})
      finished = await_status!(job.id, :completed)

      assert {:error, {:already_finished, returned}} = BackgroundJobs.kill(job.id)
      assert returned.id == finished.id
      assert returned.status == :completed
    end

    test "returns :not_found for an unknown id" do
      assert {:error, :not_found} = BackgroundJobs.kill("bash-0000000000000000")
      assert {:error, :not_found} = BackgroundJobs.job("bash-0000000000000000")
      assert {:error, :not_found} = BackgroundJobs.job("bash-0000000000000000", owner_pid: self())
    end

    test "fences a job owned by another agent", %{tmp_dir: tmp_dir} do
      owner = spawn(fn -> Process.sleep(:infinity) end)
      # The fencing contract is registry-side; the kill at the end is only
      # cleanup, so a `:unit` record keeps it off the OS-kill path.
      job = start_live_unit_job!(tmp_dir, "fenced", %{owner_pid: owner})

      assert {:error, :not_owner} = BackgroundJobs.job(job.id, owner_pid: self())
      # `job/2` without a fence sees it.
      assert {:ok, %{id: id}} = BackgroundJobs.job(job.id)
      assert id == job.id

      assert {:error, message} = BackgroundJobs.read(job.id, owner_pid: self())
      assert message =~ "another agent"
      assert message =~ job.id

      # `kill/3` keeps the small SEMANTIC tuple for an ownership fence (documented
      # on `kill/3` and stated in the module doc: "the ownership/finished probes in
      # `job/2` and `kill/3` keep the small semantic tuples"), unlike `read/2`
      # whose error vocabulary is prose. Pinned as implemented.
      assert {:error, :not_owner} = BackgroundJobs.kill(job.id, nil, owner_pid: self())

      # The real owner can still read it, and the job was never killed.
      assert {:ok, %{text: _}} = BackgroundJobs.read(job.id, owner_pid: owner)
      assert {:ok, %{status: :running}} = BackgroundJobs.job(job.id)

      assert {:ok, %{status: :killed}} = quiet_kill(job)
      Process.exit(owner, :kill)
    end
  end

  describe "per-owner job cap" do
    # HOST-DEPENDENT CAPACITY: every start acquires an AgentScheduler TOOL PERMIT
    # (`BackgroundJobs.start_job_with_handle/2` → `start_with_permit/2` →
    # `AgentScheduler.acquire_tool_permit/1`) and the permit stays held for the
    # job's whole lifetime, so filling the cap needs `max_jobs_per_owner/0`
    # permits AT ONCE. That pool defaults to the host's logical CPU count
    # (`[:scheduler, :max_tool_concurrency]` → `EvoGit.Platform.cpu_threads/0`)
    # and `acquire_tool_permit/1` is a `GenServer.call(…, :infinity)` that QUEUES
    # the caller once the pool is exhausted — so on a host with fewer than ten
    # CPUs the 5th synthetic slot would block forever and time the test out. Raise
    # the pool above the cap (never lower it) and restore the previous value, so
    # no other sync module inherits the raised capacity. The app-global scheduler
    # is why this module is `async: false`.
    setup do
      original = :sys.get_state(EvoGit.AgentScheduler).max_tool_concurrency
      # Ten live jobs hold ten permits; one more is needed for the REFUSED 11th
      # start (its permit is acquired before the registry answers the cap error),
      # plus headroom.
      wanted = max(original, BackgroundJobs.max_jobs_per_owner() + 2)
      :ok = EvoGit.AgentScheduler.update_config(max_tool_concurrency: wanted)

      on_exit(fn ->
        EvoGit.AgentScheduler.update_config(max_tool_concurrency: original)
      end)
    end

    test "refuses an 11th live job and reports the limit", %{tmp_dir: tmp_dir} do
      # Forcing GLOBAL: the app-global `EvoGit.AgentScheduler`'s tool-permit pool.
      # Every start below acquires a REAL tool permit (`BackgroundJobs`'
      # `start_with_permit/2` → `AgentScheduler.acquire_tool_permit/1`), and that
      # pool defaults to the detected CPU thread count
      # (`[:scheduler, :max_tool_concurrency]`), so on a 4-core host the fifth
      # acquisition would block forever — the test would time out instead of
      # proving the per-OWNER job cap. The pool is therefore raised for the
      # duration of this test only and restored in `on_exit`, so a failing test
      # cannot leave it inflated. `max/2` keeps an already larger pool untouched.
      # The module is `async: false` (ExUnit drains async modules before sync
      # ones), so no sibling module can observe the raise.
      #
      # Capacity is the cap PLUS ONE: the eleven starts below all acquire a permit
      # BEFORE the registry applies its per-owner cap, so the REFUSED eleventh one
      # needs a free permit too (its refusal releases it again). At exactly ten,
      # that eleventh acquisition would block until the real `sleep 30` job exited
      # and the pool freed a slot.
      previous_tool_concurrency = EvoGit.AgentScheduler.get_config(:max_tool_concurrency)
      required_tool_concurrency = BackgroundJobs.max_jobs_per_owner() + 1

      :ok =
        EvoGit.AgentScheduler.update_config(
          max_tool_concurrency: max(previous_tool_concurrency, required_tool_concurrency)
        )

      on_exit(fn ->
        EvoGit.AgentScheduler.update_config(max_tool_concurrency: previous_tool_concurrency)
      end)

      # ONE real detached OS job pins that a real child counts toward the cap; the
      # remaining slots are filled with live `:unit`-handle records (the systemd
      # handle shape, no local child). Releasing capacity through a `:unit` kill is
      # asynchronous (`systemctl --user stop`), so the term→grace→KILL cycle is
      # paid ONCE (for the real job) instead of ten times. The cap itself is
      # registry bookkeeping — it never inspects the handle kind.
      #
      # The child's OWN lifetime is a liveness WINDOW, not a deadline: it must
      # still be running while the other nine slots are filled and the cap is
      # probed. It is killed explicitly below, so a long sleep costs no wall
      # clock — a short one would let a heavily loaded host finish it mid-test and
      # silently drop the live count to nine (the 11th start then succeeds).
      real = start_job!(%{command: "sleep 30", cwd: tmp_dir})

      synthetic =
        for n <- 1..(BackgroundJobs.max_jobs_per_owner() - 1) do
          start_live_unit_job!(tmp_dir, n)
        end

      jobs = [real | synthetic]
      assert length(jobs) == 10
      assert Enum.all?(jobs, &(&1.status == :running))

      assert {:error, message} = BackgroundJobs.start_job(%{command: "sleep 5", cwd: tmp_dir})
      assert message =~ "limit"
      assert message =~ "job_kill"
      assert message =~ "10"

      replies = quiet_kill_all(jobs)

      Enum.each(jobs, fn job ->
        assert {:ok, %{status: :killed}} = Map.fetch!(replies, job.id)
      end)

      # The one real detached child is really gone (the `:unit` records carry no
      # local pid at all).
      assert is_integer(real.handle.os_pid)

      wait_until(
        fn -> not pid_alive?(real.handle.os_pid) end,
        10_000,
        "the job's OS process #{real.handle.os_pid} survived the kill"
      )

      # Capacity is released by killing, so a new job is accepted again.
      job = start_live_unit_job!(tmp_dir, "after-release")
      assert job.status == :running
      # Left live on purpose up to this point; killed here (captured) so the
      # registry's own `terminate/2` sweep at test teardown — which runs OUTSIDE
      # any capture window — has no `:unit` job left to stop.
      assert {:ok, %{status: :killed}} = quiet_kill(job)
    end
  end

  describe "owner death" do
    test "kills the jobs the owner started", %{tmp_dir: tmp_dir} do
      owner = spawn(fn -> Process.sleep(:infinity) end)
      job = start_job!(%{command: "sleep 30", cwd: tmp_dir, owner_pid: owner})
      os_pid = job.handle.os_pid

      Process.exit(owner, :kill)

      killed =
        wait_until_job(
          job.id,
          fn returned -> returned.status == :killed end,
          @deadline_ms,
          "the job was not killed after its owner exited"
        )

      assert killed.detail == "killed (owner_exited)"
      assert %DateTime{} = killed.finished_at

      wait_until(
        fn -> not pid_alive?(os_pid) end,
        @deadline_ms,
        "the job's OS process #{os_pid} survived its owner's death"
      )
    end
  end

  describe "registry shutdown" do
    # Covers the REGISTRY-TEARDOWN layer specifically, not the PRIMARY per-agent
    # guarantee: `init/1` traps exits, so an ordered shutdown (`GenServer.stop/2`,
    # a supervisor `:shutdown`) reaches `terminate/2` — whose "kill every job still
    # live" sweep would otherwise be dead code, killed by the raw exit signal
    # before it runs. The PRIMARY guarantee is the owner-pid `Process.monitor`
    # `:DOWN` path (covered by "owner death" above), and a `systemd` unit
    # deliberately SURVIVES the BEAM that started it (reaped by the next boot's
    # `sweep_stale_units/0`), so teardown here is one layer of defence in depth.
    test "stopping the registry kills a live detached job (terminate/2 runs because the registry traps exits)",
         %{registry: registry, tmp_dir: tmp_dir} do
      job = start_job!(%{command: "sleep 60", cwd: tmp_dir, owner_pid: self()})

      # The handle carries the JOB's OS pid, so everything below is asserted
      # against the real detached child rather than BEAM bookkeeping. `os_pid` is
      # `integer() | nil` (nil for a command that exited before the spawn polled
      # `Port.info(port, :os_pid)`), which is why both branches are kept total.
      assert {:ok, fetched} = BackgroundJobs.job(job.id)
      handle = fetched.handle
      os_pid = handle.os_pid
      assert handle.kind == :port

      # Safety net for the FAILING-assert path: `on_exit` still runs when a later
      # line flunks, so a live `sleep 60` can never be leaked.
      # `EvoGit.Sandbox.Helpers.kill_process_tree/1` is total (never raises).
      on_exit(fn ->
        if is_integer(os_pid), do: EvoGit.Sandbox.Helpers.kill_process_tree(os_pid)
      end)

      # Proving the child is alive FIRST is what makes the teardown assertion
      # meaningful — a job that never started would trivially "be gone".
      if is_integer(os_pid) do
        assert pid_alive?(os_pid)
      end

      # ORDERED shutdown: with `trap_exit` set, `:gen_server` turns this into a
      # real `terminate/2` call. The `start_supervised!` child is `:permanent`, so
      # the test supervisor may restart it — this assertion is about the OS
      # PROCESS, not about the registry staying down, so nothing below checks
      # registry liveness.
      assert :ok = GenServer.stop(registry, :shutdown)

      # Bounded wait that FAILS on the deadline (never an unbounded sleep):
      # `terminate/2` signals the child's process group (TERM, 100 ms grace,
      # KILL) and the BEAM reaps the child only once the port's exit is
      # delivered, so the pid can briefly still answer `kill -0`.
      if is_integer(os_pid) do
        assert wait_until(
                 fn -> not pid_alive?(os_pid) end,
                 @deadline_ms,
                 "expected the detached child (pid #{os_pid}) to be gone after the registry shut down"
               )
      else
        # Total fallback for the no-observed-pid case: assert the handle itself is
        # no longer reported as running.
        assert wait_until(
                 fn -> EvoGit.Sandbox.detached_status(handle) != {:running, nil} end,
                 @deadline_ms,
                 "expected the detached job handle to stop reporting as running after the registry shut down"
               )
      end
    end
  end

  describe "reap_under/1" do
    test "kills only the jobs under the prefix", %{tmp_dir: tmp_dir} do
      target = Path.join(tmp_dir, "reap_target")
      other = Path.join(tmp_dir, "other")
      File.mkdir_p!(target)
      File.mkdir_p!(other)

      # The REAPED job is a real detached child: the assertion that its OS process
      # is gone is what makes `reap_under/1`'s kill real. The untouched neighbour
      # uses the systemd handle shape (no local child, asynchronous stop), so the
      # term→grace→KILL cycle is paid once.
      reaped = start_job!(%{command: "sleep 30", cwd: target})
      kept = start_live_unit_job!(other, "reap-kept")

      assert :ok = BackgroundJobs.reap_under(target)

      assert {:ok, reaped_job} = BackgroundJobs.job(reaped.id)
      assert reaped_job.status == :killed
      assert reaped_job.detail == "killed (reaped)"

      wait_until(
        fn -> not pid_alive?(reaped.handle.os_pid) end,
        @deadline_ms,
        "the reaped job's OS process survived"
      )

      # The unrelated job is untouched and still running.
      assert {:ok, kept_job} = BackgroundJobs.job(kept.id)
      assert kept_job.status == :running

      assert {:ok, %{status: :killed}} = quiet_kill(kept)
    end

    test "is :ok even when no job matches the prefix", %{tmp_dir: tmp_dir} do
      assert :ok = BackgroundJobs.reap_under(Path.join(tmp_dir, "nothing-here"))
      assert :ok = BackgroundJobs.reap_under("/")
    end
  end

  describe "list/1" do
    test "is empty for a fresh registry" do
      assert BackgroundJobs.list() == []
      assert BackgroundJobs.list(owner_pid: self()) == []
    end

    test "includes finished jobs with their status", %{tmp_dir: tmp_dir} do
      job = start_job!(%{command: "echo hello", cwd: tmp_dir})
      _ = await_status!(job.id, :completed)

      assert [listed | _] = BackgroundJobs.list()
      assert listed.id == job.id
      assert listed.status == :completed
      assert listed.exit_code == 0
    end

    test "orders jobs newest first", %{tmp_dir: tmp_dir} do
      older = start_job!(%{command: "echo one", cwd: tmp_dir})
      newer = start_job!(%{command: "echo two", cwd: tmp_dir})

      listed = BackgroundJobs.list()
      assert Enum.map(listed, & &1.id) == [newer.id, older.id]
    end

    test "filters by :owner_pid", %{tmp_dir: tmp_dir} do
      owner = spawn(fn -> Process.sleep(:infinity) end)
      mine = start_job!(%{command: "echo mine", cwd: tmp_dir})
      # Filtering is registry-side; the kill below is only cleanup.
      theirs = start_live_unit_job!(tmp_dir, "list-owner", %{owner_pid: owner})

      assert Enum.map(BackgroundJobs.list(owner_pid: self()), & &1.id) == [mine.id]
      assert Enum.map(BackgroundJobs.list(owner_pid: owner), & &1.id) == [theirs.id]

      assert Enum.sort(Enum.map(BackgroundJobs.list(), & &1.id)) ==
               Enum.sort([mine.id, theirs.id])

      assert {:ok, _} = quiet_kill(theirs)
      Process.exit(owner, :kill)
    end
  end

  describe "snapshot/1 (non-reconciling state read)" do
    test "is owner-scoped, newest first, and capped at 20", %{tmp_dir: tmp_dir} do
      # One at a time: the per-owner LIVE cap is 10, while finished jobs only
      # count toward retention — so sequential short jobs yield 21 finished ones.
      # Each record is created TERMINAL through the production start path with an
      # already-exited `:unit` handle, which is the same record a real command
      # produces (status/exit_code/finished_at/started_at and retention pruning
      # are all registry-side) without spawning 21 shells: this test pins the
      # snapshot's ordering and cap, not detached-process execution (covered by
      # the `completion` / `kill/3` suites against real children).
      ids =
        for n <- 1..21 do
          job = start_terminal_unit_job!(tmp_dir, n)
          job.id
        end

      snapshot = BackgroundJobs.snapshot()
      assert length(snapshot) == 20

      newest_first = Enum.reverse(ids)
      assert Enum.map(snapshot, & &1.id) == Enum.take(newest_first, 20)
      assert Enum.all?(snapshot, &(&1.status == :completed))
    end

    test "excludes another owner's jobs", %{tmp_dir: tmp_dir} do
      owner = spawn(fn -> Process.sleep(:infinity) end)

      mine = start_job!(%{command: "echo mine", cwd: tmp_dir})
      # Owner scoping is registry-side; the kill below is only cleanup.
      theirs = start_live_unit_job!(tmp_dir, "snapshot-owner", %{owner_pid: owner})

      assert Enum.map(BackgroundJobs.snapshot(owner_pid: self()), & &1.id) == [mine.id]
      assert Enum.map(BackgroundJobs.snapshot(owner_pid: owner), & &1.id) == [theirs.id]

      assert {:ok, _} = quiet_kill(theirs)
      Process.exit(owner, :kill)
    end

    test "is a pure state read: no cursor advance, no reconcile, no announced mark", %{
      tmp_dir: tmp_dir
    } do
      job = start_job!(%{command: "echo hello", cwd: tmp_dir})
      _ = await_status!(job.id, :completed)

      first = BackgroundJobs.snapshot()
      second = BackgroundJobs.snapshot()
      assert Enum.map(first, & &1.cursor) == Enum.map(second, & &1.cursor)
      # `read/2` is the only consumer of output: the full text is still pending.
      assert {:ok, %{text: "hello\n"}} = BackgroundJobs.read(job.id)

      # `snapshot/1` never marks a job announced (that is `read/2` / `list/1` only).
      assert [%{announced: false} = snap] = first
      assert snap.id == job.id
    end

    test "is empty for an unknown owner" do
      assert BackgroundJobs.snapshot(owner_pid: spawn(fn -> :ok end)) == []
    end
  end

  describe "claim_finished_notices/1 (exactly-once, owner-scoped)" do
    test "claims only terminal, unannounced jobs and marks them", %{tmp_dir: tmp_dir} do
      finished = start_job!(%{command: "echo done", cwd: tmp_dir})
      _ = await_status!(finished.id, :completed)

      running = start_live_unit_job!(tmp_dir, "claim-running")

      assert {:ok, [claimed]} = BackgroundJobs.claim_finished_notices()
      assert claimed.id == finished.id
      assert claimed.status == :completed
      assert claimed.announced

      # Exactly-once: the claim marked it in registry state.
      assert {:ok, []} = BackgroundJobs.claim_finished_notices()
      assert {:ok, %{announced: true}} = BackgroundJobs.job(finished.id)

      assert {:ok, _} = quiet_kill(running)
    end

    test "returns multiple terminal jobs newest first", %{tmp_dir: tmp_dir} do
      older = start_job!(%{command: "echo one", cwd: tmp_dir})
      _ = await_status!(older.id, :completed)
      newer = start_job!(%{command: "echo two", cwd: tmp_dir})
      _ = await_status!(newer.id, :completed)

      assert {:ok, claimed} = BackgroundJobs.claim_finished_notices()
      assert Enum.map(claimed, & &1.id) == [newer.id, older.id]
      assert {:ok, []} = BackgroundJobs.claim_finished_notices()
    end

    test "never claims a running job", %{tmp_dir: tmp_dir} do
      job = start_live_unit_job!(tmp_dir, "claim-never")

      assert {:ok, []} = BackgroundJobs.claim_finished_notices()
      assert {:ok, []} = BackgroundJobs.claim_finished_notices()

      assert {:ok, _} = quiet_kill(job)
    end

    test "read/2 on a terminal job marks it announced, so a following claim is empty", %{
      tmp_dir: tmp_dir
    } do
      job = start_job!(%{command: "echo hello", cwd: tmp_dir})
      _ = await_status!(job.id, :completed)

      assert {:ok, %{job: read_job}} = BackgroundJobs.read(job.id)
      assert read_job.announced
      assert {:ok, []} = BackgroundJobs.claim_finished_notices()
    end

    test "list/1 on a terminal job marks it announced, so a following claim is empty", %{
      tmp_dir: tmp_dir
    } do
      job = start_job!(%{command: "echo hello", cwd: tmp_dir})
      _ = await_status!(job.id, :completed)

      assert [listed] = BackgroundJobs.list(owner_pid: self())
      assert listed.announced
      assert {:ok, []} = BackgroundJobs.claim_finished_notices()
    end

    test "read/2 and list/1 leave a running job unannounced", %{tmp_dir: tmp_dir} do
      job = start_live_unit_job!(tmp_dir, "unannounced")

      assert {:ok, %{job: read_job}} = BackgroundJobs.read(job.id)
      refute read_job.announced

      assert [listed] = BackgroundJobs.list(owner_pid: self())
      refute listed.announced

      assert {:ok, []} = BackgroundJobs.claim_finished_notices()
      assert {:ok, _} = quiet_kill(job)
    end

    test "kill/3 on a live job suppresses the notice", %{tmp_dir: tmp_dir} do
      job = start_job!(%{command: "sleep 30", cwd: tmp_dir})

      # The agent requested the kill itself, so it already knows the outcome.
      assert {:ok, killed} = BackgroundJobs.kill(job.id)
      assert killed.status == :killed
      assert killed.announced

      assert {:ok, []} = BackgroundJobs.claim_finished_notices()
      # The registry record carries the mark too, so a later turn cannot re-announce it.
      assert {:ok, %{announced: true, status: :killed}} = BackgroundJobs.job(job.id)
    end

    test "kill/3 on an already-finished job returns it announced", %{tmp_dir: tmp_dir} do
      job = start_job!(%{command: "echo done", cwd: tmp_dir})
      _ = await_status!(job.id, :completed)

      assert {:error, {:already_finished, finished}} = BackgroundJobs.kill(job.id)
      assert finished.status == :completed
      assert finished.announced

      assert {:ok, []} = BackgroundJobs.claim_finished_notices()
      assert {:ok, %{announced: true}} = BackgroundJobs.job(job.id)
    end

    test "a killed job's pre-kill output is still readable", %{tmp_dir: tmp_dir} do
      job = start_job!(%{command: "echo before-kill; sleep 30", cwd: tmp_dir})

      wait_until(
        fn -> File.read(job.output_path) == {:ok, "before-kill\n"} end,
        @deadline_ms,
        "the job never wrote its pre-kill output"
      )

      assert {:ok, %{status: :killed}} = BackgroundJobs.kill(job.id)

      assert {:ok, %{text: text, job: read_job}} = BackgroundJobs.read(job.id)
      assert text == "before-kill\n"
      assert read_job.status == :killed
      assert read_job.announced
    end
  end

  describe "registry constants and status vocabulary" do
    test "exposes the documented tunables" do
      assert BackgroundJobs.max_jobs_per_owner() == 10
      assert BackgroundJobs.wait_default_ms() == 120_000
      assert BackgroundJobs.dispatch_headroom_ms() == 25_000
      assert BackgroundJobs.poll_interval_ms() == 100

      # The cap is DERIVED at call time from the scheduler's tool ceiling minus
      # the dispatcher headroom — 30 min − 25 s with the schema defaults.
      assert BackgroundJobs.wait_max_ms() ==
               EvoGit.Config.resolve([:scheduler, :max_tool_timeout]) -
                 BackgroundJobs.dispatch_headroom_ms()

      assert BackgroundJobs.wait_max_ms() == 1_775_000

      # `tick_interval_ms/0` is read at CALL TIME and this module's `setup`
      # shortens it; the documented PRODUCTION default is asserted with the
      # test-only override removed (restored by `on_exit`, so a failure here
      # cannot leak the override).
      Application.delete_env(:evo_git, :background_tick_interval_ms)

      on_exit(fn ->
        Application.put_env(:evo_git, :background_tick_interval_ms, @no_tick_interval_ms)
      end)

      assert BackgroundJobs.tick_interval_ms() == 1_000
    end

    test "renders every status as a string" do
      assert BackgroundJobs.status_string(:running) == "running"
      assert BackgroundJobs.status_string(:stopping) == "stopping"
      assert BackgroundJobs.status_string(:completed) == "completed"
      assert BackgroundJobs.status_string(:killed) == "killed"
      assert BackgroundJobs.status_string(:failed) == "failed"
      assert BackgroundJobs.status_string(nil) == nil
    end

    test "server/0 follows the process-dictionary seam" do
      registry = Process.get(:evogit_background_jobs_server)
      assert BackgroundJobs.server() == registry

      Process.delete(:evogit_background_jobs_server)
      assert BackgroundJobs.server() == EvoGit.BackgroundJobs

      Process.put(:evogit_background_jobs_server, registry)
      assert BackgroundJobs.server() == registry
    end

    test "current_owner_pid/0 follows the process-dictionary seam" do
      assert BackgroundJobs.current_owner_pid() == self()

      Process.delete(:evogit_agent_pid)
      assert BackgroundJobs.current_owner_pid() == nil

      Process.put(:evogit_agent_pid, self())
      assert BackgroundJobs.current_owner_pid() == self()
    end
  end

  # The documented wait-budget defaults, their CALL-TIME seams, and the cap that
  # is DERIVED from the scheduler's tool ceiling on every call. Every test below
  # is a PURE read — no job is started and nothing sleeps — so the only cost is
  # the module's own per-test fixture.
  describe "wait budget tunables" do
    setup do
      # Start from the documented PRODUCTION state (no seam) and always restore
      # whatever was there: both keys are BEAM-globals a concurrent module's
      # `job_output` loop reads at call time.
      for key <- [:background_wait_default_ms, :background_wait_max_ms] do
        previous = Application.get_env(:evo_git, key)
        Application.delete_env(:evo_git, key)

        on_exit(fn ->
          if is_nil(previous) do
            Application.delete_env(:evo_git, key)
          else
            Application.put_env(:evo_git, key, previous)
          end
        end)
      end

      :ok
    end

    test "wait_default_ms/0 defaults to 120_000 and honours the seam at CALL time" do
      # No app env -> the documented production default: the SAME generous budget
      # the foreground shell tool advertises, so one wait settles a slow job.
      assert Application.get_env(:evo_git, :background_wait_default_ms) == nil
      assert BackgroundJobs.wait_default_ms() == 120_000

      # The seam is honoured ...
      put_test_env(:background_wait_default_ms, 350)
      assert BackgroundJobs.wait_default_ms() == 350

      # ... and read on EVERY call, never memoised (a cached read would keep
      # answering 350 here).
      Application.put_env(:evo_git, :background_wait_default_ms, 900)
      assert BackgroundJobs.wait_default_ms() == 900
    end

    test "wait_default_ms/0 ignores an unusable seam value" do
      # Only a non-negative INTEGER is honoured; everything else falls back to
      # the production default instead of raising or producing a junk budget.
      for invalid <- ["350", nil, 350.0, -1] do
        Application.put_env(:evo_git, :background_wait_default_ms, invalid)

        assert BackgroundJobs.wait_default_ms() == 120_000,
               "a #{inspect(invalid)} seam value must fall back to 120_000"
      end
    end

    test "wait_max_ms/0 DERIVES from the scheduler tool ceiling at CALL time" do
      # The cap is not a fixed number: it is the scheduler's hard tool timeout
      # (`[:scheduler, :max_tool_timeout]`, the single source of truth) minus the
      # headroom the dispatcher needs on top of a wait budget. With the isolated
      # test config (no [scheduler] override) that key resolves to its 1_800_000
      # schema default, so the cap is 1_775_000 ms (~29.6 min) — long enough that
      # ONE wait covers a genuinely slow job.
      ceiling = EvoGit.Config.resolve([:scheduler, :max_tool_timeout])
      headroom = BackgroundJobs.dispatch_headroom_ms()

      assert ceiling == 1_800_000
      assert headroom == 25_000
      assert BackgroundJobs.wait_max_ms() == ceiling - headroom
      assert BackgroundJobs.wait_max_ms() == 1_775_000
    end

    test "wait_max_ms/0 honours the `:background_wait_max_ms` seam at CALL time" do
      assert Application.get_env(:evo_git, :background_wait_max_ms) == nil

      put_test_env(:background_wait_max_ms, 500)
      assert BackgroundJobs.wait_max_ms() == 500

      # Read on EVERY call, never memoised.
      Application.put_env(:evo_git, :background_wait_max_ms, 900)
      assert BackgroundJobs.wait_max_ms() == 900

      # The DEFAULT budget seam is independent of the cap.
      put_test_env(:background_wait_default_ms, 350)
      assert BackgroundJobs.wait_default_ms() == 350
      assert BackgroundJobs.wait_max_ms() == 900
    end

    test "wait_max_ms/0 ignores an unusable seam value" do
      # Only a POSITIVE integer is honoured; anything else falls through to the
      # derivation from the scheduler ceiling instead of raising or producing a
      # junk cap.
      derived = BackgroundJobs.wait_max_ms()
      assert derived == 1_775_000

      for invalid <- ["500", nil, 500.0, 0, -1] do
        Application.put_env(:evo_git, :background_wait_max_ms, invalid)

        assert BackgroundJobs.wait_max_ms() == derived,
               "a #{inspect(invalid)} seam value must fall through to the derived cap"
      end
    end
  end

  describe "unreachable registry (totality)" do
    test "start_job/1 and read/2 answer the documented {:error, message} tuple", %{
      tmp_dir: tmp_dir
    } do
      Process.put(:evogit_background_jobs_server, :bg_jobs_missing_xyz)

      # Contract: an unreachable registry yields the documented `{:error, message}`
      # tuple — never a bare string (which would crash the production callers at
      # `agent/tools/shell_tool.ex:229` / `agent/tools/job_output.ex:121`).
      assert {:error, message} = BackgroundJobs.start_job(%{command: "echo hi", cwd: tmp_dir})
      assert message =~ "not running"

      assert {:error, message} = BackgroundJobs.read("bash-0000000000000000")
      assert message =~ "not running"
    end

    test "list/1, job/2, kill/3 and reap_under/1 stay total", %{tmp_dir: tmp_dir} do
      Process.put(:evogit_background_jobs_server, :bg_jobs_missing_xyz)

      # The list-shaped API never raises, and the admin-shaped call always answers.
      assert BackgroundJobs.list() == []
      assert :ok = BackgroundJobs.reap_under(tmp_dir)

      # A registry that is not running knows NOTHING about the id, so `job/2` and
      # `kill/3` report the transport failure honestly instead of pretending the
      # job does not exist (which told an agent "no such job" while its jobs were
      # still running and unkillable through this path).
      assert {:error, :registry_unavailable} = BackgroundJobs.job("bash-0000000000000000")
      assert {:error, :registry_unavailable} = BackgroundJobs.kill("bash-0000000000000000")
      assert {:error, :registry_unavailable} = BackgroundJobs.kill("bash-0000000000000000", "why")

      # The prose read keeps its defined prose contract.
      assert {:error, message} = BackgroundJobs.read("bash-0000000000000000")
      assert message =~ "not running"

      # The two per-turn reads answer their documented empty shapes and never raise.
      assert BackgroundJobs.snapshot() == []
      assert {:ok, []} = BackgroundJobs.claim_finished_notices()
    end
  end

  describe "exit-observer probe (port_open?/1)" do
    test "a live port is open; a closed port and a non-port value are not" do
      port = open_observer_port()
      assert BackgroundJobs.port_open?(port)

      # A CLOSED port answers `nil` from `Port.info/1` (it does not raise) — the
      # path that must answer `false` WITHOUT a rescue, so an unexpected raise
      # can never be reinterpreted as "observer dead".
      EvoGit.Sandbox.Helpers.close_port(port)
      refute BackgroundJobs.port_open?(port)
      refute BackgroundJobs.port_open?(:not_a_port)
      refute BackgroundJobs.port_open?(nil)
    end
  end

  describe "command fidelity" do
    test "a command containing `#` reaches the shell verbatim", %{tmp_dir: tmp_dir} do
      # REGRESSION: the command must be handed to the shell as-is. Wrapping it in
      # an in-shell redirection (`( command ) >> file 2>&1`) turns a trailing
      # comment into a syntax error / swallows the rest of the line.
      job = start_job!(%{command: "echo two # trailing-comment", cwd: tmp_dir})

      completed = await_status!(job.id, :completed)
      assert completed.exit_code == 0

      assert {:ok, %{text: text}} = BackgroundJobs.read(job.id)
      assert text == "two\n"
      refute text =~ "trailing-comment"
    end
  end

  describe "retention and tombstones" do
    # Retention only ever lets a FINISHED record leave the authoritative map, and
    # a finished record whose owner is ALIVE and has not observed the outcome is
    # the ONE shape no ordinary cap may touch: the agent's next `job_output` /
    # `job_list` and its pending completion notice both depend on it. The incident
    # these tests pin is the opposite behaviour — a live agent's just-finished job
    # was deleted while OTHER agents churned past the global cap, so the agent was
    # told no such background job was known to it about a job it had started.
    #
    # The caps are PER-REGISTRY START OPTIONS (there is no app-env or TOML key),
    # so each test starts an EXTRA isolated registry with tiny caps
    # (`start_retention_registry!/2`) and points the
    # `:evogit_background_jobs_server` seam at it; it reuses the SAME isolated
    # `EvoGit.ProcessManager` instance as `setup`, so no job tracking reaches the
    # app-global manager.
    test "keeps a live owner's unobserved record when another owner churns past the cap", %{
      tmp_dir: tmp_dir,
      process_manager: manager
    } do
      # The dead-owner cap is raised ON PURPOSE: with `max_finished_total` as the
      # only tight cap, the GLOBAL valve is the only thing that can evict here, so
      # the survival below is the protection itself and not a per-owner side door.
      _registry =
        start_retention_registry!(manager, %{max_finished_total: 3, max_dead_per_owner: 50})

      owner_a = spawn(fn -> Process.sleep(:infinity) end)
      on_exit(fn -> Process.exit(owner_a, :kill) end)

      mine = start_job!(%{command: "echo alive-owner", cwd: tmp_dir, owner_pid: owner_a})
      completed = await_status!(mine.id, :completed)
      assert completed.exit_code == 0

      # Churn from records no LIVE owner can still read: each owner is dead by the
      # time the NEXT start runs retention, which is what makes them evictable.
      churn = for n <- 1..6, do: start_dead_owner_record!(tmp_dir, n)
      churn_ids = Enum.map(churn, & &1.id)

      # The incident: A's finished, still-unobserved record survives as a PLAIN
      # record — not a tombstone, not `{:error, :not_found}`.
      assert {:ok, kept} = BackgroundJobs.job(mine.id, owner_pid: owner_a)
      assert kept.status == :completed
      assert kept.exit_code == 0
      refute EvoGit.BackgroundJobs.Retention.tombstone?(kept)

      # ORDERING IS LOAD-BEARING: `claim_finished_notices/1`, `read/2` and
      # `list/1` each mark a finished record announced AND delete its
      # notice-mirror row, so the pending notice has to be claimed BEFORE this
      # job is read or listed — afterwards there is nothing left to claim.
      assert {:ok, [claimed]} = BackgroundJobs.claim_finished_notices(owner_pid: owner_a)
      assert claimed.id == mine.id
      assert claimed.status == :completed
      # Exactly once: the claim took the mirror row.
      assert {:ok, []} = BackgroundJobs.claim_finished_notices(owner_pid: owner_a)

      # The output is still fully readable, which is what the protection exists for.
      assert {:ok, %{text: text}} = BackgroundJobs.read(mine.id, owner_pid: owner_a)
      assert text =~ "alive-owner"

      # The churn really was evicted (otherwise the survival above would be
      # vacuous): the oldest churn ids are gone …
      assert {:error, :not_found} = BackgroundJobs.job(Enum.at(churn_ids, 0))
      assert {:error, :not_found} = BackgroundJobs.job(Enum.at(churn_ids, 1))
      # … while the newest one is still an ordinary record.
      newest_id = List.last(churn_ids)
      assert {:ok, newest} = BackgroundJobs.job(newest_id)
      assert newest.id == newest_id
      assert newest.status == :completed
    end

    test "tombstones a protected record at the global valve and answers honestly", %{
      tmp_dir: tmp_dir,
      process_manager: manager
    } do
      _registry = start_retention_registry!(manager, %{max_finished_total: 1})

      original = start_job!(%{command: "echo tombstone-me", cwd: tmp_dir})
      completed = await_status!(original.id, :completed)
      assert completed.exit_code == 0
      output_path = original.output_path

      # ONE more finished record, owned by this (LIVE, still unobserved) test
      # process. Both records are protected, so the valve's excess of one has no
      # evictable record to spend itself on and must convert the OLDEST — the
      # ascending-id tiebreak makes that deterministic — into a tombstone.
      _sibling = start_terminal_unit_job!(tmp_dir, "valve")

      assert {:ok, tombstone} = BackgroundJobs.job(original.id, owner_pid: self())
      assert EvoGit.BackgroundJobs.Retention.tombstone?(tombstone)
      assert tombstone.status == :completed
      assert tombstone.exit_code == 0
      assert tombstone.evicted_reason == :retention
      assert %DateTime{} = tombstone.evicted_at
      assert tombstone.output_path == output_path
      # A tombstone is announced by construction; its notice-mirror row is what
      # still carries the outcome to the owner (`claim` … `{:ok, [tombstone]}`).
      assert tombstone.announced

      # The log file normally OUTLIVES the record, so the tombstone serves it.
      assert {:ok, %{text: "tombstone-me\n"}} =
               BackgroundJobs.read(original.id, owner_pid: self())

      # With the log gone the answer is honest prose about retention — never the
      # "unknown job" sentence that once told an agent its own job never existed.
      File.rm!(output_path)
      assert {:error, message} = BackgroundJobs.read(original.id, owner_pid: self())
      assert message =~ "aged out"
      assert message =~ output_path
      assert message =~ "exit code: 0"
      refute message =~ "No background job with id"

      # `list/1` shows the tombstone beside the ordinary records.
      listed = BackgroundJobs.list(owner_pid: self())
      assert length(listed) == 2
      listed_tombstone = Enum.find(listed, &(&1.id == original.id))
      assert EvoGit.BackgroundJobs.Retention.tombstone?(listed_tombstone)
      assert listed_tombstone.evicted_reason == :retention

      # A tombstone already reached its terminal status: killing it changes nothing.
      assert {:error, {:already_finished, killed}} = BackgroundJobs.kill(original.id)
      assert killed.evicted_reason == :retention

      # `{:error, :not_found}` is reserved for an id this registry NEVER issued.
      assert {:error, :not_found} = BackgroundJobs.job("bash-999", owner_pid: self())

      # A tombstoned id is never REISSUED, even when the id counter is rewound to it.
      :sys.replace_state(registry(), fn state -> %{state | next_id: 1} end)
      fresh = start_live_unit_job!(tmp_dir, "no-reuse")
      refute fresh.id == original.id
      assert {:ok, plain} = BackgroundJobs.job(fresh.id)
      assert plain.id == fresh.id
      refute EvoGit.BackgroundJobs.Retention.tombstone?(plain)

      assert {:ok, _} = quiet_kill(fresh)
    end

    test "the global valve tombstones oldest-first and a tombstone keeps its notice", %{
      tmp_dir: tmp_dir,
      process_manager: manager
    } do
      _registry = start_retention_registry!(manager, %{max_finished_total: 2})

      oldest = start_terminal_unit_job!(tmp_dir, "valve-1")
      second = start_terminal_unit_job!(tmp_dir, "valve-2")
      third = start_terminal_unit_job!(tmp_dir, "valve-3")

      # All three are live-owner UNOBSERVED records, so the third start's prune
      # finds an excess of one and no deletion candidate: the oldest goes.
      assert {:ok, tombstoned} = BackgroundJobs.job(oldest.id, owner_pid: self())
      assert EvoGit.BackgroundJobs.Retention.tombstone?(tombstoned)
      assert tombstoned.evicted_reason == :retention

      for survivor <- [second, third] do
        assert {:ok, job} = BackgroundJobs.job(survivor.id, owner_pid: self())
        assert job.status == :completed
        refute Map.has_key?(job, :evicted_reason)
      end

      # A tombstone deliberately KEEPS its notice-mirror row, so the owner still
      # learns the outcome exactly once through the normal per-turn claim.
      assert {:ok, claimed} = BackgroundJobs.claim_finished_notices(owner_pid: self())
      assert Enum.count(claimed, &(&1.id == oldest.id)) == 1
      assert {:ok, []} = BackgroundJobs.claim_finished_notices(owner_pid: self())

      # The claim is also a retention event; the two survivors are now observed
      # (inside the per-owner observed cap), and the rewound counter still cannot
      # reissue the tombstoned id.
      :sys.replace_state(registry(), fn state -> %{state | next_id: 1} end)
      fresh = start_live_unit_job!(tmp_dir, "valve-no-reuse")
      refute fresh.id == oldest.id

      assert {:ok, _} = quiet_kill(fresh)
    end

    test "the valve deletes dead owners' records before touching a live owner's", %{
      tmp_dir: tmp_dir,
      process_manager: manager
    } do
      _registry =
        start_retention_registry!(manager, %{max_finished_total: 2, max_dead_per_owner: 50})

      mine = start_terminal_unit_job!(tmp_dir, "protected")

      churn = for n <- 1..3, do: start_dead_owner_record!(tmp_dir, "dead-#{n}")
      churn_ids = Enum.map(churn, & &1.id)

      # The excess was spent on DELETIONS of dead owners' records, oldest first …
      assert {:error, :not_found} = BackgroundJobs.job(Enum.at(churn_ids, 0))
      assert {:error, :not_found} = BackgroundJobs.job(Enum.at(churn_ids, 1))
      # … while the live owner's unobserved record is untouched: a plain record
      # with no eviction field, i.e. the valve never had to reach it.
      assert {:ok, kept} = BackgroundJobs.job(mine.id, owner_pid: self())
      assert kept.status == :completed
      refute Map.has_key?(kept, :evicted_reason)
      # And the deletion assertions are not vacuous: the newest churn record is
      # still there.
      newest_id = List.last(churn_ids)
      assert {:ok, newest} = BackgroundJobs.job(newest_id)
      assert newest.id == newest_id
    end

    test "the per-owner observed cap trims the oldest observed records first", %{
      tmp_dir: tmp_dir,
      process_manager: manager
    } do
      _registry =
        start_retention_registry!(manager, %{
          max_observed_per_owner: 2,
          max_finished_total: 100
        })

      ids =
        for n <- 1..4 do
          job = start_terminal_unit_job!(tmp_dir, "observed-#{n}")

          # Announcing exactly this record is what makes it eligible for the
          # per-owner OBSERVED cap; the claim's own retention pass runs before
          # this process's next call (a cast is order-preserving behind a call,
          # as `claim_finished_notices/1` documents).
          assert {:ok, claimed} = BackgroundJobs.claim_finished_notices(owner_pid: self())
          assert Enum.map(claimed, & &1.id) == [job.id]

          job.id
        end

      # Only the two newest observed records remain; the older ones were DELETED
      # (an observed record is never converted into a tombstone).
      assert {:error, :not_found} = BackgroundJobs.job(Enum.at(ids, 0))
      assert {:error, :not_found} = BackgroundJobs.job(Enum.at(ids, 1))

      listed = BackgroundJobs.list(owner_pid: self())
      assert Enum.sort(Enum.map(listed, & &1.id)) == Enum.sort([Enum.at(ids, 2), Enum.at(ids, 3)])
      refute Enum.any?(listed, &EvoGit.BackgroundJobs.Retention.tombstone?/1)
    end

    test "from_opts/1 overlays per key and ignores garbage" do
      defaults = EvoGit.BackgroundJobs.Retention.defaults()

      assert EvoGit.BackgroundJobs.Retention.from_opts(%{max_finished_total: 3}) ==
               %{defaults | max_finished_total: 3}

      assert EvoGit.BackgroundJobs.Retention.from_opts(
               max_tombstones: 2,
               max_dead_per_owner: 1
             ) == %{defaults | max_tombstones: 2, max_dead_per_owner: 1}

      # A malformed option can never DISABLE the policy: every unrecognised key or
      # value leaves that cap at its default.
      for garbage <- [
            nil,
            %{max_finished_total: 0},
            %{max_finished_total: -1},
            %{max_finished_total: "3"},
            %{bogus: 5},
            [{:max_finished_total, :nope}]
          ] do
        assert EvoGit.BackgroundJobs.Retention.from_opts(garbage) == defaults,
               "expected #{inspect(garbage)} to fall back to the retention defaults"
      end
    end
  end

  ## Helpers

  defp start_job!(spec) do
    case BackgroundJobs.start_job(spec) do
      {:ok, job} ->
        track_log!(job)
        job

      {:error, message} ->
        flunk("start_job/1 failed: #{inspect(message)}")
    end
  end

  defp registry, do: Process.get(:evogit_background_jobs_server)

  # `BackgroundJobs.kill/1` for a `:unit`-shaped handle (the systemd stand-ins
  # below), with its console noise captured. `BackgroundJobs` stops such a unit
  # through `Sandbox.Background.stop_unit_async/1`, which spawns an UNLINKED,
  # untracked `Task` around `systemctl --user stop` (the registry must never block
  # on systemctl) and returns at once. Where the user bus is unreachable —
  # containers, CI, this sandbox: "Failed to connect to user scope bus via local
  # transport" — that call FAILS and the task logs
  # `[warning] Sandbox.Background: failed to stop unit …` from a process that is
  # neither the test process nor its child, usually just after the test body
  # ended, i.e. in the gap where ExUnit's per-test `capture_log: true` window is
  # gone and the line would leak to the console.
  #
  # The spawned task is discarded on purpose in production, so there is no handle
  # to await; instead the window WAITS for the `:background_unit_stop_notify` seam
  # installed in `setup`, whose completion message the stop task sends AFTER its
  # systemctl calls — i.e. after the warning line has been handed to the capture
  # handler (which runs synchronously in that task's process, so there is no
  # race). Event-driven: the window lasts exactly as long as the stop, with no
  # fixed margin. `capture_log/2` is WINDOW-based and catches logs from ANY
  # process; this module is `async: false`, so the window cannot swallow a
  # sibling module's lines.
  defp quiet_kill(%{id: id} = job) do
    replies = quiet_kill_all([job])
    Map.fetch!(replies, id)
  end

  # Kills SEVERAL `:unit`-shaped jobs inside ONE console-noise window. Every stop
  # is a fire-and-forget `systemctl --user stop` Task, so issuing them together
  # overlays those round trips instead of paying one full stop per job — which is
  # what filling and draining ten slots costs otherwise. Returns `%{id => reply}`
  # so each caller keeps asserting on the REAL kill result.
  defp quiet_kill_all(jobs) do
    _log =
      ExUnit.CaptureLog.capture_log([level: :warning], fn ->
        # `capture_log/2` returns the LOG, not the function's value, and the fun
        # runs in this process — so the replies travel via the dictionary and the
        # callers keep asserting on the REAL results.
        replies = Enum.map(jobs, fn %{id: id} = job -> {job, BackgroundJobs.kill(id)} end)
        Process.put(@quiet_kill_results, replies)
        Enum.each(replies, fn {job, reply} -> await_unit_stop(reply, job.handle) end)
      end)

    replies = Process.get(@quiet_kill_results) || []
    Process.delete(@quiet_kill_results)

    Map.new(replies, fn {%{id: id}, reply} -> {id, reply} end)
  end

  # A `:unit` stop is asynchronous, so wait for the seam's report — matched on the
  # handle's OWN unit name, so a report left over from an earlier kill in the same
  # test can never be mistaken for this one. A `:port` child is killed
  # synchronously (nothing to await), and a kill that never reached the backend
  # requested no stop.
  defp await_unit_stop(reply, %{kind: :unit, unit: unit}) do
    if stop_requested?(reply) do
      receive do
        {:background_unit_stop_finished, ^unit} -> :ok
      after
        @deadline_ms ->
          flunk("the registry's systemd stop task for #{unit} never reported back")
      end
    else
      :ok
    end
  end

  defp await_unit_stop(_reply, _handle), do: :ok

  # `kill/3` reaches the backend only for a LIVE job; the terminal branches answer
  # `{:error, {:already_finished, job}}`, `{:error, :not_found}` or `:not_owner`.
  defp stop_requested?({:ok, _job}), do: true
  defp stop_requested?({:error, message}) when is_binary(message), do: true
  defp stop_requested?(_reply), do: false

  # Registers a job with the SYSTEMD backend's handle shape (`kind: :unit`, plus
  # the still-open `systemd-run --wait` client port) through the registry's real
  # start path (`start_job_with_handle/2` is the test seam; everything else —
  # spec normalization, output file, owner monitor, tick arming — is production
  # code). `:open` gives the job a live observer port, `:closed` a `port: nil`
  # handle (an observer-less unit).
  defp start_observed_unit_job!(tmp_dir, observer \\ :open) do
    port = if(observer == :open, do: open_observer_port(), else: nil)
    {start_unit_handle_job!(tmp_dir, "observed", %{}, %{port: port}), port}
  end

  # A REAL port owned by the test process, standing in for the long-lived
  # `systemd-run --wait` client (the test env disables the systemd backend, so no
  # client can be spawned). Closed on exit; `close_port/1` is idempotent.
  defp open_observer_port do
    port =
      Port.open(
        {:spawn_executable, System.find_executable(EvoGit.Platform.shell())},
        [:binary, :exit_status, :hide, {:args, EvoGit.Platform.shell_args("sleep 30")}]
      )

    on_exit(fn -> EvoGit.Sandbox.Helpers.close_port(port) end)
    port
  end

  # Registers a LIVE job with the systemd (`:unit`) handle shape and NO local
  # child: `systemctl --user show` answers `{:unknown, _}` for it, so it stays
  # `:running` well inside the default 15 s unreportable floor. Kills on this
  # shape are asynchronous (`systemctl --user stop`), which is what makes it
  # cheap to fill and drain slots. See `start_terminal_unit_job!/3`.
  defp start_live_unit_job!(cwd, tag, spec \\ %{}) do
    start_unit_handle_job!(cwd, tag, spec, %{port: nil})
  end

  # Registers a job that is TERMINAL from the moment it is created: the handle
  # already carries the exit code an exited `systemd-run --wait` client reports,
  # so the production start path settles it immediately (see the "an exit
  # observed during the spawn itself" test). Used where a test needs many finished
  # records and a real shell spawn per record would only add wall clock.
  defp start_terminal_unit_job!(cwd, tag, spec \\ %{}) do
    start_unit_handle_job!(cwd, tag, spec, %{port: nil, pending_exit_code: 0})
  end

  defp start_unit_handle_job!(cwd, tag, spec, handle_extra) do
    handle =
      Map.merge(
        %{
          kind: :unit,
          unit: EvoGit.Sandbox.Background.unit_name("bash-#{tag}"),
          backend: EvoGit.Sandbox.Linux
        },
        handle_extra
      )

    spec =
      Map.merge(%{command: "echo ignored-by-the-stand-in-handle", cwd: cwd}, spec)

    case BackgroundJobs.start_job_with_handle(spec, handle) do
      {:ok, job} ->
        track_log!(job)
        job

      {:error, message} ->
        flunk("start_job_with_handle/2 failed: #{inspect(message)}")
    end
  end

  # Waits until the registry has run one PERIODIC reconcile tick. The tick handler
  # disarms and re-arms its timer, so the registry's `tick_timer` reference changes
  # on every tick — waiting for the change is event-driven (no fixed sleep) and
  # still proves the real timer fired.
  defp await_reconcile_tick!(registry) do
    previous = tick_timer_ref(registry)

    wait_until(
      fn -> tick_timer_ref(registry) != previous end,
      @deadline_ms,
      "the registry never ran a periodic reconcile tick"
    )
  end

  defp tick_timer_ref(registry), do: :sys.get_state(registry).tick_timer

  # Shortens the registry's defensive `{:unknown, _}` floor for one test.
  defp put_unknown_grace(ms) do
    Application.put_env(:evo_git, :background_unknown_grace_ms, ms)
    on_exit(fn -> Application.delete_env(:evo_git, :background_unknown_grace_ms) end)
  end

  # Sets a test-only CALL-TIME app-env override and restores the PREVIOUS value
  # afterwards (nil-aware: a key that was absent is deleted again, so the module
  # never leaks an override into other sync modules).
  defp put_test_env(key, value) do
    original = Application.get_env(:evo_git, key)

    Application.put_env(:evo_git, key, value)

    on_exit(fn ->
      if is_nil(original) do
        Application.delete_env(:evo_git, key)
      else
        Application.put_env(:evo_git, key, original)
      end
    end)
  end

  # Installs the per-task tmpdir seam on the TEST process — the same
  # process-dictionary seam `EvoGit.ToolRuntime` installs in every tool task —
  # so `BackgroundJobs.start_job/1` resolves the scratch dir and the child's
  # `TMPDIR` from it. The test process's dictionary dies with the test; the
  # `on_exit` clear is the documented restore contract (it runs in a different
  # process, so it is belt-and-braces only).
  defp put_task_tmpdir(dir) do
    assert :ok = EvoGit.TaskTmpdir.put_current(dir)
    on_exit(fn -> EvoGit.TaskTmpdir.put_current(nil) end)
  end

  # Polls `job/2` until the job's status is `expected`, then returns the returned
  # (reconciled) record. Completion of a `:port` job arrives as a port message, so
  # this is the only sound way to observe it — a one-shot read could still see
  # `:running`.
  defp await_status!(id, expected, timeout \\ @deadline_ms) do
    wait_until_job(
      id,
      fn job -> job.status == expected end,
      timeout,
      "job #{id} never reached status #{inspect(expected)} (last detail: #{inspect(last_detail(id))})"
    )
  end

  defp wait_until_job(id, predicate, timeout, message) do
    wait_until(
      fn ->
        case BackgroundJobs.job(id) do
          {:ok, job} -> predicate.(job)
          _ -> false
        end
      end,
      timeout,
      message
    )

    {:ok, job} = BackgroundJobs.job(id)
    job
  end

  defp last_detail(id) do
    case BackgroundJobs.job(id) do
      {:ok, %{detail: detail, status: status}} -> {status, detail}
      other -> other
    end
  end

  # Reads the whole remaining output `max_reads` calls at a time, stripping the
  # pending marker from every capped chunk. Returns the ordered chunks plus the
  # final job record. `max_bytes` is the per-call cap: the EXACT cap contract is
  # asserted separately (one 10-byte read), so the drain itself only has to prove
  # nothing is lost — a 10-byte chunk there would mean ~900 registry calls.
  defp drain(id, acc, max_reads, max_bytes \\ 10)

  defp drain(id, acc, 0, _max_bytes) do
    flunk("draining #{id} exhausted the read budget; accumulated #{length(acc)} chunks")
  end

  defp drain(id, acc, max_reads, max_bytes) do
    case BackgroundJobs.read(id, max_bytes: max_bytes) do
      {:ok, %{text: text, job: job}} ->
        cond do
          String.ends_with?(text, @pending_marker) ->
            chunk = String.replace_suffix(text, @pending_marker, "")
            drain(id, [chunk | acc], max_reads - 1)

          text == "" ->
            {Enum.reverse(acc), job}

          true ->
            {Enum.reverse([text | acc]), job}
        end

      {:error, message} ->
        flunk("read/2 failed while draining #{id}: #{inspect(message)}")
    end
  end

  defp wait_until(fun, timeout, message) do
    deadline = System.monotonic_time(:millisecond) + timeout
    do_wait_until(fun, deadline, timeout, message, @poll_first_ms)
  end

  defp do_wait_until(fun, deadline, timeout, message, poll_ms) do
    cond do
      fun.() ->
        :ok

      System.monotonic_time(:millisecond) < deadline ->
        Process.sleep(poll_ms)
        do_wait_until(fun, deadline, timeout, message, min(poll_ms * 2, @poll_max_ms))

      true ->
        flunk("timed out after #{timeout}ms: #{message}")
    end
  end

  # POSIX liveness probe for a job's os_pid. `kill -0` succeeds while the pid
  # exists (including as an unreaped zombie), so callers must POLL this rather
  # than assert it once right after a kill.
  defp pid_alive?(pid) when is_integer(pid) do
    case System.cmd("kill", ["-0", Integer.to_string(pid)], stderr_to_stdout: true) do
      {_output, 0} -> true
      {_output, _code} -> false
    end
  end

  # Per-JOB output-file hygiene: the registry decides `output_path` at spawn time
  # and returns it on the record, so the cleanup is EXACT (one `File.rm`) and
  # never lists the scratch directory, which other registries may share. Registered
  # when the job starts, so it also covers a test that flunks before its own
  # final assertions.
  defp track_log!(%{output_path: path}) when is_binary(path) do
    on_exit(fn -> _ = File.rm(path) end)
    :ok
  end

  # An EXTRA isolated registry with tiny retention caps, which this test process
  # is then pointed at. The caps are START OPTIONS (no app-env or TOML key exists
  # for them), so a second instance is the only way to drive them, and the `id:`
  # override is REQUIRED because `EvoGit.BackgroundJobs` has no custom
  # `child_spec/1` — two children of one supervisor would otherwise share the
  # module id. The caller passes the SAME isolated `EvoGit.ProcessManager` as
  # `setup`, for the same no-app-global-tracking reason.
  defp start_retention_registry!(process_manager, retention) do
    name = :"bg_jobs_retention_#{System.unique_integer([:positive])}"

    start_supervised!(
      Supervisor.child_spec(
        {EvoGit.BackgroundJobs,
         [name: name, process_manager: process_manager, retention: retention]},
        id: name
      )
    )

    Process.put(:evogit_background_jobs_server, name)
    name
  end

  # A FINISHED record whose owner is DEAD by the time the NEXT accepted start runs
  # retention, i.e. an evictable record no owner can read or be notified about.
  # The owner must be ALIVE at start time — the production start path refuses a
  # spec whose `owner_pid` has already exited — so it is started, used for one
  # terminal record and then killed.
  defp start_dead_owner_record!(cwd, tag) do
    owner = spawn(fn -> Process.sleep(:infinity) end)
    job = start_terminal_unit_job!(cwd, tag, %{owner_pid: owner})

    Process.exit(owner, :kill)

    wait_until(
      fn -> not Process.alive?(owner) end,
      @deadline_ms,
      "the throw-away owner #{inspect(owner)} of #{job.id} never exited"
    )

    job
  end
end
