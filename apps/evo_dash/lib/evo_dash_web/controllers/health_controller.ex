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

  # `system_info(:start_time)` is an Erlang epoch timestamp, so `:timer.now_diff/2`
  # against `:os.timestamp/0` yields elapsed native time. Clamped at 0 so clock
  # skew (a start time in the "future") can never produce a negative uptime.
  defp uptime_ms do
    case :erlang.system_info(:start_time) do
      start_time when is_tuple(start_time) ->
        max(div(:timer.now_diff(:os.timestamp(), start_time), 1000), 0)

      _other ->
        0
    end
  end
end
