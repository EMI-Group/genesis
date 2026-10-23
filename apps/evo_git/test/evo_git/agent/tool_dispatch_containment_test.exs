defmodule EvoGit.Agent.ToolDispatchContainmentTest do
  @moduledoc """
  Pins the CONTAINMENT guarantees of the tool-dispatch boundary
  (`EvoGit.Agent.ToolDispatch`) plus the platform-shell timeout default.

  ## Tolerant tool-argument plumbing

  Every call in a batch goes through `EvoGit.Agent.ToolInvocation.arguments/1`,
  so a model that emits broken arguments is corrected instead of crashing the
  agent. The three outcomes are pinned end-to-end, through the REAL dispatch
  plumbing (`process_tool_calls/3` / `process_regular_tool_calls/3`):

    * nothing recoverable (empty/blank argument payload) → the normal tool
      result `Error: invalid arguments: <reason>`;
    * a non-blank but unparseable argument payload → handed to the tool layer
      RAW, which answers with its own self-correcting
      `Error: tool arguments were received as a JSON-encoded string …` result;
    * a payload that DOES decode → the tool runs and receives the decoded map.

  All three are SOFT failures: the batch still produces exactly one tool-result
  message per call (`%ReqLLM.Message{role: :tool}` with the matching
  `tool_call_id`) and the agent's NEXT TURN still runs (asserted by driving
  `process_llm_response/6` and requiring its `loop_fn` to be invoked).

  ## Tool-raise / throw / exit containment

  `execute_tool_task/7` runs inside a `Task.async` LINKED to the agent process,
  so an uncontained failure would kill the whole agent. Pinned here:

    * a RAISING tool → `Error: Tool execution crashed: <exception banner>`;
    * a THROWN value → `Error: Tool execution crashed: throw <value>`;
    * containment is PER CALL — a sibling call in the SAME batch still runs;
    * the legitimate task-exit family (`:normal`, `:shutdown`, `:kill`,
      `{:shutdown, reason}`) is re-raised by the `catch` clause and is therefore
      never converted into a crash result: `:normal` (not an abnormal signal)
      leaves the caller alive and is reported by the dispatcher's
      `{:exit, reason}` arm, while every other reason propagates out of the
      dispatch caller with exactly that reason. Each case is driven in its own
      `spawn_monitor`ed process, so a propagated exit is observed as data
      (`{:died, reason}`) instead of killing the test process.

  ## Shell timeout default

  An OMITTED `timeout` on the platform shell tool resolves to the generous
  120 s default instead of the generic configured
  `[:scheduler, :default_tool_timeout]`; an explicit positive integer is used
  as-is (still clamped by `[:scheduler, :max_tool_timeout]`); an invalid
  `timeout` (`"9000"` string, negative, `0`) is treated as absent.

  ## Seams

    * **Fake tools** — the test-only registry app env `:evo_git,
      :tool_dispatch_test_tools` (`tool_name => fun.(args, repo_path,
      repo_root, node_path)`, consulted by `EvoGit.Agent.Tools.execute/5` after
      the write guards, return value passed through verbatim). That is exactly
      what lets a "tool" raise / throw / exit / sleep here. The registry is
      keyed by the NORMALISED internal tool name (`read_file`,
      `EvoGit.Agent.ToolNames.shell_tool_name/0`).
    * **Configured generic timeout** — no app-env seam exists, so it is reached
      through an isolated `XDG_CONFIG_HOME` holding a `config.toml` with a tiny
      `[scheduler] default_tool_timeout` (the same seam `task_tmpdir_test` uses
      for `[tmp]`). Shrinking it makes the shell-vs-generic discrimination
      observable in ~120 ms instead of a 10 s wait; the helper ASSERTS that the
      value actually resolved, so the seam cannot silently no-op.

  Serialized (`async: false`): the dispatcher registers agent state in the
  app-global `:evogit_agent_state` ETS table, acquires tool slots from the
  global `EvoGit.AgentScheduler`, mutates the global fake-tool app env and the
  process-wide `XDG_CONFIG_HOME` — exactly like the sibling
  `tool_dispatch_test.exs` / `tool_output_integration_test.exs` suites.
  """

  use ExUnit.Case, async: false

  alias EvoGit.Adapters.Git
  alias EvoGit.Agent.LoopState
  alias EvoGit.Agent.ToolDispatch
  alias EvoGit.Agent.ToolNames

  alias ReqLLM.Message
  alias ReqLLM.Message.ContentPart
  alias ReqLLM.ToolCall

  # Generic (non-shell) tool timeout the timeout describe installs. Small enough
  # that a ~120 ms fake tool is always cut by it, large enough that scheduling
  # jitter cannot let the tool win the race.
  @tiny_generic_timeout 50

  # How long the fake tools in the timeout describe sleep: comfortably above
  # `@tiny_generic_timeout` (so that default always fires) and incomparably
  # below the 120 s shell default (so a shell call always completes first).
  @slow_tool_ms 120

  # The explicit `timeout` used by the "explicit argument wins" case — distinct
  # from both the generic default (50) and the shell default (120_000), and
  # below `@slow_tool_ms` so the call times out instead of completing.
  @explicit_timeout 100

  # The dispatch-level read tool (parallel phase, no write guard).
  @read_tool "read_file"

  # The platform shell tool's INTERNAL dispatch key — the key the fake-tool
  # registry is consulted with after name normalisation.
  @shell_tool_key ToolNames.shell_tool_name()

  # The model-facing name a real LLM emits for the platform shell tool. The
  # timeout rule resolves it from this RAW name, while the fake-tool registry is
  # looked up by the NORMALISED key (`@shell_tool_key`).
  @shell_call_name "bash"

  # The exact tool-result string for a timed-out call (the resolved budget is
  # part of the message, which is what makes the timeout observable at all).
  defp timeout_message(ms) do
    "Error: Tool execution timed out after #{ms}ms. " <>
      "Some output may have been partially captured by the tool."
  end

  setup do
    repo = new_repo!()
    {:ok, head} = Git.rev_parse(repo)
    agent_id = 9_970_000 + :erlang.unique_integer([:positive])

    agent_state = %EvoGit.AgentScheduler.AgentState{
      context_node: %EvoGit.Core.ContextNode{path: "./", repo: repo},
      phylo_node: %EvoGit.Core.PhyloGraphNode{
        repo: repo,
        base_commit: head,
        current_commit: head
      },
      llm_model: "test:model",
      max_retries: 1,
      max_depth: 1
    }

    :ok = EvoGit.AgentScheduler.Store.put_agent_state(agent_id, agent_state)

    Process.put(:evogit_agent_id, agent_id)
    Process.put(:repo_path, repo)
    Process.put(:genesis_repo_root, repo)

    on_exit(fn ->
      # A dispatch driven in a process that died mid-call (the exit-family
      # cases) cannot run `with_tool_slot/2`'s `after` block, and the slot pool
      # is global — release it explicitly. Idempotent: deleting an agent id that
      # holds no slot is a no-op.
      EvoGit.AgentScheduler.release_tool_slot(agent_id)
      EvoGit.AgentScheduler.Store.delete_agent_state(agent_id)
      File.rm_rf!(repo)
    end)

    %{repo: repo}
  end

  # ---------------------------------------------------------------------------
  # 1. Tolerant tool-argument plumbing (soft failure, never a crash)
  # ---------------------------------------------------------------------------

  describe "tolerant tool-argument parse at the dispatch boundary" do
    test "an EMPTY arguments payload soft-fails as Error: invalid arguments: …" do
      install_fake_tools(%{@read_tool => echo_tool("read ok")})

      empty = raw_tool_call(@read_tool, "")
      good = tool_call(@read_tool, %{"file_path" => "./a.txt"})

      assert {:continue, messages, _usage} =
               ToolDispatch.process_tool_calls([empty, good], loop_state(), [])

      # One tool-result message per call, in request order — the pairing with
      # the calls survives a malformed sibling.
      assert [first, second] = messages
      assert %Message{} = first
      assert {first.role, first.tool_call_id, first.name} == {:tool, empty.id, @read_tool}
      assert message_text(first) == "Error: invalid arguments: the tool call carried no arguments"

      assert {second.role, second.tool_call_id, second.name} == {:tool, good.id, @read_tool}
      assert message_text(second) == "read ok"

      # The dispatch CALL returned instead of crashing the caller.
      assert Process.alive?(self())
    end

    test "undecodable arguments are handed to the tool layer RAW, not raised on" do
      # The fake fun would prove it ran by sending a message; it must NOT run for
      # the two undecodable payloads (the tool layer rejects the raw string
      # before the registry is consulted, and that rejection happens in the
      # DISPATCH-LINKED tool task, so the fun must report to the test process).
      parent = self()

      install_fake_tools(%{
        @read_tool => fn args, _repo, _root, _node ->
          send(parent, {:tool_ran, args})
          "read ok"
        end
      })

      garbage = raw_tool_call(@read_tool, "this is not json{{")
      truncated = raw_tool_call(@read_tool, ~s({"file_path":))
      good = tool_call(@read_tool, %{"file_path" => "./a.txt"})

      assert {:continue, messages, _usage} =
               ToolDispatch.process_tool_calls([garbage, truncated, good], loop_state(), [])

      assert [g1, g2, ok] = messages

      for {message, call} <- [{g1, garbage}, {g2, truncated}] do
        assert {message.role, message.tool_call_id} == {:tool, call.id}
        text = message_text(message)

        # The tool layer's own self-correcting message — the raw argument string
        # reaches it (stage 2), NOT the dispatcher's invalid-arguments stage.
        assert text =~ "Error: tool arguments were received as a JSON-encoded string"
        refute text =~ "Error: invalid arguments:"
      end

      assert ok.tool_call_id == good.id
      assert message_text(ok) == "read ok"
      assert_receive {:tool_ran, %{"file_path" => "./a.txt"}}
      refute_receive {:tool_ran, _other}
    end

    test "arguments that DO decode run the tool with the decoded map" do
      test_pid = self()
      install_fake_tools(%{@read_tool => echo_args_tool(test_pid)})

      # A plain JSON object — the normal provider shape.
      normal = tool_call(@read_tool, %{"file_path" => "./out.txt"})

      # A DECORATED object (fenced in a markdown code fence). Plain JSON decoding
      # rejects it, but ReqLLM's decode-repair pass (code-fence stripping) rescues
      # it into a real map, so the tool still runs with decoded arguments rather
      # than landing in the raw-string path. Empirically verified against
      # `ReqLLM.ToolCall.args_map/1`.
      decorated =
        raw_tool_call(@read_tool, "```json\n{\"file_path\": \"./out.txt\"}\n```")

      assert {:continue, messages, _usage} =
               ToolDispatch.process_tool_calls([normal, decorated], loop_state(), [])

      assert [m1, m2] = messages
      assert message_text(m1) == "args: %{\"file_path\" => \"./out.txt\"}"
      assert message_text(m2) == "args: %{\"file_path\" => \"./out.txt\"}"

      assert_receive {:tool_args, %{"file_path" => "./out.txt"}}
      assert_receive {:tool_args, %{"file_path" => "./out.txt"}}
    end

    test "an escaped JSON value INSIDE the argument object still decodes to a map" do
      parent = self()
      install_fake_tools(%{@read_tool => echo_args_tool(parent)})

      # A JSON OBJECT whose value is itself an escaped JSON string — the
      # "double-encoded value" shape a model sometimes emits. The payload as a
      # whole is a decodable object, so the tool runs with the decoded map and
      # receives the escaped value VERBATIM: a nested escape must never make the
      # whole payload look undecodable. (`~S` keeps the backslashes literal, so
      # this is exactly the bytes a provider would put in `arguments`.)
      nested =
        raw_tool_call(
          @read_tool,
          ~S|{"file_path": "./out.txt", "content": "{\"x\": 1}"}|
        )

      assert {:continue, [message], _usage} =
               ToolDispatch.process_tool_calls([nested], loop_state(), [])

      assert message.tool_call_id == nested.id
      assert_receive {:tool_args, %{"file_path" => "./out.txt", "content" => "{\"x\": 1}"}}
      refute message_text(message) =~ "Error:"
      assert message_text(message) =~ "./out.txt"
    end

    test "a fully double-encoded payload decodes to a bare STRING, so it takes the raw path" do
      # A truly double-encoded argument payload (`arguments` = a JSON string
      # whose CONTENT is the JSON object) decodes to a `String.t()`, not a map —
      # verified against `ReqLLM.ToolCall.args_map/1`. By design that is stage 2
      # (raw string to the tool layer), not stage 1/3: it must degrade to the
      # tool layer's error, never crash and never be treated as `%{}`.
      parent = self()
      install_fake_tools(%{@read_tool => echo_args_tool(parent)})

      double_encoded = raw_tool_call(@read_tool, Jason.encode!(~s({"file_path": "./out.txt"})))
      assert ReqLLM.ToolCall.args_map(double_encoded) == ~s({"file_path": "./out.txt"})

      assert {:continue, [message], _usage} =
               ToolDispatch.process_tool_calls([double_encoded], loop_state(), [])

      assert message.tool_call_id == double_encoded.id

      assert message_text(message) =~
               "Error: tool arguments were received as a JSON-encoded string"

      refute_receive {:tool_args, _anything}
    end

    test "the agent loop CONTINUES to the next turn after a malformed-arguments call" do
      install_fake_tools(%{@read_tool => echo_tool("read ok")})
      parent = self()

      response = assistant_response([raw_tool_call(@read_tool, "")])

      loop_fn = fn state ->
        send(parent, {:next_turn, state})
        :loop_reentered
      end

      assert :loop_reentered ==
               ToolDispatch.process_llm_response(
                 response,
                 loop_state(),
                 [],
                 loop_fn,
                 fn _state -> flunk("recovery must not run for a soft tool failure") end
               )

      assert_receive {:next_turn, %LoopState{} = state}

      assert [tool_message] = Enum.filter(state.context.messages, &(&1.role == :tool))

      assert message_text(tool_message) ==
               "Error: invalid arguments: the tool call carried no arguments"
    end
  end

  # ---------------------------------------------------------------------------
  # 2. Tool-raise / throw / exit containment
  # ---------------------------------------------------------------------------

  describe "tool-raise containment" do
    test "a RAISING tool becomes Error: Tool execution crashed: <banner> and the loop continues" do
      install_fake_tools(%{@read_tool => fn _args, _repo, _root, _node -> raise "boom" end})
      parent = self()

      response = assistant_response([tool_call(@read_tool, %{"file_path" => "./a.txt"})])

      loop_fn = fn state ->
        send(parent, {:next_turn, state})
        :loop_reentered
      end

      assert :loop_reentered ==
               ToolDispatch.process_llm_response(
                 response,
                 loop_state(),
                 [],
                 loop_fn,
                 fn _state -> flunk("recovery must not run for a contained tool raise") end
               )

      assert_receive {:next_turn, %LoopState{} = state}
      assert [tool_message] = Enum.filter(state.context.messages, &(&1.role == :tool))

      # Exactly the exception banner (`Exception.format_banner/2`), not an
      # `inspect/1`-rendered exit reason.
      banner = Exception.format_banner(:error, %RuntimeError{message: "boom"})
      assert message_text(tool_message) == "Error: Tool execution crashed: " <> banner
      assert message_text(tool_message) =~ "boom"
    end

    test "containment is PER CALL — a sibling call in the same batch still executes" do
      install_fake_tools(%{
        @read_tool => fn _args, _repo, _root, _node -> raise "boom" end,
        "rg" => echo_tool("rg ok")
      })

      crashing = tool_call(@read_tool, %{"file_path" => "./a.txt"})
      surviving = tool_call("rg", %{"pattern" => "foo"})

      assert {:continue, messages, _usage} =
               ToolDispatch.process_tool_calls([crashing, surviving], loop_state(), [])

      assert [crashed_message, ok_message] = messages
      assert crashed_message.tool_call_id == crashing.id
      assert message_text(crashed_message) =~ "Error: Tool execution crashed:"
      assert ok_message.tool_call_id == surviving.id
      assert message_text(ok_message) == "rg ok"
    end

    test "a THROWN value becomes a crashed result instead of a raise" do
      install_fake_tools(%{@read_tool => fn _args, _repo, _root, _node -> throw(:boom) end})

      assert {:continue, [message], _usage} =
               ToolDispatch.process_tool_calls(
                 [tool_call(@read_tool, %{"file_path" => "./a.txt"})],
                 loop_state(),
                 []
               )

      assert message_text(message) == "Error: Tool execution crashed: throw :boom"
    end
  end

  describe "tool exit-family propagation (the rescue path must not swallow it)" do
    # The exit family the `catch` clause re-raises unchanged: `:normal`,
    # `:shutdown`, `:kill` and `{:shutdown, reason}`. Re-raising means the rescue
    # path can never turn it into a crash result — the tool task really exits.
    #
    # What the dispatch caller then observes is pinned here, case by case and
    # END-TO-END through the real batch plumbing:
    #
    #   * `:normal` is NOT an abnormal signal, so the linked tool task's death
    #     leaves the dispatch caller alive and the dispatcher's
    #     `{:exit, reason}` arm renders the reason with `inspect/1` — no
    #     exception banner, i.e. demonstrably NOT the rescue path;
    #   * every OTHER reason propagates out of the dispatch caller with exactly
    #     that reason (the batch's `{:exit, reason} -> exit(reason)` arm re-raises
    #     it in the caller), so it is never converted into a tool-result string.
    #
    # Each case runs in a separate `spawn_monitor`ed process, so a propagated
    # exit surfaces as `{:died, reason}` instead of failing the test process.
    @exit_cases [
      {:normal, {:survived, "Error: Tool execution crashed: :normal"}},
      {:shutdown, {:died, :shutdown}},
      {:kill, {:died, :kill}},
      {{:shutdown, :byebye}, {:died, {:shutdown, :byebye}}}
    ]

    test "an exit reason is never contained — :normal reports, the rest propagate" do
      for {reason, expected} <- @exit_cases do
        install_fake_tools(%{@read_tool => exit_tool(reason)})

        observed =
          case dispatch_in_linked_process([
                 tool_call(@read_tool, %{"file_path" => "./a.txt"})
               ]) do
            {:survived, [text]} ->
              # The rescue path would have produced `Exception.format_banner/2`
              # (`** (ErlangError) Erlang error: …`); an exit reason renders bare.
              refute text =~ "** ("
              refute text =~ "ErlangError"
              {:survived, text}

            {:died, propagated} ->
              {:died, propagated}
          end

        assert observed == expected,
               "exit(#{inspect(reason)}) must not be swallowed by the crash containment"
      end

      assert Process.alive?(self())
    end
  end

  # ---------------------------------------------------------------------------
  # 3. Shell timeout default (end-to-end, no multi-second waits)
  # ---------------------------------------------------------------------------

  describe "platform-shell timeout default" do
    setup do
      # The generic (non-shell) default has no app-env seam; a tiny value in an
      # isolated config.toml makes the shell-vs-generic discrimination
      # observable in ~120 ms. The helper asserts the value really resolved.
      isolate_generic_tool_timeout!(@tiny_generic_timeout)
      :ok
    end

    test "an OMITTED timeout on the shell tool is NOT cut at the generic default" do
      install_fake_tools(%{@shell_tool_key => slow_tool(@slow_tool_ms, "bash finished")})

      call = tool_call(@shell_call_name, %{"command" => "echo hi"})

      assert {:continue, [message], _usage} =
               ToolDispatch.process_tool_calls([call], loop_state(), [])

      # `@slow_tool_ms` far exceeds the configured generic default but is
      # incomparably below the shell default, so a completed call proves the
      # shell fallback (120 s) was used.
      assert message_text(message) == "bash finished"
    end

    test "an OMITTED timeout on a non-shell tool IS cut at the configured generic default" do
      install_fake_tools(%{@read_tool => slow_tool(@slow_tool_ms, "read finished")})

      call = tool_call(@read_tool, %{"file_path" => "./a.txt"})

      assert {:continue, [message], _usage} =
               ToolDispatch.process_tool_calls([call], loop_state(), [])

      assert message_text(message) == timeout_message(@tiny_generic_timeout)
    end

    test "an explicit timeout argument is used as-is instead of the shell default" do
      install_fake_tools(%{@shell_tool_key => slow_tool(@slow_tool_ms, "bash finished")})

      call =
        tool_call(@shell_call_name, %{"command" => "echo hi", "timeout" => @explicit_timeout})

      assert {:continue, [message], _usage} =
               ToolDispatch.process_tool_calls([call], loop_state(), [])

      assert message_text(message) == timeout_message(@explicit_timeout)
    end

    test "an invalid timeout argument is treated as absent" do
      install_fake_tools(%{@read_tool => slow_tool(@slow_tool_ms, "read finished")})

      for invalid <- [-1, 0, "9000"] do
        call = tool_call(@read_tool, %{"file_path" => "./a.txt", "timeout" => invalid})

        assert {:continue, [message], _usage} =
                 ToolDispatch.process_tool_calls([call], loop_state(), [])

        # Honouring `-1`/`0` would yield "after -1ms"/"after 0ms"; honouring the
        # `"9000"` string would yield "after 9000ms". Absent means the generic
        # configured default.
        assert message_text(message) == timeout_message(@tiny_generic_timeout),
               "a #{inspect(invalid)} timeout argument must be treated as absent"
      end
    end
  end

  # --- Dispatch helpers ---

  # Drives the REAL dispatch entry point for one batch of LLM tool calls and
  # returns `{:continue, messages, usage}`.
  defp run_batch(calls) do
    {:continue, messages, _usage} = ToolDispatch.process_tool_calls(calls, loop_state(), [])
    Enum.map(messages, &message_text/1)
  end

  defp loop_state do
    %LoopState{
      agent_id: Process.get(:evogit_agent_id),
      agent_module: EvoGit.Agents.Executor,
      depth: 0,
      node_path: "./",
      context: ReqLLM.Context.new()
    }
  end

  # Runs one dispatch batch in a SEPARATE process (like a real agent process) and
  # reports how that process ended: `{:survived, texts}` when the dispatch
  # returned, `{:died, reason}` when an exit reason propagated out of it.
  # Keeping it off the test process means a propagated exit fails the ASSERTION,
  # not the test.
  defp dispatch_in_linked_process(calls) do
    parent = self()
    agent_id = Process.get(:evogit_agent_id)
    repo = Process.get(:repo_path)

    {pid, ref} =
      spawn_monitor(fn ->
        Process.put(:evogit_agent_id, agent_id)
        Process.put(:repo_path, repo)
        Process.put(:genesis_repo_root, repo)
        send(parent, {:dispatch_result, self(), run_batch(calls)})

        receive do
          :stop -> :ok
        end
      end)

    receive do
      {:dispatch_result, ^pid, texts} ->
        send(pid, :stop)

        receive do
          {:DOWN, ^ref, :process, ^pid, _reason} -> {:survived, texts}
        after
          5_000 -> {:survived_without_down, texts}
        end

      {:DOWN, ^ref, :process, ^pid, reason} ->
        {:died, reason}
    after
      30_000 -> flunk("the dispatch helper process neither returned nor exited")
    end
  end

  # An assistant response carrying the given tool calls, with a context that
  # already holds the assistant message (the shape `process_llm_response/6`
  # expects from a streamed turn).
  defp assistant_response(calls) do
    message = %Message{
      role: :assistant,
      content: [ContentPart.text("calling tools")],
      tool_calls: calls
    }

    %ReqLLM.Response{
      id: "test-response",
      model: "test:model",
      context: ReqLLM.Context.new([message]),
      message: message,
      usage: %{input_tokens: 11, output_tokens: 3}
    }
  end

  defp message_text(%Message{content: content}) do
    content
    |> Enum.filter(&(&1.type == :text))
    |> Enum.map_join("", & &1.text)
  end

  # --- Tool-call helpers ---

  # A call whose arguments are the exact JSON string a provider would emit.
  defp tool_call(name, args) when is_map(args) do
    raw_tool_call(name, Jason.encode!(args))
  end

  # A call carrying a RAW argument payload (used to inject malformed / exotic
  # encodings verbatim).
  defp raw_tool_call(name, raw_arguments) do
    ToolCall.new("call_#{name}_#{:erlang.unique_integer([:positive])}", name, raw_arguments)
  end

  # --- Fake-tool helpers ---

  # Installs the test-only fake-tool registry (app env) for the duration of the
  # test and restores the previous value afterwards.
  defp install_fake_tools(tools) when is_map(tools) do
    previous = Application.get_env(:evo_git, :tool_dispatch_test_tools)
    Application.put_env(:evo_git, :tool_dispatch_test_tools, tools)

    on_exit(fn ->
      case previous do
        nil -> Application.delete_env(:evo_git, :tool_dispatch_test_tools)
        _ -> Application.put_env(:evo_git, :tool_dispatch_test_tools, previous)
      end
    end)
  end

  defp echo_tool(text), do: fn _args, _repo, _root, _node -> text end

  defp echo_args_tool(pid) do
    fn args, _repo, _root, _node ->
      send(pid, {:tool_args, args})
      "args: #{inspect(args)}"
    end
  end

  defp slow_tool(sleep_ms, result) do
    fn _args, _repo, _root, _node ->
      Process.sleep(sleep_ms)
      result
    end
  end

  defp exit_tool(reason), do: fn _args, _repo, _root, _node -> exit(reason) end

  # --- Config / repo fixtures ---

  # Points `XDG_CONFIG_HOME` at a temp dir holding a `config.toml` with a tiny
  # `[:scheduler, :default_tool_timeout]` (there is NO app-env seam for it) and
  # asserts the value really resolved — otherwise the whole timeout describe
  # would assert against the production 10 s default and mean nothing.
  defp isolate_generic_tool_timeout!(timeout_ms) do
    original_xdg = System.get_env("XDG_CONFIG_HOME")

    tmp_xdg =
      Path.join(System.tmp_dir!(), "evogit_tool_timeout_#{:erlang.unique_integer([:positive])}")

    File.mkdir_p!(tmp_xdg)
    System.put_env("XDG_CONFIG_HOME", tmp_xdg)
    # config.toml lives at <xdg>/genesis/config.toml — create the parent dir
    # since this writes raw TOML (no `save_user_config/1` mkdir).
    File.mkdir_p!(EvoGit.Config.config_dir())

    File.write!(EvoGit.Config.config_path(), """
    [scheduler]
    default_tool_timeout = #{timeout_ms}
    """)

    on_exit(fn ->
      if original_xdg do
        System.put_env("XDG_CONFIG_HOME", original_xdg)
      else
        System.delete_env("XDG_CONFIG_HOME")
      end

      File.rm_rf!(tmp_xdg)
    end)

    assert EvoGit.Config.resolve([:scheduler, :default_tool_timeout]) == timeout_ms
  end

  defp new_repo! do
    repo =
      Path.join(
        System.tmp_dir!(),
        "tool_dispatch_containment_#{System.unique_integer([:positive])}"
      )

    File.mkdir_p!(repo)
    on_exit(fn -> File.rm_rf!(repo) end)
    {:ok, _} = Git.init(repo)
    {:ok, _} = Git.run(["config", "user.email", "test@example.com"], repo)
    {:ok, _} = Git.run(["config", "user.name", "Test User"], repo)
    File.write!(Path.join(repo, "README.md"), "hello\n")
    {:ok, _} = Git.add(repo, "README.md")
    {:ok, _} = Git.commit(repo, "Initial commit")
    repo
  end
end
