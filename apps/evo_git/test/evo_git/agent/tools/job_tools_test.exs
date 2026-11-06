defmodule EvoGit.Agent.Tools.JobToolsTest do
  @moduledoc """
  `async: false` — every test starts its OWN isolated `EvoGit.BackgroundJobs`
  registry under a unique registered name (reached through the
  `:evogit_background_jobs_server` process-dictionary seam) and spawns REAL
  detached OS processes through the platform shell, whose output files land in
  the SHARED scratch directory (`EvoGit.Sandbox.resolve_tmpdir/0`). An isolated
  GenServer, real OS child processes and a scratch directory shared with the
  rest of the BEAM/host are all BEAM-global, so this module must never run
  concurrently with another module.

  It also writes the app-env `:background_wait_default_ms` / `:background_wait_max_ms`
  call-time seams (the `job_output` wait's default budget and its cap) for the
  budget tests, which is one more BEAM-global a concurrent module could observe;
  the production defaults (120 000 ms default, scheduler-derived cap) are
  unchanged and restored after every test.

  This suite PINS the shipped behaviour of the background-job tool surface —
  it is a characterisation suite, not a design:

    * `job_output` / `job_list` / `job_kill` schemas and result strings
      (including the `[status: …]` line and the `Error: …` failure shape),
    * the shell tool's `run_in_background` mode (job id result string, label,
      "no timeout applies", the main-copy mutation hard block),
    * the classification/guard surface the mode depends on
      (`Tools.write_call?/2`, `Tools.background_start?/1`,
      `Tools.serial_tool?/1` and the repo-less guard's background-specific
      message).

  Hygiene: no test may hang or leak. Every wait is event-driven (bounded poll,
  never a fixed sleep used as the assertion), every long job is killed and its
  OS pid reaped before the test ends, and every job start registers an `on_exit`
  that removes that job's OWN `genesis_job_*.log` — the path the registry
  returns on the record, so the cleanup is exact and never lists the scratch
  directory (which can hold thousands of unrelated entries on a busy host).
  """
  use ExUnit.Case, async: false

  alias EvoGit.Agent.Tools
  alias EvoGit.Agent.Tools.JobKill
  alias EvoGit.Agent.Tools.JobList
  alias EvoGit.Agent.Tools.JobOutput
  alias EvoGit.Agent.Tools.ShellTool
  alias EvoGit.BackgroundJobs

  @moduletag :tmp_dir

  @job_tools ["job_output", "job_list", "job_kill"]

  # The job_output tool's own dispatch default (see `Tools.default_timeout_ms/1`)
  # is DERIVED AT RUNTIME — `EvoGit.BackgroundJobs.wait_max_ms/0` (the configured
  # scheduler tool ceiling minus the dispatcher headroom) plus that headroom
  # added straight back — so it is read through `job_output_default_timeout_ms/0`
  # below, never a compile-time attribute (which would freeze the cap at build
  # time). A bounded `wait: true` legitimately blocks up to the wait cap inside
  # the tool; that derived value is a CEILING for the real block, NOT a latency
  # race, and it is never waited out — every test below pins a SMALL budget.

  # Poll cadence for every wait below (see `wait_until/2`): tight at first, then
  # relaxed so a genuinely slow condition does not spin. The wait's own deadline
  # stays the only bound. The floor is 1 ms because each poll is a 30 µs registry
  # read, while the condition itself (a shell child's ~3 ms lifetime) is the cost.
  @poll_first_ms 1
  @poll_max_ms 20

  # Test-only CALL-TIME seam (`EvoGit.BackgroundJobs.poll_interval_ms/0`): the
  # caller-side `wait: true` loop sleeps this long between `job/2` polls, so the
  # production 100 ms would make every settled wait pay a full interval. The
  # production default is unchanged; the wait's own `timeout_ms` budget is what
  # the timed-out case exercises.
  @poll_interval_ms_override 5

  # The wait budget these tests pin explicitly: small enough that the whole
  # budget/marker coverage costs ~2 s, large enough that `elapsed` proves WHICH
  # budget the tool used (the 8000 ms default would be unmistakable).
  @wait_budget_ms 300
  @wait_budget_lower_bound_ms 250
  @wait_elapsed_ceiling_ms 5_000

  # The value the default-budget tests install on the call-time seam
  # `:background_wait_default_ms` (production `wait_default_ms/0` is 8000 ms).
  @wait_default_seam_ms 350

  setup do
    registry = :"job_tools_test_#{System.unique_integer([:positive])}"

    # Test-only CALL-TIME seam (`EvoGit.Sandbox.Helpers`): the SIGTERM→SIGKILL
    # grace is shortened to 0 ms — every liveness assertion below polls until the
    # OS confirms the child is genuinely gone, so the grace buys nothing here. The
    # production default (100 ms) is unchanged.
    put_test_env(:kill_grace_ms, 0)
    put_test_env(:background_poll_interval_ms, @poll_interval_ms_override)

    # Its `terminate/2` kills every job still live when the test ends.
    start_supervised!({EvoGit.BackgroundJobs, [name: registry]})

    # The two process-dictionary seams the job tools read at CALL time: the
    # isolated registry name, and the OWNING agent pid — so
    # `BackgroundJobs.current_owner_pid/0` binds this test's jobs to the test
    # process and the tools' ownership fence compares against it.
    Process.put(:evogit_background_jobs_server, registry)
    Process.put(:evogit_agent_pid, self())

    on_exit(fn ->
      # Belt and braces: this callback runs in a DIFFERENT process, so the test
      # process's own dictionary already dies with it. Clear the three keys the
      # tools and the guards read anyway.
      Process.delete(:evogit_agent_pid)
      Process.delete(:evogit_background_jobs_server)
      Process.delete(:repo_less)
    end)

    %{registry: registry}
  end

  # Sets a test-only CALL-TIME app-env override and restores the PREVIOUS value
  # afterwards (nil-aware: a key that was absent is deleted again).
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

  ## Scratch-directory hygiene

  # A job's output file is `<scratch dir>/genesis_job_<job_id>.log`
  # (`EvoGit.BackgroundJobs.scratch_dir/0` = `EvoGit.Sandbox.resolve_tmpdir/0`).
  # The scratch dir is shared with the whole host, so a window-style
  # snapshot/restore would have to `File.ls` it — a directory that legitimately
  # holds thousands of unrelated entries, i.e. milliseconds per listing, twice
  # per test. Instead every job start registers the EXACT path the registry
  # returned on the record, so the cleanup is one `File.rm` per job this test
  # created and can never touch another test's (or the host's) files.
  defp track_log!(%{output_path: path}) when is_binary(path) do
    # Registered when the job STARTS, so the cleanup also covers a test that
    # flunks before reaching its own final assertions.
    on_exit(fn -> _ = File.rm(path) end)
    :ok
  end

  ## Event-driven waits (never a fixed sleep as the assertion)

  defp wait_until(fun, timeout \\ 15_000) do
    deadline = System.monotonic_time(:millisecond) + timeout
    do_wait_until(fun, deadline, timeout, @poll_first_ms)
  end

  defp do_wait_until(fun, deadline, timeout, poll_ms) do
    result = fun.()

    cond do
      result ->
        result

      System.monotonic_time(:millisecond) >= deadline ->
        flunk("the awaited condition was not reached within #{timeout} ms")

      true ->
        Process.sleep(poll_ms)
        do_wait_until(fun, deadline, timeout, min(poll_ms * 2, @poll_max_ms))
    end
  end

  ## Timing (the budget a wait actually used)

  # `{result, elapsed_ms}` around a call whose OWN budget is what the elapsed
  # bounds prove: a bounded wait blocks at most its budget (plus scheduling
  # latency), so an 8000 ms default would show up unmistakably.
  defp timed(fun) do
    started = System.monotonic_time(:millisecond)
    result = fun.()
    {result, System.monotonic_time(:millisecond) - started}
  end

  # A `wait: true` `job_output` read of `job` with the given budget args, timed.
  defp wait_read(job, budget_args, cwd) do
    args = Map.merge(%{"job_id" => job.id, "wait" => true}, budget_args)
    timed(fn -> JobOutput.execute(args, cwd, cwd) end)
  end

  # The job_output tool's dispatch ceiling, DERIVED at runtime (see
  # `Tools.default_timeout_ms/1` and `EvoGit.BackgroundJobs.wait_max_ms/0`):
  # the wait cap plus the dispatcher headroom that produced it, i.e. exactly the
  # scheduler's `[:scheduler, :max_tool_timeout]`.
  defp job_output_default_timeout_ms do
    BackgroundJobs.wait_max_ms() + BackgroundJobs.dispatch_headroom_ms()
  end

  # Sets/clears the owning agent's graceful-cancel flag for the tool task. The
  # wait loop reads `:evogit_agent_id` from the process dictionary and the flag
  # from the app-owned `:evogit_agent_state` ETS table, so this mirrors exactly
  # what `TaskRegistry.cancel_task/1` + `AgentScheduler` leave behind. A UNIQUE
  # agent id keeps the row invisible to every other consumer of that table, and
  # the row is deleted afterwards.
  defp put_cancel_flag!(agent_id, value) do
    :ets.insert(:evogit_agent_state, {agent_id, %{cancel_requested: value}})

    on_exit(fn -> :ets.delete(:evogit_agent_state, agent_id) end)
    :ok
  end

  # The wait loop's backoff curve as a list: the delay AFTER each poll, starting
  # from `base_ms` and following `JobOutput.next_poll_delay/2` for `steps` polls.
  defp backoff_curve(base_ms, cap_ms, steps) do
    {delays, _last} =
      Enum.map_reduce(1..steps, base_ms, fn _step, current ->
        next = JobOutput.next_poll_delay(current, cap_ms)
        {next, next}
      end)

    delays
  end

  ## Job helpers

  defp start_job(command, cwd, extra \\ %{}) do
    spec = Map.merge(%{command: command, cwd: cwd, owner_pid: self()}, extra)

    case BackgroundJobs.start_job(spec) do
      {:ok, job} ->
        track_log!(job)
        job

      {:error, message} ->
        flunk("could not start the background job: #{message}")
    end
  end

  # The three `BackgroundJobs.start_job/1` call sites that pass an EXPLICIT
  # foreign `:owner_pid` (the ownership-fence tests) bypass `start_job/3`
  # because they assert on the `{:ok, job}` tuple; they clean up the same way.
  defp start_foreign_job!(command, cwd, owner_pid) do
    case BackgroundJobs.start_job(%{command: command, cwd: cwd, owner_pid: owner_pid}) do
      {:ok, job} ->
        track_log!(job)
        job

      {:error, message} ->
        flunk("could not start the foreign background job: #{message}")
    end
  end

  defp job_status(id) do
    case BackgroundJobs.job(id, owner_pid: self()) do
      {:ok, %{status: status}} -> status
      {:error, reason} -> reason
    end
  end

  defp await_job_status(id, status, timeout \\ 15_000) do
    wait_until(
      fn ->
        case BackgroundJobs.job(id, owner_pid: self()) do
          {:ok, %{status: ^status} = job} -> job
          _other -> false
        end
      end,
      timeout
    )
  end

  defp await_terminal(id, timeout \\ 15_000) do
    wait_until(
      fn ->
        case job_status(id) do
          status when status in [:completed, :killed, :failed] -> status
          _other -> false
        end
      end,
      timeout
    )
  end

  defp job_os_pid(job) do
    case job do
      %{handle: %{os_pid: pid}} when is_integer(pid) ->
        pid

      other ->
        flunk("expected an integer OS pid on the job handle, got: #{inspect(other.handle)}")
    end
  end

  # Server-side liveness check for a detached OS process — `kill -0` succeeds
  # only while the pid exists (the same primitive
  # `EvoGit.Sandbox.Helpers.kill_process_tree/1` uses, TERM + KILL).
  defp pid_alive?(pid) do
    case System.cmd("kill", ["-0", Integer.to_string(pid)], stderr_to_stdout: true) do
      {_output, 0} -> true
      {_output, _code} -> false
    end
  end

  defp await_dead(pid, timeout \\ 15_000) do
    wait_until(fn -> not pid_alive?(pid) end, timeout)
  end

  # Requests cancellation THROUGH THE TOOL (so the tool's result string is the
  # thing under test) and reaps the OS process, so no test can leak a detached
  # child. Only for a job that must still be live.
  defp kill_and_reap(job, cwd) do
    pid = job_os_pid(job)
    result = JobKill.execute(%{"job_id" => job.id}, cwd, cwd)

    refute String.starts_with?(result, "Error: "),
           "killing a live job must not fail, got: #{inspect(result)}"

    await_terminal(job.id)
    await_dead(pid)
    refute pid_alive?(pid)
  end

  # Ends a job whose OWNER is not the test process. The tools' ownership fence
  # correctly refuses to touch another agent's job, so the only in-test way to
  # stop it is the registry's OWNER MONITOR: kill the owner and wait for the
  # detached process to die. This MUST happen inside the test — the registry's
  # `terminate/2` cleanup is unreachable from a supervisor-ordered shutdown (the
  # GenServer does not trap exits), so anything still live when the test ends
  # leaks a real OS process.
  defp reap_with_owner(job, owner_pid) do
    pid = job_os_pid(job)
    ref = Process.monitor(owner_pid)
    Process.exit(owner_pid, :kill)
    assert_receive {:DOWN, ^ref, :process, ^owner_pid, _reason}, 5_000
    await_dead(pid)
    refute pid_alive?(pid)
  end

  describe "schema/0 — the three background-job tools" do
    test "job_output declares its id/wait/timeout/max_bytes contract" do
      schema = JobOutput.schema()

      assert schema.name == "job_output"
      assert is_binary(schema.description)
      assert schema.description =~ "background job"

      parameter_schema = schema.parameter_schema
      assert parameter_schema["type"] == "object"

      properties = parameter_schema["properties"]
      assert is_map(properties)

      for key <- ["job_id", "wait", "timeout_ms", "max_bytes"] do
        assert Map.has_key?(properties, key), "job_output must accept `#{key}`"
      end

      # STRING keys: this schema is JSON, and the implementation reads strings.
      assert Enum.all?(Map.keys(properties), &is_binary/1)
      # `job_id` is OPTIONAL: it may be omitted when this agent has exactly one
      # background job, so nothing is required.
      assert parameter_schema["required"] == []
      assert properties["job_id"]["description"] =~ "May be omitted"
    end

    test "job_list takes no arguments" do
      schema = JobList.schema()

      assert schema.name == "job_list"
      assert is_binary(schema.description)
      assert schema.description =~ "background job"
      assert schema.parameter_schema["type"] == "object"
      assert schema.parameter_schema["properties"] == %{}
    end

    test "job_kill declares its job_id/reason contract" do
      schema = JobKill.schema()

      assert schema.name == "job_kill"
      assert is_binary(schema.description)
      assert schema.description =~ "background job"

      parameter_schema = schema.parameter_schema
      assert parameter_schema["type"] == "object"
      assert Enum.sort(Map.keys(parameter_schema["properties"])) == ["job_id", "reason"]
      assert parameter_schema["required"] == ["job_id"]
    end
  end

  describe "JobOutput.execute/3" do
    test "returns the output since the previous read, then (no new output)", %{tmp_dir: cwd} do
      job = start_job("echo job-tools-output", cwd)
      await_job_status(job.id, :completed)

      first = JobOutput.execute(%{"job_id" => job.id}, cwd, cwd)
      assert is_binary(first)
      assert first =~ "job-tools-output"
      assert String.ends_with?(first, "[status: completed, exit code: 0]")

      second = JobOutput.execute(%{"job_id" => job.id}, cwd, cwd)
      assert second == "(no new output)\n[status: completed, exit code: 0]"
    end

    test "omitted job_id reads this agent's only background job", %{tmp_dir: cwd} do
      job = start_job("echo only-job", cwd)
      await_job_status(job.id, :completed)

      assert JobOutput.execute(%{}, cwd, cwd) =~ "only-job"
      # A blank or non-string id takes the SAME auto-selected path (the only job
      # is read, so the second read is an empty delta with the status line).
      assert JobOutput.execute(%{"job_id" => "   "}, cwd, cwd) ==
               "(no new output)\n[status: completed, exit code: 0]"

      assert JobOutput.execute(%{"job_id" => 123}, cwd, cwd) ==
               "(no new output)\n[status: completed, exit code: 0]"
    end

    test "omitted job_id still honours wait: true", %{tmp_dir: cwd} do
      start_job("echo waited", cwd)

      text = JobOutput.execute(%{"wait" => true, "timeout_ms" => 5_000}, cwd, cwd)

      # The full omitted-id shape: the delta, the byte-identical status line and
      # the wait marker that proves the wait path (not just a read) ran.
      assert text =~
               ~r/\Awaited\n\[status: completed, exit code: 0\]\n\[wait: finished after \d+ ms, status: completed\]\z/
    end

    test "omitted job_id with no jobs explains how to start one", %{tmp_dir: cwd} do
      assert BackgroundJobs.list(owner_pid: self()) == []

      result = JobOutput.execute(%{}, cwd, cwd)

      assert String.starts_with?(result, "Error: ")
      assert result =~ "no background jobs"
      assert result =~ "run_in_background: true"
    end

    test "omitted job_id with no owning agent keeps the explicit-id error", %{tmp_dir: cwd} do
      # Without an owning agent pid the job cannot be inferred, and an UNSCOPED
      # lookup would read another agent's job — so the explicit-id error is kept.
      Process.delete(:evogit_agent_pid)

      try do
        assert JobOutput.execute(%{}, cwd, cwd) =~ "Missing required argument 'job_id'"
      after
        Process.put(:evogit_agent_pid, self())
      end
    end

    test "omitted job_id with several jobs names every id, newest first", %{tmp_dir: cwd} do
      finished = start_job("echo first-done", cwd)
      await_job_status(finished.id, :completed)
      running = start_job("sleep 5", cwd)
      await_job_status(running.id, :running)

      result = JobOutput.execute(%{}, cwd, cwd)

      assert String.starts_with?(result, "Error: ")
      assert result =~ "Multiple background jobs"
      assert result =~ ~s|#{running.id} (running, "sleep 5")|
      assert result =~ ~s|#{finished.id} (completed, "echo first-done")|
      assert result =~ "Call job_list for details."

      # Newest first: the running job (started second) is named before the
      # finished one.
      {running_at, _} = :binary.match(result, running.id)
      {finished_at, _} = :binary.match(result, finished.id)
      assert running_at < finished_at

      # The error path advances NO read cursor: an explicit read still returns
      # the finished job's whole output.
      assert JobOutput.execute(%{"job_id" => finished.id}, cwd, cwd) =~ "first-done"

      kill_and_reap(running, cwd)
    end

    test "an explicit job_id is still used when several jobs exist", %{tmp_dir: cwd} do
      first = start_job("echo one", cwd)
      second = start_job("echo two", cwd)
      await_job_status(first.id, :completed)
      await_job_status(second.id, :completed)

      # Short sequential ids in one isolated registry.
      assert {first.id, second.id} == {"bash-1", "bash-2"}

      assert JobOutput.execute(%{"job_id" => first.id}, cwd, cwd) =~ "one"
      assert JobOutput.execute(%{"job_id" => second.id}, cwd, cwd) =~ "two"
    end

    test "a capped read reports more output pending and loses nothing", %{tmp_dir: cwd} do
      job = start_job("seq 1 2000", cwd)
      await_job_status(job.id, :completed)

      capped = JobOutput.execute(%{"job_id" => job.id, "max_bytes" => 20}, cwd, cwd)
      assert is_binary(capped)
      assert capped =~ "more output pending"

      # The cursor advances only by the bytes actually returned, so the follow-up
      # read continues exactly where the capped one stopped.
      rest = JobOutput.execute(%{"job_id" => job.id}, cwd, cwd)
      refute rest =~ "more output pending"
      assert rest =~ "2000"
    end

    test "wait: true returns once the job is terminal, well under the tool default",
         %{tmp_dir: cwd} do
      job = start_job("echo fast", cwd)

      started = System.monotonic_time(:millisecond)
      text = JobOutput.execute(%{"job_id" => job.id, "wait" => true}, cwd, cwd)
      elapsed = System.monotonic_time(:millisecond) - started

      assert text =~ "fast"

      # The FULL shape, not just the status line: the wait marker is one separate
      # line after the byte-identical `[status: …]` line.
      assert text =~
               ~r/\Afast\n\[status: completed, exit code: 0\]\n\[wait: finished after \d+ ms, status: completed\]\z/

      assert elapsed < 20_000,
             "a bounded wait must settle far under #{job_output_default_timeout_ms()} ms"
    end

    test "wait: true with a short timeout_ms returns while the job is still running",
         %{tmp_dir: cwd} do
      job = start_job("sleep 5", cwd)

      started = System.monotonic_time(:millisecond)

      text =
        JobOutput.execute(
          %{"job_id" => job.id, "wait" => true, "timeout_ms" => 30},
          cwd,
          cwd
        )

      elapsed = System.monotonic_time(:millisecond) - started

      # A timed-out wait returns (it must never hang) and leaves the job RUNNING.
      assert text =~ "[status: running]"
      # An EXPLICIT budget renders the bare expired marker (the default-only hint
      # is absent — this 30 ms budget was asked for).
      assert text =~ "[wait: 30 ms budget expired, status: running]"
      refute text =~ "pass timeout_ms"
      assert elapsed < 20_000
      assert job_status(job.id) == :running

      kill_and_reap(job, cwd)
    end

    test "every failure is an Error: string and never raises", %{tmp_dir: cwd} do
      unknown = "bash-0000000000000000"

      not_found = JobOutput.execute(%{"job_id" => unknown}, cwd, cwd)
      assert String.starts_with?(not_found, "Error: ")
      assert not_found =~ "No background job"

      other = spawn(fn -> Process.sleep(:infinity) end)
      on_exit(fn -> Process.exit(other, :kill) end)

      foreign_job = start_foreign_job!("sleep 30", cwd, other)

      # The tool fences on the CALLING agent (the pdict owner), not on the job.
      assert Process.get(:evogit_agent_pid) == self()

      foreign = JobOutput.execute(%{"job_id" => foreign_job.id}, cwd, cwd)
      assert String.starts_with?(foreign, "Error: ")
      assert foreign =~ "another agent"

      missing = JobOutput.execute(%{}, cwd, cwd)
      assert String.starts_with?(missing, "Error: ")
      # No id and NO jobs of this agent's own: an actionable zero-job error, not
      # an argument-missing one.
      assert missing =~ "no background jobs"
      assert missing =~ "run_in_background: true"

      # A non-string id is coerced to a string by `Shared.fetch_string_arg/2` and
      # then simply is not a known job — only the Error: shape is pinned here.
      coerced = JobOutput.execute(%{"job_id" => 123}, cwd, cwd)
      assert String.starts_with?(coerced, "Error: ")

      for args <- ["nope", nil] do
        assert JobOutput.execute(args, cwd, cwd) == "Error: Arguments must be a map/object"
      end

      reap_with_owner(foreign_job, other)
    end

    test "an unreachable registry is an Error: string naming the outage", %{
      tmp_dir: cwd,
      registry: registry
    } do
      Process.put(:evogit_background_jobs_server, :job_tools_missing_registry)

      result = JobOutput.execute(%{"job_id" => "bash-0000000000000000"}, cwd, cwd)
      assert String.starts_with?(result, "Error: ")
      assert result =~ "not running"

      # Leave the isolated registry reachable again for the rest of this test.
      Process.put(:evogit_background_jobs_server, registry)
      assert Process.get(:evogit_background_jobs_server) == registry
    end

    test "status_line/1 renders the status and the optional detail" do
      assert JobOutput.status_line(%{status: :completed, detail: nil}) == "[status: completed]"

      assert JobOutput.status_line(%{status: :failed, detail: "exit code: 3"}) ==
               "[status: failed, exit code: 3]"

      assert JobOutput.status_line(%{status: nil, detail: nil}) == "[status: unknown]"

      # The wait marker is a SEPARATE line after this one, and this line is shared
      # with `JobKill`'s "already finished" reply, so it must stay byte-identical.
      assert JobOutput.status_line(%{status: :completed, detail: "exit code: 0"}) ==
               "[status: completed, exit code: 0]"

      assert JobOutput.status_line(%{status: :running}) == "[status: running]"
    end
  end

  # The `wait: true` budget contract and its ONE marker line. Every wait below is
  # bounded by a SMALL budget — the 120 000 ms production default and the derived
  # ~30 min cap are shortened through the CALL-TIME seams, never waited out — and
  # every `sleep 30` job is killed and reaped.
  describe "JobOutput.execute/3 — wait budget and marker" do
    test "honours an explicit timeout_ms budget", %{tmp_dir: cwd} do
      job = start_job("sleep 30", cwd)
      {text, elapsed} = wait_read(job, %{"timeout_ms" => @wait_budget_ms}, cwd)

      assert elapsed >= @wait_budget_lower_bound_ms
      assert elapsed < @wait_elapsed_ceiling_ms
      assert text =~ "[status: running]"

      # An EXPLICIT budget renders the bare marker: the default-only hint (which
      # names the CAP) is absent.
      assert String.ends_with?(
               text,
               "[wait: #{@wait_budget_ms} ms budget expired, status: running]"
             )

      refute text =~ "pass timeout_ms"
      assert job_status(job.id) == :running

      kill_and_reap(job, cwd)
    end

    test "honours the generic `timeout` spelling as the same budget", %{tmp_dir: cwd} do
      job = start_job("sleep 30", cwd)
      {text, elapsed} = wait_read(job, %{"timeout" => @wait_budget_ms}, cwd)

      # THE regression: `timeout` used to be ignored, so this call waited the full
      # 8000 ms default and rendered NO marker at all.
      assert elapsed >= @wait_budget_lower_bound_ms
      assert elapsed < @wait_elapsed_ceiling_ms
      assert text =~ "[wait: #{@wait_budget_ms} ms budget expired, status: running]"
      refute text =~ "pass timeout_ms"
      assert job_status(job.id) == :running

      kill_and_reap(job, cwd)
    end

    test "coerces every accepted value shape to the same budget", %{tmp_dir: cwd} do
      # A float (truncated: 300.0 → exactly 300), a numeric string, a unit string
      # and the `timeoutMs` harness-alignment alias all land on 300 ms.
      shapes = [
        {"timeout_ms", 300.0},
        {"timeout_ms", "300"},
        {"timeout_ms", "300ms"},
        {"timeoutMs", 300}
      ]

      for {key, value} <- shapes do
        job = start_job("sleep 30", cwd)
        {text, elapsed} = wait_read(job, %{key => value}, cwd)
        label = "#{key} => #{inspect(value)}"

        assert elapsed >= @wait_budget_lower_bound_ms, label
        assert elapsed < @wait_elapsed_ceiling_ms, label

        assert text =~ "[wait: #{@wait_budget_ms} ms budget expired, status: running]",
               "#{label} must use a #{@wait_budget_ms} ms budget, got: #{inspect(text)}"

        refute text =~ "pass timeout_ms"
        assert job_status(job.id) == :running

        kill_and_reap(job, cwd)
      end
    end

    test "an absent budget uses the default, and only the default gets the hint", %{tmp_dir: cwd} do
      # Test-only CALL-TIME seam (`EvoGit.BackgroundJobs.wait_default_ms/0`): the
      # production 120 000 ms is unchanged — this only keeps the test fast.
      put_test_env(:background_wait_default_ms, @wait_default_seam_ms)

      job = start_job("sleep 30", cwd)
      {text, elapsed} = wait_read(job, %{}, cwd)

      assert elapsed >= @wait_default_seam_ms - 50
      assert elapsed < @wait_elapsed_ceiling_ms

      # The hint rides ONLY the default-budget marker, and it names the CAP in
      # BOTH forms — the numeric budget and its human form, both rendered at
      # runtime from `wait_max_ms/0` (never a literal). With the default config
      # the cap is 1_775_000 ms, which is NOT a whole minute, so the human form
      # is `<n>m<n>s`.
      cap_ms = BackgroundJobs.wait_max_ms()
      assert cap_ms == 1_775_000

      assert String.ends_with?(
               text,
               "[wait: #{@wait_default_seam_ms} ms budget expired, status: running; " <>
                 "pass timeout_ms (or timeout) to wait up to #{cap_ms} ms (\"29m35s\")]"
             )

      # With the SAME seam installed, an explicit budget stays distinguishable:
      # 300 ms and no hint.
      {explicit, _elapsed} = wait_read(job, %{"timeout" => @wait_budget_ms}, cwd)

      assert explicit =~ "[wait: #{@wait_budget_ms} ms budget expired, status: running]"
      refute explicit =~ "pass timeout_ms"
      assert job_status(job.id) == :running

      # The whole-minute arm of the same hint: a cap that IS a whole minute
      # renders as `<n>m`, still derived from `wait_max_ms/0` (never a literal).
      put_test_env(:background_wait_max_ms, 60_000)
      {minute, _elapsed} = wait_read(job, %{}, cwd)

      assert String.ends_with?(
               minute,
               "pass timeout_ms (or timeout) to wait up to 60000 ms (\"1m\")]"
             )

      assert job_status(job.id) == :running

      # The below-one-minute arm: a sub-minute cap renders as `<n>s`.
      put_test_env(:background_wait_max_ms, 8_000)
      {seconds, _elapsed} = wait_read(job, %{}, cwd)

      assert String.ends_with?(
               seconds,
               "pass timeout_ms (or timeout) to wait up to 8000 ms (\"8s\")]"
             )

      assert job_status(job.id) == :running

      kill_and_reap(job, cwd)
    end

    test "a present but unusable budget counts as the default", %{tmp_dir: cwd} do
      put_test_env(:background_wait_default_ms, @wait_default_seam_ms)

      job = start_job("sleep 30", cwd)
      {text, elapsed} = wait_read(job, %{"timeout_ms" => "soon"}, cwd)

      # "soon" is unusable, so the DEFAULT was waited — never a 0 ms budget (which
      # would return at once) and never the production 120 000 ms.
      assert elapsed >= @wait_default_seam_ms - 50
      assert elapsed < @wait_elapsed_ceiling_ms
      assert text =~ "[wait: #{@wait_default_seam_ms} ms budget expired, status: running; pass"
      refute text =~ "[wait: 0 ms"
      assert job_status(job.id) == :running

      kill_and_reap(job, cwd)
    end

    test "returns early with the completion marker when the job finishes mid-wait",
         %{tmp_dir: cwd} do
      job = start_job("sleep 0.3", cwd)
      {text, elapsed} = wait_read(job, %{"timeout_ms" => 5_000}, cwd)

      # The 5 s budget was NOT consumed: the wait returned as soon as the job
      # reached its terminal status.
      assert elapsed < 3_000
      assert text =~ "[status: completed, exit code: 0]"
      assert text =~ ~r/\[wait: finished after \d+ ms, status: completed\]\z/
      refute text =~ "budget expired"
      assert job_status(job.id) == :completed
    end

    test "a non-wait read renders no marker", %{tmp_dir: cwd} do
      job = start_job("echo no-wait", cwd)
      await_job_status(job.id, :completed)

      # Both the DEFAULT (no `wait` key) and an explicit `wait: false` are
      # byte-identical to the pre-marker result shape.
      default_read = JobOutput.execute(%{"job_id" => job.id}, cwd, cwd)
      assert default_read =~ "no-wait"
      refute default_read =~ "[wait:"

      false_read = JobOutput.execute(%{"job_id" => job.id, "wait" => false}, cwd, cwd)
      assert false_read == "(no new output)\n[status: completed, exit code: 0]"
      refute false_read =~ "[wait:"
    end

    test "a full-budget wait is never cut off by the dispatch ceiling", %{tmp_dir: cwd} do
      # Shrink BOTH call-time seams: the cap (so a "full budget" wait is 500 ms)
      # and the poll cadence. The dispatcher's job_output ceiling is derived from
      # the SAME cap at runtime, so this also pins the headroom arithmetic end to
      # end: cap + headroom, i.e. exactly the scheduler's tool ceiling.
      put_test_env(:background_wait_max_ms, 500)
      put_test_env(:background_poll_interval_ms, 10)

      assert BackgroundJobs.wait_max_ms() == 500

      assert Tools.default_timeout_ms("job_output") ==
               BackgroundJobs.wait_max_ms() + BackgroundJobs.dispatch_headroom_ms()

      assert Tools.default_timeout_ms("job_output") == 25_500

      # `job_output`'s `timeout` argument is an INTERNAL wait budget, so the
      # dispatcher applies that derived value as a FLOOR — an explicit budget can
      # never lower the ceiling below the wait cap plus headroom.
      assert Tools.timeout_arg_is_wait_budget?("job_output")

      job = start_job("sleep 0.03", cwd)

      # No explicit budget: the 120 000 ms default is CLAMPED to the 500 ms cap,
      # and the job finishes after a couple of polls — so the marker is "finished",
      # never "budget expired" and never a dispatcher-level abort of the call.
      {text, elapsed} = wait_read(job, %{}, cwd)

      assert elapsed < 2_000
      assert text =~ ~r/\[wait: finished after \d+ ms, status: completed\]\z/
      refute text =~ "budget expired"
      assert job_status(job.id) == :completed
    end

    test "a unit-string budget is honoured and CLAMPED to the derived cap", %{tmp_dir: cwd} do
      # The cap is shrunk to 500 ms so a 30 minute request is provably clamped in
      # half a second instead of 30 minutes.
      put_test_env(:background_wait_max_ms, 500)
      put_test_env(:background_poll_interval_ms, 10)

      shapes = [{"timeout", "30m"}, {"timeout_ms", "90s"}, {"timeout_ms", 500.0}]

      for {key, value} <- shapes do
        job = start_job("sleep 30", cwd)
        {text, elapsed} = wait_read(job, %{key => value}, cwd)
        label = "#{key} => #{inspect(value)}"

        assert elapsed >= 400, label
        assert elapsed < 3_000, label

        # The marker reports the CLAMPED budget (500), not the requested one.
        assert String.ends_with?(text, "[wait: 500 ms budget expired, status: running]"),
               "#{label} must clamp to the 500 ms cap, got: #{inspect(text)}"

        refute text =~ "pass timeout_ms"
        refute text =~ "1800000"
        refute text =~ "90000"
        assert job_status(job.id) == :running

        kill_and_reap(job, cwd)
      end
    end

    test "the poll backoff curve grows from the base and caps out" do
      # The pure curve behind the wait loop: ~1.5× per poll from the configured
      # base cadence (100 ms in production), never past the 3 s cap. Backing off
      # is what keeps a ~30 min wait from running ~18 000 `systemctl --user show`
      # polls in the single global registry.
      assert JobOutput.next_poll_delay(100, 3_000) == 150
      assert JobOutput.next_poll_delay(150, 3_000) == 225

      curve = backoff_curve(100, 3_000, 40)

      assert hd(curve) == 150
      assert List.last(curve) == 3_000
      assert curve == Enum.sort(curve), "the curve must never shrink"
      assert Enum.max(curve) == 3_000, "the curve must never exceed the cap"
      assert Enum.count(curve, &(&1 == 3_000)) > 1, "the curve must flatten AT the cap"

      # A zero base (the poll-interval seam allows 0) still sleeps at least 1 ms,
      # so the wait can never degenerate into a busy loop.
      assert JobOutput.next_poll_delay(0, 3_000) >= 1
      assert JobOutput.next_poll_delay(3_000, 3_000) == 3_000
    end

    test "a graceful cancel aborts the wait early with its own marker", %{tmp_dir: cwd} do
      agent_id = System.unique_integer([:positive])
      put_cancel_flag!(agent_id, true)
      Process.put(:evogit_agent_id, agent_id)
      on_exit(fn -> Process.delete(:evogit_agent_id) end)

      job = start_job("sleep 30", cwd)
      {text, elapsed} = wait_read(job, %{"timeout" => 5_000}, cwd)

      # The 5 s budget was NOT consumed: the cancel flag is checked on every poll,
      # so the wait returns at the next-poll latency.
      assert elapsed < 2_000
      assert text =~ "[status: running]"

      assert text =~
               ~r/\[wait: aborted after \d+ ms — cancellation requested, status: running\]\z/

      refute text =~ "budget expired"
      assert job_status(job.id) == :running

      kill_and_reap(job, cwd)
    end
  end

  # The cancel probe must be TOTAL: it runs inside a wait, so anything it cannot
  # answer is "not cancelled" — never a raise and never a crashed tool.
  describe "JobOutput cancel probe totality" do
    test "an absent or unusable agent id is never a cancel" do
      Process.delete(:evogit_agent_id)
      refute JobOutput.cancel_requested?()

      for invalid <- ["7", nil, 7.0, :agent] do
        Process.put(:evogit_agent_id, invalid)

        refute JobOutput.cancel_requested?(),
               "agent id #{inspect(invalid)} must not count as a cancel"
      end
    end

    test "an absent agent-state ETS table is never a cancel" do
      # Probed through an explicit table name, so the app-owned singleton table
      # (shared with the running scheduler) is never deleted.
      assert :ets.whereis(:evogit_no_such_state_table) == :undefined

      Process.put(:evogit_agent_id, System.unique_integer([:positive]))
      refute JobOutput.cancel_requested?(:evogit_no_such_state_table)
    end

    test "a real flag is reported for the owning agent only" do
      agent_id = System.unique_integer([:positive])
      put_cancel_flag!(agent_id, true)
      Process.put(:evogit_agent_id, agent_id)

      assert JobOutput.cancel_requested?()

      put_cancel_flag!(agent_id, nil)
      refute JobOutput.cancel_requested?()

      # A DIFFERENT agent's flag never leaks into this agent's wait.
      other_id = agent_id + 1_000_000
      put_cancel_flag!(other_id, true)
      refute JobOutput.cancel_requested?()
    end

    test "a wait with no agent id just waits its budget (no raise)", %{tmp_dir: cwd} do
      Process.delete(:evogit_agent_id)

      job = start_job("sleep 30", cwd)
      {text, elapsed} = wait_read(job, %{"timeout_ms" => 200}, cwd)

      assert elapsed >= 150
      assert elapsed < 3_000
      assert String.ends_with?(text, "[wait: 200 ms budget expired, status: running]")
      assert job_status(job.id) == :running

      kill_and_reap(job, cwd)
    end
  end

  describe "JobList.execute/3" do
    test "an empty registry yields exactly the no-jobs line", %{tmp_dir: cwd} do
      assert JobList.execute(%{}, cwd, cwd) == "(no background jobs)"
    end

    test "one line per job, newest first, separated by an em dash", %{tmp_dir: cwd} do
      # Both jobs are SHORT-LIVED by construction, so the registry settles them
      # on its own (no kill, and therefore no kill grace, is needed). The pinned
      # contract here is the rendered line shape and the ordering — the status is
      # deliberately not asserted, and a finished job stays listed.
      first = start_job("sleep 0.02", cwd)
      wait_until(fn -> length(BackgroundJobs.list()) == 1 end)

      second = start_job("sleep 0.02", cwd)
      wait_until(fn -> length(BackgroundJobs.list()) == 2 end)

      text = JobList.execute(%{}, cwd, cwd)
      assert is_binary(text)

      lines = String.split(text, "\n")
      assert length(lines) == 2

      for line <- lines do
        assert line =~ ~r/\Abash-\d+ \[bash\] (running|completed|killed|failed) — .+/
        # The separator is the EM DASH (U+2014), not a hyphen.
        assert line =~ "—"
        # The label is the command's first line.
        assert line =~ "sleep 0.02"
      end

      assert hd(lines) =~ second.id
      assert List.last(lines) =~ first.id

      # Reap: both children exit by themselves; wait for the registry to observe
      # it so nothing outlives the test.
      assert await_terminal(first.id) == :completed
      assert await_terminal(second.id) == :completed
    end

    test "the ownership fence hides another agent's job", %{tmp_dir: cwd} do
      other = spawn(fn -> Process.sleep(:infinity) end)
      on_exit(fn -> Process.exit(other, :kill) end)

      foreign_job = start_foreign_job!("sleep 30", cwd, other)

      assert Process.get(:evogit_agent_pid) == self()
      assert JobList.execute(%{}, cwd, cwd) == "(no background jobs)"

      reap_with_owner(foreign_job, other)
    end

    test "an unreachable registry is list-shaped, never an error", %{tmp_dir: cwd} do
      Process.put(:evogit_background_jobs_server, :job_tools_missing_registry)
      assert JobList.execute(%{}, cwd, cwd) == "(no background jobs)"
    end
  end

  describe "JobKill.execute/3" do
    test "requests cancellation of a live job, records the reason, then reports its settled state",
         %{tmp_dir: cwd} do
      job = start_job("sleep 30", cwd)
      pid = job_os_pid(job)

      assert JobKill.execute(%{"job_id" => job.id}, cwd, cwd) ==
               "requested cancellation of job #{job.id}"

      killed = await_job_status(job.id, :killed)
      # The DEFAULT reason is recorded verbatim.
      assert killed.detail == "killed (stopped by request)"

      await_dead(pid)
      refute pid_alive?(pid)

      # A repeat kill of the same job reports the settled state instead of
      # requesting cancellation again.
      again = JobKill.execute(%{"job_id" => job.id}, cwd, cwd)
      assert String.starts_with?(again, "job #{job.id} had already finished [status: ")
      assert again =~ "killed (stopped by request)"

      # The reply ENDS with the shared status line (unaffected by `job_output`'s
      # separate wait marker line).
      assert again ==
               "job #{job.id} had already finished " <>
                 "[status: killed, killed (stopped by request)]"

      # A caller-supplied `reason` is what lands on the job's detail.
      custom = start_job("sleep 30", cwd)
      custom_pid = job_os_pid(custom)

      assert JobKill.execute(%{"job_id" => custom.id, "reason" => "no longer needed"}, cwd, cwd) ==
               "requested cancellation of job #{custom.id}"

      custom_killed = await_job_status(custom.id, :killed)
      assert custom_killed.detail == "killed (no longer needed)"

      await_dead(custom_pid)
      refute pid_alive?(custom_pid)
    end

    test "every failure is an Error: string and never raises", %{tmp_dir: cwd} do
      unknown = "bash-0000000000000000"

      not_found = JobKill.execute(%{"job_id" => unknown}, cwd, cwd)
      assert String.starts_with?(not_found, "Error: ")
      assert not_found =~ "No background job"

      other = spawn(fn -> Process.sleep(:infinity) end)
      on_exit(fn -> Process.exit(other, :kill) end)

      foreign_job = start_foreign_job!("sleep 30", cwd, other)

      assert Process.get(:evogit_agent_pid) == self()

      foreign = JobKill.execute(%{"job_id" => foreign_job.id}, cwd, cwd)
      assert String.starts_with?(foreign, "Error: ")
      assert foreign =~ "another agent"

      missing = JobKill.execute(%{}, cwd, cwd)
      assert String.starts_with?(missing, "Error: ")
      assert missing =~ "job_id"

      assert JobKill.execute("nope", cwd, cwd) == "Error: Arguments must be a map/object"
      assert JobKill.execute(nil, cwd, cwd) == "Error: Arguments must be a map/object"

      # The fence refused to kill another agent's job, so the job is still live:
      # end it through its owner.
      reap_with_owner(foreign_job, other)
    end

    test "an unreachable registry is an Error: string, never a crash", %{
      tmp_dir: cwd,
      registry: registry
    } do
      Process.put(:evogit_background_jobs_server, :job_tools_missing_registry)

      result = JobKill.execute(%{"job_id" => "bash-0000000000000000"}, cwd, cwd)

      assert String.starts_with?(result, "Error: ")

      # OBSERVED-vs-EXPECTED (pinned as shipped, not as first assumed): unlike
      # `JobOutput`, the kill path does NOT surface the registry outage prose.
      # `BackgroundJobs.kill/3`'s dead-registry fallback is the SEMANTIC tuple
      # `{:error, :not_found}` — documented verbatim on `kill/3`: "unknown id, OR
      # AN UNREACHABLE REGISTRY" — so the tool renders its unknown-job message
      # ("No background job with id … is known to this agent") instead of
      # `job_output`'s "service is not running" sentence (that call falls back to
      # `registry_down_error/0`), while `job_list` stays list-shaped.
      assert result =~ "No background job"

      Process.put(:evogit_background_jobs_server, registry)
      assert Process.get(:evogit_background_jobs_server) == registry
    end
  end

  describe "ShellTool run_in_background" do
    test "schema/0 advertises the argument and points at the job tools" do
      schema = ShellTool.schema()
      properties = schema.parameter_schema["properties"]

      assert properties["run_in_background"]["type"] == "boolean"
      # Not a schema default: the mode is opt-in per call.
      refute Map.has_key?(properties["run_in_background"], "default")

      # The old "not available yet" caveat is gone from both descriptions.
      refute schema.description =~ "Background execution is not available yet"
      refute properties["timeout"]["description"] =~ "Background execution is not available yet"

      assert schema.description =~ "job_output"
      assert schema.description =~ "job_list"
      assert schema.description =~ "job_kill"

      # The description pushes the harness's own backgrounding mechanism and
      # warns against doing it by hand (the sandbox kills the process group, so
      # a manual `&`/`nohup` silently loses the work).
      assert schema.description =~ "run_in_background"
      assert schema.description =~ "NEVER background a command yourself"
      assert schema.description =~ "`nohup`"
      assert schema.description =~ "`&`"
      assert properties["run_in_background"]["description"] =~ "never `&`/`nohup`"
      # …and it warns that the command is already passed to the shell.
      assert schema.description =~ "shell prompt `$`"
    end

    test "a background start returns the job id and registers the job", %{tmp_dir: cwd} do
      # Two lines on purpose: the LABEL must be the command's FIRST line, and the
      # second line keeps the job live so its state is observable.
      command = "echo bg-hi\nsleep 5"

      result = ShellTool.execute(%{"command" => command, "run_in_background" => true}, cwd, cwd)
      assert result =~ ~r/\Astarted background job bash-\d+\z/

      id = String.replace_prefix(result, "started background job ", "")

      jobs = BackgroundJobs.list()
      assert [job] = jobs
      assert job.id == id
      assert job.status == :running
      assert job.label == "echo bg-hi"
      track_log!(job)

      # The job it started is killable through the tool.
      refute String.starts_with?(JobKill.execute(%{"job_id" => id}, cwd, cwd), "Error: ")
      await_dead(job_os_pid(job))
    end

    test "the timeout is ignored for a background start", %{tmp_dir: cwd} do
      # `timeout: 1` (1 ms) would abort a FOREGROUND command at once; a
      # background start has no timeout at all.
      result =
        ShellTool.execute(
          %{"command" => "sleep 5", "timeout" => 1, "run_in_background" => true},
          cwd,
          cwd
        )

      refute String.starts_with?(result, "Error: ")
      assert result =~ ~r/\Astarted background job bash-\d+\z/

      id = String.replace_prefix(result, "started background job ", "")
      job = await_job_status(id, :running)
      track_log!(job)
      pid = job_os_pid(job)

      assert JobKill.execute(%{"job_id" => id}, cwd, cwd) == "requested cancellation of job #{id}"
      await_job_status(id, :killed)
      await_dead(pid)
      refute pid_alive?(pid)
    end

    test "the main-copy mutation block still applies to a background start", %{tmp_dir: cwd} do
      repo_root = Path.join(cwd, "main-copy")
      repo_path = Path.join(cwd, "worktree")
      File.mkdir_p!(repo_root)
      File.mkdir_p!(repo_path)

      command = "cd #{repo_root} && git checkout some-branch"

      result =
        ShellTool.execute(
          %{"command" => command, "run_in_background" => true},
          repo_path,
          repo_root
        )

      assert String.starts_with?(result, "Error: ")
      assert result =~ "MAIN working copy"
      # Nothing was started: the guard runs BEFORE the spawn.
      assert BackgroundJobs.list() == []
    end
  end

  describe "tool classification" do
    test "the three job tools are in both schema sets" do
      full = Enum.map(Tools.schemas(), & &1.name)
      read_only = Enum.map(Tools.read_only_schemas(), & &1.name)

      for tool_name <- @job_tools do
        assert tool_name in full
        assert tool_name in read_only
      end
    end

    test "the job tools are never WRITE calls" do
      # `Tools.write_tool?/1` is PRIVATE; `write_call?/2` is exactly
      # `write_tool?(name) or shell-background-start?/2` (see the module doc), so
      # a false `write_call?/2` covers the name-based classification too.
      for tool_name <- @job_tools do
        refute Tools.write_call?(tool_name, %{})

        refute Tools.write_call?(tool_name, %{"job_id" => "bash-0000000000000000"})
      end
    end

    test "a background shell start IS a write call" do
      assert Tools.write_call?("bash", %{"command" => "x", "run_in_background" => true})
      assert Tools.write_call?("Bash", %{"run_in_background" => true})
      assert Tools.write_call?("run_bash", %{"run_in_background" => "true"})
      # ... while a FOREGROUND shell call is classified by its name alone (it is
      # a write tool in every mode — unchanged behaviour).
      assert Tools.write_call?("bash", %{"command" => "echo hi"})
    end

    test "background_start?/1 is leniently truthy" do
      assert Tools.background_start?(%{"run_in_background" => true})
      assert Tools.background_start?(%{"run_in_background" => "true"})

      refute Tools.background_start?(%{})
      refute Tools.background_start?(%{"run_in_background" => false})
      refute Tools.background_start?(%{"run_in_background" => "false"})
      refute Tools.background_start?(%{"run_in_background" => "yes"})
      refute Tools.background_start?(nil)
      refute Tools.background_start?("run_in_background")
    end

    test "serial_tool?/1 is false for the job tools" do
      for tool_name <- @job_tools ++ ["bash"] do
        refute Tools.serial_tool?(tool_name)
      end

      # Contrast: the genuine read-modify-write tools ARE serial.
      assert Tools.serial_tool?("write")
      assert Tools.serial_tool?("edit")
    end
  end

  describe "repo-less guard" do
    setup do
      # A repo-less agent (the self-reflective one) must not start detached jobs.
      Process.put(:repo_less, true)
      on_exit(fn -> Process.delete(:repo_less) end)
      :ok
    end

    test "a background start is blocked and names the BACKGROUND mode", %{tmp_dir: cwd} do
      result =
        Tools.execute(
          "bash",
          %{"command" => "sleep 30", "run_in_background" => true},
          cwd,
          cwd,
          nil
        )

      assert is_binary(result)
      assert String.starts_with?(result, "Error: ")
      assert result =~ "BACKGROUND process"
      assert BackgroundJobs.list() == []
    end

    test "a foreground command is still blocked with the generic message", %{tmp_dir: cwd} do
      result = Tools.execute("bash", %{"command" => "echo hi"}, cwd, cwd, nil)

      assert is_binary(result)
      assert String.starts_with?(result, "Error: ")
      # The message names the NORMALISED platform tool (`run_bash` on POSIX), so
      # assert the platform-independent substring only.
      assert result =~ "read-only access to the system"
    end

    test "the job control tools stay available to a repo-less agent", %{tmp_dir: cwd} do
      assert Tools.execute("job_list", %{}, cwd, cwd, nil) == "(no background jobs)"

      output = Tools.execute("job_output", %{"job_id" => "bash-0000000000000000"}, cwd, cwd, nil)
      assert String.starts_with?(output, "Error: ")
      assert output =~ "No background job"

      kill = Tools.execute("job_kill", %{"job_id" => "bash-0000000000000000"}, cwd, cwd, nil)
      assert String.starts_with?(kill, "Error: ")
      assert kill =~ "No background job"

      Process.delete(:repo_less)
      refute Process.get(:repo_less)
    end
  end
end
