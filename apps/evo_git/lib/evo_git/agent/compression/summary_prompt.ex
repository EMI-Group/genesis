defmodule EvoGit.Agent.Compression.SummaryPrompt do
  @moduledoc """
  The prompt that turns a span of conversation into a checkpoint summary.

  Pure — no I/O, no state, no process dictionary. `instruction/1` returns the
  user-message TEXT handed to the summarising LLM; the caller owns the request.
  The eight section headers are fixed (`sections/0`) because the summary is read
  by the same agent that continues the task, so a stable shape keeps the
  checkpoint cheap to skim and stable across repeated compactions.

  `open_tag/0` / `close_tag/0` are the checkpoint delimiters used by
  `EvoGit.Agent.Compression.Checkpoint` — they live here so the prompt and the
  detector can never drift apart.
  """

  @sections [
    "## Primary Request and Intent",
    "## Key Technical Concepts",
    "## Files and Code",
    "## Errors and Fixes",
    "## Pending Jobs",
    "## Current Work",
    "## Next Step",
    "## Critical Context"
  ]

  # One short line per section, in the same order as `@sections`.
  @guidance %{
    "## Primary Request and Intent" =>
      "The user's original request in one or two lines, plus any scope change made since.",
    "## Key Technical Concepts" =>
      "Frameworks, APIs, protocols and design decisions that govern the work.",
    "## Files and Code" =>
      "Every file path touched or examined, with the exact signatures or code fragments that matter.",
    "## Errors and Fixes" =>
      "Failures hit, their exact error strings, and the fix that resolved them (or the workaround still standing).",
    "## Pending Jobs" =>
      "Work started but not finished, with its precise state and what blocks it.",
    "## Current Work" =>
      "The task in flight right now — what was just being edited, run, or investigated.",
    "## Next Step" => "The single next action to take, with its exact path or command.",
    "## Critical Context" =>
      "Constraints, preferences and facts that must not be lost, including anything a later step depends on."
  }

  @open_tag "<compacted-summary>"
  @close_tag "</compacted-summary>"

  @doc """
  The eight section headers, in the exact order the summary must use them.
  """
  @spec sections() :: [String.t()]
  def sections, do: @sections

  @doc """
  The checkpoint delimiter opening the retained summary text.
  """
  @spec open_tag() :: String.t()
  def open_tag, do: @open_tag

  @doc """
  The checkpoint delimiter closing the retained summary text.
  """
  @spec close_tag() :: String.t()
  def close_tag, do: @close_tag

  @doc """
  The summarisation instruction text.

  `prior_summary` is the previous checkpoint's retained text (see
  `EvoGit.Agent.Compression.Checkpoint.prior_summary/1`). When it is a non-blank
  binary the instruction asks the model to MERGE it — repeated compactions then
  accumulate facts instead of losing the earlier ones. When it is `nil` or
  blank, both the merge clause and the prior text are absent, so
  `instruction(nil)` and `instruction("   ")` are byte-identical.

  Deterministic and total — never raises.
  """
  @spec instruction(String.t() | nil) :: String.t()
  def instruction(prior_summary \\ nil) do
    """
    <context_compression>
    Review the conversation above and write a checkpoint summary of the work done so far, so that the same agent can continue the task from it without re-reading the transcript.

    Use EXACTLY these eight sections, in this order:

    #{sections_block()}

    RULES
    - Preserve exact file paths, commands, function names and error strings VERBATIM — never paraphrase them.
    - Do not mention this summarisation request, the checkpoint mechanism, or that anything was compacted: the summary is read by the same agent that continues the task, so write condensed working notes about the work, never a report about writing notes.
    - Do not reproduce the original objective — it stays verbatim in the first user message, which is retained.

    #{merge_section(prior_summary)}
    Output ONLY the eight sections above, with no preamble and no closing remarks.
    </context_compression>
    """
  end

  defp sections_block do
    Enum.map_join(@sections, "\n\n", fn header ->
      header <> "\n" <> Map.fetch!(@guidance, header)
    end)
  end

  defp merge_section(prior_summary) when is_binary(prior_summary) do
    case String.trim(prior_summary) do
      "" ->
        ""

      prior ->
        # Deliberately NOT wrapped in `@open_tag`/`@close_tag`: those two tags
        # identify a CHECKPOINT message (`Checkpoint.checkpoint?/1`), and this
        # instruction may legitimately sit in a message list. A distinct
        # delimiter keeps a summarisation request from being mistaken for a
        # checkpoint.
        """
        An earlier checkpoint summary is included below; merge it into the sections above and keep every still-relevant fact from it.

        <prior-checkpoint-summary>
        #{prior}
        </prior-checkpoint-summary>
        """
        |> String.trim_trailing()
    end
  end

  defp merge_section(_prior_summary), do: ""
end
