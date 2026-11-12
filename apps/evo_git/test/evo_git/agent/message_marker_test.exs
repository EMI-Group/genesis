defmodule EvoGit.Agent.MessageMarkerTest do
  @moduledoc """
  Pins the ONE display marker that separates a REAL user turn from harness text
  sharing the `:user` role: `metadata[:user_authored] => true`, owned by
  `EvoGit.Agent.MessageMarker`.

  `async: true` — every case is a pure function of plain structs plus, for the
  drain, its OWN in-memory `:scheduler` seam (no scheduler, no ETS row).
  """

  use ExUnit.Case, async: true

  alias EvoGit.Agent.ContextBuilder
  alias EvoGit.Agent.Exchange.Pending
  alias EvoGit.Agent.MessageMarker
  alias EvoGit.Agent.State

  @system_prompt "You are the manager."
  @objective "<objective>\nBuild the parser.\n</objective>"

  defp tagged_initial_context do
    @system_prompt
    |> ContextBuilder.build_initial_messages(@objective, nil, nil)
    |> ReqLLM.Context.new()
    |> ContextBuilder.tag_context_messages_with_turn(0)
  end

  defp loop_state do
    %State{
      agent_id: 9_970_000 + :erlang.unique_integer([:positive]),
      agent_module: __MODULE__,
      depth: 0,
      node_path: "./",
      context: ReqLLM.Context.new([]),
      turn: 4
    }
  end

  defp drain(messages) do
    seam = fn :drain_inputs, _payload, _state -> messages end

    loop_state()
    |> Pending.drain_and_inject_user_messages(scheduler: seam)
    |> Map.fetch!(:context)
    |> Map.fetch!(:messages)
  end

  defp attachment(type, name, media_type) do
    %{"type" => type, "name" => name, "media_type" => media_type, "data" => Base.encode64(<<1>>)}
  end

  describe "the marker key" do
    test "is :user_authored" do
      assert MessageMarker.key() == :user_authored
    end
  end

  describe "mark_user_authored/1 + user_authored?/1" do
    test "stamps the key and PRESERVES existing metadata" do
      msg =
        MessageMarker.mark_user_authored(%ReqLLM.Message{
          role: :user,
          content: [ReqLLM.Message.ContentPart.text("hi")],
          metadata: %{turn: 3, timestamp: 42, checkpoint: true}
        })

      assert msg.metadata == %{turn: 3, timestamp: 42, checkpoint: true, user_authored: true}
      assert MessageMarker.user_authored?(msg)
    end

    test "tolerates metadata: nil" do
      msg = MessageMarker.mark_user_authored(ReqLLM.Context.user("hi"))
      assert msg.metadata == %{user_authored: true}
      assert MessageMarker.user_authored?(msg)
    end

    test "is total — non-messages pass through and read as false" do
      assert MessageMarker.mark_user_authored(:not_a_message) == :not_a_message
      refute MessageMarker.user_authored?(nil)
      refute MessageMarker.user_authored?(:not_a_message)
      refute MessageMarker.user_authored?(%{metadata: %{user_authored: true}})
      refute MessageMarker.user_authored?(ReqLLM.Context.user("hi"))
      refute MessageMarker.user_authored?(%{ReqLLM.Context.user("hi") | metadata: nil})
    end
  end

  describe "the session's first user turn" do
    test "the wrapped <context>/<objective> turn is marked; the :system persona is not" do
      context = MessageMarker.mark_first_user_authored(tagged_initial_context())
      [system, user] = context.messages

      assert system.role == :system
      refute MessageMarker.user_authored?(system)

      assert user.role == :user
      assert MessageMarker.user_authored?(user)
      assert user.metadata[:turn] == 0
      assert is_integer(user.metadata[:timestamp])
    end

    test "the objective text itself is unchanged (marker is metadata only)" do
      context = MessageMarker.mark_first_user_authored(tagged_initial_context())
      [_system, user] = context.messages
      assert user.content == ReqLLM.Context.user(@objective).content
    end

    test "mark_first_user_authored/1 is total" do
      empty = ReqLLM.Context.new([])
      assert MessageMarker.mark_first_user_authored(empty) == empty
      assert MessageMarker.mark_first_user_authored(:nope) == :nope
    end
  end

  describe "user sends at runtime" do
    test "a drained user message IS marked and keeps its turn tag" do
      assert [msg] = drain(["please also add tests"])
      assert MessageMarker.user_authored?(msg)
      assert msg.metadata[:turn] == 4
      assert is_integer(msg.metadata[:timestamp])
    end

    test "a multimodal user send IS marked" do
      assert [msg] =
               drain([
                 %{text: "look", attachments: [attachment("image", "s.png", "image/png")]}
               ])

      assert MessageMarker.user_authored?(msg)
    end

    test "a mixed batch marks only the user sends" do
      cancel = EvoGit.AgentScheduler.cancel_message()

      assert [human, notice] = drain(["go on", cancel])
      assert MessageMarker.user_authored?(human)
      refute MessageMarker.user_authored?(notice)
    end

    test "the scheduler-injected graceful-cancel notice is NOT marked (yet is still delivered)" do
      cancel = EvoGit.AgentScheduler.cancel_message()
      assert [msg] = drain([cancel])
      refute MessageMarker.user_authored?(msg)
      assert msg.content == ReqLLM.Context.user(cancel).content
      assert msg.metadata[:turn] == 4
    end

    test "build_user_authored_message/2 marks; the neutral builder never does" do
      marked = ContextBuilder.build_user_authored_message("hello", 7)
      neutral = ContextBuilder.build_injected_message("hello", 7)

      assert MessageMarker.user_authored?(marked)
      assert marked.metadata[:turn] == 7
      refute MessageMarker.user_authored?(neutral)
      assert marked.content == neutral.content
    end
  end

  describe "synthetic injections are unmarked" do
    test "background-job notices" do
      text = EvoGit.Agent.BackgroundJobNotice.notice([%{id: "bash-1", status: :exited}])
      refute MessageMarker.user_authored?(ContextBuilder.build_injected_message(text, 2))
    end

    test "turn-limit warnings (every level that can fire)" do
      appended =
        Enum.reduce(6..40, {loop_state(), []}, fn turn, {state, acc} ->
          state = %{state | turn: turn}
          new_state = EvoGit.Agent.Exchange.Warnings.check_limit_warnings(state)
          appended = Enum.drop(new_state.context.messages, length(state.context.messages))
          {new_state, acc ++ appended}
        end)
        |> elem(1)

      assert appended != []
      assert Enum.all?(appended, &(&1.role == :user))
      assert Enum.all?(appended, &(not MessageMarker.user_authored?(&1)))
    end

    test "the empty-response nudge" do
      msg = EvoGit.Agent.LLMPrompting.no_tool_call_nudge_message()
      assert msg.role == :user
      refute MessageMarker.user_authored?(msg)
    end

    test "a compression checkpoint (which keeps its own :checkpoint flag)" do
      msg = EvoGit.Agent.Compression.Checkpoint.checkpoint_message("summary of earlier work")
      assert msg.role == :user
      refute MessageMarker.user_authored?(msg)
      assert msg.metadata[:checkpoint] == true
    end

    test "the runtime-context refresh" do
      state = %{
        node_path: "./",
        repo_path: File.cwd!(),
        parent_id: nil,
        repo_less: false,
        foreign_repos: []
      }

      msg = ContextBuilder.build_context_refresh_message(state, 3)
      assert msg.role == :user
      refute MessageMarker.user_authored?(msg)
      assert msg.metadata[:turn] == 3
    end

    test "the subagent merge-conflict note (the neutral builder it goes through)" do
      note = "Subagent merge result: 1 merged, 0 conflicts."
      refute MessageMarker.user_authored?(ContextBuilder.build_injected_message(note, 5))
    end
  end

  describe "read-model round trip" do
    test "the marker survives a Snapshot built from a state that carries it" do
      context = MessageMarker.mark_first_user_authored(tagged_initial_context())
      state = %{loop_state() | context: context}
      snapshot = EvoGit.Agent.Stream.Snapshot.from(state, :running)

      [_system, user] = snapshot.messages
      assert MessageMarker.user_authored?(user)
    end
  end
end
