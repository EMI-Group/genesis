defmodule EvoDashWeb.RemoteGateComponentsTest do
  use ExUnit.Case, async: true

  import Phoenix.LiveViewTest

  alias EvoDashWeb.RemoteGateComponents

  # Component-level tests for the remote-connection gate
  # (`remote_connection_gate/1` + `gate_active?/1`).
  #
  # The gate is rendered fully-qualified by the five node-aware LiveViews
  # (agents/tasks/settings/system/review) with the RAW LiveView assigns map,
  # which carries `current_node_name` but NO `:name` key — so the display-name
  # fallback (`name` attr → `current_node_name` → "Local") is the core
  # regression this suite guards.

  describe "remote_connection_gate/1 connecting states" do
    for phase <- [:connecting, :bootstrapping, :disconnecting] do
      test "phase #{inspect(phase)} renders the spinner and connecting text" do
        html =
          render_component(&RemoteGateComponents.remote_connection_gate/1,
            remote_status: %{phase: unquote(phase)},
            name: "gpu-server"
          )

        assert html =~ "loading loading-spinner"
        assert html =~ "Connecting to gpu-server…"

        # No error content in the connecting state.
        refute html =~ "alert"
        refute html =~ "Retry"
        refute html =~ "Manage Connections"
        refute html =~ "Switch to Local"
      end
    end

    test "remote_status nil (the guard) renders the spinner and connecting text" do
      html =
        render_component(&RemoteGateComponents.remote_connection_gate/1,
          name: "gpu-server"
        )

      assert html =~ "loading loading-spinner"
      assert html =~ "Connecting to gpu-server…"
      refute html =~ "alert"
      refute html =~ "Retry"
      refute html =~ "Manage Connections"
      refute html =~ "Switch to Local"
    end
  end

  describe "remote_connection_gate/1 display-name fallback" do
    test "current_node_name is used when :name is absent (raw LiveView assigns)" do
      html =
        render_component(&RemoteGateComponents.remote_connection_gate/1,
          current_node_name: "gpu-server"
        )

      assert html =~ "Connecting to gpu-server…"
      refute html =~ "Connecting to Local…"
    end

    test "explicit name attr renders the given name" do
      html =
        render_component(&RemoteGateComponents.remote_connection_gate/1,
          name: "gpu-server"
        )

      assert html =~ "Connecting to gpu-server…"
    end

    test "name attr takes precedence over current_node_name" do
      html =
        render_component(&RemoteGateComponents.remote_connection_gate/1,
          name: "gpu-server",
          current_node_name: "other-server"
        )

      assert html =~ "Connecting to gpu-server…"
      refute html =~ "other-server"
    end

    test "falls back to Local when neither name nor current_node_name is given" do
      html = render_component(&RemoteGateComponents.remote_connection_gate/1, %{})

      assert html =~ "Connecting to Local…"
    end
  end

  describe "remote_connection_gate/1 error states" do
    for phase <- [:error, :disconnected] do
      test "phase #{inspect(phase)} renders the alert with last_error and all three actions" do
        html =
          render_component(&RemoteGateComponents.remote_connection_gate/1,
            remote_status: %{phase: unquote(phase), last_error: "ssh: connection refused"},
            name: "gpu-server"
          )

        assert html =~ "alert"
        assert html =~ "Cannot connect to gpu-server"
        assert html =~ "ssh: connection refused"
        assert html =~ ~s(phx-click="retry_remote_connection")
        assert html =~ "/settings?category=remote_connections"
        assert html =~ "Manage Connections"
        assert html =~ ~s(phx-click="switch_to_local")
        assert html =~ "Switch to Local"

        # No spinner in the error state.
        refute html =~ "loading-spinner"
      end

      test "phase #{inspect(phase)} shows the fallback string when last_error is nil" do
        html =
          render_component(&RemoteGateComponents.remote_connection_gate/1,
            remote_status: %{phase: unquote(phase)},
            name: "gpu-server"
          )

        assert html =~ "Connection lost or failed"
        assert html =~ "Cannot connect to gpu-server"
      end
    end
  end

  describe "remote_connection_gate/1 connected state" do
    test "phase :connected renders no page content" do
      html =
        render_component(&RemoteGateComponents.remote_connection_gate/1,
          remote_status: %{phase: :connected},
          name: "gpu-server"
        )

      # render_component output may carry LiveView trace comment markers
      # (<!-- <module> ... -->), so assert on the absence of content markers
      # rather than exact-empty equality.
      refute html =~ "loading-spinner"
      refute html =~ "alert"
      refute html =~ "Retry"
      refute html =~ "Connecting to"
      refute html =~ "Cannot connect"
      refute html =~ "Switch to Local"
    end
  end

  describe "gate_active?/1 truth table" do
    test "local (current_node_id nil) → false" do
      refute RemoteGateComponents.gate_active?(%{current_node_id: nil})

      refute RemoteGateComponents.gate_active?(%{
               current_node_id: nil,
               remote_status: %{phase: :connecting}
             })
    end

    test "node set + remote_status nil → true (the guard)" do
      assert RemoteGateComponents.gate_active?(%{current_node_id: "gpu-server"})

      assert RemoteGateComponents.gate_active?(%{
               current_node_id: "gpu-server",
               remote_status: nil
             })
    end

    for phase <- [:connecting, :bootstrapping, :disconnecting, :error, :disconnected] do
      test "node set + phase #{inspect(phase)} → true" do
        assert RemoteGateComponents.gate_active?(%{
                 current_node_id: "gpu-server",
                 remote_status: %{phase: unquote(phase)}
               })
      end
    end

    test "node set + phase :connected → false" do
      refute RemoteGateComponents.gate_active?(%{
               current_node_id: "gpu-server",
               remote_status: %{phase: :connected}
             })
    end

    test "non-map argument → false" do
      refute RemoteGateComponents.gate_active?(nil)
      refute RemoteGateComponents.gate_active?("gpu-server")
      refute RemoteGateComponents.gate_active?(:gpu_server)
      refute RemoteGateComponents.gate_active?(123)
      refute RemoteGateComponents.gate_active?(current_node_id: "gpu-server")
    end

    test "map with an unknown phase → false" do
      refute RemoteGateComponents.gate_active?(%{
               current_node_id: "gpu-server",
               remote_status: %{phase: :unknown}
             })
    end

    test "remote_status that is not a map → false" do
      refute RemoteGateComponents.gate_active?(%{
               current_node_id: "gpu-server",
               remote_status: :foo
             })

      refute RemoteGateComponents.gate_active?(%{
               current_node_id: "gpu-server",
               remote_status: []
             })
    end
  end
end
