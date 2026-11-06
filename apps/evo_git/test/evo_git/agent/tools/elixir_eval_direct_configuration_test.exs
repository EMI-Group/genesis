Code.require_file("elixir_eval_fixture_helper.exs", __DIR__)

defmodule EvoGit.Agent.Tools.ElixirEval.DirectConfigurationTest do
  @moduledoc """
  Genuine-Dune direct runtime APIs, disk persistence and public tier-2 approval.

  Synchronous: changes the global AgentScheduler, CommandApproval timeout and
  :config_dir_fun app-env seam. Broker runtime Tasks do not inherit ConfigDir's
  process dictionary, so a global, test-owned directory is essential here.
  PeakHourEngine is suspended before snapshots and resumed after restoration.
  Reload reconstructs model defaults and pool maps as well as scheduler scalars;
  all those fields are restored, not just the settings asserted by a test.
  """
  use EvoGit.TaskRegistryCase, async: false

  alias EvoGit.Agent.Tools.ElixirEval
  alias EvoGit.AgentScheduler.RemoteAPI
  alias EvoGit.{AgentScheduler, CommandApproval, Config}
  alias EvoGit.TestSupport.ElixirEvalFixture, as: Fixture

  @deadline 15_000
  @restored_fields ~w(default_llm_max_concurrency model_concurrency model_profiles
    agent_max_retries max_depth llm_model llm_generation_params max_retries
    max_turns max_turns_root paused max_tool_concurrency sandbox_mode
    sandbox_resources sandbox_process_resources llm_holders llm_waiting
    llm_backoff_until llm_last_granted)a

  setup %{store: store, registry: registry, tmp_dir: dir} do
    engine = Process.whereis(EvoGit.PeakHourEngine)
    :ok = :sys.suspend(engine)
    state = :sys.get_state(AgentScheduler)
    original = Map.take(state, @restored_fields)
    previous_dir = Application.fetch_env(:evo_git, :config_dir_fun)
    previous_timeout = Application.fetch_env(:evo_git, :command_approval_timeout)

    # Register cleanup before setup can fail. Preserve unrelated lifecycle fields,
    # and restore pools verbatim (update_config cannot undo a raised floor).
    on_exit(fn ->
      try do
        restored = :sys.replace_state(AgentScheduler, &struct(&1, original))
        assert Map.take(restored, @restored_fields) == original
        restore_env(:config_dir_fun, previous_dir)
        restore_env(:command_approval_timeout, previous_timeout)
      after
        :ok = :sys.resume(engine)
      end
    end)

    assert state.ref_to_agent == %{}
    assert :queue.is_empty(state.queue)
    assert :queue.is_empty(state.tool_waiting)
    assert MapSet.size(state.tool_holders) == 0
    assert Enum.all?(state.llm_waiting, fn {_, q} -> :queue.is_empty(q) end)
    assert Enum.all?(state.llm_holders, fn {_, holders} -> MapSet.size(holders) == 0 end)

    Application.put_env(:evo_git, :config_dir_fun, fn -> dir end)
    Application.put_env(:evo_git, :command_approval_timeout, 30_000)
    Phoenix.PubSub.subscribe(EvoGit.PubSub, CommandApproval.topic())
    path = Config.config_path()
    File.mkdir_p!(Path.dirname(path))

    File.write!(path, """
    # Private configuration; never the operator's config.
    [scheduler]
    max_turns = 73
    max_turns_root = 179
    max_tool_concurrency = 7
    [server]
    listen_port = 12987
    [git]
    cow_worktree_creation = "disabled"
    [sandbox]
    mode = "disabled"
    """)

    disk = Config.resolve()
    assert :ok = RemoteAPI.reload_config()
    assert :ok = AgentScheduler.resume()
    assert :ok = AgentScheduler.update_config(max_turns: 211)
    fixture = Fixture.start!(self(), store, registry)
    on_exit(fn -> Fixture.stop(fixture) end)
    %{fixture: fixture, path: path, bytes: File.read!(path), disk: disk}
  end

  @moduletag :tmp_dir

  test "get_config returns real nonscalar values, remapped depth and nil for unknown keys", ctx do
    assert :ok = AgentScheduler.update_config(max_depth: 11)
    assert :ok = AgentScheduler.update_config(model_concurrency: %{"idle" => 6, "paused" => 0})
    assert AgentScheduler.get_config(:model_concurrency) == %{"idle" => 6, "paused" => 0}
    assert is_map(AgentScheduler.get_config(:sandbox_resources))
    assert is_list(AgentScheduler.get_config(:model_profiles))
    assert is_list(AgentScheduler.get_config(:llm_generation_params))

    for key <- [
          :model_concurrency,
          :model_profiles,
          :llm_generation_params,
          :sandbox_resources,
          :sandbox_process_resources,
          :max_agent_depth,
          :max_turns,
          :max_depth,
          :scheduler,
          :not_a_configuration_key
        ] do
      assert read(ctx, "EvoGit.AgentScheduler.get_config(#{inspect(key)})") ==
               result(AgentScheduler.get_config(key))
    end

    assert AgentScheduler.get_config(:max_agent_depth) == 11
    assert AgentScheduler.get_config(:max_depth) == nil
    assert AgentScheduler.get_config(:scheduler) == nil
    assert AgentScheduler.get_config(:not_a_configuration_key) == nil
    assert_no_approval(ctx)
  end

  test "paused and slot reads expose actual per-model maps, including zero capacity", ctx do
    assert :ok = AgentScheduler.update_config(model_concurrency: %{"idle" => 6, "paused" => 0})

    expected = %{
      "idle" => %{used: 0, waiting: 0, capacity: 6},
      "paused" => %{used: 0, waiting: 0, capacity: 0}
    }

    assert AgentScheduler.get_llm_slot_status() == expected
    assert read(ctx, "EvoGit.AgentScheduler.get_llm_slot_status()") == result(expected)
    assert read(ctx, "EvoGit.AgentScheduler.paused?()") == "Result: false"
    assert_no_approval(ctx)
  end

  test "resolve reads normalized full defaults plus disk, never live runtime overrides", ctx do
    # Compare the entire returned map inside Dune, not a facade-sized projection.
    code = """
    config = EvoGit.Config.resolve()
    {config == #{inspect(ctx.disk, limit: :infinity)},
     config.scheduler.max_turns,
     EvoGit.Config.resolve(:scheduler) == config.scheduler,
     EvoGit.Config.resolve([:scheduler, :max_turns]),
     EvoGit.Config.resolve([:sandbox, :mode]),
     EvoGit.Config.resolve(:not_a_configuration_key),
     EvoGit.Config.resolve([:scheduler, :not_a_configuration_key]),
     EvoGit.AgentScheduler.get_config(:max_turns)}
    """

    assert read(ctx, code) == result({true, 73, true, 73, :disabled, nil, nil, 211})
    assert ctx.disk.server.listen_port == 12987
    assert ctx.disk.git.cow_worktree_creation == :disabled
    assert Map.has_key?(ctx.disk.scheduler, :max_retries)
    assert File.read!(ctx.path) === ctx.bytes
    assert_no_approval(ctx)
  end

  test "exact approved runtime update, pause and resume return real acknowledgements without saving",
       ctx do
    [{_, agent_before}] = :ets.lookup(:evogit_agent_state, ctx.fixture.agent_id)

    code =
      "  # exact runtime settings: 中文\nEvoGit.AgentScheduler.update_config(max_turns: 421)\n  "

    assert approved(ctx, code) == "Result: :ok"
    assert AgentScheduler.get_config(:max_turns) == 421
    assert Config.resolve([:scheduler, :max_turns]) == 73
    assert File.read!(ctx.path) === ctx.bytes

    assert :ets.lookup(:evogit_agent_state, ctx.fixture.agent_id) ==
             [{ctx.fixture.agent_id, agent_before}]

    assert approved(ctx, "EvoGit.AgentScheduler.pause()") == "Result: :ok"
    assert AgentScheduler.paused?()
    assert read(ctx, "EvoGit.AgentScheduler.paused?()") == "Result: true"
    assert approved(ctx, "EvoGit.AgentScheduler.resume()") == "Result: :ok"
    refute AgentScheduler.paused?()
    assert File.read!(ctx.path) === ctx.bytes
  end

  test "approved full-config save preserves unrelated settings and requires a separate explicit reload",
       ctx do
    before_reload = :sys.get_state(AgentScheduler) |> Map.take(@restored_fields)

    code = """
      # Preserve the full config in this exact approved read-modify-save call: 中文
      config = EvoGit.Config.resolve()
      updated = put_in(config, [:scheduler, :max_turns], 337)
      EvoGit.Config.save_user_config(updated)
    """

    assert approved(ctx, code) == "Result: :ok"
    assert File.read!(ctx.path) != ctx.bytes
    assert Config.resolve() == put_in(ctx.disk, [:scheduler, :max_turns], 337)
    assert :sys.get_state(AgentScheduler) |> Map.take(@restored_fields) == before_reload
    assert AgentScheduler.get_config(:max_turns) == 211

    assert read(
             ctx,
             "{EvoGit.Config.resolve([:scheduler, :max_turns]), EvoGit.AgentScheduler.get_config(:max_turns)}"
           ) ==
             result({337, 211})

    {:ok, saved} = TomlElixir.decode(File.read!(ctx.path))
    assert saved["server"]["listen_port"] == 12987
    assert saved["git"]["cow_worktree_creation"] == "disabled"
    assert saved["scheduler"]["max_turns_root"] == 179
    assert saved["scheduler"]["max_tool_concurrency"] == 7
    saved_bytes = File.read!(ctx.path)
    assert approved(ctx, "EvoGit.AgentScheduler.RemoteAPI.reload_config()") == "Result: :ok"
    assert AgentScheduler.get_config(:max_turns) == 337
    assert AgentScheduler.get_config(:max_turns_root) == 179
    assert AgentScheduler.get_config(:max_tool_concurrency) == 7
    assert AgentScheduler.get_config(:sandbox_mode) == :disabled

    assert AgentScheduler.get_config(:model_profiles) ==
             EvoGit.Config.Schema.effective_model_profiles(Config.resolve())

    assert File.read!(ctx.path) === saved_bytes
  end

  test "invalid approved save returns the real validation error and leaves disk and runtime unchanged",
       ctx do
    invalid = put_in(ctx.disk, [:scheduler, :max_tool_concurrency], -1)
    assert {:error, [_ | _] = errors} = EvoGit.Config.Schema.validate(invalid)

    code = """
    config = EvoGit.Config.resolve()
    EvoGit.Config.save_user_config(put_in(config, [:scheduler, :max_tool_concurrency], -1))
    """

    assert approved(ctx, code) == result({:error, errors})
    assert Config.resolve() == ctx.disk
    assert File.read!(ctx.path) === ctx.bytes
    assert AgentScheduler.get_config(:max_turns) == 211
    assert AgentScheduler.get_config(:max_tool_concurrency) == 7
  end

  test "denied direct mutations do not save, reload, pause or update, and never escalate", ctx do
    for code <- mutation_codes() do
      # Resume must be refused while actually paused, not pass vacuously because
      # the scheduler was already running.
      paused = code == "EvoGit.AgentScheduler.resume()"
      assert :ok = if(paused, do: AgentScheduler.pause(), else: AgentScheduler.resume())
      handle = start(ctx, code, "write")
      request = await_request(ctx, code)
      assert :ok = CommandApproval.respond(request.request_id, :deny)

      assert Fixture.await(handle) ==
               "Error: Elixir evaluation denied by the user; code was not executed."

      assert_resolved(request, :deny)
      assert {:error, :not_found} = CommandApproval.respond(request.request_id, :approve)
      assert AgentScheduler.get_config(:max_turns) == 211
      assert AgentScheduler.paused?() == paused
      assert File.read!(ctx.path) === ctx.bytes
      assert_no_approval(ctx)
    end
  end

  test "read tier refuses every direct mutation without opening write or sudo approval", ctx do
    for code <- mutation_codes() do
      paused = code == "EvoGit.AgentScheduler.resume()"
      assert :ok = if(paused, do: AgentScheduler.pause(), else: AgentScheduler.resume())
      output = read(ctx, code)
      assert output =~ "Error: Evaluation rejected a restricted operation."

      assert output =~
               "Writes require the write tier and exact-code approval; no automatic escalation."

      assert AgentScheduler.get_config(:max_turns) == 211
      assert AgentScheduler.paused?() == paused
      assert File.read!(ctx.path) === ctx.bytes
      assert_no_approval(ctx)
    end
  end

  defp mutation_codes do
    [
      "EvoGit.AgentScheduler.update_config(max_turns: 999)",
      "EvoGit.AgentScheduler.pause()",
      "EvoGit.AgentScheduler.resume()",
      "EvoGit.Config.save_user_config(put_in(EvoGit.Config.resolve(), [:scheduler, :max_turns], 999))",
      "EvoGit.AgentScheduler.RemoteAPI.reload_config()"
    ]
  end

  defp read(ctx, code), do: ctx |> start(code, "read") |> Fixture.await()

  defp start(ctx, code, tier) do
    Fixture.call_async(ctx.fixture, fn ->
      ElixirEval.execute(%{"code" => code, "tier" => tier}, "[system]", "[system]")
    end)
  end

  defp approved(ctx, code) do
    handle = start(ctx, code, "write")
    request = await_request(ctx, code)
    assert :ok = CommandApproval.respond(request.request_id, :approve)
    output = Fixture.await(handle)
    assert_resolved(request, :approve)
    assert {:error, :not_found} = CommandApproval.respond(request.request_id, :approve)
    assert_no_approval(ctx)
    output
  end

  defp await_request(ctx, code) do
    task_id = ctx.fixture.task_id
    agent_id = Integer.to_string(ctx.fixture.agent_id)

    assert_receive {:approval_requested,
                    %{task_id: ^task_id, agent_id: ^agent_id, code: ^code} = request},
                   @deadline

    assert request.args === code
    assert request.kind == :elixir_eval
    assert request.command == "elixir_eval"
    assert request.tier == :write
    assert request.level == 2
    assert request.warning == nil
    assert request.target_node == node()
    assert request.node == node()
    assert request in CommandApproval.pending()
    request
  end

  defp assert_resolved(request, decision) do
    id = request.request_id
    assert_receive {:approval_resolved, ^id, ^decision}, @deadline
    refute Enum.any?(CommandApproval.pending(), &(&1.request_id == id))
  end

  defp assert_no_approval(ctx) do
    task_id = ctx.fixture.task_id
    refute Enum.any?(CommandApproval.pending(), &(&1.task_id == task_id))
    # The public wrapper has joined, so a late request is structurally impossible.
    refute_received {:approval_requested, %{task_id: ^task_id}}
  end

  defp result(value), do: "Result: " <> inspect(value)
  defp restore_env(key, {:ok, value}), do: Application.put_env(:evo_git, key, value)
  defp restore_env(key, :error), do: Application.delete_env(:evo_git, key)
end
