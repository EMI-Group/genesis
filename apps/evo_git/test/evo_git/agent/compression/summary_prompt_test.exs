defmodule EvoGit.Agent.Compression.SummaryPromptTest do
  @moduledoc """
  `async: true` — pure text assertions on `EvoGit.Agent.Compression.SummaryPrompt`.
  No I/O, no global state, no scheduler, no network.
  """

  use ExUnit.Case, async: true

  alias EvoGit.Agent.Compression.SummaryPrompt

  @headers [
    "## Primary Request and Intent",
    "## Key Technical Concepts",
    "## Files and Code",
    "## Errors and Fixes",
    "## Pending Jobs",
    "## Current Work",
    "## Next Step",
    "## Critical Context"
  ]

  @merge_clause "An earlier checkpoint summary is included below"

  describe "sections/0" do
    test "returns the eight section headers in order" do
      assert SummaryPrompt.sections() == @headers
    end
  end

  describe "open_tag/0 and close_tag/0" do
    test "are the compacted-summary delimiters" do
      assert SummaryPrompt.open_tag() == "<compacted-summary>"
      assert SummaryPrompt.close_tag() == "</compacted-summary>"
    end
  end

  describe "instruction/1 — section shape" do
    test "contains every section header exactly once" do
      instruction = SummaryPrompt.instruction()

      for header <- @headers do
        assert length(String.split(instruction, header)) == 2,
               "expected #{inspect(header)} exactly once in the instruction"
      end
    end

    test "lists the section headers in order" do
      instruction = SummaryPrompt.instruction()

      indexes =
        Enum.map(@headers, fn header ->
          {index, _} = :binary.match(instruction, header)
          index
        end)

      assert indexes == Enum.sort(indexes)
      assert indexes == Enum.uniq(indexes)
    end

    test "names what belongs in each section (one line per section)" do
      instruction = SummaryPrompt.instruction()

      # Each header is immediately followed by its own (non-blank) guidance line.
      for header <- @headers do
        [_, rest] = String.split(instruction, header, parts: 2)
        ["", guidance_line | _] = String.split(rest, "\n")
        assert String.trim(guidance_line) != "", "expected guidance under #{inspect(header)}"
      end
    end

    test "wraps the whole instruction in the context_compression block" do
      instruction = SummaryPrompt.instruction()

      assert String.starts_with?(String.trim_leading(instruction), "<context_compression>")

      assert instruction |> String.trim_trailing() |> String.ends_with?("</context_compression>")
    end
  end

  describe "instruction/1 — explicit rules" do
    test "states the verbatim-preservation rule for file paths, commands and errors" do
      instruction = SummaryPrompt.instruction()

      assert instruction =~
               "Preserve exact file paths, commands, function names and error strings VERBATIM"

      assert instruction =~ "never paraphrase them"
    end

    test "forbids mentioning the summarisation request or the checkpoint mechanism" do
      instruction = SummaryPrompt.instruction()

      assert instruction =~ "Do not mention this summarisation request, the checkpoint mechanism"
    end

    test "forbids reproducing the original objective" do
      instruction = SummaryPrompt.instruction()

      assert instruction =~ "Do not reproduce the original objective"
      assert instruction =~ "first user message"
    end
  end

  describe "instruction/1 — background shell jobs" do
    test "the Pending Jobs guidance covers work started but not finished, one line each" do
      instruction = SummaryPrompt.instruction()

      [_before, rest] = String.split(instruction, "## Pending Jobs", parts: 2)
      ["", guidance_line | _] = String.split(rest, "\n")
      guidance_line = String.trim(guidance_line)

      assert guidance_line != ""
      assert guidance_line =~ "started but not finished"
      assert guidance_line =~ "one line each"
    end

    test "the Pending Jobs guidance defers background shell jobs to the runtime" do
      instruction = SummaryPrompt.instruction()

      [_before, rest] = String.split(instruction, "## Pending Jobs", parts: 2)
      ["", guidance_line | _] = String.split(rest, "\n")
      guidance_line = String.trim(guidance_line)

      assert guidance_line =~ "Background shell jobs are tracked automatically by the runtime"
      assert guidance_line =~ "re-injected there"
      assert guidance_line =~ "never duplicate them here"
      # No job bookkeeping is duplicated into the checkpoint.
      refute guidance_line =~ "exact job id"
      refute guidance_line =~ "command/label"
      refute guidance_line =~ "STILL-RUNNING"
    end

    test "does not mandate listing background jobs under Pending Jobs" do
      instruction = SummaryPrompt.instruction()

      refute instruction =~ "MUST be listed under Pending Jobs"
      refute instruction =~ "exact job id"
      refute instruction =~ "never drop a running job"
      refute instruction =~ "a finished job needs only a one-line outcome"
    end
  end

  describe "instruction/1 — prior summary merging" do
    test "omits the merge clause and the prior text when no prior summary is given" do
      instruction = SummaryPrompt.instruction()

      refute instruction =~ @merge_clause
      refute instruction =~ "<prior-checkpoint-summary>"
    end

    test "blank prior summaries produce exactly instruction(nil)" do
      for blank <- [nil, "", "   ", "\n\t  \n"] do
        assert SummaryPrompt.instruction(blank) == SummaryPrompt.instruction(nil)
      end
    end

    test "a non-blank prior summary adds the merge clause and the prior text verbatim" do
      prior = "Turn 3: rewrote apps/evo_git/lib/evo_git/agent/compression/checkpoint.ex"
      instruction = SummaryPrompt.instruction(prior)

      assert instruction =~ @merge_clause
      assert instruction =~ "keep every still-relevant fact from it"
      assert instruction =~ prior
      assert instruction =~ "<prior-checkpoint-summary>"
      assert instruction =~ "</prior-checkpoint-summary>"
    end

    test "the prior summary is trimmed but otherwise preserved" do
      instruction = SummaryPrompt.instruction("  the prior fact  ")

      assert instruction =~ "the prior fact"
      refute instruction =~ "  the prior fact  "
    end

    test "the merge block never uses the checkpoint delimiters" do
      instruction = SummaryPrompt.instruction("prior fact")

      # A summarisation request must never look like a CHECKPOINT message
      # (`EvoGit.Agent.Compression.Checkpoint.checkpoint?/1` keys off both tags).
      refute instruction =~ SummaryPrompt.open_tag()
      refute instruction =~ SummaryPrompt.close_tag()
    end

    test "the section headers and rules survive a prior summary being merged" do
      instruction = SummaryPrompt.instruction("prior fact")

      for header <- @headers do
        assert length(String.split(instruction, header)) == 2
      end

      assert instruction =~ "Do not mention this summarisation request"
    end
  end
end
