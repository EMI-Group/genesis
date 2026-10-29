defmodule EvoDashWeb.HealthController do
  @moduledoc """
  Unauthenticated liveness/readiness probe (`GET /health`).

  Answers a tiny JSON document describing this backend process, so an external
  process can tell whether the dashboard is up: the headless server CLI
  (`genesis status`) polls it, and the desktop/remote shell uses the same
  contract for health checks. The endpoint is deliberately outside every
  pipeline: no session, no CSRF token, no authentication and no HTML content
  negotiation, so a plain HTTP GET is all a caller needs.

  Response: `200` with `application/json`,
  `{"status":"ok","version":"<vsn>","uptime_ms":<integer>}`.

  `uptime_ms` is the elapsed VM time measured on the Erlang **monotonic** clock:
  `:erlang.system_info(:start_time)` and `:erlang.monotonic_time/0` are two
  readings of the SAME clock, so their difference is the uptime. The
  non-obvious part is the unit — `:start_time` is an INTEGER in the runtime's
  native time unit (nanoseconds on every supported platform), NOT an epoch
  timestamp, a timestamp tuple or a millisecond value, so it must be subtracted
  from a native-unit reading and converted with `:erlang.convert_time_unit/3`
  (mixing it with a millisecond reading yields a nonsensical value).
  """

  use EvoDashWeb, :controller

  @doc """
  Renders the health document. Never raises: an unreadable app version or VM
  start time degrades to a placeholder value instead of failing the probe.
  """
  @spec index(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def index(conn, _params) do
    json(conn, %{status: "ok", version: version(), uptime_ms: uptime_ms()})
  end

  # `Application.spec/2` returns `nil` for an app that is not loaded.
  defp version do
    case Application.spec(:evo_dash, :vsn) do
      vsn when is_list(vsn) or is_binary(vsn) -> to_string(vsn)
      _other -> "unknown"
    end
  end

  # Both readings are on the Erlang monotonic clock and therefore on the same
  # time base: `system_info(:start_time)` is the native-unit monotonic reading
  # of VM start, `monotonic_time/0` the native-unit reading of now. Converting
  # the difference keeps us on one clock (an epoch/monotonic mix or a
  # native/millisecond mix would be wrong). Clamped at 0 so clock adjustments
  # can never produce a negative uptime.
  defp uptime_ms do
    case :erlang.system_info(:start_time) do
      started_at when is_integer(started_at) ->
        elapsed = :erlang.monotonic_time() - started_at
        max(:erlang.convert_time_unit(elapsed, :native, :millisecond), 0)

      _other ->
        0
    end
  end
end
