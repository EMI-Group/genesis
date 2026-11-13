defmodule EvoDashWeb.AgentsStreamIntegrationTest.ConnectionManager do
  use GenServer

  def start_link({id, remote}), do: GenServer.start_link(__MODULE__, {id, remote})

  @impl true
  def init({id, remote}) do
    {:ok, _} = Registry.register(EvoGit.RemoteConnection.Registry, id, :status)
    {:ok, %{phase: :connected, node: Atom.to_string(remote), last_error: nil}}
  end

  @impl true
  def handle_call(:status, _from, status), do: {:reply, status, status}
end

# The fixture module is defined before the case module so it is available even
# when this file is loaded on its own.
# This synthetic transport suite intentionally keeps cohesive mounted state
# machines together; the reference-scoped runner/teardown helpers account for its
# length and let each scenario reuse one mount without timing-based waits.
# Snapshots and batches match the core contract, but do not replace real Session
# producer/consumer integration coverage.
defmodule EvoDashWeb.AgentsStreamIntegrationTest do
  # These BEAM-global app-env seams overlap the async AgentsLiveTest loaders:
  # :agents_list_runner, :agents_config_runner and :agents_history_runner.
  # :agents_watch_runner / :agents_unwatch_runner also control supervised workers.
  # Restore them only after the mounted consumer and its worker have exited.
  use EvoDashWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias EvoGit.Agent.Stream.Snapshot

  @budget 30_000
  @seams [
    :agents_list_runner,
    :agents_config_runner,
    :agents_history_runner,
    :agents_watch_runner,
    :agents_unwatch_runner
  ]

  setup do
    owner = self()
    id = System.unique_integer([:positive]) + 20_000_000
    saved = Map.new(@seams, &{&1, Application.fetch_env(:evo_dash, &1)})
    calls = :atomics.new(2, [])
    Process.put(:inspector_runner_calls, calls)
    EvoDash.Test.ConfigDir.isolate!()

    Application.put_env(:evo_dash, :agents_list_runner, fn _ ->
      Enum.map([id, id + 1], &summary/1)
    end)

    Application.put_env(:evo_dash, :agents_config_runner, fn _ -> {:ok, %{}} end)

    Application.put_env(:evo_dash, :agents_watch_runner, fn target, agent, consumer ->
      :atomics.add(calls, 1, 1)

      case request(owner, {:watch, target, agent, consumer}) do
        {:exit, reason} -> exit(reason)
        result -> result
      end
    end)

    Application.put_env(:evo_dash, :agents_unwatch_runner, fn target, agent, consumer ->
      send(owner, {:unwatch, target, agent, consumer})
      :ok
    end)

    # A watched inspector owns history through atomic watch snapshots only.
    # Count unexpected independent reads without blocking teardown on a bad call.
    Application.put_env(:evo_dash, :agents_history_runner, fn target, agent ->
      :atomics.add(calls, 2, 1)
      send(owner, {:unexpected_history, target, agent})
      []
    end)

    on_exit(fn ->
      for {key, previous} <- saved do
        case previous do
          {:ok, value} -> Application.put_env(:evo_dash, key, value)
          :error -> Application.delete_env(:evo_dash, key)
        end
      end
    end)

    {:ok, id: id}
  end

  test "selected consumer renders response and thinking with authoritative activity", %{
    conn: conn,
    id: id
  } do
    view = mount_inspector(conn)
    select(view, id)
    watch = watch_request(view, id)
    reply(watch, snapshot(id, 4, [message(:user, "Checkpoint question")]))
    await_snapshot(view, 4)

    assert has_element?(view, "#agent-detail-#{id}", "Checkpoint question")
    assert text(view, "#inspector-activity") == "Idle"
    assert assigns(view).inspector_stream.snapshot.phase == :running
    refute has_element?(view, "#inspector-thinking")

    delta(view, id, 5, [
      {:activity, activity(:llm, call())},
      {:thinking, "Compare the alternatives."},
      {:text, "The answer is "}
    ])

    assert text(view, "#inspector-activity") == "Generating response"
    assert has_element?(view, "#inspector-thinking[role='status']")
    assert has_element?(view, "#inspector-stream-cursor")
    assert text(view, "#inspector-stream details pre") == "Compare the alternatives."
    assert text(view, "#inspector-live-message-0 div pre") == "The answer is"

    # Accounting and announcements do not override activity. Only an explicit
    # successful-generation replacement stops the generation indicators.
    delta(view, id, 6, [
      {:text, "42."},
      {:turn, %{turn: 1}},
      {:tool_call, "read-1", "read"}
    ])

    assert text(view, "#inspector-activity") == "Generating response"
    assert has_element?(view, "#inspector-stream li", "Announced")
    assert has_element?(view, "#inspector-stream-cursor")
    assert has_element?(view, "#inspector-thinking")

    complete = call("The answer is 42.", "Compare the alternatives.")
    delta(view, id, 7, [{:activity, activity(:llm_complete, complete)}])
    assert text(view, "#inspector-activity") == "Response generated"
    refute has_element?(view, "#inspector-stream-cursor")
    refute has_element?(view, "#inspector-thinking")

    delta(view, id, 8, [{:activity, activity(:tools, complete)}])
    assert text(view, "#inspector-activity") == "Executing tools"
    assert text(view, "#inspector-stream details pre") == "Compare the alternatives."
    assert text(view, "#inspector-live-message-0 div pre") == "The answer is 42."
    assert length(elements(view, "#inspector-stream article")) == 1
    assert history_calls(view) == 0

    delta(view, id, 9, [{:activity, activity(:retry_wait, complete)}])
    assert text(view, "#inspector-activity") == "Waiting to retry"
    assert text(view, "#inspector-live-message-0 div pre") == "The answer is 42."
    retry = call("", "", 1, 2)
    delta(view, id, 10, [{:activity, activity(:llm_waiting, retry)}])
    refresh = watch_request(view, id)
    # Replacing a call freezes the old coherent pair until an atomic snapshot.
    assert text(view, "#inspector-activity") == "Waiting to retry"
    assert text(view, "#inspector-live-message-0 div pre") == "The answer is 42."
    reply(refresh, snapshot(id, 10, [], activity(:llm_waiting, retry)))
    await_snapshot(view, 10)
    assert text(view, "#inspector-activity") == "Waiting for model capacity"
    refute has_element?(view, "#inspector-live-message-0")
    refute text(view, "#inspector-stream") =~ "The answer is 42."
    delta(view, id, 11, [{:activity, activity(:llm, retry)}, {:text, "Retry answer"}])
    assert text(view, "#inspector-live-message-1 div pre") == "Retry answer"
    assert has_element?(view, "#inspector-thinking")
    delta(view, id, 12, [{:activity, activity(:idle, nil)}])
    refresh = watch_request(view, id)
    assert text(view, "#inspector-live-message-1 div pre") == "Retry answer"
    reply(refresh, snapshot(id, 12))
    await_snapshot(view, 12)
    assert text(view, "#inspector-activity") == "Idle"
    refute has_element?(view, "#inspector-stream article")
    assert assigns(view).inspector_stream.state.phase == :running
    assert history_calls(view) == 0
  end

  test "buffered deltas replay strictly above the snapshot watermark and watched counts never refetch",
       %{
         conn: conn,
         id: id
       } do
    view = mount_inspector(conn)
    select(view, id)
    watch = watch_request(view, id)
    assert has_element?(view, "#inspector-stream", "Connecting to live updates…")

    delta(view, id, 9, [{:activity, activity(:llm, call("Already checkpointed"))}])

    delta(view, id, 11, [
      {:activity, activity(:llm, call("Live", "Observed reasoning"))},
      {:text, " suffix"}
    ])

    delta(view, id, 11, [{:text, "DUPLICATE"}])
    delta(view, id, 10, [{:text, "STALE"}])
    # Duplicate and out-of-order deliveries consume no pending capacity.
    assert Enum.map(assigns(view).inspector_stream.pending, &elem(&1, 0)) == [9, 11]

    assert assigns(view).inspector_stream.buffer_bytes ==
             Enum.sum(Enum.map(assigns(view).inspector_stream.pending, &:erlang.external_size/1))

    update_count(view, id, 8)
    assert history_calls(view) == 0

    reply(
      watch,
      snapshot(
        id,
        10,
        [message(:assistant, "Snapshot response")],
        activity(:llm, call("Snapshot prefix", "Snapshot thought"))
      )
    )

    await_snapshot(view, 11)

    assert assigns(view).inspector_stream.pending == []
    assert assigns(view).inspector_stream.buffer_bytes == 0
    assert text(view, "#inspector-stream details pre") == "Observed reasoning"
    assert text(view, "#inspector-live-message-0 div pre") == "Live suffix"
    assert has_element?(view, "#agent-detail-#{id}", "Snapshot response")

    delta(view, id, 11, [{:text, "DUPLICATE"}])
    delta(view, id, 8, [{:text, "STALE"}])
    # Direct delivery exercises the ownership guard even if an old message was
    # already queued when the consumer unsubscribed from a different agent.
    send(view.pid, {:agent_delta, id + 1, 99, [{:text, "FOREIGN"}]})
    update_count(view, id, 12)

    assert assigns(view).inspector_stream.seq == 11
    assert text(view, "#inspector-live-message-0 div pre") == "Live suffix"
    refute render(view) =~ "DUPLICATE"
    refute render(view) =~ "STALE"
    refute render(view) =~ "FOREIGN"
    assert history_calls(view) == 0
  end

  test "incomplete capture never claims that a completed response had no thinking", %{
    conn: conn,
    id: id
  } do
    view = mount_inspector(conn)
    select(view, id)
    reply(watch_request(view, id), snapshot(id, 0))
    await_snapshot(view, 0)

    # Deliberately incomplete producer capture cannot establish absence, even
    # when the authoritative phase says successful generation has completed.
    partial_call = call("Partial capture response") |> Map.delete(:thinking)
    delta(view, id, 1, [{:activity, activity(:llm, partial_call)}])
    delta(view, id, 2, [{:activity, activity(:llm_complete, partial_call)}])
    assert has_element?(view, "#inspector-stream", "Partial capture response")
    refute text(view, "#inspector-stream") =~ "No thinking content available"
    assert [partial] = assigns(view).inspector_stream.state.projections
    assert partial.generation_complete
    assert partial.capture_coverage == :partial

    # A fresh call replaces rather than retains the partial attempt. Explicit
    # empty thinking in a complete replacement proves absence only on success.
    complete_call = call("Fully observed response", "", 2)
    delta(view, id, 3, [{:activity, activity(:llm, complete_call)}])
    refresh = watch_request(view, id)
    assert text(view, "#inspector-live-message-0 div pre") == "Partial capture response"
    reply(refresh, snapshot(id, 3, [], activity(:llm, complete_call)))
    await_snapshot(view, 3)
    refute text(view, "#inspector-stream") =~ "No thinking content available"
    delta(view, id, 4, [{:activity, activity(:llm_complete, complete_call)}])

    refute has_element?(view, "#inspector-live-message-0")
    assert text(view, "#inspector-live-message-1") =~ "No thinking content available"
    assert text(view, "#inspector-live-message-1 div pre") == "Fully observed response"
    assert length(elements(view, "#inspector-stream article")) == 1
  end

  test "selection, close and actual node patches clean up the consumer subscription", %{
    conn: conn,
    id: id
  } do
    view = mount_inspector(conn)
    select(view, id)
    reply(watch_request(view, id), snapshot(id, 1))
    await_snapshot(view, 1)
    old = assigns(view).inspector_stream
    delta(view, id, 2, [{:activity, activity(:llm, call("First agent excerpt"))}])

    select(view, id + 1)
    local = node()
    consumer = view.pid
    assert_receive {:unwatch, ^local, ^id, ^consumer}, @budget
    reply(watch_request(view, id + 1), snapshot(id + 1, 3))
    await_snapshot(view, 3)
    assert assigns(view).selected_agent_id == id + 1
    refute render(view) =~ "First agent excerpt"

    send(view.pid, {:agent_delta, id, 100, [{:activity, activity(:llm, call("Obsolete delta"))}]})
    send(view.pid, {:inspector_stream_ready, local, old.token, id, snapshot(id, 100)})
    assert assigns(view).inspector_stream.agent_id == id + 1
    assert assigns(view).inspector_stream.seq == 3
    refute render(view) =~ "Obsolete delta"

    view |> element("button[phx-click='close_details']") |> render_click()
    other = id + 1
    assert_receive {:unwatch, ^local, ^other, ^consumer}, @budget
    assert assigns(view).inspector_stream == nil
    refute has_element?(view, "#inspector-stream")
    delta(view, id + 1, 4, [{:activity, activity(:llm, call("Unsubscribed"))}])
    assert assigns(view).inspector_stream == nil

    select(view, id)
    reply(watch_request(view, id), snapshot(id, 5))
    await_snapshot(view, 5)
    token = assigns(view).inspector_stream.token

    # A real known-but-disconnected target changes scope without fabricating a
    # remote BEAM or mutating the mounted socket. Pending targets cannot watch.
    {:ok, target} =
      EvoGit.RemoteConnections.save(%{
        name: "Stream target",
        ssh_target: "test@stream.invalid"
      })

    render_patch(view, "/agents?node=#{target.id}")
    assert_receive {:unwatch, ^local, ^id, ^consumer}, @budget
    assert assigns(view).current_node_id == target.id
    assert assigns(view).selected_agent_id == nil
    assert assigns(view).inspector_stream == nil
    assert assigns(view).history_gate == %{}
    refute has_element?(view, "#inspector-stream")

    send(view.pid, {:inspector_stream_ready, local, token, id, snapshot(id, 50)})
    delta(view, id, 51, [{:activity, activity(:llm, call("Previous node excerpt"))}])
    assert assigns(view).inspector_stream == nil
    refute render(view) =~ "Previous node excerpt"

    remote = :inspector_stream_fixture@localhost
    start_supervised!({__MODULE__.ConnectionManager, {target.id, remote}})
    render_patch(view, "/agents?node=#{target.id}")
    await_loaded(view)
    assert assigns(view).current_node == remote
    select(view, id)
    reply(watch_request(view, id), snapshot(id, 40, [message(:user, "Remote checkpoint")]))
    await_snapshot(view, 40)
    assert assigns(view).inspector_stream.node == remote
    assert has_element?(view, "#agent-detail-#{id}", "Remote checkpoint")

    send(view.pid, {:inspector_stream_ready, local, token, id, snapshot(id, 50)})
    assert assigns(view).inspector_stream.seq == 40

    assert assigns(view).inspector_stream.snapshot.messages == [
             message(:user, "Remote checkpoint")
           ]

    render_patch(view, "/agents")
    assert_receive {:unwatch, ^remote, ^id, ^consumer}, @budget
    await_loaded(view)
    assert assigns(view).current_node == local
    assert assigns(view).selected_agent_id == nil
    assert assigns(view).inspector_stream == nil
    refute render(view) =~ "Remote checkpoint"
    select(view, id)
    reply(watch_request(view, id), snapshot(id, 60))
    await_snapshot(view, 60)
    assert assigns(view).inspector_stream.token > token
    assert history_calls(view) == 0
  end

  test "replacement and retirement hand off checkpoint and live content atomically", %{
    conn: conn,
    id: id
  } do
    view = mount_inspector(conn)
    initial = [message(:user, "Question")]
    a = call("Answer A", "Reason A")
    b = call("Answer B", "Reason B", 2)
    select(view, id)
    reply(watch_request(view, id), snapshot(id, 10, initial, activity(:llm_complete, a)))
    await_snapshot(view, 10)

    delta(view, id, 11, [
      {:activity, activity(:idle, nil)},
      {:activity, activity(:llm, b)},
      {:text, " prefix"}
    ])

    refresh = watch_request(view, id)
    assert history_content(view, id) == ["Question"]
    assert text(view, "#inspector-live-message-0 div pre") == "Answer A"
    refute render(view) =~ "Answer B"
    delta(view, id, 12, [{:text, " suffix"}])
    delta(view, id, 12, [{:text, "DUPLICATE"}])

    answer_a = %{message(:assistant, a.text) | reasoning_details: [%{text: a.thinking}]}
    checkpoint = initial ++ [answer_a]
    reply(refresh, snapshot(id, 11, checkpoint, activity(:llm, %{b | text: "Answer B prefix"})))
    await_snapshot(view, 12)

    assert history_content(view, id) == ["Question", "Answer A"]
    assert text(view, "#agent-history-entry-#{id}-1 .text-sm") =~ "Answer A"
    assert text(view, "#agent-history-entry-#{id}-1 .inspector-thinking") =~ "Reason A"
    assert text(view, "#inspector-live-message-1 div pre") == "Answer B prefix suffix"
    assert text(view, "#inspector-stream details pre") == "Reason B"
    refute has_element?(view, "#inspector-live-message-0")
    assert length(elements(view, "#inspector-stream article")) == 1
    refute render(view) =~ "DUPLICATE"

    # No intermediate render may combine checkpoint B with its old live copy.
    delta(view, id, 13, [{:activity, activity(:idle, nil)}, {:yield, "Answer B prefix suffix"}])
    retirement = watch_request(view, id)
    assert history_content(view, id) == ["Question", "Answer A"]
    assert text(view, "#inspector-live-message-1 div pre") == "Answer B prefix suffix"
    delta(view, id, 14, [{:yield, "Answer B prefix suffix"}])

    answer_b = %{
      message(:assistant, "Answer B prefix suffix")
      | reasoning_details: [%{text: b.thinking}]
    }

    {:ok, retired, 13} = snapshot(id, 13, checkpoint ++ [answer_b])
    reply(retirement, {:ok, %{retired | phase: :awaiting_input}, 13})
    await_snapshot(view, 14)

    assert history_content(view, id) == ["Question", "Answer A", "Answer B prefix suffix"]
    refute has_element?(view, "#inspector-stream article")
    refute has_element?(view, "#inspector-stream-cursor")
    assert length(elements(view, "#agent-history-entry-#{id}-2")) == 1
    assert text(view, "#agent-history-entry-#{id}-2 .inspector-thinking") =~ "Reason B"
    assert assigns(view).inspector_stream.state.phase == :awaiting_input
    assert watch_calls() == 3
    assert history_calls(view) == 0
  end

  test "atomic checkpoint failure preserves the coherent pair and explicit retry hands off once",
       %{
         conn: conn,
         id: id
       } do
    view = mount_inspector(conn)
    initial = [message(:system, "System checkpoint"), message(:user, "Original question")]
    select(view, id)
    reply(watch_request(view, id), snapshot(id, 1, initial))
    await_snapshot(view, 1)

    delta(view, id, 2, [
      {:activity, activity(:tools, call("Live response stays", "Live reasoning stays"))},
      {:tool_call, "call-1", "read"}
    ])

    # Tool/yield notifications alone do not fetch history or prove adoption.
    delta(view, id, 3, [{:tool_result, "call-1", :ok}])
    assert watch_calls() == 1
    assert history_calls(view) == 0

    delta(view, id, 4, [{:activity, activity(:idle, nil)}, {:text, "UNOWNED"}])
    first = watch_request(view, id)
    old = assigns(view).inspector_stream
    assert old.seq == 3
    assert history_content(view, id) == ["System checkpoint", "Original question"]
    assert text(view, "#inspector-live-message-0 div pre") == "Live response stays"

    # Explicit refreshes coalesce into the same worker snapshot. The ENTIRE
    # retirement batch and newer yields stay behind the atomic snapshot barrier.
    render_click(view, "retry_inspector_history")
    render_click(view, "retry_inspector_history")
    delta(view, id, 5, [{:yield, "Live response stays"}])
    delta(view, id, 5, [{:text, "DUPLICATE"}])
    assert watch_calls() == 2
    assert Enum.map(assigns(view).inspector_stream.pending, &elem(&1, 0)) == [4, 5]
    reply(first, {:exit, :checkpoint_unavailable})
    await(fn -> assigns(view).inspector_stream.error != nil end)

    assert assigns(view).inspector_stream.error == {:exit, :checkpoint_unavailable}
    assert assigns(view).inspector_stream.pending == []
    assert assigns(view).inspector_stream.buffer_bytes == 0
    assert has_element?(view, "button[phx-click='retry_inspector_stream']")
    assert text(view, "#inspector-stream details pre") == "Live reasoning stays"
    assert text(view, "#inspector-live-message-0 div pre") == "Live response stays"
    assert history_content(view, id) == ["System checkpoint", "Original question"]
    assert watch_calls() == 2
    assert history_calls(view) == 0

    # Failure retains watch-owned history; neither independent history results
    # nor an old in-flight reconciliation may replace the coherent pair.
    send(
      view.pid,
      {:agent_history_loaded, id, node(), assigns(view).inspector_history_seq, old.token, [], nil}
    )

    assert history_content(view, id) == ["System checkpoint", "Original question"]
    view |> element("button[phx-click='retry_inspector_stream']") |> render_click()
    retry = watch_request(view, id)
    assert assigns(view).inspector_stream.token > old.token

    answer = %{
      message(:assistant, "Live response stays")
      | reasoning_details: [%{text: "Live reasoning stays"}]
    }

    checkpoint = initial ++ [answer, message(:tool, "Authoritative tool output")]
    reply(retry, snapshot(id, 5, checkpoint))
    await_snapshot(view, 5)

    send(
      view.pid,
      {:inspector_stream_reconciled, node(), old.token, id, old.snapshot_request,
       snapshot(id, 99, initial)}
    )

    delta(view, id, 4, [{:text, "STALE"}])
    assert assigns(view).inspector_stream.seq == 5

    assert history_content(view, id) == [
             "System checkpoint",
             "Original question",
             "Live response stays",
             "Authoritative tool output"
           ]

    entries = Enum.find(assigns(view).agents, &(&1.id == id)).history
    assert Enum.map(entries, & &1.type) == ["system", "user", "assistant", "tool"]
    assert Enum.at(entries, 2).data.reasoning_details == [%{text: "Live reasoning stays"}]
    row = "#agent-history-entry-#{id}-2"
    assert text(view, "#{row} .inspector-thinking .whitespace-pre-wrap") == "Live reasoning stays"
    assert text(view, "#{row} .text-sm") =~ "Live response stays"
    assert has_element?(view, "#agent-detail-#{id}", "Authoritative tool output")
    assert length(elements(view, row)) == 1
    assert length(elements(view, "#{row} .inspector-thinking")) == 1
    assert length(elements(view, "#{row} .text-sm")) == 1
    refute has_element?(view, "#inspector-stream article")
    refute render(view) =~ "UNOWNED"
    refute render(view) =~ "DUPLICATE"
    refute render(view) =~ "STALE"
    assert assigns(view).inspector_stream.state.projections == []
    assert assigns(view).inspector_stream.state.response == ""
    assert assigns(view).inspector_stream.state.thinking == ""
    assert watch_calls() == 3
    assert history_calls(view) == 0
  end

  for order <- [
        [:finished, :status, :removed, :closed],
        [:removed, :finished, :closed],
        [:closed, :finished, :status, :removed]
      ] do
    @terminal_order order
    test "final handoff retains the selected ended transcript with ordering #{inspect(order)}", %{
      conn: conn,
      id: id
    } do
      view = mount_inspector(conn)
      select(view, id)

      reply(
        watch_request(view, id),
        snapshot(id, 10, [message(:user, "Question")], activity(:llm, call("Obsolete excerpt")))
      )

      await_snapshot(view, 10)
      assert Enum.any?(Registry.lookup(EvoGit.PubSub, "agent:#{id}"), &(elem(&1, 0) == view.pid))
      final = final_snapshot(id, 13)

      Enum.each(@terminal_order, fn event ->
        case event do
          :finished ->
            delta(view, id, 12, [{:finished, :completed}])

          :status ->
            send(view.pid, {:agent_updated, id, [status: :completed, message_count: 4], node()})
            send(view.pid, :flush_agent_events)
            assert Enum.find(assigns(view).agents, &(&1.id == id)).status == :completed

          :removed ->
            remove_agent(view, id)

          :closed ->
            admit_closure(view, id, final)
        end

        if Map.get(assigns(view).inspector_stream || %{}, :closed, false) do
          assert_final_transcript(view, id, final)
        end
      end)

      assert_final_transcript(view, id, final)
      assert assigns(view).selected_agent_id == id
      assert assigns(view).retained_agents[id].ended
      refute has_element?(view, "#agent-card-#{id}")
      assert has_element?(view, "#agent-detail-#{id}")
      refute render(view) =~ "Agent not found"
      assert_terminal_cleanup(view, id, 1)
    end
  end

  for stage <- [:attachment, :reconciliation], outcome <- [:success, :failure] do
    @late_stage stage
    @late_outcome outcome
    test "final closure wins over late #{@late_stage} #{@late_outcome}", %{conn: conn, id: id} do
      view = mount_inspector(conn)
      select(view, id)
      initial = watch_request(view, id)

      pending =
        if @late_stage == :attachment do
          initial
        else
          reply(initial, snapshot(id, 10, [], activity(:llm, call("Uncheckpointed prefix"))))
          await_snapshot(view, 10)
          delta(view, id, 11, [{:activity, activity(:idle, nil)}])
          request = watch_request(view, id)
          assert assigns(view).inspector_stream.reconciling
          request
        end

      old = assigns(view).inspector_stream
      final = final_snapshot(id, 12)
      admit_closure(view, id, final)
      assert_final_transcript(view, id, final)

      # Release a REAL blocked serial-worker RPC after the direct handoff. Its
      # unregister acknowledgement proves that result was sent before cleanup.
      result =
        if @late_outcome == :success,
          do: snapshot(id, 99, [message(:assistant, "LATE SNAPSHOT MUST NOT WIN")]),
          else: {:exit, :late_session_not_found}

      reply(pending, result)
      local = node()
      consumer = view.pid
      assert_receive {:unwatch, ^local, ^id, ^consumer}, @budget
      assert_final_transcript(view, id, final)
      refute has_element?(view, "button[phx-click='retry_inspector_stream']")

      # A ready result already queued in the consumer's mailbox is independently
      # stale, as is a reconciliation with the old token AND request identity.
      send(view.pid, {:inspector_stream_ready, local, old.token, id, result})

      send(
        view.pid,
        {:inspector_stream_reconciled, local, old.token, id, old.snapshot_request, result}
      )

      assert_final_transcript(view, id, final)
      remove_agent(view, id)
      assert_final_transcript(view, id, final)
      assert_terminal_cleanup(view, id, if(@late_stage == :attachment, do: 1, else: 2), false)
    end
  end

  test "foreign, stale and malformed closures cannot replace a selected final handoff", %{
    conn: conn,
    id: id
  } do
    view = mount_inspector(conn)
    select(view, id)
    reply(watch_request(view, id), snapshot(id, 10))
    await_snapshot(view, 10)
    select(view, id + 1)
    reply(watch_request(view, id + 1), snapshot(id + 1, 20, [message(:user, "Current question")]))
    await_snapshot(view, 20)
    before = assigns(view).inspector_stream

    for {agent, final, seq} <- [
          {id, final_snapshot(id, 100), 100},
          {id + 1, final_snapshot(id + 1, 19), 19},
          {id + 1, final_snapshot(id, 100), 100},
          {id + 1, final_snapshot(id + 1, 100), 101}
        ] do
      send(view.pid, {:agent_stream_closed, agent, final, seq})
      assert assigns(view).inspector_stream == before
      assert history_content(view, id + 1) == ["Current question"]
    end

    final = final_snapshot(id + 1, 21)
    admit_closure(view, id + 1, final)
    assert_final_transcript(view, id + 1, final)
    send(view.pid, {:agent_stream_closed, id + 1, final_snapshot(id + 1, 100), 100})
    assert_final_transcript(view, id + 1, final)
    assert_terminal_cleanup(view, id + 1, 2)
  end

  defp final_snapshot(id, seq) do
    answer = %{
      message(:assistant, "Authoritative final answer")
      | reasoning_details: [%{text: "Authoritative final reasoning"}]
    }

    %Snapshot{
      agent_id: id,
      seq: seq,
      phase: :done,
      messages: [message(:user, "Question"), answer, message(:tool, "Final tool output")],
      activity: activity(:idle, nil)
    }
  end

  defp admit_closure(view, id, final) do
    before = assigns(view).inspector_history_seq
    send(view.pid, {:agent_stream_closed, id, final, final.seq})
    assert assigns(view).inspector_stream.closed
    assert assigns(view).inspector_history_seq == before + 1
    Process.put({:snapshots, view.pid}, Process.get({:snapshots, view.pid}, 0) + 1)
  end

  defp assert_final_transcript(view, id, final) do
    stream = assigns(view).inspector_stream
    assert stream.closed
    assert stream.snapshot == final
    assert stream.seq == final.seq
    assert stream.state.messages == final.messages
    assert stream.state.activity == :idle
    assert stream.state.finished
    assert stream.error == nil
    refute stream.reconciling
    assert stream.pending == []
    assert stream.buffer_bytes == 0
    refute Enum.any?(Registry.lookup(EvoGit.PubSub, "agent:#{id}"), &(elem(&1, 0) == view.pid))

    assert history_content(view, id) == [
             "Question",
             "Authoritative final answer",
             "Final tool output"
           ]

    row = "#agent-history-entry-#{id}-1"
    assert length(elements(view, row)) == 1

    assert text(view, "#{row} .inspector-thinking .whitespace-pre-wrap") ==
             "Authoritative final reasoning"

    assert text(view, "#{row} .text-sm") =~ "Authoritative final answer"
    assert has_element?(view, "#agent-detail-#{id}", "Final tool output")
    assert text(view, "#inspector-activity") == "Idle"
    refute has_element?(view, "#inspector-stream article")
    refute has_element?(view, "#inspector-stream-cursor")
    refute has_element?(view, "#inspector-thinking")
    refute render(view) =~ "Obsolete excerpt"
    refute render(view) =~ "LATE SNAPSHOT MUST NOT WIN"
    assert history_calls(view) == 0
  end

  defp remove_agent(view, id) do
    # A fallback list refresh must not accidentally resurrect this fixture.
    other = id + 1
    Application.put_env(:evo_dash, :agents_list_runner, fn _ -> [summary(other)] end)
    send(view.pid, {:agent_removed, id, node()})
    send(view.pid, :flush_agent_events)
    refute Enum.any?(assigns(view).agents, &(&1.id == id))
    assert assigns(view).retained_agents[id].ended
  end

  defp assert_terminal_cleanup(view, id, expected_watches, await_unwatch? \\ true) do
    local = node()
    consumer = view.pid

    if await_unwatch?, do: assert_receive({:unwatch, ^local, ^id, ^consumer}, @budget)

    final = assigns(view).inspector_stream.snapshot
    # Exercise every refresh affordance after closure. None may register again
    # or launch an independent history read, even for a removed selected row.
    render_click(view, "retry_inspector_history")
    render_click(view, "retry_inspector_stream")

    send(
      view.pid,
      {:agent_delta, id, final.seq + 1, [{:activity, activity(:llm, call("LATE DELTA"))}]}
    )

    assert_final_transcript(view, id, final)
    assert watch_calls() == expected_watches

    worker = assigns(view).inspector_stream_worker
    monitor = Process.monitor(worker)
    stop_view(view)
    assert_receive {:DOWN, ^monitor, :process, ^worker, _}, @budget
    # Worker termination is the fence for these negative mailbox probes; no
    # arbitrary quiet window can hide a queued rewatch or poll after closure.
    assert watch_calls() == expected_watches
    assert :atomics.get(Process.get(:inspector_runner_calls), 2) == 0
    refute_receive {:runner, _, _, {:watch, _, ^id, ^consumer}}, 0
    refute_receive {:unexpected_history, _, ^id}, 0
  end

  # Runner calls are reference-scoped handshakes, not delays. Owner monitoring
  # frees a blocked runner even if its test fails before supplying a response.
  defp request(owner, payload) do
    ref = make_ref()
    monitor = Process.monitor(owner)
    send(owner, {:runner, ref, self(), payload})

    receive do
      {^ref, result} ->
        Process.demonitor(monitor, [:flush])
        result

      {:DOWN, ^monitor, :process, ^owner, _} ->
        {:error, :test_owner_down}
    after
      @budget -> raise "Inspector fixture runner was never released: #{inspect(payload)}"
    end
  end

  defp reply({ref, pid}, result), do: send(pid, {ref, result})

  defp watch_request(view, id) do
    target = assigns(view).current_node
    consumer = view.pid
    assert_receive {:runner, ref, pid, {:watch, ^target, ^id, ^consumer}}, @budget
    refute pid == consumer

    # Capture the actual serial worker now: the LiveViewTest proxy may die
    # before on_exit runs, so looking it up only during teardown can miss it.
    worker = assigns(view).inspector_stream_worker

    on_exit({:inspector_worker, worker}, fn ->
      monitor = Process.monitor(worker)
      stop_view(view)
      assert_receive {:DOWN, ^monitor, :process, ^worker, _}, @budget
    end)

    {ref, pid}
  end

  defp mount_inspector(conn) do
    {:ok, view, _} = live(conn, "/agents")
    await_loaded(view)

    on_exit(fn -> stop_view(view) end)

    view
  end

  defp stop_view(view) do
    # Teardown only: the test proxy can stop the consumer between the liveness
    # check and GenServer.stop; that race must not mask an assertion failure.
    if Process.alive?(view.pid), do: GenServer.stop(view.pid, :normal, @budget)
  catch
    :exit, {:noproc, _} -> :ok
  end

  defp select(view, id), do: view |> element("#agent-card-#{id}") |> render_click()

  defp snapshot(id, seq, messages \\ [], activity \\ activity(:idle, nil)) do
    {:ok,
     %Snapshot{agent_id: id, seq: seq, phase: :running, messages: messages, activity: activity},
     seq}
  end

  defp activity(phase, call), do: %{phase: phase, current_call: call}

  defp call(text \\ "", thinking \\ "", turn \\ 1, attempt \\ 1) do
    %{id: "call-#{turn}-#{attempt}", turn: turn, attempt: attempt, text: text, thinking: thinking}
  end

  defp message(role, text) do
    %ReqLLM.Message{role: role, content: [%{type: :text, text: text}], metadata: %{turn: 1}}
  end

  defp summary(id) do
    %{
      id: id,
      status: :running,
      parent_id: nil,
      depth: 0,
      message_count: 2,
      objective: "Inspect streamed agent #{id}",
      context_path: "./",
      agent_module: EvoGit.Agents.Manager,
      task_id: "stream-#{id}"
    }
  end

  defp delta(view, id, seq, events) do
    Phoenix.PubSub.broadcast(EvoGit.PubSub, "agent:#{id}", {:agent_delta, id, seq, events})
    # PubSub sends from this test process, so the state read is a FIFO fence.
    assigns(view)
    render(view)
  end

  defp update_count(view, id, count) do
    send(view.pid, {:agent_updated, id, [message_count: count], node()})
    send(view.pid, :flush_agent_events)
    await(fn -> Enum.find(assigns(view).agents, &(&1.id == id)).message_count == count end)
  end

  defp history_calls(view) do
    # The synchronous dispatch counter catches even a loader that has not yet
    # reached the runner; the runner counter independently catches actual reads.
    assert assigns(view).inspector_history_seq == Process.get({:snapshots, view.pid}, 0)
    :atomics.get(Process.get(:inspector_runner_calls), 2)
  end

  defp watch_calls, do: :atomics.get(Process.get(:inspector_runner_calls), 1)

  defp history_content(view, id) do
    state = assigns(view)
    agent = Enum.find(state.agents, &(&1.id == id)) || state.retained_agents[id]
    Enum.map(agent.history, & &1.data.content)
  end

  defp await_snapshot(view, seq) do
    await(fn ->
      stream = assigns(view).inspector_stream

      stream.snapshot != nil and stream.seq == seq and
        assigns(view).history_loading_agent_id == nil
    end)

    Process.put({:snapshots, view.pid}, Process.get({:snapshots, view.pid}, 0) + 1)
    render(view)
  end

  defp await_loaded(view) do
    await(fn -> not assigns(view).agents_loading end)
    render(view)
  end

  defp text(view, selector) do
    view
    |> render()
    |> Floki.parse_document!()
    |> Floki.find(selector)
    |> Floki.text()
    |> String.trim()
  end

  defp elements(view, selector),
    do: view |> render() |> Floki.parse_document!() |> Floki.find(selector)

  defp assigns(view), do: :sys.get_state(view.pid, @budget).socket.assigns

  defp await(predicate), do: await(predicate, System.monotonic_time(:millisecond) + @budget)

  defp await(predicate, deadline) do
    if predicate.() do
      :ok
    else
      assert System.monotonic_time(:millisecond) < deadline, "Inspector state did not settle"
      Process.sleep(2)
      await(predicate, deadline)
    end
  end
end
