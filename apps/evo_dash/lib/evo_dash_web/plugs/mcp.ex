defmodule EvoDashWeb.Plugs.MCP do
  @moduledoc """
  Local Streamable HTTP MCP endpoint, mounted before the browser JSON parser
  so malformed MCP bodies receive JSON-RPC errors instead of HTML error pages.
  """
  @behaviour Plug
  import Plug.Conn
  alias EvoDash.MCP.{Auth, Server}

  def init(opts), do: opts

  def call(%{request_path: "/mcp"} = conn, _opts) do
    case Auth.authorize(conn) do
      :ok -> serve(conn)
      {:error, status, message} -> reply(conn, status, %{error: message})
    end
    |> halt()
  end

  def call(conn, _opts), do: conn

  defp serve(%{method: "POST"} = conn) do
    cond do
      not accepted?(conn) ->
        reply(conn, 406, %{error: "Accept must include application/json and text/event-stream."})

      not json?(conn) ->
        reply(conn, 415, %{error: "Content-Type must be application/json."})

      not version?(conn) ->
        reply(conn, 400, Server.error(nil, -32600, "Unsupported MCP-Protocol-Version"))

      true ->
        read_request(conn)
    end
  end

  defp serve(conn), do: conn |> put_resp_header("allow", "POST") |> send_resp(405, "")

  defp read_request(conn) do
    case read_body(conn, length: 1_048_576) do
      {:ok, body, conn} ->
        case Jason.decode(body) do
          {:ok, request} -> dispatch(conn, request)
          {:error, _} -> reply(conn, 400, Server.error(nil, -32700, "Parse error"))
        end

      {:more, _, conn} ->
        reply(conn, 413, %{error: "MCP request exceeds 1 MiB."})

      {:error, _} ->
        reply(conn, 400, Server.error(nil, -32700, "Could not read request"))
    end
  end

  defp dispatch(conn, request) do
    case Server.handle(request) do
      :accepted -> send_resp(conn, 202, "")
      %{error: %{code: -32600}} = response -> reply(conn, 400, response)
      response -> reply(conn, 200, response)
    end
  end

  defp accepted?(conn) do
    types =
      conn
      |> get_req_header("accept")
      |> Enum.flat_map(&String.split(&1, ","))
      |> Enum.map(&(String.split(&1, ";") |> hd() |> String.trim()))

    "application/json" in types and "text/event-stream" in types
  end

  defp json?(conn) do
    case get_req_header(conn, "content-type") do
      [value] -> value |> String.split(";") |> hd() |> String.trim() == "application/json"
      _ -> false
    end
  end

  defp version?(conn) do
    case get_req_header(conn, "mcp-protocol-version") do
      [] -> true
      [version] -> version in Server.versions()
      _ -> false
    end
  end

  defp reply(conn, status, body),
    do:
      conn |> put_resp_content_type("application/json") |> send_resp(status, Jason.encode!(body))
end
