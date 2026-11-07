defmodule EvoGit.Agent.ProviderModelInheritanceTest.SSE do
  @moduledoc false
  import ExUnit.Callbacks, only: [on_exit: 1]

  # Unlike the shared error-response server, this fixture completes real streams
  # and records BOTH headers and body, tagged by the endpoint that received them.
  def start!(account) do
    {:ok, listener} =
      :gen_tcp.listen(0, [:binary, active: false, reuseaddr: true, ip: {127, 0, 0, 1}])

    {:ok, port} = :inet.port(listener)
    owner = self()
    ref = make_ref()
    pid = spawn(fn -> accept(listener, owner, ref, account) end)

    on_exit(fn ->
      Process.exit(pid, :kill)
      :gen_tcp.close(listener)
    end)

    %{url: "http://127.0.0.1:#{port}/v1", ref: ref}
  end

  defp accept(listener, owner, ref, account) do
    case :gen_tcp.accept(listener) do
      {:ok, socket} ->
        {head, rest} = headers(socket, "")
        [request_line | lines] = String.split(head, "\r\n")

        headers =
          Map.new(lines, fn line ->
            [name, value] = String.split(line, ":", parts: 2)
            {String.downcase(name), String.trim(value)}
          end)

        size = String.to_integer(Map.fetch!(headers, "content-length"))
        body = body(socket, rest, size)
        send(owner, {ref, account, request_line, headers, Jason.decode!(body)})
        payload = payload()

        :ok =
          :gen_tcp.send(socket, [
            "HTTP/1.1 200 OK\r\ncontent-type: text/event-stream\r\n",
            "connection: close\r\ncontent-length: #{byte_size(payload)}\r\n\r\n",
            payload
          ])

        :gen_tcp.close(socket)
        accept(listener, owner, ref, account)

      {:error, :closed} ->
        :ok
    end
  end

  defp headers(socket, bytes) do
    case String.split(bytes, "\r\n\r\n", parts: 2) do
      [head, rest] ->
        {head, rest}

      [_] ->
        {:ok, more} = :gen_tcp.recv(socket, 0, 10_000)
        headers(socket, bytes <> more)
    end
  end

  defp body(_socket, bytes, size) when byte_size(bytes) >= size,
    do: binary_part(bytes, 0, size)

  defp body(socket, bytes, size) do
    {:ok, more} = :gen_tcp.recv(socket, 0, 10_000)
    body(socket, bytes <> more, size)
  end

  defp payload do
    events = [
      %{
        choices: [
          %{
            index: 0,
            delta: %{role: "assistant", content: "Selected account reply"},
            finish_reason: nil
          }
        ]
      },
      %{
        choices: [%{index: 0, delta: %{}, finish_reason: "stop"}],
        usage: %{prompt_tokens: 11, completion_tokens: 7, total_tokens: 18}
      }
    ]

    Enum.map_join(events, "", fn event ->
      event =
        Map.merge(
          %{id: "selection-stream", object: "chat.completion.chunk", created: 1, model: "wide"},
          event
        )

      "data: " <> Jason.encode!(event) <> "\n\n"
    end) <> "data: [DONE]\n\n"
  end
end

defmodule EvoGit.Agent.ProviderModelInheritanceTest do
  @moduledoc """
  Canonical provider/account + model + effort selections travel through the real
  SubagentProcessing builder and Dispatch registration, never masquerading as a
  ReqLLM request model. Successful local streams pin account endpoint, auth and
  effective nested generation settings for a child, grandchild and compression.

  async: false: pins the GLOBAL AgentScheduler account snapshot/slot pools,
  suspends PeakHourEngine and replaces :llm_model_metadata_fun; named credential
  environment variables are also process-wide. Restore configuration before
  resuming the engine. ConfigDir is process-isolated; only uniquely keyed,
  production-shaped AgentState/SchedMeta rows are inserted and deleted.
  Request assertions inspect individual fields, not credential-bearing params.
  """
  use ExUnit.Case, async: false

  alias EvoGit.Agent.{
    ContextBuilder,
    ContextCompression,
    LoopState,
    SubagentProcessing,
    ToolDispatch
  }

  alias EvoGit.AgentScheduler
  alias EvoGit.AgentScheduler.{Dispatch, ModelSelection, State}
  alias EvoGit.AgentScheduler.Store, as: SchedulerStore
  alias EvoGit.AgentSpec
  alias EvoGit.Config.Schema
  alias EvoGit.Core.{ContextNode, PhyloGraphNode}
  alias __MODULE__.SSE

  @moduletag :tmp_dir
  @work_key "GENESIS_INHERITANCE_WORK_TEST_KEY"
  @backup_key "GENESIS_INHERITANCE_BACKUP_TEST_KEY"

  setup %{tmp_dir: dir} do
    EvoGit.TestSupport.ConfigDir.isolate!("provider-model-inheritance")
    File.mkdir_p!(EvoGit.Config.config_dir())
    engine = Process.whereis(EvoGit.PeakHourEngine)
    if engine, do: :sys.suspend(engine)
    original = :sys.get_state(AgentScheduler)
    metadata = Application.fetch_env(:evo_git, :llm_model_metadata_fun)
    work_key = System.get_env(@work_key)
    backup_key = System.get_env(@backup_key)

    on_exit(fn ->
      :ok =
        AgentScheduler.update_config(
          model_profiles: original.model_profiles,
          provider_profiles: original.provider_profiles,
          model_selection_config: original.model_selection_config,
          default_llm_max_concurrency: original.default_llm_max_concurrency
        )

      if original.paused, do: AgentScheduler.pause(), else: AgentScheduler.resume()
      restore_env(@work_key, work_key)
      restore_env(@backup_key, backup_key)

      case metadata do
        {:ok, value} -> Application.put_env(:evo_git, :llm_model_metadata_fun, value)
        :error -> Application.delete_env(:evo_git, :llm_model_metadata_fun)
      end

      if engine, do: :sys.resume(engine)
    end)

    Application.put_env(:evo_git, :llm_model_metadata_fun, fn _ ->
      %{limits: %{output: 8_192}, capabilities: %{reasoning: %{enabled: true}}}
    end)

    System.put_env(@work_key, "fixture-work-key")
    System.put_env(@backup_key, "fixture-backup-key")
    work = SSE.start!("work")
    backup = SSE.start!("backup")
    config = config(work.url, backup.url)
    :ok = AgentScheduler.update_config(ModelSelection.config_opts(config))
    :ok = AgentScheduler.resume()
    File.write!(Path.join(dir, "CONTEXT.md"), "# Selection fixture\n")
    Process.put(:repo_path, dir)
    %{repo: dir, config: config, snapshot: snapshot(config), work: work, backup: backup}
  end

  test "configured account/model defaults win over inventory order and stale legacy profiles",
       ctx do
    {id, _} = register!(ctx.snapshot, root_spec(ctx.repo))
    selected = agent!(id)
    assert selected.provider_profile_id == "work"
    assert selected.model_id == "work"
    assert selected.model_spec == wire("work", "small", "high")
    assert selected.llm_model == endpoint_model(ctx.work.url, "small")
    assert selected.llm_context_window == 131_072
    assert Keyword.fetch!(selected.llm_generation_params, :temperature) == 0.2
    assert Keyword.fetch!(selected.llm_generation_params, :api_key) == "fixture-work-key"

    {:ok, resolved} = Schema.resolve_model_spec(ctx.config, selected.model_spec)
    assert resolved.model_spec == selected.llm_model
    refute Map.has_key?(resolved.model_spec, "provider_profile_id")
    assert selected.model_spec["provider_profile_id"] == "work"
  end

  test "full unlocked canonical selection survives real child and grandchild building and registration",
       ctx do
    selection = wire("work", "wide", "high")
    {root, state} = register!(ctx.snapshot, root_spec(ctx.repo, model_spec: selection))
    child = child_spec(root, ctx.repo)
    assert_inherited(child, selection, false)
    {child_id, state} = register!(state, child, root, 1)
    assert_selected(child_id, selection, ctx.work.url)
    grandchild = child_spec(child_id, ctx.repo)
    assert_inherited(grandchild, selection, false)
    {grandchild_id, _} = register!(state, grandchild, child_id, 2)
    assert_selected(grandchild_id, selection, ctx.work.url)
    assert agent!(grandchild_id).parent_id == child_id
    assert grandchild.agent_module == EvoGit.Agents.Investigator
  end

  test "live effective selection takes precedence over the original root spec and opts", ctx do
    original = wire("backup", "small", "low")
    effective = wire("work", "wide", "high")
    {root, state} = register!(ctx.snapshot, root_spec(ctx.repo, model_spec: original))
    {:ok, resolved} = ModelSelection.resolve(state, effective)
    SchedulerStore.put_agent_state(root, struct!(agent!(root), resolved))
    assert meta!(root).spec.model_spec == original
    child = child_spec(root, ctx.repo)
    assert_inherited(child, effective, false)
    {id, _} = register!(state, child, root, 1)
    assert_selected(id, effective, ctx.work.url)
  end

  test "older state falls back to original spec before opts, including an opts-only lock", ctx do
    selection = wire("work", "wide", "high")
    {root, state} = register!(ctx.snapshot, root_spec(ctx.repo, model_spec: selection))
    parent = agent!(root)
    SchedulerStore.put_agent_state(root, %{parent | model_spec: nil, model_id_locked: false})
    meta = meta!(root)
    opts = [model_spec: wire("backup", "small", "low"), model_id_locked: true]
    SchedulerStore.put_sched_meta(root, %{meta | spec: %{meta.spec | opts: opts}})
    child = child_spec(root, ctx.repo)
    assert_inherited(child, selection, true)
    {id, _} = register!(state, child, root, 1)
    assert_selected(id, selection, ctx.work.url)
    assert agent!(id).model_id_locked
  end

  test "opts-only canonical selection is retained across the builder and scheduler", ctx do
    selection = wire("work", "wide", "low")
    spec = root_spec(ctx.repo, model_spec: selection, model_id_locked: true)
    {root, state} = register!(ctx.snapshot, %{spec | model_spec: nil})

    SchedulerStore.put_agent_state(root, %{agent!(root) | model_spec: nil, model_id_locked: false})

    child = child_spec(root, ctx.repo)
    assert_inherited(child, selection, true)
    {id, _} = register!(state, child, root, 1)
    assert_selected(id, selection, ctx.work.url)
  end

  test "recycled original metadata is not needed when the full live selection remains", ctx do
    selection = wire("work", "wide", "high")

    {root, state} =
      register!(ctx.snapshot, root_spec(ctx.repo, model_spec: selection, model_id_locked: true))

    loop = loop_state(root, ctx.repo)
    SchedulerStore.delete_sched_meta(root)
    child = child_spec(root, ctx.repo, loop)
    assert_inherited(child, selection, true)
    {id, _} = register!(state, child, root, 1)
    assert_selected(id, selection, ctx.work.url)
  end

  test "a locked parent overrides conflicting child selectors and a configured per-spawn script",
       ctx do
    selection = wire("work", "wide", "high")

    script!("""
    send(self(), {:locked_selection_script_invoked, agent.depth})
    %{provider_profile_id: "backup", model: "small", reasoning_effort: "low"}
    """)

    # Prove the configured script's marker is observable before checking that
    # locked registration bypasses it, rather than evaluating and discarding it.
    assert {:ok, %{provider_profile_id: "backup", model: "small", reasoning_effort: "low"}} =
             EvoGit.CustomAgents.ModelSelector.select_model(%{depth: 0})

    assert_received {:locked_selection_script_invoked, 0}

    {root, state} =
      register!(ctx.snapshot, root_spec(ctx.repo, model_spec: selection, model_id_locked: true))

    child = child_spec(root, ctx.repo)
    assert_inherited(child, selection, true)
    conflict = wire("backup", "small", "low")

    child = %{
      child
      | model_spec: conflict,
        model_id: "backup",
        opts: [model_spec: conflict, model_id_locked: false]
    }

    {id, state} = register!(state, child, root, 1)
    assert_selected(id, selection, ctx.work.url)
    assert agent!(id).model_id_locked
    grandchild = child_spec(id, ctx.repo)
    assert_inherited(grandchild, selection, true)
    {grandchild_id, _} = register!(state, grandchild, id, 2)
    assert_selected(grandchild_id, selection, ctx.work.url)
    assert agent!(grandchild_id).model_id_locked
    refute_received {:locked_selection_script_invoked, _}
  end

  test "an unlocked child is reselected by script and its grandchild retains the full fallback on nil",
       ctx do
    script!("""
    selection =
      case agent.depth do
        0 -> %{provider_profile_id: "work", model: "wide", reasoning_effort: "high"}
        1 -> %{provider_profile_id: "backup", model: "small", reasoning_effort: "low"}
        2 -> nil
      end

    send(self(), {:inheritance_script_result, agent.depth, selection})
    selection
    """)

    inherited = wire("work", "wide", "high")
    reselected = wire("backup", "small", "low")
    {root, state} = register!(ctx.snapshot, root_spec(ctx.repo))

    assert_received {:inheritance_script_result, 0,
                     %{provider_profile_id: "work", model: "wide", reasoning_effort: "high"}}

    assert_selected(root, inherited, ctx.work.url)
    child = child_spec(root, ctx.repo)
    assert_inherited(child, inherited, false)
    {id, state} = register!(state, child, root, 1)

    assert_received {:inheritance_script_result, 1,
                     %{provider_profile_id: "backup", model: "small", reasoning_effort: "low"}}

    # Inheritance is a fallback, not an explicit user choice: only a lock may
    # suppress the documented per-spawn script opportunity.
    assert_selected(id, reselected, ctx.backup.url)
    assert_selected(root, inherited, ctx.work.url)
    refute agent!(id).model_id_locked

    grandchild = child_spec(id, ctx.repo)
    assert_inherited(grandchild, reselected, false)
    {grandchild_id, _} = register!(state, grandchild, id, 2)
    assert_received {:inheritance_script_result, 2, nil}
    assert_selected(grandchild_id, reselected, ctx.backup.url)
    refute agent!(grandchild_id).model_id_locked
    assert_selected(id, reselected, ctx.backup.url)
    assert_selected(root, inherited, ctx.work.url)
  end

  test "an unlocked grandchild can be reselected without changing its parent's effective selection",
       ctx do
    inherited = wire("work", "wide", "high")
    {root, state} = register!(ctx.snapshot, root_spec(ctx.repo, model_spec: inherited))
    {child, state} = register!(state, child_spec(root, ctx.repo), root, 1)

    script!("""
    if agent.depth == 2, do: %{provider_profile_id: "backup", model: "small", reasoning_effort: "low"}, else: nil
    """)

    grandchild_spec = child_spec(child, ctx.repo)
    assert_inherited(grandchild_spec, inherited, false)
    {grandchild, _} = register!(state, grandchild_spec, child, 2)
    assert_selected(grandchild, wire("backup", "small", "low"), ctx.backup.url)
    assert_selected(child, inherited, ctx.work.url)
    assert_selected(root, inherited, ctx.work.url)
    refute agent!(grandchild).model_id_locked
  end

  test "legacy-only parent ids remain usable after real builder delegation", ctx do
    legacy = %State{
      model_profiles: [%{id: "legacy", model: "openai:legacy-model", temperature: 0.3}],
      next_agent_id: unique_id()
    }

    {root, state} = register!(legacy, root_spec(ctx.repo, model_id: "legacy"))
    assert agent!(root).model_spec == nil
    child = child_spec(root, ctx.repo)
    assert child.model_id == "legacy"
    assert child.model_spec == nil
    refute Keyword.has_key?(child.opts, :model_spec)
    refute Keyword.has_key?(child.opts, :default_model_spec)
    {id, _} = register!(state, child, root, 1)
    assert agent!(id).model_id == "legacy"
    assert agent!(id).llm_model == "openai:legacy-model"
    assert Keyword.fetch!(agent!(id).llm_generation_params, :temperature) == 0.3
  end

  test "explicit malformed or unavailable selectors never silently inherit a default or mutate ETS",
       ctx do
    for requested <- [
          nil,
          %{},
          wire("missing", "wide", "high"),
          wire("work", "missing", "high"),
          wire("work", "wide", "xhigh")
        ] do
      state = %{ctx.snapshot | next_agent_id: unique_id()}
      spec = root_spec(ctx.repo, model_spec: requested)
      assert {:error, _} = Dispatch.register_agent(state, spec, nil, nil, 0, nil, 1)
      assert SchedulerStore.get_agent_state(state.next_agent_id) == :error
      assert SchedulerStore.get_sched_meta(state.next_agent_id) == :error
    end
  end

  test "successful child and grandchild turns send the selected endpoint, credentials, model and effort",
       ctx do
    selected = wire("work", "wide", "high")

    {root, state} =
      register!(ctx.snapshot, root_spec(ctx.repo, model_spec: selected, model_id_locked: true))

    {child, state} = register!(state, child_spec(root, ctx.repo), root, 1)
    {grandchild, _} = register!(state, child_spec(child, ctx.repo), child, 2)

    for id <- [child, grandchild] do
      Process.put(:evogit_agent_id, id)
      Process.put(:repo_less, true)
      assert ToolDispatch.current_model() == endpoint_model(ctx.work.url, "wide")
      assert ToolDispatch.current_context_window() == 300_000
      assert Keyword.fetch!(ToolDispatch.current_generation_params(), :reasoning_effort) == :high
      never = fn _ -> flunk("a successful text reply must not retry or enter recovery") end

      assert {:ok, result} =
               ToolDispatch.do_turn(loop_state(id, ctx.repo), fn _ -> [] end, [], never, never)

      assert result.result == "Selected account reply"
      assert result.usage.input_tokens == 11
      assert result.usage.output_tokens == 7
      request = assert_request(ctx.work, "work", "fixture-work-key", "wide", "high", 0.6, 4_096)
      assert hd(request["messages"])["content"] == "SYSTEM"
    end

    backup_ref = ctx.backup.ref
    refute_received {^backup_ref, "backup", _, _, _}
  end

  test "a nondefault account serving the same model keeps its own endpoint and authentication",
       ctx do
    selection = wire("backup", "small", "low")
    {root, state} = register!(ctx.snapshot, root_spec(ctx.repo, model_spec: selection))
    {child, _} = register!(state, child_spec(root, ctx.repo), root, 1)
    Process.put(:evogit_agent_id, child)
    Process.put(:repo_less, true)
    assert_selected(child, selection, ctx.backup.url)
    assert ToolDispatch.current_context_window() == 64_000
    never = fn _ -> flunk("successful completion must not re-enter the loop") end

    assert {:ok, result} =
             ToolDispatch.do_turn(loop_state(child, ctx.repo), fn _ -> [] end, [], never, never)

    assert result.result == "Selected account reply"
    assert_request(ctx.backup, "backup", "fixture-backup-key", "small", "low", 0.8, 1_024, nil)
    work_ref = ctx.work.ref
    refute_received {^work_ref, "work", _, _, _}
  end

  test "a successful compression request uses the grandchild's same effective account snapshot",
       ctx do
    selected = wire("work", "wide", "high")

    {root, state} =
      register!(ctx.snapshot, root_spec(ctx.repo, model_spec: selected, model_id_locked: true))

    {child, state} = register!(state, child_spec(root, ctx.repo), root, 1)
    {grandchild, _} = register!(state, child_spec(child, ctx.repo), child, 2)
    Process.put(:evogit_agent_id, grandchild)
    Process.put(:repo_less, true)

    File.write!(
      Path.join(EvoGit.Config.config_dir(), "config.toml"),
      "[llm]\ncompression_threshold_tokens = 100\ntool_result_pruning = false\n"
    )

    head = [ReqLLM.Context.system("SYSTEM"), ReqLLM.Context.user("OBJECTIVE")]

    exchanges =
      Enum.flat_map(1..8, fn turn ->
        [ReqLLM.Context.assistant("old work #{turn}"), ReqLLM.Context.user("continue #{turn}")]
        |> Enum.map(&ContextBuilder.tag_message_turn(&1, turn))
      end)

    before = %{
      loop_state(grandchild, ctx.repo)
      | context: ReqLLM.Context.new(head ++ exchanges),
        total_tokens: 1_000
    }

    after_state =
      ContextCompression.compress_if_needed(before,
        agent_id: grandchild,
        llm_model: ToolDispatch.current_model(),
        llm_generation_params: ToolDispatch.current_generation_params(),
        llm_context_window: ToolDispatch.current_context_window()
      )

    assert %LoopState{} = after_state
    assert after_state.total_tokens == 0
    assert after_state.usage.input_tokens == 11
    assert after_state.usage.output_tokens == 7
    assert Enum.take(after_state.context.messages, 2) == head
    assert length(after_state.context.messages) < length(before.context.messages)

    assert Enum.any?(after_state.context.messages, fn message ->
             Enum.any?(
               message.content,
               &(&1.text && String.contains?(&1.text, "Selected account reply"))
             )
           end)

    assert agent!(grandchild).compression_count == 1
    request = assert_request(ctx.work, "work", "fixture-work-key", "wide", "high", 0.6, 4_096)
    assert Enum.any?(request["messages"], &String.contains?(&1["content"], "old work 1"))
    backup_ref = ctx.backup.ref
    refute_received {^backup_ref, "backup", _, _, _}
  end

  defp config(work_url, backup_url) do
    %{
      llm: %{
        default_provider_profile: "work",
        models: [%{id: "work", model: "openai:stale"}],
        providers: [
          %{
            id: "backup",
            provider: "openai",
            base_url: backup_url,
            api_key_env_var: @backup_key,
            models: ["small"],
            default_model: "small",
            context_window: 64_000,
            default_reasoning_effort: "low",
            reasoning_efforts: ["low"],
            temperature: 0.8,
            max_tokens: 1_024,
            concurrency: 2
          },
          %{
            id: "work",
            provider: "openai",
            base_url: work_url,
            api_key_env_var: @work_key,
            default_model: "small",
            context_window: 131_072,
            default_reasoning_effort: "high",
            reasoning_efforts: ["low", "high"],
            temperature: 0.2,
            max_tokens: 2_048,
            top_p: 0.9,
            concurrency: 2,
            models: [
              %{
                model: "wide",
                context_window: 300_000,
                temperature: 0.6,
                max_tokens: 4_096,
                default_reasoning_effort: "low"
              },
              "small"
            ]
          }
        ]
      }
    }
  end

  defp snapshot(config),
    do:
      struct!(State, Keyword.put(ModelSelection.config_opts(config), :next_agent_id, unique_id()))

  defp unique_id, do: 150_000_000 + System.unique_integer([:positive])

  defp wire(account, model, effort),
    do: %{"provider_profile_id" => account, "model" => model, "reasoning_effort" => effort}

  defp endpoint_model(url, model), do: %{provider: :openai, id: model, base_url: url}

  defp root_spec(repo, opts \\ []) do
    AgentSpec.new(
      %ContextNode{path: "./", repo: repo},
      %PhyloGraphNode{repo: repo, base_commit: "fixture-base", current_commit: "fixture-head"},
      EvoGit.Agents.Manager,
      "Test canonical inheritance",
      opts
    )
  end

  defp register!(state, spec, parent \\ nil, depth \\ 0) do
    id = state.next_agent_id

    on_exit(fn ->
      AgentScheduler.release_llm_slot(id)
      SchedulerStore.delete_agent_state(id)
      SchedulerStore.delete_sched_meta(id)
    end)

    assert {^id, %State{} = next} =
             Dispatch.register_agent(state, spec, nil, parent, depth, nil, 1)

    # The Runner normally installs the live phylo node after registration. Same-
    # repo building reads only that current commit and needs no git subprocess.
    SchedulerStore.put_agent_state(id, %{
      agent!(id)
      | phylo_node: %PhyloGraphNode{
          repo: Process.get(:repo_path),
          base_commit: "fixture-base",
          current_commit: "fixture-head"
        }
    })

    {id, next}
  end

  defp agent!(id) do
    {:ok, state} = SchedulerStore.get_agent_state(id)
    state
  end

  defp meta!(id) do
    {:ok, meta} = SchedulerStore.get_sched_meta(id)
    meta
  end

  defp loop_state(id, repo) do
    meta = meta!(id)

    %LoopState{
      agent_id: id,
      agent_module: meta.spec.agent_module,
      depth: meta.depth,
      parent_id: meta.parent_id,
      node_path: "./",
      repo_path: repo,
      context:
        ReqLLM.Context.new([ReqLLM.Context.system("SYSTEM"), ReqLLM.Context.user("OBJECTIVE")]),
      objective: "Test canonical inheritance",
      repo_less: Process.get(:repo_less, false)
    }
  end

  defp child_spec(parent, repo, loop \\ nil) do
    loop = loop || loop_state(parent, repo)

    module =
      case loop.agent_module do
        EvoGit.Agents.Manager -> EvoGit.Agents.Executor
        EvoGit.Agents.Executor -> EvoGit.Agents.Investigator
      end

    call =
      ReqLLM.ToolCall.new(
        "child-call",
        module.subagent_tool_name(),
        Jason.encode!(%{path: "./", objective: "Inherited child"})
      )

    assert [%AgentSpec{} = spec] = SubagentProcessing.build_subagent_specs([{call, 0}], loop)
    assert spec.phylo_node.base_commit == "fixture-head"
    spec
  end

  defp assert_inherited(spec, selection, locked) do
    assert Keyword.fetch!(spec.opts, :model_id_locked) == locked

    if locked do
      assert spec.model_spec == selection
      assert Keyword.fetch!(spec.opts, :model_spec) == selection
    else
      # A complete fallback preserves account/model/effort without suppressing
      # the next spawn's script, unlike an explicit :model_spec (even nil).
      assert spec.model_spec == nil
      refute Keyword.has_key?(spec.opts, :model_spec)
      assert Keyword.fetch!(spec.opts, :default_model_spec) == selection
    end
  end

  defp assert_selected(id, selection, url) do
    selected = agent!(id)
    assert selected.provider_profile_id == selection["provider_profile_id"]
    assert selected.model_spec == selection
    assert selected.llm_model == endpoint_model(url, selection["model"])

    assert Keyword.fetch!(selected.llm_generation_params, :reasoning_effort) ==
             Schema.LLM.convert_reasoning_effort(selection["reasoning_effort"])
  end

  defp script!(source) do
    dir = EvoGit.Config.config_dir()
    File.mkdir_p!(dir)

    File.write!(
      Path.join(dir, "agents.toml"),
      "[model_selection]\nscript = '''\n#{source}\n'''\n"
    )

    EvoGit.CustomAgents.ModelSelector.invalidate()
    assert EvoGit.CustomAgents.ModelSelector.status() == :ok
  end

  defp assert_request(server, account, key, model, effort, temperature, max_tokens, top_p \\ 0.9) do
    ref = server.ref
    assert_receive {^ref, ^account, line, headers, request}, 10_000
    assert line == "POST /v1/chat/completions HTTP/1.1"
    assert headers["authorization"] == "Bearer " <> key
    assert request["model"] == model
    assert request["reasoning_effort"] == effort
    assert request["temperature"] == temperature
    assert request["max_tokens"] == max_tokens
    assert request["top_p"] == top_p
    refute Map.has_key?(request, "provider_profile_id")
    refute Map.has_key?(request, "model_spec")
    request
  end

  defp restore_env(name, nil), do: System.delete_env(name)
  defp restore_env(name, value), do: System.put_env(name, value)
end
