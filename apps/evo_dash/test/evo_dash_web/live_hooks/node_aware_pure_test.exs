defmodule EvoDashWeb.NodeAwarePureTest do
  # Pure socket-only / pure-function tests split out of
  # EvoDashWeb.NodeAwareTest so they can run `async: true`:
  #
  # * handle_connection_status/2 transition detection (read-only registry reads)
  # * partition_active_tasks/1 (pure function)
  # * handle_task_info/2 node-filtered debounce (socket in/out, Process.send_after)
  # * event_from_current_node?/2 (pure function)
  #
  # They touch NO global Store/TaskRegistry, NO XDG_CONFIG_HOME and NO
  # EvoDash.ActiveTasks hub, so they cannot collide with the sync NodeAwareTest
  # (which terminates/restarts the production Store/TaskRegistry and swaps
  # XDG_CONFIG_HOME and registers fake connection managers in the shared
  # EvoGit.RemoteConnection.Registry).
  use ExUnit.Case, async: true

  alias EvoDashWeb.LiveHooks.NodeAware

  # Build a minimal LiveView socket with the assigns the helper reads.
  # `redirected: nil` is required for push_patch to work (it raises if already
  # set). `assigns.__changed__` is required by Phoenix.LiveView.Socket's default.
  defp socket(overrides) do
    assigns =
      %{
        __changed__: nil,
        current_node: node(),
        current_node_name: "Local",
        current_node_id: "gpu-server",
        current_path: "/agents",
        connection_statuses: %{},
        running_tasks: [],
        pending_tasks: [],
        tasks_load_seq: 0,
        tasks_reload_pending: false
      }
      |> Map.merge(overrides)

    %Phoenix.LiveView.Socket{assigns: assigns, redirected: nil}
  end

  # Extracts the patch destination path from a push_patch socket,
  # {:live, :patch, %{kind: :push, to: path}}.
  defp patch_to(%Phoenix.LiveView.Socket{redirected: {:live, :patch, %{to: to}}}), do: to
  defp patch_to(_), do: nil

  describe "handle_connection_status/2 — meaningful transitions trigger push_patch" do
    test "local → remote: :connected for the selected node triggers push_patch" do
      # current_node is local (node()) — a :connected broadcast for the
      # selected node is a local→remote transition.
      socket =
        socket(%{
          current_node: node(),
          current_node_id: "gpu-server"
        })

      status = %{phase: :connected, node: "genesis_remote@127.0.0.1", last_error: nil}

      assert {:noreply, result} =
               NodeAware.handle_connection_status(
                 socket,
                 {:remote_connection_status, "gpu-server", status}
               )

      # push_patch sets socket.redirected to {:live, :patch, %{kind: :push, to: path}}
      assert patch_to(result) == "/agents?node=gpu-server"
    end

    test "remote → local: :disconnected for the selected node triggers push_patch" do
      # current_node is remote — a :disconnected broadcast is a remote→local
      # transition.
      socket =
        socket(%{
          current_node: :"genesis_remote@127.0.0.1",
          current_node_id: "gpu-server"
        })

      assert {:noreply, result} =
               NodeAware.handle_connection_status(
                 socket,
                 {:remote_connection_status, "gpu-server", %{phase: :disconnected}}
               )

      assert patch_to(result) == "/agents?node=gpu-server"
    end

    test "remote → local: :error for the selected node triggers push_patch" do
      socket =
        socket(%{
          current_node: :"genesis_remote@127.0.0.1",
          current_node_id: "gpu-server"
        })

      assert {:noreply, result} =
               NodeAware.handle_connection_status(
                 socket,
                 {:remote_connection_status, "gpu-server", %{phase: :error, last_error: "boom"}}
               )

      assert patch_to(result) == "/agents?node=gpu-server"

      # :remote_status is recomputed from the live connection manager (in the
      # test env no manager is registered, so it degrades to the disconnected
      # default map) — never stale.
      assert %{phase: :disconnected} = result.assigns[:remote_status]
    end
  end

  describe "handle_connection_status/2 — non-transitions do NOT push_patch" do
    test ":connecting for the selected node does not push_patch" do
      # current_node is local/pending — a :connecting status is NOT a
      # reload-worthy transition (page already showing local data).
      socket = socket(%{current_node: node(), current_node_id: "gpu-server"})

      assert {:noreply, result} =
               NodeAware.handle_connection_status(
                 socket,
                 {:remote_connection_status, "gpu-server", %{phase: :connecting}}
               )

      assert patch_to(result) == nil
    end

    test ":connected for the selected node when ALREADY remote does not push_patch" do
      # current_node is already remote — a duplicate :connected is not a
      # transition (no local→remote change).
      socket =
        socket(%{
          current_node: :"genesis_remote@127.0.0.1",
          current_node_id: "gpu-server"
        })

      status = %{phase: :connected, node: "genesis_remote@127.0.0.1"}

      assert {:noreply, result} =
               NodeAware.handle_connection_status(
                 socket,
                 {:remote_connection_status, "gpu-server", status}
               )

      assert patch_to(result) == nil
    end

    test ":disconnected for the selected node when ALREADY local does not push_patch" do
      # current_node is already local — a :disconnected is not a transition
      # (no remote→local change).
      socket = socket(%{current_node: node(), current_node_id: "gpu-server"})

      assert {:noreply, result} =
               NodeAware.handle_connection_status(
                 socket,
                 {:remote_connection_status, "gpu-server", %{phase: :disconnected}}
               )

      assert patch_to(result) == nil
    end

    test "status for a NON-selected node does not push_patch" do
      # The selected node is gpu-server, but the broadcast is for another node.
      socket = socket(%{current_node: node(), current_node_id: "gpu-server"})

      status = %{phase: :connected, node: "other_remote@127.0.0.1"}

      assert {:noreply, result} =
               NodeAware.handle_connection_status(
                 socket,
                 {:remote_connection_status, "other-host", status}
               )

      assert patch_to(result) == nil
    end

    test ":bootstrapping for the selected node does not push_patch" do
      socket = socket(%{current_node: node(), current_node_id: "gpu-server"})

      assert {:noreply, result} =
               NodeAware.handle_connection_status(
                 socket,
                 {:remote_connection_status, "gpu-server",
                  %{phase: :bootstrapping, bootstrap_stage: :uploading}}
               )

      assert patch_to(result) == nil
    end
  end

  describe "handle_connection_status/2 — always refreshes connection_statuses" do
    test "refreshes connection_statuses even when not a transition" do
      socket =
        socket(%{current_node: node(), current_node_id: "gpu-server", connection_statuses: %{}})

      # node() calls to EvoDash.NodeContext.connection_status/0 should be fine
      # even in test env (returns %{} when subsystem unavailable).
      assert {:noreply, result} =
               NodeAware.handle_connection_status(
                 socket,
                 {:remote_connection_status, "gpu-server", %{phase: :connecting}}
               )

      # connection_statuses was refreshed (it's now the value from NodeContext,
      # not the stale %{})
      assert Map.has_key?(result.assigns, :connection_statuses)
    end
  end

  describe "handle_connection_status/2 — fallback clause" do
    test "unknown message shape just refreshes statuses" do
      socket = socket(%{})

      assert {:noreply, result} =
               NodeAware.handle_connection_status(socket, {:some_other_message, 1, 2})

      assert patch_to(result) == nil
    end
  end

  describe "partition_active_tasks/1 — pure partitioning" do
    # Pure function tests (no socket, no store) — partition_active_tasks/1 only
    # reads `status` for the running filter, and status/review_status/type for
    # the pending (review-candidate) filter.
    test "a :cancelling summary lands in the running partition" do
      {running, pending} = NodeAware.partition_active_tasks([%{id: "t1", status: :cancelling}])

      assert Enum.map(running, & &1.id) == ["t1"]
      assert pending == []
    end

    test "a :cancelled summary does NOT land in the running partition" do
      # :cancelled is terminal — it is neither running (not in the in-flight
      # status list) nor pending (not :completed, so not a review candidate).
      {running, pending} = NodeAware.partition_active_tasks([%{id: "t2", status: :cancelled}])

      assert running == []
      assert pending == []
    end

    test ":running/:pending/:finalizing summaries land in the running partition (regression)" do
      summaries = [
        %{id: "r1", status: :running},
        %{id: "p1", status: :pending},
        %{id: "f1", status: :finalizing}
      ]

      {running, pending} = NodeAware.partition_active_tasks(summaries)

      assert Enum.map(running, & &1.id) |> Enum.sort() == ["f1", "p1", "r1"]
      assert pending == []
    end

    test "a COMPLETED task with NO primary branch lands in the pending partition" do
      # Review candidacy no longer inspects the result/branch — a task that made
      # no changes in its PRIMARY repo but changed writable FOREIGN repos is
      # still reviewable. Column/summary-based: only status/review_status/type.
      summaries = [
        %{
          id: "done-no-branch",
          status: :completed,
          review_status: nil,
          type: :evolve,
          branch_name: nil,
          started_at: nil,
          finished_at: nil
        }
      ]

      {running, pending} = NodeAware.partition_active_tasks(summaries)

      assert running == []
      assert Enum.map(pending, & &1.id) == ["done-no-branch"]
    end

    test "a COMPLETED :reflect task is EXCLUDED from the pending partition" do
      # Repo-less self-reflective tasks have no code review — excluded
      # explicitly (previously only incidental via the branch check).
      summaries = [
        %{
          id: "reflect-1",
          status: :completed,
          review_status: nil,
          type: :reflect,
          branch_name: nil
        }
      ]

      {running, pending} = NodeAware.partition_active_tasks(summaries)

      assert running == []
      assert pending == []
    end

    test "a COMPLETED task with a non-nil review_status is NOT a review candidate" do
      summaries = [
        %{
          id: "already-reviewed",
          status: :completed,
          review_status: :merged,
          type: :evolve,
          branch_name: "feature-1"
        }
      ]

      {running, pending} = NodeAware.partition_active_tasks(summaries)

      assert running == []
      assert pending == []
    end
  end

  describe "handle_task_info/2 — node-filtered debounce" do
    # The node-identity PubSub contract: `{:task_updated, task_id, status,
    # node}` / `{:task_deleted, task_id, node}` where node is the BEAM node
    # atom of the publishing node. A matching-node event schedules the 300ms
    # trailing-edge debounce (`:node_aware_reload_tasks`); a foreign-node event
    # is dropped BEFORE the debounce — socket returned unchanged, no message.
    # Every scheduling test drains the message with `assert_receive` so a late
    # delivery can never leak into a later test's `refute_receive`.
    #
    # The receive budget (2000ms) is generously ABOVE the real 300ms
    # production debounce (`Process.send_after(self(), :node_aware_reload_tasks,
    # 300)`): the requirement is unchanged (the debounce message MUST arrive),
    # but the margin absorbs timer/scheduler latency on a loaded machine — a
    # 500ms budget is only 200ms above the timer and reproducibly flaked under
    # CPU load ("message delivered too close to the timeout value").
    test "{:task_updated, _, _, node()} with matching node schedules the debounce" do
      sock = socket(%{current_node: node(), tasks_reload_pending: false})

      assert {:noreply, result} =
               NodeAware.handle_task_info(sock, {:task_updated, "t1", :running, node()})

      assert result.assigns[:tasks_reload_pending] == true
      assert_receive :node_aware_reload_tasks, 2_000
    end

    test "{:task_updated, _, _, foreign_node} is dropped (socket unchanged, no reload scheduled)" do
      sock = socket(%{current_node: node(), tasks_reload_pending: false})

      assert {:noreply, result} =
               NodeAware.handle_task_info(sock, {:task_updated, "t1", :running, :remote@other})

      assert result == sock
      assert result.assigns[:tasks_reload_pending] == false
      refute_receive :node_aware_reload_tasks, 150
    end

    test "{:task_deleted, _, node()} with matching node schedules the debounce" do
      sock = socket(%{current_node: node(), tasks_reload_pending: false})

      assert {:noreply, result} =
               NodeAware.handle_task_info(sock, {:task_deleted, "t1", node()})

      assert result.assigns[:tasks_reload_pending] == true
      assert_receive :node_aware_reload_tasks, 2_000
    end

    test "{:task_deleted, _, foreign_node} is dropped (socket unchanged, no reload scheduled)" do
      sock = socket(%{current_node: node(), tasks_reload_pending: false})

      assert {:noreply, result} =
               NodeAware.handle_task_info(sock, {:task_deleted, "t1", :remote@other})

      assert result == sock
      assert result.assigns[:tasks_reload_pending] == false
      refute_receive :node_aware_reload_tasks, 150
    end

    test "remote viewing: event from the viewed remote node schedules; a local event is dropped" do
      remote_node = :"genesis_remote@127.0.0.1"
      sock = socket(%{current_node: remote_node, tasks_reload_pending: false})

      # The remote daemon's own event matches the viewed node → reload.
      assert {:noreply, result} =
               NodeAware.handle_task_info(sock, {:task_updated, "t1", :completed, remote_node})

      assert result.assigns[:tasks_reload_pending] == true
      assert_receive :node_aware_reload_tasks, 2_000

      # A local-node event while viewing the remote node → dropped.
      sock2 = socket(%{current_node: remote_node, tasks_reload_pending: false})

      assert {:noreply, result2} =
               NodeAware.handle_task_info(sock2, {:task_updated, "t2", :completed, node()})

      assert result2 == sock2
      assert result2.assigns[:tasks_reload_pending] == false
      refute_receive :node_aware_reload_tasks, 150
    end

    test "review-only mutation (status nil) with matching node schedules the debounce" do
      sock = socket(%{current_node: node(), tasks_reload_pending: false})

      assert {:noreply, result} =
               NodeAware.handle_task_info(sock, {:task_updated, "t1", nil, node()})

      assert result.assigns[:tasks_reload_pending] == true
      assert_receive :node_aware_reload_tasks, 2_000
    end

    test "a second matching broadcast while a reload is pending is dropped (coalescing)" do
      sock = socket(%{current_node: node(), tasks_reload_pending: false})

      {:noreply, result} =
        NodeAware.handle_task_info(sock, {:task_updated, "t1", :running, node()})

      assert result.assigns[:tasks_reload_pending] == true

      # The second broadcast arrives while the reload is pending — dropped.
      {:noreply, result2} =
        NodeAware.handle_task_info(result, {:task_updated, "t2", :completed, node()})

      assert result2 == result

      # Exactly ONE :node_aware_reload_tasks message was scheduled.
      assert_receive :node_aware_reload_tasks, 2_000
      refute_receive :node_aware_reload_tasks, 150
    end
  end

  describe "event_from_current_node?/2 — node-identity filter" do
    test "local viewing: true for node(), false for a foreign atom" do
      assert NodeAware.event_from_current_node?(%{current_node: node()}, node())
      refute NodeAware.event_from_current_node?(%{current_node: node()}, :remote@other)
    end

    test "remote viewing: true for the viewed remote atom, false for node()" do
      remote_node = :genesis_remote@host
      assert NodeAware.event_from_current_node?(%{current_node: remote_node}, remote_node)
      refute NodeAware.event_from_current_node?(%{current_node: remote_node}, node())
    end

    test "missing :current_node assign falls back to node()" do
      assert NodeAware.event_from_current_node?(%{}, node())
      refute NodeAware.event_from_current_node?(%{}, :remote@other)
    end
  end
end
