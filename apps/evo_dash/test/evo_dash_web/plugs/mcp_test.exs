defmodule EvoDashWeb.MCPTest do
  use EvoDashWeb.ConnCase, async: true
  @moduletag :tmp_dir
  @token String.duplicate("test-token", 5)

  setup %{tmp_dir: dir} do
    Process.put(:evogit_config_dir, dir)
    File.mkdir_p!(EvoGit.Config.config_dir())
    File.write!(Path.join(EvoGit.Config.config_dir(), "mcp-token"), @token)
    File.chmod!(Path.join(EvoGit.Config.config_dir(), "mcp-token"), 0o600)
    :ok
  end

  test "negotiates protocol and discovers the finite task tool surface" do
    body =
      rpc("initialize", %{
        "protocolVersion" => "2025-11-25",
        "clientInfo" => %{"name" => "test", "version" => "1"},
        "capabilities" => %{}
      })

    assert body["result"]["protocolVersion"] == "2025-11-25"
    assert body["result"]["capabilities"] == %{"tools" => %{}}
    tools = rpc("tools/list")["result"]["tools"]

    assert Enum.sort(Enum.map(tools, & &1["name"])) ==
             ~w(genesis_cancel_task genesis_check genesis_get_result genesis_get_task genesis_list_models genesis_list_tasks genesis_reload_config genesis_send_message genesis_start_task)

    assert Enum.all?(tools, &(&1["inputSchema"]["type"] == "object"))
    start = Enum.find(tools, &(&1["name"] == "genesis_start_task"))
    mode = start["inputSchema"]["properties"]["mode"]
    assert mode["description"] =~ "evolve/simple"
    assert mode["description"] =~ "genesis/new"
    assert mode["description"] =~ "genesis/existing"
  end

  test "gets existing task errors as tool results and rejects malformed arguments" do
    result =
      rpc("tools/call", %{
        "name" => "genesis_get_task",
        "arguments" => %{"task_id" => "missing-mcp-task"}
      })["result"]

    assert result["isError"]
    assert result["structuredContent"]["error"]["code"] == "not_found"

    assert rpc("tools/call", %{"name" => "genesis_start_task", "arguments" => %{"path" => 42}})[
             "error"
           ]["code"] == -32602

    assert rpc("tools/call", %{"name" => "unknown"})["error"]["code"] == -32602
    assert rpc("not_a_method")["error"]["code"] == -32601
  end

  test "ping and notifications need no connection-bound session" do
    assert rpc("ping")["result"] == %{}
    conn = request(%{"jsonrpc" => "2.0", "method" => "notifications/initialized"})
    assert response(conn, 202) == ""
    assert rpc("tools/list")["result"]["tools"] != []
  end

  test "rejects unauthenticated, remote and browser-origin requests" do
    payload = Jason.encode!(%{"jsonrpc" => "2.0", "id" => 1, "method" => "tools/list"})

    assert %{build_conn() | host: "localhost"}
           |> put_req_header("content-type", "application/json")
           |> post("/mcp", payload)
           |> response(401)

    assert request(payload, "wrong") |> response(401)
    assert request(payload, @token, [{"origin", "https://evil.example"}]) |> response(403)
    conn = %{base_conn() | remote_ip: {10, 0, 0, 1}}
    assert post(conn, "/mcp", payload) |> response(403)
    assert request(payload, @token, [{"origin", "null"}]) |> response(403)
  end

  test "disabled without a local credential" do
    File.rm!(Path.join(EvoGit.Config.config_dir(), "mcp-token"))
    assert request(%{"jsonrpc" => "2.0", "id" => 1, "method" => "ping"}) |> response(503)
  end

  test "returns protocol errors for invalid JSON, envelope and version" do
    assert request("{") |> json_response(400) |> get_in(["error", "code"]) == -32700
    assert request([]) |> json_response(400) |> get_in(["error", "code"]) == -32600

    assert request(%{"jsonrpc" => "2.0", "id" => %{}, "method" => "ping"})
           |> json_response(400)
           |> get_in(["error", "code"]) == -32600

    assert request(%{"jsonrpc" => "2.0", "id" => 1, "method" => "ping"}, @token, [
             {"mcp-protocol-version", "unknown"}
           ])
           |> response(400)
  end

  test "does not offer streaming or session deletion" do
    assert base_conn() |> get("/mcp") |> response(405)
    assert base_conn() |> delete("/mcp") |> response(405)
  end

  test "does not enable MCP with an empty credential padded by whitespace" do
    File.write!(Path.join(EvoGit.Config.config_dir(), "mcp-token"), String.duplicate(" ", 40))
    assert request(%{"jsonrpc" => "2.0", "id" => 1, "method" => "ping"}, "") |> response(503)
  end

  test "rejects wrong media type and missing accept media types" do
    payload = Jason.encode!(%{"jsonrpc" => "2.0", "id" => 1, "method" => "ping"})

    assert request(payload, @token, [{"content-type", "application/json-invalid"}])
           |> response(415)

    assert request(payload, @token, [{"accept", "text/html"}]) |> response(406)
  end

  test "readiness and task lists advertise configured browser entry points" do
    data =
      rpc("tools/call", %{"name" => "genesis_list_tasks", "arguments" => %{}})["result"][
        "structuredContent"
      ]

    assert data["links"]["dashboard"] =~ "/tasks"
    assert data["links"]["access"] == "open_on_genesis_host"
    models = rpc("tools/call", %{"name" => "genesis_list_models"})["result"]
    refute models["isError"]
    assert is_list(models["structuredContent"]["models"])
  end

  test "configuration paths and reload failures are usable without the dashboard" do
    check = rpc("tools/call", %{"name" => "genesis_check"})["result"]["structuredContent"]
    assert check["config_files"]["config"] == EvoGit.Config.config_path()
    assert check["config_files"]["credentials"] == EvoGit.Config.credentials_path()
    File.write!(EvoGit.Config.config_path(), "invalid = [")
    reload = rpc("tools/call", %{"name" => "genesis_reload_config"})["result"]
    assert reload["isError"]
    assert reload["structuredContent"]["error"]["code"] == "configuration_not_applied"
  end

  defp rpc(method, params \\ %{}) do
    request(%{"jsonrpc" => "2.0", "id" => 7, "method" => method, "params" => params})
    |> json_response(200)
  end

  defp base_conn(token \\ @token) do
    %{build_conn() | host: "localhost"}
    |> put_req_header("content-type", "application/json")
    |> put_req_header("accept", "application/json, text/event-stream")
    |> put_req_header("authorization", "Bearer " <> token)
  end

  defp request(payload, token \\ @token, headers \\ []) do
    body = if is_binary(payload), do: payload, else: Jason.encode!(payload)

    Enum.reduce(headers, base_conn(token), fn {k, v}, conn -> put_req_header(conn, k, v) end)
    |> post("/mcp", body)
  end
end
