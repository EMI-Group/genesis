defmodule EvoDash.ConnectionDiagnosticsTest do
  use ExUnit.Case, async: true

  describe "attach/0" do
    test "registers the handler and is idempotent" do
      assert EvoDash.ConnectionDiagnostics.attach() == :ok
      assert EvoDash.ConnectionDiagnostics.attach() == :ok

      handlers = :telemetry.list_handlers([:thousand_island, :connection, :start])
      assert Enum.any?(handlers, &(&1.id == EvoDash.ConnectionDiagnostics))
    end
  end

  describe "handle_connection_start/4" do
    test "copies the peer address onto the connection process's Logger metadata" do
      assert EvoDash.ConnectionDiagnostics.attach() == :ok

      task =
        Task.async(fn ->
          :telemetry.execute(
            [:thousand_island, :connection, :start],
            %{},
            %{remote_address: {127, 0, 0, 1}, remote_port: 12_345}
          )

          Logger.metadata()
        end)

      metadata = Task.await(task, 2000)
      assert metadata[:remote_ip] == "127.0.0.1"
      assert metadata[:remote_port] == 12_345
    end
  end
end
