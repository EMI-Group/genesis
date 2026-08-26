defmodule EvoGit.Agent.Tools.WebSearch do
  @moduledoc """
  Tool for web search using a configurable search provider.

  ## Supported Providers

  Five providers are supported, selected from configuration via
  `EvoGit.Config.resolve()`:

    * `:tavily` — POST JSON to the Tavily search API; parses `results[]`
      (`title`/`url`/`content`). Honors both `search_depth` and `max_results`.
    * `:perplexity` — POST JSON (model + user message) to the Perplexity
      (Sonar) chat-completions API; returns an LLM markdown answer plus
      `citations[]` URLs. `search_depth`/`max_results` are not applicable and
      are ignored.
    * `:exa` — POST JSON (`query`/`numResults`, plus a `type` derived from
      `search_depth`) to the Exa search API; parses `results[]`
      (`title`/`url`/`text`). Honors both `search_depth` and `max_results`.
    * `:bing` — GET with `q`/`count` query params to the Bing Web Search API;
      parses `webPages.value[]` (`name`/`url`/`snippet`). Honors `max_results`;
      `search_depth` is not applicable.
    * `:brave` — GET with `q`/`count` query params to the Brave Search API;
      parses `web.results[]` (`title`/`url`/`description`). Honors `max_results`;
      `search_depth` is not applicable.

  The provider list's single source of truth lives in the config schema
  (`EvoGit.Config.Schema.search_providers/0`); this module reads the provider
  atom generically via `EvoGit.Config.resolve()` (exactly as today) and
  normalizes unknown/nil values to `:tavily`.

  ## Provider Architecture

  The provider atom and its config section are read from `EvoGit.Config.resolve()`:

      config = EvoGit.Config.resolve()
      provider = get_in(config, [:tools, :search, :provider])
      # => :tavily (default)

  Each provider has its own config section under `[:tools, :search, :<provider>]`
  with the following keys:

    * `:api_key_credential_key` — the configuration key name for the API key (used with ReqLLM's key store)
    * `:base_url` — the API endpoint URL
    * `:search_depth` — default search depth (`:basic` or `:advanced`)
    * `:max_results` — default max results (1-50)
    * `:timeout` — request timeout in milliseconds
    * `:max_bytes` — maximum output size in bytes

  Per-provider request building and response parsing are pure functions in the
  sibling module `EvoGit.Agent.Tools.WebSearchProviders`; this module handles
  argument validation, API-key resolution, and the actual HTTP call.

  ## Test Seam

  The HTTP call is routed through the `:web_search_http_runner` app-env seam
  (read at call time): `Application.get_env(:evo_git, :web_search_http_runner)`
  defaults to a private Req-based runner taking `(request_spec, receive_timeout)`
  and returning the Req result tuple. Tests override it with a stub function to
  exercise `execute/3` (and `do_web_search/4`) without the network. The
  `@doc false` `do_web_search/4` entry point additionally lets tests drive the
  HTTP/parsing tail directly with a hardcoded provider map (bypassing
  `EvoGit.Config.resolve()`).

  ## Adding a New Provider

  To add a new search provider:
  1. Add the provider atom to `EvoGit.Config.Schema.Definitions.search_providers/0`
     and the `[:tools, :search, :provider]` validation list
  2. Add a config section `[:tools, :search, :<provider>]` in the schema
     with at minimum `:api_key_credential_key` and `:base_url`
  3. Add a request-builder + response-parser clause in
     `EvoGit.Agent.Tools.WebSearchProviders`
  """

  alias EvoGit.Agent.Tools.Shared
  alias EvoGit.Agent.Tools.WebSearchProviders

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

    provider =
      config
      |> get_in([:tools, :search, :provider])
      |> WebSearchProviders.normalize_provider()

    provider_config = get_in(config, [:tools, :search, provider])

    search_depth =
      provider_config
      |> Map.get(:search_depth)
      |> stringify_default("basic")

    max_results =
      provider_config
      |> Map.get(:max_results)

    timeout =
      provider_config
      |> Map.get(:timeout)

    max_bytes =
      provider_config
      |> Map.get(:max_bytes)

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

      provider =
        config
        |> get_in([:tools, :search, :provider])
        |> WebSearchProviders.normalize_provider()

      provider_config = get_in(config, [:tools, :search, provider])

      api_key_credential_key = provider_config[:api_key_credential_key]

      api_key =
        if api_key_credential_key do
          case EvoGit.Config.credential_key_to_reqllm_key(api_key_credential_key) do
            nil -> nil
            atom_key -> ReqLLM.get_key(atom_key)
          end
        else
          nil
        end

      base_url = provider_config[:base_url]
      timeout = args["timeout"] || provider_config[:timeout]
      max_bytes = args["max_bytes"] || provider_config[:max_bytes]

      provider_map = %{
        api_key: api_key,
        api_key_credential_key: api_key_credential_key,
        base_url: base_url,
        timeout: timeout,
        max_bytes: max_bytes,
        provider: provider
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
    do:
      {:error,
       "Argument 'max_results' must be an integer between 1 and 50, got: #{inspect(value)}"}

  @doc false
  # HTTP/parsing tail of the tool, provider-dispatched.
  #
  # Public (`@doc false`) solely as a test seam: it lets tests drive the full
  # request-build → HTTP (via the `:web_search_http_runner` app-env seam) →
  # parse → format pipeline with a hardcoded provider map, bypassing
  # `EvoGit.Config.resolve()`. `execute/3` is the only production caller.
  def do_web_search(query, search_depth, max_results, provider_config) do
    api_key = provider_config.api_key

    if is_nil(api_key) or api_key == "" do
      "Error: API key for search provider is not set"
    else
      provider = provider_config.provider
      receive_timeout = provider_config.timeout || 30_000

      # `build_request/5` is total for every normalized provider (all five
      # adapters return `{:ok, _}`), so the match cannot fail.
      {:ok, request} =
        WebSearchProviders.build_request(
          provider,
          provider_config,
          query,
          search_depth,
          max_results
        )

      case run_http(request, receive_timeout) do
        {:ok, %{status: 200, body: response_body}} ->
          format_provider_response(provider, response_body)

        {:ok, %{status: status, body: response_body}} ->
          "Error: Web search failed with status #{status}. #{inspect(response_body)}"

        {:error, reason} ->
          "Error: Web search request failed: #{inspect(reason)}"
      end
    end
  end

  # Runs an HTTP request spec produced by `WebSearchProviders.build_request/5`.
  #
  # Routed through the `:web_search_http_runner` app-env test seam (read at
  # call time; default = the private Req-based runner below) so execute-level
  # tests can stub the network with a hardcoded response tuple. Default
  # behavior is unchanged.
  defp run_http(request, receive_timeout) do
    runner = Application.get_env(:evo_git, :web_search_http_runner, &http_request/2)
    runner.(request, receive_timeout)
  end

  defp http_request(%{method: :post} = request, receive_timeout) do
    Req.post(request.url,
      json: request.body,
      headers: request.headers,
      receive_timeout: receive_timeout
    )
  end

  defp http_request(%{method: :get} = request, receive_timeout) do
    Req.get(request.url, headers: request.headers, receive_timeout: receive_timeout)
  end

  defp format_provider_response(provider, response_body) do
    case WebSearchProviders.parse_response(provider, response_body) do
      {:ok, %{kind: :results, entries: entries}} ->
        format_results(entries)

      {:ok, %{kind: :answer} = answer} ->
        format_answer(answer)

      {:error, _reason} ->
        "Search response (unexpected format): #{inspect(response_body)}"
    end
  end

  defp format_results(entries) do
    formatted =
      Enum.map(entries, fn entry ->
        title = entry.title || "Untitled"
        url = entry.url || ""
        content = entry.content || ""

        "## #{title}\n#{url}\n\n#{content}\n"
      end)
      |> Enum.join("\n---\n\n")

    "Found #{length(entries)} results:\n\n#{formatted}"
  end

  defp format_answer(%{text: text, citations: citations}) do
    citations_section =
      case citations do
        [] -> ""
        urls -> "\n\n## Citations\n\n" <> Enum.map_join(urls, "\n", &"- #{&1}")
      end

    "Answer:\n\n#{text}#{citations_section}"
  end

  # Converts an atom or string value to a string for use in the LLM schema.
  # If the value is nil, returns the provided default string.
  defp stringify_default(nil, default), do: default
  defp stringify_default(val, _default) when is_atom(val), do: Atom.to_string(val)
  defp stringify_default(val, _default), do: val
end
