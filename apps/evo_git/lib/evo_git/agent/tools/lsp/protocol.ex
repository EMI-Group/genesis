defmodule EvoGit.Agent.Tools.Lsp.Protocol do
  @moduledoc """
  Pure LSP wire helpers for the `lsp` tool: JSON-RPC frame encoding/decoding over
  a raw byte stream, `file` URI conversion, and result-shape normalization
  (diagnostics / hover / definition).

  Nothing here does I/O, spawns processes, or touches ports — the owning module
  `EvoGit.Agent.Tools.Lsp` spawns the user-configured language server and drives
  these functions from its `receive` loop, so every function is a plain total
  transformation that a unit test can exercise without a server.

  ## Framing (LSP base protocol, NOT a length-prefixed packet)

  Every message travels as one ASCII header block, a blank line, then a JSON body
  whose length is the BYTE count of the body:

      Content-Length: <bytes>\\r\\n
      Content-Type: application/vscode-jsonrpc; charset=utf-8\\r\\n (optional)
      \\r\\n
      {"jsonrpc":"2.0",...}

  Erlang ports therefore CANNOT be opened with `packet: 4` — that option is a
  big-endian 32-bit binary prefix, whereas LSP headers are ASCII text. `decode/1`
  is the incremental frame parser: `:more` while a frame is still incomplete,
  `{:ok, message, rest}` for exactly one complete frame, `{:error, reason}` when
  the stream can no longer be a valid frame (missing/non-numeric
  `Content-Length`, non-object JSON body, invalid JSON, or a buffer above
  `@max_buffer_bytes`).
  """

  # Hard cap on the frame buffer. A real Elixir language server never sends a
  # multi-megabyte single message; anything bigger means the stream is garbage
  # (or the server is echoing the whole project), and growing the buffer forever
  # would put the calling agent process at risk.
  @max_buffer_bytes 4 * 1024 * 1024

  @doc """
  Encodes one JSON-RPC message as a complete LSP frame (`Content-Length` header
  block + JSON body). Returns a binary ready for `Port.command/2`.
  """
  @spec encode(map()) :: binary()
  def encode(message) when is_map(message) do
    body = Jason.encode!(message)
    "Content-Length: #{byte_size(body)}\r\n\r\n" <> body
  end

  @doc "Encodes a JSON-RPC REQUEST frame (an id-bearing message expecting a response)."
  @spec request(integer(), String.t(), map()) :: binary()
  def request(id, method, params) when is_integer(id) and is_binary(method) do
    encode(%{"jsonrpc" => "2.0", "id" => id, "method" => method, "params" => params})
  end

  @doc "Encodes a JSON-RPC NOTIFICATION frame (no id — the server never replies to it)."
  @spec notification(String.t(), map()) :: binary()
  def notification(method, params) when is_binary(method) do
    encode(%{"jsonrpc" => "2.0", "method" => method, "params" => params})
  end

  @doc """
  Parses ONE frame from the front of `buffer`.

  Returns `{:ok, message, rest}` with the unparsed remainder, `:more` when the
  frame is incomplete (the caller must read more bytes and retry), or
  `{:error, reason}` with a single-sentence description of a stream that can no
  longer carry a valid frame.
  """
  @spec decode(binary()) :: {:ok, map(), binary()} | :more | {:error, String.t()}
  def decode(buffer) when is_binary(buffer) do
    if byte_size(buffer) > @max_buffer_bytes do
      {:error,
       "the language server streamed more than #{@max_buffer_bytes} bytes without completing a frame"}
    else
      case :binary.split(buffer, "\r\n\r\n") do
        [_incomplete] -> :more
        [header, rest] -> decode_body(header, rest)
      end
    end
  end

  defp decode_body(header, rest) do
    case content_length(header) do
      {:ok, length} when length > @max_buffer_bytes ->
        {:error,
         "the language server announced a #{length}-byte frame, above the " <>
           "#{@max_buffer_bytes}-byte limit"}

      {:ok, length} when byte_size(rest) >= length ->
        body = binary_part(rest, 0, length)
        remainder = binary_part(rest, length, byte_size(rest) - length)

        case Jason.decode(body) do
          {:ok, message} when is_map(message) ->
            {:ok, message, remainder}

          {:ok, other} ->
            {:error,
             "the language server sent a non-object JSON-RPC message (#{inspect(other) |> excerpt()})"}

          {:error, _reason} ->
            {:error, "the language server sent a body that is not valid JSON: #{excerpt(body)}"}
        end

      {:ok, _length} ->
        :more

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp content_length(header) do
    header
    |> String.split("\r\n")
    |> Enum.find_value(fn line ->
      case String.split(line, ":", parts: 2) do
        [name, value] ->
          if String.downcase(String.trim(name)) == "content-length", do: String.trim(value)

        _ ->
          nil
      end
    end)
    |> case do
      nil ->
        {:error, "malformed LSP frame — no Content-Length header in: #{excerpt(header)}"}

      value ->
        case Integer.parse(value) do
          {length, ""} when length >= 0 ->
            {:ok, length}

          _ ->
            {:error, "malformed LSP frame — invalid Content-Length #{inspect(value)}"}
        end
    end
  end

  # First ~120 characters of a (possibly huge/non-UTF-8) payload, for error text.
  defp excerpt(binary) when is_binary(binary) do
    binary
    |> String.slice(0, 120)
    |> String.replace(~r/[^\x20-\x7E]/u, " ")
  rescue
    # Non-UTF-8 body chunks are possible (a server writing to stdout by mistake).
    ArgumentError -> "(binary data)"
  end

  defp excerpt(other), do: inspect(other)

  # ── URIs ──────────────────────────────────────────────────────────────────

  @doc """
  Builds the `file://` URI for an absolute filesystem path, percent-encoding every
  byte that is not URI-unreserved and keeping `/` as the separator (so
  `file:///home/me/a.ex` round-trips through `path_from_uri/1`).
  """
  @spec uri_for(String.t()) :: String.t()
  def uri_for(path) when is_binary(path), do: "file://" <> percent_encode(path)

  @doc """
  Converts an LSP URI back to a filesystem path (percent-decoded, `file://`
  stripped, Windows drive letters de-slashed). Unknown schemes are returned
  unchanged so callers can still render them.
  """
  @spec path_from_uri(term()) :: String.t()
  def path_from_uri("file://" <> rest) do
    rest
    |> drop_authority()
    |> percent_decode()
    |> windows_drive()
  end

  def path_from_uri(uri) when is_binary(uri), do: uri
  def path_from_uri(other), do: to_string(other)

  defp percent_encode(path) do
    for <<byte <- path>>, into: "" do
      if unreserved?(byte),
        do: <<byte>>,
        else: "%" <> Base.encode16(<<byte>>, case: :upper)
    end
  end

  defp unreserved?(byte) when byte in ?a..?z or byte in ?A..?Z or byte in ?0..?9, do: true
  defp unreserved?(byte) when byte in [?/, ?-, ?., ?_, ?~], do: true
  defp unreserved?(_byte), do: false

  # `file:///abs/path` keeps its leading "/" once the scheme is stripped;
  # `file://host/path` (a remote authority) drops everything up to the first "/".
  defp drop_authority("/" <> _ = path), do: path

  defp drop_authority(<<drive, ?:, _::binary>> = path) when drive in ?a..?z or drive in ?A..?Z,
    do: "/" <> path

  defp drop_authority(path) do
    case String.split(path, "/", parts: 2) do
      [_authority, rest] -> "/" <> rest
      [_authority] -> "/"
    end
  end

  defp percent_decode(path) do
    URI.decode(path)
  rescue
    ArgumentError -> path
  end

  # `file:///C:/Users/x.ex` → "/C:/Users/x.ex" → "C:/Users/x.ex"
  defp windows_drive(<<?/, drive, ?:, ?/, rest::binary>>) when drive in ?a..?z or drive in ?A..?Z,
    do: <<drive, ?:, ?/, rest::binary>>

  defp windows_drive(path), do: path

  # ── Result-shape normalization ────────────────────────────────────────────

  @doc "Maps an LSP `DiagnosticSeverity` (1–4) onto the rendered word."
  @spec severity(term()) :: String.t()
  def severity(1), do: "error"
  def severity(2), do: "warning"
  def severity(3), do: "info"
  def severity(4), do: "hint"
  # The spec leaves an absent severity up to the client; treat it as an error so a
  # real problem is never silently downgraded. Non-integers land here too.
  def severity(_other), do: "error"

  @doc """
  Renders one line per diagnostic carried by a `textDocument/publishDiagnostics`
  params map: `<path>:<line>:<col> <severity> <message>`.

  Line/column are converted from LSP's 0-based positions to 1-based. Messages are
  flattened to a single line (a multi-line compiler message would otherwise break
  the one-line-per-diagnostic shape).
  """
  @spec diagnostics_lines(term(), String.t()) :: [String.t()]
  def diagnostics_lines(params, display_path) when is_map(params) and is_binary(display_path) do
    params
    |> Map.get("diagnostics", [])
    |> case do
      diagnostics when is_list(diagnostics) -> diagnostics
      _other -> []
    end
    |> Enum.flat_map(fn
      %{"range" => %{"start" => start}} = diagnostic ->
        [diagnostic_line(diagnostic, start, display_path)]

      _other ->
        []
    end)
  end

  def diagnostics_lines(_params, _display_path), do: []

  defp diagnostic_line(diagnostic, start, display_path) do
    line = position_number(Map.get(start, "line"))
    column = position_number(Map.get(start, "character"))
    severity = severity(Map.get(diagnostic, "severity"))
    message = flatten(Map.get(diagnostic, "message", ""))

    "#{display_path}:#{line}:#{column} #{severity} #{message}"
  end

  @doc """
  Extracts the display text from an LSP `textDocument/hover` result, unwrapping
  `MarkupContent` (`%{"kind", "value"}`), `MarkedString` maps/lists and plain
  strings. Returns `""` when there is nothing to show.
  """
  @spec hover_text(term()) :: String.t()
  def hover_text(nil), do: ""

  def hover_text(%{"kind" => _kind, "value" => value}), do: hover_text(value)
  def hover_text(%{"contents" => contents}), do: hover_text(contents)
  def hover_text(%{"value" => value}), do: hover_text(value)
  def hover_text(text) when is_binary(text), do: String.trim(text)

  def hover_text(parts) when is_list(parts) do
    parts
    |> Enum.map(&hover_text/1)
    |> Enum.reject(&(&1 == ""))
    |> Enum.join("\n\n")
  end

  def hover_text(_other), do: ""

  @doc """
  Normalizes an LSP `textDocument/definition` result — a single `Location`, a
  `Location[]`, or a `LocationLink[]` — into `[%{path, line, column}]` entries with
  1-based lines/columns. Anything unrecognizable yields `[]`.
  """
  @spec locations(term()) :: [%{path: String.t(), line: pos_integer(), column: pos_integer()}]
  def locations(nil), do: []

  def locations(result) when is_list(result), do: Enum.flat_map(result, &locations/1)

  def locations(%{"targetUri" => uri} = link) do
    range = Map.get(link, "targetSelectionRange") || Map.get(link, "targetRange")
    [location(uri, range)]
  end

  def locations(%{"uri" => uri} = location), do: [location(uri, Map.get(location, "range"))]

  def locations(_other), do: []

  defp location(uri, range) do
    start =
      case range do
        %{"start" => start} when is_map(start) -> start
        _other -> %{}
      end

    %{
      path: path_from_uri(uri),
      line: position_number(Map.get(start, "line")),
      column: position_number(Map.get(start, "character"))
    }
  end

  # LSP positions are 0-based; rendered positions are 1-based.
  defp position_number(index) when is_integer(index) and index >= 0, do: index + 1
  defp position_number(_other), do: 1

  defp flatten(message) when is_binary(message) do
    message |> String.replace(~r/\s+/u, " ") |> String.trim()
  rescue
    ArgumentError -> "(unprintable message)"
  end

  defp flatten(other), do: to_string(other)
end
