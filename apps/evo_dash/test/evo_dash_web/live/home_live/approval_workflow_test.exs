defmodule EvoDashWeb.HomeLive.ApprovalWorkflowTest.Helpers do
  alias EvoDashWeb.HomeLive.ApprovalWorkflow

  def socket(overrides \\ %{}) do
    assigns =
      Map.merge(
        %{
          __changed__: %{},
          chat_id: "chat-1",
          current_node_id: nil,
          current_node: node(),
          chat_node: :source@host,
          chat_task_id: "task-1",
          chat_agent_id: 17
        },
        overrides
      )

    ApprovalWorkflow.init(%Phoenix.LiveView.Socket{assigns: assigns})
  end

  def request(overrides \\ %{}) do
    Map.merge(
      %{
        request_id: "request-1",
        node: :source@host,
        task_id: "task-1",
        agent_id: nil,
        kind: :elixir_eval,
        target_node: :evaluator@host,
        code: "original()"
      },
      overrides
    )
  end

  def scope(socket) do
    a = socket.assigns

    {a.chat_id, a.current_node_id, a.current_node, a.chat_node || a.current_node, a.chat_task_id,
     a.chat_agent_id}
  end

  def recovery(socket, seq \\ 101) do
    socket =
      Phoenix.Component.assign(socket,
        approval_recovery_seq: seq,
        approval_recovering: true
      )

    {socket, {:approval_pending_loaded, seq, scope(socket)}}
  end

  def response(socket, id \\ "request-1", seq \\ 102) do
    socket = Phoenix.Component.assign(socket, approval_responses: %{id => seq})
    {socket, {:approval_workflow_response, seq, scope(socket), id}}
  end

  def scope_changes do
    [
      {:chat_id, "other-chat"},
      {:current_node_id, "other-connection"},
      {:current_node, :other_view@host},
      {:chat_node, :other_source@host},
      {:chat_task_id, "other-task"},
      {:chat_agent_id, 18}
    ]
  end
end

defmodule EvoDashWeb.HomeLive.ApprovalWorkflowTest do
  use ExUnit.Case, async: true

  alias EvoDashWeb.HomeLive.{ApprovalWorkflow, ChatState}
  import EvoDashWeb.HomeLive.ApprovalWorkflowTest.Helpers
  import Phoenix.Component, only: [assign: 2]

  describe "request ownership" do
    test "uses the source chat node and task OR normalized agent id, not evaluator target" do
      socket = socket()

      for owned <- [
            request(),
            request(%{task_id: "unrelated", agent_id: "17"}),
            request(%{task_id: nil, agent_id: 17}),
            request(%{agent_id: "unrelated", target_node: :elsewhere@host})
          ] do
        assert ApprovalWorkflow.own_request?(socket.assigns, owned)
        assert ApprovalWorkflow.requested(socket, owned).assigns.pending_approvals == [owned]
      end

      for foreign <- [
            request(%{node: :evaluator@host, target_node: :source@host}),
            request(%{task_id: "unrelated", agent_id: 18}),
            request(%{task_id: nil, agent_id: nil})
          ] do
        refute ApprovalWorkflow.own_request?(socket.assigns, foreign)
        assert ApprovalWorkflow.requested(socket, foreign) == socket
      end
    end

    test "falls back to the viewed node only when chat_node is missing" do
      socket = socket(%{chat_node: nil, current_node: :viewed@host})
      assert ApprovalWorkflow.own_request?(socket.assigns, request(%{node: :viewed@host}))
      refute ApprovalWorkflow.own_request?(socket.assigns, request())
    end

    test "legacy producers may omit source node but evaluator producers may not" do
      socket = socket()
      legacy = request() |> Map.delete(:node) |> Map.delete(:kind)
      assert ApprovalWorkflow.own_request?(socket.assigns, legacy)
      assert ApprovalWorkflow.own_request?(socket.assigns, Map.put(legacy, :node, nil))
      refute ApprovalWorkflow.own_request?(socket.assigns, request(%{node: nil}))

      refute ApprovalWorkflow.own_request?(
               socket.assigns,
               Map.put(legacy, :node, :foreign@host)
             )
    end

    test "ownership is total over malformed payloads and requires a nonblank binary id" do
      for invalid <- [nil, [], "request", 17, %{}, %{"request_id" => "request-1"}] do
        refute ApprovalWorkflow.own_request?(socket().assigns, invalid)
        assert ApprovalWorkflow.requested(socket(), invalid) == socket()
      end

      for id <- [nil, 17, "", " \n "] do
        refute ApprovalWorkflow.own_request?(socket().assigns, request(%{request_id: id}))
      end

      assert ApprovalWorkflow.own_request?(socket().assigns, request(%{request_id: " id "}))
    end

    test "usable task or agent references and a resolved source node are required" do
      for overrides <- [
            %{chat_task_id: nil, chat_agent_id: nil},
            %{chat_task_id: " ", chat_agent_id: []},
            %{chat_node: "not-an-atom"},
            %{chat_node: nil, current_node: nil},
            %{current_node_id: "disconnected-remote", current_node: node()}
          ] do
        socket = socket(overrides)
        refute ApprovalWorkflow.own_request?(socket.assigns, request())
        assert ApprovalWorkflow.recover(socket) == socket
      end

      agent_only = socket(%{chat_task_id: nil, chat_agent_id: "17"})
      assert ApprovalWorkflow.own_request?(agent_only.assigns, request(%{agent_id: 17}))

      task_number = socket(%{chat_task_id: 23, chat_agent_id: nil})
      assert ApprovalWorkflow.own_request?(task_number.assigns, request(%{task_id: "23"}))
    end
  end

  describe "source-stamped resolutions" do
    test "only the chat source can settle a busy card, not the viewed or evaluator node" do
      expected = request()
      other = request(%{request_id: "other"})

      {socket, response_tag} =
        socket(%{current_node: :viewed@host})
        |> ApprovalWorkflow.requested(other)
        |> ApprovalWorkflow.requested(expected)
        |> response()

      for foreign <- [:viewed@host, expected.target_node, :foreign@host, nil] do
        assert ApprovalWorkflow.resolved(socket, expected.request_id, foreign) == socket
      end

      resolved = ApprovalWorkflow.resolved(socket, expected.request_id, expected.node)
      assert resolved.assigns.pending_approvals == [other]
      refute ApprovalWorkflow.busy?(resolved.assigns, expected.request_id)
      assert ApprovalWorkflow.responded(resolved, response_tag, {:error, :timeout}) == resolved
    end

    test "viewed-node fallback requires a usable chat scope and rejects pending remote contexts" do
      expected = request()

      socket =
        socket(%{chat_node: nil, current_node: expected.node})
        |> ApprovalWorkflow.requested(expected)

      assert ApprovalWorkflow.resolved(socket, expected.request_id, expected.node).assigns.pending_approvals ==
               []

      for overrides <- [
            %{chat_task_id: nil, chat_agent_id: nil},
            %{chat_task_id: " ", chat_agent_id: []},
            %{chat_node: "not-an-atom"},
            %{chat_node: nil, current_node: nil},
            %{current_node_id: "pending", current_node: node()}
          ] do
        changed = assign(socket, Map.to_list(overrides))
        source = changed.assigns.chat_node || changed.assigns.current_node
        assert ApprovalWorkflow.resolved(changed, expected.request_id, source) == changed
      end
    end
  end

  describe "snapshot and broadcast reconciliation" do
    test "snapshot replaces old cards, filters ownership, and deduplicated live arrival wins" do
      old = request(%{request_id: "stale"})
      existing = request(%{request_id: "existing"})
      socket = socket() |> ApprovalWorkflow.requested(old) |> ApprovalWorkflow.requested(existing)
      {socket, tag} = recovery(socket)
      live = request(%{code: "newer()"})
      newest = request(%{code: "newest()"})
      late = request(%{request_id: "late"})

      socket =
        socket
        |> ApprovalWorkflow.requested(live)
        |> ApprovalWorkflow.requested(newest)
        |> ApprovalWorkflow.requested(late)

      socket =
        ApprovalWorkflow.recovered(socket, tag, {
          :ok,
          [request(), existing, request(%{request_id: "foreign", node: :foreign@host}), nil]
        })

      assert socket.assigns.pending_approvals == [late, newest, existing]
      refute socket.assigns.approval_recovering
      assert socket.assigns.approval_recovery_seq == nil
      assert socket.assigns.approval_recovery_new == []
      assert socket.assigns.approval_error == nil
    end

    test "empty snapshot removes stale cards but retains arrivals during recovery" do
      {socket, tag} = socket() |> ApprovalWorkflow.requested(request()) |> recovery()
      assert ApprovalWorkflow.recovered(socket, tag, {:ok, []}).assigns.pending_approvals == []

      late = request(%{request_id: "late"})
      socket = ApprovalWorkflow.requested(socket, late)

      assert ApprovalWorkflow.recovered(socket, tag, {:ok, []}).assigns.pending_approvals == [
               late
             ]
    end

    test "resolution tombstones block stale snapshot resurrection and clear busy/live entries" do
      {socket, tag} = recovery(socket())
      socket = ApprovalWorkflow.requested(socket, request())
      {socket, response_tag} = response(socket)
      socket = ApprovalWorkflow.resolved(socket, "request-1")

      assert socket.assigns.pending_approvals == []
      assert socket.assigns.approval_recovery_new == []
      refute ApprovalWorkflow.busy?(socket.assigns, "request-1")
      assert MapSet.member?(socket.assigns.approval_recovery_removed, "request-1")
      assert ApprovalWorkflow.responded(socket, response_tag, {:ok, :ok}) == socket

      # Legacy unstamped resolutions still take only an id.
      socket = ApprovalWorkflow.resolved(socket, "not-yet-seen")
      fetched = [request(), request(%{request_id: "not-yet-seen"})]

      assert ApprovalWorkflow.recovered(socket, tag, {:ok, fetched}).assigns.pending_approvals ==
               []
    end

    test "only source resolutions tombstone seen and unseen cards during recovery" do
      expected = request()
      unseen = request(%{request_id: "unseen"})
      foreign_resolution = request(%{request_id: "foreign-resolution"})
      {socket, tag} = recovery(socket())
      socket = ApprovalWorkflow.requested(socket, expected)
      {socket, response_tag} = response(socket)

      socket =
        socket
        |> ApprovalWorkflow.resolved(expected.request_id, expected.node)
        |> ApprovalWorkflow.resolved(unseen.request_id, unseen.node)

      assert socket.assigns.pending_approvals == []
      assert socket.assigns.approval_recovery_new == []
      assert socket.assigns.approval_responses == %{}
      assert socket.assigns.approval_recovery_removed == MapSet.new(["request-1", "unseen"])

      assert ApprovalWorkflow.resolved(socket, foreign_resolution.request_id, :evaluator@host) ==
               socket

      assert ApprovalWorkflow.responded(socket, response_tag, {:error, :timeout}) == socket

      socket =
        ApprovalWorkflow.recovered(socket, tag, {:ok, [expected, unseen, foreign_resolution]})

      assert socket.assigns.pending_approvals == [foreign_resolution]
      refute socket.assigns.approval_recovering
      assert socket.assigns.approval_error == nil
    end

    test "authoritative snapshots preserve busy cards until acknowledgement or source resolution" do
      expected = request()
      stale = request(%{request_id: "stale"})
      fetched = request(%{request_id: "fetched"})

      # An omitted row and an older version of the same row are both possible
      # while the backend has consumed the decision but its reply is in flight.
      for snapshot <- [[], [request(%{code: "older()"}), fetched]] do
        {socket, response_tag} =
          socket()
          |> ApprovalWorkflow.requested(stale)
          |> ApprovalWorkflow.requested(expected)
          |> response()

        {socket, recovery_tag} = recovery(socket)
        socket = ApprovalWorkflow.recovered(socket, recovery_tag, {:ok, snapshot})
        others = Enum.reject(snapshot, &(&1.request_id == expected.request_id))

        assert socket.assigns.pending_approvals == [expected | others]
        assert ApprovalWorkflow.busy?(socket.assigns, expected.request_id)
        assert socket.assigns.approval_responses == %{"request-1" => elem(response_tag, 1)}
        refute socket.assigns.approval_recovering
        assert ApprovalWorkflow.respond(socket, expected.request_id, "deny") == socket

        for acknowledgement <- [{:ok, :ok}, {:ok, {:error, :not_found}}] do
          settled = ApprovalWorkflow.responded(socket, response_tag, acknowledgement)
          assert settled.assigns.pending_approvals == others
          refute ApprovalWorkflow.busy?(settled.assigns, expected.request_id)
        end

        settled = ApprovalWorkflow.resolved(socket, expected.request_id, expected.node)
        assert settled.assigns.pending_approvals == others
        refute ApprovalWorkflow.busy?(settled.assigns, expected.request_id)
        assert ApprovalWorkflow.responded(settled, response_tag, {:error, :timeout}) == settled

        failed = ApprovalWorkflow.responded(socket, response_tag, {:error, :timeout})
        assert failed.assigns.pending_approvals == [expected | others]
        assert failed.assigns.approval_error == {:response, "request-1", :timeout}
        refute ApprovalWorkflow.busy?(failed.assigns, expected.request_id)
      end
    end

    test "recovery errors and malformed replies finish loading without losing cards" do
      for {result, reason} <- [
            {{:error, :offline}, :offline},
            {{:ok, {:error, :unavailable}}, :unavailable},
            {{:ok, :invalid}, {:unexpected_result, {:ok, :invalid}}}
          ] do
        {socket, tag} = socket() |> ApprovalWorkflow.requested(request()) |> recovery()
        socket = ApprovalWorkflow.recovered(socket, tag, result)
        assert socket.assigns.pending_approvals == [request()]
        assert socket.assigns.approval_error == {:recovery, reason}
        assert socket.assigns.approval_recovery_seq == nil
        refute socket.assigns.approval_recovering
      end
    end

    test "older tokens are inert, including after reset" do
      {socket, old_tag} = recovery(socket(), 100)
      {socket, new_tag} = recovery(socket, 101)
      assert ApprovalWorkflow.recovered(socket, old_tag, {:ok, [request()]}) == socket
      reset = ApprovalWorkflow.init(socket)
      assert ApprovalWorkflow.recovered(reset, new_tag, {:ok, [request()]}) == reset
    end

    test "every captured scope field guards recovery even when the token still matches" do
      for {field, value} <- scope_changes() do
        {socket, tag} = socket() |> ApprovalWorkflow.requested(request()) |> recovery()
        changed = assign(socket, [{field, value}])
        result = ApprovalWorkflow.recovered(changed, tag, {:ok, []})
        assert result.assigns.pending_approvals == [request()], inspect(field)
        assert result.assigns.approval_recovery_seq == nil, inspect(field)
        refute result.assigns.approval_recovering, inspect(field)
      end
    end
  end

  describe "response application" do
    test "success and already-resolved not_found remove only the matching card" do
      other = request(%{request_id: "other"})

      for result <- [{:ok, :ok}, {:ok, {:error, :not_found}}] do
        {socket, tag} =
          socket()
          |> ApprovalWorkflow.requested(request())
          |> ApprovalWorkflow.requested(other)
          |> response()

        socket = ApprovalWorkflow.responded(socket, tag, result)
        assert socket.assigns.pending_approvals == [other]
        refute ApprovalWorkflow.busy?(socket.assigns, "request-1")
        assert socket.assigns.approval_error == nil
      end
    end

    test "backend and transport failures retain the card and clear busy state" do
      for {result, reason} <- [
            {{:ok, {:error, :denied}}, :denied},
            {{:error, {:exit, :timeout}}, {:exit, :timeout}},
            {{:ok, :unexpected}, {:unexpected_result, {:ok, :unexpected}}}
          ] do
        {socket, tag} = socket() |> ApprovalWorkflow.requested(request()) |> response()
        assert ApprovalWorkflow.busy?(socket.assigns, "request-1")
        socket = ApprovalWorkflow.responded(socket, tag, result)
        assert socket.assigns.pending_approvals == [request()]
        assert socket.assigns.approval_error == {:response, "request-1", reason}
        refute ApprovalWorkflow.busy?(socket.assigns, "request-1")
      end
    end

    test "stale response tokens, wrong ids and reset results are inert" do
      {socket, old_tag} = socket() |> ApprovalWorkflow.requested(request()) |> response()
      {socket, new_tag} = response(socket, "request-1", 103)
      assert ApprovalWorkflow.responded(socket, old_tag, {:ok, :ok}) == socket
      {kind, seq, scope, _id} = new_tag
      assert ApprovalWorkflow.responded(socket, {kind, seq, scope, "other"}, {:ok, :ok}) == socket
      reset = ApprovalWorkflow.init(socket)
      assert ApprovalWorkflow.responded(reset, new_tag, {:ok, :ok}) == reset
    end

    test "every captured scope field guards responses and clears only that busy token" do
      for {field, value} <- scope_changes() do
        {socket, tag} = socket() |> ApprovalWorkflow.requested(request()) |> response()

        socket =
          assign(socket,
            approval_responses: Map.put(socket.assigns.approval_responses, "other", 999)
          )

        changed = assign(socket, [{field, value}])
        result = ApprovalWorkflow.responded(changed, tag, {:ok, :ok})
        assert result.assigns.pending_approvals == [request()], inspect(field)
        assert result.assigns.approval_responses == %{"other" => 999}, inspect(field)
        assert result.assigns.approval_error == nil
      end
    end

    test "absent, invalid, unowned, disconnected and duplicate submissions are no-ops" do
      socket = ApprovalWorkflow.requested(socket(), request())

      for {id, decision} <- [
            {"absent", "approve"},
            {nil, "deny"},
            {"request-1", "invalid"},
            {"request-1", :approve},
            {"request-1", nil}
          ] do
        assert ApprovalWorkflow.respond(socket, id, decision) == socket
      end

      for changed <- [
            assign(socket, chat_task_id: "foreign", chat_agent_id: nil),
            assign(socket, chat_node: :foreign@host),
            assign(socket, current_node_id: "pending", current_node: node())
          ] do
        assert ApprovalWorkflow.respond(changed, "request-1", "approve") == changed
      end

      {busy, _tag} = response(socket)
      assert ApprovalWorkflow.respond(busy, "request-1", "deny") == busy
    end
  end

  test "init clears runtime workflow state and ChatState never persists it" do
    {socket, _tag} = socket() |> ApprovalWorkflow.requested(request()) |> recovery()
    {socket, _tag} = response(socket)
    socket = assign(socket, approval_error: {:response, "request-1", :offline})
    reset = ApprovalWorkflow.init(socket)
    assert reset.assigns.pending_approvals == []
    assert reset.assigns.approval_recovery_seq == nil
    refute reset.assigns.approval_recovering
    assert reset.assigns.approval_recovery_removed == MapSet.new()
    assert reset.assigns.approval_recovery_new == []
    assert reset.assigns.approval_responses == %{}
    assert reset.assigns.approval_error == nil
    assert reset.assigns.chat_id == socket.assigns.chat_id

    runtime_keys = [
      :pending_approvals,
      :approval_recovery_seq,
      :approval_recovering,
      :approval_recovery_removed,
      :approval_recovery_new,
      :approval_responses,
      :approval_error
    ]

    assert Map.take(ChatState.build(socket.assigns), runtime_keys) == %{}
  end
end

defmodule EvoDashWeb.HomeLive.ApprovalWorkflowRunnersTest do
  # Sole async owner of :approval_pending_runner and :approval_responder.
  # The other responder writer is HomeLiveTest (async: false), which ExUnit
  # starts only after this cohort finishes; never split seam writers across
  # async modules. The pure sibling module above reads neither global key.
  use ExUnit.Case, async: true

  alias EvoDashWeb.HomeLive.ApprovalWorkflow
  import EvoDashWeb.HomeLive.ApprovalWorkflowTest.Helpers

  setup do
    for key <- [:approval_pending_runner, :approval_responder] do
      previous = Application.fetch_env(:evo_dash, key)

      on_exit(fn ->
        case previous do
          {:ok, value} -> Application.put_env(:evo_dash, key, value)
          :error -> Application.delete_env(:evo_dash, key)
        end
      end)
    end

    :ok
  end

  test "pending runner runs off-process on source node with the nested SafeCall envelope" do
    owner = self()
    expected = request()

    Application.put_env(:evo_dash, :approval_pending_runner, fn source ->
      send(owner, {:pending_started, self(), source})

      receive do
        :release -> [expected]
      after
        5_000 -> flunk("pending runner was not released")
      end
    end)

    socket = ApprovalWorkflow.recover(socket())
    seq = socket.assigns.approval_recovery_seq
    scope = scope(socket)
    assert socket.assigns.approval_recovering
    assert_receive {:pending_started, worker, :source@host}, 2_000
    refute worker == self()
    monitor = Process.monitor(worker)

    # Swapping the seam cannot replace the runner already captured by this load.
    Application.put_env(:evo_dash, :approval_pending_runner, fn _ -> raise "wrong runner" end)
    send(worker, :release)

    assert_receive {{:approval_pending_loaded, ^seq, ^scope} = tag, {:ok, [^expected]} = result},
                   2_000

    assert_receive {:DOWN, ^monitor, :process, ^worker, :normal}, 2_000
    socket = ApprovalWorkflow.recovered(socket, tag, result)
    assert socket.assigns.pending_approvals == [expected]
    refute socket.assigns.approval_recovering
  end

  test "new recovery and reset allocate strictly increasing tokens; late loads cannot apply" do
    Application.put_env(:evo_dash, :approval_pending_runner, fn _ -> [] end)
    first = ApprovalWorkflow.recover(socket())
    first_seq = first.assigns.approval_recovery_seq
    assert_receive {{:approval_pending_loaded, ^first_seq, _} = first_tag, {:ok, []}}, 2_000
    second = ApprovalWorkflow.recover(first)
    second_seq = second.assigns.approval_recovery_seq
    assert second_seq > first_seq
    assert_receive {{:approval_pending_loaded, ^second_seq, _} = second_tag, {:ok, []}}, 2_000
    assert ApprovalWorkflow.recovered(second, first_tag, {:ok, [request()]}) == second

    third = second |> ApprovalWorkflow.init() |> ApprovalWorkflow.recover()
    third_seq = third.assigns.approval_recovery_seq
    assert third_seq > second_seq
    assert_receive {{:approval_pending_loaded, ^third_seq, _} = third_tag, {:ok, []}}, 2_000
    assert ApprovalWorkflow.recovered(third, second_tag, {:ok, [request()]}) == third
    assert ApprovalWorkflow.recovered(third, third_tag, {:ok, []}).assigns.pending_approvals == []
  end

  test "missing chat node routes both runners to the viewed source, and not_found removes the card" do
    owner = self()
    expected = request()

    Application.put_env(:evo_dash, :approval_pending_runner, fn source ->
      send(owner, {:pending_source, source})
      [expected]
    end)

    Application.put_env(:evo_dash, :approval_responder, fn source, id, decision ->
      send(owner, {:response_source, source, id, decision})
      {:error, :not_found}
    end)

    socket = socket(%{chat_node: nil, current_node: :source@host}) |> ApprovalWorkflow.recover()
    seq = socket.assigns.approval_recovery_seq
    assert_receive {:pending_source, :source@host}, 2_000
    assert_receive {{:approval_pending_loaded, ^seq, _} = tag, {:ok, [^expected]} = result}, 2_000
    socket = ApprovalWorkflow.recovered(socket, tag, result)
    socket = ApprovalWorkflow.respond(socket, "request-1", "approve")
    seq = socket.assigns.approval_responses["request-1"]
    assert_receive {:response_source, :source@host, "request-1", "approve"}, 2_000

    assert_receive {{:approval_workflow_response, ^seq, _, "request-1"} = tag,
                    {:ok, {:error, :not_found}} = result},
                   2_000

    socket = ApprovalWorkflow.responded(socket, tag, result)
    assert socket.assigns.pending_approvals == []
    assert socket.assigns.approval_responses == %{}
    assert socket.assigns.approval_error == nil
  end

  test "pending runner exit is reported, loading ends, and retry can recover" do
    Application.put_env(:evo_dash, :approval_pending_runner, fn _ -> exit(:offline) end)
    socket = socket() |> ApprovalWorkflow.requested(request()) |> ApprovalWorkflow.recover()
    seq = socket.assigns.approval_recovery_seq

    assert_receive {{:approval_pending_loaded, ^seq, _} = tag,
                    {:error, {:exit, :offline}} = result},
                   2_000

    socket = ApprovalWorkflow.recovered(socket, tag, result)
    refute socket.assigns.approval_recovering
    assert socket.assigns.pending_approvals == [request()]
    assert socket.assigns.approval_error == {:recovery, {:exit, :offline}}

    Application.put_env(:evo_dash, :approval_pending_runner, fn _ -> [] end)
    socket = ApprovalWorkflow.recover(socket)
    assert socket.assigns.approval_error == nil
    next_seq = socket.assigns.approval_recovery_seq
    assert_receive {{:approval_pending_loaded, ^next_seq, _} = tag, {:ok, []} = result}, 2_000
    assert ApprovalWorkflow.recovered(socket, tag, result).assigns.pending_approvals == []
  end

  test "responder failure keeps card, retry gets a new token, and stale responses cannot settle it" do
    owner = self()

    Application.put_env(:evo_dash, :approval_responder, fn source, id, decision ->
      send(owner, {:response_called, self(), source, id, decision})
      {:error, :offline}
    end)

    socket =
      socket()
      |> ApprovalWorkflow.requested(request())
      |> ApprovalWorkflow.respond("request-1", "approve")

    first_seq = socket.assigns.approval_responses["request-1"]
    assert socket.assigns.pending_approvals == [request()]
    assert ApprovalWorkflow.busy?(socket.assigns, "request-1")
    assert_receive {:response_called, worker, :source@host, "request-1", "approve"}, 2_000
    refute worker == self()

    assert_receive {{:approval_workflow_response, ^first_seq, _, "request-1"} = old_tag,
                    {:ok, {:error, :offline}} = result},
                   2_000

    # The authoritative pending API can omit a consumed request before the
    # responder's failure is applied; that must not destroy its retry card.
    Application.put_env(:evo_dash, :approval_pending_runner, fn _ -> [] end)
    socket = ApprovalWorkflow.recover(socket)
    recovery_seq = socket.assigns.approval_recovery_seq

    assert_receive {{:approval_pending_loaded, ^recovery_seq, _} = recovery_tag,
                    {:ok, []} = recovery_result},
                   2_000

    socket = ApprovalWorkflow.recovered(socket, recovery_tag, recovery_result)
    assert socket.assigns.pending_approvals == [request()]
    assert ApprovalWorkflow.busy?(socket.assigns, "request-1")

    socket = ApprovalWorkflow.responded(socket, old_tag, result)
    assert socket.assigns.approval_error == {:response, "request-1", :offline}
    assert socket.assigns.pending_approvals == [request()]
    refute ApprovalWorkflow.busy?(socket.assigns, "request-1")

    Application.put_env(:evo_dash, :approval_responder, fn source, id, decision ->
      send(owner, {:retry_started, self(), source, id, decision})

      receive do
        :release -> :ok
      after
        5_000 -> flunk("response runner was not released")
      end
    end)

    socket = ApprovalWorkflow.respond(socket, "request-1", "deny")
    next_seq = socket.assigns.approval_responses["request-1"]
    assert next_seq > first_seq
    assert socket.assigns.approval_error == nil
    assert_receive {:retry_started, worker, :source@host, "request-1", "deny"}, 2_000
    monitor = Process.monitor(worker)
    Application.put_env(:evo_dash, :approval_responder, fn _, _, _ -> raise "wrong runner" end)
    assert ApprovalWorkflow.respond(socket, "request-1", "approve") == socket
    assert ApprovalWorkflow.responded(socket, old_tag, {:ok, :ok}) == socket
    send(worker, :release)

    assert_receive {{:approval_workflow_response, ^next_seq, _, "request-1"} = tag,
                    {:ok, :ok} = result},
                   2_000

    assert_receive {:DOWN, ^monitor, :process, ^worker, :normal}, 2_000
    socket = ApprovalWorkflow.responded(socket, tag, result)
    assert socket.assigns.pending_approvals == []
    refute ApprovalWorkflow.busy?(socket.assigns, "request-1")
  end
end
