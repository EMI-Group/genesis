defmodule EvoDashWeb.AgentsStreamRenderTest do
  use ExUnit.Case, async: true

  import Phoenix.LiveViewTest, only: [render_component: 2]

  alias EvoDashWeb.AgentsLive
  alias EvoDashWeb.AgentsLive.RuntimeStream

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

  defp watch(flight \\ nil, snapshot_fields \\ %{}) do
    snapshot =
      Map.merge(
        %{agent_id: @agent_id, seq: 10, phase: :running, activity: :llm, in_flight: flight},
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

  defp flight(overrides \\ %{}) do
    Map.merge(
      %{
        message_index: 7,
        turn: 2,
        response: "Live response <not markup>",
        thinking: "Live reasoning & evidence",
        capture_coverage: :complete,
        generation_complete: false
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
    dom = page(watch(flight()), agent: %{history: [checkpoint()]})

    assert text(dom, "#inspector-stream h4") == "Live activity"
    assert text(dom, "#inspector-live-message-7 details summary") == "Thinking"
    assert text(dom, "#inspector-live-message-7 details pre") == "Live reasoning & evidence"
    assert text(dom, "#inspector-live-message-7 > div pre") == "Live response <not markup>"
    assert text(dom, "#inspector-live-message-7 > div .font-medium") == "Response"
    assert Floki.find(dom, "#inspector-live-message-7 pre not") == []

    assert text(dom, "#agent-history-entry-41-0 .inspector-thinking .whitespace-pre-wrap") ==
             "Checkpoint reasoning"

    assert words(dom, "#agent-history-entry-41-0 .text-sm") == "Response Checkpoint response"
    refute text(live(dom), "pre") =~ "Checkpoint"
    refute text(dom, "#agent-history-entry-41-0") =~ "Live reasoning"
  end

  test "authoritative llm phase animates generation even after tool announcements and results" do
    stream =
      watch(flight())
      |> batch([{:tool_call, "call-1", "read"}, {:tool_result, "call-1", :ok}])

    dom = page(stream)
    assert text(dom, "#inspector-activity") == "Generating response"
    assert attr(dom, "#inspector-thinking", "role") == ["status"]
    assert attr(dom, "#inspector-thinking", "aria-label") == ["Generating response"]
    assert attr(dom, "#inspector-stream-cursor", "aria-hidden") == ["true"]
    assert attr(dom, "#inspector-thinking", "class") |> hd() =~ "motion-reduce:animate-none"
    assert attr(dom, "#inspector-stream-cursor", "class") |> hd() =~ "motion-reduce:animate-none"
    assert text(dom, "#inspector-live-message-7 li") == "readCompleted"
  end

  test "authoritative tools phase stops llm indicators without hiding response or thinking" do
    dom =
      watch(flight())
      |> batch([{:activity, %{phase: :tools}}, {:thinking, " still retained"}])
      |> page()

    assert text(dom, "#inspector-activity") == "Executing tools"
    assert Floki.find(dom, "#inspector-thinking, #inspector-stream-cursor") == []

    assert text(dom, "#inspector-live-message-7 details pre") ==
             "Live reasoning & evidence still retained"

    assert text(dom, "#inspector-live-message-7 > div pre") == "Live response <not markup>"
  end

  test "missing activity never infers generation or tools from chunks or running lifecycle" do
    dom =
      watch(nil, %{activity: nil})
      |> batch([
        {:thinking, "Observed thought"},
        {:text, "Observed reply"},
        {:tool_call, "c", "rg"}
      ])
      |> page()

    assert text(dom, "#inspector-activity") == "Activity unavailable"
    assert Floki.find(dom, "#inspector-thinking, #inspector-stream-cursor") == []
    assert text(live(dom), "details pre") == "Observed thought"
    assert text(live(dom), "article > div pre") == "Observed reply"
    assert text(live(dom), "li") == "rgAnnounced"
  end

  test "no-thinking notice requires completed generation, explicit complete capture and empty thinking" do
    for generation_complete <- [false, true], capture_coverage <- [:partial, :complete] do
      dom =
        flight(%{
          thinking: "",
          generation_complete: generation_complete,
          capture_coverage: capture_coverage
        })
        |> watch()
        |> page()

      notices =
        Floki.find(live(dom), "article > p")
        |> Enum.map(&Floki.text/1)
        |> Enum.map(&String.trim/1)

      expected =
        if generation_complete and capture_coverage == :complete, do: [@no_thinking], else: []

      assert notices == expected,
             "generation_complete=#{generation_complete}, capture_coverage=#{capture_coverage}"

      assert Floki.find(live(dom), "details") == []
      assert text(live(dom), "article > div pre") == "Live response <not markup>"
    end
  end

  test "missing thinking in a purported complete snapshot cannot fabricate no-thinking" do
    dom =
      flight(%{generation_complete: true})
      |> Map.delete(:thinking)
      |> watch()
      |> page()

    refute text(live(dom), "article") =~ @no_thinking
    assert Floki.find(live(dom), "details") == []
    assert text(live(dom), "article > div pre") == "Live response <not markup>"
  end

  test "completed captured thinking stays visible and never receives a no-thinking notice" do
    dom = watch(flight(%{generation_complete: true})) |> page()

    assert text(live(dom), "details pre") == "Live reasoning & evidence"
    assert text(live(dom), "article > div pre") == "Live response <not markup>"
    refute text(live(dom), "article") =~ @no_thinking
    assert Floki.find(dom, "#inspector-thinking, #inspector-stream-cursor") == []
  end

  test "a late message-start cannot turn a partially captured text-only answer into no-thinking" do
    dom =
      watch(flight(%{thinking: "", capture_coverage: :partial}))
      |> batch([{:message_start, %{message_index: 7, turn: 2}}, {:turn, %{turn: 2}}])
      |> page()

    refute text(live(dom), "article") =~ @no_thinking
    assert text(live(dom), "article > div pre") == "Live response <not markup>"
    assert Floki.find(live(dom), "details") == []
  end

  test "failed or cancelled lifecycle is not proof that thinking generation completed" do
    for status <- [:failed, :cancelled] do
      dom =
        watch()
        |> batch([
          {:message_start, %{message_index: 8, turn: 3}},
          {:text, "Unfinished response"},
          {:finished, status}
        ])
        |> page()

      refute text(live(dom), "article") =~ @no_thinking
      assert text(live(dom), "article > div pre") == "Unfinished response"
      assert Floki.find(dom, "#inspector-thinking, #inspector-stream-cursor") == []
    end
  end

  test "a fully observed empty-thinking message gains a notice only when its generation ends" do
    stream =
      watch()
      |> batch([{:message_start, %{message_index: 8, turn: 3}}, {:text, "Text-only answer"}])

    refute text(page(stream) |> live(), "article") =~ @no_thinking

    dom = stream |> batch([{:turn, %{turn: 3}}]) |> page()
    assert text(live(dom), "article > p") == @no_thinking
    assert text(live(dom), "article > div pre") == "Text-only answer"
    assert Floki.find(dom, "#inspector-thinking, #inspector-stream-cursor") == []
  end

  test "message animation keys are unique, stable across chunks, and wrap both parts and expansion" do
    first = watch(flight())
    updated = batch(first, [{:text, " plus more"}, {:thinking, " plus evidence"}])
    first_dom = page(first)
    updated_dom = page(updated)

    assert attr(first_dom, @history, "phx-hook") == ["InspectorMessages"]
    assert attr(first_dom, "[phx-hook='InspectorMessages']", "id") == ["agent-history-41"]
    assert messages(first_dom) == ["live-7"]
    assert messages(updated_dom) == messages(first_dom)
    assert scope(updated_dom) == scope(first_dom)

    assert attr(updated_dom, "#{@history} [data-inspector-message]", "id") ==
             ["inspector-live-message-7"]

    assert Floki.find(updated_dom, "#inspector-live-message-7 details[open]") == []
    assert text(updated_dom, "#inspector-live-message-7 details summary") == "Thinking"

    assert text(updated_dom, "#inspector-live-message-7 details pre") ==
             "Live reasoning & evidence plus evidence"

    assert text(updated_dom, "#inspector-live-message-7 > div pre") ==
             "Live response <not markup> plus more"

    assert Floki.find(updated_dom, "#inspector-live-message-7 details [data-inspector-message]") ==
             []

    assert Floki.find(updated_dom, "#inspector-live-message-7 [phx-hook]") == []
    assert Floki.find(updated_dom, "#{@history} .inspector-message-enter") == []

    second =
      updated
      |> batch([
        {:turn, %{turn: 2}},
        {:message_start, %{message_index: 9, turn: 3}},
        {:text, "Second response"},
        {:thinking, "Second thought"}
      ])
      |> page()

    assert messages(second) == ["live-7", "live-9"]

    assert attr(second, "#{@history} [data-inspector-message]", "id") ==
             ["inspector-live-message-7", "inspector-live-message-9"]

    assert text(second, "#inspector-live-message-7 details pre") ==
             "Live reasoning & evidence plus evidence"

    assert text(second, "#inspector-live-message-9 details pre") == "Second thought"
    assert text(second, "#inspector-live-message-9 > div pre") == "Second response"
    assert attr(second, "#inspector-stream-cursor", "id") == ["inspector-stream-cursor"]
    assert Floki.find(second, "#inspector-live-message-7 #inspector-stream-cursor") == []
    assert Floki.find(second, "#inspector-live-message-9 #inspector-stream-cursor") != []
  end

  test "animation scope includes target, node, agent, attachment token and snapshot baseline" do
    stream = watch(flight())
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

  test "checkpoint coverage is identity-gated and independently scoped to response and thinking" do
    flight = flight(%{generation_complete: true})
    stream = watch(flight)
    entry = checkpoint(flight.response, flight.thinking)
    row = "#agent-history-entry-41-0"

    # Matching text alone is not proof that a live excerpt covers a checkpoint.
    unowned = page(stream, agent: %{history: [entry]})
    assert text(unowned, "#{row} .inspector-thinking .whitespace-pre-wrap") == flight.thinking
    assert words(unowned, "#{row} .text-sm") == "Response " <> flight.response
    assert Floki.find(unowned, "#{row} > .space-y-2 > p") == []

    owned = put_in(entry, [:data, :metadata], %{message_index: 7, turn: 2})
    response_only = put_in(owned, [:data, :reasoning_details], [%{text: "Different reasoning"}])
    dom = page(stream, agent: %{history: [response_only]})
    assert text(dom, "#{row} > .space-y-2 > p") == "Response shown in live activity above."
    assert Floki.find(dom, "#{row} .text-sm") == []
    assert text(dom, "#{row} .inspector-thinking .whitespace-pre-wrap") == "Different reasoning"

    thinking_only = put_in(owned, [:data, :content], "Different response")
    dom = page(stream, agent: %{history: [thinking_only]})
    assert Floki.find(dom, "#{row} .inspector-thinking") == []
    assert words(dom, "#{row} .text-sm") == "Response Different response"
    assert Floki.find(dom, "#{row} > .space-y-2 > p") == []

    # Partial attachment must preserve BOTH checkpoint parts, even with identity
    # and exact text equality; excerpt overlap cannot establish full capture.
    partial = watch(%{flight | capture_coverage: :partial})
    dom = page(partial, agent: %{history: [owned]})
    assert text(dom, "#{row} .inspector-thinking .whitespace-pre-wrap") == flight.thinking
    assert words(dom, "#{row} .text-sm") == "Response " <> flight.response
    assert Floki.find(dom, "#{row} > .space-y-2 > p") == []
  end

  test "checkpoint entries retain independent animation keys and full-message expansion payloads" do
    response = String.duplicate("Response body ", 30)
    thinking = String.duplicate("Thinking body ", 30)
    entry = checkpoint(response, thinking)
    stream = watch(flight())
    dom = page(stream, agent: %{history: [entry]}, selected_history_entry: entry)
    row = "#agent-history-entry-41-0"

    assert messages(dom) == ["live-7", "0-#{:erlang.phash2(entry)}"]
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
