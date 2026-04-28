defmodule EvoGit.Agent.Tools.WebSearch do
  @moduledoc """
  Tool for web search using Tavily API.
  """

  alias EvoGit.Agent.Tools.Shared

  @doc """
  Returns the tool schema for ReqLLM.
  """
  def schema do
    ReqLLM.tool(
      name: "search_web",
      description:
        "Searches the web for information with Tavily. " <>
          "Returns structured search results including titles, URLs, and content summaries.",
      parameter_schema: %{
        "type" => "object",
        "properties" => %{
          "query" => %{
            "type" => "string",
            "description" => "The search query string"
          },
          "search_depth" => %{
            "type" => "string",
            "description" => "Search depth: 'basic' or 'advanced' (default: 'basic')",
            "default" => "basic"
          },
          "max_results" => %{
            "type" => "integer",
            "description" => "Maximum number of results to return (1-50, default 10)",
            "default" => 10
          }
        },
        "required" => ["query"]
      },
      callback: fn _ -> {:ok, nil} end
    )
  end

  @doc """
  Executes the search_web tool.
  """
  def execute(args, _repo_path, _repo_root) do
    with {:ok, query} <- Shared.fetch_string_arg(args, "query"),
         {:ok, search_depth} <- validate_search_depth(Map.get(args, "search_depth", "basic")),
         {:ok, max_results} <- validate_max_results(Map.get(args, "max_results", 10)) do
      do_web_search(query, search_depth, max_results)
    end
  end

  defp validate_search_depth(value) when value in ["basic", "advanced"], do: {:ok, value}

  defp validate_search_depth(value),
    do: {:error, "Argument 'search_depth' must be 'basic' or 'advanced', got: #{inspect(value)}"}

  defp validate_max_results(value) when is_integer(value) and value >= 1 and value <= 50,
    do: {:ok, value}

  defp validate_max_results(value),
    do: {:error, "Argument 'max_results' must be an integer between 1 and 50, got: #{inspect(value)}"}

  defp do_web_search(query, search_depth, max_results) do
    api_key = System.get_env("TAVILY_API_KEY")

    if is_nil(api_key) do
      "Error: TAVILY_API_KEY environment variable is not set"
    else
      url = "https://api.tavily.com/search"

      body = %{
        query: query,
        search_depth: search_depth,
        max_results: max_results
      }

      headers = %{
        "Content-Type" => "application/json",
        "Authorization" => "Bearer #{api_key}"
      }

      case Req.post(url, json: body, headers: headers, receive_timeout: 30_000) do
        {:ok, %{status: 200, body: response_body}} ->
          format_response(response_body)

        {:ok, %{status: status, body: response_body}} ->
          "Error: Web search failed with status #{status}. #{inspect(response_body)}"

        {:error, reason} ->
          "Error: Web search request failed: #{inspect(reason)}"
      end
    end
  end

  defp format_response(%{"results" => results}) when is_list(results) do
    formatted =
      Enum.map(results, fn result ->
        title = result["title"] || "Untitled"
        url = result["url"] || ""
        content = result["content"] || ""

        "## #{title}\n#{url}\n\n#{content}\n"
      end)
      |> Enum.join("\n---\n\n")

    "Found #{length(results)} results:\n\n#{formatted}"
  end

  defp format_response(response) do
    "Search response (unexpected format): #{inspect(response)}"
  end
end
