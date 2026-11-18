defmodule EvoGit.Agent.ExchangeActivityPhasesTest.BlockingStubLlmServer do
  @moduledoc """
  Raw-TCP SSE endpoint that can HOLD a request open, so a live-activity phase
  published *before* an LLM call can be observed while that call is still in
  flight.

  `EvoGit.TestLlmServer` always answers `content-type: application/json`, which
  a streaming (`ReqLLM.stream_text/3`) request cannot parse, so a SUCCESSFUL
  streaming round trip needs a `text/event-stream` responder. Handing an LLM the
  model spec whose `base_url` points here makes the real ReqLLM stack produce a
  genuine `%ReqLLM.Response{}` — no network, no mocks.

  The difference from `EvoGit.Agent.ContextCompressionStagesTest.StubLlmServer`:
  every served request's body is announced as
  `{:stub_llm_request, ref, body}` (a per-request `reference`, so the test knows
  exactly which request it is releasing), and the FIRST request additionally
  BLOCKS on `receive {:release, ^ref}` (30 s safety net) BEFORE its HTTP
  response is written. Requests 2..n answer immediately, so a test can hold the
  compression summary call open, assert what has been published so far, then let
  the run continue through the following turn.
  """

  import ExUnit.Callbacks, only: [on_exit: 1]

  @summary_usage %{prompt_tokens: 11, completion_tokens: 7, total_tokens: 18}

  # How long a held request waits before answering anyway. Only a stuck test can
  # reach it; the happy path releases it as soon as the phase is asserted.
  @hold_timeout_ms 30_000

  @doc """
  Starts the server and returns `%{url:, port:, counters:, pid:}` — `pid` is the
  acceptor process that owns the hold, i.e. the process a test sends
  `{:release, ref}` to.

  `summary` answers the FIRST request (the compression summary — only its SSE
  framing matters) and `report` answers every later request (the turn's own
  reply, whose tool-free text becomes the run's report).
  """
  def start!(summary, report) when is_binary(summary) and is_binary(report) do
    {:ok, listen} =
      :gen_tcp.listen(0, [
        :binary,
        packet: :raw,
        active: false,
        reuseaddr: true,
        ip: {127, 0, 0, 1}
      ])

    {:ok, port} = :inet.port(listen)
    counters = :counters.new(1, [:atomics])
    payloads = {sse_payload(summary), sse_payload(report)}
    parent = self()
    acceptor = spawn(fn -> accept_loop(listen, payloads, counters, parent) end)

    on_exit(fn ->
      Process.exit(acceptor, :kill)
      :gen_tcp.close(listen)
    end)

    %{url: "http://127.0.0.1:#{port}", port: port, counters: counters, pid: acceptor}
  end

  @doc "Number of HTTP requests served so far (incremented before any hold)."
  def request_count(%{counters: counters}), do: :counters.get(counters, 1)

  defp accept_loop(listen, payloads, counters, parent) do
    case :gen_tcp.accept(listen) do
      {:ok, socket} ->
        serve(socket, payloads, counters, parent)
        :gen_tcp.close(socket)
        accept_loop(listen, payloads, counters, parent)

      {:error, _reason} ->
        :ok
    end
  end

  # Drain the request body BEFORE replying (closing on unread data can RST the
  # response before the client reads it), then announce it, hold it when it is
  # the FIRST request, and answer with the payload for that request's position.
  defp serve(socket, {summary_payload, turn_payload}, counters, parent) do
    {headers, rest} = read_headers(socket, "")
    body = drain_body(socket, rest, content_length(headers))
    :counters.add(counters, 1, 1)
    index = :counters.get(counters, 1)
    ref = make_ref()
    send(parent, {:stub_llm_request, ref, body})

    if index == 1, do: await_release(ref)

    payload = if index == 1, do: summary_payload, else: turn_payload
    :gen_tcp.send(socket, response(payload))
  end

  defp await_release(ref) do
    receive do
      {:release, ^ref} -> :ok
    after
      @hold_timeout_ms -> :ok
    end
  end

  defp read_headers(socket, acc) do
    case String.split(acc, "\r\n\r\n", parts: 2) do
      [headers, rest] ->
        {headers, rest}

      [_incomplete] ->
        case :gen_tcp.recv(socket, 0, 5_000) do
          {:ok, data} -> read_headers(socket, acc <> data)
          {:error, _reason} -> {acc, ""}
        end
    end
  end

  defp content_length(headers) do
    case Regex.run(~r/content-length:\s*(\d+)/i, headers) do
      [_, length] -> String.to_integer(length)
      _ -> 0
    end
  end

  defp drain_body(_socket, have, length) when byte_size(have) >= length, do: have

  defp drain_body(socket, have, length) do
    case :gen_tcp.recv(socket, 0, 5_000) do
      {:ok, data} -> drain_body(socket, have <> data, length)
      {:error, _reason} -> have
    end
  end

  defp response(payload) do
    [
      "HTTP/1.1 200 OK\r\n",
      "content-type: text/event-stream\r\n",
      "cache-control: no-cache\r\n",
      "connection: close\r\n",
      "\r\n",
      payload
    ]
  end

  defp sse_payload(summary) do
    [
      chunk(%{role: "assistant", content: summary}, nil),
      chunk(%{}, "stop", @summary_usage),
      "data: [DONE]\n\n"
    ]
    |> Enum.join("")
  end

  defp chunk(delta, finish_reason, usage \\ nil) do
    event =
      %{
        id: "stub-completion",
        object: "chat.completion.chunk",
        created: 1,
        model: "stub-model",
        choices: [%{index: 0, delta: delta, finish_reason: finish_reason}]
      }
      |> maybe_put_usage(usage)

    "data: " <> Jason.encode!(event) <> "\n\n"
  end

  defp maybe_put_usage(event, nil), do: event
  defp maybe_put_usage(event, usage), do: Map.put(event, :usage, usage)
end

defmodule EvoGit.Agent.ExchangeActivityPhasesTest.ActivityAgent do
  @moduledoc """
  The role the live-activity exchange runs AS: an EMPTY tool inventory, because
  the phase sequence under test is the compression step plus the following LLM
  call — no tool batch participates.
  """

  use EvoGit.Agent

  @doc "No tools: the stubbed model's reply is plain text, so no batch can run."
  def available_tools, do: []

  @doc "No subagent spawn schemas either."
  def subagent_modules, do: []
end

defmodule EvoGit.Agent.ExchangeActivityPhasesTest do
  @moduledoc """
  End-to-end proof of the live-activity PHASE ordering across a context
  compression and the turn that follows it, with the REAL LLM path running
  (`EvoGit.Agent.LLMPrompting` + the real compression `LlmRetry` call) against a
  loopback SSE endpoint that HOLDS its first request open.

  ## What is proven

  1. `{:phase, :compressing}` is published WHILE the stage-2 summary request is
     still blocked — i.e. the phase covers the in-flight compression, it is not
     a post-hoc label. Batched with the held request: the phase arrives, the
     stub announces request #1, the counter is exactly 1, and only THEN does the
     test release it.
  2. The following turn's `{:phase, :preparing}` is published BEFORE the turn's
     own LLM attempt begins (`{:start_call, id, turn, attempt}`), and no
     `{:phase, :compressing}` can appear after the LAST `:preparing` — the
     compression step belongs to the loop TOP, never to a turn.
  3. Request #2 really was served: the turn's own LLM call happened after
     compression, so the ordering above is not an artifact of a run that ended
     early.

  ## How the events are observed

  `EvoGit.Agent.Stream.Sink.install/2` is PROCESS-LOCAL, so the run installs its
  sink pointing at the TEST process. Every emission then arrives as
  `{:activity, worker_pid, event}` and, because every one of them is sent by the
  run process (and the final reply rides the same sender), mailbox order IS the
  publication order.

  ## `async: false`

  Two BEAM-global surfaces force serialization, both named here:

  * the app-global `EvoGit.AgentScheduler` — `resume/0` plus a
    `update_config(model_profiles: …)` that installs the single-slot
    `"default"` pool both LLM calls draw their slot from (restored on exit); and
  * the `:llm_model_metadata_fun` app-env seam — read at CALL time by
    `Threshold.for_model/2`'s output reservation, pinned here to a fixed
    8_192-token output so the derived 128k-window trigger (57_344) is decisive
    without a real catalog decode.

  The config dir is isolated PER PROCESS through `EvoGit.TestSupport.ConfigDir`
  (the suite-wide `:config_dir_fun` seam), so the operator's own `config.toml`
  can never supply a compression-threshold override or disable pruning, and the
  fake OpenAI credential comes from the suite-wide `test_helper.exs` default.
  """

  use ExUnit.Case, async: false

  alias EvoGit.Agent.Compression.Threshold
  alias EvoGit.Agent.ContextBuilder
  alias EvoGit.Agent.Exchange
  alias EvoGit.Agent.ExchangeActivityPhasesTest.ActivityAgent
  alias EvoGit.Agent.ExchangeActivityPhasesTest.BlockingStubLlmServer
  alias EvoGit.Agent.Result
  alias EvoGit.Agent.State
  alias EvoGit.Agent.Stream.Sink
  alias EvoGit.Agent.Usage
  alias EvoGit.AgentScheduler
  alias EvoGit.AgentScheduler.AgentState
  alias EvoGit.AgentScheduler.SchedMeta
  alias EvoGit.AgentScheduler.Store, as: SchedStore
  alias EvoGit.AgentSpec

  # Per-test-unique, disjoint from every other suite's id base, so the two
  # app-global ETS rows this test installs can never collide with (or be deleted
  # by) a concurrently running module.
  @agent_id_base 9_930_000

  # A 128k configured window -> a 57_344-token trigger (8_192-token output
  # reservation, 0.8 x window capped by the headroom and the floor).
  @window_128k 131_072
  @threshold_128k 57_344

  @seam :llm_model_metadata_fun
  @model_id "default"

  @summary "## Current Work\nImplemented the parser and ran the suite."
  @system_text "You are the live-activity phase test agent."
  @objective "Objective: publish the compression and preparing phases in order."
  @report_text "phase test report"

  # Where the observed mailbox log lives (process dictionary of the test).
  @observed_key :evogit_exchange_phase_observed

  setup do
    Process.delete(@observed_key)
    on_exit(fn -> Process.delete(@observed_key) end)

    assert Process.whereis(EvoGit.AgentScheduler), "AgentScheduler must be running"
    AgentScheduler.resume()

    # The metadata seam supplies ONLY the fixed output reservation, so the
    # window-relative trigger is the documented 57_344 for a 128k window.
    previous_seam = Application.get_env(:evo_git, @seam)

    on_exit(fn ->
      case previous_seam do
        nil -> Application.delete_env(:evo_git, @seam)
        value -> Application.put_env(:evo_git, @seam, value)
      end
    end)

    Application.put_env(:evo_git, @seam, fn _model ->
      %{limits: %{output: 8_192}, capabilities: %{}}
    end)

    # Keep the operator's ~/.config/genesis out of every config read the run
    # performs (threshold override, tool_result_pruning).
    EvoGit.TestSupport.ConfigDir.isolate!("evogit-exchange-phases")

    original_profiles = AgentScheduler.get_config(:model_profiles)

    # A single-slot "default" pool: BOTH the compression call and the turn's own
    # LLM call live there (`Slots.resolve_model_id/2` resolves the agent's bound
    # model_id).
    AgentScheduler.update_config(
      model_profiles: [%{id: @model_id, model: "stub:model", concurrency: 1}]
    )

    on_exit(fn -> AgentScheduler.update_config(model_profiles: original_profiles) end)

    agent_id = @agent_id_base + System.unique_integer([:positive])

    server = BlockingStubLlmServer.start!(@summary, @report_text)
    model = %{provider: :openai, id: "stub-model", base_url: server.url, api_key: "k"}

    install_agent_row(agent_id, model)

    on_exit(fn ->
      SchedStore.delete_agent_state(agent_id)
      SchedStore.delete_sched_meta(agent_id)
    end)

    %{agent_id: agent_id, server: server, model: model}
  end

  test "a long compression publishes :compressing in flight, then the turn publishes :preparing before :llm",
       %{agent_id: agent_id, server: server, model: model} do
    # ONE past the trigger, so the compression gate opens on the first loop pass.
    assert Threshold.for_model(model, context_window: @window_128k) == %{
             threshold: @threshold_128k,
             window: @window_128k,
             source: :window
           }

    state = initial_state(agent_id, model, @threshold_128k + 1)
    test_pid = self()

    # The run happens in its OWN process (so the test can observe the mailbox
    # while it is still in flight); `Task.async` propagates `$callers`, which is
    # what keeps the per-process config-dir seam reachable from the run.
    task =
      Task.async(fn ->
        Sink.install(test_pid, agent_id)
        Process.put(:repo_less, true)
        # `ToolDispatch.current_model/0` (the real LLM path) reads the agent's
        # pool/model from the pdict key + the ETS row.
        Process.put(:evogit_agent_id, agent_id)

        Exchange.run(state,
          llm_call: nil,
          tool_batch: fn _indexed_calls, _state -> [] end,
          scheduler: scheduler_stub(),
          checkpoint: fn _state -> :ok end
        )
      end)

    # --- 1. The phase is published WHILE the summary request is held ----------
    assert {:ok, {:event, {:phase, :compressing}}} =
             await_matching(&match?({:event, {:phase, :compressing}}, &1), 10_000)

    assert {:ok, {:request, ref1, _body}} =
             await_matching(&match?({:request, _ref, _body}, &1), 10_000)

    # The hold is real: the request is blocked inside the stub, so the phase
    # above could only have been observed while the call was still in flight.
    assert BlockingStubLlmServer.request_count(server) == 1

    send(server.pid, {:release, ref1})

    # --- 2. The run still finishes normally -----------------------------------
    assert {:finish, %State{}, %Result{result: @report_text}} = Task.await(task, 30_000)

    # --- 3. Publication order, from the raw events ---------------------------
    log = observed() ++ drain_observed([])
    events = for {:event, event} <- log, do: event

    assert events != []

    compressing = indexes(events, &match?({:phase, :compressing}, &1))
    preparing = indexes(events, &match?({:phase, :preparing}, &1))
    start_calls = indexes(events, &match?({:start_call, _id, _turn, _attempt}, &1))

    assert compressing != []
    assert preparing != []
    assert start_calls != []

    first_compressing = hd(compressing)
    first_preparing = hd(preparing)
    last_preparing = List.last(preparing)

    # The follow-up turn is labelled AFTER the compression step it follows.
    assert Enum.any?(preparing, &(&1 > first_compressing))

    # :preparing is initialised at the LOOP TOP (before the LLM attempt starts),
    # never after it — the first preparing precedes the first start_call.
    assert first_preparing < hd(start_calls)

    # A compression step belongs to the loop top, so nothing after the LAST
    # turn's `:preparing` may claim to be compressing.
    refute Enum.any?(compressing, &(&1 > last_preparing))

    # --- 4. The turn's own LLM call really happened after compression ---------
    assert BlockingStubLlmServer.request_count(server) >= 2
  end

  # ---------------------------------------------------------------------------
  # Observation
  # ---------------------------------------------------------------------------

  # Every mailbox message the assertions consume is RECORDED (in arrival order)
  # instead of being thrown away, so the final ordering assertions see the whole
  # publication sequence — `assert_receive` alone would remove the very events
  # it matched.

  defp record(entry) do
    Process.put(@observed_key, [entry | Process.get(@observed_key, [])])
    :ok
  end

  defp observed, do: @observed_key |> Process.get([]) |> Enum.reverse()

  # Waits (bounded) for the first logged message matching `predicate`, recording
  # every message it walks past.
  defp await_matching(predicate, timeout) do
    do_await_matching(predicate, System.monotonic_time(:millisecond) + timeout)
  end

  defp do_await_matching(predicate, deadline) do
    remaining = max(deadline - System.monotonic_time(:millisecond), 0)

    receive do
      {:activity, _worker, event} ->
        await_recorded({:event, event}, predicate, deadline)

      {:stub_llm_request, ref, body} ->
        await_recorded({:request, ref, body}, predicate, deadline)

      {:delta, events} ->
        await_recorded({:delta, events}, predicate, deadline)
    after
      remaining -> {:error, :timeout}
    end
  end

  defp await_recorded(entry, predicate, deadline) do
    record(entry)

    if predicate.(entry) do
      {:ok, entry}
    else
      do_await_matching(predicate, deadline)
    end
  end

  # Drains whatever is still queued once the run has returned. `after 0` is safe
  # here: every message the run process sent is already in the mailbox.
  defp drain_observed(acc) do
    receive do
      {:activity, _worker, event} -> drain_observed([{:event, event} | acc])
      {:stub_llm_request, ref, body} -> drain_observed([{:request, ref, body} | acc])
      {:delta, events} -> drain_observed([{:delta, events} | acc])
    after
      0 -> Enum.reverse(acc)
    end
  end

  defp indexes(list, predicate) do
    list
    |> Enum.with_index()
    |> Enum.flat_map(fn {event, index} -> if predicate.(event), do: [index], else: [] end)
  end

  # ---------------------------------------------------------------------------
  # Seams
  # ---------------------------------------------------------------------------

  # The scheduler CONTROL-PLANE seam: no pending inputs, no cancellation and no
  # task-level pause, so the turn proceeds through every boundary.
  defp scheduler_stub do
    fn
      :drain_inputs, _payload, _state -> []
      :cancel_requested?, _payload, _state -> false
      :pause_requested?, _payload, _state -> false
      _kind, _payload, _state -> :ok
    end
  end

  # ---------------------------------------------------------------------------
  # Scenario data
  # ---------------------------------------------------------------------------

  # `[system, objective | old span | recent tagged turns]`: a NON-EMPTY old span
  # (`Checkpoint.split/2` replaces it with ONE summary) and NO prunable tool
  # result (both tool outputs are tiny, so stage 1 prunes nothing and is
  # rejected — stage 2, the LLM call, is what actually runs).
  defp conversation_for_checkpoint do
    [
      ReqLLM.Context.system(@system_text),
      ReqLLM.Context.user(@objective) |> tag(0),
      assistant_with_call("old work", "call_old") |> tag(0),
      ReqLLM.Context.tool_result("call_old", "read_file", "OLD TOOL OUTPUT") |> tag(1),
      ReqLLM.Context.assistant("old assistant reply") |> tag(1),
      ReqLLM.Context.user("old note 1") |> tag(1)
    ] ++
      [
        ReqLLM.Context.assistant("recent turn 2") |> tag(2),
        ReqLLM.Context.user("note 2") |> tag(2),
        ReqLLM.Context.assistant("recent turn 3") |> tag(3),
        ReqLLM.Context.user("note 3") |> tag(3),
        assistant_with_call("recent work", "call_recent") |> tag(4),
        ReqLLM.Context.tool_result("call_recent", "read_file", "RECENT TOOL OUTPUT") |> tag(4),
        ReqLLM.Context.assistant("recent turn 5") |> tag(5),
        ReqLLM.Context.user("note 5") |> tag(5)
      ]
  end

  defp tag(message, turn), do: ContextBuilder.tag_message_turn(message, turn)

  defp assistant_with_call(text, call_id) do
    ReqLLM.Context.assistant(text, tool_calls: [ReqLLM.ToolCall.new(call_id, "read_file", "{}")])
  end

  defp initial_state(agent_id, model, total_tokens) do
    %State{
      agent_id: agent_id,
      agent_module: ActivityAgent,
      depth: 0,
      node_path: "./",
      context: ReqLLM.Context.new(conversation_for_checkpoint()),
      objective: @objective,
      repo_less: true,
      max_turns: 128,
      max_retries: 3,
      llm_generation_params: [],
      llm_context_window: @window_128k,
      llm_model: model,
      model_id: @model_id,
      total_tokens: total_tokens,
      usage: Usage.zero(),
      compression_count: 0
    }
  end

  # The registration metadata the completion path reads
  # (`ToolDispatch.build_completion/3` → the summary row for the archive/model
  # fields, the sched-meta for the spec): `archive: false` and a repo-less run
  # keep the note/archive writers out of it entirely.
  defp install_agent_row(agent_id, model) do
    context_node = %EvoGit.Core.ContextNode{path: "./", repo: "[system]"}

    :ok =
      SchedStore.put_agent_state(agent_id, %AgentState{
        context_node: context_node,
        parent_id: nil,
        archive: false,
        llm_model: model,
        model_id: @model_id,
        max_turns: 128,
        max_retries: 3,
        max_depth: nil,
        repo_id: "primary",
        llm_context_window: @window_128k,
        task_local_id: 1
      })

    :ok =
      SchedStore.put_sched_meta(agent_id, %SchedMeta{
        id: agent_id,
        depth: 0,
        task_number: 1,
        spec: %AgentSpec{
          context_node: context_node,
          phylo_node: nil,
          agent_module: ActivityAgent,
          objective: @objective
        }
      })

    :ok
  end
end
