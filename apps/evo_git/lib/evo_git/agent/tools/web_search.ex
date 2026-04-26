defmodule EvoGit.Agent.Tools.WebSearch do
  @moduledoc """
  Tool for web search using Z.AI (zhipu.ai/chat.z.ai) API.
  Note: This is NOT Google Search. Z.AI is a Chinese AI service provider.
  """

  alias EvoGit.Agent.Tools.Shared

  @doc """
  Returns the tool schema for ReqLLM.
  """
  def schema do
    ReqLLM.tool(
      name: "web_search",
      description:
        "Searches the web for information. " <>
          "Returns structured search results including titles, URLs, summaries, site names, and publication dates.",
      parameter_schema: %{
        "type" => "object",
        "properties" => %{
          "search_query" => %{
            "type" => "string",
            "description" => "The search query string"
          },
          "count" => %{
            "type" => "integer",
            "description" => "Number of results to return (1-50, default 10)",
            "default" => 10
          },
          "search_domain_filter" => %{
            "type" => "string",
            "description" =>
              "Optional domain filter (e.g., 'www.example.com') to only search within a specific domain"
          },
          "search_recency_filter" => %{
            "type" => "string",
            "description" =>
              "Time filter for search results (e.g., 'noLimit', '1d', '1w', '1m', '1y')",
            "default" => "noLimit"
          }
        },
        "required" => ["search_query"]
      },
      callback: fn _ -> {:ok, nil} end
    )
  end

  @doc """
  Executes the web_search tool.
  """
  def execute(args, _repo_path, _repo_root) do
    with {:ok, search_query} <- Shared.fetch_string_arg(args, "search_query"),
         {:ok, count} <- validate_count(Map.get(args, "count", 10)),
         {:ok, search_recency_filter} <-
           Shared.fetch_optional_string_arg(args, "search_recency_filter", "noLimit"),
         search_domain_filter = Map.get(args, "search_domain_filter") do
      do_web_search(search_query, count, search_domain_filter, search_recency_filter)
    end
  end

  defp validate_count(value) when is_integer(value) and value >= 1 and value <= 50,
    do: {:ok, value}

  defp validate_count(value),
    do: {:error, "Argument 'count' must be an integer between 1 and 50, got: #{inspect(value)}"}

  defp do_web_search(search_query, count, search_domain_filter, search_recency_filter) do
    api_key = System.get_env("ZAI_API_KEY")

    if is_nil(api_key) do
      "Error: ZAI_API_KEY environment variable is not set"
    else
      url = "https://api.z.ai/api/paas/v4/web-search"

      body =
        %{
          search_query: search_query,
          count: count,
          search_recency_filter: search_recency_filter
        }
        |> then(fn base ->
          if search_domain_filter do
            Map.put(base, :search_domain_filter, search_domain_filter)
          else
            base
          end
        end)

      case Req.post(url,
             json: body,
             auth: {:bearer, api_key},
             receive_timeout: 30_000
           ) do
        {:ok, %{status: 200, body: response_body}} ->
          format_response(response_body)

        {:ok, %{status: status, body: response_body}} ->
          "Error: Web search failed with status #{status}. #{inspect(response_body)}"

        {:error, reason} ->
          "Error: Web search request failed: #{inspect(reason)}"
      end
    end
  end

  defp format_response(%{"search_result" => results}) when is_list(results) do
    formatted =
      Enum.map(results, fn result ->
        title = result["title"] || "Untitled"
        link = result["link"] || ""
        content = result["content"] || ""
        media = result["media"] || ""
        publish_date = result["publish_date"] || ""

        date_str = if publish_date != "", do: " (#{publish_date})", else: ""
        media_str = if media != "", do: " - #{media}", else: ""

        "## #{title}#{date_str}#{media_str}\n#{link}\n\n#{content}\n"
      end)
      |> Enum.join("\n---\n\n")

    "Found #{length(results)} results:\n\n#{formatted}"
  end

  defp format_response(response) do
    "Search response (unexpected format): #{inspect(response)}"
  end
end
