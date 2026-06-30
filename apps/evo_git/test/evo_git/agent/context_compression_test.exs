defmodule EvoGit.Agent.ContextCompressionTest do
  use ExUnit.Case, async: true

  alias EvoGit.Agent.ContextCompression

  describe "compression_instruction/0" do
    test "returns a binary string" do
      assert is_binary(ContextCompression.compression_instruction())
    end

    test "contains the Original Objective section" do
      instruction = ContextCompression.compression_instruction()

      assert instruction =~ ~s(## Original Objective)

      assert instruction =~
               ~s(The COMPLETE original objective/task from the user, reproduced as close to verbatim as possible.)
    end

    test "contains the Overall Progress section" do
      instruction = ContextCompression.compression_instruction()

      assert instruction =~ ~s(## Overall Progress)

      assert instruction =~
               ~s(Cumulative high-level status of the ORIGINAL objective.)
    end

    test "contains the Completed section" do
      instruction = ContextCompression.compression_instruction()
      assert instruction =~ ~s(## Completed)
    end

    test "contains the complete_task reminder about the original objective" do
      instruction = ContextCompression.compression_instruction()

      assert instruction =~
               ~s(your final report MUST summarize the status of the ORIGINAL objective as a whole)
    end

    test "does NOT contain the old objective drift phrasing" do
      instruction = ContextCompression.compression_instruction()

      refute instruction =~ ~s(the current goal being worked on)
      # The old section header should also be gone
      refute instruction =~ ~s(## Objective\n)
    end

    test "preserves all other structural sections" do
      instruction = ContextCompression.compression_instruction()

      assert instruction =~ ~s(<context_compression>)
      assert instruction =~ ~s(PRESERVE THESE EXACTLY)
      assert instruction =~ ~s(SUMMARIZE THESE)
      assert instruction =~ ~s(DISCARD COMPLETELY)
      assert instruction =~ ~s(## Key Findings)
      assert instruction =~ ~s(## Decisions Made)
      assert instruction =~ ~s(## SubAgents Dispatched)
      assert instruction =~ ~s(## Errors Encountered)
      assert instruction =~ ~s(## Next Steps)
      assert instruction =~ ~s(</context_compression>)
    end
  end
end
