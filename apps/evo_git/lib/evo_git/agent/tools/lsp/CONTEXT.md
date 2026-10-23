# EvoGit.Agent.Tools.Lsp.Protocol — Pure LSP Wire Codec

## Intent
`EvoGit.Agent.Tools.Lsp.Protocol` (`protocol.ex`) is the PURE wire layer behind the `lsp` tool: JSON-RPC frame encoding/decoding over a raw byte stream, `file` URI conversion, and LSP result-shape normalization (diagnostics / hover / definition). It does no I/O, spawns no process and touches no port — the owning module `EvoGit.Agent.Tools.Lsp` (`../lsp.ex`) spawns the user-configured language server and drives these functions from its own `receive` loop, so every function here is a total transformation a unit test can exercise without a server.

## Routing Table
- The ONLY consumer is `../lsp.ex` (the `lsp` tool — spawn, stdio, `receive` loop, timeouts, teardown). Tool-level detail (schema, `[lsp]` config, bounds, test seam): `../CONTEXT.md` → "Language Server (`lsp`)".

## API Surface

| Function | Description |
|---|---|
| `encode/1` (`:42`) | Encodes ONE JSON-RPC message as a complete LSP frame — `"Content-Length: <byte_size(body)>\r\n\r\n" <> Jason.encode!(message)` — ready for `Port.command/2` |
| `request/3` (`:49`) | Encodes an id-bearing JSON-RPC REQUEST frame (`%{"jsonrpc" => "2.0", "id" => id, "method" => method, "params" => params}`) — the server replies to it |
| `notification/2` (`:55`) | Encodes a JSON-RPC NOTIFICATION frame (no `id`) — the server never replies (`initialized`, `textDocument/didOpen`, `textDocument/didClose`, `exit`) |
| `decode/1` (`:68`) | The incremental frame parser: `{:ok, message, rest}` for exactly one complete frame, `:more` while a frame is still incomplete, `{:error, reason}` when the stream can no longer be a valid frame |
| `uri_for/1` (`:158`) | Absolute path → `"file://" <> percent_encode(path)` |
| `path_from_uri/1` (`:166`) | `file://` URI → path (percent-decoded, the Windows drive-slash case de-slashed); any other scheme passes through |
| `severity/1` (`:218`) | LSP diagnostic severity integer → `"error"` (1) / `"warning"` (2) / `"info"` (3) / `"hint"` (4); anything else → `"error"` |
| `diagnostics_lines/2` (`:235`) | `publishDiagnostics` params + display path → one `"<path>:<line>:<col> <severity> <message>"` string per diagnostic (1-based); `[]` for a non-map / non-binary input |
| `hover_text/1` (`:268`) | `textDocument/hover` result → plain text (unwraps `%{"kind","value"}`, `%{"contents"}`, `%{"value"}` and lists joined by a blank line); unknown shapes → `""` |
| `locations/1` (`:290`) | `textDocument/definition` result → `[%{path:, line:, column:}]` (1-based), handling a single `Location`, a `Location` list, and `LocationLink` (`targetUri` + `targetSelectionRange`/`targetRange`); non-matches → `[]` |

## Constraints
- **Pure**: no I/O, no processes, no ports, no config reads, no `receive`. Every function is total for its documented inputs and never raises on a malformed server response.
- **Framing is the ASCII LSP base protocol, never `packet: 4`**: a header block (`Content-Length: <bytes>\r\n`, optional `Content-Type`, blank line) followed by a byte-counted JSON body. An Erlang port opened with `packet: 4` would expect a big-endian 32-bit length prefix, so the tool must decode frames itself through `decode/1`.
- **Frame-buffer bound**: `@max_buffer_bytes` = 4 MiB (`:35`). A buffer above it, a missing/non-numeric `Content-Length`, a non-object JSON body, or invalid JSON all produce `{:error, reason}` — the buffer never grows without bound, protecting the calling agent process.
- **Coordinates**: LSP is 0-based; every rendered output (`diagnostics_lines/2`, `locations/1`) is 1-based, matching the model-facing tool contract.
- No state and no caching — each call is a fresh parse, which is why the `lsp` tool can safely use one disposable server per invocation.
