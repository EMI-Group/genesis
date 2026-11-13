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
      assert state.tool_calls == [%{id: "call-1", name: "read", status: :announced}]
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
               %{id: "one", name: "bash", status: :ok},
               %{id: "two", name: "read", status: :announced}
             ]

      next = batch(tools, 3, [{:text, "second"}, {:tool_result, "two", :failed}])

      assert [
               %{thinking: "first thought", tool_calls: [_, %{status: :failed}]},
               %{response: "second", thinking: "", complete: false, tool_calls: []}
             ] = next.projections

      complete = batch(next, 4, [{:turn, %{turn: 2}}])
      # Empty thinking is not evidence of no reasoning until generation completes.
      assert List.last(complete.projections).complete
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
end
