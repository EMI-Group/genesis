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
  """

  import ExUnit.Callbacks, only: [on_exit: 1]

  @doc """
  Starts the server and returns `%{port: port, url: "http://127.0.0.1:<port>"}`
  (`port` is an OS-assigned ephemeral port).
  """
  @spec start!(non_neg_integer(), binary()) :: %{port: non_neg_integer(), url: String.t()}
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
    acceptor = spawn(fn -> accept_loop(listen, status, body) end)

    on_exit(fn ->
      Process.exit(acceptor, :kill)
      :gen_tcp.close(listen)
    end)

    %{port: port, url: "http://127.0.0.1:#{port}"}
  end

  defp accept_loop(listen, status, body) do
    case :gen_tcp.accept(listen) do
      {:ok, socket} ->
        serve(socket, status, body)
        :gen_tcp.close(socket)
        accept_loop(listen, status, body)

      {:error, _reason} ->
        :ok
    end
  end

  # Reads the request headers, drains the request body, then replies. Draining
  # the body first avoids closing the socket on unread data (which could RST
  # the response before the client reads it).
  defp serve(socket, status, body) do
    {headers, rest} = read_headers(socket, "")
    length = content_length(headers)
    drain_body(socket, byte_size(rest), length)
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
