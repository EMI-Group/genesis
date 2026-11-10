defmodule EvoGit.ToolRuntimeTrackingTest do
  @moduledoc """
  Pins the PER-CALL backend of the managed tool-call runtime's tracking records
  (`EvoGit.ToolRuntime.Tracking` + `EvoGit.ProcessManager`), which is what makes
  a non-shell tool call a `:builtin` execution:

    * a tool that runs INSIDE the BEAM (any non-shell tool) is tracked with
      `backend: :builtin` and settles `:completed` + `reason: :no_os_process`,
      with no `exit_code` and no `stats` — there is no OS process to sample;
    * `EvoGit.ProcessManager.Execution.builtin?/1` / `external?/1` /
      `sampleable?/1` classify it, and EVERY OS-facing control call
      (`sample/2`, `signal/3`, `pause/2`, `resume/2`, `kill/2`) answers
      `{:error, :no_os_process}` instead of raising — `kill/2` in particular
      leaves the record untouched;
    * sampling SKIPS builtin records: `ProcessManager.sample_all/1` omits them
      and `EvoGit.ProcessManager.Registry.live/1` never lists them.

  ## Why the `write` tool
  `EvoGit.Agent.Tools.serial_tool?/1` puts every non-shell write tool in the
  SERIAL group, which `EvoGit.ToolRuntime.Executor` runs in the REQUEST's own
  process — so the isolated manager seam installed here (the
  `:evogit_process_manager_server` process-dictionary key, read at CALL time by
  `EvoGit.ProcessManager.server/0`) also reaches the tracking call. A tool in
  the CONCURRENT group runs inside a `Task.async_stream` worker that does NOT
  inherit a test process dictionary, so those pins live in
  `tool_runtime_test.exs`, which filters the app-global registry by a per-test
  unique `agent_id` and additionally pins the SHELL call's resolved sandbox
  backend.

  ## Isolation
  `async: true` — every test starts its OWN uniquely-named
  `EvoGit.ProcessManager`, nothing here touches the app-global registry, the
  app-global scheduler's slot pools (the request's `agent_id` is unique per
  test) or the fake-tool app-env registry. Every assertion is additionally
  filtered by that unique `agent_id`.
  """
  use ExUnit.Case, async: true

  @moduletag :tmp_dir

  alias EvoGit.ProcessManager
  alias EvoGit.ProcessManager.Execution
  alias EvoGit.ProcessManager.Registry
  alias EvoGit.ProcessManager.Stats
  alias EvoGit.ToolRuntime
  alias EvoGit.ToolRuntime.Tracking
  alias ReqLLM.ToolCall

  @max_timeout 30_000

  setup do
    manager = :"evogit_tool_tracking_manager_#{:erlang.unique_integer([:positive])}"
    start_supervised!({ProcessManager, name: manager})
    Process.put(:evogit_process_manager_server, manager)

    agent_id = 9_900_000 + :erlang.unique_integer([:positive])
    task_id = "tool_runtime_tracking_#{:erlang.unique_integer([:positive])}"

    %{manager: manager, agent_id: agent_id, task_id: task_id}
  end

  test "a non-shell call is tracked as :builtin and settles :completed / :no_os_process", %{
    manager: manager,
    agent_id: agent_id,
    task_id: task_id,
    tmp_dir: tmp_dir
  } do
    target = Path.join(tmp_dir, "builtin-note.txt")

    calls =
      indexed([
        tool_call("write", %{"file_path" => target, "content" => "hello builtin"})
      ])

    assert [{0, _, "write", output}] =
             ToolRuntime.execute_batch(calls, request(agent_id, task_id, tmp_dir))

    assert is_binary(output)

    assert [execution] = tool_executions(manager, agent_id)
    assert execution.kind == :tool_call
    assert execution.tool == "write"
    assert execution.status == :completed
    # Inside the BEAM: no OS process ever backed this call.
    assert execution.backend == :builtin
    assert execution.reason == :no_os_process
    assert execution.exit_code == nil
    assert execution.os_pid == nil
    assert execution.unit == nil
    assert execution.stats == Stats.empty()
    assert Execution.builtin?(execution)
    refute Execution.external?(execution)
    refute Execution.sampleable?(execution)
  end

  test "sampling omits a builtin execution", %{
    manager: manager,
    agent_id: agent_id,
    task_id: task_id,
    tmp_dir: tmp_dir
  } do
    execution = track_builtin!(manager, agent_id, task_id, tmp_dir)
    assert execution.backend == :builtin

    # No OS process → nothing to sample, so neither the sampling surface nor
    # the registry's live roster reports it (a live-but-unattached record would
    # otherwise be sampled).
    assert ProcessManager.sample_all(server: manager) == %{}
    assert Registry.live(manager) == []
    # It is still a first-class, listable record.
    assert [listed] = ProcessManager.list(server: manager)
    assert listed.id == execution.id
  end

  test "every OS-facing control call on a builtin execution answers :no_os_process", %{
    manager: manager,
    agent_id: agent_id,
    task_id: task_id,
    tmp_dir: tmp_dir
  } do
    execution = track_builtin!(manager, agent_id, task_id, tmp_dir)

    assert {:error, :no_os_process} = ProcessManager.sample(execution.id, server: manager)
    assert {:error, :no_os_process} = ProcessManager.signal(execution.id, :term, server: manager)
    assert {:error, :no_os_process} = ProcessManager.pause(execution.id, server: manager)
    assert {:error, :no_os_process} = ProcessManager.resume(execution.id, server: manager)

    assert {:error, :no_os_process} =
             ProcessManager.kill(execution.id,
               server: manager,
               reason: "builtin_kill_attempt",
               actor: :operator
             )

    # A refused kill leaves the record exactly as it was: still live, no
    # control-log entry, no terminal fact.
    assert {:ok, after_kill} = ProcessManager.get(execution.id, server: manager)
    assert after_kill.status == :running
    assert after_kill.reason == nil
    assert after_kill.exit_code == nil
    assert after_kill.control_log == []
    assert after_kill.ended_at == nil
  end

  test "an attached handle never downgrades :builtin", %{
    manager: manager,
    agent_id: agent_id,
    task_id: task_id,
    tmp_dir: tmp_dir
  } do
    execution = track_builtin!(manager, agent_id, task_id, tmp_dir)

    assert :ok =
             ProcessManager.attach(
               execution.id,
               EvoGit.ProcessManager.Handle.posix(424_242),
               server: manager
             )

    assert {:ok, attached} = ProcessManager.get(execution.id, server: manager)
    # A builtin record stays builtin even when an OS identity is attached to it.
    assert attached.backend == :builtin
    assert Execution.builtin?(attached)
    assert attached.os_pid == 424_242
  end

  # ---------------------------------------------------------------------------
  # Helpers
  # ---------------------------------------------------------------------------

  # One builtin `:tool_call` execution tracked through the SAME entry point the
  # executor uses, so the pins do not depend on a tool dispatch.
  defp track_builtin!(manager, agent_id, task_id, tmp_dir) do
    request = request(agent_id, task_id, tmp_dir)
    execution_id = Tracking.track(request, "write", %{"file_path" => "./a.txt"}, :builtin)
    assert is_binary(execution_id)
    assert {:ok, execution} = ProcessManager.get(execution_id, server: manager)
    assert execution.backend == :builtin
    assert execution.status == :running
    execution
  end

  defp request(agent_id, task_id, tmp_dir) do
    EvoGit.ToolRuntime.Request.new(
      agent_id: agent_id,
      task_id: task_id,
      agent_pid: self(),
      repo_path: tmp_dir,
      repo_root: tmp_dir,
      node_path: nil,
      taskdir: nil,
      max_timeout: @max_timeout,
      delegation_level: :high,
      agent_module: EvoGit.Agents.Executor
    )
  end

  defp indexed(calls), do: Enum.with_index(calls)

  defp tool_call(name, args) do
    ToolCall.new(
      "call_#{name}_#{:erlang.unique_integer([:positive])}",
      name,
      Jason.encode!(args)
    )
  end

  defp tool_executions(manager, agent_id) do
    manager
    |> ProcessManager.list(agent_id: agent_id)
    |> Enum.filter(&(&1.kind == :tool_call))
  end
end
