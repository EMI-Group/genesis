#!/usr/bin/env elixir
# Fake language server fixture for `EvoGit.Agent.Tools.Lsp` tests.
#
# Speaks the LSP base protocol over stdio with CANNED answers, so the `lsp` tool
# can be exercised end-to-end (spawn → initialize → didOpen → request → teardown)
# without any real language server, project compilation, or network:
#
#   initialize                       → capabilities {}
#   textDocument/didOpen             → textDocument/publishDiagnostics for the URI
#   textDocument/hover               → MarkupContent with HOVER_TEXT
#   textDocument/definition          → one Location (and a JSON null when asked at
#                                      line 1, column 1 → the "no definition" path)
#   shutdown                         → result null
#   exit (notification)              → halt 0
#
# Modes (first CLI argument):
#
#   (none)      normal canned behaviour
#   clean       same as normal, but publishDiagnostics carries an EMPTY list
#               (the "No diagnostics for <path>." path)
#   crash       write a line to stderr and exit 3 IMMEDIATELY, before reading
#               anything (the "server exits immediately" error path)
#   silent      never answer initialize (the initialize-timeout path)
#   malformed   answer initialize with a frame that has no Content-Length header
#
# Launched by the tests as `elixir fake_lsp_server.exs [mode]`. Deliberately
# dependency-free: a bare `elixir <script>` has no Mix deps on its code path, so
# JSON comes from OTP's stdlib `:json` module (OTP 27+).
defmodule FakeLspServer do
  @moduledoc false

  @hover_text "**def** hello_world() — fake hover from the fixture"
  @diagnostic_message "undefined function foo/0 (fake diagnostic from the fixture)"
  @definition_path "/fake/lib/definition.ex"

  def main do
    # Raw-byte stdio (what a real language server does). The default stdio device
    # is in `:unicode` encoding mode, so `IO.binwrite/2` would re-encode non-ASCII
    # UTF-8 (e.g. an em dash: E2 80 94 → C3 A2 C2 80 C2 94) and the frame's
    # `Content-Length` would no longer match the bytes on the wire.
    _ = :io.setopts(:standard_io, encoding: :latin1)

    case List.first(System.argv()) do
      "crash" -> crash()
      "silent" -> never_reply()
      "malformed" -> wait_for_initialize(fn _message -> send_malformed() end, :normal)
      "clean" -> wait_for_initialize(&send_initialize_result/1, :clean)
      _normal -> wait_for_initialize(&send_initialize_result/1, :normal)
    end
  end

  defp crash do
    IO.puts(:stderr, "fake-lsp: deliberate startup failure")
    System.halt(3)
  end

  # ── Handshake ─────────────────────────────────────────────────────────────

  defp wait_for_initialize(on_initialize, mode) do
    case read_message() do
      {:ok, %{"method" => "initialize"} = message} ->
        on_initialize.(message)
        loop(mode)

      {:ok, _other} ->
        wait_for_initialize(on_initialize, mode)

      :eof ->
        :ok
    end
  end

  defp send_initialize_result(message) do
    write(%{
      "jsonrpc" => "2.0",
      "id" => request_id(message),
      "result" => %{"capabilities" => %{"hoverProvider" => true, "definitionProvider" => true}}
    })
  end

  defp send_malformed do
    # A body WITHOUT the required Content-Length header block: the client must
    # report a malformed frame instead of hanging.
    body = encode(%{"jsonrpc" => "2.0", "id" => 1, "result" => %{}})
    IO.binwrite(:stdio, "Content-Type: application/vscode-jsonrpc\r\n\r\n" <> body)
  end

  # ── Message loop ──────────────────────────────────────────────────────────

  defp loop(mode) do
    case read_message() do
      {:ok, message} ->
        handle(message, mode)
        loop(mode)

      :eof ->
        :ok
    end
  end

  defp handle(%{"method" => "textDocument/didOpen", "params" => params}, mode) do
    uri = get_in(params, ["textDocument", "uri"]) || "file:///unknown.ex"

    write(%{
      "jsonrpc" => "2.0",
      "method" => "textDocument/publishDiagnostics",
      "params" => %{"uri" => uri, "diagnostics" => diagnostics(mode)}
    })
  end

  defp handle(%{"method" => "textDocument/hover", "id" => id}, _mode) when not is_nil(id) do
    write(%{
      "jsonrpc" => "2.0",
      "id" => id,
      "result" => %{"contents" => %{"kind" => "markdown", "value" => @hover_text}}
    })
  end

  defp handle(%{"method" => "textDocument/definition", "id" => id, "params" => params}, _mode)
       when not is_nil(id) do
    write(%{"jsonrpc" => "2.0", "id" => id, "result" => definition_result(params)})
  end

  defp handle(%{"method" => "shutdown", "id" => id}, _mode) when not is_nil(id) do
    write(%{"jsonrpc" => "2.0", "id" => id, "result" => :null})
  end

  defp handle(%{"method" => "exit"}, _mode), do: System.halt(0)

  # Any other request gets a null result so a client never waits forever.
  defp handle(%{"id" => id}, _mode) when not is_nil(id) do
    write(%{"jsonrpc" => "2.0", "id" => id, "result" => :null})
  end

  defp handle(_notification, _mode), do: :ok

  # ── Canned payloads ───────────────────────────────────────────────────────

  # `:clean` publishes an EMPTY batch — the "No diagnostics for <path>." path.
  defp diagnostics(:clean), do: []

  defp diagnostics(_mode) do
    [
      %{
        "range" => %{
          "start" => %{"line" => 2, "character" => 4},
          "end" => %{"line" => 2, "character" => 7}
        },
        "severity" => 1,
        "message" => @diagnostic_message
      },
      %{
        "range" => %{
          "start" => %{"line" => 6, "character" => 0},
          "end" => %{"line" => 6, "character" => 3}
        },
        "severity" => 2,
        "message" => "unused variable"
      }
    ]
  end

  # At 0-based line 0 / character 0 the fixture reports "no definition" (JSON
  # null), so the empty-result rendering is covered without a second mode.
  defp definition_result(%{"position" => %{"line" => 0, "character" => 0}}), do: :null

  defp definition_result(_params) do
    [
      %{
        "uri" => "file://" <> @definition_path,
        "range" => %{
          "start" => %{"line" => 9, "character" => 2},
          "end" => %{"line" => 9, "character" => 15}
        }
      }
    ]
  end

  defp request_id(%{"id" => id}), do: id
  defp request_id(_message), do: 1

  defp never_reply do
    case read_message() do
      {:ok, _message} -> never_reply()
      :eof -> :ok
    end
  end

  # ── Framing ───────────────────────────────────────────────────────────────

  defp write(message) do
    body = encode(message)
    IO.binwrite(:stdio, "Content-Length: #{byte_size(body)}\r\n\r\n" <> body)
  end

  # OTP's `:json` encodes to iodata; `:null` is the JSON null atom (a plain `nil`
  # atom would encode as the string "nil").
  defp encode(message), do: :erlang.iolist_to_binary(:json.encode(message))

  defp read_message do
    with {:ok, length} <- read_content_length(),
         {:ok, body} <- read_exactly(length) do
      decode(body)
    end
  end

  defp decode(body) do
    case :json.decode(body) do
      message when is_map(message) -> {:ok, message}
      _other -> :eof
    end
  rescue
    _error -> :eof
  end

  # Headers are read line by line ("\n"-terminated, so both "\r\n" and "\n" work);
  # a blank line ends the header block.
  defp read_content_length(headers \\ "") do
    case read_line() do
      {:ok, ""} -> parse_content_length(headers)
      {:ok, line} -> read_content_length(headers <> line <> "\n")
      :eof -> :eof
    end
  end

  defp parse_content_length(headers) do
    headers
    |> String.split("\n")
    |> Enum.find_value(fn line ->
      case String.split(line, ":", parts: 2) do
        [name, value] ->
          if String.downcase(String.trim(name)) == "content-length", do: String.trim(value)

        _other ->
          nil
      end
    end)
    |> case do
      nil ->
        :eof

      value ->
        case Integer.parse(value) do
          {length, _rest} -> {:ok, length}
          :error -> :eof
        end
    end
  end

  defp read_line(acc \\ "") do
    case IO.binread(:stdio, 1) do
      :eof -> :eof
      {:error, _reason} -> :eof
      "\n" -> {:ok, String.trim_trailing(acc, "\r")}
      byte when is_binary(byte) -> read_line(acc <> byte)
    end
  end

  # `IO.binread/2` may return fewer bytes than asked for on a pipe, so keep reading
  # until the whole body is in.
  defp read_exactly(count) when count <= 0, do: {:ok, ""}

  defp read_exactly(count) do
    case IO.binread(:stdio, count) do
      :eof -> :eof
      {:error, _reason} -> :eof
      data when is_binary(data) -> read_exactly(count, data)
    end
  end

  defp read_exactly(count, acc) do
    case count - byte_size(acc) do
      remaining when remaining <= 0 ->
        {:ok, acc}

      remaining ->
        case IO.binread(:stdio, remaining) do
          :eof -> :eof
          {:error, _reason} -> :eof
          data when is_binary(data) -> read_exactly(count, acc <> data)
        end
    end
  end
end

FakeLspServer.main()
