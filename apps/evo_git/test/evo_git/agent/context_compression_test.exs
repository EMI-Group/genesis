defmodule EvoGit.Agent.ContextCompressionTest do
  @moduledoc """
  `async: true` — exercises the pure `compression_instruction/0` text and the
  threshold-gating/usage-accumulation paths of `compress_if_needed/2` with
  in-memory `LoopState`/`ReqLLM.Response` values; the below-threshold gate
  performs only a read-only `EvoGit.Config.resolve/1` and never acquires an LLM
  slot. The context-tree refresh cases use per-test temp repo dirs (removed in
  `on_exit`) and the pure `ContextBuilder.refresh_first_user_message/2`. No
  shared/global state is mutated.

  The real compression LLM call (threshold overflow -> slot -> HTTP request) is
  NOT covered here — it needs a live endpoint and the global scheduler, so it
  lives in the sibling `context_compression_fail_fast_test.exs`, which drives it
  against `EvoGit.TestLlmServer` (a raw-TCP HTTP server).
  """

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
  # Usage accumulation from the compression LLM call (composition only)
  #
  # The compression call ITSELF is exercised end-to-end by the sibling
  # context_compression_fail_fast_test.exs, which drives a real HTTP request
  # through EvoGit.TestLlmServer (a raw-TCP HTTP server in
  # test/support/llm_server.ex — no mocks, no VCR): the HTTP 400 non-retryable
  # terminal, the 500 / 402 / refused-transport MatchError regressions, the
  # one-request + no-scheduler-backoff guarantees and slot release.
  #
  # The tests below are still worth keeping because they pin the EXACT
  # usage-accumulation composition — Usage.add(state.usage,
  # Usage.from_response_usage(ReqLLM.Response.usage(response))) — with no server
  # and no timing. A live endpoint cannot return a controlled, non-zero usage
  # map (the cache-hit path zeroes usage via
  # ReqLLM.Cache.cache_hit_response), whereas a hand-built ReqLLM.Response with
  # a known usage map drives the same transformation deterministically. This is
  # the same composition tool_dispatch.ex applies to the main turn.
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

  # ---------------------------------------------------------------------------
  # Context-tree refresh (compression re-injects a FRESH <context> block)
  #
  # The refresh function is public + pure, so it is driven directly against a
  # real temp repo dir: write a CONTEXT.md chain, build the initial first-user
  # message with the shared builders, EDIT the chain, refresh, and assert the
  # <context> block shows the edited content while the <objective> block stays
  # byte-identical. No LLM/HTTP harness is needed (the sibling
  # `context_compression_fail_fast_test.exs` covers the compression branch
  # shape end-to-end).
  # ---------------------------------------------------------------------------

  describe "ContextBuilder context-tree refresh" do
    alias EvoGit.Agent.ContextBuilder

    # Writes `<repo>/CONTEXT.md` (root) + `<repo>/<node_rel>/CONTEXT.md` and
    # returns the repo path; removed in `on_exit`.
    defp write_repo(node_rel, root_md, node_md) do
      repo =
        Path.join(
          System.tmp_dir!(),
          "evogit_ctx_refresh_#{System.unique_integer([:positive])}"
        )

      File.mkdir_p!(Path.join(repo, node_rel))
      File.write!(Path.join(repo, "CONTEXT.md"), root_md)
      File.write!(Path.join([repo, node_rel, "CONTEXT.md"]), node_md)
      on_exit(fn -> File.rm_rf!(repo) end)
      repo
    end

    # A LoopState carrying exactly the fields the refresh consumes.
    defp refresh_state(overrides) do
      state(
        Keyword.merge(
          [
            node_path: "./docs",
            repo_path: nil,
            parent_id: nil,
            repo_less: false,
            foreign_repos: [],
            repo_notes: nil,
            quality_level: nil,
            objective: "Do the thing.",
            attachments: nil
          ],
          overrides
        )
      )
    end

    # Mirrors the production first-user-message assembly (the SAME shared
    # helpers `Runner.do_run/2` uses): context block + objective block joined
    # with the delimiter, then the gated user message.
    defp original_first_user_message(st) do
      combined =
        [
          ContextBuilder.build_context_block(st),
          ContextBuilder.objective_block(st.objective)
        ]
        |> Enum.reject(&ContextBuilder.blank?/1)
        |> Enum.join("\n\n---\n\n")

      ContextBuilder.build_first_user_message(combined, st.parent_id, st.attachments)
    end

    defp text_of(%ReqLLM.Message{content: [%ReqLLM.Message.ContentPart{text: text} | _]}),
      do: text

    # Extracts the `<objective>...</objective>` substring so byte-identity can
    # be asserted independently of the (refreshed) `<context>` block.
    defp objective_section(message_text) do
      [block] = Regex.run(~r{<objective>.*?</objective>}s, message_text)
      block
    end

    test "refreshes the <context> block from the worktree, keeping <objective> byte-identical" do
      repo = write_repo("docs", "# Root\nroot body\n", "# Docs\nOLD BODY\n")
      objective = "Implement the widget."

      st = refresh_state(repo_path: repo, objective: objective)

      original = original_first_user_message(st)
      original_text = text_of(original)

      assert original_text =~ "OLD BODY"
      refute original_text =~ "NEW BODY"

      original_objective = objective_section(original_text)
      assert original_objective == "<objective>\n#{objective}\n</objective>"

      # The agent edits the CONTEXT.md chain in its worktree mid-run.
      File.write!(Path.join([repo, "docs", "CONTEXT.md"]), "# Docs\nNEW BODY\n")

      refreshed = ContextBuilder.refresh_first_user_message(original, st)
      refreshed_text = text_of(refreshed)

      # Fresh context tree: the edit is visible, the stale text is gone.
      assert refreshed_text =~ "NEW BODY"
      refute refreshed_text =~ "OLD BODY"

      # <objective> block unchanged, byte-for-byte.
      assert objective_section(refreshed_text) == original_objective
      assert objective_section(refreshed_text) == "<objective>\n#{objective}\n</objective>"

      # Role preserved + metadata (turn-0 tag + creation timestamp) survives.
      assert refreshed.role == original.role
      assert refreshed.metadata == original.metadata
    end

    test "no CONTEXT.md change -> refreshed message is structurally identical" do
      repo = write_repo("docs", "# Root\n", "# Docs\nSTABLE\n")

      st =
        refresh_state(repo_path: repo, objective: "Objective text.")

      original =
        original_first_user_message(st)
        |> ContextBuilder.tag_message_turn(0)

      refreshed = ContextBuilder.refresh_first_user_message(original, st)

      assert refreshed == original
    end

    test "root-agent media content parts are reproduced byte-identically" do
      repo = write_repo("docs", "# Root\n", "# Docs\nOLD\n")
      objective = "with media"

      attachments = [
        %{
          "type" => "image",
          "name" => "a.png",
          "media_type" => "image/png",
          "data" => Base.encode64(<<1, 2, 3>>)
        }
      ]

      st = refresh_state(repo_path: repo, objective: objective, attachments: attachments)

      original = original_first_user_message(st)
      assert [%ReqLLM.Message.ContentPart{}, image_part] = original.content
      assert image_part == ReqLLM.Message.ContentPart.image(<<1, 2, 3>>, "image/png")

      File.write!(Path.join([repo, "docs", "CONTEXT.md"]), "# Docs\nNEW\n")

      refreshed = ContextBuilder.refresh_first_user_message(original, st)

      assert [%ReqLLM.Message.ContentPart{} = text_part, refreshed_image] = refreshed.content
      assert refreshed_image == image_part
      assert text_part.text =~ "NEW"
      refute text_part.text =~ "OLD"
    end

    test "a non-root agent's attachments never materialize on refresh (root gate)" do
      repo = write_repo("docs", "# Root\n", "# Docs\n#\n")

      attachments = [
        %{
          "type" => "image",
          "name" => "a.png",
          "media_type" => "image/png",
          "data" => Base.encode64(<<9>>)
        }
      ]

      st =
        refresh_state(
          repo_path: repo,
          objective: "sub",
          parent_id: 7,
          attachments: attachments
        )

      original = original_first_user_message(st)

      refreshed = ContextBuilder.refresh_first_user_message(original, st)

      assert [%ReqLLM.Message.ContentPart{}] = refreshed.content
      assert refreshed == original
    end
  end
end
