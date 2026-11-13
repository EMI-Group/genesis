defmodule EvoDashWeb.AgentsLive.RuntimeStreamTest do
  use ExUnit.Case, async: true

  alias EvoDashWeb.AgentsLive.RuntimeStream
  alias EvoGit.Agent.Stream.Snapshot

  defp fresh, do: RuntimeStream.new(41, :inspector@host)

  defp batch(state, seq, events), do: RuntimeStream.apply_batch(state, 41, seq, events)

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
      assert state.activity == nil
      assert RuntimeStream.active?(state)
    end

    test "resync replaces previous live chunks and supports optional string-keyed in-flight data" do
      old = batch(fresh(), 4, [{:text, "old"}, {:thinking, "old thought"}])

      state =
        RuntimeStream.seed(
          old,
          %{
            "agent_id" => 41,
            "seq" => 10,
            "phase" => :running,
            "activity" => %{phase: :llm},
            "in_flight" => %{
              "text" => "new",
              "thinking" => "new thought",
              "turn" => 2,
              "message_index" => 6
            }
          },
          nil
        )

      assert state.seq == 10
      assert state.response == "new"
      assert state.thinking == "new thought"
      assert state.activity == %{phase: :llm}
      assert [%{message_index: 6, turn: 2, complete: false}] = state.projections
      assert batch(state, 11, {:text, " chunk"}).response == "new chunk"
    end

    test "rejects foreign snapshots and stale, duplicate, malformed or foreign-agent batches" do
      state = RuntimeStream.seed(fresh(), %Snapshot{agent_id: 41, seq: 8}, nil)
      assert RuntimeStream.seed(state, %Snapshot{agent_id: 42}, 99) === state

      for seq <- [0, 7, 8, nil, "9", 9.5] do
        assert batch(state, seq, [{:text, "must not appear"}]) === state
      end

      assert RuntimeStream.apply_batch(state, 42, 9, [{:text, "foreign"}]) === state
      assert batch(state, 9, [:unknown, {:text, nil}, {:thinking, 7}]) == %{state | seq: 9}
      assert batch(state, 10, nil) == %{state | seq: 10}
    end

    test "resync trusts the caller's admitted snapshot and normalizes sequence precedence" do
      old = batch(fresh(), 20, [{:text, "old live state"}])

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
      old = batch(fresh(), 1, [{:text, "old"}])

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

  describe "message-local text, thinking and authoritative activity" do
    test "chunks concatenate independently and neither thinking nor tools infer activity" do
      state =
        batch(fresh(), 1, [
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
      assert state.activity == nil
      refute RuntimeStream.active?(state)

      assert state.tool_calls == [
               %{id: "call-1", name: "read", status: :announced, omitted_name_bytes: 0}
             ]

      assert [%{complete: false, response: "答案", thinking: "think more"}] = state.projections

      active = RuntimeStream.seed(fresh(), %{phase: :cancelling}, 0)
      assert RuntimeStream.active?(active)
      assert active.activity == nil
    end

    test "identity-free activity preserves content; explicit identity advances once" do
      state =
        batch(fresh(), 1, [
          {:message_start, %{turn: 1, id: "first"}},
          {:thinking, "reason"},
          {:text, "answer"}
        ])

      same =
        batch(state, 2, [{:activity, %{phase: :llm}}, {:message_start, %{turn: 1, id: "first"}}])

      assert same.response == "answer"
      assert same.thinking == "reason"
      assert length(same.projections) == 1
      assert same.activity == %{phase: :llm}

      next =
        batch(same, 3, [{:activity, %{phase: :llm, turn: 2, message_index: 5}}, {:text, "next"}])

      assert [
               %{response: "answer", thinking: "reason", complete: true},
               %{response: "next", thinking: "", complete: false, message_index: 5}
             ] = next.projections

      assert next.response == "next"
      assert next.thinking == ""
      assert next.activity == %{phase: :llm, turn: 2, message_index: 5}
    end

    test "generation completion preserves reasoning and tools; only the next chunk opens a message" do
      state =
        batch(fresh(), 1, [
          {:thinking, "first thought"},
          {:text, "first"},
          {:tool_call, "one", "bash"},
          {:turn, %{turn: 1}}
        ])

      tools = batch(state, 2, [{:tool_result, "one", :ok}, {:tool_call, "two", "read"}])
      assert [%{complete: true, response: "first", thinking: "first thought"}] = tools.projections

      assert tools.tool_calls == [
               %{id: "one", name: "bash", status: :ok, omitted_name_bytes: 0},
               %{id: "two", name: "read", status: :announced, omitted_name_bytes: 0}
             ]

      next = batch(tools, 3, [{:text, "second"}, {:tool_result, "two", :failed}])

      assert [
               %{thinking: "first thought", tool_calls: [_, %{status: :failed}]},
               %{response: "second", thinking: "", complete: false, tool_calls: []}
             ] = next.projections

      complete = batch(next, 4, [{:turn, %{turn: 2}}])
      # Generation completion alone never proves that mid-generation capture was complete.
      assert List.last(complete.projections).complete
      assert List.last(complete.projections).generation_complete
      assert List.last(complete.projections).capture_coverage == :partial
      assert List.last(complete.projections).thinking == ""
      assert hd(complete.projections).thinking == "first thought"
    end

    test "yield replaces a complete response without erasing thought; finish freezes even the same batch" do
      state =
        batch(fresh(), 1, [
          {:activity, :llm},
          {:thinking, "retained"},
          {:text, "partial"},
          {:yield, "full response"}
        ])

      assert state.response == "full response"
      assert state.thinking == "retained"
      assert state.phase == :awaiting_input
      assert state.status == :awaiting_input
      assert state.activity == nil
      refute state.finished
      refute RuntimeStream.active?(state)
      assert List.last(state.projections).complete
      assert batch(state, 2, [{:yield, ""}]).response == "full response"

      finished = batch(state, 3, [{:finished, :cancelled}, {:text, "ignored"}, {:activity, :llm}])
      assert finished.finished
      assert finished.phase == :finished
      assert finished.status == :cancelled
      assert finished.activity == nil
      assert finished.response == "full response"
      assert finished.thinking == "retained"
      assert batch(finished, 4, [{:thinking, "ignored"}]) === finished
    end

    test "terminal snapshots complete optional in-flight projections" do
      state =
        RuntimeStream.seed(
          fresh(),
          %{phase: :failed, activity: :llm, in_flight: %{response: "last", thinking: "why"}},
          5
        )

      assert state.finished
      assert state.activity == nil
      assert [%{response: "last", thinking: "why", complete: true}] = state.projections
      refute RuntimeStream.active?(state)
    end
  end

  describe "explicit source capture and generation completion" do
    test "message start proves capture only before chunks and does not imply generation completion" do
      started = batch(fresh(), 1, [{:message_start, %{id: "observed"}}])

      assert [%{capture_coverage: :complete, generation_complete: false, chunks_seen: false}] =
               started.projections

      streamed = batch(started, 2, [{:text, "answer"}])

      assert [%{capture_coverage: :complete, generation_complete: false, thinking: ""}] =
               streamed.projections

      ended = batch(streamed, 3, [{:turn, %{turn: 1}}])

      assert [%{capture_coverage: :complete, generation_complete: true, complete: true}] =
               ended.projections

      # A repeated start arriving after partial capture cannot retroactively prove coverage.
      partial =
        batch(fresh(), 1, [
          {:activity, %{phase: :llm, id: "late"}},
          {:text, "tail"},
          {:message_start, %{id: "late"}},
          {:turn, %{turn: 1}},
          {:message_start, %{id: "late"}}
        ])

      assert [%{capture_coverage: :partial, generation_complete: true, response: "tail"}] =
               partial.projections
    end

    test "snapshot coverage requires explicit binary response and thinking, even when empty" do
      for flight <- [
            %{response: "answer", thinking: ""},
            %{response: "answer", capture_coverage: :complete},
            %{response: "answer", thinking: nil, capture_coverage: :complete},
            %{response: nil, thinking: "", capture_coverage: :complete},
            %{response: "answer", thinking: "", capture_coverage: "complete"}
          ] do
        state =
          RuntimeStream.seed(
            fresh(),
            %{in_flight: Map.put(flight, :generation_complete, true)},
            1
          )

        assert [%{capture_coverage: :partial, generation_complete: true, complete: true}] =
                 state.projections
      end

      state =
        RuntimeStream.seed(
          fresh(),
          %{
            "in_flight" => %{
              "id" => "snapshot-message",
              "text" => "answer",
              "thinking" => "",
              "capture_coverage" => :complete,
              "generation_complete" => true
            }
          },
          2
        )

      assert [
               %{
                 identity: %{id: "snapshot-message"},
                 response: "answer",
                 thinking: "",
                 capture_coverage: :complete,
                 generation_complete: true
               }
             ] = state.projections
    end

    test "lifecycle finish and message boundaries do not fabricate completed generation" do
      for status <- [:failed, :cancelled, :completed] do
        state =
          batch(fresh(), 1, [
            {:message_start, "first"},
            {:text, "unfinished"},
            {:finished, status}
          ])

        assert [%{complete: true, generation_complete: false, capture_coverage: :complete}] =
                 state.projections

        assert state.status == status
      end

      state =
        batch(fresh(), 1, [
          {:message_start, "first"},
          {:thinking, "retained"},
          {:message_start, "second"}
        ])

      assert [
               %{complete: true, generation_complete: false, thinking: "retained"},
               %{complete: false, generation_complete: false, thinking: ""}
             ] = state.projections

      terminal =
        RuntimeStream.seed(
          fresh(),
          %{
            phase: :failed,
            in_flight: %{response: "tail", thinking: "", capture_coverage: :complete}
          },
          3
        )

      assert [%{complete: true, generation_complete: false, capture_coverage: :complete}] =
               terminal.projections
    end

    test "identity reader preserves explicit backend identity, never deriving it from content" do
      assert RuntimeStream.message_identity(0) == %{message_index: 0}
      assert RuntimeStream.message_identity("backend-id") == %{id: "backend-id"}

      assert RuntimeStream.message_identity(%{"turn" => 2, "message_index" => 4, "id" => 0}) ==
               %{turn: 2, message_index: 4, id: 0}

      for malformed <- [
            nil,
            -1,
            "",
            [],
            %{turn: -1, message_index: "4", id: nil},
            %{response: "same text", row: 4}
          ] do
        assert RuntimeStream.message_identity(malformed) == %{}
      end
    end
  end

  describe "bounded retention with honest cumulative omissions" do
    test "public retention budgets stay explicit and independent of checkpoint size" do
      assert RuntimeStream.max_projections() == 12
      assert RuntimeStream.max_text_bytes() == 48_000
      assert RuntimeStream.max_tools() == 20
      assert RuntimeStream.max_tool_name_bytes() == 1_024
    end

    test "response and thinking retain independent UTF-8 prefixes and count every lost byte" do
      limit = RuntimeStream.max_text_bytes()
      prefix = String.duplicate("a", limit - 1)
      full = prefix <> "界"

      state =
        batch(fresh(), 1, [
          {:message_start, "bounded"},
          {:text, full},
          {:thinking, full}
        ])

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
      next = batch(state, 2, [{:text, "z"}, {:thinking, "more"}])
      assert next.response == prefix
      assert next.thinking == prefix
      assert [%{omitted_response_bytes: 4, omitted_thinking_bytes: 7}] = next.projections
    end

    test "exact byte boundary has no omission until a further chunk arrives" do
      full = String.duplicate("x", RuntimeStream.max_text_bytes())
      state = batch(fresh(), 1, [{:text, full}, {:thinking, "short"}])
      assert state.response == full
      assert [%{omitted_response_bytes: 0, omitted_thinking_bytes: 0}] = state.projections
      next = batch(state, 2, [{:text, "界"}, {:thinking, " thought"}])
      assert next.response == full
      assert next.thinking == "short thought"
      assert [%{omitted_response_bytes: 3, omitted_thinking_bytes: 0}] = next.projections
    end

    test "yield replacement accumulates prior loss and resync alone resets omission counters" do
      oversized = String.duplicate("x", RuntimeStream.max_text_bytes() + 7)
      messages = [%{role: :assistant, content: oversized}]

      state =
        RuntimeStream.seed(
          fresh(),
          %{
            messages: messages,
            in_flight: %{
              id: "full",
              response: oversized,
              thinking: oversized,
              capture_coverage: :complete
            }
          },
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

      yielded = batch(state, 2, [{:yield, oversized}])

      assert [%{omitted_response_bytes: 14, omitted_thinking_bytes: 7, generation_complete: true}] =
               yielded.projections

      replaced = batch(yielded, 3, [{:yield, "short"}])
      assert replaced.response == "short"
      assert [%{omitted_response_bytes: 14, omitted_thinking_bytes: 7}] = replaced.projections
      reset = RuntimeStream.seed(replaced, %{messages: messages}, 4)
      assert reset.projections == []
      assert reset.omitted_messages == 0
      assert reset.messages === messages
    end

    test "newest message retention counts evictions and preserves explicit identities" do
      limit = RuntimeStream.max_projections()

      state =
        Enum.reduce(0..(limit + 1), fresh(), fn index, state ->
          batch(state, index + 1, [
            {:message_start, %{id: "message-#{index}", message_index: index}},
            {:thinking, "thought-#{index}"},
            {:text, "answer-#{index}"},
            {:turn, %{turn: index}}
          ])
        end)

      assert length(state.projections) == limit
      assert state.omitted_messages == 2
      assert Enum.map(state.projections, & &1.message_index) == Enum.to_list(2..(limit + 1))
      assert hd(state.projections).identity == %{id: "message-2", message_index: 2}
      assert hd(state.projections).thinking == "thought-2"
      assert state.response == "answer-#{limit + 1}"
      assert state.thinking == "thought-#{limit + 1}"

      assert Enum.all?(
               state.projections,
               &(&1.capture_coverage == :complete and &1.generation_complete)
             )
    end

    test "tools retain bounded names and first descriptors, with updates still reaching retained tools" do
      limit = RuntimeStream.max_tools()
      name_limit = RuntimeStream.max_tool_name_bytes()
      name = String.duplicate("a", name_limit - 1) <> "界"
      state = batch(fresh(), 1, [{:tool_call, "long", name}, {:tool_call, "long", name}])

      assert [%{id: "long", name: retained, status: :announced, omitted_name_bytes: 3}] =
               state.tool_calls

      assert retained == String.duplicate("a", name_limit - 1)
      assert String.valid?(retained)
      assert :binary.referenced_byte_size(retained) == byte_size(retained)

      events = Enum.map(1..(limit + 1), &{:tool_call, "call-#{&1}", "read"})
      full = batch(state, 2, events)
      assert length(full.tool_calls) == limit
      assert [%{omitted_tools: 2}] = full.projections

      assert Enum.map(full.tool_calls, & &1.id) == [
               "long" | Enum.map(1..(limit - 1), &"call-#{&1}")
             ]

      updated = batch(full, 3, [{:tool_call, "call-1", "write"}, {:tool_result, "long", :ok}])
      assert hd(updated.tool_calls).status == :ok

      assert Enum.at(updated.tool_calls, 1) == %{
               id: "call-1",
               name: "write",
               status: :announced,
               omitted_name_bytes: 0
             }

      assert [%{omitted_tools: 2}] = updated.projections
    end
  end
end
