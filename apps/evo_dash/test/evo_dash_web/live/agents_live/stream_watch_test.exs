defmodule EvoDashWeb.AgentsLive.StreamWatchTest do
  use ExUnit.Case, async: true

  alias EvoDashWeb.AgentsLive.{RuntimeStream, StreamWatch}
  alias EvoGit.Agent.Stream
  alias EvoGit.Agent.Stream.Snapshot

  @timeout 30_000

  defp socket(id, overrides \\ []) do
    target_node = :inspector@host

    stream = %{
      agent_id: id,
      node: target_node,
      token: 4,
      snapshot: nil,
      seq: nil,
      pending: [],
      buffer_bytes: 0,
      error: nil,
      state: RuntimeStream.new(id, target_node)
    }

    %Phoenix.LiveView.Socket{
      transport_pid: self(),
      assigns: %{
        __changed__: %{},
        current_node: target_node,
        inspector_stream: stream,
        inspector_stream_token: 4,
        # Capture only the public worker command boundary, without replacing
        # the BEAM-global runner seams or calling a real session/RPC.
        inspector_stream_worker: self()
      }
    }
    |> Phoenix.Component.assign(overrides)
  end

  defp snapshot(id, seq \\ 5), do: %Snapshot{agent_id: id, seq: seq, phase: :running}

  defp ready(socket, result) do
    stream = socket.assigns.inspector_stream
    StreamWatch.ready(socket, stream.node, stream.token, stream.agent_id, result)
  end

  defp unique_id, do: System.unique_integer([:positive]) + 100_000_000

  describe "snapshot barrier and buffered replay" do
    test "buffers arrival order, replays only above snapshot seq and empties buffer accounting" do
      id = unique_id()
      socket = socket(id)
      assert StreamWatch.active?(socket, id)
      refute StreamWatch.active?(socket, id + 1)

      buffered =
        socket
        |> StreamWatch.push(id, 4, [{:text, "covered"}])
        |> StreamWatch.push(id, 5, [{:thinking, "also covered"}])
        |> StreamWatch.push(id, 6, [{:text, "new"}])
        |> StreamWatch.push(id, 6, [{:text, "duplicate"}])
        |> StreamWatch.push(id, 8, [{:thinking, "reason"}])
        |> StreamWatch.push(id, 7, [{:text, "late"}])
        |> StreamWatch.push(id, 9, [{:text, " tail"}])

      assert length(buffered.assigns.inspector_stream.pending) == 7
      assert buffered.assigns.inspector_stream.buffer_bytes > 0
      assert buffered.assigns.inspector_stream.state.response == ""
      snap = snapshot(id)
      seeded = ready(buffered, {:ok, {:ok, snap, 5}})
      stream = seeded.assigns.inspector_stream
      assert stream.snapshot === snap
      assert stream.seq == 9
      assert stream.state.seq == 9
      assert stream.state.response == "new tail"
      assert stream.state.thinking == "reason"
      assert stream.pending == []
      assert stream.buffer_bytes == 0
      assert stream.error == nil
      assert StreamWatch.active?(seeded, id)

      assert StreamWatch.push(seeded, id, 9, [{:text, "duplicate"}]) === seeded
      assert StreamWatch.push(seeded, id, 8, [{:text, "late"}]) === seeded
      newer = StreamWatch.push(seeded, id, 10, [{:text, "!"}])
      assert newer.assigns.inspector_stream.state.response == "new tail!"
    end

    test "rejects foreign agents and malformed deltas before and after snapshot" do
      id = unique_id()
      initial = socket(id)
      seeded = ready(initial, {:ok, snapshot(id), 5})

      for socket <- [initial, seeded] do
        assert StreamWatch.push(socket, id + 1, 20, [{:text, "foreign"}]) === socket
        assert StreamWatch.push(socket, id, "20", [{:text, "bad seq"}]) === socket
        assert StreamWatch.push(socket, id, 20, {:text, "not a batch"}) === socket
      end
    end

    test "old node, token and agent ready messages cannot seed the current selection" do
      id = unique_id()
      socket = socket(id)
      stream = socket.assigns.inspector_stream
      result = {:ok, {:ok, snapshot(id), 5}}

      assert StreamWatch.ready(socket, :other@host, stream.token, id, result) === socket
      assert_receive {:cleanup, {:other@host, ^id}}, @timeout
      assert StreamWatch.ready(socket, stream.node, stream.token - 1, id, result) === socket
      # Same-target stale results must NOT unregister the newer watch.
      refute_receive {:cleanup, _}, 0
      other_id = id + 1
      assert StreamWatch.ready(socket, stream.node, stream.token, other_id, result) === socket
      assert_receive {:cleanup, {:inspector@host, ^other_id}}, @timeout

      seeded = ready(socket, result)
      assert ready(seeded, {:ok, {:ok, snapshot(id, 99), 99}}) === seeded
      assert seeded.assigns.inspector_stream.seq == 5
    end

    test "failed or invalid snapshots fail visibly and ignore later deltas" do
      id = unique_id()

      for {result, reason} <- [
            {{:error, :offline}, :offline},
            {{:ok, {:error, :not_found}}, :not_found},
            {{:ok, %{}, 5}, {:invalid_watch_result, {:ok, %{}, 5}}}
          ] do
        failed = socket(id) |> StreamWatch.push(id, 6, [{:text, "pending"}]) |> ready(result)
        assert failed.assigns.inspector_stream.error == reason
        assert failed.assigns.inspector_stream.pending == []
        assert failed.assigns.inspector_stream.buffer_bytes == 0
        refute StreamWatch.active?(failed, id)
        assert_receive {:desired, 4, nil}, @timeout
        assert StreamWatch.push(failed, id, 7, [{:text, "ignored"}]) === failed
        assert ready(failed, {:ok, snapshot(id), 5}) === failed
      end
    end

    test "batch count and byte limits fail explicitly rather than silently dropping deltas" do
      id = unique_id()

      full =
        Enum.reduce(1..128, socket(id), fn seq, socket ->
          StreamWatch.push(socket, id, seq, [{:text, "x"}])
        end)

      assert length(full.assigns.inspector_stream.pending) == 128
      assert full.assigns.inspector_stream.error == nil
      overflow = StreamWatch.push(full, id, 129, [])
      assert overflow.assigns.inspector_stream.error == :pre_snapshot_buffer_overflow
      assert overflow.assigns.inspector_stream.pending == []
      assert overflow.assigns.inspector_stream.buffer_bytes == 0
      refute StreamWatch.active?(overflow, id)
      assert_receive {:desired, 4, nil}, @timeout

      oversized = StreamWatch.push(socket(id), id, 1, [{:text, String.duplicate("x", 1_048_576)}])
      assert oversized.assigns.inspector_stream.error == :pre_snapshot_buffer_overflow
      assert oversized.assigns.inspector_stream.pending == []
      assert_receive {:desired, 4, nil}, @timeout
    end
  end

  describe "consumer-local lifecycle and worker command boundary" do
    test "invalid/disconnected attach is inert and healthy same-target attach is idempotent" do
      id = unique_id()
      socket = socket(id)
      assert StreamWatch.attach(socket, id) === socket

      for invalid <- [nil, 0, -1, "41"] do
        assert StreamWatch.attach(socket, invalid) === socket
      end

      disconnected = %{socket | transport_pid: nil}
      assert StreamWatch.attach(disconnected, id + 1) === disconnected
      refute_receive {:desired, _, _}, 0
    end

    test "rapid A to B to A selection unsubscribes old topics and orders monotonic desired commands" do
      a = unique_id()
      b = unique_id()
      socket = socket(a, inspector_stream: nil)
      # Subscription ownership is the calling consumer, not the worker.
      first = StreamWatch.attach(socket, a)
      assert_receive {:desired, 5, nil}, @timeout

      assert_receive {:desired, 6,
                      %{id: ^a, token: 6, node: :inspector@host, watch: watch, unwatch: unwatch}},
                     @timeout

      assert is_function(watch, 3)
      assert is_function(unwatch, 3)
      assert_subscribed(a)

      second = StreamWatch.attach(first, b)
      assert_receive {:desired, 7, nil}, @timeout
      assert_receive {:desired, 8, %{id: ^b, token: 8}}, @timeout
      refute_subscribed(a)
      assert_subscribed(b)

      third = StreamWatch.attach(second, a)
      assert_receive {:desired, 9, nil}, @timeout
      assert_receive {:desired, 10, %{id: ^a, token: 10}}, @timeout
      refute_subscribed(b)
      assert_subscribed(a)
      assert StreamWatch.ready(third, :inspector@host, 6, a, {:ok, snapshot(a), 5}) === third
      refute_receive {:cleanup, _}, 0

      detached = StreamWatch.detach(third)
      assert_receive {:desired, 11, nil}, @timeout
      assert detached.assigns.inspector_stream == nil
      assert detached.assigns.inspector_stream_token == 11
      refute StreamWatch.active?(detached, a)
      refute_subscribed(a)
      assert StreamWatch.push(detached, a, 20, [{:text, "late"}]) === detached
      assert StreamWatch.detach(detached).assigns.inspector_stream_token == 12
      assert_receive {:desired, 12, nil}, @timeout
    end

    test "failure removes the local subscription before requesting remote cleanup" do
      id = unique_id()
      assert :ok = Stream.subscribe(id)
      assert_subscribed(id)
      failed = ready(socket(id), {:error, :offline})
      assert failed.assigns.inspector_stream.error == :offline
      refute_subscribed(id)
      assert_receive {:desired, 4, nil}, @timeout
    end
  end

  defp assert_subscribed(id) do
    marker = make_ref()
    assert :ok = Phoenix.PubSub.broadcast(EvoGit.PubSub, Stream.topic(id), marker)
    assert_receive ^marker, @timeout
    # Broadcast dispatch has completed synchronously; duplicate subscriptions
    # would already have delivered a second copy into this mailbox.
    refute_receive ^marker, 0
  end

  defp refute_subscribed(id) do
    marker = make_ref()
    assert :ok = Phoenix.PubSub.broadcast(EvoGit.PubSub, Stream.topic(id), marker)
    # Synchronous dispatch is the drain witness, not a timed quiet-window guess.
    refute_receive ^marker, 0
  end
end
