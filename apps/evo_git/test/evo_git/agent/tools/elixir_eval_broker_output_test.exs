Code.require_file("elixir_eval_fixture_helper.exs", __DIR__)

defmodule EvoGit.Agent.Tools.ElixirEval.BrokerOutputTest do
  @moduledoc """
  Broker-level (non-Dune) captured-stdout truncation contract.

  The broker is the SINGLE enforcement point for the requested stdout budget:
  an item larger than the remaining budget is truncated to it with the
  `"\\n[output truncated]"` marker kept inside the cap, a valid-UTF-8 prefix is
  never split across a codepoint, and an exhausted budget is a bounded no-op.
  Output volume never fails an evaluation — only expired authority or a
  malformed item replies with an error.

  Async-safe: every test owns its isolated `EvoGit.Store`/`EvoGit.TaskRegistry`
  (via `EvoGit.TaskRegistryCase`), an isolated per-process config directory, and
  a genuine `EvoGit.TestSupport.ElixirEvalFixture` owner/tool Task with unique
  ETS rows. No registered names, scheduler configuration, app-env keys or
  global PubSub topics are changed, and no Dune interpreter is involved — the
  broker is driven directly over its real GenServer API.
  """
  use EvoGit.TaskRegistryCase, async: true

  alias EvoGit.Agent.Tools.ElixirEval.{Authorization, Broker}
  alias EvoGit.TestSupport.ElixirEvalFixture, as: Fixture

  @deadline 15_000
  @marker "\n[output truncated]"

  setup %{store: store, registry: registry} do
    EvoGit.TestSupport.ConfigDir.isolate!("eval_broker_output")
    fixture = Fixture.start!(self(), store, registry)
    on_exit(fn -> Fixture.stop(fixture) end)
    %{fixture: fixture}
  end

  test "an over-budget item is truncated inside the cap instead of failing the evaluation",
       %{fixture: fixture} do
    item = String.duplicate("a", 300)

    assert %{replies: [reply], output: output} = capture!(fixture, 256, [item])

    assert reply == :ok
    refute match?({:error, _}, reply)
    assert byte_size(output) == 256
    assert String.valid?(output)
    assert output == String.duplicate("a", 237) <> @marker
    assert String.starts_with?(output, String.duplicate("a", 237))
    assert String.ends_with?(output, @marker)
  end

  test "a one-megabyte item is cheaply bounded at the maximum cap", %{fixture: fixture} do
    item = String.duplicate("a", 1_000_000)

    assert %{replies: [reply], output: output} = capture!(fixture, 65_536, [item])

    assert reply == :ok
    assert byte_size(output) == 65_536
    assert String.valid?(output)
    assert output == String.duplicate("a", 65_517) <> @marker
    assert String.ends_with?(output, @marker)
  end

  test "an item exactly filling the remaining budget is stored verbatim without a marker",
       %{fixture: fixture} do
    item = String.duplicate("a", 64)

    assert %{replies: [reply], output: output} = capture!(fixture, 64, [item])

    assert reply == :ok
    assert output == item
    refute output =~ "[output truncated]"
  end

  test "cumulative writes that exactly fill the cap keep both chunks verbatim", %{
    fixture: fixture
  } do
    first = String.duplicate("a", 64)
    second = String.duplicate("b", 64)

    assert %{replies: [first_reply, second_reply], output: output} =
             capture!(fixture, 128, [first, second])

    assert first_reply == :ok
    assert second_reply == :ok
    assert output == first <> second
    refute output =~ "[output truncated]"
  end

  test "writes after the budget is exhausted are bounded no-ops that still reply :ok",
       %{fixture: fixture} do
    fill = String.duplicate("a", 32)

    assert %{replies: replies, output: output} =
             capture!(fixture, 32, [fill, "x", "y", "z"])

    assert replies == [:ok, :ok, :ok, :ok]
    assert byte_size(output) == 32
    assert output == fill
    refute output =~ "x"
    refute output =~ "[output truncated]"
  end

  test "multi-byte UTF-8 truncated at a codepoint boundary stays valid", %{fixture: fixture} do
    # Four four-byte emoji fit exactly inside a 32-byte cap, so nothing is cut.
    fits = String.duplicate("🙂", 4)
    assert byte_size(fits) == 16

    assert %{replies: [:ok], output: output} = capture!(fixture, 32, [fits])
    assert output == fits
    assert String.valid?(output)
    assert byte_size(output) <= 32
    assert String.match?(output, ~r/^🙂*(\n\[output truncated\])?$/u)

    # A 10-byte cap is below the 19-byte marker: the cut keeps whole codepoints.
    for {item, whole_codepoint_bytes} <- [
          {String.duplicate("é", 10), 2},
          {String.duplicate("🙂", 3), 4}
        ] do
      assert %{replies: [:ok], output: truncated} = capture!(fixture, 10, [item])
      assert String.valid?(truncated)
      assert byte_size(truncated) <= 10
      assert rem(byte_size(truncated), whole_codepoint_bytes) == 0
      assert String.starts_with?(item, truncated)
      refute truncated =~ "[output truncated]"
    end

    assert %{output: two_accents} = capture!(fixture, 10, [String.duplicate("é", 10)])
    assert two_accents == String.duplicate("é", 5)

    assert %{output: two_emoji} = capture!(fixture, 10, [String.duplicate("🙂", 3)])
    assert two_emoji == String.duplicate("🙂", 2)
  end

  test "an overflow followed by another write keeps replying :ok and never aborts the run",
       %{fixture: fixture} do
    item = String.duplicate("a", 100)

    assert %{replies: [first_reply, tail_reply], output: output} =
             capture!(fixture, 40, [item, "tail"])

    assert first_reply == :ok
    assert tail_reply == :ok
    assert byte_size(output) == 40
    assert output == String.duplicate("a", 21) <> @marker
    assert String.ends_with?(output, @marker)
  end

  # Drives `bins` through one real broker/worker handshake in the genuine tool
  # process and returns the per-write replies plus the captured output.
  defp capture!(fixture, cap, bins) do
    case Fixture.await(Fixture.call_async(fixture, fn -> capture(cap, bins) end)) do
      {:exit, reason} ->
        flunk("broker handshake or stdio dispatch failed: #{inspect(reason)}")

      %{replies: replies, output: output} ->
        %{replies: replies, output: output}
    end
  end

  # Runs inside the fixture's real tool Task, which is the broker's creator and
  # controller (`context.tool_pid == self()`), so it alone may start the broker,
  # attach one worker and read the captured output.
  defp capture(cap, bins) do
    {:ok, context} = Authorization.authorize()
    context = Map.put(context, :max_output_bytes, cap)
    controller = self()
    {:ok, broker} = Broker.start(context, :read, controller)

    worker = spawn(fn -> worker_loop(controller, broker) end)

    try do
      assert_receive {:ready, ^worker}, @deadline
      :ok = Broker.attach(broker, worker)
      send(worker, {:run, bins})

      replies =
        Enum.map(bins, fn _bin ->
          assert_receive {:reply, reply}, @deadline
          reply
        end)

      %{replies: replies, output: Broker.output(broker)}
    after
      Broker.stop(broker)
      if Process.alive?(worker), do: Process.exit(worker, :kill)
    end
  end

  # The trusted worker entry installs exactly the controller as its immediate
  # ancestor (never inherited from evaluated code) before announcing readiness.
  defp worker_loop(controller, broker) do
    Process.put(:"$ancestors", [controller])
    Process.put(:evogit_eval_broker, broker)
    send(controller, {:ready, self()})

    receive do
      {:run, bins} ->
        Enum.each(bins, fn bin ->
          send(controller, {:reply, Broker.call(:stdio, [bin])})
        end)
    end
  end
end
