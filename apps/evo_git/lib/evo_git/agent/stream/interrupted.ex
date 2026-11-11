defmodule EvoGit.Agent.Stream.Interrupted do
  @moduledoc """
  Raised INSIDE a `ReqLLM.StreamResponse.process_stream/2` callback to abort an in-flight stream.

  It is the per-chunk interrupt check of `EvoGit.Agent.Stream.Sink`: raising from `:on_chunk`
  stops the enumeration immediately, and `process_stream/2`'s own `rescue` converts the raise into
  its documented `{:error, %Interrupted{}}` return (`deps/req_llm/lib/req_llm/stream_response.ex`,
  `process_stream/2` + `finish_conversion/2`) instead of leaking the exception into the caller.
  The exchange treats that error like any other failed stream attempt, so an interrupt never
  corrupts the conversation or the session.
  """

  defexception [:reason]

  @impl Exception
  def message(%__MODULE__{reason: nil}), do: "stream interrupted"

  def message(%__MODULE__{reason: reason}) when is_binary(reason),
    do: "stream interrupted: " <> reason

  def message(%__MODULE__{reason: reason}), do: "stream interrupted: #{inspect(reason)}"
end
