defmodule EvoDashWeb.AgentsLive.Render do
  @moduledoc """
  The ONE bounded rendering path for the Agents page's inspector history payloads.
  It exists to prevent an OOM: an unbounded `inspect(value, limit: :infinity)`
  allocates the whole printed tree, and a large tool payload or a deeply nested
  argument map can reach hundreds of megabytes.
  Bounding is two-dimensional — `:limit` caps collection depth/length and
  `:printable_limit` caps string/binary content — so neither a huge binary nor
  a deep nesting can blow up the render.
  The module is TOTAL: `inspect/2` with these options never raises for any term
  (maps, structs, invalid UTF-8 binaries, pids/refs, nil, functions) and always
  answers a binary, so there is deliberately no rescue wrapper.
  These values are user/model data, so they are never gettext-wrapped.
  """

  @doc """
  Renders a tool call's arguments map bounded by `inspect_opts/0`.
  """
  @spec args(term()) :: binary()
  def args(value), do: inspect(value, inspect_opts())

  @doc """
  Renders a whole history-entry payload bounded by `inspect_opts/0`.
  """
  @spec data(term()) :: binary()
  def data(value), do: inspect(value, inspect_opts())

  @doc """
  The shared `inspect/2` options every bounded render uses, so callers can reuse or
  extend them instead of re-deriving the bounds.
  """
  @spec inspect_opts() :: keyword()
  def inspect_opts, do: [limit: 200, printable_limit: 20_000, pretty: true]
end
