defmodule EvoGit.Agent.ImplicitCompletionTest.StubLlmServer do
  @moduledoc """
  Minimal raw-TCP SSE endpoint that answers a SCRIPT of OpenAI-style streaming
  completions — one script entry per HTTP request, the LAST entry repeated once
  the script is exhausted — so a test can drive "the model wrote text", "the
  model answered nothing at all", or a mixed sequence, and can count exactly how
  many requests the agent issued.

  A script entry is either `{:text, text}` (one streamed assistant text part) or
  `:empty` (a role-only delta: no content part, so the assembled assistant
  message carries no usable text).

  `EvoGit.TestLlmServer` always answers `content-type: application/json`, which
  a streaming (`ReqLLM.stream_text/3`) request cannot parse, so a SUCCESSFUL
  streaming round trip needs a `text/event-stream` responder. Handing the agent
  a model spec whose `base_url` points here makes the real ReqLLM stack produce
  a genuine `%ReqLLM.Response{}` — `CompletionProtocol.classify/1`,
  `ReqLLM.Response.text/1` and the usage/cost accounting are exercised for real,
  with no network and no mocks.

  Every served request's BODY is also sent to the test process as
  `{:stub_request, index, body}` so a test can assert what the agent actually
  asked the model on each attempt (e.g. that exactly one nudge message was
  appended before the second request).
  """
  import ExUnit.Callbacks, only: [on_exit: 1]

  @usage %{prompt_tokens: 13, completion_tokens: 5, total_tokens: 18}

  @doc """
  Starts the server for `script` and returns `%{url: url, port: port, counters:
  counters}` (`counters` is read by `request_count/1`).
  """
  def start!(script) when is_list(script) and script != [] do
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
    payloads = Enum.map(script, &sse_payload/1)
    parent = self()
    acceptor = spawn(fn -> accept_loop(listen, payloads, counters, parent, 0) end)

    on_exit(fn ->
      Process.exit(acceptor, :kill)
      :gen_tcp.close(listen)
    end)

    %{url: "http://127.0.0.1:#{port}", port: port, counters: counters}
  end

  @doc "Number of HTTP requests served so far."
  def request_count(%{counters: counters}), do: :counters.get(counters, 1)

  defp accept_loop(listen, payloads, counters, parent, index) do
    case :gen_tcp.accept(listen) do
      {:ok, socket} ->
        serve(socket, payload_for(payloads, index), counters, parent, index)
        :gen_tcp.close(socket)
        accept_loop(listen, payloads, counters, parent, index + 1)

      {:error, _reason} ->
        :ok
    end
  end

  # The script's LAST entry repeats, so an agent that issues MORE requests than
  # the script describes keeps answering the same way — the request COUNT then
  # tells a nudge/extra-request bug apart from correct behaviour.
  defp payload_for(payloads, index), do: Enum.at(payloads, index, List.last(payloads))

  # Drain the request body BEFORE replying (closing on unread data can RST the
  # response before the client reads it), then report it and answer.
  defp serve(socket, payload, counters, parent, index) do
    {headers, rest} = read_headers(socket, "")
    body = drain_body(socket, rest, content_length(headers))
    :counters.add(counters, 1, 1)
    send(parent, {:stub_request, index, body})
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

  defp sse_payload({:text, text}) do
    [
      chunk(%{role: "assistant", content: text}, nil),
      chunk(%{}, "stop", @usage),
      "data: [DONE]\n\n"
    ]
    |> Enum.join("")
  end

  # A role-only delta: no `content` key at all, so ReqLLM's OpenAI decoder
  # emits no text chunk and the assembled assistant message has no usable text.
  defp sse_payload(:empty) do
    [
      chunk(%{role: "assistant"}, nil),
      chunk(%{}, "stop", @usage),
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

defmodule EvoGit.Agent.ImplicitCompletionTest do
  @moduledoc """
  End-to-end coverage of the harness-aligned IMPLICIT completion protocol and of
  the single-nudge recovery for a genuinely EMPTY response, driven against a
  real streaming LLM round trip.

  ## What is pinned

  * `EvoGit.Agent.ToolDispatch.prompt_until_tools_or_limit/5` classifies one LLM
    turn through `EvoGit.Agent.CompletionProtocol.classify/1`: a reply with ZERO
    tool calls and usable text is `{:implicit_completion, response, text}` —
    **no nudge and no extra request** (the stub server's `request_count/1` stays
    at 1), and the text is returned verbatim.
  * The implicit route through `process_llm_response/6` (6th arg = the report
    text) returns `{:ok, %EvoGit.Agent.Result{}}` whose `result` is exactly that
    text, and `build_completion/2` commits pending work BEFORE capturing
    `commit_sha` — the reported sha therefore CONTAINS the agent's still
    uncommitted file change (the reviewable-commit guarantee) and the worktree
    is left clean. The agent loop does NOT continue (`loop_fn` is never called)
    and the dirty-workspace gate of the EXPLICIT `complete_task` route never
    applies: a dirty workspace does not turn a legitimate finish into a refusal.
  * The same holds for a SUBAGENT (depth 1, non-nil `parent_id`) — one request,
    no nudge — and its `%Result{}` surfaces to the parent through
    `EvoGit.Agent.SubagentProcessing.format_subagent_result/1`.
  * A genuinely EMPTY response (zero tool calls AND no text) gets EXACTLY ONE
    nudge and one re-prompt, so the stub server sees exactly 2 requests (not 4);
    still empty, the turn ends gracefully with `{:error, :protocol_violation}`,
    and the second request provably carried exactly one appended nudge message.

  ## Seams (no mocks — this codebase has no Mox/Meck)

  * A successful STREAMING reply needs a `text/event-stream` responder:
    `EvoGit.Agent.ImplicitCompletionTest.StubLlmServer` (in-file, raw
    `:gen_tcp`) serves a SCRIPT of responses and counts requests. Handing an
    agent a model spec `%{provider: :openai, id: ..., base_url: server.url,
    api_key: ...}` makes the real ReqLLM stack produce a genuine
    `%ReqLLM.Response{}`. Its one-off `LLMDB.load/1` catalog decode is paid once
    in `setup_all/1`, never per test.
  * Agents are registered in the app-global `:evogit_agent_state` ETS table via
    `EvoGit.AgentScheduler.Store.put_agent_state/2` (unique ids, deleted in
    `on_exit`), and the per-agent model is bound by that row — so the LLM slot
    request resolves to the pinned single-profile pool.
  * Real git repositories on `System.tmp_dir!()` via `EvoGit.Adapters.Git`, for
    the commit-ordering and worktree-cleanliness assertions.

  Serialized (`async: false`): the suite drives the global
  `EvoGit.AgentScheduler` (config update for a deterministic slot pool), the
  app-global `:evogit_agent_state` ETS table, and the scheduler's LLM slot pool.
  """
  use ExUnit.Case, async: false

  alias EvoGit.Agent.ImplicitCompletionTest.StubLlmServer
  alias EvoGit.Agent.LoopState
  alias EvoGit.Agent.Result
  alias EvoGit.Agent.SubagentProcessing
  alias EvoGit.Agent.ToolDispatch
  alias EvoGit.Agent.Tools.CompleteTask
  alias EvoGit.Adapters.Git
  alias EvoGit.AgentScheduler
  alias EvoGit.AgentScheduler.AgentState
  alias EvoGit.AgentScheduler.Store, as: SchedStore
  alias EvoGit.Core.ContextNode
  alias EvoGit.Core.PhyloGraphNode

  # The model-profile id every agent in this file is bound to; the setup pins a
  # small deterministic pool for it so a slot request is granted immediately.
  @model_id "default"
  @system_text "You are the implicit-completion test agent."
  @objective "Objective: finish the task and report what you did."
  # The report the stub "model" writes. Deliberately free of the dirty-workspace
  # wording so the context scan below cannot be satisfied by the report itself.
  @report_text "Implemented the parser and ran the suite: 42 tests, 0 failures."
  @child_report_text "Child finished: added the CONTEXT.md for the parser node."
  # A distinctive fragment of the single nudge message, used to prove the nudged
  # context carried EXACTLY one nudge on the second request.
  @nudge_fragment "did not write any text"
  @uncommitted_file "work.txt"
  # `EvoGit.Adapters.Git.run/2` trims command output, so `Git.show/2` hands this
  # content back WITHOUT the trailing newline (assertions compare trimmed).
  @uncommitted_content "uncommitted work\n"

  setup_all do
    # ReqLLM's FIRST call in a fresh BEAM pays a one-off `LLMDB.load/1`: reading
    # + JSON-decoding the packaged multi-megabyte model catalog (~2.5s). Pay it
    # here ONCE so no individual test is charged it; a build-phase/transport
    # failure is harmless at this point (each test's own request reports its own
    # error loudly).
    server = StubLlmServer.start!([{:text, "warm-up"}])

    case ReqLLM.stream_text(
           stub_model(server),
           ReqLLM.Context.new([ReqLLM.Context.user("hi")]),
           []
         ) do
      {:ok, stream_resp} ->
        _ = ReqLLM.StreamResponse.process_stream(stream_resp)
        :ok

      {:error, _reason} ->
        :ok
    end
  end

  setup do
    assert Process.whereis(EvoGit.AgentScheduler), "AgentScheduler must be running"
    AgentScheduler.resume()

    # One deterministic LLM pool for `@model_id` (2 slots, no peak windows), so
    # every slot request below is granted immediately regardless of any user
    # config.toml profile that might carry a peak-hours hard pause.
    original_profiles = AgentScheduler.get_config(:model_profiles)

    AgentScheduler.update_config(
      model_profiles: [%{id: @model_id, model: "stub:model", concurrency: 2}]
    )

    on_exit(fn -> AgentScheduler.update_config(model_profiles: original_profiles) end)

    repo = new_repo!()
    on_exit(fn -> File.rm_rf!(repo) end)

    %{repo: repo}
  end

  # ---------------------------------------------------------------------------
  # 1. Text-only completion, ROOT agent (depth 0, no parent)
  # ---------------------------------------------------------------------------
  describe "text-only reply from the ROOT agent" do
    test "is an implicit completion: one request, the text is the result, and the reported sha contains the uncommitted change",
         %{repo: repo} do
      agent_id = new_agent_id()
      server = StubLlmServer.start!([{:text, @report_text}])
      register_agent(agent_id, stub_model(server), repo, parent_id: nil)
      {:ok, pre_sha} = Git.rev_parse(repo)
      # The agent leaves work UNCOMMITTED: only the implicit completion's
      # commit-before-capture can make the reported sha reviewable.
      File.write!(Path.join(repo, @uncommitted_file), @uncommitted_content)
      assert {:ok, dirty} = Git.status(repo)
      assert dirty =~ @uncommitted_file

      context = initial_context()
      state = loop_state(agent_id, context, repo, depth: 0, parent_id: nil)
      {loop_fn, recovery_fn} = never_called_funs()

      assert {:implicit_completion, response, text} =
               prompt_once(agent_id, context)

      # The report text is the model's own text, verbatim — and the whole turn
      # cost exactly ONE request: no nudge, no re-prompt.
      assert text == @report_text
      assert %ReqLLM.Response{} = response
      assert ReqLLM.Response.text(response) == @report_text
      assert StubLlmServer.request_count(server) == 1

      assert {:ok, %Result{} = result} =
               ToolDispatch.process_llm_response(
                 response,
                 state,
                 [],
                 loop_fn,
                 recovery_fn,
                 text
               )

      assert result.result == @report_text
      assert is_binary(result.commit_sha)
      # No extra LLM request on the completion path either.
      assert StubLlmServer.request_count(server) == 1

      # The loop does NOT continue, and no recovery is ever triggered.
      refute_received :loop_fn_called
      refute_received :recovery_triggered

      # The reported sha is a REAL commit that is NOT the pre-flow HEAD, and it
      # CONTAINS the agent's previously uncommitted file.
      sha = result.commit_sha
      assert {:ok, ^sha} = Git.rev_parse(repo, sha)
      refute sha == pre_sha
      assert {:ok, head} = Git.rev_parse(repo)
      assert head == result.commit_sha
      assert {:ok, committed} = Git.show(repo, "#{result.commit_sha}:#{@uncommitted_file}")
      assert committed == String.trim_trailing(@uncommitted_content)
      assert {:ok, listed} = Git.ls_tree_names(repo, result.commit_sha)
      assert Enum.sort(listed) == ["README.md", @uncommitted_file]

      # Committing was part of the finish, so the worktree is clean afterwards.
      assert {:ok, ""} = Git.status(repo)

      # The dirty-workspace / refusal tool-result family never appears anywhere
      # in the agent's context: the finish was a Result, not a {:continue, ...}.
      # (The positive half keeps the negative assertion non-vacuous: the context
      # really was synced and really does carry the model's final message.)
      live_context = context_text(agent_id)
      assert live_context =~ @report_text
      refute live_context =~ ~r/\bdirty\b|workspace|uncommitted changes/i
    end
  end

  # ---------------------------------------------------------------------------
  # 2. The dirty-workspace boundary belongs to the EXPLICIT route only
  # ---------------------------------------------------------------------------
  describe "dirty worktree at finish time" do
    test "does not gate an implicit completion (the change is committed into the reported sha)",
         %{repo: repo} do
      agent_id = new_agent_id()
      server = StubLlmServer.start!([{:text, @report_text}])
      register_agent(agent_id, stub_model(server), repo, parent_id: nil)
      {:ok, pre_sha} = Git.rev_parse(repo)
      # Deliberately dirty BEFORE the first LLM request: `complete_task` would
      # answer with a tool result asking the model to commit and call again.
      File.write!(Path.join(repo, @uncommitted_file), @uncommitted_content)
      File.write!(Path.join(repo, "second.txt"), "second change\n")

      # CONTROL: this exact worktree state DOES trip the EXPLICIT route's gate,
      # so the assertions below prove the IMPLICIT route skips it — not that the
      # repo happened to be clean.
      assert {:dirty, refusal} = CompleteTask.check_workspace_dirty(repo)
      assert refusal =~ "the workspace has uncommitted changes"

      context = initial_context()
      state = loop_state(agent_id, context, repo, depth: 0, parent_id: nil)
      {loop_fn, recovery_fn} = never_called_funs()

      assert {:implicit_completion, response, text} = prompt_once(agent_id, context)
      assert StubLlmServer.request_count(server) == 1

      assert {:ok, %Result{} = result} =
               ToolDispatch.process_llm_response(
                 response,
                 state,
                 [],
                 loop_fn,
                 recovery_fn,
                 text
               )

      assert result.result == @report_text
      refute_received :loop_fn_called
      refute_received :recovery_triggered

      # BOTH pending files are in the reported commit, and the worktree is clean.
      assert {:ok, head} = Git.rev_parse(repo)
      assert head == result.commit_sha
      refute result.commit_sha == pre_sha
      assert {:ok, committed} = Git.show(repo, "#{result.commit_sha}:#{@uncommitted_file}")
      assert committed == String.trim_trailing(@uncommitted_content)
      assert {:ok, "second change"} = Git.show(repo, "#{result.commit_sha}:second.txt")
      assert {:ok, ""} = Git.status(repo)
      # ... and the explicit route's gate is now satisfied as well.
      assert {:clean, nil} = CompleteTask.check_workspace_dirty(repo)
      refute context_text(agent_id) =~ ~r/the workspace has uncommitted changes/i
    end
  end

  # ---------------------------------------------------------------------------
  # 3. Text-only completion, SUBAGENT (depth 1, non-nil parent)
  # ---------------------------------------------------------------------------
  describe "text-only reply from a SUBAGENT" do
    test "is an implicit completion too: one request, the child text is the result, and it surfaces to the parent",
         %{repo: repo} do
      parent_id = new_agent_id()
      child_id = new_agent_id()
      server = StubLlmServer.start!([{:text, @child_report_text}])
      register_agent(child_id, stub_model(server), repo, parent_id: parent_id, depth: 1)
      {:ok, pre_sha} = Git.rev_parse(repo)
      File.write!(Path.join(repo, @uncommitted_file), @uncommitted_content)

      # The child's `%Result{}` is produced by driving the SAME production
      # `ToolDispatch` path with a child-shaped `LoopState`/`AgentState` (depth 1,
      # non-nil parent_id) rather than spawning a full heavyweight agent run —
      # the protocol classification under test is identical either way.
      context = initial_context()
      state = loop_state(child_id, context, repo, depth: 1, parent_id: parent_id)
      {loop_fn, recovery_fn} = never_called_funs()

      assert {:implicit_completion, response, text} = prompt_once(child_id, context)
      assert text == @child_report_text
      assert StubLlmServer.request_count(server) == 1

      assert {:ok, %Result{} = result} =
               ToolDispatch.process_llm_response(
                 response,
                 state,
                 [],
                 loop_fn,
                 recovery_fn,
                 text
               )

      assert result.result == @child_report_text
      assert StubLlmServer.request_count(server) == 1
      refute_received :loop_fn_called
      refute_received :recovery_triggered

      # The child's pending work is in its own reported commit.
      refute result.commit_sha == pre_sha
      assert {:ok, committed} = Git.show(repo, "#{result.commit_sha}:#{@uncommitted_file}")
      assert committed == String.trim_trailing(@uncommitted_content)
      assert {:ok, ""} = Git.status(repo)

      # ... and the parent-visible tool-result string carries the child's own
      # report text plus its final commit.
      surfaced = SubagentProcessing.format_subagent_result({:ok, result})
      assert surfaced =~ @child_report_text
      assert surfaced =~ result.commit_sha
    end
  end

  # ---------------------------------------------------------------------------
  # 4. Empty-response recovery: the nudge budget is EXACTLY 1
  # ---------------------------------------------------------------------------
  describe "a genuinely empty response" do
    test "gets exactly ONE nudge (2 requests total, not 4) and then ends with {:error, :protocol_violation}",
         %{repo: repo} do
      agent_id = new_agent_id()
      # Every request answers EMPTY — the script's last entry repeats, so an
      # unbounded (or 3-nudge) recovery loop would keep going and be caught by
      # the request-count assertion below.
      server = StubLlmServer.start!([:empty])
      register_agent(agent_id, stub_model(server), repo, parent_id: nil)

      context = initial_context()
      Process.put(:evogit_agent_id, agent_id)

      assert ToolDispatch.prompt_until_tools_or_limit(context, [], [], agent_id, 1) ==
               {:error, :protocol_violation}

      # Initial attempt + exactly ONE nudge attempt.
      assert StubLlmServer.request_count(server) == 2
      assert_received {:stub_request, 0, first_body}
      assert_received {:stub_request, 1, second_body}
      # The initial request carries NO nudge; the nudged one carries it ONCE.
      assert occurrences(first_body, @nudge_fragment) == 0
      assert occurrences(second_body, @nudge_fragment) == 1
    end

    test "the nudge is one appended USER message around the same context" do
      context = initial_context()
      nudge = ToolDispatch.no_tool_call_nudge_message()
      nudged = ToolDispatch.append_no_tool_call_nudge(context)

      assert nudge.role == :user
      assert length(nudged.messages) == length(context.messages) + 1
      assert List.last(nudged.messages) == nudge
      assert nudged.messages |> Enum.drop(-1) == context.messages
      assert context_text_of(nudge) =~ @nudge_fragment
    end
  end

  # ---------------------------------------------------------------------------
  # 5. The nudge budget is never spent on a TEXT reply
  # ---------------------------------------------------------------------------
  describe "a text reply" do
    test "never consumes the nudge budget — it completes on the FIRST request", %{repo: repo} do
      agent_id = new_agent_id()
      # A one-entry script: if the text reply were nudged, the repeated entry
      # would produce a SECOND request that the count refutes.
      server = StubLlmServer.start!([{:text, @report_text}])
      register_agent(agent_id, stub_model(server), repo, parent_id: nil)

      context = initial_context()
      Process.put(:evogit_agent_id, agent_id)

      assert {:implicit_completion, _response, text} =
               ToolDispatch.prompt_until_tools_or_limit(context, [], [], agent_id, 1)

      assert text == @report_text
      assert StubLlmServer.request_count(server) == 1
      assert_received {:stub_request, 0, body}
      assert occurrences(body, @nudge_fragment) == 0
    end
  end

  # ---------------------------------------------------------------------------
  # Helpers
  # ---------------------------------------------------------------------------

  # A model spec whose `base_url` is the raw-TCP SSE stub: ReqLLM streams a real
  # request at it and assembles a genuine `%ReqLLM.Response{}`. The dummy key
  # only clears ReqLLM's provider-build phase; the local server never checks it.
  defp stub_model(server) do
    %{provider: :openai, id: "stub-model", base_url: server.url, api_key: "test-key"}
  end

  defp new_agent_id, do: 9_700_000 + :erlang.unique_integer([:positive])

  defp initial_context do
    ReqLLM.Context.new([
      ReqLLM.Context.system(@system_text),
      ReqLLM.Context.user(@objective)
    ])
  end

  defp loop_state(agent_id, context, repo, opts) do
    %LoopState{
      agent_id: agent_id,
      agent_module: __MODULE__,
      depth: Keyword.get(opts, :depth, 0),
      parent_id: Keyword.get(opts, :parent_id),
      node_path: "./",
      repo_path: repo,
      context: context,
      objective: @objective
    }
  end

  # Runs the production LLM prompting step for one turn with the agent's
  # process-dictionary identity installed (`current_model/0` reads it).
  defp prompt_once(agent_id, context) do
    Process.put(:evogit_agent_id, agent_id)
    ToolDispatch.prompt_until_tools_or_limit(context, [], [], agent_id, 1)
  end

  # Fun pairs whose INVOCATION is the assertion: the implicit-completion route
  # must neither re-enter the loop nor trigger the recovery path.
  defp never_called_funs do
    test = self()

    loop_fn = fn _state ->
      send(test, :loop_fn_called)
      :loop_continued
    end

    recovery_fn = fn _state, _reason ->
      send(test, :recovery_triggered)
      :recovery_triggered
    end

    {loop_fn, recovery_fn}
  end

  # Registers the agent's live state (the LLM slot pool + `current_model/0` both
  # read it) with a per-test unique id, and installs the process-dictionary
  # identity the Runner would have set for it (`:repo_path` is the agent's
  # worktree, which is what the completion path commits in). Cleaned up on exit.
  defp register_agent(agent_id, model, repo, opts) do
    {:ok, head} = Git.rev_parse(repo)

    state = %AgentState{
      context_node: %ContextNode{path: "./", repo: repo},
      phylo_node: %PhyloGraphNode{repo: repo, base_commit: head, current_commit: head},
      llm_model: model,
      max_retries: 1,
      max_depth: 3,
      max_turns: 20,
      model_id: @model_id,
      parent_id: Keyword.get(opts, :parent_id),
      objective: @objective,
      repo_root: repo
    }

    :ok = SchedStore.put_agent_state(agent_id, state)
    on_exit(fn -> SchedStore.delete_agent_state(agent_id) end)

    Process.put(:evogit_agent_id, agent_id)
    Process.put(:evogit_agent_depth, Keyword.get(opts, :depth, 0))
    Process.put(:repo_path, repo)
    Process.put(:genesis_repo_root, repo)
    agent_id
  end

  # The agent's LIVE context as text, read back from the app-global ETS table
  # (`process_llm_response/6` syncs it there) — used to prove the dirty-workspace
  # / refusal tool-result family never entered the conversation.
  defp context_text(agent_id) do
    {:ok, agent_state} = SchedStore.get_agent_state(agent_id)

    agent_state.context
    |> ReqLLM.Context.to_list()
    |> Enum.map_join("\n", &context_text_of/1)
  end

  defp context_text_of(%ReqLLM.Message{content: content}) when is_list(content) do
    content
    |> Enum.filter(&(&1.type == :text))
    |> Enum.map_join("", & &1.text)
  end

  defp context_text_of(other), do: inspect(other)

  # Number of non-overlapping occurrences of `needle` in `haystack`.
  defp occurrences(haystack, needle) when is_binary(haystack) and is_binary(needle) do
    haystack |> String.split(needle) |> length() |> Kernel.-(1)
  end

  # Fresh temp git repo with one committed README.md and a deterministic
  # repo-local commit identity, so `Git.commit/2` works without user git config.
  defp new_repo! do
    repo =
      Path.join(
        System.tmp_dir!(),
        "evogit-implicit-completion-#{System.unique_integer([:positive])}"
      )

    File.mkdir_p!(repo)
    {:ok, _} = Git.init(repo)
    {:ok, _} = Git.run(["config", "user.email", "test@example.com"], repo)
    {:ok, _} = Git.run(["config", "user.name", "Test User"], repo)
    File.write!(Path.join(repo, "README.md"), "hello\n")
    {:ok, _} = Git.add(repo, "README.md")
    {:ok, _} = Git.commit(repo, "Initial commit")
    repo
  end
end
