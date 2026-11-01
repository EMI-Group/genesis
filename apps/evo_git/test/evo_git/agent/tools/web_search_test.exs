defmodule EvoGit.Agent.Tools.WebSearchTest do
  @moduledoc """
  `async: false` — the execute-level tests mutate BEAM-global app env observable
  by production code: the `:web_search_http_runner` seam and the shared
  `:req_llm` API-key store (`ReqLLM.put_key/2` on `:tavily_api_key`).
  """

  use ExUnit.Case, async: false

  alias EvoGit.Agent.Tools.WebSearch
  alias EvoGit.Agent.Tools.WebSearchProviders, as: Providers
  alias EvoGit.TestSupport.ConfigDir

  # Drives the timeout ceiling through a MODULE-PROCESS-local config directory
  # (`:config_dir_fun` seam), so an assertion pins the CONFIGURED maximum and
  # never the developer's real `~/.config/genesis/config.toml`.
  defp isolate_max_timeout!(max_ms) do
    ConfigDir.isolate!("evogit-web-search-timeout")
    :ok = EvoGit.Config.save_user_config(%{scheduler: %{max_tool_timeout: max_ms}})
  end

  # Runner stub that reports the `receive_timeout` it was handed. Req's
  # `receive_timeout` must never be a non-integer, so the value is asserted at
  # this seam rather than only at the tool's own boundary.
  defp timeout_capturing_runner(body) do
    fn _request, receive_timeout ->
      send(self(), {:receive_timeout, receive_timeout})
      {:ok, %{status: 200, body: body}}
    end
  end

  # ── Hardcoded config maps (no EvoGit.Config.resolve()/schema reliance) ──

  @tavily %{api_key: "tavily-key", base_url: "https://api.tavily.com/search"}
  @perplexity %{
    api_key: "perplexity-key",
    base_url: "https://api.perplexity.ai/chat/completions",
    model: "sonar"
  }
  @exa %{api_key: "exa-key", base_url: "https://api.exa.ai/search"}
  @bing %{api_key: "bing-key", base_url: "https://api.bing.microsoft.com/v7.0/search"}
  @brave %{api_key: "brave-key", base_url: "https://api.search.brave.com/res/v1/web/search"}

  setup do
    on_exit(fn -> Application.delete_env(:evo_git, :web_search_http_runner) end)
    :ok
  end

  describe "providers/0" do
    test "lists all five supported providers" do
      assert Providers.providers() == [:tavily, :perplexity, :exa, :bing, :brave]
    end
  end

  describe "normalize_provider/1" do
    test "passes known providers through" do
      for provider <- Providers.providers() do
        assert Providers.normalize_provider(provider) == provider
      end
    end

    test "falls back to :tavily for nil/unknown/string values" do
      assert Providers.normalize_provider(nil) == :tavily
      assert Providers.normalize_provider(:unknown_provider) == :tavily
      assert Providers.normalize_provider("tavily") == :tavily
    end
  end

  describe "build_request/5" do
    test "tavily: POST JSON with search_depth/max_results and Bearer auth" do
      assert {:ok, request} =
               Providers.build_request(:tavily, @tavily, "hello world", "advanced", 7)

      assert request.method == :post
      assert request.url == "https://api.tavily.com/search"

      assert request.headers == %{
               "Content-Type" => "application/json",
               "Authorization" => "Bearer tavily-key"
             }

      assert request.body == %{query: "hello world", search_depth: "advanced", max_results: 7}
    end

    test "perplexity: POST chat-completions, model defaults to sonar" do
      config = Map.delete(@perplexity, :model)

      assert {:ok, request} =
               Providers.build_request(:perplexity, config, "what is elixir?", "basic", 10)

      assert request.method == :post
      assert request.url == "https://api.perplexity.ai/chat/completions"
      assert request.headers["Authorization"] == "Bearer perplexity-key"

      assert request.body == %{
               model: "sonar",
               messages: [%{role: "user", content: "what is elixir?"}]
             }
    end

    test "perplexity: config model is honored; search_depth/max_results ignored" do
      assert {:ok, request} =
               Providers.build_request(:perplexity, @perplexity, "q", "advanced", 50)

      assert request.body == %{model: "sonar", messages: [%{role: "user", content: "q"}]}
    end

    test "exa: POST JSON with numResults and type derived from search_depth" do
      assert {:ok, request} = Providers.build_request(:exa, @exa, "exa query", "basic", 5)

      assert request.method == :post
      assert request.url == "https://api.exa.ai/search"
      assert request.headers == %{"Content-Type" => "application/json", "x-api-key" => "exa-key"}
      assert request.body == %{query: "exa query", numResults: 5, type: "keyword"}

      assert {:ok, %{body: %{type: "neural"}}} =
               Providers.build_request(:exa, @exa, "exa query", "advanced", 5)
    end

    test "bing: GET with q/count query params and Ocp-Apim-Subscription-Key header" do
      assert {:ok, request} = Providers.build_request(:bing, @bing, "bing query", "basic", 3)

      assert request.method == :get
      assert request.body == nil
      assert request.headers == %{"Ocp-Apim-Subscription-Key" => "bing-key"}
      assert request.url =~ "https://api.bing.microsoft.com/v7.0/search?"
      assert request.url =~ "q=bing+query"
      assert request.url =~ "count=3"
    end

    test "brave: GET with q/count query params and X-Subscription-Token header" do
      assert {:ok, request} = Providers.build_request(:brave, @brave, "brave query", "basic", 4)

      assert request.method == :get
      assert request.body == nil
      assert request.headers == %{"X-Subscription-Token" => "brave-key"}
      assert request.url =~ "https://api.search.brave.com/res/v1/web/search?"
      assert request.url =~ "q=brave+query"
      assert request.url =~ "count=4"
    end

    test "unknown provider normalizes to tavily" do
      assert {:ok, %{method: :post, url: "https://api.tavily.com/search"}} =
               Providers.build_request(:bogus, @tavily, "q", "basic", 5)
    end
  end

  describe "parse_response/2" do
    test "tavily: parses results[] with title/url/content" do
      body =
        Jason.decode!(
          ~s({"results":[{"title":"T1","url":"http://t1","content":"c1"},{"title":"T2","url":"http://t2"}]})
        )

      assert {:ok, %{kind: :results, entries: entries}} = Providers.parse_response(:tavily, body)

      assert entries == [
               %{title: "T1", url: "http://t1", content: "c1"},
               %{title: "T2", url: "http://t2", content: nil}
             ]
    end

    test "exa: parses results[] with title/url/text" do
      body = Jason.decode!(~s({"results":[{"title":"E1","url":"http://e1","text":"txt"}]}))

      assert {:ok, %{kind: :results, entries: [%{title: "E1", url: "http://e1", content: "txt"}]}} =
               Providers.parse_response(:exa, body)
    end

    test "bing: parses webPages.value[] with name/url/snippet" do
      body =
        Jason.decode!(
          ~s({"webPages":{"value":[{"name":"B1","url":"http://b1","snippet":"snip"}]}})
        )

      assert {:ok,
              %{kind: :results, entries: [%{title: "B1", url: "http://b1", content: "snip"}]}} =
               Providers.parse_response(:bing, body)
    end

    test "brave: parses web.results[] with title/url/description" do
      body =
        Jason.decode!(
          ~s({"web":{"results":[{"title":"Br1","url":"http://br1","description":"desc"}]}})
        )

      assert {:ok,
              %{kind: :results, entries: [%{title: "Br1", url: "http://br1", content: "desc"}]}} =
               Providers.parse_response(:brave, body)
    end

    test "perplexity: parses markdown answer plus citations" do
      body =
        Jason.decode!(
          ~s({"choices":[{"message":{"content":"**markdown** answer"}}],"citations":["https://c1","https://c2"]})
        )

      assert {:ok,
              %{
                kind: :answer,
                text: "**markdown** answer",
                citations: ["https://c1", "https://c2"]
              }} = Providers.parse_response(:perplexity, body)
    end

    test "perplexity: missing citations -> empty list" do
      body = Jason.decode!(~s({"choices":[{"message":{"content":"answer"}}]}))

      assert {:ok, %{kind: :answer, text: "answer", citations: []}} =
               Providers.parse_response(:perplexity, body)
    end

    test "perplexity: non-list citations -> empty list (no crash)" do
      assert Providers.parse_response(:perplexity, %{
               "choices" => [%{"message" => %{"content" => "a"}}],
               "citations" => "not-a-list"
             }) == {:ok, %{kind: :answer, text: "a", citations: []}}
    end

    test "unexpected formats return {:error, :unexpected_format}" do
      assert Providers.parse_response(:tavily, %{}) == {:error, :unexpected_format}

      assert Providers.parse_response(:tavily, %{"results" => "not-a-list"}) ==
               {:error, :unexpected_format}

      assert Providers.parse_response(:exa, %{"results" => %{}}) == {:error, :unexpected_format}
      assert Providers.parse_response(:bing, %{"webPages" => %{}}) == {:error, :unexpected_format}
      assert Providers.parse_response(:brave, %{"web" => %{}}) == {:error, :unexpected_format}
      assert Providers.parse_response(:perplexity, %{}) == {:error, :unexpected_format}
    end
  end

  describe "do_web_search/4 through the :web_search_http_runner seam" do
    # Hardcoded provider map for the @doc false test seam (bypasses
    # EvoGit.Config.resolve()); opts override the defaults.
    defp provider_map(provider, opts \\ %{}) do
      Map.merge(
        %{
          provider: provider,
          api_key: "test-key",
          timeout: nil,
          base_url: "https://example.test"
        },
        opts
      )
    end

    # Stub runner: captures the request into the test process mailbox and
    # returns the given canned response body (no network).
    defp stub_runner(body) do
      fn request, _receive_timeout ->
        send(self(), {:web_search_request, request})
        {:ok, %{status: 200, body: body}}
      end
    end

    test "tavily: captures the POST request and formats results (Found N prefix)" do
      body = %{"results" => [%{"title" => "T", "url" => "http://t", "content" => "c"}]}
      Application.put_env(:evo_git, :web_search_http_runner, stub_runner(body))

      result = WebSearch.do_web_search("q", "advanced", 7, provider_map(:tavily))

      assert result == "Found 1 results:\n\n## T\nhttp://t\n\nc\n"

      assert_receive {:web_search_request, request}
      assert request.method == :post
      assert request.url == "https://example.test"
      assert request.headers["Authorization"] == "Bearer test-key"
      assert request.body == %{query: "q", search_depth: "advanced", max_results: 7}
    end

    test "perplexity: formats the markdown answer with a citations section" do
      body = %{
        "choices" => [%{"message" => %{"content" => "**answer**"}}],
        "citations" => ["https://c1", "https://c2"]
      }

      Application.put_env(:evo_git, :web_search_http_runner, stub_runner(body))

      result =
        WebSearch.do_web_search(
          "q",
          "advanced",
          50,
          provider_map(:perplexity, %{
            base_url: "https://api.perplexity.ai/chat/completions",
            model: "sonar"
          })
        )

      assert result == "Answer:\n\n**answer**\n\n## Citations\n\n- https://c1\n- https://c2"

      assert_receive {:web_search_request, request}
      assert request.method == :post
      assert request.body == %{model: "sonar", messages: [%{role: "user", content: "q"}]}
    end

    test "exa: x-api-key header + results formatting" do
      body = %{"results" => [%{"title" => "E", "url" => "http://e", "text" => "txt"}]}
      Application.put_env(:evo_git, :web_search_http_runner, stub_runner(body))

      result = WebSearch.do_web_search("q", "advanced", 3, provider_map(:exa))

      assert result == "Found 1 results:\n\n## E\nhttp://e\n\ntxt\n"

      assert_receive {:web_search_request, request}
      assert request.headers["x-api-key"] == "test-key"
      assert request.body == %{query: "q", numResults: 3, type: "neural"}
    end

    test "bing: GET request with Ocp-Apim-Subscription-Key + webPages.value parsing" do
      body = %{
        "webPages" => %{"value" => [%{"name" => "B", "url" => "http://b", "snippet" => "snip"}]}
      }

      Application.put_env(:evo_git, :web_search_http_runner, stub_runner(body))

      result = WebSearch.do_web_search("q", "basic", 3, provider_map(:bing))

      assert result == "Found 1 results:\n\n## B\nhttp://b\n\nsnip\n"

      assert_receive {:web_search_request, request}
      assert request.method == :get
      assert request.headers["Ocp-Apim-Subscription-Key"] == "test-key"
      assert request.body == nil
      assert request.url =~ "q=q"
      assert request.url =~ "count=3"
    end

    test "brave: GET request with X-Subscription-Token + web.results parsing" do
      body = %{
        "web" => %{
          "results" => [%{"title" => "Br", "url" => "http://br", "description" => "desc"}]
        }
      }

      Application.put_env(:evo_git, :web_search_http_runner, stub_runner(body))

      result = WebSearch.do_web_search("q", "basic", 4, provider_map(:brave))

      assert result == "Found 1 results:\n\n## Br\nhttp://br\n\ndesc\n"

      assert_receive {:web_search_request, request}
      assert request.method == :get
      assert request.headers["X-Subscription-Token"] == "test-key"
      assert request.body == nil
    end

    test "missing or empty API key returns the exact error string before any HTTP" do
      for api_key <- [nil, ""] do
        result =
          WebSearch.do_web_search("q", "basic", 5, provider_map(:tavily, %{api_key: api_key}))

        assert result == "Error: API key for search provider is not set"
      end
    end

    test "non-200 status produces the status error string" do
      Application.put_env(:evo_git, :web_search_http_runner, fn _request, _timeout ->
        {:ok, %{status: 429, body: %{"error" => "rate limited"}}}
      end)

      result = WebSearch.do_web_search("q", "basic", 5, provider_map(:tavily))

      assert result ==
               "Error: Web search failed with status 429. %{\"error\" => \"rate limited\"}"
    end

    test "request failure produces the request error string" do
      Application.put_env(:evo_git, :web_search_http_runner, fn _request, _timeout ->
        {:error, :timeout}
      end)

      result = WebSearch.do_web_search("q", "basic", 5, provider_map(:tavily))
      assert result == "Error: Web search request failed: :timeout"
    end

    test "unparseable 200 body produces the unexpected-format fallback" do
      Application.put_env(:evo_git, :web_search_http_runner, stub_runner(%{"nope" => true}))

      result = WebSearch.do_web_search("q", "basic", 5, provider_map(:tavily))
      assert result == "Error: Search response (unexpected format): %{\"nope\" => true}"
    end

    test "a unit-string timeout reaches the runner as integer ms" do
      isolate_max_timeout!(1_800_000)

      Application.put_env(
        :evo_git,
        :web_search_http_runner,
        timeout_capturing_runner(%{"results" => []})
      )

      assert WebSearch.do_web_search("q", "basic", 5, provider_map(:tavily, %{timeout: "90s"})) ==
               "Found 0 results:\n\n"

      assert_receive {:receive_timeout, receive_timeout}
      assert is_integer(receive_timeout)
      assert receive_timeout == 90_000
    end

    test "a float timeout is truncated to integer ms" do
      isolate_max_timeout!(1_800_000)
      Application.put_env(:evo_git, :web_search_http_runner, timeout_capturing_runner(%{}))
      WebSearch.do_web_search("q", "basic", 5, provider_map(:tavily, %{timeout: 2_500.9}))
      assert_receive {:receive_timeout, 2_500}
    end

    test "an oversized timeout is clamped to the configured maximum" do
      isolate_max_timeout!(5_000)
      assert EvoGit.Config.resolve([:scheduler, :max_tool_timeout]) == 5_000
      Application.put_env(:evo_git, :web_search_http_runner, timeout_capturing_runner(%{}))
      WebSearch.do_web_search("q", "basic", 5, provider_map(:tavily, %{timeout: "10m"}))
      assert_receive {:receive_timeout, 5_000}
      WebSearch.do_web_search("q", "basic", 5, provider_map(:tavily, %{timeout: 999_999_999}))
      assert_receive {:receive_timeout, 5_000}
    end

    test "an absent or unusable timeout keeps the 30 s default (never a non-integer)" do
      isolate_max_timeout!(1_800_000)
      Application.put_env(:evo_git, :web_search_http_runner, timeout_capturing_runner(%{}))
      WebSearch.do_web_search("q", "basic", 5, provider_map(:tavily))
      assert_receive {:receive_timeout, 30_000}
      WebSearch.do_web_search("q", "basic", 5, provider_map(:tavily, %{timeout: "soon"}))
      assert_receive {:receive_timeout, 30_000}
    end
  end

  describe "execute/3 through the seam (tavily, base schema)" do
    test "dispatches a tavily POST and formats results end-to-end" do
      body = %{"results" => [%{"title" => "T", "url" => "http://t", "content" => "c"}]}
      Application.put_env(:evo_git, :web_search_http_runner, stub_runner(body))

      original_key = Application.get_env(:req_llm, :tavily_api_key)
      ReqLLM.put_key(:tavily_api_key, "test-key")

      try do
        result =
          WebSearch.execute(
            %{"query" => "hello", "search_depth" => "advanced", "max_results" => 7},
            nil,
            nil
          )

        assert result == "Found 1 results:\n\n## T\nhttp://t\n\nc\n"

        assert_receive {:web_search_request, request}
        assert request.method == :post
        assert request.url == "https://api.tavily.com/search"
        assert request.headers["Authorization"] == "Bearer test-key"
        assert request.body == %{query: "hello", search_depth: "advanced", max_results: 7}
      after
        if original_key do
          Application.put_env(:req_llm, :tavily_api_key, original_key)
        else
          Application.delete_env(:req_llm, :tavily_api_key)
        end
      end
    end

    test "a unit-string timeout argument is coerced before the runner sees it" do
      isolate_max_timeout!(1_800_000)

      Application.put_env(
        :evo_git,
        :web_search_http_runner,
        timeout_capturing_runner(%{"results" => []})
      )

      original_key = Application.get_env(:req_llm, :tavily_api_key)
      ReqLLM.put_key(:tavily_api_key, "test-key")

      try do
        assert WebSearch.execute(%{"query" => "hello", "timeout" => "2m"}, nil, nil) ==
                 "Found 0 results:\n\n"

        assert_receive {:receive_timeout, receive_timeout}
        assert is_integer(receive_timeout)
        assert receive_timeout == 120_000
      after
        if original_key do
          Application.put_env(:req_llm, :tavily_api_key, original_key)
        else
          Application.delete_env(:req_llm, :tavily_api_key)
        end
      end
    end
  end
end
