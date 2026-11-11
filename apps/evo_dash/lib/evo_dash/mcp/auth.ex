defmodule EvoDash.MCP.Auth do
  @moduledoc "Local MCP credential and request checks; does not trust proxy headers."
  import Plug.Conn

  def authorize(conn) do
    cond do
      not loopback?(conn.remote_ip) ->
        {:error, 403, "MCP is available on the local host only."}

      conn.host not in ["localhost", "127.0.0.1", "::1", "[::1]"] ->
        {:error, 403, "Invalid MCP host."}

      not valid_origin?(conn) ->
        {:error, 403, "Invalid Origin."}

      true ->
        verify_token(conn)
    end
  end

  defp verify_token(conn) do
    with {:ok, raw} <- File.read(Path.join(EvoGit.Config.config_dir(), "mcp-token")),
         token = String.trim(raw),
         true <- byte_size(token) >= 32 and not String.match?(token, ~r/\s/) do
      case get_req_header(conn, "authorization") do
        [supplied] ->
          if Plug.Crypto.secure_compare(supplied, "Bearer " <> token),
            do: :ok,
            else: {:error, 401, "Invalid MCP token."}

        _ ->
          {:error, 401, "MCP token required."}
      end
    else
      _ ->
        {:error, 503,
         "MCP is not configured. Create mcp-token in the Genesis configuration directory."}
    end
  end

  defp valid_origin?(conn) do
    case get_req_header(conn, "origin") do
      [] ->
        true

      [origin] ->
        uri = URI.parse(origin)

        uri.scheme == Atom.to_string(conn.scheme) and uri.host == conn.host and
          uri.port == conn.port and
          is_nil(uri.userinfo) and uri.path in [nil, ""] and is_nil(uri.query) and
          is_nil(uri.fragment)

      _ ->
        false
    end
  end

  defp loopback?({127, _, _, _}), do: true
  defp loopback?({0, 0, 0, 0, 0, 0, 0, 1}), do: true
  defp loopback?(_), do: false
end
