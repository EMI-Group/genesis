defmodule EvoDashWeb.HomeLive.DeltaTest do
  use ExUnit.Case, async: true

  alias EvoDashWeb.HomeLive.Delta
  alias EvoDashWeb.HomeLive.Transcript

  # Pure reducer tests for the push-only agent-delta contract
  # (`EvoGit.Agent.Stream`): every event shape folds into the chat surface
  # (transcript / thought process / turn meta) with no processes and no
  # side effects, and malformed payloads are ignored instead of raising.

  defp stream(transcript \\ [], thought_process \\ [], meta \\ nil) do
    %{
      delta: Delta.new(7, node(), 0),
      transcript: transcript,
      thought_process: thought_process,
      meta: meta || Delta.meta()
    }
  end

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
      %{transcript: transcript} = run([{:text, String.duplicate("a", 7_900)}])

      %{transcript: transcript} =
        run([{:text, String.duplicate("b", 500)}], stream(transcript))

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

    test "a new turn starts a NEW thinking entry (one bucket per turn)" do
      %{thought_process: first} = run([{:thinking, "turn zero"}])

      %{thought_process: thought_process} =
        run([{:turn, %{turn: 1}}, {:thinking, "turn one"}], stream([], first))

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
      %{transcript: transcript} =
        run([
          {:text, "partial "},
          {:tool_call, "c1", "bash"},
          {:text, "more"},
          {:tool_result, "c1", :ok}
        ])

      %{transcript: transcript} = run([{:turn, %{turn: 1}}], stream(transcript))

      assert Enum.filter(transcript, &(&1.role == :assistant)) ==
               [Enum.find(transcript, &(&1.role == :assistant and &1.text == "partial more"))]

      %{transcript: transcript} = run([{:text, "next"}], stream(transcript))

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
      %{transcript: transcript} = run([{:tool_call, "c1", "bash"}, {:tool_call, "c2", "read"}])

      %{transcript: transcript} = run([{:tool_result, "c1", :ok}], stream(transcript))

      assert [
               %{tool_call_id: "c1", tool_status: :ok},
               %{tool_call_id: "c2", tool_status: :running}
             ] =
               transcript
    end

    test "a nil call id updates the most recent still-running row" do
      %{transcript: transcript} =
        run([{:tool_call, nil, "bash"}, {:tool_call, nil, "read"}])

      %{transcript: transcript} = run([{:tool_result, nil, :timeout}], stream(transcript))

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
      %{transcript: transcript} = run([{:tool_call, "c1", "bash"}])

      %{transcript: after_result} = run([{:tool_result, "nope", :ok}], stream(transcript))

      assert after_result == Transcript.normalize(transcript)
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
      %{delta: delta} = run([{:text, "a"}, {:turn, %{turn: 1}}])
      assert Delta.streamed_text?(delta)

      %{delta: delta} = run([{:text, "a"}, {:turn, %{turn: 1}}, {:turn, %{turn: 2}}])
      refute Delta.streamed_text?(delta)
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
