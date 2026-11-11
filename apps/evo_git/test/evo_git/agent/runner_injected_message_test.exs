defmodule EvoGit.Agent.RunnerInjectedMessageTest do
  @moduledoc """
  Exchange-engine coverage of multimodal INJECTED (mid-run) user messages.

  A message queued for a running agent (dashboard/RPC → `pending_user_messages`)
  may be a legacy plain `String.t()` or a `%{text:, attachments:}` map carrying
  images/audio (see `EvoGit.Attachments.message/1`). The drain at the top of
  `EvoGit.Agent.Exchange.run/2`
  (`EvoGit.Agent.Exchange.Pending.drain_and_inject_user_messages/2`) materializes
  EACH drained message through the pure
  `EvoGit.Agent.ContextBuilder.build_injected_message/2` and appends it as a
  turn-tagged user message:

    * legacy binary / no media → plain `user(text)`;
    * attachments present → `user([ContentPart.text(text) | media…])`.

  There is NO root gate on injected messages: an agent at ANY depth may receive
  media this way (the root-only gate covers the `:attachments` TASK OPT only —
  the initial user message, see `ContextBuilder.build_initial_messages/4`).

  `async: true` — every case is a pure function of `%EvoGit.Agent.State{}` plus
  its OWN in-memory `:scheduler` seam (`EvoGit.Agent.Exchange.Seams`), so the
  engine runs in this plain ExUnit process with no scheduler and no ETS row.
  The returned state — not an ETS write — is the authority: these tests assert
  on the state the helper hands back.
  """

  use ExUnit.Case, async: true

  alias EvoGit.Agent.ContextBuilder
  alias EvoGit.Agent.Exchange.Pending
  alias EvoGit.Agent.State

  @turn 5

  setup do
    # This file's own id range keeps the agent identity unshared with every
    # other module. No ETS row is written: the scheduler seam is in-memory.
    agent_id = 9_960_000 + :erlang.unique_integer([:positive])

    %{agent_id: agent_id}
  end

  # ---------------------------------------------------------------------------
  # Harness
  # ---------------------------------------------------------------------------

  # Builds the pure `:scheduler` seam (`EvoGit.Agent.Exchange.Seams`) for one
  # test: an IN-MEMORY stand-in for the scheduler's per-agent control plane, so
  # the engine runs with no scheduler and no ETS row.
  #
  #   * `queue` — the pending user-message queue; `:drain_inputs` POPS it, so a
  #     second drain is a no-op exactly as the real queue behaves;
  #   * `calls` — every `{kind, payload}` interaction, in order.
  #
  # Assertions observe this record for the control-plane interactions (the
  # emptied queue) and the RETURNED state for the conversation itself.
  defp scheduler_stub(opts \\ []) do
    {:ok, pid} = Agent.start_link(fn -> %{queue: Keyword.get(opts, :queue, []), calls: []} end)

    {fn kind, payload, _state -> interact(pid, kind, payload) end, pid}
  end

  defp interact(pid, kind, payload) do
    Agent.get_and_update(pid, fn stub ->
      stub = %{stub | calls: stub.calls ++ [{kind, payload}]}

      case kind do
        :drain_inputs -> {stub.queue, %{stub | queue: []}}
      end
    end)
  end

  defp calls(pid), do: Agent.get(pid, & &1.calls)
  defp kinds(pid), do: for({kind, _payload} <- calls(pid), do: kind)
  defp queue(pid), do: Agent.get(pid, & &1.queue)

  defp loop_state(agent_id) do
    %State{
      agent_id: agent_id,
      agent_module: __MODULE__,
      depth: 0,
      node_path: "./",
      context: ReqLLM.Context.new([]),
      turn: @turn
    }
  end

  defp drain(agent_id, pending) do
    {seam, _stub} = scheduler_stub(queue: pending)

    loop_state(agent_id)
    |> Pending.drain_and_inject_user_messages(scheduler: seam)
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
    {seam, stub} = scheduler_stub(queue: ["injected"])

    state = loop_state(agent_id)
    existing = ReqLLM.Context.user("already here")
    state = %{state | context: ReqLLM.Context.append(state.context, existing)}

    new_state = Pending.drain_and_inject_user_messages(state, scheduler: seam)

    assert [first, injected] = new_state.context.messages
    assert first.content == existing.content
    assert injected.content == [ReqLLM.Message.ContentPart.text("injected")]

    # The returned state IS the updated conversation (the engine publishes it at
    # the next turn boundary through `:checkpoint`) — nothing else was touched.
    assert new_state.context == ReqLLM.Context.append(state.context, injected)

    assert kinds(stub) == [:drain_inputs]
  end

  test "the queue is emptied by the drain (a second drain is a no-op)", %{agent_id: agent_id} do
    {seam, stub} = scheduler_stub(queue: ["once"])

    state = loop_state(agent_id)
    drained = Pending.drain_and_inject_user_messages(state, scheduler: seam)

    assert [%ReqLLM.Message{}] = drained.context.messages
    # The queue itself is empty now: the drain POPPED it.
    assert queue(stub) == []

    # A second drain therefore adds nothing (and touches nothing).
    assert Pending.drain_and_inject_user_messages(drained, scheduler: seam) == drained
    assert kinds(stub) == [:drain_inputs, :drain_inputs]
  end

  test "an empty queue leaves the state untouched", %{agent_id: agent_id} do
    {seam, stub} = scheduler_stub()

    state = loop_state(agent_id)
    assert Pending.drain_and_inject_user_messages(state, scheduler: seam) == state

    # A drain that found nothing touched no context at all.
    assert kinds(stub) == [:drain_inputs]
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
