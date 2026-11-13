defmodule EvoGit.Agent.LLMPromptingActivityTest do
  @moduledoc """
  Real LLMPrompting -> scheduler -> ReqLLM -> loopback HTTP activity boundaries.
  Unlike the stream/session exchange seams, these tests do not replace the LLM
  call or invoke its callbacks themselves. The TCP peer holds each response
  until explicitly released, so active-call observations cannot race completion.

  Serialized for the app-global AgentScheduler's model pools and pause state,
  PeakHourEngine suspension, and the multi-value :llm_retry_backoff_base_ms app
  env seam. Only uniquely keyed production-shaped summary rows are inserted.
  Credentials are supplied per request; no external LLM endpoint is contacted.
  Session snapshot/retirement semantics belong to the child session/ suites;
  here we assert the exact worker-identified events emitted at the real boundary.
  """
  use ExUnit.Case, async: false

  alias EvoGit.Agent.LLMPrompting
  alias EvoGit.Agent.Stream.{Interrupted, Sink}
  alias EvoGit.AgentScheduler
  alias EvoGit.AgentScheduler.{AgentState, Store}

  @pool "llm-prompting-activity"
  @deadline 30_000
  @turn 7

  setup do
    engine = Process.whereis(EvoGit.PeakHourEngine)
    if engine, do: :sys.suspend(engine)
    original = :sys.get_state(AgentScheduler)
    backoff = Application.fetch_env(:evo_git, :llm_retry_backoff_base_ms)

    on_exit(fn ->
      :ok =
        AgentScheduler.update_config(
          model_profiles: original.model_profiles,
          provider_profiles: original.provider_profiles,
          model_selection_config: original.model_selection_config,
          default_llm_max_concurrency: original.default_llm_max_concurrency
        )

      if original.paused, do: AgentScheduler.pause(), else: AgentScheduler.resume()

      case backoff do
        {:ok, value} -> Application.put_env(:evo_git, :llm_retry_backoff_base_ms, value)
        :error -> Application.delete_env(:evo_git, :llm_retry_backoff_base_ms)
      end

      if engine, do: :sys.resume(engine)
    end)

    Application.put_env(:evo_git, :llm_retry_backoff_base_ms, 0)
    :ok = AgentScheduler.resume()

    :ok =
      AgentScheduler.update_config(
        model_profiles: [%{id: @pool, model: "test:activity", concurrency: 1}],
        default_llm_max_concurrency: 1
      )

    server = start_provider()
    id = 9_980_000 + System.unique_integer([:positive, :monotonic])

    Store.put_agent_state(id, %AgentState{
      context_node: %EvoGit.Core.ContextNode{path: "./", repo: File.cwd!()},
      max_retries: 3,
      max_depth: 1,
      model_id: @pool,
      llm_model: %{provider: :openai, id: "activity-test", base_url: server.url}
    })

    on_exit(fn ->
      # A failed assertion can leave a killed worker queued. Remove only our id,
      # including its pending slot request, before restoring the scheduler pools.
      :sys.replace_state(AgentScheduler, fn state ->
        holders = Map.new(state.llm_holders, fn {key, ids} -> {key, MapSet.delete(ids, id)} end)

        waiting =
          Map.new(state.llm_waiting, fn {key, queue} ->
            {key, :queue.filter(fn entry -> elem(entry, 0) != id end, queue)}
          end)

        %{state | llm_holders: holders, llm_waiting: waiting}
      end)

      Store.delete_agent_state(id)
    end)

    %{id: id, server: server}
  end

  test "slot queue is waiting, provider entry is active, and decoded chunks precede completion",
       ctx do
    :ok = AgentScheduler.pause()
    worker = start_call(ctx.id, :retry, 0)
    call = started(worker, 0)
    await_pool(:waiting, 1)
    refute_received {:activity, ^worker, {:call_phase, ^call, :llm}}
    refute_received {:provider_request, _, _, _}

    :ok = AgentScheduler.resume()
    phase(worker, call, :llm)
    socket = request(ctx.server, 0)
    open_stream(socket)
    send_chunk(socket, %{role: "assistant", reasoning_content: "planning"})
    chunk(worker, call, :thinking, "planning")
    send_chunk(socket, %{content: "answer"})
    chunk(worker, call, :text, "answer")
    refute_received {:activity, ^worker, {:call_phase, ^call, :llm_complete}}

    finish_stream(ctx.server, socket)
    phase(worker, call, :llm_complete)
    assert_receive {:prompt_result, ^worker, {:ok, response, duration}, ^call}, @deadline
    assert ReqLLM.Response.text(response) == "answer"
    assert is_integer(duration) and duration >= 0
    await_pool(:used, 0)
    refute_received {:activity, ^worker, {:call_phase, ^call, :retry_wait}}
  end

  test "failed attempt retires before a fresh retry waits for and enters its own slot", ctx do
    worker = start_call(ctx.id, :retry, 1)
    first = started(worker, 0)
    phase(worker, first, :llm)
    socket = request(ctx.server, 0)

    # Pause BEFORE the failure is released: the retry cannot acquire its slot
    # even with a zero backoff. No timed race against a retry sleep is needed.
    :ok = AgentScheduler.pause()
    send_error(ctx.server, socket, 500)
    phase(worker, first, :retry_wait)

    second = started(worker, 1)
    assert second != first
    await_pool(:waiting, 1)
    await_pool(:used, 0)
    refute_received {:activity, ^worker, {:call_phase, ^second, :llm}}
    refute_received {:provider_request, _, 1, _}

    :ok = AgentScheduler.resume()
    phase(worker, second, :llm)
    socket = request(ctx.server, 1)
    open_stream(socket)
    send_chunk(socket, %{role: "assistant", content: "retry succeeded"})
    chunk(worker, second, :text, "retry succeeded")
    finish_stream(ctx.server, socket)
    phase(worker, second, :llm_complete)
    assert_receive {:prompt_result, ^worker, {:ok, response, _}, ^second}, @deadline
    assert ReqLLM.Response.text(response) == "retry succeeded"
    refute_received {:provider_request, _, 2, _}
  end

  test "empty-response nudge starts a new call even though its attempt index resets to zero",
       ctx do
    worker = start_call(ctx.id, :prompt, 0)
    first = started(worker, 0)
    phase(worker, first, :llm)
    {socket, first_body} = request_with_body(ctx.server, 0)
    open_stream(socket)
    send_chunk(socket, %{role: "assistant"})
    finish_stream(ctx.server, socket)
    phase(worker, first, :llm_complete)

    second = started(worker, 0)
    assert second != first
    phase(worker, second, :llm)
    {socket, second_body} = request_with_body(ctx.server, 1)

    assert Enum.take(second_body["messages"], length(first_body["messages"])) ==
             first_body["messages"]

    assert List.last(second_body["messages"])["role"] == "user"
    assert List.last(second_body["messages"])["content"] =~ "Your last response was empty"
    open_stream(socket)
    send_chunk(socket, %{role: "assistant", content: "finished after nudge"})
    chunk(worker, second, :text, "finished after nudge")
    finish_stream(ctx.server, socket)
    phase(worker, second, :llm_complete)

    assert_receive {:prompt_result, ^worker, {:implicit_completion, _, "finished after nudge"},
                    ^second},
                   @deadline

    refute_received {:activity, ^worker, {:call_phase, ^first, :retry_wait}}
    refute_received {:provider_request, _, 2, _}
  end

  test "exhausted transient failure retires its call and releases the slot", ctx do
    worker = start_call(ctx.id, :retry, 0)
    call = started(worker, 0)
    phase(worker, call, :llm)
    socket = request(ctx.server, 0)
    send_error(ctx.server, socket, 500)
    phase(worker, call, :retry_wait)

    assert_receive {:prompt_result, ^worker,
                    {:error,
                     %ReqLLM.Error.API.Stream{cause: %ReqLLM.Error.API.Request{status: 500}}},
                    nil},
                   @deadline

    await_pool(:used, 0)
    refute_received {:activity, ^worker, {:call_phase, ^call, :llm_complete}}
    refute_received {:activity, ^worker, {:start_call, _, _, _}}
    refute_received {:provider_request, _, 1, _}
  end

  test "nonretryable provider rejection retires the call without another attempt", ctx do
    worker = start_call(ctx.id, :prompt, 3)
    call = started(worker, 0)
    phase(worker, call, :llm)
    socket = request(ctx.server, 0)
    send_error(ctx.server, socket, 400)
    phase(worker, call, :retry_wait)

    assert_receive {:prompt_result, ^worker, {:error, {:llm_request_rejected, message}}, nil},
                   @deadline

    assert message =~ "activity rejection"
    await_pool(:used, 0)
    refute_received {:activity, ^worker, {:start_call, _, _, _}}
    refute_received {:provider_request, _, 1, _}
  end

  test "real stream interruption retires to idle without retrying or nudging", ctx do
    worker = start_call(ctx.id, :prompt, 3)
    call = started(worker, 0)
    phase(worker, call, :llm)
    socket = request(ctx.server, 0)
    open_stream(socket)
    send_chunk(socket, %{role: "assistant", content: "before interrupt"})
    chunk(worker, call, :text, "before interrupt")
    send(worker, {:evogit_interrupt, make_ref()})
    send_chunk(socket, %{content: "after interrupt"})
    finish_stream(ctx.server, socket)
    phase(worker, call, :idle)
    assert_receive {:prompt_result, ^worker, {:interrupted, %Interrupted{}}, nil}, @deadline
    await_pool(:used, 0)
    refute_received {:activity, ^worker, {:call_phase, ^call, :retry_wait}}
    refute_received {:activity, ^worker, {:start_call, _, _, _}}
    refute_received {:provider_request, _, 1, _}
  end

  defp start_call(id, entrypoint, retries) do
    owner = self()

    {worker, _ref} =
      spawn_monitor(fn ->
        Process.put(:evogit_agent_id, id)
        Sink.install(owner, id)
        Sink.start_turn(@turn)

        try do
          context = ReqLLM.Context.new([ReqLLM.Context.user("activity objective")])
          opts = [api_key: "activity-test-key"]

          result =
            case entrypoint do
              :retry -> LLMPrompting.call_llm_with_retry(context, [], opts, id, retries)
              :prompt -> LLMPrompting.prompt_until_tools_or_limit(context, [], opts, id, retries)
            end

          send(owner, {:prompt_result, self(), result, Process.get(:evogit_stream_call)})
        after
          Sink.uninstall()
        end
      end)

    on_exit(fn -> stop_process(worker) end)
    assert_receive {:activity, ^worker, :reset}, @deadline
    worker
  end

  defp stop_process(pid) do
    ref = Process.monitor(pid)
    Process.exit(pid, :kill)
    assert_receive {:DOWN, ^ref, :process, ^pid, _}, @deadline
  end

  defp started(worker, attempt) do
    assert {:start_call, id, @turn, ^attempt} = next_activity(worker)
    assert is_binary(id) and id != ""
    id
  end

  defp phase(worker, id, phase) do
    assert {:call_phase, ^id, ^phase} = next_activity(worker)
  end

  defp chunk(worker, id, kind, text) do
    assert {:chunk, ^id, ^kind, ^text} = next_activity(worker)
  end

  # Match the envelope first, not the requested event, so an out-of-order
  # completion/phase/chunk cannot be skipped by selective receive.
  defp next_activity(worker) do
    assert_receive {:activity, ^worker, event}, @deadline
    event
  end

  defp await_pool(field, expected, deadline \\ nil) do
    deadline = deadline || System.monotonic_time(:millisecond) + @deadline
    status = Map.fetch!(AgentScheduler.get_llm_slot_status(), @pool)

    if Map.fetch!(status, field) != expected do
      assert System.monotonic_time(:millisecond) < deadline, inspect(status)
      Process.sleep(1)
      await_pool(field, expected, deadline)
    end
  end

  # Existing fixed-response helpers cannot hold a stream mid-response or gate
  # retries. This peer exposes accepted sockets, so the test controls the exact
  # bytes delivered through the genuine ReqLLM decoder, never fake callbacks.
  defp start_provider do
    {:ok, listener} =
      :gen_tcp.listen(0, [:binary, active: false, reuseaddr: true, ip: {127, 0, 0, 1}])

    {:ok, port} = :inet.port(listener)
    owner = self()
    {pid, _ref} = spawn_monitor(fn -> accept_requests(listener, owner, 0) end)

    on_exit(fn ->
      stop_process(pid)
      :gen_tcp.close(listener)
    end)

    %{pid: pid, url: "http://127.0.0.1:#{port}"}
  end

  defp accept_requests(listener, owner, index) do
    case :gen_tcp.accept(listener) do
      {:ok, socket} ->
        serve_request(socket, owner, index)
        accept_requests(listener, owner, index + 1)

      {:error, :closed} ->
        # The test owns the listening socket, so ExUnit closes it as the test
        # exits, possibly before the on_exit process kills this acceptor.
        :ok
    end
  end

  defp serve_request(socket, owner, index) do
    {headers, rest} = read_headers(socket, "")
    [_, size] = Regex.run(~r/content-length:\s*(\d+)/i, headers)
    body = read_body(socket, rest, String.to_integer(size))
    send(owner, {:provider_request, self(), index, {socket, Jason.decode!(body)}})

    receive do
      :next_request -> :ok
    end

    :gen_tcp.close(socket)
  end

  defp read_headers(socket, acc) do
    case String.split(acc, "\r\n\r\n", parts: 2) do
      [headers, rest] ->
        {headers, rest}

      [_] ->
        {:ok, data} = :gen_tcp.recv(socket, 0, @deadline)
        read_headers(socket, acc <> data)
    end
  end

  defp read_body(_socket, data, size) when byte_size(data) >= size, do: data

  defp read_body(socket, data, size) do
    {:ok, more} = :gen_tcp.recv(socket, 0, @deadline)
    read_body(socket, data <> more, size)
  end

  defp request_with_body(%{pid: pid}, index) do
    assert_receive {:provider_request, ^pid, ^index, request}, @deadline
    request
  end

  defp request(server, index), do: elem(request_with_body(server, index), 0)

  defp open_stream(socket) do
    :ok =
      :gen_tcp.send(
        socket,
        "HTTP/1.1 200 OK\r\ncontent-type: text/event-stream\r\nconnection: close\r\n\r\n"
      )
  end

  defp send_chunk(socket, delta, finish \\ nil) do
    event = %{
      id: "activity-response",
      object: "chat.completion.chunk",
      model: "activity-test",
      created: 1,
      choices: [%{index: 0, delta: delta, finish_reason: finish}]
    }

    :ok = :gen_tcp.send(socket, "data: " <> Jason.encode!(event) <> "\n\n")
  end

  defp finish_stream(server, socket) do
    send_chunk(socket, %{}, "stop")
    :ok = :gen_tcp.send(socket, "data: [DONE]\n\n")
    send(server.pid, :next_request)
  end

  defp send_error(server, socket, status) do
    body =
      Jason.encode!(%{error: %{message: "activity rejection", type: "invalid_request_error"}})

    :ok =
      :gen_tcp.send(socket, [
        "HTTP/1.1 #{status} Error\r\ncontent-type: application/json\r\n",
        "content-length: #{byte_size(body)}\r\nconnection: close\r\n\r\n",
        body
      ])

    send(server.pid, :next_request)
  end
end
