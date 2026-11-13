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
      # A foreign viewed-node result is rejected before it can issue any worker command.
      # Commands to the capture pid are synchronous, so this mailbox probe is conclusive.
      refute_receive {:cleanup, _}, 0
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

    test "mismatched-agent snapshot fails before accepting its watermark and can retry" do
      id = unique_id()
      pending = StreamWatch.push(socket(id), id, 6, [{:text, "pending"}])
      failed = ready(pending, {:ok, snapshot(id + 1, 900), 999})
      stream = failed.assigns.inspector_stream
      assert stream.error == :snapshot_agent_mismatch
      assert stream.snapshot == nil
      assert stream.seq == nil
      assert stream.state == RuntimeStream.new(id, :inspector@host)
      assert stream.pending == []
      assert stream.buffer_bytes == 0
      refute StreamWatch.active?(failed, id)
      assert_receive {:desired, 4, nil}, @timeout
      assert StreamWatch.push(failed, id, 1_000, [{:text, "foreign watermark"}]) === failed

      retried = StreamWatch.attach(failed, id)
      assert_receive {:desired, 5, nil}, @timeout
      assert_receive {:desired, 6, %{id: ^id, token: 6}}, @timeout
      refute StreamWatch.active?(failed, id)
      assert StreamWatch.active?(retried, id)
      assert retried.assigns.inspector_stream.error == nil
      assert retried.assigns.inspector_stream.pending == []
      assert retried.assigns.inspector_stream.seq == nil

      recovered = ready(retried, {:ok, snapshot(id, 2), 2})
      assert recovered.assigns.inspector_stream.seq == 2
      assert recovered.assigns.inspector_stream.state.seq == 2
      assert recovered.assigns.inspector_stream.error == nil

      assert StreamWatch.push(recovered, id, 3, [{:text, "recovered"}]).assigns.inspector_stream.state.response ==
               "recovered"

      StreamWatch.detach(recovered)
      assert_receive {:desired, 7, nil}, @timeout
    end

    test "failed attachment preserves the last checkpoint until retry replaces it, never appends" do
      id = unique_id()
      checkpoint = [%{role: :assistant, content: "checkpoint"}]
      original = %{snapshot(id, 5) | messages: checkpoint}
      established = ready(socket(id), {:ok, original, 5})

      live =
        StreamWatch.push(established, id, 6, [{:thinking, "live thought"}, {:text, "live tail"}])

      ref = make_ref()
      monitored = Phoenix.Component.assign(live, inspector_stream_worker_monitor: ref)
      failed = StreamWatch.down(monitored, ref, self(), :crashed)
      assert failed.assigns.inspector_stream.error == {:watch_worker_down, :crashed}
      assert failed.assigns.inspector_stream.snapshot === original
      assert failed.assigns.inspector_stream.state === live.assigns.inspector_stream.state
      assert failed.assigns.inspector_stream.state.messages === checkpoint
      assert failed.assigns.inspector_stream.state.thinking == "live thought"
      assert failed.assigns.inspector_stream_worker == nil
      assert failed.assigns.inspector_stream_worker_monitor == nil
      assert_receive {:desired, 4, nil}, @timeout
      assert ready(failed, {:ok, snapshot(id, 99), 99}) === failed
      assert StreamWatch.push(failed, id, 7, [{:text, "ignored"}]) === failed

      # Reinstall only the command-capture boundary; no worker or RPC is run here.
      retried =
        failed
        |> Phoenix.Component.assign(inspector_stream_worker: self())
        |> StreamWatch.attach(id)

      assert_receive {:desired, 5, nil}, @timeout
      assert_receive {:desired, 6, %{id: ^id}}, @timeout
      assert retried.assigns.inspector_stream.state.messages == []
      assert retried.assigns.inspector_stream.state.projections == []
      assert StreamWatch.ready(retried, :inspector@host, 4, id, {:ok, original, 5}) === retried
      refute_receive {:cleanup, _}, 0

      replacement = [%{role: :assistant, content: "new checkpoint", reasoning: "saved thought"}]
      current = %{snapshot(id, 8) | messages: replacement}

      recovered =
        retried
        |> StreamWatch.push(id, 8, [{:text, "covered"}])
        |> StreamWatch.push(id, 9, [{:text, "new tail"}])
        |> ready({:ok, current, 8})

      assert recovered.assigns.inspector_stream.snapshot === current
      assert recovered.assigns.inspector_stream.state.messages === replacement
      assert recovered.assigns.inspector_stream.state.response == "new tail"
      assert recovered.assigns.inspector_stream.state.thinking == ""

      assert [%{capture_coverage: :partial, generation_complete: false}] =
               recovered.assigns.inspector_stream.state.projections

      assert recovered.assigns.inspector_stream.seq == 9
      assert recovered.assigns.inspector_stream.pending == []
      assert recovered.assigns.inspector_stream.buffer_bytes == 0
      StreamWatch.detach(recovered)
      assert_receive {:desired, 7, nil}, @timeout
    end

    test "explicit registration watermark wins and obsolete or duplicate snapshots never replace it" do
      id = unique_id()
      seeded = ready(socket(id), {:ok, {:ok, snapshot(id, 50), 5}})
      assert seeded.assigns.inspector_stream.seq == 5
      assert seeded.assigns.inspector_stream.state.seq == 5
      live = StreamWatch.push(seeded, id, 6, [{:text, "keep"}])

      for seq <- [0, 5, 6, 99] do
        assert ready(live, {:ok, snapshot(id, seq), seq}) === live
      end

      assert StreamWatch.push(live, id, 5, [{:text, "duplicate"}]) === live
      assert StreamWatch.push(live, id, 6, [{:thinking, "duplicate"}]) === live
      assert live.assigns.inspector_stream.state.response == "keep"
    end

    test "unrelated worker DOWN and pending remote contexts cannot mutate a healthy watch" do
      id = unique_id()
      ref = make_ref()
      initial = Phoenix.Component.assign(socket(id), inspector_stream_worker_monitor: ref)
      assert StreamWatch.down(initial, make_ref(), self(), :crashed) === initial
      assert StreamWatch.down(initial, ref, nil, :crashed) === initial
      switched = Phoenix.Component.assign(initial, current_node: :other@host)
      refute StreamWatch.active?(switched, id)
      assert StreamWatch.push(switched, id, 20, [{:text, "old node"}]) === switched

      pending =
        Phoenix.Component.assign(initial, current_node: node(), current_node_id: "remote-target")

      refute StreamWatch.active?(pending, id)
      assert StreamWatch.attach(pending, id) === pending
      assert StreamWatch.push(pending, id, 20, [{:text, "pending remote"}]) === pending
      assert StreamWatch.ready(pending, node(), 4, id, {:ok, snapshot(id), 5}) === pending
      refute_receive {:desired, _, _}, 0
      refute_receive {:cleanup, _}, 0
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
