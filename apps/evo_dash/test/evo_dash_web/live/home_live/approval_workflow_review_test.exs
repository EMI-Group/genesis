defmodule EvoDashWeb.HomeLive.ApprovalWorkflowReviewTest do
  use ExUnit.Case, async: true

  alias EvoDashWeb.HomeLive.ApprovalWorkflow
  import Phoenix.Component, only: [assign: 2]

  describe "live notification admission" do
    test "only the first owned arrival notifies, while duplicates update the pending payload" do
      request = request("first")
      {socket, payload} = ApprovalWorkflow.requested_with_notification(socket(), request)
      assert payload == ApprovalWorkflow.notification_payload(socket.assigns, "first")
      assert payload.request_id == "first"

      updated = %{request | code: "updated()"}
      {socket, nil} = ApprovalWorkflow.requested_with_notification(socket, updated)
      assert socket.assigns.pending_approvals == [updated]

      for rejected <- [
            nil,
            %{},
            request("foreign", %{node: :foreign@host}),
            request("unowned", %{task_id: "other", agent_id: 18}),
            request(" ")
          ] do
        assert ApprovalWorkflow.requested_with_notification(socket, rejected) == {socket, nil}
      end

      {socket, second} =
        ApprovalWorkflow.requested_with_notification(socket, request("second"))

      assert second.request_id == "second"
      refute second.tag == payload.tag
      socket = ApprovalWorkflow.resolved(socket, "first", :source@host)
      assert ApprovalWorkflow.requested_with_notification(socket, request) == {socket, nil}
      assert ApprovalWorkflow.notification_payload(socket.assigns, "first") == nil
    end

    test "recovered and already resolved ids never become novel live notifications" do
      socket = socket()
      {socket, tag} = recovery(socket)
      socket = ApprovalWorkflow.recovered(socket, tag, {:ok, [request("recovered")]})

      assert ApprovalWorkflow.requested_with_notification(socket, request("recovered")) ==
               {socket, nil}

      {socket, tag} = recovery(socket)
      socket = ApprovalWorkflow.recovered(socket, tag, {:ok, []})
      assert socket.assigns.pending_approvals == []
      {socket, nil} = ApprovalWorkflow.requested_with_notification(socket, request("recovered"))
      assert ApprovalWorkflow.pending_request?(socket.assigns, "recovered")

      # Even a resolution received before its request must suppress a late arrival.
      socket = ApprovalWorkflow.resolved(socket, "resolved-before-arrival", :source@host)

      assert ApprovalWorkflow.requested_with_notification(
               socket,
               request("resolved-before-arrival")
             ) == {socket, nil}

      {socket, tag} = recovery(socket)
      {socket, payload} = ApprovalWorkflow.requested_with_notification(socket, request("live"))
      assert payload.request_id == "live"
      socket = ApprovalWorkflow.recovered(socket, tag, {:ok, [request("live")]})

      assert ApprovalWorkflow.requested_with_notification(socket, request("live")) ==
               {socket, nil}
    end

    test "generic review payload and host metadata never include evaluator or legacy secrets" do
      for details <- [
            %{tier: :write, code: "exact_write(secret)", warning: "write warning"},
            %{tier: :sudo, code: "exact_sudo(secret)", warning: "unrestricted sudo warning"},
            %{kind: :command, command: "private-command", args: ["private-argument"], level: 3}
          ] do
        expected = request("private-id", details)
        {socket, payload} = ApprovalWorkflow.requested_with_notification(socket(), expected)

        assert Map.keys(payload) |> Enum.sort() ==
                 [:body, :request_id, :scope, :tag, :title]

        assert payload.title == "Approval needed"
        assert payload.body == "Genesis is waiting for your approval."
        assert payload.tag =~ "genesis-approval:#{payload.scope}:"
        refute payload.tag =~ expected.request_id
        assert ApprovalWorkflow.pending_request(socket.assigns, expected.request_id) == expected

        host = ApprovalWorkflow.notification_host(socket.assigns)
        assert host == %{scope: payload.scope, request_ids: [expected.request_id]}

        assert Jason.decode!(ApprovalWorkflow.notification_host_json(socket.assigns)) == %{
                 "scope" => payload.scope,
                 "request_ids" => [expected.request_id]
               }
      end
    end
  end

  describe "exact-id review routing" do
    test "selects only the requested owned pending row, without submitting a decision" do
      first = request("first")
      second = request("second")
      foreign = request("foreign", %{node: :foreign@host})

      socket =
        socket()
        |> ApprovalWorkflow.requested(first)
        |> ApprovalWorkflow.requested(second)

      # Corrupt/stale display rows must not become review authority.
      socket = assign(socket, pending_approvals: [nil, foreign, second, first])
      captured_scope = ApprovalWorkflow.notification_scope(socket.assigns)
      assert ApprovalWorkflow.dialog_index(socket.assigns, "first", captured_scope) == 3
      assert ApprovalWorkflow.dialog_index(socket.assigns, "second") == 2
      assert ApprovalWorkflow.pending_request(socket.assigns, "first") == first
      assert ApprovalWorkflow.pending_request?(socket.assigns, "second")

      for id <- [nil, 17, %{}, [], "", " ", " first", "first ", "FIRST", "forged", "foreign"] do
        assert ApprovalWorkflow.pending_request(socket.assigns, id) == nil
        refute ApprovalWorkflow.pending_request?(socket.assigns, id)
        assert ApprovalWorkflow.dialog_index(socket.assigns, id) == nil
        assert ApprovalWorkflow.dialog_index(socket.assigns, id, captured_scope) == nil
        assert ApprovalWorkflow.notification_payload(socket.assigns, id) == nil
      end

      assert socket.assigns.approval_responses == %{}
      assert ApprovalWorkflow.notification_request_ids(socket.assigns) == ["second", "first"]

      socket =
        socket
        |> assign(pending_approvals: [second, first])
        |> ApprovalWorkflow.resolved("second", :source@host)

      assert ApprovalWorkflow.dialog_index(socket.assigns, "second", captured_scope) == nil
      assert ApprovalWorkflow.dialog_index(socket.assigns, "first", captured_scope) == 0
    end

    test "each captured chat scope field invalidates a notification click without falling back" do
      socket = ApprovalWorkflow.requested(socket(), request("exact"))
      captured_scope = ApprovalWorkflow.notification_scope(socket.assigns)
      assert is_binary(captured_scope)
      assert ApprovalWorkflow.notification_scope?(socket.assigns, captured_scope)
      assert ApprovalWorkflow.dialog_index(socket.assigns, "exact", captured_scope) == 0

      for {key, value} <- [
            {:chat_id, "different-chat"},
            {:current_node_id, "different-target"},
            {:current_node, :different_view@host},
            {:chat_node, :different_source@host},
            {:chat_task_id, "different-task"},
            {:chat_agent_id, 18}
          ] do
        changed = assign(socket, [{key, value}])
        refute ApprovalWorkflow.notification_scope?(changed.assigns, captured_scope), inspect(key)
        assert ApprovalWorkflow.dialog_index(changed.assigns, "exact", captured_scope) == nil
        assert changed.assigns.approval_responses == %{}
      end

      for invalid <- [nil, 17, %{}, [], "", "forged-scope"] do
        refute ApprovalWorkflow.notification_scope?(socket.assigns, invalid)
        assert ApprovalWorkflow.dialog_index(socket.assigns, "exact", invalid) == nil
      end

      pending = assign(socket, current_node_id: "pending-remote", current_node: node())
      assert ApprovalWorkflow.notification_scope(pending.assigns) == nil
      assert ApprovalWorkflow.notification_host(pending.assigns) == %{scope: nil, request_ids: []}
      assert ApprovalWorkflow.dialog_index(pending.assigns, "exact", captured_scope) == nil
    end

    test "busy and failed exact-id reviews remain available until source-authoritative settlement" do
      expected = request("exact", %{tier: :sudo, warning: "unrestricted", code: "original()"})
      other = request("other")

      socket =
        socket()
        |> ApprovalWorkflow.requested(other)
        |> ApprovalWorkflow.requested(expected)
        |> assign(approval_responses: %{"exact" => 101, "other" => 102})

      captured_scope = ApprovalWorkflow.notification_scope(socket.assigns)
      assert ApprovalWorkflow.dialog_index(socket.assigns, "exact", captured_scope) == 0
      assert ApprovalWorkflow.busy?(socket.assigns, "exact")
      assert ApprovalWorkflow.respond(socket, "exact", "deny") == socket
      assert ApprovalWorkflow.resolved(socket, "exact", expected.target_node) == socket

      tag = {:approval_workflow_response, 101, scope(socket), "exact"}
      failed = ApprovalWorkflow.responded(socket, tag, {:error, :timeout})
      assert failed.assigns.approval_error == {:response, "exact", :timeout}
      assert failed.assigns.approval_responses == %{"other" => 102}
      assert ApprovalWorkflow.pending_request(failed.assigns, "exact") == expected
      assert ApprovalWorkflow.dialog_index(failed.assigns, "exact", captured_scope) == 0
      assert ApprovalWorkflow.requested_with_notification(failed, expected) == {failed, nil}

      settled = ApprovalWorkflow.resolved(failed, "exact", expected.node)
      assert ApprovalWorkflow.dialog_index(settled.assigns, "exact", captured_scope) == nil
      assert settled.assigns.pending_approvals == [other]
      assert settled.assigns.approval_responses == %{"other" => 102}
    end
  end

  # Independent fixtures keep this pure suite runnable without loading another test file.
  defp socket do
    ApprovalWorkflow.init(%Phoenix.LiveView.Socket{
      assigns: %{
        __changed__: %{},
        chat_id: "chat-1",
        current_node_id: nil,
        current_node: node(),
        chat_node: :source@host,
        chat_task_id: "task-1",
        chat_agent_id: 17
      }
    })
  end

  defp request(id, overrides \\ %{}) do
    Map.merge(
      %{
        request_id: id,
        node: :source@host,
        task_id: "task-1",
        agent_id: 17,
        kind: :elixir_eval,
        target_node: :evaluator@host,
        code: "original()"
      },
      overrides
    )
  end

  defp scope(socket) do
    a = socket.assigns
    {a.chat_id, a.current_node_id, a.current_node, a.chat_node, a.chat_task_id, a.chat_agent_id}
  end

  defp recovery(socket) do
    {assign(socket, approval_recovering: true, approval_recovery_seq: 100),
     {:approval_pending_loaded, 100, scope(socket)}}
  end
end
