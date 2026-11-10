defmodule EvoGit.Sandbox.ForegroundTrackingTest do
  @moduledoc """
  End-to-end proof that a FOREGROUND command run through
  `EvoGit.Sandbox.run_with_partial/7` is anchored to a real OS execution.

  These tests drive the real `EvoGit.Sandbox` dispatcher (the active backend —
  the disabled `bash -c` path under `MIX_ENV=test`) against REAL child
  processes, so they assert what a tracked execution actually carries:

    * the tracked record gets a non-nil `os_pid` (POSIX/Windows backends) or a
      non-nil `unit` (the systemd-run backend), i.e. the previous "degraded
      pid-less foreground execution" gap is closed;
    * the record can be settled (`:completed`);
    * on the POSIX path a long-running command can be paused, resumed and
      killed through `EvoGit.ProcessManager`, which reaches the real child;
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
    test "a real command attaches a real OS pid/unit and can be settled" do
      isolated_manager!()

      {:ok, id} = ProcessManager.track(:tool_call, %{tool: "bash", command: "echo hello"})

      assert {:ok, output, 0} =
               Sandbox.run_with_partial(
                 System.tmp_dir!(),
                 "bash",
                 ["-c", "echo hello"],
                 nil,
                 10_000,
                 nil,
                 execution_id: id
               )

      assert output =~ "hello"

      # THE regression this suite exists for: the handle is NOT pid-less.
      execution = await_handle(id)
      assert execution.status == :running
      assert os_identity(execution) != nil
      assert execution.kind == :tool_call

      assert :ok = ProcessManager.finish(id, :completed)
      assert {:ok, %Execution{status: :completed}} = ProcessManager.get(id)
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
      assert {:ok, %Execution{status: :killed}} = ProcessManager.get(id)

      # The foreground call observes the child's death and returns instead of
      # waiting out its 60 s timeout.
      assert {:ok, _output, exit_code} = Task.await(task, 10_000)
      assert is_integer(exit_code)

      refute EvoGit.ProcessManager.Control.Posix.alive?(Handle.posix(os_pid))
    end
  end
end
