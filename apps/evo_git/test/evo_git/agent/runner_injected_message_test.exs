defmodule EvoGit.Agent.RunnerInjectedMessageTest do
  @moduledoc """
  Runner-side coverage of multimodal INJECTED (mid-run) user messages.

  A message queued for a running agent (dashboard/RPC → `pending_user_messages`)
  may be a legacy plain `String.t()` or a `%{text:, attachments:}` map carrying
  images/audio (see `EvoGit.Attachments.message/1`). The drain at the top of
  `Runner.loop/1` (`Runner.drain_and_inject_user_messages/1`, public `@doc false`
  so it can be driven directly) materializes EACH drained message through the
  pure `EvoGit.Agent.ContextBuilder.build_injected_message/2` and appends it as a
  turn-tagged user message:

    * legacy binary / no media → plain `user(text)`;
    * attachments present → `user([ContentPart.text(text) | media…])`.

  There is NO root gate on injected messages: an agent at ANY depth may receive
  media this way (the root-only gate covers the `:attachments` TASK OPT only —
  the initial user message, see `ContextBuilder.build_initial_messages/4`).

  `async: true` — the cases seed ONE row in the app-global named
  `:evogit_agent_state` ETS table, keyed by a per-test unique agent id from this
  file's own id range, and delete exactly that row on exit. Nothing is asserted
  about the table as a whole, so the writes are concurrent-safe.
  """

  use ExUnit.Case, async: true

  alias EvoGit.Agent.ContextBuilder
  alias EvoGit.Agent.LoopState
  alias EvoGit.Agent.Runner
  alias EvoGit.AgentScheduler.AgentState
  alias EvoGit.AgentScheduler.Store
  alias EvoGit.Core.ContextNode
  alias EvoGit.Core.PhyloGraphNode

  @turn 5

  setup do
    create_ets_if_missing(:evogit_agent_state)
    create_ets_if_missing(:evogit_sched_meta)

    # This file's own id range keeps the row unshared with every other module
    # that seeds the same app-global tables concurrently.
    agent_id = 9_960_000 + :erlang.unique_integer([:positive])
    on_exit(fn -> delete_agent_rows(agent_id) end)

    %{agent_id: agent_id}
  end

  # ---------------------------------------------------------------------------
  # Harness
  # ---------------------------------------------------------------------------

  defp create_ets_if_missing(name) do
    if :ets.whereis(name) == :undefined do
      :ets.new(name, [:set, :named_table, :public])
    end
  end

  # Deletes ONLY this test's rows — never another module's.
  defp delete_agent_rows(agent_id) do
    if :ets.whereis(:evogit_agent_state) != :undefined,
      do: :ets.delete(:evogit_agent_state, agent_id)

    if :ets.whereis(:evogit_sched_meta) != :undefined,
      do: :ets.delete(:evogit_sched_meta, agent_id)
  end

  # Seeds the agent's pending-message queue EXACTLY as the scheduler's queue
  # append would (a direct state write, so the test does not depend on the
  # queue's own normalization/validation).
  defp seed_pending_queue(agent_id, pending) do
    Store.put_agent_state(agent_id, %AgentState{
      context_node: %ContextNode{path: "./", repo: "/tmp/test"},
      phylo_node: %PhyloGraphNode{repo: "/tmp/test", base_commit: "abc", current_commit: "abc"},
      llm_model: "test:model",
      max_retries: 3,
      max_depth: 8,
      pending_user_messages: pending
    })
  end

  defp loop_state(agent_id) do
    %LoopState{
      agent_id: agent_id,
      agent_module: __MODULE__,
      depth: 0,
      node_path: "./",
      context: ReqLLM.Context.new([]),
      turn: @turn
    }
  end

  defp drain(agent_id, pending) do
    seed_pending_queue(agent_id, pending)

    loop_state(agent_id)
    |> Runner.drain_and_inject_user_messages()
    |> Map.fetch!(:context)
    |> Map.fetch!(:messages)
  end

  defp attachment(type, name, media_type, raw) do
    %{
      "type" => type,
      "name" => name,
      "media_type" => media_type,
      "data" => Base.encode64(raw)
    }
  end

  # ---------------------------------------------------------------------------
  # Materialization
  # ---------------------------------------------------------------------------

  test "a drained map message with an image produces user([text | image])", %{agent_id: agent_id} do
    message = %{
      text: "Look at this screenshot",
      attachments: [attachment("image", "shot.png", "image/png", <<1, 2, 3>>)]
    }

    assert [msg] = drain(agent_id, [message])

    assert msg.role == :user

    assert msg.content == [
             ReqLLM.Message.ContentPart.text("Look at this screenshot"),
             ReqLLM.Message.ContentPart.image(<<1, 2, 3>>, "image/png")
           ]

    assert msg.metadata[:turn] == @turn
  end

  test "a drained audio attachment rides as a file part", %{agent_id: agent_id} do
    message = %{
      text: "Transcribe this",
      attachments: [attachment("audio", "clip.mp3", "audio/mpeg", <<4, 5, 6>>)]
    }

    assert [msg] = drain(agent_id, [message])

    assert msg.content == [
             ReqLLM.Message.ContentPart.text("Transcribe this"),
             ReqLLM.Message.ContentPart.file(<<4, 5, 6>>, "clip.mp3", "audio/mpeg")
           ]
  end

  test "a drained string-keyed map (Codec / RPC shape) is materialized the same way", %{
    agent_id: agent_id
  } do
    message = %{
      "text" => "Wire shape",
      "attachments" => [attachment("image", "w.png", "image/png", <<7>>)]
    }

    assert [msg] = drain(agent_id, [message])

    assert msg.content == [
             ReqLLM.Message.ContentPart.text("Wire shape"),
             ReqLLM.Message.ContentPart.image(<<7>>, "image/png")
           ]
  end

  test "a drained legacy binary produces the plain user(text) message", %{agent_id: agent_id} do
    assert [msg] = drain(agent_id, ["please wrap it up"])

    assert msg.role == :user
    # Same bytes as the legacy injection path: one text part, nothing else.
    assert msg.content == ReqLLM.Context.user("please wrap it up").content
    assert msg.content == [ReqLLM.Message.ContentPart.text("please wrap it up")]
    assert msg.metadata[:turn] == @turn
    assert is_integer(msg.metadata[:timestamp])
  end

  test "a map message without media (attachments: []) takes the plain-text path", %{
    agent_id: agent_id
  } do
    assert [msg] = drain(agent_id, [%{text: "no media here", attachments: []}])
    assert msg.content == [ReqLLM.Message.ContentPart.text("no media here")]
  end

  test "a mixed batch is drained in order, each message materialized on its own", %{
    agent_id: agent_id
  } do
    image = %{
      text: "first (with image)",
      attachments: [attachment("image", "a.png", "image/png", <<9>>)]
    }

    assert [m1, m2, m3] =
             drain(agent_id, [image, "second (legacy)", %{text: "third", attachments: nil}])

    assert m1.content == [
             ReqLLM.Message.ContentPart.text("first (with image)"),
             ReqLLM.Message.ContentPart.image(<<9>>, "image/png")
           ]

    assert m2.content == [ReqLLM.Message.ContentPart.text("second (legacy)")]
    assert m3.content == [ReqLLM.Message.ContentPart.text("third")]

    assert Enum.all?([m1, m2, m3], &(&1.metadata[:turn] == @turn))
  end

  test "messages are appended AFTER the existing context (nothing is replaced)", %{
    agent_id: agent_id
  } do
    seed_pending_queue(agent_id, ["injected"])

    state = loop_state(agent_id)
    existing = ReqLLM.Context.user("already here")
    state = %{state | context: ReqLLM.Context.append(state.context, existing)}

    new_state = Runner.drain_and_inject_user_messages(state)

    assert [first, injected] = new_state.context.messages
    assert first.content == existing.content
    assert injected.content == [ReqLLM.Message.ContentPart.text("injected")]
  end

  test "the queue is emptied by the drain (a second drain is a no-op)", %{agent_id: agent_id} do
    seed_pending_queue(agent_id, ["once"])

    state = loop_state(agent_id)
    drained = Runner.drain_and_inject_user_messages(state)

    assert [%ReqLLM.Message{}] = drained.context.messages
    assert Store.drain_pending_user_messages(agent_id) == []
  end

  test "an empty queue leaves the state untouched", %{agent_id: agent_id} do
    seed_pending_queue(agent_id, [])

    state = loop_state(agent_id)
    assert Runner.drain_and_inject_user_messages(state) == state
  end

  test "no root gate — media is materialized for an injected message via build_injected_message/2 (arity 2, no parent input)",
       %{agent_id: agent_id} do
    # `function_exported?/3` is a BIF that does NOT load its module, so this
    # module (`async: true`) must load it first — otherwise the answer depends on
    # whether some OTHER test happened to load it already.
    Code.ensure_loaded!(ContextBuilder)

    assert function_exported?(ContextBuilder, :build_injected_message, 2)

    message = %{
      text: "media for any depth",
      attachments: [attachment("image", "d.png", "image/png", <<5>>)]
    }

    assert [msg] = drain(agent_id, [message])
    assert length(msg.content) == 2
  end
end
