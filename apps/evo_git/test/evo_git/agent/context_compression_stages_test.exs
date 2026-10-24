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
    the Stage-1 target, and therefore NO summarising call happens — the stub
    server records ZERO requests, `total_tokens` is reset, `usage` is untouched
    (nothing was spent) and `compression_count` still records the event;
  * STAGE-1 REJECTED: when most of the transcript is non-prunable, the projected
    count stays above the Stage-1 target, so Stage 2 runs over the ORIGINAL,
    un-pruned message list (the captured summary request body still carries text
    that pruning would have deleted);
  * the STAGE-2 (summarising checkpoint) composition, driven end-to-end against
    `StubLlmServer` (a raw-TCP SSE endpoint): the resulting context is
    `[system, first_user, checkpoint, ...last-K-turns verbatim, context_refresh]`
    with the head byte-identical and no orphaned `tool_call_id`;
  * `[:llm, :tool_result_pruning] = false`: Stage 1 never runs — neither a
    no-old-span conversation (Stage 2 skipped, so the huge tool result survives
    BYTE-IDENTICALLY with no request at all) nor an old-span conversation (Stage
    2's request body keeps the un-pruned tool text);
  * the window-relative trigger (the window is passed EXPLICITLY through
    `llm_context_window` / `context_window`), the explicit
    `[:llm, :compression_threshold_tokens]` override, and the incompressible
    context shapes.

  `async: false` — the module swaps the global `:llm_model_metadata_fun` seam,
  redirects the process-wide `XDG_CONFIG_HOME` (so the operator's own
  `config.toml` can never supply a threshold override or disable pruning),
  installs a single-slot model profile on the GLOBAL `EvoGit.AgentScheduler`, and
  registers agent-state ETS rows (which `increment_compression_count/1` requires).
  """

  use ExUnit.Case, async: false

  alias EvoGit.Agent.Compression.Checkpoint
  alias EvoGit.Agent.Compression.SummaryPrompt
  alias EvoGit.Agent.Compression.Threshold
  alias EvoGit.Agent.Compression.ToolResultPruner
  alias EvoGit.Agent.ContextBuilder
  alias EvoGit.Agent.ContextCompression
  alias EvoGit.Agent.LoopState
  alias EvoGit.Agent.Usage
  alias EvoGit.AgentScheduler
  alias EvoGit.AgentScheduler.AgentState
  alias EvoGit.AgentScheduler.Store, as: SchedStore

  # The recency window protected verbatim by both stages.
  @keep_recent_turns 4

  # The windows the tests pass EXPLICITLY (`llm_context_window:` /
  # `context_window:`): a 128k window -> a 57_344-token trigger and a
  # 57_344-token Stage-1 target; a 1M window -> an 800_000-token trigger.
  @window_128k 131_072
  @window_1m 1_000_000
  @threshold_128k 57_344

  @seam :llm_model_metadata_fun
  @model_id "default"
  # The credential the stubbed stage-2 round trip authenticates with (see the
  # `setup/1` pin).
  @api_key "test-key"

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
  @reject_agent 9_205
  @pruning_off_agent 9_206
  @pruning_off_span_agent 9_207
  @jobs_agent 9_208
  @jobs_stage2_agent 9_209
  @jobs_accumulation_agent 9_210

  @huge_tool_output String.duplicate("tool-output-line\n", 14_000) <>
                      "FINAL LINE: 42 tests, 0 failures"

  # Sits ~100_000 characters into a 200_000-character tool output, i.e. far past
  # the 4 KiB head Stage 1 keeps — so Stage 1 would delete it, and finding it in
  # a captured summarising request body proves that request carried the
  # ORIGINAL, un-pruned transcript.
  @middle_sentinel "MIDDLE-SENTINEL-9F3A2"

  defp sentinel_tool_output do
    String.duplicate("z", 100_000) <>
      @middle_sentinel <> String.duplicate("z", 100_000) <> "\nFINAL LINE: sentinel tail"
  end

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

  # The Stage-1-REJECTED fixture: MOST characters here are NON-prunable (a long
  # old assistant text plus a long old user note), so pruning the ONE huge old
  # tool result cannot possibly reach half the window — the projection stays
  # above the Stage-1 target and Stage 2 must run over the ORIGINAL list.
  #
  # Measured against a 128k window (trigger + target = 57_344): ~600k chars
  # before, ~405k after pruning -> a projection of ~81k tokens, well above the
  # target but still below the reported count.
  defp conversation_stage1_rejected do
    [
      ReqLLM.Context.system(@system_text),
      ReqLLM.Context.user(@objective) |> tag(0),
      ReqLLM.Context.assistant("old analysis " <> String.duplicate("a", 400_000)) |> tag(0),
      assistant_with_call("reading the big log", "call_old") |> tag(0),
      tool_result("call_old", sentinel_tool_output()),
      ReqLLM.Context.user("old note " <> String.duplicate("b", 400_000)) |> tag(1),
      ReqLLM.Context.assistant("old assistant reply") |> tag(1)
    ] ++ turn_pairs(2..5)
  end

  # A conversation whose OLD span is EMPTY (`Checkpoint.split/2` reports
  # `old: []`, so Stage 2 is skipped) yet which DOES contain a huge prunable tool
  # result — the shape that makes "Stage 1 never ran" observable rather than
  # vacuous.
  #
  # Why the odd double tool result: the recency boundary here is 3 (11 messages,
  # so the positional floor `count - 2 * K` = 3 wins over the turn boundary 4),
  # which leaves the tool result at index 2 OLD for the pruner. `Checkpoint`'s
  # candidate boundary (index 3) lands on the second `:tool` message, so its
  # rewind walks back to the head and the old span stays empty.
  defp conversation_without_old_span do
    [
      ReqLLM.Context.system(@system_text),
      ReqLLM.Context.user(@objective) |> tag(0),
      tool_result("call_a", @huge_tool_output) |> tag(0),
      tool_result("call_b", "short second result") |> tag(0),
      ReqLLM.Context.assistant("turn 1") |> tag(1),
      ReqLLM.Context.user("note 1") |> tag(1),
      ReqLLM.Context.assistant("turn 2") |> tag(2),
      ReqLLM.Context.user("note 2") |> tag(2),
      ReqLLM.Context.assistant("turn 3") |> tag(3),
      ReqLLM.Context.user("note 3") |> tag(3),
      ReqLLM.Context.assistant("turn 4") |> tag(4)
    ]
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

  # Starts an ISOLATED `EvoGit.BackgroundJobs` registry carrying ONE still-running
  # job owned by the test process — the very process compression runs in, so
  # `EvoGit.BackgroundJobs.snapshot(owner_pid: self())` resolves to this job's
  # owner. The `:evogit_background_jobs_server` process-dictionary seam points the
  # registry calls at it. Returns `{registry, job}`.
  defp start_live_job!(repo_path, label) do
    registry = :"compression_jobs_#{System.unique_integer([:positive])}"
    # A per-registry child id, so one test can start a SECOND isolated registry.
    start_supervised!({EvoGit.BackgroundJobs, [name: registry]}, id: registry)
    Process.put(:evogit_background_jobs_server, registry)
    Process.put(:evogit_agent_pid, self())

    assert {:ok, job} =
             EvoGit.BackgroundJobs.start_job(%{
               command: "sleep 30",
               cwd: repo_path,
               label: label
             })

    on_exit(fn ->
      Process.delete(:evogit_background_jobs_server)
      Process.delete(:evogit_agent_pid)
      File.rm(job.output_path)
    end)

    {registry, job}
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

  # The window is passed EXPLICITLY by every test (`llm_context_window:` to
  # `compress_if_needed/2` and `context_window:` to `Threshold.for_model/2`), so
  # the metadata seam is pinned to a fixed OUTPUT reservation only. That keeps
  # the derived trigger the documented one AND avoids forcing the real catalog
  # decode (ReqLLM's `LLMDB.load/1`, ~2.5s) for a model id that is not in it.
  defp stub_metadata(output \\ 8_192) do
    Application.put_env(:evo_git, @seam, fn _model ->
      %{limits: %{output: output}, capabilities: %{}}
    end)
  end

  defp restore_seam(nil), do: Application.delete_env(:evo_git, @seam)
  defp restore_seam(value), do: Application.put_env(:evo_git, @seam, value)

  # Redirects the process-wide `XDG_CONFIG_HOME` at a fresh temp dir and returns
  # the config directory the runtime then resolves. Tests that need a config key
  # write `config.toml` there. Without this the developer's own
  # `~/.config/genesis/config.toml` (which may set
  # `compression_threshold_tokens`) would silently override the window formula.
  defp isolate_config! do
    original_xdg = System.get_env("XDG_CONFIG_HOME")

    tmp_xdg =
      Path.join(System.tmp_dir!(), "evogit-stages-#{System.unique_integer([:positive])}")

    File.mkdir_p!(tmp_xdg)
    System.put_env("XDG_CONFIG_HOME", tmp_xdg)

    on_exit(fn ->
      case original_xdg do
        nil -> System.delete_env("XDG_CONFIG_HOME")
        value -> System.put_env("XDG_CONFIG_HOME", value)
      end

      File.rm_rf!(tmp_xdg)
    end)

    config_dir = EvoGit.Config.config_dir()
    File.mkdir_p!(config_dir)
    config_dir
  end

  defp write_config!(config_dir, contents) do
    File.write!(Path.join(config_dir, "config.toml"), contents)
  end

  # Restores the `:req_llm, :openai_api_key` app-env value captured before the
  # pin, DELETING it again when there was none (mirrors
  # `tool_dispatch_retry_slot_test`).
  defp restore_api_key(nil), do: Application.delete_env(:req_llm, :openai_api_key)
  defp restore_api_key(value), do: Application.put_env(:req_llm, :openai_api_key, value)

  setup do
    assert Process.whereis(EvoGit.AgentScheduler), "AgentScheduler must be running"
    AgentScheduler.resume()

    # PIN the provider credential the stage-2 stubbed round trip needs:
    # `ReqLLM.Keys.get/2` resolves a provider key from
    # `Application.get_env(:req_llm, :openai_api_key)` (or the `OPENAI_API_KEY`
    # env var) and never from the model spec's `api_key` field — so the credential
    # is declared here instead of being borrowed from whatever
    # `EvoGit.Config.credentials/0` loaded at boot out of the developer's real
    # `credentials.toml`. Declaring it makes this module behave identically with an
    # empty config dir; `on_exit` restores the previous value (or deletes the key
    # again when there was none).
    previous_api_key = Application.get_env(:req_llm, :openai_api_key)
    Application.put_env(:req_llm, :openai_api_key, @api_key)
    on_exit(fn -> restore_api_key(previous_api_key) end)

    previous_seam = Application.get_env(:evo_git, @seam)
    on_exit(fn -> restore_seam(previous_seam) end)

    # The metadata seam supplies ONLY the fixed output reservation; every test
    # passes its window explicitly.
    stub_metadata()

    config_dir = isolate_config!()
    original_profiles = AgentScheduler.get_config(:model_profiles)

    # A single-slot "default" pool: the compression call's slot lives there
    # (`Slots.resolve_model_id/2` resolves an agent's bound model_id).
    AgentScheduler.update_config(
      model_profiles: [%{id: @model_id, model: "stub:model", concurrency: 1}]
    )

    on_exit(fn -> AgentScheduler.update_config(model_profiles: original_profiles) end)

    %{repo_path: temp_repo(), config_dir: config_dir}
  end

  # ---------------------------------------------------------------------------
  # Stage 1 — model-free pruning is enough, so the LLM is never called
  # ---------------------------------------------------------------------------

  describe "stage 1 (model-free pruning)" do
    test "prunes the old tool result, skips the LLM entirely (zero requests)", %{
      repo_path: repo_path
    } do
      register_agent(@stage1_agent)

      info = Threshold.for_model("stub:model", context_window: @window_128k)
      assert info == %{threshold: @threshold_128k, window: @window_128k, source: :window}

      # The server is what PROVES no LLM call happened: it records zero requests
      # (it would happily serve one, so a regression into Stage 2 shows up here).
      server = EvoGit.Agent.ContextCompressionStagesTest.StubLlmServer.start!(@summary)

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
          llm_model: "stub:model",
          llm_context_window: @window_128k
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

      # Nothing was spent: pruning is free, so NO request was served and `usage`
      # is UNCHANGED.
      assert EvoGit.Agent.ContextCompressionStagesTest.StubLlmServer.request_count(server) == 0
      refute_received {:stub_llm_request, _body}
      assert result.usage == prior_usage

      # The event is still recorded (token reset + compression counter).
      assert result.total_tokens == 0
      assert compression_count(@stage1_agent) == 1
    end

    test "the stage-1 refresh message carries NO background-jobs snapshot",
         %{repo_path: repo_path} do
      register_agent(@jobs_agent)

      # A still-running `sleep` keeps the snapshot deterministic — no waiting for
      # a terminal status.
      {_registry, job} = start_live_job!(repo_path, "long running suite")

      # The SAME stage-1 fixture as the pruning test above, so the stage-1 adopt
      # path is what reaches `refresh_messages/2` (and no LLM call is spent).
      st =
        state(@jobs_agent, conversation_with_old_tool_result(),
          repo_path: repo_path,
          total_tokens: 60_000
        )

      result =
        ContextCompression.compress_if_needed(st,
          agent_id: @jobs_agent,
          llm_model: "stub:model",
          llm_context_window: @window_128k
        )

      assert %LoopState{} = result

      refresh = result |> messages_of() |> List.last()
      assert refresh.role == :user

      # The plain runtime-context refresh is still appended on the prune-only
      # path — but it deliberately carries NO background-jobs snapshot.
      text = text_of(refresh)
      assert text =~ "stage-test context body"
      assert text =~ "SUPERSEDES any earlier <context> snapshot"
      refute text =~ "## Background Jobs"
      refute text =~ job.id
    end

    test "Stage 1 is REJECTED when most characters are non-prunable, so Stage 2 runs over the ORIGINAL list",
         %{repo_path: repo_path} do
      register_agent(@reject_agent)

      server = EvoGit.Agent.ContextCompressionStagesTest.StubLlmServer.start!(@summary)
      llm_model = %{provider: :openai, id: "stub-model", base_url: server.url, api_key: "k"}

      original = conversation_stage1_rejected()
      pruned = ToolResultPruner.prune(original)
      info = Threshold.for_model(llm_model, context_window: @window_128k)
      target = Threshold.pruning_target(info, 0.5)
      projected = Threshold.project(120_000, pruned.chars_before, pruned.chars_after)

      # Precondition — Stage 1 DOES prune here, but the projection lands ABOVE
      # the Stage-1 target (and still below the reported count), which is exactly
      # the "not worth invalidating the provider cache" case.
      assert pruned.pruned > 0
      assert projected > target
      assert projected < 120_000
      assert Threshold.exceeded?(120_000, info)

      st =
        state(@reject_agent, original,
          repo_path: repo_path,
          total_tokens: 120_000,
          turn: 7
        )

      result =
        ContextCompression.compress_if_needed(st,
          agent_id: @reject_agent,
          llm_model: llm_model,
          llm_context_window: @window_128k
        )

      assert %LoopState{} = result

      # Exactly ONE summarising request was served (Stage 2, over the ORIGINAL
      # list) — the rejected prune never became a second call.
      assert EvoGit.Agent.ContextCompressionStagesTest.StubLlmServer.request_count(server) == 1
      assert_received {:stub_llm_request, request_body}

      # The request body carries the ORIGINAL transcript: the middle sentinel of
      # the huge old tool result (Stage 1 would have DELETED it) and the long old
      # assistant/user text are both present, and no prune marker appears.
      assert request_body =~ @middle_sentinel
      assert request_body =~ "old analysis aaa"
      assert request_body =~ "old note bbb"
      refute request_body =~ "[... tool result middle pruned ...]"

      # The old span really was replaced by a checkpoint, and the recent tail
      # survived verbatim.
      messages = messages_of(result)
      assert Checkpoint.checkpoint?(Enum.at(messages, 2))
      refute Enum.any?(messages, &(&1.tool_call_id == "call_old"))
      assert_no_orphaned_tools(messages)

      assert result.total_tokens == 0
      assert compression_count(@reject_agent) == 1
    end

    test "the projected token count is what decides — pruning is not enough here", %{
      repo_path: repo_path
    } do
      register_agent(@stage1_agent)

      # An ordinary (non-prunable) conversation: nothing to prune, so the
      # projection keeps the reported count and stage 2 would have to run. We
      # assert the DECISION, not the call: `Threshold.project/3` on an unchanged
      # list never dips below the trigger.
      original = conversation_for_checkpoint()
      info = Threshold.for_model("stub:model", context_window: @window_128k)

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
  # [:llm, :tool_result_pruning] = false — Stage 1 never runs
  # ---------------------------------------------------------------------------

  describe "tool_result_pruning disabled by config" do
    test "a conversation with NO old span keeps the huge tool result BYTE-IDENTICALLY and calls no LLM",
         %{repo_path: repo_path, config_dir: config_dir} do
      register_agent(@pruning_off_agent)
      write_config!(config_dir, "[llm]\ntool_result_pruning = false\n")

      server = EvoGit.Agent.ContextCompressionStagesTest.StubLlmServer.start!(@summary)

      original = conversation_without_old_span()

      # Precondition: Stage 2 has NOTHING to replace (so no summarising call is
      # reachable) while Stage 1 — when enabled — WOULD rewrite the huge tool
      # result. That contrast is what makes the byte-identity below meaningful.
      assert Checkpoint.split(original).old == []
      pruned = ToolResultPruner.prune(original)
      assert pruned.pruned == 1
      assert pruned.chars_after < pruned.chars_before

      st = state(@pruning_off_agent, original, repo_path: repo_path, total_tokens: 120_000)

      result =
        ContextCompression.compress_if_needed(st,
          agent_id: @pruning_off_agent,
          llm_model: "stub:model",
          llm_context_window: @window_128k
        )

      assert %LoopState{} = result

      # Neither stage ran: the recorded count reset and the counter moved, but
      # the transcript (plus the appended refresh message) is untouched.
      messages = messages_of(result)
      assert length(messages) == length(original) + 1
      assert Enum.take(messages, length(original)) == original

      tool_message = Enum.at(messages, 2)
      assert tool_message.role == :tool
      assert tool_message.tool_call_id == "call_a"
      assert text_of(tool_message) == @huge_tool_output
      refute text_of(tool_message) =~ "tool result middle pruned"

      assert EvoGit.Agent.ContextCompressionStagesTest.StubLlmServer.request_count(server) == 0
      refute_received {:stub_llm_request, _body}

      assert result.total_tokens == 0
      assert compression_count(@pruning_off_agent) == 1
    end

    test "a conversation WITH an old span summarises the UN-PRUNED transcript", %{
      repo_path: repo_path,
      config_dir: config_dir
    } do
      register_agent(@pruning_off_span_agent)
      write_config!(config_dir, "[llm]\ntool_result_pruning = false\n")

      server = EvoGit.Agent.ContextCompressionStagesTest.StubLlmServer.start!(@summary)
      llm_model = %{provider: :openai, id: "stub-model", base_url: server.url, api_key: "k"}

      original = conversation_stage1_rejected()
      assert Checkpoint.split(original).old != []

      st = state(@pruning_off_span_agent, original, repo_path: repo_path, total_tokens: 120_000)

      result =
        ContextCompression.compress_if_needed(st,
          agent_id: @pruning_off_span_agent,
          llm_model: llm_model,
          llm_context_window: @window_128k
        )

      assert %LoopState{} = result

      # Stage 2 ran once, and its request carried the huge tool output VERBATIM:
      # the middle sentinel Stage 1 always deletes is still there.
      assert EvoGit.Agent.ContextCompressionStagesTest.StubLlmServer.request_count(server) == 1
      assert_received {:stub_llm_request, request_body}
      assert request_body =~ @middle_sentinel
      refute request_body =~ "[... tool result middle pruned ...]"

      messages = messages_of(result)
      assert Checkpoint.checkpoint?(Enum.at(messages, 2))
      refute Enum.any?(messages, &(&1.tool_call_id == "call_old"))

      assert result.total_tokens == 0
      assert compression_count(@pruning_off_span_agent) == 1
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
        ContextCompression.compress_if_needed(st,
          agent_id: @stage2_agent,
          llm_model: llm_model,
          llm_context_window: @window_128k
        )

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

    test "the summarising refresh message re-injects the agent's LIVE background jobs",
         %{repo_path: repo_path} do
      register_agent(@jobs_stage2_agent)

      {_registry, job} = start_live_job!(repo_path, "summarising suite")

      server = EvoGit.Agent.ContextCompressionStagesTest.StubLlmServer.start!(@summary)
      llm_model = %{provider: :openai, id: "stub-model", base_url: server.url, api_key: "k"}

      st =
        state(@jobs_stage2_agent, conversation_for_checkpoint(),
          repo_path: repo_path,
          total_tokens: 60_000,
          turn: 7
        )

      result =
        ContextCompression.compress_if_needed(st,
          agent_id: @jobs_stage2_agent,
          llm_model: llm_model,
          llm_context_window: @window_128k
        )

      assert %LoopState{} = result
      assert EvoGit.Agent.ContextCompressionStagesTest.StubLlmServer.request_count(server) == 1

      # The refresh appended by the SUMMARISING path carries the live snapshot.
      refresh = result |> messages_of() |> List.last()
      assert refresh.role == :user

      text = text_of(refresh)
      assert text =~ "## Background Jobs"
      assert text =~ job.id
      assert text =~ "summarising suite"
      assert text =~ "running"
    end

    test "a SECOND summarising compression keeps exactly ONE current Background Jobs section",
         %{repo_path: repo_path} do
      register_agent(@jobs_accumulation_agent)

      # FIRST snapshot: job A is live.
      {_registry_a, job_a} = start_live_job!(repo_path, "first job alpha")

      server = EvoGit.Agent.ContextCompressionStagesTest.StubLlmServer.start!(@summary)
      llm_model = %{provider: :openai, id: "stub-model", base_url: server.url, api_key: "k"}

      first =
        state(@jobs_accumulation_agent, conversation_for_checkpoint(),
          repo_path: repo_path,
          total_tokens: 60_000,
          turn: 7
        )

      first_result =
        ContextCompression.compress_if_needed(first,
          agent_id: @jobs_accumulation_agent,
          llm_model: llm_model,
          llm_context_window: @window_128k
        )

      assert %LoopState{} = first_result
      assert first_result |> messages_of() |> List.last() |> text_of() =~ job_a.id

      # Turn the first result into a LATER conversation. The appended turns carry
      # turn numbers far ABOVE the first compression's turn (7), so the second
      # compression's recency boundary lands AFTER the stale refresh: the stale
      # snapshot sits inside the protected recent tail and would survive verbatim
      # without the explicit cleanup.
      extended = messages_of(first_result) ++ turn_pairs(17..19)
      split = Checkpoint.split(extended)

      assert length(split.old) > 0
      assert Enum.any?(split.recent, &(text_of(&1) =~ job_a.id))
      refute Enum.any?(split.old, &(text_of(&1) =~ job_a.id))

      # SECOND snapshot: a FRESH registry holding only job B. A killed/finished
      # job would still be listed by `snapshot/1`, so a fresh registry is what
      # makes "absent from the current snapshot" real.
      {_registry_b, job_b} = start_live_job!(repo_path, "second job beta")
      assert job_b.id != job_a.id

      second =
        state(@jobs_accumulation_agent, extended,
          repo_path: repo_path,
          total_tokens: 60_000,
          turn: 20
        )

      second_result =
        ContextCompression.compress_if_needed(second,
          agent_id: @jobs_accumulation_agent,
          llm_model: llm_model,
          llm_context_window: @window_128k
        )

      assert %LoopState{} = second_result
      assert EvoGit.Agent.ContextCompressionStagesTest.StubLlmServer.request_count(server) == 2

      messages = messages_of(second_result)
      texts = Enum.map(messages, &text_of/1)

      # Exactly ONE `## Background Jobs` section survives, and it is the CURRENT
      # snapshot: the stale job id is gone from the WHOLE context.
      assert Enum.count(texts, &String.contains?(&1, "## Background Jobs")) == 1
      refute Enum.any?(texts, &String.contains?(&1, job_a.id))
      assert Enum.any?(texts, &String.contains?(&1, job_b.id))

      # Head byte-identical, order preserved, the new refresh LAST.
      assert Enum.at(messages, 0) == Enum.at(extended, 0)
      assert Enum.at(messages, 1) == Enum.at(extended, 1)

      refresh = List.last(messages)
      assert ContextBuilder.refresh_message?(refresh)
      assert text_of(refresh) =~ job_b.id

      assert second_result.total_tokens == 0
      assert compression_count(@jobs_accumulation_agent) == 2
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
  # drop_stale_background_job_refreshes/1 — the stale-snapshot cleanup
  # ---------------------------------------------------------------------------

  describe "drop_stale_background_job_refreshes/1" do
    test "drops refreshes carrying a Background Jobs section, keeps every other message in order",
         %{repo_path: repo_path} do
      plain_refresh =
        ContextBuilder.build_context_refresh_message(
          %{node_path: "./", repo_path: repo_path},
          nil
        )

      jobs_refresh =
        ContextBuilder.build_context_refresh_message(
          %{
            node_path: "./",
            repo_path: repo_path,
            background_jobs: [%{id: "bash-stale00000000", status: :running, label: "stale job"}]
          },
          nil
        )

      assert ContextBuilder.refresh_message?(plain_refresh)
      assert ContextBuilder.refresh_message?(jobs_refresh)
      assert text_of(jobs_refresh) =~ "## Background Jobs"

      system = ReqLLM.Context.system(@system_text)
      first_user = ReqLLM.Context.user(@objective)
      assistant = ReqLLM.Context.assistant("working")
      tool = tool_result("call_x", "tool output")
      checkpoint = Checkpoint.checkpoint_message(@summary, 3)
      notice = ReqLLM.Context.user("[NOTICE] 1 background shell job finished:\n- `bash-x`")

      messages = [
        system,
        first_user,
        assistant,
        jobs_refresh,
        tool,
        checkpoint,
        plain_refresh,
        notice
      ]

      assert ContextCompression.drop_stale_background_job_refreshes(messages) ==
               [system, first_user, assistant, tool, checkpoint, plain_refresh, notice]

      # TOTAL: malformed message shapes never match and never raise.
      malformed = [
        nil,
        :not_a_message,
        %{role: :user},
        %ReqLLM.Message{role: :user, content: "binary content is not a list"},
        %ReqLLM.Message{role: :user, content: [%{type: :text, text: 42}]},
        %ReqLLM.Message{role: :assistant, content: [%{type: :text, text: @summary}]}
      ]

      assert ContextCompression.drop_stale_background_job_refreshes(malformed ++ [jobs_refresh]) ==
               malformed

      assert ContextCompression.drop_stale_background_job_refreshes(:not_a_list) == :not_a_list
    end
  end

  # ---------------------------------------------------------------------------
  # Window-relative trigger
  # ---------------------------------------------------------------------------

  describe "window-relative trigger" do
    test "a 1M-context model does NOT compress at 200_000 tokens", %{repo_path: repo_path} do
      register_agent(@window_agent)

      assert Threshold.for_model("stub:model", context_window: @window_1m).threshold == 800_000

      st =
        state(@window_agent, conversation_with_old_tool_result(),
          repo_path: repo_path,
          total_tokens: 200_000
        )

      result =
        ContextCompression.compress_if_needed(st,
          agent_id: @window_agent,
          llm_model: "stub:model",
          llm_context_window: @window_1m
        )

      # The identical state — no log line, no pruning, no slot, no counter.
      assert result == st
      assert compression_count(@window_agent) == 0
    end

    test "a 128k-context model compresses at 120_000 tokens", %{repo_path: repo_path} do
      register_agent(@window_agent)

      info = Threshold.for_model("stub:model", context_window: @window_128k)
      assert info.threshold == @threshold_128k
      assert Threshold.exceeded?(120_000, info)

      st =
        state(@window_agent, conversation_with_old_tool_result(),
          repo_path: repo_path,
          total_tokens: 120_000
        )

      result =
        ContextCompression.compress_if_needed(st,
          agent_id: @window_agent,
          llm_model: "stub:model",
          llm_context_window: @window_128k
        )

      assert result.total_tokens == 0
      assert compression_count(@window_agent) == 1
      assert Enum.any?(messages_of(result), &(text_of(&1) =~ "tool result middle pruned"))
      # Usage untouched: the projection landed under the trigger, so no call.
      assert result.usage == st.usage
    end
  end

  # ---------------------------------------------------------------------------
  # The explicit [:llm, :compression_threshold_tokens] override
  #
  # There is no "unknown window" path any more: the window ALWAYS defaults to
  # 200_000, so the only way to move the trigger off the formula is this key.
  # ---------------------------------------------------------------------------

  describe "[:llm, :compression_threshold_tokens] override" do
    test "a positive override wins over the window and still gates strictly", %{
      repo_path: repo_path,
      config_dir: config_dir
    } do
      register_agent(@config_agent)
      write_config!(config_dir, "[llm]\ncompression_threshold_tokens = 90000\n")

      info = Threshold.for_model("mystery:model", context_window: @window_1m)

      # The override wins VERBATIM, while the reported window is still the
      # configured one (never nil).
      assert info == %{threshold: 90_000, window: @window_1m, source: :config}
      assert EvoGit.Config.resolve([:llm, :compression_threshold_tokens]) == 90_000

      # Exactly ON the threshold is NOT enough (strictly greater).
      at_threshold =
        state(@config_agent, conversation_with_old_tool_result(),
          repo_path: repo_path,
          total_tokens: 90_000
        )

      assert ContextCompression.compress_if_needed(at_threshold,
               agent_id: @config_agent,
               llm_model: "mystery:model",
               llm_context_window: @window_1m
             ) == at_threshold

      assert compression_count(@config_agent) == 0

      # One past it compresses — via Stage 1 (0.5 * 1M = 500_000 > the 90_000
      # override, so pruning is measured against the override itself), so no LLM
      # is reachable here.
      beyond =
        state(@config_agent, conversation_with_old_tool_result(),
          repo_path: repo_path,
          total_tokens: 90_001
        )

      result =
        ContextCompression.compress_if_needed(beyond,
          agent_id: @config_agent,
          llm_model: "mystery:model",
          llm_context_window: @window_1m
        )

      assert result.total_tokens == 0
      assert compression_count(@config_agent) == 1
      assert Enum.any?(messages_of(result), &(text_of(&1) =~ "tool result middle pruned"))
    end
  end

  # ---------------------------------------------------------------------------
  # Incompressible shapes
  # ---------------------------------------------------------------------------

  describe "incompressible context shapes" do
    test "an empty context is returned unchanged", %{repo_path: repo_path} do
      register_agent(@window_agent)

      st = state(@window_agent, [], repo_path: repo_path, total_tokens: 60_000)

      result =
        ContextCompression.compress_if_needed(st,
          agent_id: @window_agent,
          llm_model: "stub:model",
          llm_context_window: @window_128k
        )

      assert result == st
      assert compression_count(@window_agent) == 0
    end

    test "a system-only context is returned unchanged", %{repo_path: repo_path} do
      register_agent(@window_agent)

      st =
        state(@window_agent, [ReqLLM.Context.system(@system_text)],
          repo_path: repo_path,
          total_tokens: 60_000
        )

      result =
        ContextCompression.compress_if_needed(st,
          agent_id: @window_agent,
          llm_model: "stub:model",
          llm_context_window: @window_128k
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
