defmodule EvoDashWeb.HomeLive.DeltaTest do
  use ExUnit.Case, async: true

  alias EvoDashWeb.HomeLive.Delta
  alias EvoDashWeb.HomeLive.Transcript

  # Pure reducer tests for the push-only agent-delta contract
  # (`EvoGit.Agent.Stream`): every event shape folds into the chat surface
  # (transcript / thought process / turn meta) with no processes and no
  # side effects, and malformed payloads are ignored instead of raising.

  # Only initial fixtures create a reducer; subsequent batches pass run/2's
  # complete result so call identity, thinking prefixes and flags survive.
  defp stream(transcript \\ []) do
    %{
      delta: Delta.new(7, node(), 0),
      transcript: transcript,
      thought_process: [],
      meta: Delta.meta()
    }
  end

  defp call(id, turn \\ 0, attempt \\ 0, text \\ "", thinking \\ "") do
    %{id: id, turn: turn, attempt: attempt, text: text, thinking: thinking}
  end

  defp activity(phase, call), do: {:activity, %{phase: phase, current_call: call}}

  defp run(events, state \\ nil) do
    state = state || stream()

    Delta.apply_batch(
      state.delta,
      state.transcript,
      state.thought_process,
      state.meta,
      events
    )
  end

  defp streaming_entry(text) do
    Transcript.entry(:assistant, text, streaming: true)
  end

  describe "new/3 and seed/3" do
    test "new/3 keeps a non-negative integer seq and defaults everything else" do
      delta = Delta.new(42, :a@b, 9)

      assert %Delta{agent_id: 42, node: :a@b, seq: 9, turn: 0, thinking: ""} = delta
    end

    test "new/3 tolerates a missing/garbage seq and node" do
      for seq <- [nil, "9", -1, 1.5, %{}] do
        assert Delta.new(1, nil, seq).seq == 0
      end
    end

    test "seed/3 records the snapshot seq and turn" do
      snapshot = %EvoGit.Agent.Stream.Snapshot{agent_id: 1, seq: 4, turn: 3}

      assert %Delta{seq: 11, turn: 3} = Delta.seed(Delta.new(1, node(), 0), snapshot, 11)
    end

    test "seed/3 falls back to the snapshot's own seq and keeps the turn on garbage" do
      snapshot = %EvoGit.Agent.Stream.Snapshot{agent_id: 1, seq: 6, turn: 2}

      assert %Delta{seq: 6, turn: 2} = Delta.seed(Delta.new(1, node(), 0), snapshot, nil)
      # A non-struct snapshot never raises and never resets a known turn.
      assert %Delta{seq: 0, turn: 5} =
               Delta.seed(Delta.new(1, node(), 0) |> Map.put(:turn, 5), :junk, nil)
    end
  end

  describe "whole activity projections and call identity" do
    test "a captured prefix hydrates text and thinking, then later batches append exactly once" do
      current = call("call-a", 3, 1, "prefix", "reason")
      state = run([activity(:llm, current)])
      id = state.delta.call_entry_id

      assert [%{id: ^id, text: "prefix", streaming: true}] = state.transcript
      assert state.delta.turn == 3
      assert Delta.streamed_text?(state.delta)
      assert state.delta.activity == %{phase: :llm, current_call: current}
      assert [thought] = state.thought_process
      assert thought.data.metadata == %{thinking: true, call_id: "call-a"}
      assert thought.turn == 3
      assert thought.data.content == ""
      assert [%{text: "reason"}] = thought.data.reasoning_details

      state = run([{:text, " suffix"}, {:thinking, " more"}], state)
      assert [%{id: ^id, text: "prefix suffix"}] = state.transcript
      assert state.delta.thinking == "reason more"
      assert state.delta.activity.current_call.text == "prefix suffix"
      assert state.delta.activity.current_call.thinking == "reason more"
      assert [extended] = state.thought_process
      assert extended.timestamp == thought.timestamp
      assert [%{text: "reason more"}] = extended.data.reasoning_details
    end

    test "same-call phase replacements overwrite rather than append captured content" do
      state = run([activity(:llm, call("call-a", 2, 0, "old", "old thought"))])
      id = state.delta.call_entry_id
      timestamp = hd(state.thought_process).timestamp
      corrected = call("call-a", 2, 0, "corrected", "new thought")

      state = run([activity(:llm_complete, corrected)], state)
      state = run([activity(:tools, corrected)], state)

      assert state.delta.activity == %{phase: :tools, current_call: corrected}
      assert [%{id: ^id, text: "corrected", streaming: true}] = state.transcript
      assert [thought] = state.thought_process
      assert thought.timestamp == timestamp
      assert [%{text: "new thought"}] = thought.data.reasoning_details

      state = run([activity(:tools, %{corrected | thinking: ""})], state)
      assert state.thought_process == []
      assert state.delta.thinking == ""
      assert [%{id: ^id, text: "corrected", streaming: true}] = state.transcript
    end

    test "retry_wait discards only the failed attempt and a fresh attempt starts empty" do
      state = run([activity(:llm, call("older", 3, 0, "earlier answer", "earlier thought"))])
      state = run([{:turn, %{turn: 4}}, activity(:idle, nil)], state)
      [older] = state.transcript
      [older_thought] = state.thought_process
      state = run([activity(:llm, call("failed", 4, 0, "discard me", "bad thought"))], state)

      failed_id = state.delta.call_entry_id
      state = run([activity(:retry_wait, nil)], state)

      assert state.transcript == [older]
      assert state.thought_process == [older_thought]
      assert state.delta.call_entry_id == nil
      assert state.delta.thinking == ""
      assert state.delta.text_in_turn == false
      assert state.delta.text_in_closed_turn == true
      assert state.delta.activity == %{phase: :retry_wait, current_call: nil}

      state = run([activity(:llm_waiting, call("retry", 4, 1))], state)
      assert state.transcript == [older]
      assert state.delta.call_entry_id == nil
      state = run([{:thinking, "fresh thought"}, {:text, "fresh answer"}], state)

      assert [^older, %{id: retry_id, text: "fresh answer", streaming: true}] = state.transcript
      assert retry_id != failed_id

      assert state.delta.activity.current_call ==
               call("retry", 4, 1, "fresh answer", "fresh thought")

      assert [^older_thought, thought] = state.thought_process
      assert thought.data.metadata.call_id == "retry"
      assert [%{text: "fresh thought"}] = thought.data.reasoning_details
    end

    test "a new same-turn call id replaces the old attempt even when its text is identical" do
      state = run([activity(:llm, call("attempt-0", 1, 0, "same", "same thought"))])
      previous_id = state.delta.call_entry_id
      state = run([activity(:llm, call("attempt-1", 1, 1, "same", "same thought"))], state)

      assert [%{id: id, text: "same"}] = state.transcript
      assert id != previous_id
      assert state.delta.call_entry_id == id
      assert [thought] = state.thought_process
      assert thought.data.metadata.call_id == "attempt-1"
      state = run([{:text, " suffix"}, {:thinking, " suffix"}], state)
      assert [%{id: ^id, text: "same suffix"}] = state.transcript

      assert [%{data: %{reasoning_details: [%{text: "same thought suffix"}]}}] =
               state.thought_process
    end

    test "new-turn identity keeps earlier text and thinking even with identical content" do
      state = run([activity(:llm, call("first", 1, 0, "same", "same thought"))])
      first_id = state.delta.call_entry_id
      state = run([{:turn, %{turn: 2, total_tokens: 99}}], state)
      state = run([activity(:llm, call("second", 2, 0, "same", "same thought"))], state)

      assert [
               %{id: ^first_id, text: "same", streaming: false},
               %{id: second_id, text: "same", streaming: true}
             ] = state.transcript

      assert second_id != first_id
      assert state.delta.call_entry_id == second_id
      assert state.meta.total_tokens == 99

      assert Enum.map(state.thought_process, &{&1.turn, &1.data.metadata.call_id}) ==
               [{1, "first"}, {2, "second"}]
    end

    test "completion and idle retirement preserve one finalized answer and its reasoning" do
      current = call("answer", 1, 0, "partial", "reasoning")
      state = run([activity(:llm, current)])
      id = state.delta.call_entry_id
      state = run([activity(:llm_complete, %{current | text: "complete"})], state)
      state = run([{:turn, %{turn: 1}}, {:yield, "authoritative"}], state)

      assert state.outcome == :yield
      assert [%{id: ^id, text: "authoritative", streaming: false}] = state.transcript
      thoughts = state.thought_process
      state = run([activity(:idle, nil)], state)
      assert state.outcome == nil
      assert state.delta.activity == %{phase: :idle, current_call: nil}
      assert state.delta.thinking == ""
      assert state.thought_process == thoughts
      assert [%{id: ^id, text: "authoritative", streaming: false}] = state.transcript
      assert Delta.streamed_text?(state.delta)
      # A retired call must not accept stray text/thinking chunks.
      assert run([{:text, "stray"}, {:thinking, "stray"}], state) == state
    end

    test "thinking-only activity never creates a bubble and no-call phases ignore chunks" do
      for phase <- [:idle, :llm_waiting, :retry_wait, :tools] do
        state = run([activity(phase, nil)])
        assert run([{:text, "stray"}, {:thinking, "stray"}], state) == state
        refute Delta.streamed_text?(state.delta)
      end

      state = run([activity(:llm, call("thinking-only", 0, 0, "", "reason"))])
      assert state.transcript == []
      assert length(state.thought_process) == 1
      refute Delta.streamed_text?(state.delta)
      state = run([{:finished, :cancelled}], state)
      assert state.outcome == {:finished, :cancelled}
      assert state.transcript == []
      assert [%{data: %{metadata: %{call_id: "thinking-only"}}}] = state.thought_process
    end

    test "malformed activity replacements preserve the entire active surface" do
      state = run([activity(:llm, call("valid", 2, 0, "keep", "keep thought"))])

      invalid_calls = [
        :junk,
        %{},
        Map.delete(call("bad"), :attempt),
        %{call("bad") | id: 42},
        %{call("bad") | turn: -1},
        %{call("bad") | attempt: -1},
        %{call("bad") | text: nil},
        %{call("bad") | thinking: nil}
      ]

      projections =
        [
          nil,
          :llm,
          %{phase: :llm},
          %{current_call: call("bad")},
          %{phase: :unknown, current_call: nil}
        ] ++
          Enum.map(invalid_calls, &%{phase: :llm, current_call: &1})

      for projection <- projections do
        assert run([{:activity, projection}], state) == state
      end
    end
  end

  describe "text deltas" do
    test "the first chunk creates ONE streaming assistant entry" do
      %{transcript: transcript} = run([{:text, "Hello"}])

      assert [%{role: :assistant, text: "Hello", streaming: true}] = transcript
    end

    test "later chunks append to that same bubble instead of creating a new one" do
      %{transcript: transcript} = run([{:text, "Hello"}, {:text, " "}, {:text, "world"}])

      assert [%{role: :assistant, text: "Hello world", streaming: true}] = transcript
    end

    test "an empty chunk is ignored" do
      %{transcript: transcript} = run([{:text, ""}])

      assert transcript == []
      # A non-binary chunk is ignored too (the vocabulary is binary-only).
      assert run([{:text, nil}]).transcript == []
      assert run([{:text, 42}]).transcript == []
    end

    test "the 8 000-grapheme per-entry cap still applies across chunks" do
      state = run([{:text, String.duplicate("a", 7_900)}])

      %{transcript: transcript} = run([{:text, String.duplicate("b", 500)}], state)

      assert [%{text: text}] = transcript
      assert String.length(text) == 8_000
      refute String.ends_with?(text, "…")
    end
  end

  describe "thinking deltas" do
    test "chunks accumulate into ONE thought entry for the current turn" do
      %{thought_process: thought_process, transcript: transcript} =
        run([{:thinking, "let me "}, {:thinking, "think"}])

      assert transcript == []

      assert [entry] = thought_process
      assert entry.turn == 0
      assert entry.type == "assistant"
      assert entry.data.metadata == %{thinking: true}
      assert entry.data.content == ""
      assert entry.data.reasoning_details == [%{text: "let me think", type: "thinking"}]
      assert is_integer(entry.timestamp)
    end

    test "later batches extend the same thinking prefix without replacing it" do
      state = run([{:thinking, "let me "}])
      state = run([{:thinking, "think"}], state)

      assert state.delta.thinking == "let me think"
      assert [entry] = state.thought_process
      assert [%{text: "let me think"}] = entry.data.reasoning_details
    end

    test "a new turn starts a NEW thinking entry (one bucket per turn)" do
      state = run([{:thinking, "turn zero"}])

      %{thought_process: thought_process} =
        run([{:turn, %{turn: 1}}, {:thinking, "turn one"}], state)

      assert [zero, one] = thought_process
      assert zero.turn == 0
      assert [%{text: "turn zero"}] = zero.data.reasoning_details
      assert one.turn == 1
      assert [%{text: "turn one"}] = one.data.reasoning_details
    end

    test "thinking never touches the assistant bubble text" do
      %{transcript: transcript, thought_process: thought_process} =
        run([{:text, "answer"}, {:thinking, "reasoning"}])

      assert [%{text: "answer"}] = transcript
      assert length(thought_process) == 1
    end

    test "the thought list is capped at 40 entries, newest kept" do
      batch =
        Enum.flat_map(1..45, fn turn -> [{:turn, %{turn: turn}}, {:thinking, "t#{turn}"}] end)

      %{thought_process: thought_process} = run(batch)

      assert length(thought_process) == 40
      assert List.first(thought_process).turn == 6
      assert List.last(thought_process).turn == 45
      assert [%{text: "t45"}] = List.last(thought_process).data.reasoning_details
    end
  end

  describe "tool deltas" do
    test "a tool_call keeps the streaming bubble open and appends a running tool row" do
      %{transcript: transcript} =
        run([
          {:text, "partial "},
          {:tool_call, "c1", "bash"},
          {:text, "more"},
          {:tool_result, "c1", :ok}
        ])

      # ONE bubble per turn: the text after the tool call accumulates into the
      # same assistant entry, which never holds empty text.
      assert [assistant, tool] = transcript
      assert assistant.role == :assistant
      assert assistant.text == "partial more"
      assert assistant.text != ""
      assert assistant.streaming == true

      assert tool.role == :tool
      assert tool.text == ""
      assert tool.streaming == false
      assert tool.tool_name == "bash"
      assert tool.tool_call_id == "c1"
      assert tool.tool_status == :ok
      assert tool.turn == 0
      assert is_binary(tool.id)
    end

    test "a turn closes that single bubble and the next text opens a fresh one" do
      state =
        run([
          {:text, "partial "},
          {:tool_call, "c1", "bash"},
          {:text, "more"},
          {:tool_result, "c1", :ok}
        ])

      state = run([{:turn, %{turn: 1}}], state)

      assert [%{text: "partial more", streaming: false}] =
               Enum.filter(state.transcript, &(&1.role == :assistant))

      %{transcript: transcript, delta: delta} = run([{:text, "next"}], state)

      assert delta.turn == 1

      # Exactly TWO assistant entries: the closed turn and the new streaming one.
      assert [
               %{text: "partial more", streaming: false},
               %{text: "next", streaming: true}
             ] = Enum.filter(transcript, &(&1.role == :assistant))
    end

    test "a thinking-only segment drops the empty placeholder instead of finalizing it" do
      state = stream(Transcript.put_streaming_text([], ""))

      %{transcript: transcript, thought_process: thought_process} =
        run([{:thinking, "hmm"}, {:turn, %{turn: 1}}], state)

      refute Enum.any?(transcript, &(&1.role == :assistant))
      assert [entry] = thought_process
      assert [%{text: "hmm"}] = entry.data.reasoning_details
    end

    test "an empty placeholder is dropped on finished and on a text-less yield" do
      for event <- [{:finished, :completed}, {:yield, ""}, {:yield, nil}] do
        %{transcript: transcript} = run([event], stream(Transcript.put_streaming_text([], "")))

        refute Enum.any?(transcript, &(&1.role == :assistant)),
               "expected no assistant entry for #{inspect(event)}"
      end
    end

    test "a tool_result by call id updates that exact row" do
      state = run([{:tool_call, "c1", "bash"}, {:tool_call, "c2", "read"}])

      %{transcript: transcript} = run([{:tool_result, "c1", :ok}], state)

      assert [
               %{tool_call_id: "c1", tool_status: :ok},
               %{tool_call_id: "c2", tool_status: :running}
             ] =
               transcript
    end

    test "a nil call id updates the most recent still-running row" do
      state = run([{:tool_call, nil, "bash"}, {:tool_call, nil, "read"}])

      %{transcript: transcript} = run([{:tool_result, nil, :timeout}], state)

      assert [
               %{tool_name: "bash", tool_status: :running},
               %{tool_name: "read", tool_status: :timeout}
             ] =
               transcript
    end

    test "tool statuses normalize to :ok, :timeout and :error" do
      for {raw, expected} <- [
            {:ok, :ok},
            {:timeout, :timeout},
            {:error, :error},
            {:crashed, :error},
            {"ok", :ok},
            {"weird", :error}
          ] do
        %{transcript: [tool]} = run([{:tool_call, "c1", "bash"}, {:tool_result, "c1", raw}])

        assert tool.tool_status == expected, "expected #{inspect(expected)} for #{inspect(raw)}"
      end
    end

    test "an unmatched tool_result leaves the transcript untouched" do
      state = run([{:tool_call, "c1", "bash"}])

      %{transcript: after_result} = run([{:tool_result, "nope", :ok}], state)

      assert after_result == Transcript.normalize(state.transcript)
      assert [%{tool_status: :running}] = after_result
    end
  end

  describe "turn and terminal deltas" do
    test "a turn event records the meta, finalizes the bubble and resets thinking" do
      state = stream([streaming_entry("partial ")])

      %{meta: meta, delta: delta, transcript: transcript} =
        run([{:turn, %{turn: 2, total_tokens: 120, duration_ms: 1500, usage: :usage}}], state)

      assert meta == %{turn: 2, total_tokens: 120, duration_ms: 1500, usage: :usage}
      assert delta.turn == 2
      assert delta.thinking == ""
      assert [%{text: "partial ", streaming: false}] = transcript
    end

    test "a turn event accepts string-keyed info and leaves absent keys alone" do
      %{meta: meta, delta: delta} =
        run([{:turn, %{"turn" => 3, "total_tokens" => 7}}])

      assert meta == %{turn: 3, total_tokens: 7, duration_ms: nil, usage: nil}
      assert delta.turn == 3
    end

    test "a malformed turn info is ignored" do
      for info <- [nil, "turn 2", 42, [:turn]] do
        %{meta: meta, delta: delta} = run([{:turn, info}])

        assert meta == Delta.meta()
        assert delta.turn == 0
      end
    end

    test "a yield finalizes the bubble with the authoritative text" do
      %{transcript: transcript, outcome: outcome} =
        run([{:text, "partial"}, {:yield, "final answer"}])

      assert outcome == :yield
      assert [%{role: :assistant, text: "final answer", streaming: false}] = transcript
    end

    test "a yield without a usable text only finalizes the streamed bubble" do
      for text <- [nil, "", 42] do
        %{transcript: transcript, outcome: outcome} =
          run([{:text, "partial"}, {:yield, text}])

        assert outcome == :yield
        assert [%{text: "partial", streaming: false}] = transcript
      end
    end

    test "finished finalizes the bubble and reports the terminal status" do
      for status <- [:completed, :failed, :cancelled] do
        %{transcript: transcript, outcome: outcome} =
          run([{:text, "partial"}, {:finished, status}])

        assert outcome == {:finished, status}
        assert [%{text: "partial", streaming: false}] = transcript
      end
    end

    test "the LAST outcome in a batch wins" do
      assert run([{:yield, "a"}, {:finished, :completed}]).outcome == {:finished, :completed}
      assert run([{:finished, :failed}, {:yield, "b"}]).outcome == :yield
    end
  end

  describe "streamed_text?/1" do
    test "false for a fresh delta, thinking-only and junk input" do
      refute Delta.streamed_text?(Delta.new(1, node(), 0))

      %{delta: delta} = run([{:thinking, "hmm"}])
      refute Delta.streamed_text?(delta)

      # Total on anything that is not a delta.
      for junk <- [nil, :junk, %{}, "delta"] do
        refute Delta.streamed_text?(junk)
      end
    end

    test "true once text streamed in the open turn" do
      %{delta: delta} = run([{:text, "a"}])

      assert Delta.streamed_text?(delta)
    end

    test "a closed turn keeps the flag, and a later text-less turn clears it" do
      state = run([{:text, "a"}, {:turn, %{turn: 1}}])
      assert Delta.streamed_text?(state.delta)

      state = run([{:turn, %{turn: 2}}], state)
      refute Delta.streamed_text?(state.delta)
    end
  end

  describe "totality" do
    test "unknown events are ignored" do
      state = stream([streaming_entry("keep")])

      %{transcript: transcript, thought_process: thought_process, outcome: outcome} =
        run([{:unknown, "x"}, :junk, %{event: :text}, {"text", "x"}, {:text, "kept!"}], state)

      assert outcome == nil
      assert thought_process == []
      assert [%{text: "keepkept!"}] = transcript
    end

    test "malformed batches never raise" do
      for batch <- [nil, :junk, %{}, {:text, "single"}, [{:text, "a"}], [[:nested]]] do
        assert %{outcome: nil, transcript: transcript} = run(batch)
        assert is_list(transcript)
      end
    end

    test "a transcript/thought process of a non-list degrades instead of raising" do
      %{transcript: transcript, thought_process: thought_process, meta: meta} =
        Delta.apply_batch(Delta.new(1, node(), 0), :junk, :junk, :junk, [
          {:text, "a"},
          {:thinking, "b"},
          {:turn, %{turn: 1}}
        ])

      assert [%{text: "a", streaming: false}] = transcript
      assert [%{turn: 0}] = thought_process
      assert meta == %{turn: 1, total_tokens: nil, duration_ms: nil, usage: nil}
    end

    test "meta/0 carries the four nil turn-meta keys" do
      assert Delta.meta() == %{turn: nil, total_tokens: nil, duration_ms: nil, usage: nil}
    end
  end
end
