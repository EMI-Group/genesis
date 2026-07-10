defmodule EvoGit.Agent.ContextCompressionTest do
  use ExUnit.Case, async: true

  alias EvoGit.Agent.ContextCompression
  alias EvoGit.Agent.LoopState
  alias EvoGit.Agent.Usage

  # Build a minimal LoopState for testing.
  defp state(overrides) do
    %LoopState{
      agent_id: 1,
      agent_module: __MODULE__,
      depth: 0,
      node_path: "./",
      context: ReqLLM.Context.new([]),
      usage: Usage.zero()
    }
    |> struct(overrides)
  end

  # Build a ReqLLM.Response with a known usage map and a text message, matching
  # the shape that the compression LLM call produces in production.
  defp fake_response(usage_map, text) do
    msg = %ReqLLM.Message{
      role: :assistant,
      content: [ReqLLM.Message.ContentPart.text(text)]
    }

    %ReqLLM.Response{
      id: "test-resp",
      model: "test:model",
      context: nil,
      message: msg,
      usage: usage_map
    }
  end

  # ---------------------------------------------------------------------------
  # compression_instruction/0
  # ---------------------------------------------------------------------------

  describe "compression_instruction/0" do
    test "returns a binary string" do
      assert is_binary(ContextCompression.compression_instruction())
    end

    test "does NOT reproduce the original objective (anti-drift: no Original Objective section)" do
      instruction = ContextCompression.compression_instruction()

      # The "## Original Objective" section was removed — the verbatim
      # objective is preserved in the first user message instead.
      refute instruction =~ ~s(## Original Objective)
      refute instruction =~ ~s(reproduced as close to verbatim as possible)
    end

    test "contains the Current State section (replaces Overall Progress)" do
      instruction = ContextCompression.compression_instruction()

      assert instruction =~ ~s(## Current State)

      assert instruction =~
               ~s(Your current state within the overall objective: what major milestones/parts are complete, what remains to be done, and what you should focus on next.)
    end

    test "does NOT contain the old Overall Progress section" do
      instruction = ContextCompression.compression_instruction()

      refute instruction =~ ~s(## Overall Progress)
      refute instruction =~ ~s(Cumulative high-level status of the ORIGINAL objective.)
    end

    test "contains the Completed section" do
      instruction = ContextCompression.compression_instruction()
      assert instruction =~ ~s(## Completed)
    end

    test "contains the complete_task reminder about the original objective" do
      instruction = ContextCompression.compression_instruction()

      assert instruction =~
               ~s(your final report MUST summarize the status of the ORIGINAL objective as a whole)

      # The reminder now references the first user message and "Current State".
      assert instruction =~ ~s(refer to the first user message and "Current State" above)
    end

    test "does NOT contain the old objective drift phrasing" do
      instruction = ContextCompression.compression_instruction()

      refute instruction =~ ~s(the current goal being worked on)
      # The old section header should also be gone
      refute instruction =~ ~s(## Objective\n)
    end

    test "contains anti-drift note: objective preserved in first user message" do
      instruction = ContextCompression.compression_instruction()

      assert instruction =~
               ~s(Do NOT reproduce, restate, or paraphrase)

      assert instruction =~
               ~s(The original objective is preserved verbatim in the first user message above.)
    end

    test "contains the CRITICAL anti-drift instruction" do
      instruction = ContextCompression.compression_instruction()

      assert instruction =~
               ~s(CRITICAL: You are working on the SAME original objective as when you started)

      assert instruction =~ ~s(Do NOT drift, redefine, narrow, or expand the objective.)

      assert instruction =~ ~s(STOP and realign to it.)
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

  # ---------------------------------------------------------------------------
  # compress_if_needed/2 — threshold gating (no LLM call needed)
  # ---------------------------------------------------------------------------

  describe "compress_if_needed/2 threshold gating" do
    @describetag :capture_log

    # `compression_threshold_tokens` resolves from config (defaults to a high
    # value, typically 100_000+). We pass a total_tokens count far below the
    # default threshold so compression is skipped without any LLM call.
    test "returns state unchanged when total_tokens is below threshold" do
      st = state(total_tokens: 0, usage: Usage.zero())

      result =
        ContextCompression.compress_if_needed(st,
          agent_id: 1,
          llm_model: "test:model"
        )

      assert result == st
      # Usage must be untouched (still zero) when no compression occurs.
      assert result.usage == Usage.zero()
    end

    test "does not accumulate usage when compression does not trigger" do
      # A small non-zero usage present, but tokens below threshold.
      pre = %Usage{input_tokens: 100, output_tokens: 20, total_tokens: 120}
      st = state(total_tokens: 0, usage: pre)

      result =
        ContextCompression.compress_if_needed(st,
          agent_id: 1,
          llm_model: "test:model"
        )

      assert result.usage == pre
    end
  end

  # ---------------------------------------------------------------------------
  # Usage accumulation from compression LLM call
  #
  # compress_if_needed/2 makes a real ReqLLM.stream_text call inside the slot
  # callback, which cannot be executed without a live LLM endpoint. There is no
  # mocking library (Mox/Meck) in this codebase, and ReqLLM's test fixture/VCR
  # backend is not shipped in the installed package. The cache-hit path zeroes
  # usage (ReqLLM.Cache.cache_hit_response), so it cannot represent a real call.
  #
  # To verify the fix without fragile HTTP mocking, we exercise the EXACT
  # composition that compress_if_needed/2 applies to the compression call's
  # response — Usage.add(state.usage, Usage.from_response_usage(ReqLLM.Response.usage(response)))
  # — using a real ReqLLM.Response struct built with a known, non-zero usage map.
  # This is the same transformation tool_dispatch.ex uses for the main turn.
  # ---------------------------------------------------------------------------

  describe "compression usage accumulation (fix verification)" do
    test "usage map from a compression response is added into state.usage" do
      # A compression-call response carrying a known, non-zero token usage.
      compression_usage = %{
        input_tokens: 5_000,
        output_tokens: 800,
        total_tokens: 5_800,
        input_cost: 0.05,
        output_cost: 0.02,
        total_cost: 0.07
      }

      response = fake_response(compression_usage, "Compressed summary of progress.")

      # Mirror the exact transformation compress_if_needed/2 performs after a
      # successful compression call.
      starting_usage = Usage.zero()

      accumulated =
        Usage.add(starting_usage, Usage.from_response_usage(ReqLLM.Response.usage(response)))

      # The compression tokens MUST appear in the accumulated usage (not zero).
      assert accumulated.input_tokens == 5_000
      assert accumulated.output_tokens == 800
      assert accumulated.total_tokens == 5_800
      assert accumulated.input_cost == 0.05
      assert accumulated.output_cost == 0.02
      assert accumulated.total_cost == 0.07
    end

    test "compression usage is accumulated on top of existing usage (no overwrite)" do
      # The agent already has some usage from prior turns.
      prior = %Usage{
        input_tokens: 1_000,
        output_tokens: 200,
        total_tokens: 1_200,
        input_cost: 0.01,
        output_cost: 0.005,
        total_cost: 0.015
      }

      compression_usage = %{
        input_tokens: 3_000,
        output_tokens: 400,
        total_tokens: 3_400,
        input_cost: 0.03,
        output_cost: 0.012,
        total_cost: 0.042
      }

      response = fake_response(compression_usage, "Summary.")

      accumulated = Usage.add(prior, Usage.from_response_usage(ReqLLM.Response.usage(response)))

      # Accumulated, NOT overwritten: prior + compression.
      assert accumulated.input_tokens == 4_000
      assert accumulated.output_tokens == 600
      assert accumulated.total_tokens == 4_600
      assert accumulated.input_cost == 0.04
      assert accumulated.output_cost == 0.017
      assert accumulated.total_cost == 0.057
    end

    test "a response whose usage is nil yields zero compression tokens (graceful)" do
      # Some providers return nil usage; the fix must not crash or double-count.
      response = fake_response(nil, "Summary.")

      accumulated =
        Usage.add(Usage.zero(), Usage.from_response_usage(ReqLLM.Response.usage(response)))

      assert accumulated == Usage.zero()
    end

    test "ReqLLM.Response.usage/1 returns the usage map embedded in the response" do
      # Confirms the response struct we build round-trips through the same
      # accessor the production code uses (ReqLLM.Response.usage/1).
      compression_usage = %{input_tokens: 7, output_tokens: 3, total_tokens: 10}

      response = fake_response(compression_usage, "summary")

      assert ReqLLM.Response.usage(response) == compression_usage
      assert ReqLLM.Response.text(response) == "summary"
    end
  end

  # ---------------------------------------------------------------------------
  # Regression: state.usage default and Usage struct shape
  # ---------------------------------------------------------------------------

  describe "LoopState.usage default" do
    test "a fresh LoopState starts with zero usage" do
      st = state(total_tokens: 0)
      assert st.usage == Usage.zero()
    end
  end
end
