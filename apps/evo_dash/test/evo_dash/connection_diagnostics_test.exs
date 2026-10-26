defmodule EvoDash.ConnectionDiagnosticsTest do
  use ExUnit.Case, async: true

  test "attach/0 registers the handler idempotently and copies the peer address to Logger metadata" do
    assert EvoDash.ConnectionDiagnostics.attach() == :ok
    assert EvoDash.ConnectionDiagnostics.attach() == :ok

    handlers = :telemetry.list_handlers([:thousand_island, :connection, :start])
    assert Enum.count(handlers, &(&1.id == EvoDash.ConnectionDiagnostics)) == 1

    # The handler runs in the emitting process, so observe the metadata there.
    metadata =
      Task.async(fn ->
        :telemetry.execute(
          [:thousand_island, :connection, :start],
          %{},
          %{remote_address: {127, 0, 0, 1}, remote_port: 12_345}
        )

        Logger.metadata()
      end)
      |> Task.await(2000)

    assert metadata[:remote_ip] == "127.0.0.1"
    assert metadata[:remote_port] == 12_345
  end
end
