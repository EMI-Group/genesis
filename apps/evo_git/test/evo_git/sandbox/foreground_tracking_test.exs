defmodule EvoGit.Sandbox.ForegroundTrackingTest do
  @moduledoc """
  End-to-end proof that a FOREGROUND command run through
  `EvoGit.Sandbox.run_with_partial/7` is anchored to a real OS execution.

  These tests drive the real `EvoGit.Sandbox` dispatcher (the active backend —
  the disabled `bash -c` path under `MIX_ENV=test`) against REAL child
  processes, so they assert what a tracked execution actually carries:

    * the tracked record attaches a REAL `os_pid` (POSIX/Windows backends) or a
      REAL `unit` (the systemd-run backend) WHILE the child is alive — the OS
      pid is only readable through an open port, so a foreground child that
      exits before the pid is read legitimately keeps no OS identity — and that
      identity STAYS on the terminal record afterwards;
    * the record settles ITSELF when the sandbox layer observes the OS exit
      status, so it is already `:completed` (with its real `exit_code` and
      `reason: :exited`) by the time `run_with_partial/7` returns;
    * on the POSIX path a long-running command can be paused, resumed and
      killed through `EvoGit.ProcessManager`, which reaches the real child, and
      the operator's kill is authoritative over the signal exit it causes;
    * the TERMINAL FACTS are recorded by the helper that observes the OS exit
      status: an exit settles `:completed` + its integer `exit_code` +
      `reason: :exited`, a timeout settles `:killed` + `exit_code: nil` +
      `reason: :timeout`, and a later, coarser `finish/3` (the executor's) is a
      no-op that never clears what the helper observed.

  `async: true` — every test points the manager's documented CALL-TIME seam
  (`:evogit_process_manager_server` in the calling process dictionary) at its
  own isolated named `EvoGit.ProcessManager`, so the app-global instance is
  never read or mutated. The spawned tool process installs the SAME seam
  itself (a spawned task starts with an empty process dictionary).
  """

  use ExUnit.Case, async: true

  alias EvoGit.ProcessManager
  alias EvoGit.ProcessManager.Execution
  alias EvoGit.ProcessManager.Handle
  alias EvoGit.Sandbox

  # Long enough for a pause/resume/kill cycle, short enough to never wedge CI.
  @sleep_seconds 30

  # Popping a pid out of the OS is POSIX/Windows work either way, but the
  # command used here (`sleep`) and the signals only exist on POSIX hosts.
  @posix_skip if EvoGit.Platform.windows?(),
                do: "POSIX signals are not exercised on Windows",
                else: false

  defp uniq, do: System.unique_integer([:positive])

  # A unique scratch dir for a fixture SCRIPT and its release file. Never used
  # as a child's `cwd`: a subprocess chdir'ing into an ExUnit-style fixture dir
  # is unsafe elsewhere in this suite, so `cwd` stays `System.tmp_dir!()`.
  defp fixture_dir! do
    dir = Path.join(System.tmp_dir!(), "foreground_tracking_#{uniq()}")
    File.mkdir_p!(dir)
    on_exit(fn -> File.rm_rf!(dir) end)
    dir
  end

  # POSIX single-quoting, so a fixture path can never break out of the script
  # line that tests for it.
  defp sh_quote(value), do: "'" <> String.replace(value, "'", "'\\''") <> "'"

  # Starts an ISOLATED manager and points the calling process at it.
  defp isolated_manager! do
    name = :"foreground_tracking_manager_#{uniq()}"
    start_supervised!({ProcessManager, name: name})
    Process.put(:evogit_process_manager_server, name)
    name
  end

  # The execution's OS identity: a pid (`:posix` / `:windows`) or a unit name
  # (the systemd-run backend, which has no single child pid of its own). Both
  # are MIRRORED onto the frozen `%Execution{}` struct from its `%Handle{}`.
  defp os_identity(%Execution{os_pid: pid}) when is_integer(pid), do: {:pid, pid}

  defp os_identity(%Execution{unit: unit}) when is_binary(unit) and unit != "",
    do: {:unit, unit}

  defp os_identity(_execution), do: nil

  # Bounded poll for the execution to become :running WITH an OS identity.
  # Event-driven-ish: the attach happens synchronously inside the spawn, so
  # this resolves on the first or second look; the deadline only protects
  # against a broken backend hanging the suite.
  defp await_handle(id, deadline \\ nil) do
    deadline = deadline || System.monotonic_time(:millisecond) + 5_000

    case ProcessManager.get(id) do
      {:ok, execution} ->
        if os_identity(execution) do
          execution
        else
          retry_await_handle(id, deadline, execution)
        end

      other ->
        flunk("expected a running execution for #{id}, got: #{inspect(other)}")
    end
  end

  defp retry_await_handle(id, deadline, execution) do
    if System.monotonic_time(:millisecond) < deadline do
      Process.sleep(20)
      await_handle(id, deadline)
    else
      flunk("execution #{id} never got an OS handle, last seen: #{inspect(execution)}")
    end
  end

  # Bounded poll for a killed child to be reaped by the OS.
  defp await_dead(handle, deadline \\ nil) do
    deadline = deadline || System.monotonic_time(:millisecond) + 5_000

    cond do
      not EvoGit.ProcessManager.Control.Posix.alive?(handle) ->
        true

      System.monotonic_time(:millisecond) < deadline ->
        Process.sleep(20)
        await_dead(handle, deadline)

      true ->
        false
    end
  end

  # Bounded poll for the execution to reach a TERMINAL record (a `reason` is set
  # only once it is terminal). The settle happens synchronously in the process
  # that observed the OS exit status, so this resolves on the first look; the
  # deadline only protects against a broken settle path hanging the suite.
  defp await_terminal(id, deadline \\ nil) do
    deadline = deadline || System.monotonic_time(:millisecond) + 5_000

    case ProcessManager.get(id) do
      {:ok, %Execution{reason: reason} = execution} when not is_nil(reason) ->
        execution

      {:ok, execution} ->
        if System.monotonic_time(:millisecond) < deadline do
          Process.sleep(20)
          await_terminal(id, deadline)
        else
          flunk("execution #{id} never became terminal, last seen: #{inspect(execution)}")
        end

      other ->
        flunk("expected a tracked execution for #{id}, got: #{inspect(other)}")
    end
  end

  describe "foreground execution tracking" do
    test "a real command attaches a real OS pid/unit and settles itself on exit" do
      manager = isolated_manager!()

      # The OS pid is readable ONLY while the port is open, so a child that
      # exits before the read is honest but unobservable. This fixture holds the
      # child alive (a bounded wait for a release file, then `echo hello`) until
      # the test has asserted its identity, instead of racing a microseconds-long
      # `echo hello` whose pid window closes under host load.
      dir = fixture_dir!()
      trigger = Path.join(dir, "release")
      script = Path.join(dir, "barrier.sh")

      File.write!(script, """
      for ((i = 0; i < 200; i++)); do
        [ -e #{sh_quote(trigger)} ] && break
        sleep 0.05
      done
      echo hello
      """)

      {:ok, id} = ProcessManager.track(:tool_call, %{tool: "bash", command: "#{script}"})

      # The spawned process starts with an EMPTY process dictionary, so it must
      # install the same manager seam itself for the attach to reach this
      # test's isolated registry.
      task =
        Task.async(fn ->
          Process.put(:evogit_process_manager_server, manager)

          Sandbox.run_with_partial(
            System.tmp_dir!(),
            "bash",
            [script],
            nil,
            30_000,
            nil,
            execution_id: id
          )
        end)

      on_exit(fn ->
        # Release the barrier so a failed run never leaves the child behind (its
        # loop is bounded anyway); the task itself is LINKED to this test
        # process and dies with it.
        File.write!(trigger, "")
      end)

      # The identity is attached WHILE the child is alive, and it really is a
      # LIVE OS process, not a remembered number.
      execution = await_handle(id)
      assert {:pid, os_pid} = os_identity(execution)
      assert execution.status == :running

      unless EvoGit.Platform.windows?() do
        assert EvoGit.ProcessManager.Control.Posix.alive?(Handle.posix(os_pid))
      end

      # Release the barrier: the child ends normally (`echo hello`, exit 0).
      File.write!(trigger, "")

      assert {:ok, output, 0} = Task.await(task, 10_000)
      assert output =~ "hello"

      # THE regression this suite exists for: the handle is NOT pid-less, and a
      # command that already exited keeps its OS identity on the terminal record.
      execution = await_terminal(id)
      assert {:pid, ^os_pid} = os_identity(execution)
      assert execution.kind == :tool_call

      # The sandbox layer OBSERVES the OS exit status, so it settles the record
      # itself: by the time `run_with_partial/7` returns the call is already
      # `:completed` with its real (zero) exit code and `:exited`.
      assert execution.status == :completed
      assert execution.exit_code == 0
      assert execution.reason == :exited

      unless EvoGit.Platform.windows?() do
        # The child genuinely exited; the identity outlived it.
        assert await_dead(Handle.posix(os_pid))
      end

      # A later, coarser finish (the executor's) is a no-op on the settled record:
      # it never clears the exit code it did not observe.
      assert :ok = EvoGit.ToolRuntime.Tracking.finish(id, :completed)

      assert {:ok, after_executor} = ProcessManager.get(id)
      assert after_executor.status == :completed
      assert after_executor.exit_code == 0
      assert after_executor.reason == :exited
      assert after_executor.ended_at == execution.ended_at
    end
  end

  describe "foreground terminal facts" do
    @tag skip: @posix_skip
    test "a real exit status settles :completed with its exit code and :exited" do
      isolated_manager!()

      {:ok, id} = ProcessManager.track(:tool_call, %{tool: "bash", command: "exit 7"})

      assert {:ok, _output, 7} =
               Sandbox.run_with_partial(
                 System.tmp_dir!(),
                 "bash",
                 ["-c", "exit 7"],
                 nil,
                 10_000,
                 nil,
                 execution_id: id
               )

      # `EvoGit.Sandbox.Helpers` is the process that OBSERVES the OS exit status,
      # so it owns the terminal facts: a NON-ZERO exit still COMPLETES the
      # execution (the uniform mapping keys on "the OS process actually exited",
      # not on the status code).
      execution = await_terminal(id)
      assert execution.status == :completed
      assert execution.exit_code == 7
      assert execution.reason == :exited
      assert %DateTime{} = execution.ended_at

      # The executor's LATER, coarser finish only knows the tool call is over; it
      # must be a no-op on the already-terminal record and must never clear the
      # exit code it did not observe.
      EvoGit.ToolRuntime.Tracking.finish(id, :completed)

      assert {:ok, after_executor} = ProcessManager.get(id)
      assert after_executor.status == :completed
      assert after_executor.exit_code == 7
      assert after_executor.reason == :exited
    end

    @tag skip: @posix_skip
    test "a timeout settles :killed with no exit code and reason :timeout" do
      isolated_manager!()

      {:ok, id} = ProcessManager.track(:tool_call, %{tool: "bash", command: "sleep 5"})

      assert {:timeout, _partial} =
               Sandbox.run_with_partial(
                 System.tmp_dir!(),
                 "bash",
                 ["-c", "sleep 5"],
                 nil,
                 200,
                 nil,
                 execution_id: id
               )

      # No OS exit status was observed (the tree was killed by the timeout), so
      # there is NO integer exit code — a timeout is `:killed` + `:timeout`.
      execution = await_terminal(id)
      assert execution.status == :killed
      assert execution.exit_code == nil
      assert execution.reason == :timeout
      assert %DateTime{} = execution.ended_at
    end
  end

  describe "foreground timeout" do
    @tag skip: @posix_skip
    test "the timeout kills the whole child tree, not just a wrapper" do
      isolated_manager!()

      {:ok, id} = ProcessManager.track(:tool_call, %{tool: "bash", command: "sleep 30"})

      assert {:timeout, partial} =
               Sandbox.run_with_partial(
                 System.tmp_dir!(),
                 "bash",
                 ["-c", "sleep 30"],
                 nil,
                 300,
                 nil,
                 execution_id: id
               )

      assert partial =~ "[TRUNCATED due to timeout]"

      # The executed pid was published before the wait, and the timeout path
      # terminated the child itself (today's old `Task.shutdown` only reached a
      # `System.cmd` wrapper). Reaping is asynchronous, so poll briefly.
      execution = await_handle(id)
      assert {:pid, os_pid} = os_identity(execution)
      assert await_dead(Handle.posix(os_pid))
    end
  end

  describe "foreground execution control (POSIX)" do
    @tag skip: @posix_skip
    test "pause, resume and kill reach the real long-running child" do
      # Per-PROCESS shrink of the TERM→KILL grace
      # (`EvoGit.ProcessManager.Control.kill_grace_ms/0`): every kill below runs
      # in THIS process, and the production 1 500 ms flush window would dominate
      # the pause/resume/kill proof. A process-dictionary entry is invisible to
      # concurrently running modules and dies with the test process, so the
      # escalation itself (TERM, grace, KILL, verdict) stays exactly as shipped.
      Process.put(:process_kill_grace_ms, 0)
      manager = isolated_manager!()

      {:ok, id} =
        ProcessManager.track(:tool_call, %{tool: "bash", command: "sleep #{@sleep_seconds}"})

      cwd = System.tmp_dir!()

      # The spawned process starts with an EMPTY process dictionary, so it must
      # install the same manager seam itself for the attach to reach this
      # test's isolated registry.
      task =
        Task.async(fn ->
          Process.put(:evogit_process_manager_server, manager)

          Sandbox.run_with_partial(
            cwd,
            "bash",
            ["-c", "sleep #{@sleep_seconds}"],
            nil,
            60_000,
            nil,
            execution_id: id
          )
        end)

      on_exit(fn ->
        # Never leave a sleep behind, even if an assertion above failed. The
        # kill reaches the real child, so the foreground call returns; the task
        # itself is LINKED to this test process and dies with it.
        ProcessManager.kill(id)
      end)

      execution = await_handle(id)
      assert {:pid, os_pid} = os_identity(execution)

      assert :ok = ProcessManager.pause(id)
      assert {:ok, %Execution{status: :paused}} = ProcessManager.get(id)
      assert :ok = ProcessManager.resume(id)
      assert {:ok, %Execution{status: :running}} = ProcessManager.get(id)

      assert :ok = ProcessManager.kill(id, reason: "foreground tracking test cleanup")

      # The OPERATOR's kill is AUTHORITATIVE over the sandbox layer's own
      # observation of the signal exit it caused: the record settles `:killed`
      # with the attributable cause and NO exit code, rather than `:completed` +
      # `:exited` + the signal's 143.
      assert {:ok, killed} = ProcessManager.get(id)
      assert killed.status == :killed
      assert killed.reason == {:killed_by, :operator}
      assert killed.exit_code == nil
      # The OS identity stays on the terminal record.
      assert {:pid, ^os_pid} = os_identity(killed)

      # The foreground call observes the child's death and returns instead of
      # waiting out its 60 s timeout.
      assert {:ok, _output, exit_code} = Task.await(task, 10_000)
      assert is_integer(exit_code)

      refute EvoGit.ProcessManager.Control.Posix.alive?(Handle.posix(os_pid))
    end
  end
end
