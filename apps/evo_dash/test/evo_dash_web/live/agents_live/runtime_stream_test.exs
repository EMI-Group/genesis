defmodule EvoDashWeb.AgentsLive.RuntimeStreamTest do
  use ExUnit.Case, async: true

  alias EvoDashWeb.AgentsLive.RuntimeStream
  alias EvoGit.Agent.Stream.Snapshot

  defp fresh, do: RuntimeStream.new(41, :inspector@host)

  defp batch(state, seq, events), do: RuntimeStream.apply_batch(state, 41, seq, events)

  defp call(id, attrs \\ %{}) do
    Map.merge(%{id: id, turn: 1, attempt: 1, text: "", thinking: ""}, attrs)
  end

  defp activity(phase, current_call), do: %{phase: phase, current_call: current_call}

  defp started(id \\ "first") do
    batch(fresh(), 1, {:activity, activity(:llm_waiting, call(id))})
  end

  describe "snapshot replacement and sequence ownership" do
    test "seeds raw history without extracting checkpoint text or inventing live content" do
      messages = [%{role: :assistant, content: "checkpoint", reasoning: "raw reasoning"}]
      snapshot = %Snapshot{agent_id: 41, seq: 7, phase: :running, turn: 3, messages: messages}
      state = RuntimeStream.seed(fresh(), snapshot, 9)

      assert state.agent_id == 41
      assert state.node == :inspector@host
      assert state.seq == 9
      assert state.turn == 3
      assert state.messages === messages
      assert state.response == ""
      assert state.thinking == ""
      assert state.projections == []
      assert state.activity == :idle
      assert RuntimeStream.active?(state)
    end

    test "resync replaces previous chunks with a string-keyed nested current call" do
      old = batch(started(), 4, [{:text, "old"}, {:thinking, "old thought"}])

      state =
        RuntimeStream.seed(
          old,
          %{
            "agent_id" => 41,
            "seq" => 10,
            "phase" => :running,
            "activity" => %{
              "phase" => :llm,
              "current_call" => %{
                "id" => "new-call",
                "turn" => 2,
                "attempt" => 3,
                "text" => "new",
                "thinking" => "new thought"
              }
            }
          },
          nil
        )

      assert state.seq == 10
      assert state.phase == :running
      assert state.response == "new"
      assert state.thinking == "new thought"
      assert state.activity == :llm

      assert [
               %{
                 identity: %{id: "new-call"},
                 turn: 2,
                 attempt: 3,
                 complete: false,
                 capture_coverage: :complete
               }
             ] = state.projections

      assert batch(state, 11, {:text, " chunk"}).response == "new chunk"
    end

    test "rejects foreign snapshots and stale, duplicate, malformed or foreign-agent batches" do
      state =
        RuntimeStream.seed(
          fresh(),
          %Snapshot{
            agent_id: 41,
            seq: 8,
            activity: activity(:llm, call("live", %{text: "retained"}))
          },
          nil
        )

      assert RuntimeStream.seed(state, %Snapshot{agent_id: 42}, 99) === state

      for seq <- [0, 7, 8, nil, "9", 9.5] do
        assert batch(state, seq, [{:text, "must not appear"}]) === state
        assert batch(state, seq, {:activity, activity(:idle, nil)}) === state

        assert batch(state, seq, {:activity, activity(:llm, call("stale"))}) === state
      end

      assert RuntimeStream.apply_batch(state, 42, 9, [{:text, "foreign"}]) === state
      assert batch(state, 9, [:unknown, {:text, nil}, {:thinking, 7}]) == %{state | seq: 9}
      assert batch(state, 10, nil) == %{state | seq: 10}
    end

    test "resync trusts the caller's admitted snapshot and normalizes sequence precedence" do
      old = batch(started(), 20, [{:text, "old live state"}])

      for {explicit, embedded, expected} <- [
            {0, 9, 0},
            {2, 9, 2},
            {nil, 9, 9},
            {-1, 9, 9},
            {"10", 9, 9},
            {nil, -1, 0},
            {nil, "9", 0}
          ] do
        seeded = RuntimeStream.seed(old, %{agent_id: 41, seq: embedded}, explicit)
        assert seeded.seq == expected
        assert seeded.response == ""
        assert seeded.projections == []
      end

      # Seed is replacement, not a stale-snapshot gate; StreamWatch owns admission.
      assert RuntimeStream.seed(old, %{seq: 1}, nil).seq == 1
    end

    test "malformed snapshot fields reset to defaults and invalid state is total" do
      old = batch(started(), 2, [{:text, "old"}])

      state =
        RuntimeStream.seed(
          old,
          %{seq: -1, turn: "2", messages: :bad, phase: "running", activity: []},
          :bad
        )

      assert state == fresh()
      assert RuntimeStream.seed(nil, %{}, 1) == RuntimeStream.new(nil, nil)
      assert RuntimeStream.apply_batch(nil, 41, 1, []) == RuntimeStream.new(nil, nil)
      refute RuntimeStream.active?(nil)
    end
  end

  describe "replaceable current call and authoritative activity" do
    test "chunks append independently only to an established call and never infer activity" do
      orphaned =
        batch(fresh(), 1, [
          {:text, "orphan"},
          {:thinking, "orphan thought"},
          {:tool_call, "orphan", "read"}
        ])

      assert orphaned.projections == []
      assert orphaned.response == ""
      assert orphaned.thinking == ""
      assert orphaned.tool_calls == []
      assert orphaned.activity == nil
      refute RuntimeStream.active?(orphaned)

      state =
        batch(started(), 2, [
          {:text, "答"},
          {:thinking, "think"},
          {:text, "案"},
          {:thinking, " more"},
          {:text, ""},
          {:thinking, ""},
          {:tool_call, nil, "read"},
          {:tool_call, "call-1", "read"}
        ])

      assert state.response == "答案"
      assert state.thinking == "think more"
      assert state.activity == :llm_waiting

      assert state.tool_calls == [
               %{id: "call-1", name: "read", status: :announced, omitted_name_bytes: 0}
             ]

      assert [%{complete: false, response: "答案", thinking: "think more"}] = state.projections
    end

    test "whole activity replacements do not append or duplicate already accumulated chunks" do
      current = call("first", %{text: "answer", thinking: "reason"})
      state = batch(started(), 2, [{:text, "answer"}, {:thinking, "reason"}])
      index = state.message_index

      for phase <- [:llm, :llm_complete, :tools] do
        replaced = batch(state, 3, {:activity, activity(phase, current)})
        assert replaced.response == "answer"
        assert replaced.thinking == "reason"
        assert replaced.activity == phase
        assert replaced.message_index == index
        assert length(replaced.projections) == 1
        assert replaced.messages == []
      end

      replaced = batch(state, 3, {:activity, activity(:llm, call("first", %{text: "corrected"}))})
      assert replaced.response == "corrected"
      assert replaced.thinking == ""
      appended = batch(replaced, 4, [{:text, " tail"}, {:thinking, "new thought"}])
      assert appended.response == "corrected tail"
      assert appended.thinking == "new thought"
    end

    test "retry retires the failed attempt and a fresh call id replaces rather than archives it" do
      state = batch(started(), 2, [{:text, "failed answer"}, {:thinking, "failed thought"}])
      index = state.message_index
      retrying = batch(state, 3, {:activity, activity(:retry_wait, nil)})
      assert retrying.activity == :retry_wait
      assert retrying.projections == []
      assert retrying.response == ""
      assert retrying.thinking == ""

      retried =
        batch(retrying, 4, [
          {:activity, activity(:llm_waiting, call("retry", %{attempt: 2}))},
          {:text, "retry answer"}
        ])

      assert [%{identity: %{id: "retry"}, attempt: 2, response: "retry answer", thinking: ""}] =
               retried.projections

      assert retried.message_index > index

      next =
        batch(retried, 5, {:activity, activity(:llm, call("next", %{turn: 2, text: "next"}))})

      assert [%{identity: %{id: "next"}, turn: 2, response: "next", thinking: ""}] =
               next.projections

      assert next.message_index > retried.message_index
      assert next.omitted_messages == 0
    end

    test "completed generation survives tools until nil retires it into unmodified checkpoints" do
      current = call("first", %{text: "answer", thinking: "reason"})
      state = batch(started(), 2, {:activity, activity(:llm_complete, current)})

      tools =
        batch(state, 3, [{:activity, activity(:tools, current)}, {:tool_call, "one", "bash"}])

      tools = batch(tools, 4, {:tool_result, "one", :ok})

      assert [
               %{
                 response: "answer",
                 thinking: "reason",
                 generation_complete: true,
                 tool_calls: [%{id: "one", status: :ok}]
               }
             ] = tools.projections

      messages = [%{role: :assistant, content: "answer", reasoning: "reason"}]

      checkpoint =
        RuntimeStream.seed(
          tools,
          %Snapshot{
            agent_id: 41,
            phase: :running,
            messages: messages,
            activity: activity(:idle, nil)
          },
          5
        )

      assert checkpoint.messages === messages
      assert checkpoint.projections == []
      assert checkpoint.response == ""
      assert checkpoint.thinking == ""
      assert checkpoint.tool_calls == []
      assert checkpoint.activity == :idle
      assert RuntimeStream.active?(checkpoint)
      retired = batch(tools, 5, {:activity, activity(:idle, nil)})
      assert retired.projections == []
      assert retired.response == ""
      assert retired.thinking == ""
      assert retired.tool_calls == []
      assert batch(retired, 6, [{:text, "late"}, {:tool_result, "one", :ok}]).projections == []
    end

    test "lifecycle and activity phases remain independent across all core phases" do
      for phase <- [:idle, :llm_waiting, :llm, :llm_complete, :retry_wait, :tools],
          lifecycle <- [:running, :cancelling, :awaiting_input] do
        current = if phase in [:idle, :retry_wait], do: nil, else: call("live")
        snapshot = %Snapshot{phase: lifecycle, activity: activity(phase, current)}
        state = RuntimeStream.seed(fresh(), snapshot, 1)
        assert state.phase == lifecycle
        assert state.activity == phase
        assert RuntimeStream.active?(state) == lifecycle in [:running, :cancelling]
      end
    end

    test "yield and turn accounting never replace text or resurrect a retired call" do
      state = batch(started(), 2, [{:text, "captured"}, {:thinking, "retained"}])
      yielded = batch(state, 3, [{:turn, %{turn: 4}}, {:yield, "checkpoint-only response"}])
      assert yielded.turn == 4
      assert yielded.response == "captured"
      assert yielded.thinking == "retained"
      assert yielded.phase == :awaiting_input
      assert yielded.status == :awaiting_input
      refute yielded.finished
      refute RuntimeStream.active?(yielded)
      assert [%{complete: true, generation_complete: false}] = yielded.projections

      retired = batch(yielded, 4, {:activity, activity(:idle, nil)})
      after_checkpoint = batch(retired, 5, [{:yield, "full answer"}, {:turn, %{turn: 5}}])
      assert after_checkpoint.projections == []
      assert after_checkpoint.response == ""
      assert after_checkpoint.turn == 5
    end

    test "finish freezes excerpts even against later events in the same batch" do
      state = batch(started(), 2, [{:text, "answer"}, {:thinking, "reason"}])

      finished =
        batch(state, 3, [
          {:finished, :cancelled},
          {:text, "ignored"},
          {:activity, activity(:idle, nil)}
        ])

      assert finished.finished
      assert finished.phase == :finished
      assert finished.status == :cancelled
      assert finished.response == "answer"
      assert finished.thinking == "reason"
      assert [%{complete: true, generation_complete: false}] = finished.projections
      refute RuntimeStream.active?(finished)
      assert batch(finished, 4, [{:thinking, "ignored"}]) === finished
    end

    test "terminal snapshots complete nested current calls without fabricating generation completion" do
      for status <- [:failed, :cancelled, :completed] do
        state =
          RuntimeStream.seed(
            fresh(),
            %Snapshot{
              phase: status,
              activity: activity(:llm, call("last", %{text: "tail", thinking: "why"}))
            },
            5
          )

        assert state.finished
        assert state.status == status

        assert [%{response: "tail", thinking: "why", complete: true, generation_complete: false}] =
                 state.projections

        refute RuntimeStream.active?(state)
      end
    end
  end

  describe "source capture and generation completion" do
    test "explicit binary text and thinking prove capture, including empty pre-chunk fields" do
      for phase <- [:llm_waiting, :llm, :llm_complete, :tools] do
        state =
          RuntimeStream.seed(fresh(), %Snapshot{activity: activity(phase, call("empty"))}, 1)

        assert [%{capture_coverage: :complete, thinking: "", response: ""} = projection] =
                 state.projections

        assert projection.generation_complete == phase in [:llm_complete, :tools]
        assert projection.complete == projection.generation_complete
      end

      for malformed <- [
            Map.delete(call("partial"), :text),
            Map.delete(call("partial"), :thinking),
            call("partial", %{text: nil}),
            call("partial", %{thinking: nil})
          ] do
        state =
          RuntimeStream.seed(fresh(), %Snapshot{activity: activity(:llm_complete, malformed)}, 1)

        assert [%{capture_coverage: :partial, generation_complete: true}] = state.projections
      end
    end

    test "turn accounting and lifecycle finish are not successful generation signals" do
      for status <- [:failed, :cancelled, :completed] do
        state =
          batch(started(), 2, [{:text, "unfinished"}, {:turn, %{turn: 1}}, {:finished, status}])

        assert [%{complete: true, generation_complete: false, capture_coverage: :complete}] =
                 state.projections

        assert state.status == status
      end
    end

    test "identity reader accepts explicit map identity without guessing from content" do
      assert RuntimeStream.message_identity(%{"turn" => 2, "message_index" => 4, "id" => "call"}) ==
               %{turn: 2, message_index: 4, id: "call"}

      for malformed <- [
            nil,
            -1,
            "backend-id",
            [],
            %{turn: -1, message_index: "4", id: nil},
            %{response: "same text", row: 4}
          ] do
        assert RuntimeStream.message_identity(malformed) == %{}
      end
    end
  end

  describe "bounded retention with honest omissions" do
    test "public retention budgets stay explicit and independent of checkpoint size" do
      assert RuntimeStream.max_projections() == 12
      assert RuntimeStream.max_text_bytes() == 48_000
      assert RuntimeStream.max_tools() == 20
      assert RuntimeStream.max_tool_name_bytes() == 1_024
    end

    test "response and thinking retain independent UTF-8 prefixes and count every lost chunk byte" do
      limit = RuntimeStream.max_text_bytes()
      prefix = String.duplicate("a", limit - 1)
      full = prefix <> "界"
      state = batch(started("bounded"), 2, [{:text, full}, {:thinking, full}])

      assert state.response == prefix
      assert state.thinking == prefix
      assert String.valid?(state.response)
      assert String.valid?(state.thinking)

      assert [
               %{
                 omitted_response_bytes: 3,
                 omitted_thinking_bytes: 3,
                 capture_coverage: :complete,
                 identity: %{id: "bounded"}
               }
             ] = state.projections

      assert :binary.referenced_byte_size(state.response) == byte_size(state.response)
      assert :binary.referenced_byte_size(state.thinking) == byte_size(state.thinking)

      # Once loss occurs, later chunks cannot fill a UTF-8 boundary gap out of order.
      next = batch(state, 3, [{:text, "z"}, {:thinking, "more"}])
      assert next.response == prefix
      assert next.thinking == prefix
      assert [%{omitted_response_bytes: 4, omitted_thinking_bytes: 7}] = next.projections
    end

    test "exact byte boundary has no omission until a further chunk arrives" do
      full = String.duplicate("x", RuntimeStream.max_text_bytes())
      state = batch(started(), 2, [{:text, full}, {:thinking, "short"}])
      assert state.response == full
      assert [%{omitted_response_bytes: 0, omitted_thinking_bytes: 0}] = state.projections
      next = batch(state, 3, [{:text, "界"}, {:thinking, " thought"}])
      assert next.response == full
      assert next.thinking == "short thought"
      assert [%{omitted_response_bytes: 3, omitted_thinking_bytes: 0}] = next.projections
    end

    test "replacement omissions describe authoritative bytes, not retransmission or yield" do
      oversized = String.duplicate("x", RuntimeStream.max_text_bytes() + 7)
      messages = [%{role: :assistant, content: oversized}]
      current = call("full", %{text: oversized, thinking: oversized})

      state =
        RuntimeStream.seed(
          fresh(),
          %Snapshot{messages: messages, activity: activity(:llm, current)},
          1
        )

      assert state.messages === messages

      assert [
               %{
                 omitted_response_bytes: 7,
                 omitted_thinking_bytes: 7,
                 capture_coverage: :complete
               }
             ] = state.projections

      replaced = batch(state, 2, {:activity, activity(:llm_complete, current)})

      assert [%{omitted_response_bytes: 7, omitted_thinking_bytes: 7, generation_complete: true}] =
               replaced.projections

      yielded = batch(replaced, 3, {:yield, oversized})
      assert [%{omitted_response_bytes: 7, omitted_thinking_bytes: 7}] = yielded.projections

      short = batch(yielded, 4, {:activity, activity(:tools, call("full", %{text: "short"}))})
      assert short.response == "short"
      assert short.thinking == ""
      assert [%{omitted_response_bytes: 0, omitted_thinking_bytes: 0}] = short.projections
      reset = RuntimeStream.seed(short, %Snapshot{messages: messages}, 5)
      assert reset.projections == []
      assert reset.omitted_messages == 0
      assert reset.messages === messages
    end

    test "many call replacements retain only the current attempt and bounded metadata" do
      limit = RuntimeStream.max_projections()

      state =
        Enum.reduce(0..(limit + 1), fresh(), fn index, state ->
          current =
            call("call-#{index}", %{
              turn: index,
              text: "answer-#{index}",
              thinking: "thought-#{index}"
            })

          batch(state, index + 1, {:activity, activity(:llm_complete, current)})
        end)

      assert [%{identity: %{id: id}, turn: turn, generation_complete: true}] = state.projections
      assert id == "call-#{limit + 1}"
      assert turn == limit + 1
      assert state.response == "answer-#{limit + 1}"
      assert state.thinking == "thought-#{limit + 1}"
      assert state.omitted_messages == 0
      assert state.messages == []
    end

    test "tools retain bounded names and descriptors, with updates reaching retained tools" do
      limit = RuntimeStream.max_tools()
      name_limit = RuntimeStream.max_tool_name_bytes()
      name = String.duplicate("a", name_limit - 1) <> "界"
      state = batch(started(), 2, [{:tool_call, "long", name}, {:tool_call, "long", name}])

      assert [%{id: "long", name: retained, status: :announced, omitted_name_bytes: 3}] =
               state.tool_calls

      assert retained == String.duplicate("a", name_limit - 1)
      assert String.valid?(retained)
      assert :binary.referenced_byte_size(retained) == byte_size(retained)

      events = Enum.map(1..(limit + 1), &{:tool_call, "call-#{&1}", "read"})
      full = batch(state, 3, events)
      assert length(full.tool_calls) == limit
      assert [%{omitted_tools: 2}] = full.projections

      assert Enum.map(full.tool_calls, & &1.id) == [
               "long" | Enum.map(1..(limit - 1), &"call-#{&1}")
             ]

      updated = batch(full, 4, [{:tool_call, "call-1", "write"}, {:tool_result, "long", :ok}])
      assert hd(updated.tool_calls).status == :ok

      assert Enum.at(updated.tool_calls, 1) == %{
               id: "call-1",
               name: "write",
               status: :announced,
               omitted_name_bytes: 0
             }

      assert [%{omitted_tools: 2}] = updated.projections

      next = batch(updated, 5, {:activity, activity(:llm_waiting, call("next"))})
      assert next.tool_calls == []
      assert [%{omitted_tools: 0}] = next.projections
    end
  end
end
