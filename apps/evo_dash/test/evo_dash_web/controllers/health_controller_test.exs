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
