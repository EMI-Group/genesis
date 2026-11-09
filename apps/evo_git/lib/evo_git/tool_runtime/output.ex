defmodule EvoGit.ToolRuntime.Output do
  @moduledoc """
  Finalizes a tool's raw return value for the tool-result message.

  This is the RUNTIME side of the multimodal wrap boundary: a tool may return a
  plain binary, a `%EvoGit.Agent.ToolOutput{}` (text + optional images/audio) or
  an error tuple. `sanitize/3` wraps the raw return, runs the BINARY-ONLY
  sanitize → truncation-feedback pipeline on its text component and re-attaches
  the sanitized text (`ToolOutput.with_text/2`) so the media survive, collapsing
  an all-text output back to a plain binary.

  Delegation hints and the redundant-cd warning are deliberately NOT applied
  here — those are agent-side, process-dictionary-backed bookkeeping that runs
  in the PARENT agent process (`EvoGit.Agent.ToolDispatch`).
  """

  alias EvoGit.Agent.OutputSanitizer
  alias EvoGit.Agent.ToolOutput

  @doc """
  Wraps → sanitizes → appends truncation feedback → re-wraps one tool result.

  An all-text return (the shape every built-in tool produces today) comes back
  as the plain sanitized BINARY — byte-identical to the legacy path, never
  promoted to a `%ToolOutput{}`. A return carrying media comes back as a
  `%ToolOutput{}` from which the media parts are materialized exactly once at
  the message-construction site.

  `nil` (a tool that legitimately returns nothing) stays `nil`. Any other
  non-binary term is passed through verbatim to preserve the legacy
  pass-through sanitizer behavior — no built-in tool returns one (the
  `execute/5` contract is `String.t() | %ToolOutput.t() | {:error, reason}`,
  and the error path is stringified upstream).
  """
  @spec sanitize(term(), String.t(), map() | String.t() | nil) :: term()
  def sanitize(nil, _name, _args), do: nil

  def sanitize(result, name, args) when is_binary(result) or is_struct(result, ToolOutput) do
    output = ToolOutput.wrap(result)

    sanitized =
      output
      |> ToolOutput.text()
      |> sanitize_and_append_truncation_feedback(name, args)

    output
    |> ToolOutput.with_text(sanitized)
    |> collapse_all_text_output()
  end

  def sanitize(other, _name, _args), do: other

  # Runs the BINARY-ONLY sanitize → truncation-feedback pipeline on the text
  # component. Neither `OutputSanitizer` nor `TruncationFeedback` ever sees a
  # `%ToolOutput{}`.
  defp sanitize_and_append_truncation_feedback(text, name, args) do
    {sanitized, truncation_info} = OutputSanitizer.sanitize_and_truncate(text, name, args)

    EvoGit.Agent.TruncationFeedback.append_truncation_feedback(sanitized, truncation_info, name)
  end

  # A `%ToolOutput{}` carrying NO media collapses back to its plain text binary:
  # the all-text path must stay BYTE-IDENTICAL to the legacy string pipeline and
  # behave like a plain string for every downstream consumer. A media-carrying
  # output stays a struct.
  defp collapse_all_text_output(%ToolOutput{} = output) do
    if ToolOutput.media?(output), do: output, else: ToolOutput.text(output)
  end
end
