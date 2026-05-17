# ServerSentEvents

[![CI](https://github.com/benjreinhart/server_sent_events/actions/workflows/ci.yml/badge.svg)](https://github.com/benjreinhart/server_sent_events/actions/workflows/ci.yml)
[![License](https://img.shields.io/hexpm/l/server_sent_events.svg)](https://github.com/benjreinhart/server_sent_events/blob/main/LICENSE.md)
[![Version](https://img.shields.io/hexpm/v/server_sent_events.svg)](https://hex.pm/packages/server_sent_events)
[![Docs](https://img.shields.io/badge/api-docs-green.svg?style=flat)](https://hexdocs.pm/server_sent_events/readme.html)

Lightweight, ultra-fast Server Sent Event parser for Elixir.

This module parses according to the official [Server Sent Events specification](https://html.spec.whatwg.org/multipage/server-sent-events.html#parsing-an-event-stream) with a comprehensive [test suite](https://github.com/benjreinhart/server_sent_events/blob/main/test/server_sent_events/parser_test.exs). See [Behavior Boundary](#behavior-boundary) for more info.

## Installation

The package can be installed by adding `server_sent_events` to your list of dependencies in `mix.exs`:

```elixir
def deps do
  [
    {:server_sent_events, "~> 1.0.0"}
  ]
end
```

## Usage

Decode an enumerable of binary chunks with `ServerSentEvents.decode_stream/1`:

```elixir
events =
  [
    "event: message\n",
    "data: {\"complete\":true}\n\n"
  ]
  |> ServerSentEvents.decode_stream()
  |> Enum.to_list()

IO.inspect(events)
# [%{event: "message", data: "{\"complete\":true}"}]
```

The decoder keeps state across arbitrary chunk boundaries:

```elixir
events =
  [
    "event: mes",
    "sage\ndata: {\"complete\":",
    "true}\n\n"
  ]
  |> ServerSentEvents.decode_stream()
  |> Enum.to_list()

IO.inspect(events)
# [%{event: "message", data: "{\"complete\":true}"}]
```

Events are maps that always include `:data`, and may also include `:id`, `:event`, or `:retry`.
The `:id`, `:event`, and `:data` values are binaries. The `:retry` value is a non-negative
integer when present.

### Real world example using Req

Req can expose the response body as an enumerable with `into: :self`. That body can be passed through `ServerSentEvents.decode_stream/1`:

From there, callers typically filter event types and JSON-decode the `data` field.

```elixir
%Req.Response{status: 200, body: response_body} =
  Req.post!("https://api.anthropic.com/v1/messages",
    json: request,
    into: :self,
    headers: %{
      "x-api-key" => api_key(),
      "anthropic-version" => "2023-06-01",
      "anthropic-beta" => "adaptive-thinking-2026-01-28,effort-2025-11-24,max-effort-2026-01-24"
    }
  )

response_body
|> ServerSentEvents.decode_stream()
|> Stream.map(fn %{data: data} -> JSON.decode!(data) end)
|> Enum.each(&IO.inspect/1)

#  %{
#    "content_block" => %{"type" => "thinking", "signature" => "", "thinking" => ""},
#    "index" => 0,
#    "type" => "content_block_start"
#  }
#  %{
#    "delta" => %{"type" => "thinking_delta", "thinking" => "Now"},
#    "index" => 0,
#    "type" => "content_block_delta"
#  }
#  %{
#    "delta" => %{"type" => "thinking_delta", "thinking" => " I have a good understanding of the project. Let "},
#    "index" => 0,
#    "type" => "content_block_delta"
#  }
#
#  # etc...
#
#  %{"index" => 11, "type" => "content_block_stop"}
#  %{
#    "delta" => %{"stop_details" => nil, "stop_reason" => "tool_use", "stop_sequence" => nil},
#    "type" => "message_delta",
#    "usage" => %{
#      "cache_creation_input_tokens" => 2810,
#      "cache_read_input_tokens" => 14451,
#      "input_tokens" => 6,
#      "output_tokens" => 10528
#    }
#  }
```

## Behavior Boundary

This library decodes the event stream syntax and applies the field-level parsing rules from the
specification. In particular, `id` fields containing NULL are ignored, and `retry` fields are
emitted as integers only when they contain ASCII digits. Events that do not contain a `data`
field are suppressed.

It intentionally leaves EventSource state and connection behavior to the caller, including:

- Tracking, resetting, or applying `lastEventId`.
- Applying retry delays.
- Supplying a default event type such as `"message"`.
- Opening HTTP connections, reconnecting, or interpreting response headers.

This decoder also assumes the input stream is UTF-8. It does not validate UTF-8, reject malformed input, or perform replacement-character decoding.

## Benchmarking

Run the local benchmark with:

```sh
mix bench
```

The benchmark exercises both large complete payloads and large payloads that end with an incomplete trailing event, and reports execution time and memory usage.
