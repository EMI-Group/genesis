defmodule EvoDashWeb.HealthControllerTest do
  use EvoDashWeb.ConnCase, async: true

  describe "GET /health" do
    test "answers 200 JSON with status, version and uptime", %{conn: conn} do
      conn = get(conn, "/health")

      assert conn.status == 200
      assert [content_type] = get_resp_header(conn, "content-type")
      assert content_type =~ "application/json"

      body = json_response(conn, 200)
      assert body["status"] == "ok"
      assert is_binary(body["version"])
      assert body["version"] != ""
      assert is_integer(body["uptime_ms"])
      assert body["uptime_ms"] >= 0
    end

    # The regression this guards: the old implementation read the VM start time
    # from the wrong clock/unit and always degraded to `0`. The test VM has been
    # up for a while, so a real (non-zero) uptime is deterministic here.
    test "reports the real VM uptime in milliseconds", %{conn: conn} do
      body = json_response(get(conn, "/health"), 200)

      assert is_integer(body["uptime_ms"])
      assert body["uptime_ms"] > 0
      # Sane upper bound: a fresh test VM is minutes old at most, and certainly
      # not near an epoch-value (~1.7e12 ms) or a native-unit leak (~1e17 ms).
      assert body["uptime_ms"] < :timer.hours(24)
    end

    test "uptime is monotonic across calls", %{conn: conn} do
      first = json_response(get(conn, "/health"), 200)["uptime_ms"]

      Process.sleep(20)

      second = json_response(get(conn, "/health"), 200)["uptime_ms"]

      assert is_integer(first)
      assert is_integer(second)
      assert second >= first
    end

    test "needs no session, CSRF token or authentication", %{conn: conn} do
      # A bare connection (no browser pipeline, no cookies) is enough.
      conn = get(conn, "/health")

      assert conn.status == 200
      # The probe must not redirect (e.g. to the onboarding/welcome page).
      assert conn.state == :sent
    end

    test "reports the running evo_dash application version", %{conn: conn} do
      body = json_response(get(conn, "/health"), 200)

      assert body["version"] == to_string(Application.spec(:evo_dash, :vsn))
    end
  end
end
