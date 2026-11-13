defmodule EvoDashWeb.AgentsStreamRenderTest do
  use ExUnit.Case, async: true

  import Phoenix.LiveViewTest, only: [render_component: 2]

  alias EvoDashWeb.AgentsLive
  alias EvoDashWeb.AgentsLive.{RuntimeStream, StreamPresentation}
  alias EvoGit.Agent.Stream.Snapshot

  @agent_id 41
  @history "#agent-history-41"
  @no_thinking "No thinking content available"

  # Render the public page API, not a mounted LiveView: these presentation-only
  # fixtures never subscribe, start loaders, touch app env or write shared hubs.
  defp page(stream, overrides \\ []) do
    agent =
      Map.merge(
        %{
          id: @agent_id,
          task_local_id: 1,
          status: :running,
          agent_module: EvoGit.Agents.Coder,
          model_label: "Fixture account - fixture model",
          context_path: "./",
          objective: "Inspect streamed activity",
          worktree: nil,
          task_number: 1,
          task_id: "render-only-task",
          depth: 0,
          retries: 0,
          base_commit: nil,
          current_commit: nil,
          parent_id: nil,
          has_children: false,
          children: [],
          history: []
        },
        Keyword.get(overrides, :agent, %{})
      )

    assigns = [
      flash: %{},
      config_status: nil,
      current_node: node(),
      current_node_id: nil,
      current_node_name: "Local",
      remote_status: %{phase: :connected},
      running_tasks: [],
      pending_tasks: [],
      desktop_quit_confirm: false,
      update_status: nil,
      guide: nil,
      agents: [agent],
      agents_loading: false,
      agents_error: nil,
      left_view: :tree,
      repo_trees: [],
      id_to_display: %{@agent_id => 1},
      new_agent_ids: MapSet.new(),
      changed_status_ids: MapSet.new(),
      selected_agent_id: agent.id,
      selected_history_entry: nil,
      selected_objective: nil,
      send_message_agent_id: nil,
      show_usage: false,
      optimistic_messages: %{},
      inspector_stream: stream,
      inspector_stream_token: 3,
      inspector_history_error: false,
      history_loading_agent_id: nil
    ]

    render_component(
      &AgentsLive.render/1,
      Keyword.merge(assigns, Keyword.delete(overrides, :agent))
    )
    |> Floki.parse_document!()
  end

  defp watch(call \\ call(), phase \\ :llm, snapshot_fields \\ %{}) do
    snapshot =
      Map.merge(
        %Snapshot{agent_id: @agent_id, seq: 10, phase: :running, activity: activity(phase, call)},
        snapshot_fields
      )

    %{
      snapshot: snapshot,
      error: nil,
      state: RuntimeStream.new(@agent_id, node()) |> RuntimeStream.seed(snapshot, snapshot.seq)
    }
  end

  defp batch(stream, events) do
    %{
      stream
      | state: RuntimeStream.apply_batch(stream.state, @agent_id, stream.state.seq + 1, events)
    }
  end

  defp activity(phase, call), do: %{phase: phase, current_call: call}

  defp call(overrides \\ %{}) do
    Map.merge(
      %{
        id: "render-call-2-1",
        turn: 2,
        attempt: 1,
        text: "Live response <not markup>",
        thinking: "Live reasoning & evidence"
      },
      overrides
    )
  end

  defp checkpoint(response \\ "Checkpoint response", thinking \\ "Checkpoint reasoning") do
    %{
      type: "assistant",
      turn: 1,
      timestamp: nil,
      data: %{
        content: response,
        reasoning_details: [%{text: thinking}],
        tool_calls: [],
        metadata: %{}
      }
    }
  end

  defp text(dom, selector), do: dom |> Floki.find(selector) |> Floki.text() |> String.trim()
  defp words(dom, selector), do: dom |> text(selector) |> String.replace(~r/\s+/, " ")
  defp attr(dom, selector, name), do: dom |> Floki.find(selector) |> Floki.attribute(name)
  defp live(dom), do: Floki.find(dom, "#inspector-stream")

  defp messages(dom),
    do: attr(dom, "#{@history} [data-inspector-message]", "data-inspector-message")

  defp scope(dom), do: attr(dom, "[phx-hook='InspectorMessages']", "data-inspector-scope")

  test "page presents live response and thinking separately from checkpoint history" do
    dom = page(watch(), agent: %{history: [checkpoint()]})

    assert text(dom, "#inspector-stream h4") == "Live activity"
    assert text(dom, "#inspector-live-message-0 details summary") == "Thinking"
    assert text(dom, "#inspector-live-message-0 details pre") == "Live reasoning & evidence"
    assert text(dom, "#inspector-live-message-0 > div pre") == "Live response <not markup>"
    assert text(dom, "#inspector-live-message-0 > div .font-medium") == "Response"
    assert Floki.find(dom, "#inspector-live-message-0 pre not") == []

    assert text(dom, "#agent-history-entry-41-0 .inspector-thinking .whitespace-pre-wrap") ==
             "Checkpoint reasoning"

    assert words(dom, "#agent-history-entry-41-0 .text-sm") == "Response Checkpoint response"
    refute text(live(dom), "pre") =~ "Checkpoint"
    refute text(dom, "#agent-history-entry-41-0") =~ "Live reasoning"
  end

  test "authoritative llm phase animates generation even after tool announcements and results" do
    stream = watch() |> batch([{:tool_call, "call-1", "read"}, {:tool_result, "call-1", :ok}])

    dom = page(stream)
    assert text(dom, "#inspector-activity") == "Generating response"
    assert attr(dom, "#inspector-thinking", "role") == ["status"]
    assert attr(dom, "#inspector-thinking", "aria-label") == ["Generating response"]
    assert attr(dom, "#inspector-stream-cursor", "aria-hidden") == ["true"]
    assert attr(dom, "#inspector-thinking", "class") |> hd() =~ "motion-reduce:animate-none"
    assert attr(dom, "#inspector-stream-cursor", "class") |> hd() =~ "motion-reduce:animate-none"
    assert text(dom, "#inspector-live-message-0 li") == "readCompleted"
  end

  test "authoritative activity phases are independent of the running snapshot lifecycle" do
    for phase <- [:idle, :llm_waiting, :llm, :llm_complete, :retry_wait, :tools] do
      stream = watch(call(), phase)
      dom = page(stream)
      assert stream.state.phase == :running
      assert stream.state.activity == phase
      assert text(live(dom), "details pre") == "Live reasoning & evidence"
      assert text(live(dom), "article > div pre") == "Live response <not markup>"
      assert Floki.find(dom, "#inspector-thinking") != [] == (phase == :llm)
      assert Floki.find(dom, "#inspector-stream-cursor") != [] == (phase == :llm)
    end

    dom = watch() |> batch([{:activity, activity(:tools, call())}]) |> page()
    assert text(dom, "#inspector-activity") == "Executing tools"
  end

  test "missing activity never infers a call from chunks, tool announcements or running lifecycle" do
    dom =
      watch(nil, :idle, %{activity: nil})
      |> batch([
        {:thinking, "Unowned thought"},
        {:text, "Unowned reply"},
        {:tool_call, "c", "rg"}
      ])
      |> page()

    assert text(dom, "#inspector-activity") == "Activity unavailable"
    assert Floki.find(dom, "#inspector-thinking, #inspector-stream-cursor") == []
    assert Floki.find(live(dom), "article") == []
    refute text(live(dom), "pre") =~ "Unowned"
  end

  test "no-thinking notice requires successful generation and explicitly captured empty thinking" do
    for phase <- [:llm, :llm_complete, :retry_wait, :tools], complete? <- [false, true] do
      current = call(%{thinking: ""})
      current = if complete?, do: current, else: Map.delete(current, :thinking)
      dom = watch(current, phase) |> page()

      notices =
        Floki.find(live(dom), "article > p")
        |> Enum.map(&Floki.text/1)
        |> Enum.map(&String.trim/1)

      expected = if phase in [:llm_complete, :tools] and complete?, do: [@no_thinking], else: []
      assert notices == expected, "phase=#{phase}, explicit thinking=#{complete?}"
      assert Floki.find(live(dom), "details") == []
      assert text(live(dom), "article > div pre") == "Live response <not markup>"
    end
  end

  test "missing response in a completed snapshot cannot fabricate complete capture" do
    dom = call(%{thinking: ""}) |> Map.delete(:text) |> watch(:llm_complete) |> page()
    refute text(live(dom), "article") =~ @no_thinking
    assert Floki.find(live(dom), "details") == []
  end

  test "completed captured thinking stays visible and never receives a no-thinking notice" do
    dom = watch(call(), :llm_complete) |> page()

    assert text(live(dom), "details pre") == "Live reasoning & evidence"
    assert text(live(dom), "article > div pre") == "Live response <not markup>"
    refute text(live(dom), "article") =~ @no_thinking
    assert Floki.find(dom, "#inspector-thinking, #inspector-stream-cursor") == []
  end

  test "turn accounting and lifecycle failure do not establish successful generation" do
    for status <- [:failed, :cancelled] do
      stream = watch(call(%{thinking: ""})) |> batch([{:turn, %{turn: 2}}])
      refute text(page(stream) |> live(), "article") =~ @no_thinking

      dom = stream |> batch([{:finished, status}]) |> page()
      refute text(live(dom), "article") =~ @no_thinking
      assert text(live(dom), "article > div pre") == "Live response <not markup>"
      assert Floki.find(dom, "#inspector-thinking, #inspector-stream-cursor") == []
    end
  end

  test "full replacements retain a stable key but replace rather than duplicate accumulated chunks" do
    current = call(%{thinking: "", text: "Text-only"})
    stream = watch(current) |> batch([{:text, " answer"}])
    refute text(page(stream) |> live(), "article") =~ @no_thinking

    complete = %{current | text: "Text-only answer"}
    stream = batch(stream, [{:activity, activity(:llm_complete, complete)}])
    dom = page(stream)
    assert text(live(dom), "article > p") == @no_thinking
    assert text(live(dom), "article > div pre") == "Text-only answer"
    assert messages(dom) == ["live-0"]
    assert Floki.find(dom, "#inspector-thinking, #inspector-stream-cursor") == []

    repeated = batch(stream, [{:activity, activity(:llm_complete, complete)}]) |> page()
    assert text(live(repeated), "article > div pre") == "Text-only answer"
    assert messages(repeated) == messages(dom)
  end

  test "animation keys are stable across chunks and replacements but a retry replaces the old call" do
    first = watch()
    updated = batch(first, [{:text, " plus more"}, {:thinking, " plus evidence"}])
    first_dom = page(first)
    updated_dom = page(updated)

    assert attr(first_dom, @history, "phx-hook") == ["InspectorMessages"]
    assert attr(first_dom, "[phx-hook='InspectorMessages']", "id") == ["agent-history-41"]
    assert messages(first_dom) == ["live-0"]
    assert messages(updated_dom) == messages(first_dom)
    assert scope(updated_dom) == scope(first_dom)

    assert attr(updated_dom, "#{@history} [data-inspector-message]", "id") ==
             ["inspector-live-message-0"]

    assert Floki.find(updated_dom, "#inspector-live-message-0 details[open]") == []
    assert text(updated_dom, "#inspector-live-message-0 details summary") == "Thinking"

    assert text(updated_dom, "#inspector-live-message-0 details pre") ==
             "Live reasoning & evidence plus evidence"

    assert text(updated_dom, "#inspector-live-message-0 > div pre") ==
             "Live response <not markup> plus more"

    assert Floki.find(updated_dom, "#inspector-live-message-0 details [data-inspector-message]") ==
             []

    assert Floki.find(updated_dom, "#inspector-live-message-0 [phx-hook]") == []
    assert Floki.find(updated_dom, "#{@history} .inspector-message-enter") == []

    replacement = call(%{text: "Replacement response", thinking: "Replacement thought"})
    replaced = batch(updated, [{:activity, activity(:retry_wait, replacement)}])
    assert messages(page(replaced)) == ["live-0"]
    assert text(live(page(replaced)), "article > div pre") == "Replacement response"

    retry =
      call(%{
        id: "render-call-2-2",
        attempt: 2,
        text: "Retry response",
        thinking: "Retry thought"
      })

    second = replaced |> batch([{:activity, activity(:llm, retry)}]) |> page()
    assert messages(second) == ["live-1"]

    assert attr(second, "#{@history} [data-inspector-message]", "id") == [
             "inspector-live-message-1"
           ]

    assert Floki.find(second, "#inspector-live-message-0") == []
    assert text(second, "#inspector-live-message-1 details pre") == "Retry thought"
    assert text(second, "#inspector-live-message-1 > div pre") == "Retry response"
    assert attr(second, "#inspector-stream-cursor", "id") == ["inspector-stream-cursor"]
    assert Floki.find(second, "#inspector-live-message-1 #inspector-stream-cursor") != []
  end

  test "animation scope includes target, node, agent, attachment token and snapshot baseline" do
    stream = watch()
    assert scope(page(stream)) == ["local:#{node()}:41:3:10"]

    assert scope(page(stream, current_node_id: "remote-target", current_node: :remote@host)) ==
             ["remote-target:remote@host:41:3:10"]

    assert scope(page(stream, agent: %{id: 42})) == ["local:#{node()}:42:3:10"]
    assert scope(page(stream, inspector_stream_token: 4)) == ["local:#{node()}:41:4:10"]

    assert scope(page(%{stream | snapshot: %{stream.snapshot | seq: 20}})) ==
             ["local:#{node()}:41:3:20"]

    assert scope(page(%{stream | snapshot: nil})) == ["local:#{node()}:41:3:pending"]
    assert scope(page(nil)) == ["local:#{node()}:41:3:pending"]
    assert Floki.find(page(nil), "#inspector-stream") == []
  end

  test "checkpoint parts are never guessed away; explicit retirement leaves one authoritative copy" do
    current = call()
    stream = watch(current, :llm_complete)
    entry = checkpoint(current.text, current.thinking)
    row = "#agent-history-entry-41-0"

    # Even apparent matching metadata cannot establish checkpoint coverage.
    # Call ids belong to live attempts; history has no producer coverage watermark.
    entry = put_in(entry, [:data, :metadata], %{id: current.id, message_index: 0, turn: 2})
    dom = page(stream, agent: %{history: [entry]})
    assert text(dom, "#{row} .inspector-thinking .whitespace-pre-wrap") == current.thinking
    assert words(dom, "#{row} .text-sm") == "Response " <> current.text
    assert Floki.find(dom, "#{row} > .space-y-2 > p") == []

    retired = batch(stream, [{:activity, activity(:idle, nil)}])
    dom = page(retired, agent: %{history: [entry]})
    assert messages(dom) == ["0-#{:erlang.phash2(entry)}"]
    assert Floki.find(live(dom), "article") == []
    assert text(dom, "#{row} .inspector-thinking .whitespace-pre-wrap") == current.thinking
    assert words(dom, "#{row} .text-sm") == "Response " <> current.text
    assert length(Floki.find(dom, "#{row}")) == 1

    # Neither yield text nor unowned chunks can resurrect a retired call.
    late =
      batch(retired, [
        {:text, current.text},
        {:thinking, current.thinking},
        {:yield, current.text}
      ])

    assert messages(page(late, agent: %{history: [entry]})) == messages(dom)
  end

  test "large full replacements remain bounded and retirement clears all live excerpts" do
    cap = RuntimeStream.max_text_bytes()

    current =
      call(%{text: String.duplicate("x", cap + 37), thinking: String.duplicate("y", cap + 19)})

    stream = watch(current, :llm_complete)
    repeated = batch(stream, [{:activity, activity(:llm_complete, current)}])
    assert byte_size(repeated.state.response) == cap
    assert byte_size(repeated.state.thinking) == cap
    assert [projection] = repeated.state.projections
    assert projection.omitted_response_bytes == 37
    assert projection.omitted_thinking_bytes == 19
    dom = page(repeated)

    assert String.length(text(live(dom), "article > div pre")) ==
             StreamPresentation.max_characters()

    assert String.length(text(live(dom), "details pre")) == StreamPresentation.max_characters()
    refute text(live(dom), "article") =~ @no_thinking

    retired = batch(repeated, [{:activity, activity(:idle, nil)}])
    assert retired.state.projections == []
    assert retired.state.response == ""
    assert retired.state.thinking == ""
    assert Floki.find(live(page(retired)), "article") == []
  end

  test "checkpoint entries retain independent animation keys and full-message expansion payloads" do
    response = String.duplicate("Response body ", 30)
    thinking = String.duplicate("Thinking body ", 30)
    entry = checkpoint(response, thinking)
    stream = watch()
    dom = page(stream, agent: %{history: [entry]}, selected_history_entry: entry)
    row = "#agent-history-entry-41-0"

    assert messages(dom) == ["live-0", "0-#{:erlang.phash2(entry)}"]
    assert attr(dom, "#{row} button[phx-click='view_full_message']", "phx-value-index") == ["0"]

    assert text(dom, "#{row} .inspector-thinking .whitespace-pre-wrap") ==
             String.slice(thinking, 0, 200) <> "..."

    assert words(dom, "#{row} .text-sm") == "Response " <> String.slice(response, 0, 300) <> "..."
    assert text(dom, "#full-message-modal h4") == "ThinkingResponse"

    assert dom |> Floki.find("#full-message-modal pre") |> Enum.map(&Floki.text/1) ==
             [thinking, response]

    assert Floki.find(
             dom,
             "#full-message-modal [data-inspector-message], #full-message-modal [phx-hook]"
           ) == []

    assert attr(dom, "#full-message-modal button[phx-click='close_message_modal']", "phx-click") ==
             ["close_message_modal"]

    updated = page(batch(stream, [{:text, " delta"}]), agent: %{history: [entry]})
    assert messages(updated) == messages(dom)
    assert scope(updated) == scope(dom)
  end
end
