defmodule EvoGit.BackgroundJobsTest do
  # async: false — every test drives REAL OS processes (the sandbox backend is
  # disabled in the test env, so each job is a plain `Port.open/2` child through
  # the platform shell) and they all share the ONE process-wide scratch
  # directory `<sandbox tmpdir>/genesis`, where each job writes
  # `genesis_job_<id>.log`. The file-hygiene snapshot/restore below is only sound
  # because the sync phase runs one module at a time, so no other module can
  # create a `genesis_job_*.log` between the snapshot and the cleanup; and the
  # liveness probes (`kill -0`, real `sleep` children) are host-process global.
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

  setup %{tmp_dir: tmp_dir} do
    name = :"bg_jobs_test_#{System.unique_integer([:positive])}"

    # An ISOLATED registry per test: the test supervisor guarantees a graceful
    # shutdown, whose `terminate/2` kills every job still live.
    start_supervised!({EvoGit.BackgroundJobs, [name: name]})

    Process.put(:evogit_background_jobs_server, name)
    Process.put(:evogit_agent_pid, self())

    jobs_dir = Path.join(EvoGit.Sandbox.resolve_tmpdir(), "genesis")
    logs_before = job_log_files(jobs_dir)

    on_exit(fn ->
      # `on_exit` runs in a DIFFERENT process, so the process dictionary these
      # deletes touch is not the test process's — the test process's own keys die
      # with it. Kept as belt-and-braces for the seam contract.
      Process.delete(:evogit_agent_pid)
      Process.delete(:evogit_background_jobs_server)

      # Safe because this module is `async: false`: no other module can be
      # creating job logs while we hold the sync phase.
      remove_new_job_logs(jobs_dir, logs_before)
    end)

    %{jobs_dir: jobs_dir, registry: name, tmp_dir: tmp_dir}
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

      {chunks, last} = drain(job.id, [first_chunk], 1_000)
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
      job = start_job!(%{command: "sleep 30", cwd: tmp_dir, owner_pid: owner})

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

      assert {:ok, %{status: :killed}} = BackgroundJobs.kill(job.id)
      Process.exit(owner, :kill)
    end
  end

  describe "per-owner job cap" do
    test "refuses an 11th live job and reports the limit", %{tmp_dir: tmp_dir} do
      jobs =
        for _ <- 1..BackgroundJobs.max_jobs_per_owner() do
          start_job!(%{command: "sleep 5", cwd: tmp_dir})
        end

      assert length(jobs) == 10
      assert Enum.all?(jobs, &(&1.status == :running))

      assert {:error, message} = BackgroundJobs.start_job(%{command: "sleep 5", cwd: tmp_dir})
      assert message =~ "limit"
      assert message =~ "job_kill"
      assert message =~ "10"

      os_pids =
        Enum.map(jobs, fn job ->
          assert {:ok, %{status: :killed}} = BackgroundJobs.kill(job.id)
          job.handle.os_pid
        end)

      wait_until(
        fn -> Enum.all?(os_pids, &(not pid_alive?(&1))) end,
        10_000,
        "some job OS processes survived the kills: #{inspect(os_pids)}"
      )

      # Capacity is released by killing, so a new job is accepted again.
      job = start_job!(%{command: "echo hi", cwd: tmp_dir})
      assert {:ok, %{status: :killed}} = BackgroundJobs.kill(job.id)
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

  describe "reap_under/1" do
    test "kills only the jobs under the prefix", %{tmp_dir: tmp_dir} do
      target = Path.join(tmp_dir, "reap_target")
      other = Path.join(tmp_dir, "other")
      File.mkdir_p!(target)
      File.mkdir_p!(other)

      reaped = start_job!(%{command: "sleep 30", cwd: target})
      kept = start_job!(%{command: "sleep 30", cwd: other})

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
      assert pid_alive?(kept.handle.os_pid)

      assert {:ok, %{status: :killed}} = BackgroundJobs.kill(kept.id)

      wait_until(
        fn -> not pid_alive?(kept.handle.os_pid) end,
        @deadline_ms,
        "the unrelated job's OS process survived its kill"
      )
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
      theirs = start_job!(%{command: "sleep 30", cwd: tmp_dir, owner_pid: owner})

      assert Enum.map(BackgroundJobs.list(owner_pid: self()), & &1.id) == [mine.id]
      assert Enum.map(BackgroundJobs.list(owner_pid: owner), & &1.id) == [theirs.id]

      assert Enum.sort(Enum.map(BackgroundJobs.list(), & &1.id)) ==
               Enum.sort([mine.id, theirs.id])

      assert {:ok, _} = BackgroundJobs.kill(theirs.id)
      Process.exit(owner, :kill)
    end
  end

  describe "registry constants and status vocabulary" do
    test "exposes the documented tunables" do
      assert BackgroundJobs.max_jobs_per_owner() == 10
      assert BackgroundJobs.wait_default_ms() == 8_000
      assert BackgroundJobs.wait_max_ms() == 60_000
      assert BackgroundJobs.poll_interval_ms() == 100
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

      # FINDING (observed vs expected, reported rather than papered over): both
      # functions are specified and documented as returning `{:error, String.t()}`
      # ("... one actionable prose sentence ... unreachable registry") and BOTH
      # production callers pattern-match exactly `{:error, message}`
      # (`agent/tools/shell_tool.ex:229`, `agent/tools/job_output.ex:121`), but the
      # dead-registry fallback is passed WITHOUT the tuple wrapper
      # (`call_registry({:start_job, ...}, registry_down_error())` /
      # `call_registry({:read, ...}, registry_down_error())` — background_jobs.ex:111,136),
      # so a bare binary is returned here and those callers hit a CaseClauseError —
      # the crash the module doc promises a dead registry can never cause.
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
      {:ok, job} -> job
      {:error, message} -> flunk("start_job/1 failed: #{inspect(message)}")
    end
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
  # final job record.
  defp drain(id, acc, 0) do
    flunk("draining #{id} exhausted the read budget; accumulated #{length(acc)} chunks")
  end

  defp drain(id, acc, max_reads) do
    case BackgroundJobs.read(id, max_bytes: 10) do
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
    do_wait_until(fun, deadline, timeout, message)
  end

  defp do_wait_until(fun, deadline, timeout, message) do
    cond do
      fun.() ->
        :ok

      System.monotonic_time(:millisecond) < deadline ->
        Process.sleep(20)
        do_wait_until(fun, deadline, timeout, message)

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

  defp job_log_files(dir) do
    case File.ls(dir) do
      {:ok, files} ->
        files
        |> Enum.filter(&String.starts_with?(&1, "genesis_job_"))
        |> MapSet.new()

      {:error, _reason} ->
        # The scratch dir may not exist yet (no job has ever run on this host).
        MapSet.new()
    end
  end

  defp remove_new_job_logs(dir, before) do
    dir
    |> job_log_files()
    |> MapSet.difference(before)
    |> Enum.each(fn file ->
      # Best effort: the file may already be gone (the registry never recreates it).
      _ = File.rm(Path.join(dir, file))
      :ok
    end)
  end
end
