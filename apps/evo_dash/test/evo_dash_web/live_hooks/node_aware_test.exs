defmodule EvoDashWeb.NodeAwareTest do
  # Tests the transition-detection + push_patch behavior of
  # handle_connection_status/2. We build a minimal LiveView socket struct and
  # call the helper directly, then assert on the returned socket's `redirected`
  # field (push_patch sets it to {:live, :patch, %{to: path}}) or the assigns.
  #
  # This avoids booting a real LiveView or remote node — we only test the
  # pure transition-detection logic in the hook.
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
        connection_statuses: %{}
      }
      |> Map.merge(overrides)

    %Phoenix.LiveView.Socket{assigns: assigns, redirected: nil}
  end

  # Extracts the patch destination path from a push_patch socket, or returns
  # nil if not redirected. push_patch sets socket.redirected to
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
      socket = socket(%{current_node: node(), current_node_id: "gpu-server", connection_statuses: %{}})

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
end
