defmodule EvoGit.Agent.CompletionProtocol do
  @moduledoc """
  Pure classifier for one LLM turn's outcome — the `dsh`-aligned completion
  protocol.

  A reference harness (DeepSeek Harness / Claude-Code shaped, i.e. the training
  distribution) ends a turn when the model STOPS calling tools: the assistant's
  text IS the answer. `classify/1` therefore reports three outcomes:

    * `{:tool_calls, calls}` — the turn continues with tool execution (the model
      may still call `complete_task` explicitly, or delegate, or read a file).
    * `{:text_reply, text}` — ZERO tool calls with usable text: an IMPLICIT
      COMPLETION. `EvoGit.Agent.ToolDispatch` turns that text into the same
      `%EvoGit.Agent.Result{}` an explicit `complete_task` call would produce
      (same post-auto-commit `commit_sha`, same usage, same git note / archive
      refs), so every downstream consumer — scheduler result handling,
      `Runtime.Helpers.merge_and_report/3,4`, the `genesis/agent_*` review
      branch, task persistence, the dashboard — is unchanged.
    * `:empty` — zero tool calls and no usable text (e.g. a provider returning
      an empty message). That is still a protocol failure; it is recovered by
      exactly ONE nudge in `ToolDispatch.prompt_until_tools_or_limit/6` before
      the turn ends (`dsh` has the same `EMPTY_RESPONSE` recovery code).

  `complete_task` remains a supported, fully functional, OPTIONAL tool: both
  routes finish the same way, and the explicit route keeps its dirty-workspace
  gate, archive refs and git note.

  Text is read through `ReqLLM.Response.text/1`, which filters `:text` content
  parts ONLY — a streamed reply whose content is `[text, thinking]` therefore
  never promotes the reasoning text to the agent's result.

  ## Totality

  Both functions are TOTAL over any input term. `ReqLLM.Response.tool_calls/1` is
  reached only for a `%ReqLLM.Response{}` whose message is a `%ReqLLM.Message{}`
  (its own struct-only shape), and `ReqLLM.Response.text/1` additionally requires
  that message's `:content` to be a LIST — the shape its `Enum.filter/2` over the
  content parts needs. Every other shape — a nil or missing message, `content:
  nil`, or any non-list content — takes the "nothing usable" path: `report_text/1`
  returns `:empty` and `classify/1` returns `:empty` (unless real tool calls are
  present, which still win), never `Protocol.UndefinedError` /
  `FunctionClauseError`.
  """

  @doc """
  Classifies one LLM response into the turn outcome.

  Returns `{:tool_calls, [ReqLLM.ToolCall.t()]}` when the assistant produced any
  tool call, `{:text_reply, raw_text}` when it produced none but did produce
  non-blank text, or `:empty` when it produced neither.

  `raw_text` is returned VERBATIM (not trimmed) so it becomes the agent's report
  byte-for-byte as the model wrote it; blankness is judged after trimming.

  TOTAL: every input without tool calls — including a nil or missing message,
  `content: nil` and any non-list content — classifies as `:empty`. This function
  never raises.
  """
  @spec classify(term()) ::
          {:tool_calls, [ReqLLM.ToolCall.t()]} | {:text_reply, String.t()} | :empty
  def classify(response) do
    case tool_calls(response) do
      [] -> to_outcome(report_text(response))
      calls when is_list(calls) -> {:tool_calls, calls}
    end
  end

  @doc """
  The assistant's usable text, or `:empty` when it wrote nothing usable.

  Returns `{:ok, raw_text}` for any non-blank text; a nil message, a reply
  carrying only `:thinking` parts, `content: nil` and any other non-list content
  all yield `:empty`. TOTAL: this function never raises.
  """
  @spec report_text(term()) :: {:ok, String.t()} | :empty
  def report_text(response) do
    case text(response) do
      text when is_binary(text) ->
        if String.trim(text) == "", do: :empty, else: {:ok, text}

      _ ->
        :empty
    end
  end

  # `ReqLLM.Response.tool_calls/1` is struct-only: it matches on the response and
  # message shapes (never on `:content`), so the gate here is exactly that shape
  # — a plain map, a nil/missing message or any other non-`%ReqLLM.Message{}`
  # value must not raise `FunctionClauseError`, and tool calls still win.
  defp tool_calls(%ReqLLM.Response{message: %ReqLLM.Message{}} = response) do
    ReqLLM.Response.tool_calls(response)
  end

  defp tool_calls(_not_a_well_formed_response), do: []

  # Same shape gate for the text read: `ReqLLM.Response.text/1` enumerates the
  # content parts, so a non-list `:content` must never reach it.
  defp text(%ReqLLM.Response{message: %ReqLLM.Message{} = message} = response)
       when is_list(message.content) do
    ReqLLM.Response.text(response)
  end

  defp text(_not_a_well_formed_response), do: nil

  defp to_outcome({:ok, text}), do: {:text_reply, text}
  defp to_outcome(:empty), do: :empty
end
