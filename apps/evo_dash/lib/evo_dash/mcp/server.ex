defmodule EvoDash.MCP.Server do
  @moduledoc """
  Stateless MCP JSON-RPC tools endpoint. Tasks belong to TaskRegistry, not
  MCP connections. No sessions, SSE stream, or optional task extension is needed.
  """
  alias EvoDash.MCP.Tools
  @versions ["2025-11-25", "2025-06-18"]
  def versions, do: @versions

  def handle(%{"jsonrpc" => "2.0", "method" => method, "id" => id} = request)
      when is_binary(method) and (is_binary(id) or is_integer(id)) do
    params = Map.get(request, "params", %{})

    if is_map(params),
      do: dispatch(method, params, id),
      else: error(id, -32602, "params must be an object")
  end

  # Notifications must never dispatch tools or other side effects.
  def handle(%{"jsonrpc" => "2.0", "method" => method} = request) when is_binary(method) do
    if not Map.has_key?(request, "id") and String.starts_with?(method, "notifications/") do
      :accepted
    else
      error(nil, -32600, "Invalid Request")
    end
  end

  def handle(_), do: error(nil, -32600, "Invalid Request")

  defp dispatch(
         "initialize",
         %{"protocolVersion" => version, "capabilities" => capabilities, "clientInfo" => info},
         id
       )
       when is_binary(version) and is_map(capabilities) and is_map(info) do
    success(id, %{
      protocolVersion: if(version in @versions, do: version, else: hd(@versions)),
      capabilities: %{tools: %{}},
      serverInfo: %{name: "genesis", version: to_string(Application.spec(:evo_git, :vsn))},
      instructions:
        "Genesis is a background software-development engine with its own configured models and cooperating agents. You coordinate the user’s requirements, provide a self-contained objective (the conversation is not inherited), follow progress, and verify returned changes. Use genesis_check before work; for model setup use its config_files paths and genesis_reload_config after file edits or vendor login, without requiring the Genesis GUI; tasks outlive the calling session while this service runs. Save task IDs, offer optional browser links, report meaningful changes and inspect actual results. Existing Genesis Git behavior applies."
    })
  end

  defp dispatch("initialize", _, id),
    do: error(id, -32602, "initialize requires protocolVersion, capabilities and clientInfo")

  defp dispatch("ping", _, id), do: success(id, %{})
  defp dispatch("tools/list", _, id), do: success(id, %{tools: Tools.list()})

  defp dispatch("tools/call", %{"name" => name} = params, id) do
    case Tools.call(name, Map.get(params, "arguments", %{})) do
      {:ok, result} -> success(id, result)
      {:invalid, message} -> error(id, -32602, message)
    end
  end

  defp dispatch("tools/call", _, id), do: error(id, -32602, "Tool name is required")
  defp dispatch(_, _, id), do: error(id, -32601, "Method not found")

  def error(id, code, message),
    do: %{jsonrpc: "2.0", id: id, error: %{code: code, message: message}}

  defp success(id, result), do: %{jsonrpc: "2.0", id: id, result: result}
end
