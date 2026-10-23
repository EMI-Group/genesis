defmodule EvoGit.Agent.Tools.WebFetchTest do
  @moduledoc """
  End-to-end tests for `EvoGit.Agent.Tools.WebFetch` against a real (in-test)
  HTTP/1.1 server on `127.0.0.1`, so the whole Req → socket → stream → convert
  path is exercised with no network access and no mocking of `Req`.
  """

  use ExUnit.Case, async: false

  alias EvoGit.Agent.Tools.WebFetch

  @repo "/tmp/web-fetch-test-repo"

  defmodule Server do
    @moduledoc false
    # Minimal raw-TCP HTTP/1.1 server. `start!/1` takes a `%{path => spec}` map:
    #
    #   * `{status, headers, body}` — a canned response
    #   * `{:redirect, location}`   — a 302 with that `location`
    #   * `{:sleep, ms, spec}`      — wait, then respond with `spec`
    #   * `fun/0`                   — any of the above, computed per request
    #
    # Unknown paths answer 404. `send_timeout: 2_000` keeps a client that hangs
    # up mid-body (the size-cap test) from wedging the accept loop.

    import ExUnit.Callbacks, only: [on_exit: 1]

    def start!(routes) do
      {:ok, listen} =
        :gen_tcp.listen(0, [
          :binary,
          packet: :raw,
          active: false,
          reuseaddr: true,
          send_timeout: 2_000,
          ip: {127, 0, 0, 1}
        ])

      {:ok, port} = :inet.port(listen)
      routes = Map.new(routes)
      acceptor = spawn(fn -> accept_loop(listen, routes) end)

      on_exit(fn ->
        Process.exit(acceptor, :kill)
        :gen_tcp.close(listen)
      end)

      %{port: port, url: "http://127.0.0.1:#{port}"}
    end

    defp accept_loop(listen, routes) do
      case :gen_tcp.accept(listen) do
        {:ok, socket} ->
          serve(socket, routes)
          :gen_tcp.close(socket)
          accept_loop(listen, routes)

        {:error, _reason} ->
          :ok
      end
    end

    defp serve(socket, routes) do
      case read_request(socket) do
        {:ok, path} ->
          spec =
            routes
            |> Map.get(path, {404, [{"content-type", "text/plain"}], "not found"})
            |> resolve()

          send_response(socket, spec)

        {:error, _reason} ->
          :ok
      end
    end

    defp resolve(fun) when is_function(fun, 0), do: resolve(fun.())

    defp resolve({:sleep, ms, spec}) do
      Process.sleep(ms)
      resolve(spec)
    end

    defp resolve({:redirect, location}),
      do: {302, [{"location", location}, {"content-type", "text/plain"}], ""}

    defp resolve({status, headers, body}), do: {status, headers, body}

    defp read_request(socket, acc \\ "") do
      case String.split(acc, "\r\n\r\n", parts: 2) do
        [head, _rest] ->
          {:ok, request_path(head)}

        [_incomplete] ->
          case :gen_tcp.recv(socket, 0, 5_000) do
            {:ok, data} -> read_request(socket, acc <> data)
            {:error, reason} -> {:error, reason}
          end
      end
    end

    defp request_path(head) do
      case String.split(head, "\r\n") do
        [request_line | _] ->
          case String.split(request_line, " ") do
            [_method, target | _] -> target |> String.split("?") |> hd()
            _ -> "/"
          end

        _ ->
          "/"
      end
    end

    defp send_response(socket, {status, headers, body}) do
      headers =
        headers ++
          [{"content-length", Integer.to_string(byte_size(body))}, {"connection", "close"}]

      :gen_tcp.send(socket, [
        "HTTP/1.1 #{status} #{reason(status)}\r\n",
        Enum.map(headers, fn {name, value} -> "#{name}: #{value}\r\n" end),
        "\r\n",
        body
      ])
    end

    defp reason(200), do: "OK"
    defp reason(302), do: "Found"
    defp reason(404), do: "Not Found"
    defp reason(500), do: "Internal Server Error"
    defp reason(_status), do: "Status"
  end

  setup do
    previous = Application.fetch_env(:evo_git, :web_fetch_allow_private_hosts)
    Application.put_env(:evo_git, :web_fetch_allow_private_hosts, true)

    on_exit(fn ->
      case previous do
        {:ok, value} -> Application.put_env(:evo_git, :web_fetch_allow_private_hosts, value)
        :error -> Application.delete_env(:evo_git, :web_fetch_allow_private_hosts)
      end
    end)

    :ok
  end

  defp fetch(args), do: WebFetch.execute(args, @repo, @repo)

  describe "schema" do
    test "exposes the model-facing name, params and defaults" do
      schema = WebFetch.schema()

      assert schema.name == "web_fetch"
      assert schema.description =~ "Markdown"

      properties = schema.parameter_schema["properties"]
      assert properties["url"]["type"] == "string"
      assert properties["max_chars"]["default"] == 200_000
      assert properties["timeout"]["default"] == 30_000
      assert schema.parameter_schema["required"] == ["url"]
    end
  end

  describe "happy path" do
    test "converts an HTML page to markdown inside the Fetched envelope" do
      server =
        Server.start!(%{
          "/page" =>
            {200, [{"content-type", "text/html; charset=utf-8"}],
             """
             <html>
               <head><title>t</title><script>alert("nope")</script><style>.x{}</style></head>
               <body>
                 <!-- a comment -->
                 <h1>Heading</h1>
                 <p>Hello <strong>world</strong>.</p>
                 <ul><li>one</li><li>two</li></ul>
                 <ol><li>first</li></ol>
                 <a href="/rel">rel link</a>
               </body>
             </html>
             """}
        })

      result = fetch(%{"url" => server.url <> "/page"})

      assert String.starts_with?(result, "Fetched #{server.url}/page (HTTP 200)\n\n# Heading\n\n")
      assert result =~ "Hello **world**."
      assert result =~ "- one"
      assert result =~ "- two"
      assert result =~ "1. first"
      assert result =~ "[rel link](#{server.url}/rel)"
      refute result =~ "alert"
      refute result =~ ".x{}"
      refute result =~ "a comment"
    end

    test "passes plain text through verbatim" do
      server =
        Server.start!(%{
          "/text" => {200, [{"content-type", "text/plain; charset=utf-8"}], "line one\nline two"}
        })

      result = fetch(%{"url" => server.url <> "/text"})

      assert result == "Fetched #{server.url}/text (HTTP 200)\n\nline one\nline two"
    end

    test "replaces binary payloads with a one-line note" do
      server =
        Server.start!(%{
          "/doc.pdf" => {200, [{"content-type", "application/pdf"}], "%PDF-1.7 ..."}
        })

      result = fetch(%{"url" => server.url <> "/doc.pdf"})

      assert result ==
               "Fetched #{server.url}/doc.pdf (HTTP 200)\n\n[binary content omitted: application/pdf]"
    end

    test "sniffs HTML when the content type is missing" do
      server =
        Server.start!(%{"/sniff" => {200, [], "<html><body><p>sniffed</p></body></html>"}})

      result = fetch(%{"url" => server.url <> "/sniff"})

      assert result == "Fetched #{server.url}/sniff (HTTP 200)\n\nsniffed"
    end
  end

  describe "size cap" do
    test "stops reading at the raw cap and truncates the converted text" do
      huge = String.duplicate("a", 2_000_000)
      server = Server.start!(%{"/big" => {200, [{"content-type", "text/plain"}], huge}})

      {elapsed_us, result} =
        :timer.tc(fn -> fetch(%{"url" => server.url <> "/big", "max_chars" => 500}) end)

      assert String.starts_with?(result, "Fetched #{server.url}/big (HTTP 200)\n\n")
      assert result =~ ~r/\[truncated: first 500 of ~\d+ characters\]\z/

      # The retained prefix is exactly max_chars characters (plus the marker).
      [body_and_envelope, marker] = String.split(result, "\n\n[truncated:", parts: 2)
      body = body_and_envelope |> String.split("\n\n", parts: 2) |> List.last()
      assert String.length(body) == 500
      assert marker =~ ~r/^ first 500 of ~\d+ characters\]$/

      # Reading halted early: the 2 MB body never made it into memory.
      assert elapsed_us < 3_000_000
    end
  end

  describe "failures" do
    test "non-2xx names the status" do
      server = Server.start!(%{"/missing" => {404, [{"content-type", "text/plain"}], "gone"}})

      assert fetch(%{"url" => server.url <> "/missing"}) ==
               "Error: #{server.url}/missing returned HTTP 404 Not Found"
    end

    test "a slow server yields a timeout error naming the ms budget" do
      server =
        Server.start!(%{
          "/slow" => {:sleep, 500, {200, [{"content-type", "text/plain"}], "late"}}
        })

      {elapsed_us, result} =
        :timer.tc(fn -> fetch(%{"url" => server.url <> "/slow", "timeout" => 100}) end)

      assert result == "Error: the request to #{server.url}/slow timed out after 100 ms"
      assert elapsed_us < 2_000_000
    end

    test "rejects non-http(s) schemes naming the scheme" do
      assert fetch(%{"url" => "file:///etc/passwd"}) ==
               "Error: the URL scheme \"file\" is not supported: web_fetch only fetches http and https URLs"

      assert fetch(%{"url" => "ftp://example.com/x"}) =~
               "Error: the URL scheme \"ftp\" is not supported"
    end

    test "rejects a missing or non-absolute url" do
      assert fetch(%{}) =~ "Error: Missing required argument 'url'"
      assert fetch(%{"url" => "/relative/path"}) =~ "Error: "
    end

    test "validates max_chars and timeout ranges" do
      assert fetch(%{"url" => "http://example.com/", "max_chars" => 5}) =~
               "Error: Argument 'max_chars' must be an integer between 100 and 2000000"

      assert fetch(%{"url" => "http://example.com/", "timeout" => 1}) =~
               "Error: Argument 'timeout' must be an integer between 50 and 600000"
    end
  end

  describe "redirects" do
    test "follows same-host, same-scheme redirects and reports the final url" do
      server =
        Server.start!(%{
          "/r0" => {:redirect, "/r1"},
          "/r1" => {:redirect, "/r2"},
          "/r2" => {200, [{"content-type", "text/plain"}], "arrived"}
        })

      assert fetch(%{"url" => server.url <> "/r0"}) ==
               "Fetched #{server.url}/r2 (HTTP 200)\n\narrived"
    end

    test "refuses the 6th redirect (5-hop budget)" do
      redirects =
        for hop <- 0..5, into: %{} do
          {"/c#{hop}", {:redirect, "/c#{hop + 1}"}}
        end

      server =
        Server.start!(Map.put(redirects, "/c6", {200, [{"content-type", "text/plain"}], "end"}))

      result = fetch(%{"url" => server.url <> "/c0"})

      assert result ==
               "Error: #{server.url}/c5 exceeded the redirect limit of 5 hops (too many redirects)"
    end

    test "refuses cross-host redirects" do
      server = Server.start!(%{"/x" => {:redirect, "http://example.com/elsewhere"}})

      result = fetch(%{"url" => server.url <> "/x"})

      assert result =~ "Error: refused the cross-host redirect"
      assert result =~ "same-host, same-scheme redirects"
    end

    test "refuses scheme-changing redirects" do
      server = Server.start!(%{})

      server =
        Server.start!(%{
          "/s" => fn ->
            {:redirect, String.replace(server.url, "http://", "https://") <> "/s2"}
          end
        })

      result = fetch(%{"url" => server.url <> "/s"})

      assert result =~ "Error: refused the redirect"
      assert result =~ "the scheme changed (http -> https)"
    end

    test "a redirect without a Location header is an error" do
      server = Server.start!(%{"/no-location" => {302, [{"content-type", "text/plain"}], ""}})

      assert fetch(%{"url" => server.url <> "/no-location"}) =~
               "Error: #{server.url}/no-location returned HTTP 302 Found without a Location header"
    end
  end

  describe "host gate" do
    setup do
      Application.put_env(:evo_git, :web_fetch_allow_private_hosts, false)
      :ok
    end

    test "refuses loopback addresses when the test seam is off" do
      server = Server.start!(%{"/page" => {200, [{"content-type", "text/plain"}], "hi"}})

      result = fetch(%{"url" => server.url <> "/page"})

      assert result =~ "Error: 127.0.0.1 resolves to the non-public address 127.0.0.1"
      assert result =~ "only fetches public hosts"
    end

    test "refuses the localhost name" do
      assert fetch(%{"url" => "http://localhost:9/"}) =~
               "Error: localhost is a local/loopback name"

      assert fetch(%{"url" => "http://api.localhost:9/"}) =~
               "Error: api.localhost is a local/loopback name"
    end

    test "refuses cloud-metadata and private ranges by IP literal" do
      assert fetch(%{"url" => "http://169.254.169.254/latest/meta-data/"}) =~
               "Error: 169.254.169.254 resolves to the non-public address 169.254.169.254"

      assert fetch(%{"url" => "http://10.1.2.3/"}) =~ "Error: 10.1.2.3 resolves to the non-public"

      assert fetch(%{"url" => "http://192.168.0.1/"}) =~
               "Error: 192.168.0.1 resolves to the non-public"

      assert fetch(%{"url" => "http://172.20.0.1/"}) =~
               "Error: 172.20.0.1 resolves to the non-public"

      assert fetch(%{"url" => "http://100.64.0.1/"}) =~
               "Error: 100.64.0.1 resolves to the non-public"

      assert fetch(%{"url" => "http://0.0.0.0/"}) =~ "Error: 0.0.0.0 resolves to the non-public"
      assert fetch(%{"url" => "http://[::1]/"}) =~ "Error: ::1 resolves to the non-public"
      assert fetch(%{"url" => "http://[fe80::1]/"}) =~ "Error: fe80::1 resolves to the non-public"
      assert fetch(%{"url" => "http://[fc00::1]/"}) =~ "Error: fc00::1 resolves to the non-public"
      assert fetch(%{"url" => "http://[::ffff:127.0.0.1]/"}) =~ "resolves to the non-public"
    end
  end
end
