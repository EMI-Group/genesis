defmodule EvoGit.TestLlmServer do
  @moduledoc """
  Minimal raw-TCP HTTP/1.1 server that answers EVERY request with a fixed
  status + JSON body — the error-path LLM harness used by
  `agent/tool_dispatch_retry_slot_test.exs`.

  Handing an agent a model spec whose `base_url` points at this server makes
  ReqLLM stream a real HTTP request against it and surface a genuine
  `%ReqLLM.Error.API.Request{}` (e.g. `status: 402` with an
  `{"error": {"message": "Insufficient Balance"}}` body), so the LLM retry
  loop's error CLASSIFICATION can be exercised end-to-end without any network
  access, mocks, or VCR fixtures.

  One connection at a time — the retry loop issues attempts sequentially and
  every response carries `connection: close`. Start it from a test process;
  `start!/2` registers an `on_exit` that closes the listener and kills the
  acceptor.

  The server also keeps an additive request counter (a `:counters` object
  created by `start!/2`, incremented exactly once per accepted HTTP request and
  returned in the start map). Read it with `request_count/1` — useful for
  asserting how many attempts were actually issued (e.g. the LLM retry loop
  hitting the server N times).
  """

  import ExUnit.Callbacks, only: [on_exit: 1]

  @doc """
  Starts the server and returns
  `%{port: port, url: "http://127.0.0.1:<port>", counters: counters}`
  (`port` is an OS-assigned ephemeral port, `counters` the request counter
  handle read by `request_count/1`).
  """
  @spec start!(non_neg_integer(), binary()) :: %{
          port: non_neg_integer(),
          url: String.t(),
          counters: :counters.counters_ref()
        }
  def start!(status, body) when is_integer(status) and is_binary(body) do
    {:ok, listen} =
      :gen_tcp.listen(0, [
        :binary,
        packet: :raw,
        active: false,
        reuseaddr: true,
        ip: {127, 0, 0, 1}
      ])

    {:ok, port} = :inet.port(listen)
    counters = :counters.new(1, [:atomics])
    acceptor = spawn(fn -> accept_loop(listen, status, body, counters) end)

    on_exit(fn ->
      Process.exit(acceptor, :kill)
      :gen_tcp.close(listen)
    end)

    %{port: port, url: "http://127.0.0.1:#{port}", counters: counters}
  end

  @doc """
  Returns the number of HTTP requests served so far by the server described by
  `server` (the map returned by `start!/2`).
  """
  @spec request_count(%{counters: :counters.counters_ref()}) :: non_neg_integer()
  def request_count(%{counters: counters}), do: :counters.get(counters, 1)

  defp accept_loop(listen, status, body, counters) do
    case :gen_tcp.accept(listen) do
      {:ok, socket} ->
        serve(socket, status, body, counters)
        :gen_tcp.close(socket)
        accept_loop(listen, status, body, counters)

      {:error, _reason} ->
        :ok
    end
  end

  # Reads the request headers, drains the request body, then replies. Draining
  # the body first avoids closing the socket on unread data (which could RST
  # the response before the client reads it).
  defp serve(socket, status, body, counters) do
    {headers, rest} = read_headers(socket, "")
    length = content_length(headers)
    drain_body(socket, byte_size(rest), length)
    :counters.add(counters, 1, 1)
    :gen_tcp.send(socket, response(status, body))
  end

  defp read_headers(socket, acc) do
    case String.split(acc, "\r\n\r\n", parts: 2) do
      [headers, rest] ->
        {headers, rest}

      [_incomplete] ->
        case :gen_tcp.recv(socket, 0, 5_000) do
          {:ok, data} -> read_headers(socket, acc <> data)
          {:error, _reason} -> {acc, ""}
        end
    end
  end

  defp content_length(headers) do
    case Regex.run(~r/content-length:\s*(\d+)/i, headers) do
      [_, length] -> String.to_integer(length)
      _ -> 0
    end
  end

  defp drain_body(_socket, have, length) when have >= length, do: :ok

  defp drain_body(socket, have, length) do
    case :gen_tcp.recv(socket, 0, 5_000) do
      {:ok, data} -> drain_body(socket, have + byte_size(data), length)
      {:error, _reason} -> :ok
    end
  end

  defp response(status, body) do
    [
      "HTTP/1.1 #{status} #{reason_phrase(status)}\r\n",
      "content-type: application/json\r\n",
      "content-length: #{byte_size(body)}\r\n",
      "connection: close\r\n",
      "\r\n",
      body
    ]
  end

  defp reason_phrase(402), do: "Payment Required"
  defp reason_phrase(429), do: "Too Many Requests"
  defp reason_phrase(500), do: "Internal Server Error"
  defp reason_phrase(_status), do: "Error"
end
