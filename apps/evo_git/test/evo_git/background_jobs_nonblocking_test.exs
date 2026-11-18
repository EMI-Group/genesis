defmodule EvoGit.BackgroundJobsNonblockingTest do
  @moduledoc """
  The two non-blocking guarantees of the background-job platform, asserted
  against a REAL registry:

    * `EvoGit.BackgroundJobs.claim_finished_notices/1` — the call every agent
      turn makes — is a pure `:ets` read of the notice mirror, so it answers
      while the registry process is unable to run (suspended); and
    * a `:unit` handle's OS status probe (`systemctl --user show`) runs in its
      OWN unlinked task, never inside the registry, so a read/claim issued while
      a probe is in flight is answered immediately instead of waiting for the
      subprocess.
  """
  # async: false — this module writes BEAM-GLOBAL call-time seams
  # (`:background_status_probe_fun`, `:background_probe_min_interval_ms`,
  # `:background_tick_interval_ms`, `:process_stats_enabled`) that a concurrent
  # module's `job/2` / probe path would read.
  use ExUnit.Case, async: false

  alias EvoGit.BackgroundJobs

  @moduletag :tmp_dir

  @deadline_ms 5_000
  @poll_first_ms 1
  @poll_max_ms 20
  # A claim answers from ETS in microseconds; this bound only proves the registry
  # is not on the path (the pre-fix baseline with a suspended registry was the
  # full 15 000 ms `GenServer.call` timeout), with headroom for a loaded host.
  @nonblocking_ms 250

  setup %{tmp_dir: tmp_dir} do
    name = :"bg_jobs_nonblocking_#{System.unique_integer([:positive])}"
    # The periodic tick is DISARMED by default here: every test that wants a probe
    # kicks it through a read, which is the path under test.
    put_test_env(:background_tick_interval_ms, 3_600_000)
    put_test_env(:process_stats_enabled, false)

    manager = :"bg_jobs_nonblocking_pm_#{System.unique_integer([:positive])}"
    start_supervised!({EvoGit.ProcessManager, name: manager})
    start_supervised!({EvoGit.BackgroundJobs, [name: name, process_manager: manager]})

    Process.put(:evogit_background_jobs_server, name)
    Process.put(:evogit_agent_pid, self())

    on_exit(fn ->
      Process.delete(:evogit_agent_pid)
      Process.delete(:evogit_background_jobs_server)
    end)

    %{registry: name, tmp_dir: tmp_dir, process_manager: manager}
  end

  describe "claim_finished_notices/1 (never serialized behind the registry)" do
    test "answers from the mirror while the registry process is SUSPENDED", %{
      tmp_dir: tmp_dir,
      registry: registry
    } do
      job = start_job!(%{command: "echo done", cwd: tmp_dir})
      _completed = await_status!(job.id, :completed)

      :ok = :sys.suspend(registry)

      try do
        {us, claim} =
          :timer.tc(fn -> BackgroundJobs.claim_finished_notices(owner_pid: self()) end)

        # The ready job is still claimed (with its announced mark) while the
        # registry cannot run a single callback.
        assert {:ok, [claimed]} = claim
        assert claimed.id == job.id
        assert claimed.status == :completed
        assert claimed.announced
        assert us < @nonblocking_ms * 1000

        # Exactly-once holds too: the atomic `:ets.take/2` removed the row.
        {us2, second} =
          :timer.tc(fn -> BackgroundJobs.claim_finished_notices(owner_pid: self()) end)

        assert second == {:ok, []}
        assert us2 < @nonblocking_ms * 1000
      after
        :sys.resume(registry)
      end
    end

    test "is exactly-once under CONCURRENT claims from several processes", %{
      tmp_dir: tmp_dir,
      registry: registry
    } do
      job = start_job!(%{command: "echo done", cwd: tmp_dir})
      _completed = await_status!(job.id, :completed)

      owner = self()

      claims =
        1..8
        |> Enum.map(fn _ ->
          Task.async(fn ->
            # The server seam is a PROCESS-dictionary key, so each claimant sets it.
            Process.put(:evogit_background_jobs_server, registry)
            BackgroundJobs.claim_finished_notices(owner_pid: owner)
          end)
        end)
        |> Task.await_many(@deadline_ms)

      claimed_ids = for {:ok, jobs} <- claims, job <- jobs, do: job.id
      assert claimed_ids == [job.id]
      assert Enum.count(claims, &match?({:ok, [_]}, &1)) == 1
    end
  end

  describe "status probes (never inside the registry process)" do
    test "a :unit probe runs off-process, so reads and claims answer while it is in flight", %{
      tmp_dir: tmp_dir,
      registry: registry
    } do
      test_pid = self()

      # The probe seam BLOCKS until this test releases it, so the registry's
      # responsiveness is measured against a genuinely in-flight probe.
      put_test_env(:background_status_probe_fun, fn _handle ->
        send(test_pid, {:probe_started, self()})

        receive do
          {:finish_probe, reply} -> reply
        after
          @deadline_ms -> {:unknown, nil}
        end
      end)

      # Always probe, so one read is enough to schedule it.
      put_test_env(:background_probe_min_interval_ms, 0)

      job = start_live_unit_job!(tmp_dir, "probe-offprocess")

      {us, read} = :timer.tc(fn -> BackgroundJobs.read(job.id) end)
      assert {:ok, %{job: %{status: :running}}} = read
      assert us < @nonblocking_ms * 1000

      assert_receive {:probe_started, probe_pid}, @deadline_ms
      # The OS probe ran in its OWN process, not in the registry.
      refute probe_pid == registry

      # While the probe is still blocked, the registry keeps answering: a claim
      # (ETS-only) and even a `:sys` call that must enter the process.
      {us2, claim} = :timer.tc(fn -> BackgroundJobs.claim_finished_notices(owner_pid: self()) end)
      assert claim == {:ok, []}
      assert us2 < @nonblocking_ms * 1000

      {us3, state} = :timer.tc(fn -> :sys.get_state(registry, @deadline_ms) end)
      assert is_map(state)
      assert us3 < @nonblocking_ms * 1000

      {us4, _read_again} = :timer.tc(fn -> BackgroundJobs.read(job.id) end)
      assert us4 < @nonblocking_ms * 1000

      # A not-yet-answered probe never invents a status: the job is still running.
      assert {:ok, %{status: :running}} = BackgroundJobs.job(job.id)

      # Release it: the reported exit settles the job with no further read.
      send(probe_pid, {:finish_probe, {:exited, 0}})
      completed = await_status!(job.id, :completed)
      assert completed.exit_code == 0
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

  # A LIVE job with the systemd (`:unit`) handle shape and no local child: its
  # status can only come from a probe (the real `systemctl --user show` in
  # production, the seam above here).
  defp start_live_unit_job!(cwd, tag) do
    handle = %{
      kind: :unit,
      unit: EvoGit.Sandbox.Background.unit_name("bash-#{tag}"),
      backend: EvoGit.Sandbox.Linux,
      port: nil
    }

    case BackgroundJobs.start_job_with_handle(
           %{command: "echo ignored-by-the-stand-in-handle", cwd: cwd},
           handle
         ) do
      {:ok, job} ->
        track_log!(job)
        job

      {:error, message} ->
        flunk("start_job_with_handle/2 failed: #{inspect(message)}")
    end
  end

  defp await_status!(id, expected) do
    wait_until(
      fn ->
        case BackgroundJobs.job(id) do
          {:ok, job} -> job.status == expected
          _other -> false
        end
      end,
      @deadline_ms,
      "job #{id} never reached status #{inspect(expected)}"
    )

    {:ok, job} = BackgroundJobs.job(id)
    job
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

  defp track_log!(%{output_path: path}) when is_binary(path) do
    on_exit(fn -> _ = File.rm(path) end)
    :ok
  end

  # Sets a test-only CALL-TIME app-env override and restores the PREVIOUS value
  # afterwards (nil-aware), so this sync module never leaks a seam.
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
end
