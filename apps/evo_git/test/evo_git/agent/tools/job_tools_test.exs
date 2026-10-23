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
  OS pid reaped before the test ends, and `on_exit` removes exactly the
  `genesis_job_*.log` files this test created (safe because the module is
  `async: false`: the sync phase runs one module at a time).
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

  # The job_output tool's own dispatch default (see
  # `Tools.default_timeout_ms/1`): a bounded `wait: true` legitimately blocks up
  # to 60 s inside the tool, so this generous bound is a compile-time-safe
  # ceiling, NOT a latency race.
  @job_output_default_timeout_ms 65_000

  setup do
    registry = :"job_tools_test_#{System.unique_integer([:positive])}"

    # Its `terminate/2` kills every job still live when the test ends.
    start_supervised!({EvoGit.BackgroundJobs, [name: registry]})

    # The two process-dictionary seams the job tools read at CALL time: the
    # isolated registry name, and the OWNING agent pid — so
    # `BackgroundJobs.current_owner_pid/0` binds this test's jobs to the test
    # process and the tools' ownership fence compares against it.
    Process.put(:evogit_background_jobs_server, registry)
    Process.put(:evogit_agent_pid, self())

    before = scratch_logs()

    on_exit(fn ->
      # Belt and braces: this callback runs in a DIFFERENT process, so the test
      # process's own dictionary already dies with it. Clear the three keys the
      # tools and the guards read anyway.
      Process.delete(:evogit_agent_pid)
      Process.delete(:evogit_background_jobs_server)
      Process.delete(:repo_less)

      remove_new_scratch_logs(before)
    end)

    %{registry: registry}
  end

  ## Scratch-directory hygiene

  # A job's output file is `<scratch dir>/genesis_job_<job_id>.log`
  # (`BackgroundJobs.scratch_dir/0` = `EvoGit.Sandbox.resolve_tmpdir/0`). The
  # scratch dir is shared with the whole host, so record what is there first and
  # remove ONLY the logs that appeared during this test.
  #
  # Why a window and not the job ids: the isolated registry is already terminated
  # by the time `on_exit` callbacks run (ExUnit stops `start_supervised!` children
  # first), so its job list cannot be read there. The window is safe within this
  # BEAM because the module is `async: false` — the sync phase runs one module at
  # a time — and removing a log file only ever affects a job this module's OWN
  # tests left behind (every long job is killed and reaped before its test ends).
  defp scratch_logs do
    for dir <- scratch_dirs(),
        name <- ls(dir),
        String.starts_with?(name, "genesis_job_"),
        into: MapSet.new(),
        do: Path.join(dir, name)
  end

  defp scratch_dirs do
    root = EvoGit.Sandbox.resolve_tmpdir()

    [root, Path.join(root, "genesis")]
    |> Enum.filter(&File.dir?/1)
  end

  defp ls(dir) do
    case File.ls(dir) do
      {:ok, names} -> names
      {:error, _reason} -> []
    end
  end

  defp remove_new_scratch_logs(before) do
    scratch_logs()
    |> MapSet.difference(before)
    |> Enum.each(&File.rm/1)
  end

  ## Event-driven waits (never a fixed sleep as the assertion)

  defp wait_until(fun, timeout \\ 15_000) do
    deadline = System.monotonic_time(:millisecond) + timeout
    do_wait_until(fun, deadline, timeout)
  end

  defp do_wait_until(fun, deadline, timeout) do
    result = fun.()

    cond do
      result ->
        result

      System.monotonic_time(:millisecond) >= deadline ->
        flunk("the awaited condition was not reached within #{timeout} ms")

      true ->
        Process.sleep(20)
        do_wait_until(fun, deadline, timeout)
    end
  end

  ## Job helpers

  defp start_job(command, cwd, extra \\ %{}) do
    spec = Map.merge(%{command: command, cwd: cwd, owner_pid: self()}, extra)

    case BackgroundJobs.start_job(spec) do
      {:ok, job} -> job
      {:error, message} -> flunk("could not start the background job: #{message}")
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
      assert parameter_schema["required"] == ["job_id"]
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
      assert text =~ ~r/\[status: completed, exit code: 0\]\z/

      assert elapsed < 20_000,
             "a bounded wait must settle far under #{@job_output_default_timeout_ms} ms"
    end

    test "wait: true with a short timeout_ms returns while the job is still running",
         %{tmp_dir: cwd} do
      job = start_job("sleep 5", cwd)

      started = System.monotonic_time(:millisecond)

      text =
        JobOutput.execute(
          %{"job_id" => job.id, "wait" => true, "timeout_ms" => 200},
          cwd,
          cwd
        )

      elapsed = System.monotonic_time(:millisecond) - started

      # A timed-out wait returns (it must never hang) and leaves the job RUNNING.
      assert text =~ "[status: running]"
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

      {:ok, foreign_job} =
        BackgroundJobs.start_job(%{command: "sleep 30", cwd: cwd, owner_pid: other})

      # The tool fences on the CALLING agent (the pdict owner), not on the job.
      assert Process.get(:evogit_agent_pid) == self()

      foreign = JobOutput.execute(%{"job_id" => foreign_job.id}, cwd, cwd)
      assert String.starts_with?(foreign, "Error: ")
      assert foreign =~ "another agent"

      missing = JobOutput.execute(%{}, cwd, cwd)
      assert String.starts_with?(missing, "Error: ")
      assert missing =~ "job_id"

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
    end
  end

  describe "JobList.execute/3" do
    test "an empty registry yields exactly the no-jobs line", %{tmp_dir: cwd} do
      assert JobList.execute(%{}, cwd, cwd) == "(no background jobs)"
    end

    test "one line per job, newest first, separated by an em dash", %{tmp_dir: cwd} do
      first = start_job("sleep 5", cwd)
      wait_until(fn -> length(BackgroundJobs.list()) == 1 end)

      second = start_job("sleep 5", cwd)
      wait_until(fn -> length(BackgroundJobs.list()) == 2 end)

      text = JobList.execute(%{}, cwd, cwd)
      assert is_binary(text)

      lines = String.split(text, "\n")
      assert length(lines) == 2

      for line <- lines do
        assert line =~ ~r/\Abash-[0-9a-f]{16} \[bash\] (running|completed|killed|failed) — .+/
        # The separator is the EM DASH (U+2014), not a hyphen.
        assert line =~ "—"
        # The label is the command's first line.
        assert line =~ "sleep 5"
      end

      assert hd(lines) =~ second.id
      assert List.last(lines) =~ first.id

      kill_and_reap(first, cwd)
      kill_and_reap(second, cwd)
    end

    test "the ownership fence hides another agent's job", %{tmp_dir: cwd} do
      other = spawn(fn -> Process.sleep(:infinity) end)
      on_exit(fn -> Process.exit(other, :kill) end)

      {:ok, foreign_job} =
        BackgroundJobs.start_job(%{command: "sleep 30", cwd: cwd, owner_pid: other})

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
    test "requests cancellation of a live job, then reports its settled state", %{tmp_dir: cwd} do
      job = start_job("sleep 30", cwd)
      pid = job_os_pid(job)

      assert JobKill.execute(%{"job_id" => job.id}, cwd, cwd) ==
               "requested cancellation of job #{job.id}"

      killed = await_job_status(job.id, :killed)
      assert killed.detail == "killed (stopped by request)"

      await_dead(pid)
      refute pid_alive?(pid)

      again = JobKill.execute(%{"job_id" => job.id}, cwd, cwd)
      assert String.starts_with?(again, "job #{job.id} had already finished [status: ")
      assert again =~ "killed (stopped by request)"
    end

    test "a custom reason is recorded on the job", %{tmp_dir: cwd} do
      job = start_job("sleep 30", cwd)
      pid = job_os_pid(job)

      assert JobKill.execute(%{"job_id" => job.id, "reason" => "no longer needed"}, cwd, cwd) ==
               "requested cancellation of job #{job.id}"

      killed = await_job_status(job.id, :killed)
      assert killed.detail == "killed (no longer needed)"

      await_dead(pid)
      refute pid_alive?(pid)
    end

    test "every failure is an Error: string and never raises", %{tmp_dir: cwd} do
      unknown = "bash-0000000000000000"

      not_found = JobKill.execute(%{"job_id" => unknown}, cwd, cwd)
      assert String.starts_with?(not_found, "Error: ")
      assert not_found =~ "No background job"

      other = spawn(fn -> Process.sleep(:infinity) end)
      on_exit(fn -> Process.exit(other, :kill) end)

      {:ok, foreign_job} =
        BackgroundJobs.start_job(%{command: "sleep 30", cwd: cwd, owner_pid: other})

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
    end

    test "a background start returns the job id and registers the job", %{tmp_dir: cwd} do
      # Two lines on purpose: the LABEL must be the command's FIRST line, and the
      # second line keeps the job live so its state is observable.
      command = "echo bg-hi\nsleep 5"

      result = ShellTool.execute(%{"command" => command, "run_in_background" => true}, cwd, cwd)
      assert result =~ ~r/\Astarted background job bash-[0-9a-f]{16}\z/

      id = String.replace_prefix(result, "started background job ", "")

      jobs = BackgroundJobs.list()
      assert [job] = jobs
      assert job.id == id
      assert job.status == :running
      assert job.label == "echo bg-hi"

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
      assert result =~ ~r/\Astarted background job bash-[0-9a-f]{16}\z/

      id = String.replace_prefix(result, "started background job ", "")
      job = await_job_status(id, :running)
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
