defmodule EvoGit.BackgroundJobsTest do
  # async: false — tests drive REAL OS processes (the sandbox backend is
  # disabled in the test env, so each job is a plain `Port.open/2` child through
  # the platform shell; where only registry bookkeeping is under test, a job is
  # registered through the same production start path with a systemd `:unit`
  # stand-in handle instead) and they all share the ONE process-wide scratch
  # directory (`<sandbox tmpdir>`), where each job writes `genesis_job_<id>.log`.
  # File hygiene is per JOB, not per directory window: the registry returns the
  # exact `:output_path` it created, so every job start registers an `on_exit`
  # that removes that ONE file — never a `File.ls` of a scratch directory the
  # whole host shares (thousands of entries = milliseconds per listing). The
  # liveness probes (`kill -0`, real `sleep` children) are host-process global,
  # which is why this module must stay in the sync phase.
  #
  # The suite is POSIX-oriented by construction: `pid_alive?/1` probes with
  # `kill -0` and the fixtures are `sh` command lines (`sleep`, `seq`, `echo`),
  # matching what the disabled-backend port path spawns on this host.
  use ExUnit.Case, async: false

  alias EvoGit.BackgroundJobs

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
    start_supervised!({EvoGit.BackgroundJobs, [name: name]})

    Process.put(:evogit_background_jobs_server, name)
    Process.put(:evogit_agent_pid, self())

    on_exit(fn ->
      # `on_exit` runs in a DIFFERENT process, so the process dictionary these
      # deletes touch is not the test process's — the test process's own keys die
      # with it. Kept as belt-and-braces for the seam contract.
      Process.delete(:evogit_agent_pid)
      Process.delete(:evogit_background_jobs_server)
    end)

    %{registry: name, tmp_dir: tmp_dir}
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

      assert job.id =~ ~r/\Abash-[0-9a-f]{16}\z/
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
    test "refuses an 11th live job and reports the limit", %{tmp_dir: tmp_dir} do
      # ONE real detached OS job pins that a real child counts toward the cap; the
      # remaining slots are filled with live `:unit`-handle records (the systemd
      # handle shape, no local child). Releasing capacity through a `:unit` kill is
      # asynchronous (`systemctl --user stop`), so the term→grace→KILL cycle is
      # paid ONCE (for the real job) instead of ten times. The cap itself is
      # registry bookkeeping — it never inspects the handle kind.
      real = start_job!(%{command: "sleep 5", cwd: tmp_dir})

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
      assert BackgroundJobs.wait_default_ms() == 8_000
      assert BackgroundJobs.wait_max_ms() == 60_000
      assert BackgroundJobs.poll_interval_ms() == 100

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

      # `job/2` keeps its semantic tuple, and `kill/3` falls back to its documented
      # `{:error, :not_found}` for an unreachable registry (module doc: "the
      # ownership/finished probes in `job/2` and `kill/3` keep the small semantic
      # tuples"; `kill/3`'s spec names "unknown id, or an unreachable registry").
      assert {:error, :not_found} = BackgroundJobs.job("bash-0000000000000000")
      assert {:error, :not_found} = BackgroundJobs.kill("bash-0000000000000000")

      # The two per-turn reads answer their documented empty shapes and never raise.
      assert BackgroundJobs.snapshot() == []
      assert {:ok, []} = BackgroundJobs.claim_finished_notices()
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
  defp drain(id, acc, 0, _max_bytes) do
    flunk("draining #{id} exhausted the read budget; accumulated #{length(acc)} chunks")
  end

  defp drain(id, acc, max_reads, max_bytes \\ 10) do
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
  # never lists the scratch directory, which the whole host shares. Registered
  # when the job starts, so it also covers a test that flunks before its own
  # final assertions.
  defp track_log!(%{output_path: path}) when is_binary(path) do
    on_exit(fn -> _ = File.rm(path) end)
    :ok
  end
end
