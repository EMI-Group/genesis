defmodule EvoGit.Agent.Tools.WebFetch do
  @moduledoc """
  `web_fetch` — fetch ONE web page over HTTP(S) and hand it back as readable
  Markdown.

  A *reader*, not a browser or a crawler: one HTTP GET per hop, no JavaScript,
  no cookies/authentication, no side effects. HTML is converted by
  `EvoGit.Agent.Tools.HtmlToMarkdown` (relative links resolved against the
  final URL); plain text, Markdown, JSON, XML and CSV pass through verbatim;
  other binary payloads become a one-line note so a PDF never floods the
  context. Every failure is a single `Error: …` sentence
  (`EvoGit.Agent.Tools.Failure`) — the tool never raises.

  ## Response envelope

      2xx only:

      Fetched <final url as requested> (HTTP 200)

      <converted body>

  `max_chars` caps the CONVERTED text; when it truncates, a marker is appended:

      [truncated: first 200000 of ~1234567 characters]

  (The count is the text that was actually converted, itself bounded by the
  raw byte cap — so for a very large page the total is a lower bound.)

  ## Size cap (hard, streaming)

  The body is streamed with `Req`'s `into:` callback and the read is HALTED at
  `raw_cap = clamp(max_chars * 8, 512 KiB, 16 MiB)`: 8 bytes of markup per
  retained character, floored at 512 KiB (a small `max_chars` still sees enough
  markup to produce readable text) and capped at 16 MiB (reached at the maximum
  accepted `max_chars` of 2 000 000). The socket is closed at the cap, so a
  multi-gigabyte response is never buffered. Bodies we will never show (non-2xx,
  binary content types) are not read at all.

  ## Redirect policy (documented deviation)

  Redirects are followed MANUALLY (`redirect: false`) so every hop passes the
  same gates: **≤ 5 hops** (the 6th fails with `Error: … too many redirects …`)
  and **same host, same scheme only** — a hop that changes the scheme
  (`https`↔`http`) or the host is REFUSED with a descriptive `Error:`. The
  reference "same-origin ≤5" policy is thus adapted to same-host/same-scheme:
  the port may change, because every hop is re-validated and re-resolved by the
  host gate anyway.

  ## SSRF / host gate — BEST EFFORT, honestly

  Unless the test seam below is enabled, the tool refuses anything that is not
  a public address: IPv4 loopback (`127/8`), private (`10/8`, `172.16/12`,
  `192.168/16`), link-local (`169.254/16` — cloud metadata), CGNAT
  (`100.64/10`), `0/8`, multicast/reserved (`224/4`, `240/4`); IPv6
  loopback/unspecified (`::1`, `::`), unique-local (`fc00::/7`), link-local
  (`fe80::/10`), multicast (`ff00::/8`) and the IPv4-mapped/compatible forms of
  all of the above; plus the literal names `localhost` and `*.localhost`. The
  host is resolved by the tool itself (`:inet.getaddrs/2` for both `:inet` and
  `:inet6`) and EVERY resolved address is checked.

  **This cannot be complete**: the request is then issued by name, so a hostile
  DNS server can answer the check with a public address and the connection with
  a private one (DNS rebinding), and a chain served by a hostile *public* host
  can still reach an internal service. Defeating rebinding needs pinning the
  resolved IP for the actual connection (Finch `conn_opts` + `Host` header),
  which this tool deliberately does not do: treat the gate as a guard against
  careless/internal URLs, not as a security boundary against a determined
  attacker.

  ## Test seam

  `Application.get_env(:evo_git, :web_fetch_allow_private_hosts, false)` —
  **TEST-ONLY**, read at call time: when `true` the host gate is skipped so the
  suite can point the tool at a `127.0.0.1` server. Never set it in shipped
  configuration.

  ## Timing and client

  `timeout` is the WHOLE-request budget (all hops): a monotonic deadline is
  checked before every hop and each socket read gets the remaining budget as its
  `receive_timeout`. Retries are disabled — a hidden retry storm would blow the
  budget and multiply the load on a struggling host.

  The client is `Req` (~> 0.7 in `apps/evo_git/mix.exs`): already a declared
  dependency, already used by the sibling `web_search` tool, and it exposes the
  streaming `into:` callback needed for halt-at-cap reading. `:httpc` would need
  hand-rolled streaming/TLS; `curl`/`wget` shells are forbidden (no sandbox, no
  size control, no address gate).
  """
  import Bitwise

  alias EvoGit.Agent.Tools.Failure
  alias EvoGit.Agent.Tools.HtmlToMarkdown
  alias EvoGit.Agent.Tools.Shared

  @tool_name "web_fetch"

  @default_max_chars 200_000
  @min_max_chars 100
  @max_max_chars 2_000_000

  @default_timeout 30_000
  @min_timeout 50
  @max_timeout 600_000

  @max_redirect_hops 5

  @bytes_per_char 8
  @min_raw_cap 512 * 1024
  @max_raw_cap 16 * 1024 * 1024

  @redirect_statuses [301, 302, 303, 307, 308]

  @user_agent "genesis-web-fetch/1.0 (+https://genesis.evox.group)"

  @text_content_types ~w(
    application/json application/xml application/x-ndjson application/ld+json
    application/problem+json application/javascript application/toml
    application/yaml application/x-yaml application/csv application/graphql
  )

  @html_content_types ~w(text/html application/xhtml+xml application/xhtml text/xhtml)

  @reason_phrases %{
    301 => " Moved Permanently",
    302 => " Found",
    303 => " See Other",
    307 => " Temporary Redirect",
    308 => " Permanent Redirect",
    400 => " Bad Request",
    401 => " Unauthorized",
    403 => " Forbidden",
    404 => " Not Found",
    405 => " Method Not Allowed",
    408 => " Request Timeout",
    410 => " Gone",
    429 => " Too Many Requests",
    500 => " Internal Server Error",
    502 => " Bad Gateway",
    503 => " Service Unavailable",
    504 => " Gateway Timeout"
  }

  @doc """
  Returns the tool schema for ReqLLM (model-facing name: `web_fetch`).
  """
  def schema do
    ReqLLM.tool(
      name: @tool_name,
      description:
        "Fetch one web page over HTTP(S) and return it as readable Markdown " <>
          "(HTML is converted to Markdown; plain text, Markdown, JSON, XML and CSV pass " <>
          "through verbatim; other binary payloads are reported as omitted). " <>
          "Use it after web_search when you need the actual page content. " <>
          "One GET, no JavaScript rendering, no cookies or logins. " <>
          "At most 5 redirects are followed, and only within the same host and scheme. " <>
          "Local, loopback, private-network and cloud-metadata hosts are refused.",
      parameter_schema: %{
        "type" => "object",
        "properties" => %{
          "url" => %{
            "type" => "string",
            "description" =>
              "Absolute URL to fetch. Only the http and https schemes are accepted."
          },
          "max_chars" => %{
            "type" => "integer",
            "description" =>
              "Cap on the converted text handed back, in characters " <>
                "(#{@min_max_chars}-#{@max_max_chars}); larger values cost more context.",
            "default" => @default_max_chars
          },
          "timeout" => %{
            "type" => "integer",
            "description" =>
              "Whole-request budget in milliseconds, including all redirect hops " <>
                "(#{@min_timeout}-#{@max_timeout}).",
            "default" => @default_timeout
          }
        },
        "required" => ["url"]
      },
      callback: fn _ -> {:ok, nil} end
    )
  end

  @doc """
  Fetches `args["url"]` and returns the text handed back to the model.

  Always returns a `String.t()`; failures are `Error: …` sentences.
  """
  def execute(args, _repo_path, _repo_root) do
    case validate_args(args) do
      {:ok, url, max_chars, timeout} ->
        # The tool is a leaf of the agent loop: a raise here would kill the
        # task, so every unexpected crash is reported as a failure instead.
        deadline = System.monotonic_time(:millisecond) + timeout

        try do
          hop(String.trim(url), max_chars, timeout, deadline, 0)
        rescue
          error ->
            Failure.error("#{@tool_name} failed unexpectedly: #{Exception.message(error)}")
        end

      {:error, message} ->
        Failure.error(message)
    end
  end

  defp validate_args(args) do
    with {:ok, url} <- Shared.fetch_string_arg(args, "url"),
         {:ok, max_chars} <-
           int_arg(args, "max_chars", @default_max_chars, @min_max_chars, @max_max_chars),
         {:ok, timeout} <-
           int_arg(args, "timeout", @default_timeout, @min_timeout, @max_timeout) do
      {:ok, url, max_chars, timeout}
    end
  end

  ## ------------------------------------------------------------------
  ## Argument validation
  ## ------------------------------------------------------------------

  defp int_arg(args, key, default, min, max) do
    case Map.get(args, key) do
      nil -> {:ok, default}
      value -> validate_int(value, key, min, max)
    end
  end

  defp validate_int(value, key, min, max) do
    case coerce_int(value) do
      {:ok, int} when is_integer(int) and int >= min and int <= max ->
        {:ok, int}

      _ ->
        {:error,
         "Argument '#{key}' must be an integer between #{min} and #{max}, got: #{inspect(value)}"}
    end
  end

  defp coerce_int(value) when is_integer(value), do: {:ok, value}

  defp coerce_int(value) when is_float(value) do
    if value == trunc(value), do: {:ok, trunc(value)}, else: :error
  end

  defp coerce_int(value) when is_binary(value) do
    case Integer.parse(String.trim(value)) do
      {int, ""} -> {:ok, int}
      _ -> :error
    end
  end

  defp coerce_int(_value), do: :error

  ## ------------------------------------------------------------------
  ## Fetch loop (one hop per call)
  ## ------------------------------------------------------------------

  defp hop(url, max_chars, timeout, deadline, hops) do
    with {:ok, uri} <- parse_url(url),
         :ok <- check_scheme(uri),
         :ok <- check_host(uri),
         {:ok, budget} <- hop_budget(url, deadline, timeout) do
      case http_get(url, raw_cap(max_chars), budget) do
        {:ok, response} when response.status in 200..299 ->
          render(url, response, max_chars)

        {:ok, response} when response.status in @redirect_statuses ->
          follow_redirect(url, uri, response, max_chars, timeout, deadline, hops)

        {:ok, response} ->
          Failure.error(
            "#{url} returned HTTP #{response.status}#{reason_phrase(response.status)}"
          )

        {:error, {:timeout, budget_ms}} ->
          Failure.error("the request to #{url} timed out after #{budget_ms} ms")

        {:error, {:transport, detail}} ->
          Failure.error("the request to #{url} failed: #{detail}")
      end
    else
      {:error, message} -> Failure.error(message)
    end
  end

  defp hop_budget(url, deadline, timeout) do
    remaining = deadline - System.monotonic_time(:millisecond)

    if remaining > 0 do
      {:ok, remaining}
    else
      {:error, "the request to #{url} timed out after #{timeout} ms"}
    end
  end

  defp follow_redirect(url, uri, response, max_chars, timeout, deadline, hops) do
    location = header(response, "location")

    cond do
      is_nil(location) or String.trim(location) == "" ->
        Failure.error(
          "#{url} returned HTTP #{response.status}#{reason_phrase(response.status)} without a Location header"
        )

      hops >= @max_redirect_hops ->
        Failure.error(
          "#{url} exceeded the redirect limit of #{@max_redirect_hops} hops (too many redirects)"
        )

      true ->
        next_url = resolve_location(url, location)

        case parse_url(next_url) do
          {:error, message} ->
            Failure.error(message)

          {:ok, next_uri} ->
            cond do
              next_uri.scheme != uri.scheme ->
                Failure.error(
                  "refused the redirect from #{url} to #{next_url}: the scheme changed " <>
                    "(#{uri.scheme} -> #{next_uri.scheme}) and #{@tool_name} only follows " <>
                    "same-host, same-scheme redirects"
                )

              next_uri.host != uri.host ->
                Failure.error(
                  "refused the cross-host redirect from #{url} to #{next_url}: " <>
                    "#{@tool_name} only follows same-host, same-scheme redirects"
                )

              true ->
                hop(next_url, max_chars, timeout, deadline, hops + 1)
            end
        end
    end
  end

  defp resolve_location(current_url, location) do
    location = String.trim(location)

    if absolute_url?(location) do
      location
    else
      merge_url(current_url, location)
    end
  end

  defp absolute_url?(url), do: Regex.match?(~r/^[a-zA-Z][a-zA-Z0-9+.\-]*:/, url)

  defp merge_url(base, url) do
    URI.merge(base, url) |> URI.to_string()
  rescue
    # A malformed base/location pair is reported by the caller's URL parsing
    # instead of crashing here.
    _ -> url
  end

  ## ------------------------------------------------------------------
  ## URL gates
  ## ------------------------------------------------------------------

  defp parse_url(url) do
    case URI.parse(url) do
      %URI{scheme: scheme} = uri when is_binary(scheme) and scheme != "" ->
        {:ok,
         %{uri | scheme: String.downcase(scheme), host: uri.host && String.downcase(uri.host)}}

      _ ->
        {:error, "#{inspect(url)} is not an absolute URL (it has no scheme)"}
    end
  end

  defp check_scheme(%URI{scheme: scheme}) when scheme in ["http", "https"], do: :ok

  defp check_scheme(%URI{scheme: scheme}) do
    {:error,
     "the URL scheme #{inspect(scheme)} is not supported: #{@tool_name} only fetches http and https URLs"}
  end

  defp check_host(uri) do
    case uri.host do
      host when is_binary(host) and host != "" -> validate_public_host(uri)
      _ -> {:error, "#{@tool_name} needs an absolute URL with a host"}
    end
  end

  # TEST SEAM — see the module doc. Read at call time; test-only.
  defp allow_private_hosts?,
    do: Application.get_env(:evo_git, :web_fetch_allow_private_hosts, false) == true

  defp validate_public_host(%URI{host: host}) do
    host = String.downcase(host)

    cond do
      allow_private_hosts?() ->
        :ok

      localhost_name?(host) ->
        {:error,
         "#{host} is a local/loopback name: #{@tool_name} only fetches public hosts " <>
           "(loopback, private, link-local, CGNAT and cloud-metadata addresses are refused)"}

      true ->
        case resolve_host(host) do
          {:ok, addresses} ->
            case Enum.find(addresses, &private_address?/1) do
              nil ->
                :ok

              address ->
                {:error,
                 "#{host} resolves to the non-public address #{format_address(address)}: " <>
                   "#{@tool_name} only fetches public hosts (loopback, private, link-local, " <>
                   "CGNAT and cloud-metadata addresses are refused)"}
            end

          {:error, detail} ->
            {:error, "could not resolve the host #{host}: #{detail}"}
        end
    end
  end

  defp localhost_name?(host), do: host == "localhost" or String.ends_with?(host, ".localhost")

  defp resolve_host(host) do
    charlist = String.to_charlist(host)

    case :inet.parse_address(charlist) do
      {:ok, address} ->
        {:ok, [address]}

      {:error, _not_an_ip} ->
        v4 = :inet.getaddrs(charlist, :inet)
        v6 = :inet.getaddrs(charlist, :inet6)

        case addresses_of(v4) ++ addresses_of(v6) do
          [] -> {:error, dns_failure(v4, v6)}
          addresses -> {:ok, addresses}
        end
    end
  end

  defp addresses_of({:ok, addresses}) when is_list(addresses), do: addresses
  defp addresses_of(_error), do: []

  defp dns_failure(v4, v6) do
    case {v4, v6} do
      {{:error, reason}, _} -> inspect(reason)
      {_, {:error, reason}} -> inspect(reason)
      _ -> "no addresses returned"
    end
  end

  # Best-effort non-public address classification (see the module doc for the
  # honest disclaimer about DNS rebinding).
  defp private_address?({0, _, _, _}), do: true
  defp private_address?({10, _, _, _}), do: true
  defp private_address?({127, _, _, _}), do: true
  defp private_address?({169, 254, _, _}), do: true
  defp private_address?({172, b, _, _}) when b in 16..31, do: true
  defp private_address?({192, 168, _, _}), do: true
  defp private_address?({100, b, _, _}) when b in 64..127, do: true
  defp private_address?({a, _, _, _}) when a >= 224, do: true
  defp private_address?({_, _, _, _}), do: false

  defp private_address?({0, 0, 0, 0, 0, 0, 0, 1}), do: true
  defp private_address?({0, 0, 0, 0, 0, 0, 0, 0}), do: true

  defp private_address?({0, 0, 0, 0, 0, 0xFFFF, hi, lo}),
    do: private_address?({hi >>> 8, hi &&& 0xFF, lo >>> 8, lo &&& 0xFF})

  defp private_address?({0, 0, 0, 0, 0, 0, hi, lo}),
    do: private_address?({hi >>> 8, hi &&& 0xFF, lo >>> 8, lo &&& 0xFF})

  defp private_address?({a, _, _, _, _, _, _, _}) when (a &&& 0xFE00) == 0xFC00, do: true
  defp private_address?({a, _, _, _, _, _, _, _}) when (a &&& 0xFFC0) == 0xFE80, do: true
  defp private_address?({a, _, _, _, _, _, _, _}) when (a &&& 0xFF00) == 0xFF00, do: true
  defp private_address?({_, _, _, _, _, _, _, _}), do: false

  defp format_address(address) do
    case :inet.ntoa(address) do
      {:error, _reason} -> inspect(address)
      charlist -> to_string(charlist)
    end
  end

  ## ------------------------------------------------------------------
  ## HTTP
  ## ------------------------------------------------------------------

  defp raw_cap(max_chars) do
    (max_chars * @bytes_per_char)
    |> max(@min_raw_cap)
    |> min(@max_raw_cap)
  end

  # A single GET: no client-side redirects, no retries, no body decoding (the
  # body is streamed), no transparent decompression (`compressed: false` — the
  # streaming path never advertises an encoding, so the server sends plain
  # bytes and the byte cap counts real bytes).
  #
  # `connect_options` is deliberately NOT used: passing it makes Req start a
  # fresh dynamic Finch pool per distinct option set, i.e. a new pool for every
  # distinct remaining-ms budget. `receive_timeout` is a Finch REQUEST option
  # (per socket read) and the monotonic deadline bounds the hop chain.
  defp http_get(url, cap, budget) do
    request = [
      headers: [
        {"user-agent", @user_agent},
        {"accept", "text/html,application/xhtml+xml,text/plain;q=0.9,*/*;q=0.8"}
      ],
      redirect: false,
      retry: false,
      decode_body: false,
      compressed: false,
      receive_timeout: budget,
      into: chunk_collector(cap)
    ]

    case Req.get(url, request) do
      {:ok, %Req.Response{} = response} ->
        {:ok,
         %{
           status: response.status,
           headers: response.headers,
           body: response |> Req.Response.get_private(:body_acc, "") |> IO.iodata_to_binary(),
           truncated?: Req.Response.get_private(response, :body_truncated, false) == true
         }}

      {:error, %Req.TransportError{reason: :timeout}} ->
        {:error, {:timeout, budget}}

      {:error, %Mint.TransportError{reason: :timeout}} ->
        {:error, {:timeout, budget}}

      {:error, %Req.TransportError{reason: reason}} ->
        {:error, transport_error(reason)}

      {:error, %Mint.TransportError{reason: reason}} ->
        {:error, transport_error(reason)}

      {:error, %{__exception__: true} = error} ->
        {:error, {:transport, Exception.message(error)}}

      {:error, other} ->
        {:error, {:transport, inspect(other)}}
    end
  end

  @doc false
  # The ONE renderer for a transport failure reason, producing the
  # `{:transport, message}` payload above (test-pinned so the non-binary paths are
  # provable: the in-test TCP server can only yield atom reasons).
  # Mint/Req normally hand back an atom (`:econnrefused`, `:nxdomain`, `:closed`,
  # …), rendered bare so the message stays byte-identical, while any OTHER reason
  # — a TLS failure surfaces as a tuple such as
  # `{:tls_alert, {:handshake_failure, _}}` — goes through the shared TOTAL
  # formatter (`Failure.format_reason/1`) instead of raising
  # `Protocol.UndefinedError` out of string interpolation.
  def transport_error(reason), do: {:transport, "transport error (#{transport_reason(reason)})"}

  defp transport_reason(reason) when is_atom(reason), do: Atom.to_string(reason)
  defp transport_reason(reason), do: Failure.format_reason(reason)

  # Streaming collector: reads only what the cap allows and HALTS the socket at
  # the cap. Bodies we are never going to show (non-2xx, binary content types)
  # are not read at all.
  defp chunk_collector(cap) do
    fn {:data, data}, {request, response} ->
      if collectable?(response) do
        collect_chunk({request, response}, data, cap)
      else
        {:halt, {request, response}}
      end
    end
  end

  defp collect_chunk({request, response}, data, cap) do
    size = Req.Response.get_private(response, :body_size, 0)
    acc = Req.Response.get_private(response, :body_acc, [])
    remaining = cap - size

    cond do
      remaining <= 0 ->
        {:halt, {request, mark_truncated(response)}}

      byte_size(data) > remaining ->
        response =
          response
          # iodata, so the accumulator stays O(1) per chunk
          |> Req.Response.put_private(:body_acc, [acc, binary_part(data, 0, remaining)])
          |> Req.Response.put_private(:body_size, cap)
          |> mark_truncated()

        {:halt, {request, response}}

      true ->
        response =
          response
          |> Req.Response.put_private(:body_acc, [acc, data])
          |> Req.Response.put_private(:body_size, size + byte_size(data))

        {:cont, {request, response}}
    end
  end

  defp mark_truncated(response), do: Req.Response.put_private(response, :body_truncated, true)

  defp collectable?(response) do
    response.status in 200..299 and
      case content_type(response) do
        nil ->
          true

        type ->
          type in @html_content_types or text_content_type?(type) or generic_content_type?(type)
      end
  end

  defp generic_content_type?(type),
    do: type in ["", "application/octet-stream", "binary/octet-stream", "*/*"]

  defp text_content_type?(type) do
    String.starts_with?(type, "text/") or type in @text_content_types or
      String.ends_with?(type, "+json") or String.ends_with?(type, "+xml")
  end

  ## ------------------------------------------------------------------
  ## Rendering
  ## ------------------------------------------------------------------

  defp render(url, response, max_chars) do
    body =
      case classify(response.body, content_type(response), url) do
        {:markdown, text} -> text
        {:verbatim, text} -> text
        {:binary, label} -> "[binary content omitted: #{label}]"
      end

    {text, truncated_by_chars?} = truncate(body, max_chars)
    text = maybe_mark_raw_cap(text, truncated_by_chars?, response.truncated?, max_chars)

    "Fetched #{url} (HTTP #{response.status})\n\n#{text}"
  end

  # The character cap can bite before the byte cap (the usual case), but a page
  # of extremely bloated markup can be cut at the byte cap while still fitting
  # in `max_chars` — say so instead of silently handing back a partial page.
  defp maybe_mark_raw_cap(text, false, true, max_chars) do
    text <>
      "\n\n[truncated: the response body exceeded the #{raw_cap(max_chars)}-byte fetch limit]"
  end

  defp maybe_mark_raw_cap(text, _capped_by_chars, _raw_capped, _max_chars), do: text

  # Relative href/src values are resolved against the final URL so the model
  # gets absolute, followable links.
  defp classify(body, type, url) do
    cond do
      not is_nil(type) and type in @html_content_types ->
        {:markdown, HtmlToMarkdown.convert(body, base_url: url)}

      not is_nil(type) and text_content_type?(type) ->
        {:verbatim, valid_utf8(body)}

      is_nil(type) or generic_content_type?(type) ->
        sniff(body, url)

      true ->
        {:binary, type}
    end
  end

  defp sniff(body, url) do
    cond do
      HtmlToMarkdown.html?(body) -> {:markdown, HtmlToMarkdown.convert(body, base_url: url)}
      text_looking?(body) -> {:verbatim, valid_utf8(body)}
      true -> {:binary, "unknown content type"}
    end
  end

  defp text_looking?(body), do: String.valid?(body) and not String.contains?(body, <<0>>)

  # Non-UTF-8 payloads (a latin-1 page, a truncated multi-byte tail) are made
  # representable instead of dropped: invalid bytes become U+FFFD.
  defp valid_utf8(body) do
    if String.valid?(body), do: body, else: String.replace_invalid(body)
  end

  defp truncate(text, max_chars) do
    total = String.length(text)

    if total > max_chars do
      {String.slice(text, 0, max_chars) <>
         "\n\n[truncated: first #{max_chars} of ~#{total} characters]", true}
    else
      {text, false}
    end
  end

  ## ------------------------------------------------------------------
  ## Header helpers
  ## ------------------------------------------------------------------

  defp content_type(response) do
    case header(response, "content-type") do
      nil ->
        nil

      value ->
        value
        |> String.downcase()
        |> String.split(";")
        |> hd()
        |> String.trim()
    end
  end

  defp header(%{headers: headers}, name) do
    headers
    |> Req.Fields.get_values(name)
    |> List.first()
    |> case do
      nil -> nil
      value when is_binary(value) -> value
      value -> to_string(value)
    end
  end

  defp header(_response, _name), do: nil

  defp reason_phrase(status), do: Map.get(@reason_phrases, status, "")
end
