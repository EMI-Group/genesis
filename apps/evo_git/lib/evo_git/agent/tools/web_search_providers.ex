defmodule EvoGit.Agent.Tools.WebSearchProviders do
  @moduledoc """
  Pure, I/O-free per-provider request builders and response parsers for the
  `search_web` tool (`EvoGit.Agent.Tools.WebSearch`).

  This module deliberately contains NO HTTP, NO configuration resolution, and
  NO state — every function is a pure function of its arguments, so each
  provider path is fully unit-testable with hardcoded config maps.

  ## Supported Providers

  The system-wide single source of truth for the provider list is the config
  schema (`EvoGit.Config.Schema.search_providers/0`). This module implements
  adapters for the five current providers:

    * `:tavily` — POST JSON (`query`/`search_depth`/`max_results`);
      `Authorization: Bearer <key>`; parses `results[]` (`title`/`url`/`content`).
      Honors both `search_depth` and `max_results`.
    * `:perplexity` — POST JSON chat-completions (`model` from config, default
      `"sonar"`, plus a single user message); `Authorization: Bearer <key>`;
      parses the LLM markdown answer from `choices[0].message.content` plus the
      top-level `citations[]` URLs. `search_depth`/`max_results` are not
      applicable and are ignored.
    * `:exa` — POST JSON (`query`/`numResults`, plus `type`: `"neural"` for
      `"advanced"` depth, `"keyword"` otherwise); `x-api-key: <key>`;
      parses `results[]` (`title`/`url`/`text`). Honors both `search_depth`
      and `max_results`.
    * `:bing` — GET with `q`/`count` query params; `Ocp-Apim-Subscription-Key`;
      parses `webPages.value[]` (`name`/`url`/`snippet`). Honors `max_results`;
      `search_depth` is not applicable.
    * `:brave` — GET with `q`/`count` query params; `X-Subscription-Token`;
      parses `web.results[]` (`title`/`url`/`description`). Honors `max_results`;
      `search_depth` is not applicable.

  Unknown or nil provider atoms normalize to `:tavily` (`normalize_provider/1`).

  ## API

    * `build_request/5` — `{:ok, %{method: :post | :get, url: String.t(), headers: map(), body: map() | nil}}`
    * `parse_response/2` — `{:ok, %{kind: :results, entries: [%{title:, url:, content:}]}}`
      (list providers) or `{:ok, %{kind: :answer, text: String.t(), citations: [String.t()]}}`
      (Perplexity) or `{:error, :unexpected_format}`.
  """

  @providers [:tavily, :perplexity, :exa, :bing, :brave]

  @doc """
  Returns the list of supported provider atoms.
  """
  def providers, do: @providers

  @doc """
  Normalizes a provider atom to a known provider, falling back to `:tavily`
  for unknown or nil values.
  """
  def normalize_provider(provider) when provider in @providers, do: provider
  def normalize_provider(_provider), do: :tavily

  @doc """
  Builds the HTTP request spec for `provider`.

  `provider_config` is a map with at least `:api_key` and `:base_url` (plus
  provider-specific keys such as Perplexity's `:model`).

  Returns `{:ok, %{method: :post | :get, url: String.t(), headers: map(), body: map() | nil}}`.
  """
  def build_request(provider, provider_config, query, search_depth, max_results) do
    case normalize_provider(provider) do
      :tavily -> build_tavily(provider_config, query, search_depth, max_results)
      :perplexity -> build_perplexity(provider_config, query)
      :exa -> build_exa(provider_config, query, search_depth, max_results)
      :bing -> build_bing(provider_config, query, max_results)
      :brave -> build_brave(provider_config, query, max_results)
    end
  end

  @doc """
  Parses a decoded provider response body into a unified shape:

    * `{:ok, %{kind: :results, entries: [%{title:, url:, content:}]}}` — list
      providers (Tavily, Exa, Bing, Brave); `title`/`url`/`content` may be nil
      for missing keys (the formatter applies defaults).
    * `{:ok, %{kind: :answer, text:, citations:}}` — Perplexity's LLM markdown
      answer plus citation URLs.
    * `{:error, :unexpected_format}` — body does not match the provider shape.
  """
  def parse_response(provider, response_body) do
    case normalize_provider(provider) do
      :tavily -> parse_results(response_body, "content")
      :exa -> parse_results(response_body, "text")
      :bing -> parse_bing(response_body)
      :brave -> parse_brave(response_body)
      :perplexity -> parse_perplexity(response_body)
    end
  end

  # ── Request builders ────────────────────────────────────────────────────

  defp build_tavily(provider_config, query, search_depth, max_results) do
    {:ok,
     %{
       method: :post,
       url: provider_config[:base_url],
       headers: %{
         "Content-Type" => "application/json",
         "Authorization" => "Bearer #{provider_config[:api_key]}"
       },
       body: %{query: query, search_depth: search_depth, max_results: max_results}
     }}
  end

  defp build_perplexity(provider_config, query) do
    model = provider_config[:model] || "sonar"

    {:ok,
     %{
       method: :post,
       url: provider_config[:base_url],
       headers: %{
         "Content-Type" => "application/json",
         "Authorization" => "Bearer #{provider_config[:api_key]}"
       },
       body: %{model: model, messages: [%{role: "user", content: query}]}
     }}
  end

  defp build_exa(provider_config, query, search_depth, max_results) do
    type = if search_depth == "advanced", do: "neural", else: "keyword"

    {:ok,
     %{
       method: :post,
       url: provider_config[:base_url],
       headers: %{
         "Content-Type" => "application/json",
         "x-api-key" => provider_config[:api_key]
       },
       body: %{query: query, numResults: max_results, type: type}
     }}
  end

  defp build_bing(provider_config, query, max_results) do
    {:ok,
     %{
       method: :get,
       url: get_url(provider_config[:base_url], %{"q" => query, "count" => max_results}),
       headers: %{"Ocp-Apim-Subscription-Key" => provider_config[:api_key]},
       body: nil
     }}
  end

  defp build_brave(provider_config, query, max_results) do
    {:ok,
     %{
       method: :get,
       url: get_url(provider_config[:base_url], %{"q" => query, "count" => max_results}),
       headers: %{"X-Subscription-Token" => provider_config[:api_key]},
       body: nil
     }}
  end

  defp get_url(base_url, params) do
    query_string =
      params
      |> Enum.map_join("&", fn {key, value} ->
        "#{URI.encode_www_form(key)}=#{URI.encode_www_form(to_string(value))}"
      end)

    separator = if String.contains?(base_url || "", "?"), do: "&", else: "?"
    "#{base_url}#{separator}#{query_string}"
  end

  # ── Response parsers ────────────────────────────────────────────────────

  # Shared by Tavily (`results[]` with `content`) and Exa (`results[]` with `text`).
  defp parse_results(%{"results" => results}, content_key) when is_list(results) do
    entries =
      Enum.map(results, fn result ->
        %{
          title: result["title"],
          url: result["url"],
          content: result[content_key]
        }
      end)

    {:ok, %{kind: :results, entries: entries}}
  end

  defp parse_results(_response_body, _content_key), do: {:error, :unexpected_format}

  defp parse_bing(%{"webPages" => %{"value" => results}}) when is_list(results) do
    entries =
      Enum.map(results, fn result ->
        %{title: result["name"], url: result["url"], content: result["snippet"]}
      end)

    {:ok, %{kind: :results, entries: entries}}
  end

  defp parse_bing(_response_body), do: {:error, :unexpected_format}

  defp parse_brave(%{"web" => %{"results" => results}}) when is_list(results) do
    entries =
      Enum.map(results, fn result ->
        %{title: result["title"], url: result["url"], content: result["description"]}
      end)

    {:ok, %{kind: :results, entries: entries}}
  end

  defp parse_brave(_response_body), do: {:error, :unexpected_format}

  defp parse_perplexity(response_body) do
    case response_body do
      %{"choices" => [%{"message" => %{"content" => content}} | _]} when is_binary(content) ->
        citations =
          case Map.get(response_body, "citations") do
            list when is_list(list) -> Enum.filter(list, &is_binary/1)
            _ -> []
          end

        {:ok, %{kind: :answer, text: content, citations: citations}}

      _ ->
        {:error, :unexpected_format}
    end
  end
end
