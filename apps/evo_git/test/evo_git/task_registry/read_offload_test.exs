defmodule EvoGit.TaskRegistry.ReadOffloadTest do
  @moduledoc """
  Unit coverage for `EvoGit.TaskRegistry.ReadOffload` — the supervised,
  deadline-bounded read offload behind every large-decode `TaskRegistry` read.

  The caller side is simulated with a `{pid, ref}` pair, exactly the `from` a
  `GenServer.call/3` passes: a `GenServer.reply(from, value)` then arrives in
  this process as `{ref, value}`.

  Pinned here:

    * the worker replies to the CALLER directly (the decoded term never travels
      through the registry), and its `:DOWN` settles the pending entry;
    * a worker that dies WITHOUT replying has its caller answered with that
      read's degraded value, and the fault is logged at `:error`;
    * a wedged worker is killed at the deadline (`:brutal_kill`, so it can never
      reply afterwards) and its caller gets the degraded value;
    * settling an unknown ref is a no-op (`:unknown` / unchanged map), so a
      `:DOWN` from anything else is left to the registry's wrapper handlers.
  """

  use ExUnit.Case, async: true

  import ExUnit.CaptureLog

  alias EvoGit.TaskRegistry.ReadOffload

  test "the worker replies to the caller directly and its :DOWN settles the entry" do
    {from, call_ref} = fake_caller()

    pending =
      ReadOffload.start(ReadOffload.new(), "list_tasks", [], from, fn -> [%{id: "t1"}] end)

    assert map_size(pending) == 1
    assert ReadOffload.offload?(pending, worker_ref(pending))

    assert_receive {^call_ref, [%{id: "t1"}]}, 1_000

    assert {:settled, settled} = ReadOffload.settle_down(pending, worker_ref(pending), :normal)
    assert settled == %{}
    refute ReadOffload.offload?(settled, worker_ref(pending))
  end

  test "a worker that dies without replying answers the caller with the degraded value" do
    {from, call_ref} = fake_caller()

    pending =
      ReadOffload.start(
        ReadOffload.new(),
        "list_task_archives",
        %{entries: [], total: 0},
        from,
        fn ->
          Process.sleep(30_000)
        end
      )

    worker = worker(pending)
    Process.exit(worker.pid, :kill)

    log =
      capture_log(fn ->
        assert {:settled, settled} = ReadOffload.settle_down(pending, worker.ref, :killed)
        assert settled == %{}
        assert_receive {^call_ref, %{entries: [], total: 0}}, 1_000
      end)

    assert log =~ "the read worker for list_task_archives FAILED"
    assert log =~ ":killed"
  end

  test "a wedged worker is killed at the deadline and the caller gets the degraded value" do
    {from, call_ref} = fake_caller()

    pending =
      ReadOffload.start(ReadOffload.new(), "get_task_lite", nil, from, fn ->
        Process.sleep(30_000)
      end)

    worker = worker(pending)

    log =
      capture_log(fn ->
        assert ReadOffload.settle_deadline(pending, worker.ref) == %{}
        assert_receive {^call_ref, nil}, 1_000
      end)

    assert log =~ "the read worker for get_task_lite FAILED"
    assert log =~ "timeout"
    assert_down(worker.pid)
  end

  test "an unknown ref leaves the pending map untouched" do
    {from, _call_ref} = fake_caller()
    pending = ReadOffload.start(ReadOffload.new(), "op", :degraded, from, fn -> :ok end)
    unknown = make_ref()

    refute ReadOffload.offload?(pending, unknown)
    assert ReadOffload.settle_down(pending, unknown, :normal) == :unknown
    assert ReadOffload.settle_deadline(pending, unknown) == pending
  end

  # `GenServer.from()` for a caller in this process.
  defp fake_caller do
    call_ref = make_ref()
    {{self(), call_ref}, call_ref}
  end

  defp worker_ref(pending), do: pending |> Map.keys() |> hd()
  defp worker(pending), do: pending |> Map.fetch!(worker_ref(pending)) |> Map.fetch!(:task)

  # The wedged worker must be DEAD after the deadline settle (a monitored wait
  # instead of a fixed sleep; `Task.shutdown/2` already flushed its own ref).
  defp assert_down(pid) do
    ref = Process.monitor(pid)
    assert_receive {:DOWN, ^ref, :process, ^pid, _reason}, 1_000
  end
end
