defmodule EvoGit.Agent.ContextCompressionStagesTest.StubLlmServer do
  @moduledoc """
  Minimal raw-TCP SSE endpoint answering EVERY request with one OpenAI-style
  streaming completion that carries a fixed summary text and a fixed usage map.

  `EvoGit.TestLlmServer` always answers `content-type: application/json`, which a
  streaming (`ReqLLM.stream_text/3`) request cannot parse, so a SUCCESSFUL
  streaming round trip needs a `text/event-stream` responder. Handing the
  compression call a model spec whose `base_url` points here makes the real
  ReqLLM stack produce a genuine `%ReqLLM.Response{}` — so
  `ReqLLM.Response.text/1` and `ReqLLM.Response.usage/1` are exercised for real,
  with no network and no mocks. Every served request's BODY is also sent to the
  test process as `{:stub_llm_request, body}` so a test can assert what the
  compression call actually asked the model.
  """

  import ExUnit.Callbacks, only: [on_exit: 1]

  @summary_usage %{prompt_tokens: 11, completion_tokens: 7, total_tokens: 18}

  @doc """
  Starts the server and returns `%{url: url, port: port, counters: counters}`
  (`counters` is the per-request counter read by `request_count/1`).
  """
  def start!(summary) when is_binary(summary) do
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
    payload = sse_payload(summary)
    parent = self()
    acceptor = spawn(fn -> accept_loop(listen, payload, counters, parent) end)

    on_exit(fn ->
      Process.exit(acceptor, :kill)
      :gen_tcp.close(listen)
    end)

    %{url: "http://127.0.0.1:#{port}", port: port, counters: counters}
  end

  @doc "Number of HTTP requests served so far."
  def request_count(%{counters: counters}), do: :counters.get(counters, 1)

  defp accept_loop(listen, payload, counters, parent) do
    case :gen_tcp.accept(listen) do
      {:ok, socket} ->
        serve(socket, payload, counters, parent)
        :gen_tcp.close(socket)
        accept_loop(listen, payload, counters, parent)

      {:error, _reason} ->
        :ok
    end
  end

  # Drane the request body BEFORE replying (closing on unread data can RST the
  # response before the client reads it), then report it and answer.
  defp serve(socket, payload, counters, parent) do
    {headers, rest} = read_headers(socket, "")
    body = drain_body(socket, rest, content_length(headers))
    :counters.add(counters, 1, 1)
    send(parent, {:stub_llm_request, body})
    :gen_tcp.send(socket, response(payload))
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

defmodule EvoGit.Agent.ContextCompressionStagesTest do
  @moduledoc """
  Stage-level coverage of `EvoGit.Agent.ContextCompression.compress_if_needed/2`.

  * the STAGE-1 (model-free tool-result pruning) fan-out: a long OLD tool result
    is rewritten to head + marker + tail, the projected token count lands under
    the trigger, and therefore NO summarising call happens — `total_tokens` is
    reset, `usage` is untouched (nothing was spent) and `compression_count`
    still records the compression event;
  * the STAGE-2 (summarising checkpoint) composition, driven end-to-end against
    `StubLlmServer` (a raw-TCP SSE endpoint): the resulting context is
    `[system, first_user, checkpoint, ...last-K-turns verbatim, context_refresh]`
    with the head byte-identical and no orphaned `tool_call_id`;
  * the window-relative trigger (`:llm_model_metadata_fun` seam), the unknown
    window config fallback, and the incompressible context shapes.

  `async: false` — the module swaps the global `:llm_model_metadata_fun` seam,
  installs a single-slot model profile on the GLOBAL `EvoGit.AgentScheduler`, and
  registers agent-state ETS rows (which `increment_compression_count/1` requires).
  """

  use ExUnit.Case, async: false

  alias EvoGit.Agent.Compression.Checkpoint
  alias EvoGit.Agent.Compression.SummaryPrompt
  alias EvoGit.Agent.Compression.Threshold
  alias EvoGit.Agent.ContextBuilder
  alias EvoGit.Agent.ContextCompression
  alias EvoGit.Agent.LoopState
  alias EvoGit.Agent.Usage
  alias EvoGit.AgentScheduler
  alias EvoGit.AgentScheduler.AgentState
  alias EvoGit.AgentScheduler.Store, as: SchedStore

  # The recency window protected verbatim by both stages.
  @keep_recent_turns 4

  # A 128k window -> a 57_344-token trigger; a 1M window -> 800_000.
  @window_128k 131_072
  @window_1m 1_000_000

  @seam :llm_model_metadata_fun
  @model_id "default"

  # The summary text the stub server streams back, and the `## Current Work`
  # section it deliberately opens with (so it looks like a real summary).
  @summary "## Current Work\nImplemented the parser and ran the suite."

  @system_text "You are the compression stage test agent."
  @objective "Objective: exercise the two-stage compression path."

  # Agent ids are high + distinct so no sibling test's leftover ETS row collides.
  @stage1_agent 9_201
  @stage2_agent 9_202
  @window_agent 9_203
  @config_agent 9_204

  @huge_tool_output String.duplicate("tool-output-line\n", 14_000) <>
                      "FINAL LINE: 42 tests, 0 failures"

  # --- State / fixture helpers ---------------------------------------------

  defp tag(message, turn), do: ContextBuilder.tag_message_turn(message, turn)

  defp tool_result(call_id, text) do
    ReqLLM.Context.tool_result(call_id, "read_file", text)
  end

  defp assistant_with_call(text, call_id) do
    ReqLLM.Context.assistant(text, tool_calls: [ReqLLM.ToolCall.new(call_id, "read_file", "{}")])
  end

  # `[system, objective | 6 tagged (assistant, user) turns]`, with ONE huge OLD
  # tool result (index 3, i.e. inside the replaceable/ prunable span: the
  # recency boundary is 6 for this 14-message fixture).
  #
  # The turn tags MATTER: `Recency.boundary/2` protects the last 4 turns, so an
  # untagged conversation has NO old span at all and both stages degrade to
  # no-ops.
  defp conversation_with_old_tool_result do
    head = [
      ReqLLM.Context.system(@system_text),
      ReqLLM.Context.user(@objective) |> tag(0),
      assistant_with_call("reading the big log", "call_old") |> tag(0),
      tool_result("call_old", @huge_tool_output)
    ]

    head ++ turn_pairs(1..5)
  end

  # The stage-2 fixture: an OLD span (a tool call + its result, turns 0-1) and a
  # RECENT tool call/result pair (turn 4) that must survive verbatim.
  defp conversation_for_checkpoint do
    [
      ReqLLM.Context.system(@system_text),
      ReqLLM.Context.user(@objective) |> tag(0),
      assistant_with_call("old work", "call_old") |> tag(0),
      tool_result("call_old", "OLD TOOL OUTPUT") |> tag(1),
      ReqLLM.Context.assistant("old assistant reply") |> tag(1),
      ReqLLM.Context.user("old note 1") |> tag(1)
    ] ++
      [
        ReqLLM.Context.assistant("recent turn 2") |> tag(2),
        ReqLLM.Context.user("note 2") |> tag(2),
        ReqLLM.Context.assistant("recent turn 3") |> tag(3),
        ReqLLM.Context.user("note 3") |> tag(3),
        assistant_with_call("recent work", "call_recent") |> tag(4),
        tool_result("call_recent", "RECENT TOOL OUTPUT") |> tag(4),
        ReqLLM.Context.assistant("recent turn 5") |> tag(5),
        ReqLLM.Context.user("note 5") |> tag(5)
      ]
  end

  defp turn_pairs(turns) do
    Enum.flat_map(turns, fn turn ->
      [
        ReqLLM.Context.assistant("working on turn #{turn}") |> tag(turn),
        ReqLLM.Context.user("note #{turn}") |> tag(turn)
      ]
    end)
  end

  defp state(agent_id, messages, opts) do
    %LoopState{
      agent_id: agent_id,
      agent_module: __MODULE__,
      depth: 0,
      node_path: "./",
      repo_path: Keyword.fetch!(opts, :repo_path),
      repo_less: false,
      context: ReqLLM.Context.new(messages),
      total_tokens: Keyword.fetch!(opts, :total_tokens),
      usage: Keyword.get(opts, :usage, Usage.zero()),
      turn: Keyword.get(opts, :turn, 7)
    }
  end

  defp messages_of(%LoopState{context: context}), do: ReqLLM.Context.to_list(context)

  defp text_of(%ReqLLM.Message{content: content}) when is_list(content) do
    content
    |> Enum.filter(&(&1.type == :text))
    |> Enum.map(& &1.text)
    |> Enum.join("")
  end

  defp text_of(_message), do: ""

  # Registers the ETS agent-state row `increment_compression_count/1` requires
  # (`{:ok, agent_state} = get_agent_state(agent_id)`), and deletes it on exit.
  defp register_agent(agent_id) do
    :ok =
      SchedStore.put_agent_state(agent_id, %AgentState{
        context_node: nil,
        llm_model: "stub:model",
        max_retries: 3,
        max_depth: 3,
        model_id: @model_id
      })

    on_exit(fn -> SchedStore.delete_agent_state(agent_id) end)
  end

  defp compression_count(agent_id) do
    {:ok, agent_state} = SchedStore.get_agent_state(agent_id)
    agent_state.compression_count
  end

  # A temp repo whose CONTEXT.md the refresh message renders, so "the refresh
  # carries the CURRENT chain" is observable.
  defp temp_repo do
    repo = Path.join(System.tmp_dir!(), "evogit_stages_#{System.unique_integer([:positive])}")
    File.mkdir_p!(repo)
    File.write!(Path.join(repo, "CONTEXT.md"), "# Root\nstage-test context body\n")
    on_exit(fn -> File.rm_rf!(repo) end)
    repo
  end

  # Drives the window through the call-time seam `model_metadata/1` reads.
  defp stub_window(context, output \\ 8_192) do
    Application.put_env(:evo_git, @seam, fn _model ->
      %{limits: %{context: context, output: output}, capabilities: %{}}
    end)
  end

  defp restore_seam(nil), do: Application.delete_env(:evo_git, @seam)
  defp restore_seam(value), do: Application.put_env(:evo_git, @seam, value)

  setup do
    assert Process.whereis(EvoGit.AgentScheduler), "AgentScheduler must be running"
    AgentScheduler.resume()

    previous_seam = Application.get_env(:evo_git, @seam)
    on_exit(fn -> restore_seam(previous_seam) end)

    original_profiles = AgentScheduler.get_config(:model_profiles)

    # A single-slot "default" pool: the compression call's slot lives there
    # (`Slots.resolve_model_id/2` resolves an agent's bound model_id).
    AgentScheduler.update_config(
      model_profiles: [%{id: @model_id, model: "stub:model", concurrency: 1}]
    )

    on_exit(fn -> AgentScheduler.update_config(model_profiles: original_profiles) end)

    %{repo_path: temp_repo()}
  end

  # ---------------------------------------------------------------------------
  # Stage 1 — model-free pruning is enough, so the LLM is never called
  # ---------------------------------------------------------------------------

  describe "stage 1 (model-free pruning)" do
    test "prunes the old tool result and skips the LLM entirely", %{repo_path: repo_path} do
      register_agent(@stage1_agent)
      stub_window(@window_128k)

      info = Threshold.for_model("stub:model")
      assert info.threshold == 57_344

      original = conversation_with_old_tool_result()
      prior_usage = %Usage{input_tokens: 100, output_tokens: 20, total_tokens: 120}

      # One token past the trigger, so the gate opens.
      st =
        state(@stage1_agent, original,
          repo_path: repo_path,
          total_tokens: 60_000,
          usage: prior_usage
        )

      result =
        ContextCompression.compress_if_needed(st,
          agent_id: @stage1_agent,
          llm_model: "stub:model"
        )

      assert %LoopState{} = result
      messages = messages_of(result)

      # 14 original messages (none deleted — stage 1 never shortens the list)
      # plus ONE appended runtime-context refresh message.
      assert length(messages) == length(original) + 1

      # The huge OLD tool result is rewritten to head + marker + tail.
      tool_message = Enum.at(messages, 3)
      assert tool_message.role == :tool
      assert tool_message.tool_call_id == "call_old"
      tool_text = text_of(tool_message)
      assert tool_text =~ "[... tool result middle pruned ...]"
      assert tool_text =~ "tool-output-line"
      # The TAIL survives (errors/totals live there) — the middle does not.
      assert tool_text =~ "FINAL LINE: 42 tests, 0 failures"
      assert byte_size(tool_text) < byte_size(@huge_tool_output)

      # The cacheable prefix stays BYTE-IDENTICAL (system + first user message).
      assert Enum.at(messages, 0) == Enum.at(original, 0)
      assert Enum.at(messages, 1) == Enum.at(original, 1)

      # ... and so does every non-tool message (only the tool text changed).
      assert Enum.at(messages, 2) == Enum.at(original, 2)

      # The refresh message is LAST and carries the CURRENT context tree.
      refresh = List.last(messages)
      assert refresh.role == :user
      assert text_of(refresh) =~ "stage-test context body"
      refute text_of(refresh) =~ "<objective>\n"

      # Nothing was spent: pruning is free, so `usage` is UNCHANGED.
      assert result.usage == prior_usage

      # The event is still recorded (token reset + compression counter).
      assert result.total_tokens == 0
      assert compression_count(@stage1_agent) == 1
    end

    test "the projected token count is what decides — pruning is not enough here", %{
      repo_path: repo_path
    } do
      register_agent(@stage1_agent)
      stub_window(@window_128k)

      # An ordinary (non-prunable) conversation: nothing to prune, so the
      # projection keeps the reported count and stage 2 would have to run. We
      # assert the DECISION, not the call: `Threshold.project/3` on an unchanged
      # list never dips below the trigger.
      original = conversation_for_checkpoint()
      info = Threshold.for_model("stub:model")

      assert Threshold.project(60_000, 1_000, 1_000) == 60_000
      assert Threshold.project(60_000, 1_000, 1_000) > info.threshold

      st =
        state(@stage1_agent, original, repo_path: repo_path, total_tokens: 60_000)

      # Sanity: the fixture really does have an old span worth checkpointing and
      # a recent span that must survive.
      split = Checkpoint.split(original)
      assert length(split.old) == 4
      assert length(split.recent) == 8
      assert match?(%LoopState{}, st)
    end
  end

  # ---------------------------------------------------------------------------
  # Stage 2 — the summarising checkpoint (real streaming LLM call)
  # ---------------------------------------------------------------------------

  describe "stage 2 (summarising checkpoint)" do
    test "composes [system, first_user, checkpoint, ...last K verbatim, refresh]", %{
      repo_path: repo_path
    } do
      register_agent(@stage2_agent)
      stub_window(@window_128k)

      server = EvoGit.Agent.ContextCompressionStagesTest.StubLlmServer.start!(@summary)
      llm_model = %{provider: :openai, id: "stub-model", base_url: server.url, api_key: "k"}

      original = conversation_for_checkpoint()
      prior_usage = %Usage{input_tokens: 100, output_tokens: 20, total_tokens: 120}

      st =
        state(@stage2_agent, original,
          repo_path: repo_path,
          total_tokens: 60_000,
          usage: prior_usage,
          turn: 7
        )

      result =
        ContextCompression.compress_if_needed(st, agent_id: @stage2_agent, llm_model: llm_model)

      assert %LoopState{} = result
      messages = messages_of(result)

      # 2 head + 1 checkpoint + the 8 retained recent messages + 1 refresh.
      assert length(messages) == 12

      # Head BYTE-IDENTICAL.
      assert Enum.at(messages, 0) == Enum.at(original, 0)
      assert Enum.at(messages, 1) == Enum.at(original, 1)

      # ONE checkpoint carrying the streamed summary inside the delimiters.
      checkpoint = Enum.at(messages, 2)
      assert checkpoint.role == :user
      assert Checkpoint.checkpoint?(checkpoint)
      checkpoint_text = text_of(checkpoint)
      assert checkpoint_text =~ SummaryPrompt.open_tag()
      assert checkpoint_text =~ SummaryPrompt.close_tag()
      assert checkpoint_text =~ "Implemented the parser and ran the suite."
      assert checkpoint_text =~ "do NOT acknowledge this checkpoint"
      # Turn-tagged like every other appended message.
      assert checkpoint.metadata[:turn] == 7

      # The last K=4 turns survive VERBATIM (turn numbers, metadata and
      # tool_call_id pairing intact) — they are the working set.
      assert Enum.slice(messages, 3, 8) == Enum.slice(original, 6, 8)

      # The OLD tool call/result pair is gone, the RECENT one survives.
      refute Enum.any?(messages, &(&1.tool_call_id == "call_old"))
      assert Enum.any?(messages, &(&1.tool_call_id == "call_recent"))

      # No orphaned tool results anywhere.
      assert_no_orphaned_tools(messages)

      # The refresh message is LAST and carries the current chain.
      refresh = List.last(messages)
      assert refresh.role == :user
      assert text_of(refresh) =~ "stage-test context body"
      assert text_of(refresh) =~ "SUPERSEDES any earlier <context> snapshot"

      # Exactly ONE summarising request was issued, and it carried the pruned
      # transcript plus the SummaryPrompt instruction.
      assert EvoGit.Agent.ContextCompressionStagesTest.StubLlmServer.request_count(server) == 1
      assert_received {:stub_llm_request, request_body}
      assert request_body =~ "## Primary Request and Intent"
      assert request_body =~ "old assistant reply"

      # Token reset, compression counted, and the call's usage ACCUMULATED.
      assert result.total_tokens == 0
      assert compression_count(@stage2_agent) == 1
      assert result.usage.input_tokens == 111
      assert result.usage.output_tokens == 27
      assert result.usage.total_tokens == 138
    end

    test "a conversation whose old span would orphan a tool result rewinds the boundary", %{
      repo_path: repo_path
    } do
      # Pure composition through `Checkpoint.build/3`: the boundary candidate is
      # rewound off the `:tool` message, so the assistant that produced it is
      # retained too.
      messages =
        [
          ReqLLM.Context.system(@system_text),
          ReqLLM.Context.user(@objective) |> tag(0),
          ReqLLM.Context.assistant("turn 1") |> tag(1),
          # The positional floor for this length (12 - 2*4 = 4) lands EXACTLY on
          # the tool result, so the split must rewind onto the assistant that
          # produced it — otherwise the retained tool result would be orphaned.
          assistant_with_call("turn 1 tool call", "call_x") |> tag(1),
          tool_result("call_x", "tool output") |> tag(1)
        ] ++ turn_pairs(2..4) ++ [ReqLLM.Context.assistant("turn 5") |> tag(5)]

      split = Checkpoint.split(messages)
      assert length(messages) == 12
      assert split.head == Enum.take(messages, 2)
      # Rewound onto the assistant message, NOT the orphaned tool result.
      assert hd(split.recent).role == :assistant

      built = Checkpoint.build(messages, "summary text", turn: 3)
      assert built.replaced > 0
      assert built.messages == split.head ++ [Enum.at(built.messages, 2)] ++ split.recent
      assert_no_orphaned_tools(built.messages)

      # Untouched when there is nothing old to replace.
      assert Checkpoint.build(Enum.take(messages, 2), "summary").messages ==
               Enum.take(messages, 2)

      # And a blank summary never fabricates a checkpoint.
      blank = Checkpoint.build(messages, "   ")
      assert blank.replaced == 0
      assert blank.messages == messages

      assert %LoopState{} = state(@stage2_agent, messages, repo_path: repo_path, total_tokens: 0)
    end
  end

  # ---------------------------------------------------------------------------
  # Window-relative trigger
  # ---------------------------------------------------------------------------

  describe "window-relative trigger" do
    test "a 1M-context model does NOT compress at 200_000 tokens", %{repo_path: repo_path} do
      register_agent(@window_agent)
      stub_window(@window_1m)

      assert Threshold.for_model("stub:model").threshold == 800_000

      st =
        state(@window_agent, conversation_with_old_tool_result(),
          repo_path: repo_path,
          total_tokens: 200_000
        )

      result =
        ContextCompression.compress_if_needed(st,
          agent_id: @window_agent,
          llm_model: "stub:model"
        )

      # The identical state — no log line, no pruning, no slot, no counter.
      assert result == st
      assert compression_count(@window_agent) == 0
    end

    test "a 128k-context model compresses at 120_000 tokens", %{repo_path: repo_path} do
      register_agent(@window_agent)
      stub_window(@window_128k)

      info = Threshold.for_model("stub:model")
      assert info.threshold == 57_344
      assert Threshold.exceeded?(120_000, info)

      st =
        state(@window_agent, conversation_with_old_tool_result(),
          repo_path: repo_path,
          total_tokens: 120_000
        )

      result =
        ContextCompression.compress_if_needed(st,
          agent_id: @window_agent,
          llm_model: "stub:model"
        )

      assert result.total_tokens == 0
      assert compression_count(@window_agent) == 1
      assert Enum.any?(messages_of(result), &(text_of(&1) =~ "tool result middle pruned"))
      # Usage untouched: the projection landed under the trigger, so no call.
      assert result.usage == st.usage
    end
  end

  # ---------------------------------------------------------------------------
  # Unknown window -> the legacy config value, still gated the same way
  # ---------------------------------------------------------------------------

  describe "unknown window" do
    test "falls back to [:llm, :compression_threshold_tokens]", %{repo_path: repo_path} do
      register_agent(@config_agent)
      # A seam answering `nil` => no usable window => the config fallback.
      Application.put_env(:evo_git, @seam, fn _model -> nil end)

      info = Threshold.for_model("mystery:model")
      config_threshold = EvoGit.Config.resolve([:llm, :compression_threshold_tokens])

      assert info == %{threshold: config_threshold, window: nil, source: :config}

      # Exactly ON the threshold is NOT enough (strictly greater).
      at_threshold =
        state(@config_agent, conversation_with_old_tool_result(),
          repo_path: repo_path,
          total_tokens: config_threshold
        )

      assert ContextCompression.compress_if_needed(at_threshold,
               agent_id: @config_agent,
               llm_model: "mystery:model"
             ) == at_threshold

      assert compression_count(@config_agent) == 0

      # One past it compresses (via stage 1, so no LLM is reachable here).
      beyond =
        state(@config_agent, conversation_with_old_tool_result(),
          repo_path: repo_path,
          total_tokens: config_threshold + 1
        )

      result =
        ContextCompression.compress_if_needed(beyond,
          agent_id: @config_agent,
          llm_model: "mystery:model"
        )

      assert result.total_tokens == 0
      assert compression_count(@config_agent) == 1
    end
  end

  # ---------------------------------------------------------------------------
  # Incompressible shapes
  # ---------------------------------------------------------------------------

  describe "incompressible context shapes" do
    test "an empty context is returned unchanged", %{repo_path: repo_path} do
      register_agent(@window_agent)
      stub_window(@window_128k)

      st = state(@window_agent, [], repo_path: repo_path, total_tokens: 60_000)

      result =
        ContextCompression.compress_if_needed(st,
          agent_id: @window_agent,
          llm_model: "stub:model"
        )

      assert result == st
      assert compression_count(@window_agent) == 0
    end

    test "a system-only context is returned unchanged", %{repo_path: repo_path} do
      register_agent(@window_agent)
      stub_window(@window_128k)

      st =
        state(@window_agent, [ReqLLM.Context.system(@system_text)],
          repo_path: repo_path,
          total_tokens: 60_000
        )

      result =
        ContextCompression.compress_if_needed(st,
          agent_id: @window_agent,
          llm_model: "stub:model"
        )

      assert result == st
      assert compression_count(@window_agent) == 0
    end
  end

  # Every retained `:tool` message must still have the assistant `tool_calls`
  # entry that produced it, or the provider rejects the conversation.
  defp assert_no_orphaned_tools(messages) do
    call_ids =
      messages
      |> Enum.flat_map(fn
        %ReqLLM.Message{tool_calls: calls} when is_list(calls) -> Enum.map(calls, & &1.id)
        _ -> []
      end)
      |> MapSet.new()

    for %ReqLLM.Message{role: :tool, tool_call_id: id} <- messages do
      assert MapSet.member?(call_ids, id),
             "orphaned tool result #{inspect(id)}: no assistant tool_calls carries it"
    end

    # The retained-turns window is honoured: no `:tool` message outlives its call.
    assert @keep_recent_turns == EvoGit.Agent.Compression.Recency.default_keep_recent_turns()
  end
end
