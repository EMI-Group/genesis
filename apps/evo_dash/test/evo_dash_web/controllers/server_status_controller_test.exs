defmodule EvoDashWeb.ServerStatusControllerTest do
  # async: true — the ONLY process-global this suite touches is the
  # `:evo_dash` app-env key `:server_status_task_runner` (the seam injected by
  # `put_seam/2` below). That key is read ONLY by
  # `EvoDashWeb.ServerStatusController.task_runner/0`, which no other suite
  # exercises (grep: the key appears in no other file), and every test restores
  # the previous value in `on_exit`, so no concurrent async module can observe
  # it. Nothing else here is shared: the default-path test reads the real
  # `EvoGit.TaskRegistry` without writing to it.
  use EvoDashWeb.ConnCase, async: true

  @seam :server_status_task_runner

  describe "GET /server/status" do
    test "answers 200 JSON with exactly status, version and active_tasks", %{conn: conn} do
      put_seam(@seam, fn -> [%{id: "a"}, %{id: "b"}] end)

      conn = get(conn, "/server/status")

      assert conn.status == 200
      assert [content_type] = get_resp_header(conn, "content-type")
      assert content_type =~ "application/json"

      body = json_response(conn, 200)

      assert body |> Map.keys() |> Enum.sort() == ["active_tasks", "status", "version"]
      assert body["status"] == "ok"
      assert is_binary(body["version"])
      assert body["version"] != ""
      assert is_integer(body["active_tasks"])
    end

    test "active_tasks counts the ids returned by the registry read", %{conn: conn} do
      put_seam(@seam, fn -> [%{id: "a"}, %{id: "b"}] end)

      assert json_response(get(conn, "/server/status"), 200)["active_tasks"] == 2
    end

    test "an empty live-task set reports 0", %{conn: conn} do
      put_seam(@seam, fn -> [] end)

      assert json_response(get(conn, "/server/status"), 200)["active_tasks"] == 0
    end

    test "a raising task read degrades to -1 and still answers 200", %{conn: conn} do
      put_seam(@seam, fn -> raise "boom" end)

      conn = get(conn, "/server/status")

      assert conn.status == 200
      assert json_response(conn, 200)["active_tasks"] == -1
    end

    # The interesting case: a registry `GenServer.call` timeout/dead process
    # EXITS the caller, which a `rescue` cannot catch — only `SafeCall.run/1`'s
    # `catch :exit` turns it into a value.
    test "an exiting task read degrades to -1", %{conn: conn} do
      put_seam(@seam, fn -> exit(:timeout) end)

      conn = get(conn, "/server/status")

      assert conn.status == 200
      assert json_response(conn, 200)["active_tasks"] == -1
    end

    test "a non-list task read degrades to -1 (never a wrong zero)", %{conn: conn} do
      put_seam(@seam, fn -> :nope end)

      conn = get(conn, "/server/status")

      assert conn.status == 200
      assert json_response(conn, 200)["active_tasks"] == -1
    end

    test "version reports the running evo_git application version", %{conn: conn} do
      body = json_response(get(conn, "/server/status"), 200)

      assert body["version"] == to_string(Application.spec(:evo_git, :vsn))
    end

    test "needs no session, CSRF token or authentication", %{conn: conn} do
      # A bare connection (no browser pipeline, no cookies) is enough.
      put_seam(@seam, fn -> [] end)

      conn = get(conn, "/server/status")

      assert conn.status == 200
      # The probe must not redirect (e.g. to the onboarding/welcome page).
      assert conn.state == :sent
    end

    # Leaves the seam at its default: the real `EvoGit.TaskRegistry` path must
    # produce an integer verdict — the task count, or `-1` when the registry is
    # unavailable — instead of raising.
    test "the default registry read returns an integer count", %{conn: conn} do
      active_tasks = json_response(get(conn, "/server/status"), 200)["active_tasks"]

      assert is_integer(active_tasks)

      if active_tasks != -1 do
        assert active_tasks >= 0
      end
    end
  end

  # ── helpers ────────────────────────────────────────────────────────

  # Injects a runner seam and restores the previous value on exit, so no
  # `:evo_dash` app-env state leaks into another suite.
  defp put_seam(key, fun) do
    previous = Application.get_env(:evo_dash, key)
    Application.put_env(:evo_dash, key, fun)

    on_exit(fn ->
      case previous do
        nil -> Application.delete_env(:evo_dash, key)
        value -> Application.put_env(:evo_dash, key, value)
      end
    end)

    :ok
  end
end
