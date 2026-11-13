defmodule EvoDashWeb.RealStreamConsumersTest.Provider do
  @moduledoc false
  import ExUnit.Assertions

  @budget 30_000

  # A gated TCP peer, not an LLM/callback override: every byte passes through
  # ReqLLM's real OpenAI SSE decoder and the production Session stream sink.
  def start do
    {:ok, listener} =
      :gen_tcp.listen(0, [:binary, active: false, reuseaddr: true, ip: {127, 0, 0, 1}])

    {:ok, port} = :inet.port(listener)
    owner = self()
    pid = spawn(fn -> accept(listener, owner, 0) end)
    %{pid: pid, listener: listener, url: "http://127.0.0.1:#{port}"}
  end

  def request(provider, index), do: elem(request_with_body(provider, index), 0)

  def request_with_body(%{pid: pid}, index) do
    assert_receive {:provider_request, ^pid, ^index, socket, body}, @budget
    assert body["stream"] == true
    assert is_list(body["messages"])
    {socket, body}
  end

  def unavailable(provider, socket) do
    body =
      Jason.encode!(%{error: %{message: "fixture temporarily unavailable", type: "server_error"}})

    :ok =
      :gen_tcp.send(
        socket,
        "HTTP/1.1 503 Service Unavailable\r\ncontent-type: application/json\r\n" <>
          "content-length: #{byte_size(body)}\r\nconnection: close\r\n\r\n" <> body
      )

    send(provider.pid, :next_request)
  end

  def tool(socket, index, id, path) do
    write(socket, %{
      tool_calls: [
        %{
          index: index,
          id: id,
          type: "function",
          function: %{name: "read", arguments: Jason.encode!(%{file_path: path})}
        }
      ]
    })
  end

  def open(socket, content_length \\ nil) do
    length_header = if content_length, do: "content-length: #{content_length}\r\n", else: ""

    :ok =
      :gen_tcp.send(
        socket,
        "HTTP/1.1 200 OK\r\ncontent-type: text/event-stream\r\n" <>
          length_header <> "connection: close\r\n\r\n"
      )
  end

  # With an advertised Content-Length, early EOF is a genuine transport failure,
  # not a valid SSE response ending at connection close. No fake stream errors.
  def truncate(provider), do: send(provider.pid, :next_request)

  def write(socket, delta, finish \\ nil) do
    chunk = %{
      id: "real-consumer-response",
      object: "chat.completion.chunk",
      model: "activity-test",
      created: 1,
      choices: [%{index: 0, delta: delta, finish_reason: finish}]
    }

    chunk =
      if finish,
        do: Map.put(chunk, :usage, %{prompt_tokens: 32, completion_tokens: 8, total_tokens: 40}),
        else: chunk

    :ok = :gen_tcp.send(socket, "data: " <> Jason.encode!(chunk) <> "\n\n")
  end

  def finish(provider, socket, reason \\ "stop") do
    write(socket, %{}, reason)
    :ok = :gen_tcp.send(socket, "data: [DONE]\n\n")
    send(provider.pid, :next_request)
  end

  def stop(provider) do
    ref = Process.monitor(provider.pid)
    Process.exit(provider.pid, :kill)
    assert_receive {:DOWN, ^ref, :process, _, _}, @budget
    :gen_tcp.close(provider.listener)
  end

  defp accept(listener, owner, index) do
    case :gen_tcp.accept(listener) do
      {:ok, socket} ->
        {headers, rest} = headers(socket, "")
        [_, size] = Regex.run(~r/content-length:\s*(\d+)/i, headers)
        body = body(socket, rest, String.to_integer(size))
        send(owner, {:provider_request, self(), index, socket, Jason.decode!(body)})
        receive do: (:next_request -> :ok)
        :gen_tcp.close(socket)
        accept(listener, owner, index + 1)

      {:error, :closed} ->
        :ok
    end
  end

  defp headers(socket, acc) do
    case String.split(acc, "\r\n\r\n", parts: 2) do
      [headers, rest] ->
        {headers, rest}

      [_] ->
        {:ok, data} = :gen_tcp.recv(socket, 0, @budget)
        headers(socket, acc <> data)
    end
  end

  defp body(_socket, data, size) when byte_size(data) >= size, do: data

  defp body(socket, data, size) do
    {:ok, more} = :gen_tcp.recv(socket, 0, @budget)
    body(socket, data <> more, size)
  end
end

defmodule EvoDashWeb.RealStreamConsumersTest do
  # Forcing globals: the scheduler's account pools/pause state, PeakHourEngine,
  # and mounted HomeLive's shared ChatHistory (also ActiveTasks). No synthetic
  # watch snapshots, stream batches, role substitutes or llm_call overrides.
  use EvoDashWeb.ConnCase, async: false

  import Phoenix.LiveViewTest
  alias EvoDashWeb.RealStreamConsumersTest.Provider
  alias EvoGit.Agent.{Session, Stream}
  alias EvoGit.AgentScheduler
  alias EvoGit.AgentScheduler.{AgentState, SchedMeta, Store}

  @budget 30_000
  @pool "real-stream-consumers"

  setup do
    EvoDash.Test.ConfigDir.isolate!()
    EvoGit.Config.VersionState.complete_onboarding()
    EvoDash.ChatHistory.reset()
    EvoDash.ActiveTasks.reset()
    engine = Process.whereis(EvoGit.PeakHourEngine)
    if engine, do: :sys.suspend(engine)
    original = :sys.get_state(AgentScheduler, @budget)

    # Registered FIRST, so consumers, workers, Session and TCP peer are all
    # monitored and awaited by later callbacks BEFORE restoring global config.
    on_exit(fn ->
      :ok =
        scheduler_config(
          model_profiles: original.model_profiles,
          provider_profiles: original.provider_profiles,
          model_selection_config: original.model_selection_config,
          default_llm_max_concurrency: original.default_llm_max_concurrency
        )

      if original.paused, do: AgentScheduler.pause(), else: AgentScheduler.resume()
      if engine, do: :sys.resume(engine)
      EvoDash.ChatHistory.reset()
      EvoDash.ActiveTasks.reset()
    end)

    :ok = AgentScheduler.resume()

    :ok =
      scheduler_config(
        model_profiles: [%{id: @pool, model: "test:activity", concurrency: 1}],
        default_llm_max_concurrency: 1
      )

    provider = Provider.start()
    on_exit(fn -> Provider.stop(provider) end)
    %{provider: provider}
  end

  test "real producer late attach seeds inspector prefixes and retires exactly once at yield",
       ctx do
    session = start_session(ctx.provider)
    socket = Provider.request(ctx.provider, 0)
    Provider.open(socket)
    Provider.write(socket, %{role: "assistant", reasoning_content: "Inspector thought prefix"})
    Provider.write(socket, %{content: "Inspector answer prefix"})
    prefix = await_call(session, "Inspector answer prefix", "Inspector thought prefix")
    assert prefix.phase == :running
    assert prefix.activity.phase == :llm
    assert is_binary(prefix.activity.current_call.id)
    assert prefix.activity.current_call.turn == prefix.turn
    assert is_integer(prefix.activity.current_call.attempt)
    assert watchers(session) == %{}
    refute Session.watching?(session.pid)

    {:ok, view, _} = live(ctx.conn, "/agents")
    track_consumer(view)
    await(fn -> not assigns(view).agents_loading end)
    view |> element("#agent-card-#{session.id}") |> render_click()
    track_watch_worker(view)

    await(fn ->
      case assigns(view).inspector_stream do
        %{snapshot: snapshot, state: state} when not is_nil(snapshot) ->
          state.response == "Inspector answer prefix" and
            state.thinking == "Inspector thought prefix"

        _ ->
          false
      end
    end)

    assert Map.has_key?(watchers(session), view.pid)

    assert assigns(view).inspector_stream.snapshot.activity.current_call.id ==
             prefix.activity.current_call.id

    assert text(view, "#inspector-stream details pre") == "Inspector thought prefix"
    assert text(view, "#inspector-stream article div pre") == "Inspector answer prefix"
    assert has_element?(view, "#inspector-stream-cursor")
    refute has_element?(view, "#inspector-stream", "No thinking content available")

    Provider.write(socket, %{reasoning_content: " plus suffix"})
    Provider.write(socket, %{content: " plus suffix"})

    await(fn ->
      text(view, "#inspector-stream article div pre") == "Inspector answer prefix plus suffix"
    end)

    assert text(view, "#inspector-stream details pre") == "Inspector thought prefix plus suffix"
    assert length(elements(view, "#inspector-stream article")) == 1
    Provider.finish(ctx.provider, socket)
    assert_yield(session, "Inspector answer prefix plus suffix")

    assert Session.history(session.pid)
           |> Enum.filter(&(&1.role == :assistant))
           |> Enum.map(fn message ->
             message.content
             |> Enum.filter(&(&1.type == :text))
             |> Enum.map_join(& &1.text)
           end) == ["Inspector answer prefix plus suffix"]

    await(
      fn ->
        a = assigns(view)

        a.history_loading_agent_id == nil and
          a.inspector_stream.state.projections == [] and
          Enum.any?(agent_history(view, session.id), &(&1.type == "assistant"))
      end,
      System.monotonic_time(:millisecond) + @budget,
      fn ->
        a = assigns(view)

        inspect(
          %{
            stream: a.inspector_stream.state,
            history:
              Enum.map(agent_history(view, session.id), fn entry ->
                {entry.type,
                 if(entry.type == "assistant", do: entry.data.content, else: :omitted)}
              end),
            loading: a.history_loading_agent_id
          },
          limit: 50
        )
      end
    )

    history = agent_history(view, session.id)
    answers = Enum.filter(history, &(&1.type == "assistant"))
    assert Enum.map(answers, & &1.data.content) == ["Inspector answer prefix plus suffix"]
    assert length(elements(view, "#agent-detail-#{session.id} .inspector-thinking")) == 1

    assert text(view, "#agent-detail-#{session.id} .inspector-thinking .whitespace-pre-wrap") ==
             "Inspector thought prefix plus suffix"

    assert length(Regex.scan(~r/Inspector answer prefix plus suffix/, render(view))) == 1

    refute has_element?(view, "#inspector-stream article")
    refute has_element?(view, "#inspector-stream-cursor")
    assert assigns(view).inspector_stream.state.response == ""
    assert assigns(view).inspector_stream.state.thinking == ""
    stop_consumer(view)
    await(fn -> watchers(session) == %{} end)
  end

  test "real Assistant late attach, yield and actual remount preserve each answer's thinking",
       ctx do
    session = start_session(ctx.provider)
    socket = Provider.request(ctx.provider, 0)
    Provider.open(socket)
    Provider.write(socket, %{role: "assistant", reasoning_content: "First thought prefix"})
    Provider.write(socket, %{content: "First answer prefix"})
    prefix = await_call(session, "First answer prefix", "First thought prefix")
    assert prefix.activity.phase == :llm
    assert watchers(session) == %{}
    refute Session.watching?(session.pid)

    view = mount_assistant(ctx.conn, session)
    await_answers(view, ["First answer prefix"], :streaming)
    assert_thoughts(view, ["First thought prefix"])
    assert has_element?(view, ".help-caret")
    assert Map.has_key?(watchers(session), view.pid)

    Provider.write(socket, %{reasoning_content: " plus suffix"})
    Provider.write(socket, %{content: " plus suffix"})
    await_answers(view, ["First answer prefix plus suffix"], :streaming)
    assert_thoughts(view, ["First thought prefix plus suffix"])
    Provider.finish(ctx.provider, socket)
    assert_yield(session, "First answer prefix plus suffix")
    await(fn -> assigns(view).chat_status == :idle end)
    assert answers(view) == ["First answer prefix plus suffix"]
    assert_thoughts(view, ["First thought prefix plus suffix"])
    refute has_element?(view, ".help-caret")

    stop_consumer(view)
    await(fn -> watchers(session) == %{} end)
    remount = mount_assistant(ctx.conn, session)
    await(fn -> answers(remount) == ["First answer prefix plus suffix"] end)
    assert_thoughts(remount, ["First thought prefix plus suffix"])
    refute has_element?(remount, ".help-caret")

    # Start a second REAL exchange over the same session. Distinct texts make
    # cross-answer reasoning leakage and accidental duplicate replay observable.
    :ok = Session.start_input(session.pid, "A second question")
    second_socket = Provider.request(ctx.provider, 1)
    Provider.open(second_socket)
    Provider.write(second_socket, %{role: "assistant", reasoning_content: "Second thought"})
    Provider.write(second_socket, %{content: "Second answer"})
    second = await_call(session, "Second answer", "Second thought")
    refute second.activity.current_call.id == prefix.activity.current_call.id
    await_answers(remount, ["First answer prefix plus suffix", "Second answer"], :streaming)
    Provider.finish(ctx.provider, second_socket)
    assert_yield(session, "Second answer")
    await(fn -> assigns(remount).chat_status == :idle end)
    assert answers(remount) == ["First answer prefix plus suffix", "Second answer"]
    assert_thoughts(remount, ["First thought prefix plus suffix", "Second thought"])
    refute has_element?(remount, ".help-caret")
    stop_consumer(remount)
    await(fn -> watchers(session) == %{} end)

    final_mount = mount_assistant(ctx.conn, session)
    await(fn -> answers(final_mount) == ["First answer prefix plus suffix", "Second answer"] end)
    assert_thoughts(final_mount, ["First thought prefix plus suffix", "Second thought"])
    refute has_element?(final_mount, ".help-caret")
    stop_consumer(final_mount)
    await(fn -> watchers(session) == %{} end)
  end

  test "Assistant first mounts after a real yield and remounts the complete answer without a caret",
       ctx do
    session = start_session(ctx.provider)
    socket = Provider.request(ctx.provider, 0)
    Provider.open(socket)
    Provider.write(socket, %{role: "assistant", reasoning_content: "Completed thought"})
    Provider.write(socket, %{content: "Completed answer"})
    await_call(session, "Completed answer", "Completed thought")
    assert watchers(session) == %{}
    Provider.finish(ctx.provider, socket)
    assert_yield(session, "Completed answer")

    first = mount_assistant(ctx.conn, session)
    await(fn -> answers(first) == ["Completed answer"] end)
    assert_thoughts(first, ["Completed thought"])
    refute has_element?(first, ".help-caret")
    stop_consumer(first)
    await(fn -> watchers(session) == %{} end)

    second = mount_assistant(ctx.conn, session)
    await(fn -> answers(second) == ["Completed answer"] end)
    assert_thoughts(second, ["Completed thought"])
    refute has_element?(second, ".help-caret")

    :ok = Session.start_input(session.pid, "Continue after remount")
    next_socket = Provider.request(ctx.provider, 1)
    Provider.open(next_socket)
    Provider.write(next_socket, %{role: "assistant", reasoning_content: "Follow-up thought"})
    Provider.write(next_socket, %{content: "Follow-up answer"})
    await_call(session, "Follow-up answer", "Follow-up thought")
    await_answers(second, ["Completed answer", "Follow-up answer"], :streaming)
    Provider.finish(ctx.provider, next_socket)
    assert_yield(session, "Follow-up answer")
    await(fn -> assigns(second).chat_status == :idle end)
    assert answers(second) == ["Completed answer", "Follow-up answer"]
    assert_thoughts(second, ["Completed thought", "Follow-up thought"])
    refute has_element?(second, ".help-caret")
    stop_consumer(second)
    await(fn -> watchers(session) == %{} end)

    final = mount_assistant(ctx.conn, session)
    await(fn -> answers(final) == ["Completed answer", "Follow-up answer"] end)
    assert_thoughts(final, ["Completed thought", "Follow-up thought"])
    refute has_element?(final, ".help-caret")
    stop_consumer(final)
    await(fn -> watchers(session) == %{} end)
  end

  test "Assistant restores two completed real answers with thinking scoped to each answer", ctx do
    session = start_session(ctx.provider)

    for {index, answer, thought} <- [
          {0, "Earlier answer", "Earlier thought"},
          {1, "Later answer", "Later thought"}
        ] do
      if index == 1, do: assert(:ok == Session.start_input(session.pid, "Next question"))
      socket = Provider.request(ctx.provider, index)
      Provider.open(socket)
      Provider.write(socket, %{role: "assistant", reasoning_content: thought})
      Provider.write(socket, %{content: answer})
      await_call(session, answer, thought)
      Provider.finish(ctx.provider, socket)
      assert_yield(session, answer)
      assert watchers(session) == %{}
    end

    first = mount_assistant(ctx.conn, session)
    await(fn -> answers(first) == ["Earlier answer", "Later answer"] end)
    assert_thoughts(first, ["Earlier thought", "Later thought"])
    refute has_element?(first, ".help-caret")
    stop_consumer(first)
    await(fn -> watchers(session) == %{} end)

    remount = mount_assistant(ctx.conn, session)
    await(fn -> answers(remount) == ["Earlier answer", "Later answer"] end)
    assert_thoughts(remount, ["Earlier thought", "Later thought"])
    refute has_element?(remount, ".help-caret")
    stop_consumer(remount)
    await(fn -> watchers(session) == %{} end)
  end

  test "real read tools publish results, retire their call and start a fresh inspector call",
       ctx do
    session = start_session(ctx.provider)
    socket = Provider.request(ctx.provider, 0)
    Provider.open(socket)
    Provider.write(socket, %{role: "assistant", reasoning_content: "Read planning thought"})
    Provider.write(socket, %{content: "Checking the fixture"})
    first = await_call(session, "Checking the fixture", "Read planning thought")
    view = mount_inspector(ctx.conn, session)
    await(fn -> text(view, "#inspector-stream article div pre") == "Checking the fixture" end)
    {:ok, _, _} = Stream.watch(session.pid)

    # A paused scheduler gates the REAL tool-slot acquisition, not tool execution
    # or its result. This makes the otherwise very short :tools phase observable.
    :ok = AgentScheduler.pause()
    Provider.tool(socket, 0, "read-ok", Path.join(session.dir, "fixture.txt"))
    Provider.tool(socket, 1, "read-missing", Path.join(session.dir, "missing.txt"))
    Provider.finish(ctx.provider, socket, "tool_calls")

    await(fn -> text(view, "#inspector-activity") == "Executing tools" end)
    {:ok, during_tools, _} = Stream.snapshot(session.pid)
    assert during_tools.activity.phase == :tools
    assert during_tools.activity.current_call.id == first.activity.current_call.id
    refute has_element?(view, "#inspector-stream-cursor")
    assert text(view, "#inspector-stream details pre") == "Read planning thought"

    :ok = AgentScheduler.resume()
    {next_socket, request} = Provider.request_with_body(ctx.provider, 1)
    tool_messages = Enum.filter(request["messages"], &(&1["role"] == "tool"))
    assert Enum.map(tool_messages, & &1["tool_call_id"]) == ["read-ok", "read-missing"]
    assert Enum.at(tool_messages, 0)["content"] =~ "real tool fixture payload"
    assert Enum.at(tool_messages, 1)["content"] =~ "Error:"

    # The consumer sees production tool events (including the error status), not
    # synthetic batches; a terminal tool_result is the drain boundary here.
    events = receive_events_until(session.id, {:tool_result, "read-missing", :error})
    assert {:tool_call, "read-ok", "read"} in events
    assert {:tool_call, "read-missing", "read"} in events
    assert {:tool_result, "read-ok", :ok} in events
    assert Enum.count(events, &(&1 == {:tool_result, "read-ok", :ok})) == 1
    assert Enum.count(events, &(&1 == {:tool_result, "read-missing", :error})) == 1

    Provider.open(next_socket)
    Provider.write(next_socket, %{role: "assistant", reasoning_content: "After tools thought"})
    Provider.write(next_socket, %{content: "After tools answer"})
    next = await_call(session, "After tools answer", "After tools thought")
    refute next.activity.current_call.id == first.activity.current_call.id
    assert next.activity.current_call.turn > first.activity.current_call.turn
    assert next.activity.current_call.attempt == 0
    await(fn -> text(view, "#inspector-stream article div pre") == "After tools answer" end)
    assert text(view, "#inspector-stream details pre") == "After tools thought"
    assert length(elements(view, "#inspector-stream article")) == 1
    refute text(view, "#inspector-stream") =~ "Read planning thought"

    Provider.finish(ctx.provider, next_socket)
    assert_yield(session, "After tools answer")
    await(fn -> assigns(view).inspector_stream.state.projections == [] end)
    history = Session.history(session.pid)
    assert Enum.count(history, &(&1.role == :tool)) == 2
    assert Enum.count(history, &(&1.role == :assistant)) == 2
    refute has_element?(view, "#inspector-stream-cursor")
    Stream.unwatch(session.pid)
    stop_consumer(view)
    await(fn -> watchers(session) == %{} end)
  end

  test "real HTTP retry replaces inspector call identity within the same turn", ctx do
    # 503 is not retried internally by ReqLLM's Finch streaming transport (unlike
    # 429). The next request therefore exercises EvoGit's actual attempt loop.
    ExUnit.CaptureLog.capture_log(fn ->
      session = start_session(ctx.provider, max_retries: 1)
      socket = Provider.request(ctx.provider, 0)
      {:ok, first, _} = Stream.snapshot(session.pid)
      assert first.activity.phase == :llm
      assert first.activity.current_call.attempt == 0
      view = mount_inspector(ctx.conn, session)
      {:ok, _, _} = Stream.watch(session.pid)
      Provider.unavailable(ctx.provider, socket)

      next_socket = Provider.request(ctx.provider, 1)
      {:ok, retry, _} = Stream.snapshot(session.pid)
      assert retry.activity.phase == :llm
      assert retry.activity.current_call.attempt == 1
      assert retry.activity.current_call.turn == first.activity.current_call.turn
      refute retry.activity.current_call.id == first.activity.current_call.id
      assert retry.activity.current_call.text == ""
      assert retry.activity.current_call.thinking == ""

      events = receive_events_until(session.id, {:activity, retry.activity})
      assert {:activity, %{phase: :retry_wait, current_call: nil}} in events
      Provider.open(next_socket)
      Provider.write(next_socket, %{role: "assistant", reasoning_content: "Recovered thought"})
      Provider.write(next_socket, %{content: "Recovered answer"})
      await_call(session, "Recovered answer", "Recovered thought")
      await(fn -> text(view, "#inspector-stream article div pre") == "Recovered answer" end)
      assert text(view, "#inspector-stream details pre") == "Recovered thought"
      assert length(elements(view, "#inspector-stream article")) == 1
      assert has_element?(view, "#inspector-stream-cursor")
      Provider.finish(ctx.provider, next_socket)
      assert_yield(session, "Recovered answer")
      await(fn -> assigns(view).inspector_stream.state.projections == [] end)
      assert Enum.count(Session.history(session.pid), &(&1.role == :assistant)) == 1
      Stream.unwatch(session.pid)
      stop_consumer(view)
      await(fn -> watchers(session) == %{} end)
    end)
    |> then(fn log -> assert log =~ "LLM request failed, retrying" end)
  end

  test "a truncated real SSE attempt cannot leak its inspector excerpts into the retry", ctx do
    ExUnit.CaptureLog.capture_log(fn ->
      session = start_session(ctx.provider, max_retries: 1)
      socket = Provider.request(ctx.provider, 0)
      Provider.open(socket, 100_000)
      Provider.write(socket, %{role: "assistant", reasoning_content: "Abandoned thought"})
      Provider.write(socket, %{content: "Abandoned answer"})
      first = await_call(session, "Abandoned answer", "Abandoned thought")
      view = mount_inspector(ctx.conn, session)
      await(fn -> text(view, "#inspector-stream article div pre") == "Abandoned answer" end)
      assert text(view, "#inspector-stream details pre") == "Abandoned thought"
      {:ok, _, _} = Stream.watch(session.pid)
      Provider.truncate(ctx.provider)

      next_socket = Provider.request(ctx.provider, 1)
      {:ok, retry, _} = Stream.snapshot(session.pid)
      assert retry.activity.current_call.attempt == 1
      assert retry.activity.current_call.turn == first.activity.current_call.turn
      refute retry.activity.current_call.id == first.activity.current_call.id
      assert retry.activity.current_call.text == ""
      assert retry.activity.current_call.thinking == ""
      events = receive_events_until(session.id, {:activity, retry.activity})
      assert {:activity, %{phase: :retry_wait, current_call: nil}} in events
      await(fn -> assigns(view).inspector_stream.state.response == "" end)
      assert assigns(view).inspector_stream.state.thinking == ""
      refute text(view, "#inspector-stream") =~ "Abandoned"

      Provider.open(next_socket)
      Provider.write(next_socket, %{role: "assistant", reasoning_content: "Replacement thought"})
      Provider.write(next_socket, %{content: "Replacement answer"})
      await_call(session, "Replacement answer", "Replacement thought")
      await(fn -> text(view, "#inspector-stream article div pre") == "Replacement answer" end)
      assert text(view, "#inspector-stream details pre") == "Replacement thought"
      assert length(elements(view, "#inspector-stream article")) == 1
      Provider.finish(ctx.provider, next_socket)
      assert_yield(session, "Replacement answer")
      await(fn -> assigns(view).inspector_stream.state.projections == [] end)
      history = Session.history(session.pid)
      assert Enum.count(history, &(&1.role == :assistant)) == 1
      refute inspect(history) =~ "Abandoned"
      Stream.unwatch(session.pid)
      stop_consumer(view)
      await(fn -> watchers(session) == %{} end)
    end)
    |> then(fn log -> assert log =~ "LLM request failed, retrying" end)
  end

  for page <- [:inspector, :assistant] do
    @page page
    test "real one-shot #{@page} receives its final handoff only after Session death", ctx do
      session = start_session(ctx.provider, mode: :oneshot)
      socket = Provider.request(ctx.provider, 0)
      Provider.open(socket)
      Provider.write(socket, %{role: "assistant", reasoning_content: "Terminal thought"})
      Provider.write(socket, %{content: "Terminal answer"})
      assert await_call(session, "Terminal answer", "Terminal thought").mode == :oneshot

      view =
        case @page do
          :inspector ->
            view = mount_inspector(ctx.conn, session)
            await(fn -> text(view, "#inspector-stream article div pre") == "Terminal answer" end)
            view

          :assistant ->
            view = mount_assistant(ctx.conn, session)
            await_answers(view, ["Terminal answer"], :streaming)
            view
        end

      await(fn -> Map.has_key?(watchers(session), view.pid) end)
      owner = self()
      key = if @page == :inspector, do: :agents_history_runner, else: :home_agent_history_runner
      previous = Application.fetch_env(:evo_dash, key)

      on_exit(fn ->
        case previous do
          {:ok, runner} -> Application.put_env(:evo_dash, key, runner)
          :error -> Application.delete_env(:evo_dash, key)
        end
      end)

      Application.put_env(:evo_dash, key, fn target, id ->
        send(owner, {:unexpected_terminal_history_read, id})
        EvoDash.NodeContext.get_agent_history(target, id)
      end)

      # The suffix is NEVER rendered while the producer exists. Inspect the real
      # consumer mailbox after DOWN: no fabricated snapshot, handoff or delta.
      ref = Process.monitor(session.pid)
      :ok = :sys.suspend(view.pid)

      on_exit({:resume, view.pid}, fn ->
        ExUnit.CaptureLog.capture_log(fn ->
          resume_consumer(view)
          stop_consumer(view)
        end)
      end)

      Provider.write(socket, %{reasoning_content: " after suspension"})
      Provider.write(socket, %{content: " after suspension"})
      await_call(session, "Terminal answer after suspension", "Terminal thought after suspension")
      Provider.finish(ctx.provider, socket)
      id = session.id
      pid = session.pid
      assert_receive {:agent_session_result, ^id, ^pid, {:ok, result}}, @budget
      assert result.result == "Terminal answer after suspension"
      assert_receive {:DOWN, ^ref, :process, ^pid, :normal}, @budget
      refute Process.alive?(pid)
      assert {:error, {:not_found, _reason}} = Stream.watch(id)
      assert {:error, {:not_found, _reason}} = Stream.snapshot(id)

      {:messages, queued} = Process.info(view.pid, :messages)

      assert [{:agent_stream_closed, ^id, snapshot, seq}] =
               Enum.filter(queued, &match?({:agent_stream_closed, ^id, _, _}, &1))

      assert %Stream.Snapshot{agent_id: ^id, phase: :done, seq: ^seq, mode: :oneshot} = snapshot
      assert snapshot.activity == %{phase: :idle, current_call: nil}
      assert is_integer(seq) and seq > 0
      assert Enum.any?(snapshot.messages, &(&1.role == :assistant))
      :ok = :sys.resume(view.pid)

      case @page do
        :inspector ->
          await(fn -> assigns(view).inspector_stream.snapshot == snapshot end)

          assert text(view, "#agent-detail-#{id} .inspector-thinking .whitespace-pre-wrap") ==
                   "Terminal thought after suspension"

          assert length(Regex.scan(~r/Terminal answer after suspension/, render(view))) == 1
          assert text(view, "#agent-detail-#{id}") =~ "DONE"
          refute has_element?(view, "#inspector-stream-cursor")
          refute has_element?(view, "#inspector-stream article")

        :assistant ->
          await(fn ->
            a = assigns(view)
            a.chat_status == :ended and a.chat_stream.snapshot == snapshot
          end)

          assert assigns(view).chat_task_status == :completed
          assert answers(view) == ["Terminal answer after suspension"]
          assert_thoughts(view, ["Terminal thought after suspension"])
          refute has_element?(view, ".help-caret")
          assert Enum.all?(assigns(view).transcript, &(not &1.streaming))
      end

      stop_consumer(view)
      refute_receive {:unexpected_terminal_history_read, ^id}, 0
    end
  end

  test "an unwatched real one-shot leaves no terminal Session to attach to", ctx do
    session = start_session(ctx.provider, mode: :oneshot)
    socket = Provider.request(ctx.provider, 0)
    Provider.open(socket)
    Provider.write(socket, %{role: "assistant", reasoning_content: "Unwatched thought"})
    Provider.write(socket, %{content: "Unwatched answer"})
    await_call(session, "Unwatched answer", "Unwatched thought")
    assert watchers(session) == %{}
    ref = Process.monitor(session.pid)
    Provider.finish(ctx.provider, socket)
    pid = session.pid
    assert_receive {:DOWN, ^ref, :process, ^pid, :normal}, @budget
    assert {:error, {:not_found, _reason}} = Stream.watch(session.id)
    assert {:error, {:not_found, _reason}} = Stream.snapshot(session.id)
  end

  defp resume_consumer(view) do
    if Process.alive?(view.pid), do: :sys.resume(view.pid)
  catch
    # Teardown only: LiveViewTest may already have stopped the suspended owner.
    :exit, {:noproc, _} -> :ok
  end

  defp mount_inspector(conn, session) do
    {:ok, view, _} = live(conn, "/agents")
    track_consumer(view)
    await(fn -> not assigns(view).agents_loading end)
    view |> element("#agent-card-#{session.id}") |> render_click()
    track_watch_worker(view)
    await(fn -> assigns(view).inspector_stream.snapshot != nil end)
    view
  end

  defp receive_events_until(id, terminal, acc \\ []) do
    assert_receive {:agent_delta, ^id, _seq, batch}, @budget
    events = acc ++ batch
    if terminal in events, do: events, else: receive_events_until(id, terminal, events)
  end

  defp scheduler_config(opts), do: GenServer.call(AgentScheduler, {:update_config, opts}, @budget)

  defp start_session(provider, opts \\ []) do
    id = 35_000_000 + System.unique_integer([:positive, :monotonic])
    mode = Keyword.get(opts, :mode, :interactive)
    dir = Path.join(System.tmp_dir!(), "real_stream_consumers_#{id}")
    File.mkdir_p!(dir)
    File.write!(Path.join(dir, "fixture.txt"), "real tool fixture payload\n")
    node = %EvoGit.Core.ContextNode{path: "./", repo: dir}

    spec = %EvoGit.AgentSpec{
      context_node: node,
      phylo_node: nil,
      agent_module: EvoGit.Agents.SelfReflective,
      objective: "Explain the first answer",
      opts: [repo_less: true, task_tmpdir: dir]
    }

    meta = %SchedMeta{
      id: id,
      depth: 0,
      task_id: "real-consumer-#{id}",
      spec: spec,
      status: :running
    }

    :ok =
      Store.put_agent_state(id, %AgentState{
        context_node: node,
        objective: spec.objective,
        llm_model: %{provider: :openai, id: "activity-test", base_url: provider.url},
        llm_generation_params: [api_key: "loopback-fixture-only"],
        model_id: @pool,
        max_turns: 16,
        max_retries: Keyword.get(opts, :max_retries, 0),
        max_depth: 1,
        repo_root: dir,
        mode: mode
      })

    :ok = Store.put_sched_meta(id, meta)

    {:ok, pid} =
      Session.start_link(
        agent_id: id,
        depth: 0,
        repo_root: dir,
        repo_id: "primary",
        worktree_path: Path.join(dir, "unused"),
        retries: 0,
        spec: spec,
        meta: meta,
        repo_less: true,
        repo_less_repo_path: dir,
        session_mode: mode,
        scheduler: self()
      )

    Process.unlink(pid)
    session = %{id: id, pid: pid, dir: dir}

    on_exit(fn ->
      {_, data} = if Process.alive?(pid), do: :sys.get_state(pid, @budget), else: {nil, %{}}

      workers =
        case data[:worker] do
          %Task{pid: worker} -> [worker]
          _ -> []
        end

      # ReqLLM starts linked stream processes below the exchange worker. Await
      # them inside the same capture window as force cancellation: otherwise a
      # failed regression leaks their expected :killed report between tests.
      descendants =
        Enum.filter(Process.list(), fn process ->
          case Process.info(process, :dictionary) do
            {:dictionary, dict} ->
              lineage = Keyword.get(dict, :"$callers", []) ++ Keyword.get(dict, :"$ancestors", [])
              Enum.any?(workers, &(&1 in lineage))

            nil ->
              false
          end
        end)

      refs = Enum.map(Enum.uniq([pid | workers ++ descendants]), &{&1, Process.monitor(&1)})

      ExUnit.CaptureLog.capture_log(fn ->
        _ = Session.cancel(pid, :force)

        for {process, ref} <- refs do
          assert_receive {:DOWN, ^ref, :process, ^process, _}, @budget
        end
      end)

      # A force-stopped blocked provider can leave its slot grant queued. Remove
      # only this fixture's identity before the scheduler pools are restored.
      :sys.replace_state(AgentScheduler, fn state ->
        holders = Map.new(state.llm_holders, fn {key, ids} -> {key, MapSet.delete(ids, id)} end)

        waiting =
          Map.new(state.llm_waiting, fn {key, queue} ->
            {key, :queue.filter(fn entry -> elem(entry, 0) != id end, queue)}
          end)

        %{
          state
          | llm_holders: holders,
            llm_waiting: waiting,
            tool_holders: MapSet.delete(state.tool_holders, id),
            tool_waiting:
              :queue.filter(fn {agent_id, _from} -> agent_id != id end, state.tool_waiting)
        }
      end)

      Store.delete_agent_state(id)
      Store.delete_sched_meta(id)
      Store.clear_cancel_requested(id)
      File.rm_rf!(dir)
    end)

    session
  end

  defp await_call(session, text, thinking) do
    await(fn ->
      case Stream.snapshot(session.pid) do
        {:ok, %{activity: %{current_call: %{text: ^text, thinking: ^thinking}}}, _} -> true
        _ -> false
      end
    end)

    {:ok, snapshot, _} = Stream.snapshot(session.pid)
    snapshot
  end

  defp assert_yield(%{id: id, pid: pid} = session, expected_answer) do
    assert_receive {:agent_session_yield, ^id, ^pid, ^expected_answer}, @budget

    await(fn ->
      case Stream.snapshot(session.pid) do
        {:ok, %{phase: :awaiting_input, activity: %{phase: :idle, current_call: nil}}, _} -> true
        _ -> false
      end
    end)

    {:ok, snapshot, _} = Stream.snapshot(session.pid)
    assert snapshot.phase == :awaiting_input
    assert snapshot.activity == %{phase: :idle, current_call: nil}
    assert elem(:sys.get_state(session.pid, @budget), 1).worker == nil
  end

  defp watchers(session), do: elem(:sys.get_state(session.pid, @budget), 1).watchers

  defp mount_assistant(conn, session) do
    {:ok, view, _} = live(conn, "/assistant?session=#{session.id}")
    track_consumer(view)

    await(fn ->
      a = assigns(view)

      a.session_id == session.id and a[:chat_status] in [:running, :idle] and
        match?(%{delta: %{seq: seq}} when is_integer(seq), a[:chat_stream])
    end)

    view
  end

  defp track_consumer(view) do
    on_exit({:consumer, view.pid}, fn -> stop_consumer(view) end)
  end

  defp track_watch_worker(view) do
    worker = assigns(view).inspector_stream_worker

    on_exit({:watch_worker, worker}, fn ->
      ref = Process.monitor(worker)
      stop_consumer(view)
      assert_receive {:DOWN, ^ref, :process, ^worker, _}, @budget
    end)
  end

  defp stop_consumer(view) do
    # Capture supervised attach/history children before stopping the owner;
    # already-exited children need no waiting. Watch workers monitor the owner.
    children = Task.Supervisor.children(EvoDash.TaskSupervisor)

    owned =
      Enum.filter(children, fn pid ->
        case Process.info(pid, :dictionary) do
          {:dictionary, dict} -> view.pid in Keyword.get(dict, :"$callers", [])
          nil -> false
        end
      end)

    refs = Enum.map([view.pid | owned], &{&1, Process.monitor(&1)})
    if Process.alive?(view.pid), do: GenServer.stop(view.pid, :normal, @budget)

    for {pid, ref} <- refs do
      assert_receive {:DOWN, ^ref, :process, ^pid, _}, @budget
    end
  catch
    # Teardown only: LiveViewTest may have stopped its consumer already.
    :exit, {:noproc, _} -> :ok
  end

  defp agent_history(view, id), do: Enum.find(assigns(view).agents, &(&1.id == id)).history
  defp assigns(view), do: :sys.get_state(view.pid, @budget).socket.assigns

  defp elements(view, selector),
    do: view |> render() |> Floki.parse_document!() |> Floki.find(selector)

  defp text(view, selector), do: elements(view, selector) |> Floki.text() |> String.trim()

  defp answers(view),
    do:
      elements(view, "#chat-messages button[id^='assistant-copy-'][data-content]")
      |> Floki.attribute("data-content")

  defp await_answers(view, expected, :streaming) do
    await(
      fn ->
        assigns(view).transcript |> Enum.filter(&(&1.role == :assistant)) |> Enum.map(& &1.text) ==
          expected
      end,
      System.monotonic_time(:millisecond) + @budget,
      fn ->
        inspect(
          Map.take(assigns(view), [:transcript, :chat_stream, :chat_status]),
          limit: :infinity
        )
      end
    )

    rows = Enum.filter(assigns(view).transcript, &(&1.role == :assistant))

    for {row, answer} <- Enum.zip(rows, expected) do
      if row.streaming do
        assert text(view, "#chat-entry-#{row.id} .whitespace-pre-wrap") =~ answer
      else
        assert elements(view, "#chat-entry-#{row.id} button[data-content]")
               |> Floki.attribute("data-content") == [answer]
      end
    end
  end

  defp assert_thoughts(view, expected) do
    rows = Enum.filter(assigns(view).transcript, &(&1.role == :assistant))
    assert length(rows) == length(expected)

    for {row, thought} <- Enum.zip(rows, expected) do
      assert length(elements(view, "#chat-entry-#{row.id} details")) == 1,
             "Expected one thinking disclosure for #{inspect(row.text)}, got: #{inspect(row.reasoning)}"

      assert text(view, "#chat-entry-#{row.id} details .italic.whitespace-pre-wrap") == thought
    end

    assert length(elements(view, "#chat-messages details summary")) == length(expected)
  end

  defp await(predicate), do: await(predicate, System.monotonic_time(:millisecond) + @budget)

  defp await(predicate, deadline),
    do: await(predicate, deadline, fn -> "Real stream consumer did not settle" end)

  defp await(predicate, deadline, diagnostics) do
    if predicate.() do
      :ok
    else
      assert System.monotonic_time(:millisecond) < deadline, diagnostics.()
      Process.sleep(2)
      await(predicate, deadline, diagnostics)
    end
  end
end
