defmodule EvoGit.Agent.Tools.WebSearch do
  @moduledoc """
  Tool for web search using a configurable search provider.

  ## Provider Architecture

  The search provider is selected from configuration via `EvoGit.Config.resolve()`:

      config = EvoGit.Config.resolve()
      provider = get_in(config, [:tools, :search, :provider])
      # => :tavily (default)

  Each provider has its own config section under `[:tools, :search, :<provider>]`
  with the following keys:

  - `:api_key_env_var` — the environment variable name for the API key
  - `:base_url` — the API endpoint URL
  - `:search_depth` — default search depth (`:basic` or `:advanced`)
  - `:max_results` — default max results (1-50)
  - `:timeout` — request timeout in milliseconds
  - `:max_bytes` — maximum output size in bytes

  ## Adding a New Provider

  To add a new search provider:
  1. Add the provider atom to the validation list in `EvoGit.Config.Schema`
     (`[:tools, :search, :provider]`)
  2. Add a new config section `[:tools, :search, :<provider>]` in the schema
     with at minimum `:api_key_env_var` and `:base_url`
  3. The provider will work automatically — this module reads all provider-
     specific settings from config at execution time
  """

  alias EvoGit.Agent.Tools.Shared

  @default_timeout 60_000
  @default_max_bytes 16_384

  @doc """
  Returns the tool schema for ReqLLM.

  Delegates to `schema/1` with empty opts.
  """
  def schema do
    schema([])
  end

  @doc """
  Returns the tool schema for ReqLLM, accepting optional configuration.

  The `_opts` parameter is reserved for future use (e.g., overriding
  defaults per-agent). Currently ignored.
  """
  def schema(_opts) do
    config = EvoGit.Config.resolve()
    provider = get_in(config, [:tools, :search, :provider]) || :tavily
    provider_config = get_in(config, [:tools, :search, provider]) || %{}

    search_depth =
      provider_config
      |> Map.get(:search_depth)
      |> stringify_default("basic")

    max_results =
      provider_config
      |> Map.get(:max_results)
      |> Kernel.||(10)

    timeout =
      provider_config
      |> Map.get(:timeout)
      |> Kernel.||(@default_timeout)

    max_bytes =
      provider_config
      |> Map.get(:max_bytes)
      |> Kernel.||(@default_max_bytes)

    ReqLLM.tool(
      name: "search_web",
      description:
        "Searches the web for information with the configured search provider. " <>
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
            "description" => "Search depth: 'basic' or 'advanced' (default: '#{search_depth}')",
            "default" => search_depth
          },
          "max_results" => %{
            "type" => "integer",
            "description" => "Maximum number of results to return (1-50, default #{max_results})",
            "default" => max_results
          },
          "timeout" => %{
            "type" => "integer",
            "description" =>
              "Timeout in milliseconds for this tool execution. Default: #{timeout}",
            "default" => timeout
          },
          "max_bytes" => %{
            "type" => "integer",
            "description" =>
              "Maximum output size in bytes before truncation. " <>
                "Default: #{max_bytes} (#{div(max_bytes, 1024)}KB). Increase up to 131072 (128KB) if you need more output.",
            "default" => max_bytes
          }
        },
        "required" => ["query"]
      },
      callback: fn _ -> {:ok, nil} end
    )
  end

  @doc """
  Executes the search_web tool.

  Reads the provider configuration from `EvoGit.Config.resolve()` at
  execution time, builds a provider config map, and delegates to
  `do_web_search/4`.
  """
  def execute(args, _repo_path, _repo_root) do
    with {:ok, query} <- Shared.fetch_string_arg(args, "query"),
         {:ok, search_depth} <- validate_search_depth(Map.get(args, "search_depth", "basic")),
         {:ok, max_results} <- validate_max_results(Map.get(args, "max_results", 10)) do
      config = EvoGit.Config.resolve()
      provider = get_in(config, [:tools, :search, :provider]) || :tavily
      provider_config = get_in(config, [:tools, :search, provider]) || %{}

      api_key_env_var = provider_config[:api_key_env_var]
      api_key =
        if api_key_env_var do
          case EvoGit.Config.env_var_to_reqllm_key(api_key_env_var) do
            nil -> System.get_env(api_key_env_var)
            atom_key ->
              case ReqLLM.get_key(atom_key) do
                nil -> System.get_env(api_key_env_var)
                key -> key
              end
          end
        else
          nil
        end

      base_url = provider_config[:base_url]
      timeout = args["timeout"] || provider_config[:timeout] || @default_timeout
      max_bytes = args["max_bytes"] || provider_config[:max_bytes] || @default_max_bytes

      provider_map = %{
        api_key: api_key,
        api_key_env_var: api_key_env_var,
        base_url: base_url,
        timeout: timeout,
        max_bytes: max_bytes
      }

      do_web_search(query, search_depth, max_results, provider_map)
    end
  end

  defp validate_search_depth(value) when value in ["basic", "advanced"], do: {:ok, value}

  defp validate_search_depth(value),
    do: {:error, "Argument 'search_depth' must be 'basic' or 'advanced', got: #{inspect(value)}"}

  defp validate_max_results(value) when is_integer(value) and value >= 1 and value <= 50,
    do: {:ok, value}

  defp validate_max_results(value),
    do: {:error, "Argument 'max_results' must be an integer between 1 and 50, got: #{inspect(value)}"}

  defp do_web_search(query, search_depth, max_results, provider_config) do
    api_key = provider_config.api_key

    if is_nil(api_key) or api_key == "" do
      "Error: API key for search provider is not set"
    else
      url = provider_config.base_url || "https://api.tavily.com/search"
      receive_timeout = provider_config.timeout || 30_000

      body = %{
        query: query,
        search_depth: search_depth,
        max_results: max_results
      }

      headers = %{
        "Content-Type" => "application/json",
        "Authorization" => "Bearer #{api_key}"
      }

      case Req.post(url, json: body, headers: headers, receive_timeout: receive_timeout) do
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

  # Converts an atom or string value to a string for use in the LLM schema.
  # If the value is nil, returns the provided default string.
  defp stringify_default(nil, default), do: default
  defp stringify_default(val, _default) when is_atom(val), do: Atom.to_string(val)
  defp stringify_default(val, _default), do: val
end
