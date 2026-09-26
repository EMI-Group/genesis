defmodule EvoDash.ConnectionDiagnostics do
  @moduledoc """
  Connection-address diagnostics for HTTP connections.

  Bandit/ThousandIsland emit a `** (Bandit.HTTPError) Read timeout` ERROR line
  when a client opens a connection and then sends nothing for ~120s, but the
  client address is not visible in that line — so it is impossible to tell
  whether the client came from `::1` or `127.0.0.1`. The peer address IS
  available in ThousandIsland's connection-span metadata.

  This module attaches a `:telemetry` handler to
  `[:thousand_island, :connection, :start]` and copies
  `metadata[:remote_address]` / `metadata[:remote_port]` onto the CONNECTION
  PROCESS's `Logger.metadata/1`. `:telemetry.execute/3` runs handlers INLINE in
  the calling (connection) process, so that metadata lands on the connection
  process and rides every later log line of that connection — including the
  Bandit read timeout.

  It deliberately does NOT suppress or downgrade Bandit's protocol-error
  logging.

  Wired (non-fatally) from `EvoDash.Application.start/2` via `attach/0`, so it
  works in desktop AND normal modes. It is NOT a supervised child: there is
  nothing to supervise — `:telemetry` owns the handler registration. The
  `config/config.exs` console-logger `metadata:` list must include the new keys
  for them to actually appear in log output.
  """

  require Logger

  @event [:thousand_island, :connection, :start]

  @doc """
  Attaches the diagnostics handler to the ThousandIsland connection-start
  event.

  Idempotent: a second attach returns `{:error, :already_exists}`, which is
  treated as `:ok` (the handler id is this module). Never raises — returns
  `:ok` on success and `{:error, reason}` on any attach failure.
  """
  @spec attach() :: :ok | {:error, term()}
  def attach do
    case :telemetry.attach(__MODULE__, @event, &__MODULE__.handle_connection_start/4, nil) do
      :ok -> :ok
      {:error, :already_exists} -> :ok
      {:error, reason} -> {:error, reason}
    end
  rescue
    # Expected error? No — `:telemetry.attach/4` does not raise for our fixed
    # event/handler. But `attach/0` is called from `EvoDash.Application.start/2`,
    # where a raise would break app boot; degrading to a logged `{:error, _}`
    # (rather than swallowing the reason) is the cleanest non-fatal boundary.
    e ->
      Logger.warning("[desktop] connection diagnostics attach failed: #{inspect(e)}")
      {:error, e}
  end

  @doc """
  Telemetry handler for `[:thousand_island, :connection, :start]`.

  Reads `metadata[:remote_address]` (an `:inet.ip_address()` tuple) and
  `metadata[:remote_port]`, storing them on the connection process's Logger
  metadata as `:remote_ip` (human-readable, via `:inet.ntoa/1`) and
  `:remote_port`. Total: a missing or invalid value only omits its own key —
  it never raises.
  """
  @spec handle_connection_start(
          [atom()],
          map(),
          map(),
          :telemetry.handler_config()
        ) :: :ok
  def handle_connection_start(_event, _measurements, metadata, _config) do
    metadata = metadata || %{}

    case Map.get(metadata, :remote_address) do
      address when is_tuple(address) -> Logger.metadata(remote_ip: to_string(:inet.ntoa(address)))
      _ -> :ok
    end

    case Map.get(metadata, :remote_port) do
      port when is_integer(port) -> Logger.metadata(remote_port: port)
      _ -> :ok
    end

    :ok
  end
end
