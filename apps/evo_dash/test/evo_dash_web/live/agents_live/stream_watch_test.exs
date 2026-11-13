defmodule EvoDashWeb.AgentsLive.StreamWatchTest do
  use ExUnit.Case, async: true

  alias EvoDashWeb.AgentsLive.{RuntimeStream, StreamWatch}
  alias EvoGit.Agent.Stream
  alias EvoGit.Agent.State
  alias EvoGit.Agent.Stream.{Activity, Snapshot}

  @timeout 30_000

  defp blank_socket do
    target_node = :inspector@host

    %Phoenix.LiveView.Socket{
      transport_pid: self(),
      assigns: %{
        __changed__: %{},
        current_node: target_node,
        inspector_stream: nil,
        inspector_stream_token: 2,
        # Capture only the public worker command boundary, without replacing
        # the BEAM-global runner seams or calling a real session/RPC.
        inspector_stream_worker: self()
      }
    }
  end

  defp socket(id) do
    initialized =
      blank_socket() |> Phoenix.Component.assign(selected_agent_id: id) |> StreamWatch.attach(id)

    assert_receive {:desired, 3, nil}, @timeout
    assert_receive {:desired, 4, %{id: ^id, token: 4, snapshot_request: 0}}, @timeout
    initialized
  end

  defp snapshot(id, seq \\ 5), do: %Snapshot{agent_id: id, seq: seq, phase: :running}

  defp call_snapshot(id, seq, overrides \\ []) do
    call =
      Map.merge(%{id: "call-1", turn: 1, attempt: 1, text: "", thinking: ""}, Map.new(overrides))

    %{snapshot(id, seq) | activity: %{phase: :llm, current_call: call}}
  end

  defp ready(socket, result) do
    stream = socket.assigns.inspector_stream
    StreamWatch.ready(socket, stream.node, stream.token, stream.agent_id, result)
  end

  defp reconciled(socket, result) do
    stream = socket.assigns.inspector_stream

    StreamWatch.reconciled(
      socket,
      stream.node,
      stream.token,
      stream.agent_id,
      stream.snapshot_request,
      result
    )
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

      assert Enum.map(buffered.assigns.inspector_stream.pending, &elem(&1, 0)) == [4, 5, 6, 8, 9]

      assert buffered.assigns.inspector_stream.buffer_bytes ==
               Enum.sum(
                 Enum.map(buffered.assigns.inspector_stream.pending, &:erlang.external_size/1)
               )

      assert buffered.assigns.inspector_stream.state.response == ""
      snap = call_snapshot(id, 5, text: "snapshot ", thinking: "saved ")
      seeded = ready(buffered, {:ok, {:ok, snap, 5}})
      stream = seeded.assigns.inspector_stream
      assert stream.snapshot === snap
      assert stream.seq == 9
      assert stream.state.seq == 9
      assert stream.state.response == "snapshot new tail"
      assert stream.state.thinking == "saved reason"
      assert stream.state.phase == :running
      assert stream.state.activity == :llm

      assert [%{identity: %{id: "call-1"}, turn: 1, attempt: 1, capture_coverage: :complete}] =
               stream.state.projections

      assert stream.pending == []
      assert stream.buffer_bytes == 0
      assert stream.error == nil
      assert StreamWatch.active?(seeded, id)

      assert StreamWatch.push(seeded, id, 9, [{:text, "duplicate"}]) === seeded
      assert StreamWatch.push(seeded, id, 8, [{:text, "late"}]) === seeded
      newer = StreamWatch.push(seeded, id, 10, [{:text, "!"}])
      assert newer.assigns.inspector_stream.state.response == "snapshot new tail!"
    end

    test "core activity snapshot and buffered replacements keep one call through generation and tools" do
      id = unique_id()
      checkpoint = [%{role: :user, content: "objective"}]
      {activity, _} = Activity.apply(Activity.new(), {:start_call, "core-call", 3, 1})
      {activity, _} = Activity.apply(activity, {:call_phase, "core-call", :llm})
      {activity, _} = Activity.apply(activity, {:chunk, "core-call", :text, "before"})
      {activity, _} = Activity.apply(activity, {:chunk, "core-call", :thinking, "reason"})

      snap =
        Snapshot.from(
          %State{
            agent_id: id,
            agent_module: EvoGit.Agents.SelfReflective,
            depth: 0,
            node_path: "./",
            event_seq: 5,
            turn: 3,
            context: %{messages: checkpoint}
          },
          :running,
          activity: activity
        )

      {activity, chunks} = Activity.apply(activity, {:chunk, "core-call", :text, " after"})
      {activity, completed} = Activity.apply(activity, {:call_phase, "core-call", :llm_complete})
      {_activity, tools} = Activity.apply(activity, {:call_phase, "core-call", :tools})

      # The snapshot already contains pre-attachment chunks; later full activity
      # contains the replayed chunk too and must replace rather than concatenate it.
      buffered =
        socket(id)
        |> StreamWatch.push(id, 5, [{:text, "before"}, {:thinking, "reason"}])
        |> StreamWatch.push(id, 6, chunks)
        |> StreamWatch.push(id, 7, completed)
        |> StreamWatch.push(id, 7, completed)
        |> StreamWatch.push(id, 8, tools ++ [{:tool_call, "tool-1", "read"}])
        |> StreamWatch.push(id, 9, [{:tool_result, "tool-1", :ok}])

      seeded = ready(buffered, {:ok, {:ok, snap, 5}})
      stream = seeded.assigns.inspector_stream
      assert stream.snapshot === snap
      assert stream.seq == 9
      assert stream.pending == []
      assert stream.buffer_bytes == 0
      assert stream.state.messages === checkpoint
      assert stream.state.phase == :running
      assert RuntimeStream.active?(stream.state)
      assert stream.state.activity == :tools
      assert stream.state.response == "before after"
      assert stream.state.thinking == "reason"

      assert [
               %{
                 identity: %{id: "core-call"},
                 turn: 3,
                 attempt: 1,
                 generation_complete: true,
                 capture_coverage: :complete,
                 tool_calls: [%{id: "tool-1", name: "read", status: :ok}]
               }
             ] = stream.state.projections

      assert StreamWatch.push(seeded, id, 8, tools) === seeded
      assert ready(seeded, {:ok, snap, 5}) === seeded
    end

    test "core retry identity replaces the failed attempt and nil retirement survives checkpoint reattach" do
      id = unique_id()
      {activity, _} = Activity.apply(Activity.new(), {:start_call, "attempt-1", 2, 1})
      {activity, _} = Activity.apply(activity, {:call_phase, "attempt-1", :llm})
      {activity, _} = Activity.apply(activity, {:chunk, "attempt-1", :text, "failed prefix"})
      snap = %{snapshot(id) | activity: activity}
      established = ready(socket(id), {:ok, snap, 5})
      assert established.assigns.inspector_stream.state.response == "failed prefix"

      {activity, retry_wait} = Activity.apply(activity, {:call_phase, "attempt-1", :retry_wait})
      pending_retry = StreamWatch.push(established, id, 6, retry_wait)
      assert_receive {:reconcile, 4, 1}, @timeout

      assert pending_retry.assigns.inspector_stream.state ===
               established.assigns.inspector_stream.state

      retry_snapshot = %{snapshot(id, 6) | activity: activity}
      waiting = reconciled(pending_retry, {:ok, retry_snapshot, 6})
      assert waiting.assigns.inspector_stream.state.activity == :retry_wait
      assert waiting.assigns.inspector_stream.state.response == ""
      assert waiting.assigns.inspector_stream.state.projections == []
      assert waiting.assigns.inspector_stream.state.phase == :running

      {activity, start} = Activity.apply(activity, {:start_call, "attempt-2", 2, 2})
      restarted = StreamWatch.push(waiting, id, 7, start)
      assert restarted.assigns.inspector_stream.state.activity == :llm_waiting

      assert [%{identity: %{id: "attempt-2"}, turn: 2, attempt: 2}] =
               restarted.assigns.inspector_stream.state.projections

      {activity, generating} = Activity.apply(activity, {:call_phase, "attempt-2", :llm})
      {activity, chunks} = Activity.apply(activity, {:chunk, "attempt-2", :text, "success"})
      {activity, completed} = Activity.apply(activity, {:call_phase, "attempt-2", :llm_complete})

      completed_socket =
        restarted
        |> StreamWatch.push(id, 8, generating ++ chunks)
        |> StreamWatch.push(id, 9, completed)

      assert completed_socket.assigns.inspector_stream.state.response == "success"

      assert [%{identity: %{id: "attempt-2"}, generation_complete: true}] =
               completed_socket.assigns.inspector_stream.state.projections

      {idle, retired} = Activity.apply(activity, :reset)
      pending_retirement = StreamWatch.push(completed_socket, id, 10, retired)
      assert_receive {:reconcile, 4, 2}, @timeout

      assert pending_retirement.assigns.inspector_stream.state ===
               completed_socket.assigns.inspector_stream.state

      checkpoint = [%{role: :assistant, content: "success"}]
      current = %{snapshot(id, 10) | messages: checkpoint, activity: idle}
      retired_socket = reconciled(pending_retirement, {:ok, current, 10})
      assert retired_socket.assigns.inspector_stream.state.messages === checkpoint
      assert retired_socket.assigns.inspector_stream.state.activity == :idle
      assert retired_socket.assigns.inspector_stream.state.projections == []
      assert retired_socket.assigns.inspector_stream.state.response == ""
      assert retired_socket.assigns.inspector_stream.state.thinking == ""
      assert retired_socket.assigns.inspector_stream.state.tool_calls == []

      # Chunks without a current call cannot resurrect retired content.
      late = StreamWatch.push(retired_socket, id, 11, [{:text, "orphan"}, {:thinking, "orphan"}])
      assert late.assigns.inspector_stream.state.projections == []

      current = %{current | seq: 12}
      reattached = late |> StreamWatch.detach() |> StreamWatch.attach(id)
      assert_receive {:desired, 5, nil}, @timeout
      assert_receive {:desired, 6, nil}, @timeout
      assert_receive {:desired, 7, %{id: ^id, token: 7}}, @timeout
      recovered = ready(reattached, {:ok, current, 12})
      assert recovered.assigns.inspector_stream.state.messages === checkpoint
      assert recovered.assigns.inspector_stream.state.projections == []
      assert recovered.assigns.inspector_stream.state.response == ""
      assert StreamWatch.push(recovered, id, 9, completed) === recovered
      assert ready(recovered, {:ok, current, 12}) === recovered
      StreamWatch.detach(recovered)
      assert_receive {:desired, 8, nil}, @timeout
    end

    test "explicit refresh coalesces and atomically replaces checkpoint and current call before replay" do
      id = unique_id()
      old = %{call_snapshot(id, 5, text: "old live") | messages: [%{content: "old checkpoint"}]}
      established = ready(socket(id), {:ok, old, 5})
      refreshing = StreamWatch.reconcile(established)
      assert_receive {:reconcile, 4, 1}, @timeout
      assert StreamWatch.active?(refreshing, id)
      assert StreamWatch.reconcile(refreshing) === refreshing
      refute_receive {:reconcile, _, _}, 0
      refute_receive {:desired, _, _}, 0

      buffered =
        refreshing
        |> StreamWatch.push(id, 5, [{:text, "stale"}])
        |> StreamWatch.push(id, 6, [{:text, "covered"}])
        |> StreamWatch.push(id, 6, [{:text, "duplicate"}])
        |> StreamWatch.push(id, 8, [{:text, " suffix"}])
        |> StreamWatch.push(id, 7, [{:text, "out of order"}])

      assert buffered.assigns.inspector_stream.state ===
               established.assigns.inspector_stream.state

      assert Enum.map(buffered.assigns.inspector_stream.pending, &elem(&1, 0)) == [6, 8]

      for {target, token, agent, request} <- [
            {:other@host, 4, id, 1},
            {:inspector@host, 3, id, 1},
            {:inspector@host, 4, id + 1, 1},
            {:inspector@host, 4, id, 0},
            {:inspector@host, 4, id, 2}
          ] do
        assert StreamWatch.reconciled(buffered, target, token, agent, request, {:ok, old, 5}) ===
                 buffered
      end

      replacement = %{
        call_snapshot(id, 6, text: "snapshot")
        | messages: [%{content: "new checkpoint"}]
      }

      adopted = reconciled(buffered, {:ok, {:ok, replacement, 6}})
      assert adopted.assigns.inspector_stream.snapshot === replacement
      assert adopted.assigns.inspector_stream.state.messages === replacement.messages
      assert adopted.assigns.inspector_stream.state.response == "snapshot suffix"
      assert adopted.assigns.inspector_stream.seq == 8
      assert adopted.assigns.inspector_stream.pending == []
      assert adopted.assigns.inspector_stream.buffer_bytes == 0
      assert reconciled(adopted, {:ok, old, 99}) === adopted
      assert ready(adopted, {:ok, old, 99}) === adopted
      refute_receive {:cleanup, _}, 0
    end

    test "replay holds an entire replacement batch and requests the next atomic pair" do
      id = unique_id()
      original = call_snapshot(id, 5, text: "first")
      established = ready(socket(id), {:ok, original, 5})
      refreshing = StreamWatch.reconcile(established)
      assert_receive {:reconcile, 4, 1}, @timeout
      next = call_snapshot(id, 8, id: "call-2", turn: 2, text: "second")
      boundary = [{:text, "must not leak"}, {:activity, next.activity}, {:yield, "not adoption"}]

      pending =
        refreshing
        |> StreamWatch.push(id, 8, boundary)
        |> StreamWatch.push(id, 9, [{:thinking, " suffix thought"}])

      # The first snapshot is valid for its own request, but replay crosses a
      # later boundary; none of that boundary batch may touch the rendered pair.
      intermediate = %{original | seq: 6, messages: [%{content: "first checkpoint"}]}
      held = reconciled(pending, {:ok, intermediate, 6})
      assert_receive {:reconcile, 4, 2}, @timeout
      assert held.assigns.inspector_stream.snapshot === intermediate
      assert held.assigns.inspector_stream.state.messages === intermediate.messages
      assert held.assigns.inspector_stream.state.response == "first"
      assert held.assigns.inspector_stream.state.phase == :running
      assert held.assigns.inspector_stream.seq == 6
      assert Enum.map(held.assigns.inspector_stream.pending, &elem(&1, 0)) == [8, 9]
      assert StreamWatch.reconcile(held) === held
      refute_receive {:reconcile, _, _}, 0

      current = %{next | messages: [%{content: "first adopted once"}]}
      adopted = reconciled(held, {:ok, current, 8})
      assert adopted.assigns.inspector_stream.state.messages === current.messages
      assert adopted.assigns.inspector_stream.state.response == "second"
      assert adopted.assigns.inspector_stream.state.thinking == " suffix thought"
      assert adopted.assigns.inspector_stream.state.phase == :running
      assert [%{identity: %{id: "call-2"}}] = adopted.assigns.inspector_stream.state.projections
      assert adopted.assigns.inspector_stream.seq == 9
      assert adopted.assigns.inspector_stream.pending == []
      assert StreamWatch.push(adopted, id, 8, boundary) === adopted

      assert StreamWatch.reconciled(adopted, :inspector@host, 4, id, 1, {:ok, intermediate, 99}) ===
               adopted
    end

    test "boundary reconciliation failures preserve the coherent pair and require explicit retry" do
      id = unique_id()
      original = %{call_snapshot(id, 5, text: "keep") | messages: [%{content: "checkpoint"}]}

      for {result, reason} <- [
            {{:error, :offline}, :offline},
            {{:ok, snapshot(id, 5), 5}, {:snapshot_before_boundary, 5, 6}},
            {{:ok, snapshot(id + 1, 6), 6}, :snapshot_agent_mismatch},
            {{:ok, %{}, 6}, {:invalid_watch_result, {:ok, %{}, 6}}}
          ] do
        established = ready(socket(id), {:ok, original, 5})
        pending = StreamWatch.push(established, id, 6, [{:activity, Activity.new()}])
        assert_receive {:reconcile, 4, 1}, @timeout

        assert pending.assigns.inspector_stream.state ===
                 established.assigns.inspector_stream.state

        failed = reconciled(pending, result)
        assert failed.assigns.inspector_stream.error == reason
        assert failed.assigns.inspector_stream.snapshot === original

        assert failed.assigns.inspector_stream.state ===
                 established.assigns.inspector_stream.state

        assert failed.assigns.inspector_stream.pending == []
        assert failed.assigns.inspector_stream.buffer_bytes == 0
        refute StreamWatch.active?(failed, id)
        refute_subscribed(id)
        assert_receive {:desired, 4, nil}, @timeout
        assert StreamWatch.reconcile(failed) === failed
        assert StreamWatch.push(failed, id, 7, [{:text, "ignored"}]) === failed
        assert reconciled(failed, {:ok, snapshot(id, 7), 7}) === failed
        refute_receive {:reconcile, _, _}, 0
      end
    end

    test "reconciliation buffer overflow preserves the admitted checkpoint and excerpt" do
      id = unique_id()
      snap = %{call_snapshot(id, 5, text: "keep") | messages: [%{content: "checkpoint"}]}
      established = ready(socket(id), {:ok, snap, 5})
      pending = StreamWatch.push(established, id, 6, [{:activity, Activity.new()}])
      assert_receive {:reconcile, 4, 1}, @timeout

      full =
        Enum.reduce(7..133, pending, fn seq, socket ->
          StreamWatch.push(socket, id, seq, [{:text, "buffered"}])
        end)

      assert length(full.assigns.inspector_stream.pending) == 128
      assert StreamWatch.push(full, id, 133, []) === full
      failed = StreamWatch.push(full, id, 134, [])
      assert failed.assigns.inspector_stream.error == :snapshot_buffer_overflow
      assert failed.assigns.inspector_stream.state === established.assigns.inspector_stream.state
      assert failed.assigns.inspector_stream.snapshot === snap
      assert failed.assigns.inspector_stream.pending == []
      assert failed.assigns.inspector_stream.buffer_bytes == 0
      refute StreamWatch.active?(failed, id)
      refute_subscribed(id)
      assert_receive {:desired, 4, nil}, @timeout
      assert reconciled(failed, {:ok, snapshot(id, 134), 134}) === failed
      assert StreamWatch.reconcile(failed) === failed
      refute_receive {:reconcile, _, _}, 0
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

      recovered = ready(retried, {:ok, call_snapshot(id, 2), 2})
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
      original = %{call_snapshot(id, 5) | messages: checkpoint}
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
      current = %{call_snapshot(id, 8, id: "call-2", turn: 2) | messages: replacement}

      recovered =
        retried
        |> StreamWatch.push(id, 8, [{:text, "covered"}])
        |> StreamWatch.push(id, 9, [{:text, "new tail"}])
        |> ready({:ok, current, 8})

      assert recovered.assigns.inspector_stream.snapshot === current
      assert recovered.assigns.inspector_stream.state.messages === replacement
      assert recovered.assigns.inspector_stream.state.response == "new tail"
      assert recovered.assigns.inspector_stream.state.thinking == ""

      assert [
               %{
                 identity: %{id: "call-2"},
                 capture_coverage: :complete,
                 generation_complete: false
               }
             ] =
               recovered.assigns.inspector_stream.state.projections

      assert recovered.assigns.inspector_stream.seq == 9
      assert recovered.assigns.inspector_stream.pending == []
      assert recovered.assigns.inspector_stream.buffer_bytes == 0
      StreamWatch.detach(recovered)
      assert_receive {:desired, 7, nil}, @timeout
    end

    test "explicit registration watermark wins and obsolete or duplicate snapshots never replace it" do
      id = unique_id()
      seeded = ready(socket(id), {:ok, {:ok, call_snapshot(id, 50), 5}})
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
      assert StreamWatch.push(full, id, 128, [{:text, "duplicate"}]) === full
      assert StreamWatch.push(full, id, 1, [{:text, "old"}]) === full
      overflow = StreamWatch.push(full, id, 129, [])
      assert overflow.assigns.inspector_stream.error == :snapshot_buffer_overflow
      assert overflow.assigns.inspector_stream.pending == []
      assert overflow.assigns.inspector_stream.buffer_bytes == 0
      refute StreamWatch.active?(overflow, id)
      assert_receive {:desired, 4, nil}, @timeout

      oversized = StreamWatch.push(socket(id), id, 1, [{:text, String.duplicate("x", 1_048_576)}])
      assert oversized.assigns.inspector_stream.error == :snapshot_buffer_overflow
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
      socket = Phoenix.Component.assign(blank_socket(), inspector_stream_token: 4)
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

  describe "persistent terminal handoff" do
    test "ownership includes pending, failed and terminal watches but requires the selected scope" do
      id = unique_id()
      pending = socket(id)
      live = ready(pending, {:ok, call_snapshot(id, 5), 5})
      failed = ready(pending, {:error, :not_found})
      assert_receive {:desired, 4, nil}, @timeout
      final = terminal_snapshot(id, 6)
      closed = StreamWatch.closed(failed, id, final, 6)
      assert_receive {:desired, 4, nil}, @timeout

      for owned <- [pending, live, failed, closed] do
        assert StreamWatch.owns?(owned, id)
        refute StreamWatch.owns?(owned, id + 1)
        assert StreamWatch.terminal?(owned, id) == (owned === closed)
      end

      assert StreamWatch.active?(pending, id)
      assert StreamWatch.active?(live, id)
      refute StreamWatch.active?(failed, id)
      refute StreamWatch.active?(closed, id)
      refute StreamWatch.terminal?(closed, id + 1)

      for changes <- [
            [selected_agent_id: nil],
            [selected_agent_id: id + 1],
            [inspector_stream_token: 5],
            [current_node: :other@host],
            [current_node_id: "other-target"],
            [current_node: node(), current_node_id: "pending-target"]
          ],
          owned <- [pending, live, failed, closed] do
        foreign = Phoenix.Component.assign(owned, changes)
        refute StreamWatch.owns?(foreign, id)
        refute StreamWatch.terminal?(foreign, id)
        assert StreamWatch.closed(foreign, id, final, 6) === foreign
      end

      detached = StreamWatch.detach(closed)
      assert_receive {:desired, 5, nil}, @timeout
      refute StreamWatch.owns?(detached, id)
      refute StreamWatch.terminal?(detached, id)
      assert StreamWatch.closed(detached, id, final, 6) === detached
      refute_receive {:desired, _, _}, 0
    end

    test "finished delta is not a handoff; equal-watermark closure replaces and seals the final pair" do
      id = unique_id()

      original = %{
        call_snapshot(id, 5, text: "live", thinking: "live reasoning")
        | messages: [%{role: :assistant, content: "old checkpoint"}]
      }

      established = ready(socket(id), {:ok, original, 5})
      finished = StreamWatch.push(established, id, 6, [{:finished, :completed}])
      assert finished.assigns.inspector_stream.state.finished
      assert StreamWatch.owns?(finished, id)
      refute StreamWatch.terminal?(finished, id)
      assert_subscribed(id)

      final = terminal_snapshot(id, 6)
      closed = StreamWatch.closed(finished, id, final, 6)
      assert_terminal(closed, final)
      assert closed.assigns.inspector_stream.token == 4
      assert closed.assigns.inspector_stream_token == 4
      assert_receive {:desired, 4, nil}, @timeout
      refute_subscribed(id)

      assert StreamWatch.attach(closed, id) === closed
      assert StreamWatch.reconcile(closed) === closed
      assert StreamWatch.push(closed, id, 99, [{:text, "late"}]) === closed
      assert StreamWatch.closed(closed, id, final, 6) === closed
      assert StreamWatch.closed(closed, id, terminal_snapshot(id, 99), 99) === closed
      refute_receive {:desired, _, _}, 0
      refute_receive {:reconcile, _, _}, 0

      detached = StreamWatch.detach(closed)
      assert_receive {:desired, 5, nil}, @timeout
      assert detached.assigns.inspector_stream == nil
      refute StreamWatch.terminal?(detached, id)
    end

    test "freshness covers applied, boundary and buffered watermarks without sequence regression" do
      for kind <- [:applied, :boundary, :buffered] do
        id = unique_id()
        established = ready(socket(id), {:ok, call_snapshot(id, 5, text: "keep"), 5})

        {current, watermark} =
          case kind do
            :applied ->
              {StreamWatch.push(established, id, 7, [{:text, " suffix"}]), 7}

            :boundary ->
              pending = StreamWatch.push(established, id, 8, [{:activity, Activity.new()}])
              assert_receive {:reconcile, 4, 1}, @timeout
              assert pending.assigns.inspector_stream.required_seq == 8
              {pending, 8}

            :buffered ->
              pending = StreamWatch.reconcile(established)
              assert_receive {:reconcile, 4, 1}, @timeout
              {StreamWatch.push(pending, id, 10, [{:text, "buffered"}]), 10}
          end

        stale = terminal_snapshot(id, watermark - 1)
        assert StreamWatch.closed(current, id, stale, stale.seq) === current
        assert_subscribed(id)
        refute_receive {:desired, _, _}, 0
        final = terminal_snapshot(id, watermark)
        closed = StreamWatch.closed(current, id, final, watermark)
        assert_terminal(closed, final)
        assert_receive {:desired, 4, nil}, @timeout
        refute_subscribed(id)
      end
    end

    test "rejects mismatched agents, nonterminal snapshots and malformed sequence envelopes inertly" do
      id = unique_id()
      current = ready(socket(id), {:ok, call_snapshot(id, 5, text: "keep"), 5})
      final = terminal_snapshot(id, 6)

      for {agent, snap, seq} <- [
            {id + 1, terminal_snapshot(id + 1, 6), 6},
            {id, terminal_snapshot(id + 1, 6), 6},
            {id, %{final | phase: :running}, 6},
            {id, %{final | seq: 7}, 6},
            {id, %{final | seq: -1}, -1},
            {id, %{final | seq: "6"}, "6"},
            {id, Map.from_struct(final), 6},
            {id, nil, 6}
          ] do
        assert StreamWatch.closed(current, agent, snap, seq) === current
      end

      assert_subscribed(id)
      refute_receive {:desired, _, _}, 0
      refute_receive {:cleanup, _}, 0
    end

    test "closure overtakes pending registration and its buffered suffix before any snapshot is ready" do
      id = unique_id()
      pending = socket(id) |> StreamWatch.push(id, 8, [{:text, "unadmitted suffix"}])
      assert pending.assigns.inspector_stream.snapshot == nil
      assert pending.assigns.inspector_stream.buffer_bytes > 0
      stale = terminal_snapshot(id, 7)
      assert StreamWatch.closed(pending, id, stale, 7) === pending

      final = terminal_snapshot(id, 8)
      closed = StreamWatch.closed(pending, id, final, 8)
      assert_terminal(closed, final)
      assert_receive {:desired, 4, nil}, @timeout
      refute_subscribed(id)

      # These are the real public ready envelopes, delivered after direct closure.
      for result <- [
            {:error, :timeout},
            {:ok, {:error, :not_found}},
            {:ok, call_snapshot(id, 5, text: "old"), 5},
            {:ok, {:ok, call_snapshot(id, 99, text: "late"), 99}}
          ] do
        assert ready(closed, result) === closed
      end

      refute_receive {:desired, _, _}, 0
      refute_receive {:cleanup, _}, 0
    end

    test "closure overtakes reconciliation and late success or failure cannot overwrite its checkpoint" do
      id = unique_id()
      established = ready(socket(id), {:ok, call_snapshot(id, 5, text: "keep"), 5})
      pending = StreamWatch.push(established, id, 6, [{:activity, Activity.new()}])
      assert_receive {:reconcile, 4, 1}, @timeout
      buffered = StreamWatch.push(pending, id, 7, [{:thinking, "unadmitted"}])
      final = terminal_snapshot(id, 7)
      closed = StreamWatch.closed(buffered, id, final, 7)
      assert_terminal(closed, final)
      assert_receive {:desired, 4, nil}, @timeout
      refute_subscribed(id)

      for result <- [
            {:error, :offline},
            {:ok, {:error, :not_found}},
            {:ok, call_snapshot(id, 6, text: "old"), 6},
            {:ok, {:ok, call_snapshot(id, 99, text: "late"), 99}}
          ] do
        assert reconciled(closed, result) === closed
        assert ready(closed, result) === closed
      end

      assert StreamWatch.reconcile(closed) === closed
      assert StreamWatch.push(closed, id, 100, [{:activity, Activity.new()}]) === closed
      refute_receive {:desired, _, _}, 0
      refute_receive {:cleanup, _}, 0
      refute_receive {:reconcile, _, _}, 0
    end

    test "direct closure recovers a failed reconciliation without reattaching or losing final reasoning" do
      id = unique_id()
      established = ready(socket(id), {:ok, call_snapshot(id, 5, text: "keep"), 5})
      pending = StreamWatch.push(established, id, 6, [{:activity, Activity.new()}])
      assert_receive {:reconcile, 4, 1}, @timeout
      failed = reconciled(pending, {:error, :not_found})
      assert_receive {:desired, 4, nil}, @timeout
      assert failed.assigns.inspector_stream.error == :not_found
      assert failed.assigns.inspector_stream.state === established.assigns.inspector_stream.state
      assert StreamWatch.owns?(failed, id)
      refute_subscribed(id)
      # Failure cleared the buffer, but its required boundary still forbids rollback.
      assert failed.assigns.inspector_stream.pending == []
      assert failed.assigns.inspector_stream.required_seq == 6
      assert StreamWatch.closed(failed, id, terminal_snapshot(id, 5), 5) === failed
      final = terminal_snapshot(id, 6)
      closed = StreamWatch.closed(failed, id, final, 6)
      assert_terminal(closed, final)
      assert_receive {:desired, 4, nil}, @timeout
      assert reconciled(closed, {:error, :timeout}) === closed
      assert ready(closed, {:ok, call_snapshot(id, 99), 99}) === closed
      refute_receive {:desired, _, _}, 0
      refute_receive {:cleanup, _}, 0
    end
  end

  defp terminal_snapshot(id, seq) do
    %{
      snapshot(id, seq)
      | phase: :done,
        messages: [
          %{role: :user, content: "objective"},
          %{role: :assistant, content: "final answer — complete", reasoning: "final reasoning"}
        ]
    }
  end

  defp assert_terminal(socket, snapshot) do
    stream = socket.assigns.inspector_stream
    assert stream.snapshot === snapshot
    assert stream.seq == snapshot.seq
    assert stream.state.seq == snapshot.seq
    assert stream.state.messages === snapshot.messages
    assert stream.state.phase == :done
    assert stream.state.finished
    assert stream.state.response == ""
    assert stream.state.thinking == ""
    assert stream.state.projections == []
    assert stream.pending == []
    assert stream.buffer_bytes == 0
    assert stream.error == nil
    refute stream.reconciling
    assert StreamWatch.owns?(socket, snapshot.agent_id)
    assert StreamWatch.terminal?(socket, snapshot.agent_id)
    refute StreamWatch.active?(socket, snapshot.agent_id)
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
