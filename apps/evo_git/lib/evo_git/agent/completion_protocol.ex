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
  """

  @doc """
  Classifies one LLM response into the turn outcome.

  Returns `{:tool_calls, [ReqLLM.ToolCall.t()]}` when the assistant produced any
  tool call, `{:text_reply, raw_text}` when it produced none but did produce
  non-blank text, or `:empty` when it produced neither.

  `raw_text` is returned VERBATIM (not trimmed) so it becomes the agent's report
  byte-for-byte as the model wrote it; blankness is judged after trimming.
  """
  @spec classify(ReqLLM.Response.t()) ::
          {:tool_calls, [ReqLLM.ToolCall.t()]} | {:text_reply, String.t()} | :empty
  def classify(response) do
    case ReqLLM.Response.tool_calls(response) do
      [] -> to_outcome(report_text(response))
      calls when is_list(calls) -> {:tool_calls, calls}
    end
  end

  @doc """
  The assistant's usable text, or `:empty` when it wrote nothing usable.

  Returns `{:ok, raw_text}` for any non-blank text (a nil message or a reply
  carrying only `:thinking` parts yields `:empty`).
  """
  @spec report_text(ReqLLM.Response.t()) :: {:ok, String.t()} | :empty
  def report_text(response) do
    case ReqLLM.Response.text(response) do
      text when is_binary(text) ->
        if String.trim(text) == "", do: :empty, else: {:ok, text}

      _ ->
        :empty
    end
  end

  defp to_outcome({:ok, text}), do: {:text_reply, text}
  defp to_outcome(:empty), do: :empty
end
