defmodule EvoDash.MCP.Links do
  @moduledoc "Browser entry points based on the configured endpoint, never request headers."

  def enrich(data) do
    base = String.trim_trailing(EvoDashWeb.Endpoint.url(), "/")
    host = URI.parse(base).host

    links = %{
      dashboard: base <> "/tasks",
      agents: base <> "/agents",
      access:
        if(host in ["localhost", "127.0.0.1", "::1"],
          do: "open_on_genesis_host",
          else: "configured_address"
        )
    }

    links =
      case Map.get(data, :id) || Map.get(data, :task_id) do
        id when is_binary(id) ->
          Map.put(links, :task, base <> "/review/" <> URI.encode(id, &URI.char_unreserved?/1))

        _ ->
          links
      end

    data = Map.put(data, :links, links)

    if is_list(Map.get(data, :tasks)),
      do: Map.update!(data, :tasks, &Enum.map(&1, fn task -> enrich(task) end)),
      else: data
  end
end
