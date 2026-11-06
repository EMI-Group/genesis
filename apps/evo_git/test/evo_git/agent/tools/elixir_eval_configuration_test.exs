Code.require_file("elixir_eval_fixture_helper.exs", __DIR__)

defmodule EvoGit.Agent.Tools.ElixirEval.ConfigurationTest do
  @moduledoc """
  Genuine-Dune configuration facades and public exact-code approval integration.

  Synchronous: mutates the app-global EvoGit.AgentScheduler and uses the global
  CommandApproval service and its :command_approval_timeout app-env key.
  PeakHourEngine is suspended before snapshot/mutation and resumed only after
  restoring every changed scalar and the derived model_concurrency map.
  TaskRegistry/Store and genuine owner/tool authority use the isolated Fixture.
  Direct Engine writes model an approved tier; separate wrapper cases establish
  the actual manual approval boundary. No Dune or authorization stubs are used.
  """
  use EvoGit.TaskRegistryCase, async: false

  alias EvoGit.Agent.Tools.ElixirEval
  alias EvoGit.Agent.Tools.ElixirEval.{Authorization, Engine}
  alias EvoGit.{AgentScheduler, CommandApproval}
  alias EvoGit.TestSupport.ElixirEvalFixture, as: Fixture

  @read "EvoGit.Agent.Tools.ElixirEval.Read"
  @write "EvoGit.Agent.Tools.ElixirEval.Write"
  @limits %{timeout_ms: 5_000, max_output_bytes: 16_384}
  @deadline 15_000
  @keys [
    :default_llm_max_concurrency,
    :max_tool_concurrency,
    :max_turns,
    :max_turns_root,
    :paused
  ]
  @restored_fields @keys ++ [:model_concurrency]
  @baseline %{
    default_llm_max_concurrency: 3,
    max_tool_concurrency: 7,
    max_turns: 101,
    max_turns_root: 151,
    paused: false
  }
  @restricted "Evaluation rejected a restricted operation. Use admitted APIs such as EvoGit.TaskRegistry.list_tasks_page/0,1 or EvoGit.AgentScheduler.get_config/1; Read/Write facade APIs remain available. Call EvoGit.Agent.Tools.ElixirEval.Read.help() for exact MFAs and limits. Writes require the write tier and exact-code approval; no automatic escalation."
  @denied "Error: Elixir evaluation requires a live root reflective assistant on the local node."

  setup %{store: store, registry: registry} do
    engine = Process.whereis(EvoGit.PeakHourEngine)
    :ok = :sys.suspend(engine)
    original = :sys.get_state(AgentScheduler) |> Map.take(@restored_fields)
    previous_timeout = Application.fetch_env(:evo_git, :command_approval_timeout)

    # Register restoration before any assertion/setup mutation can fail. Restore
    # the map verbatim: lowering the scalar via update_config would NOT undo a
    # concurrency floor raised by the test. Never replace unrelated live state.
    on_exit(fn ->
      try do
        restored = :sys.replace_state(AgentScheduler, &struct(&1, original))
        assert Map.take(restored, @restored_fields) == original

        case previous_timeout do
          {:ok, value} -> Application.put_env(:evo_git, :command_approval_timeout, value)
          :error -> Application.delete_env(:evo_git, :command_approval_timeout)
        end
      after
        :ok = :sys.resume(engine)
      end
    end)

    # With no queued work, pause/resume and capacity changes cannot dispatch an
    # unrelated agent or change holder/queue state that would also need restoring.
    state = :sys.get_state(AgentScheduler)
    assert :queue.is_empty(state.queue)
    assert :queue.is_empty(state.tool_waiting)
    assert Enum.all?(state.llm_waiting, fn {_, queue} -> :queue.is_empty(queue) end)

    :ok = AgentScheduler.update_config(Map.to_list(Map.delete(@baseline, :paused)))
    :ok = AgentScheduler.resume()
    Application.put_env(:evo_git, :command_approval_timeout, 30_000)
    Phoenix.PubSub.subscribe(EvoGit.PubSub, CommandApproval.topic())

    dir = EvoGit.TestSupport.ConfigDir.isolate!("eval_configuration")
    path = Path.join(dir, "config.toml")
    bytes = "# Keep these exact bytes: 中文\n[scheduler]\nmax_turns = 73\n"
    File.write!(path, bytes)
    fixture = Fixture.start!(self(), store, registry)

    on_exit(fn ->
      Fixture.stop(fixture)
      assert File.read!(path) === bytes
    end)

    %{fixture: fixture, config_path: path, config_bytes: bytes}
  end

  describe "live projected configuration through genuine Dune" do
    test "configuration_status returns exactly five scalars via five single-key reads", ctx do
      {result, requests} =
        scheduler_requests(fn ->
          evaluate(ctx.fixture, "#{@read}.configuration_status()")
        end)

      assert result == {:ok, "Result: " <> inspect(@baseline)}
      assert requests == Enum.map(@keys, &{:get_config, &1})
      assert live_settings() == @baseline
      assert_config_unchanged(ctx)
    end

    test "read-tier mutation is restricted with no scheduler dispatch or approval", ctx do
      code = "#{@write}.update_scheduler_config(%{max_turns: 222})"

      {result, requests} = scheduler_requests(fn -> evaluate(ctx.fixture, code) end)
      assert result == {:error, @restricted}
      assert requests == []
      assert live_settings() == @baseline
      assert_no_approval(ctx.fixture)
      assert_config_unchanged(ctx)
    end

    test "numeric writes acknowledge only normalized requested runtime settings", ctx do
      [{_, agent_before}] = :ets.lookup(:evogit_agent_state, ctx.fixture.agent_id)

      settings = %{
        default_llm_max_concurrency: 5,
        max_tool_concurrency: 11,
        max_turns: 223,
        max_turns_root: 337
      }

      code = """
      #{@write}.update_scheduler_config(%{
        "default_llm_max_concurrency" => 5, :max_tool_concurrency => 11,
        "max_turns" => 223, :max_turns_root => 337
      })
      """

      assert evaluate(ctx.fixture, code, :write) == {:ok, acknowledgement(settings)}
      assert live_settings() == Map.merge(@baseline, settings)

      assert evaluate(ctx.fixture, "#{@read}.configuration_status()") ==
               {:ok, "Result: " <> inspect(Map.merge(@baseline, settings))}

      # Turn limits affect future registrations, never rewrite the live agent.
      assert :ets.lookup(:evogit_agent_state, ctx.fixture.agent_id) ==
               [{ctx.fixture.agent_id, agent_before}]

      assert_config_unchanged(ctx)
    end

    test "standalone pause and resume use scheduler transitions and exact acknowledgements",
         ctx do
      {result, requests} =
        scheduler_requests(fn ->
          assert evaluate(
                   ctx.fixture,
                   "#{@write}.update_scheduler_config(%{\"paused\" => true})",
                   :write
                 ) ==
                   {:ok, acknowledgement(%{paused: true})}

          assert AgentScheduler.paused?()

          assert evaluate(ctx.fixture, "#{@read}.configuration_status().paused") ==
                   {:ok, "Result: true"}

          evaluate(ctx.fixture, "#{@write}.update_scheduler_config(%{paused: false})", :write)
        end)

      assert result == {:ok, acknowledgement(%{paused: false})}
      assert Enum.filter(requests, &mutation?/1) == [:pause, :resume]
      refute AgentScheduler.paused?()
      assert live_settings() == @baseline
      assert_config_unchanged(ctx)
    end
  end

  describe "configuration capability quota accounting" do
    test "each configuration_status charges one read, not five, and the 33rd never dispatches",
         ctx do
      code = """
      results = Enum.map(1..32, fn _ -> #{@read}.configuration_status() end)
      {Enum.all?(results, fn value -> value == #{inspect(@baseline)} end),
       #{@read}.configuration_status()}
      """

      {result, requests} = scheduler_requests(fn -> evaluate(ctx.fixture, code) end)
      assert result == {:ok, ~s|Result: {true, {:error, "Evaluation read limit reached."}}|}
      assert requests == List.duplicate(Enum.map(@keys, &{:get_config, &1}), 32) |> List.flatten()
      # A fresh evaluation receives a fresh quota.
      assert evaluate(ctx.fixture, "#{@read}.configuration_status()") ==
               {:ok, "Result: " <> inspect(@baseline)}
    end

    test "configuration_status consumes exactly one of the 500 projected rows", ctx do
      # Page costs charge requested rows, including empty pages. 9*50 + 49 =
      # 499 rows in ten reads: read quota cannot explain either boundary result.
      code = """
      pages = Enum.map(1..9, fn _ -> #{@read}.list_tasks(%{limit: 50}) end)
      last_page = #{@read}.list_tasks(%{limit: 49})
      {Enum.all?(pages, fn page -> is_map(page) end) and is_map(last_page),
       #{@read}.configuration_status() == #{inspect(@baseline)},
       #{@read}.configuration_status()}
      """

      {result, requests} = scheduler_requests(fn -> evaluate(ctx.fixture, code) end)
      assert result == {:ok, ~s|Result: {true, true, {:error, "Evaluation read limit reached."}}|}
      assert requests == Enum.map(@keys, &{:get_config, &1})
    end

    test "sixteen numeric writes dispatch once each and the seventeenth has no effect", ctx do
      code = """
      results = Enum.map(601..616, fn value ->
        #{@write}.update_scheduler_config(%{max_turns: value})
      end)
      {Enum.with_index(results, 601) |> Enum.all?(fn {result, value} ->
         result == %{status: :updated, scope: :runtime, persisted: false,
                     settings: %{max_turns: value}}
       end),
       #{@write}.update_scheduler_config(%{max_turns: 617})}
      """

      {result, requests} = scheduler_requests(fn -> evaluate(ctx.fixture, code, :write) end)

      assert result ==
               {:ok,
                ~s|Result: {true, {:error, "Write capability unavailable or write limit reached."}}|}

      assert Enum.filter(requests, &mutation?/1) ==
               Enum.map(601..616, &{:update_config, [max_turns: &1]})

      assert live_settings() == %{@baseline | max_turns: 616}
      assert_config_unchanged(ctx)
    end
  end

  describe "public configuration wrapper and exact-code approval" do
    test "public read is approval-free but a mutation cannot escalate its read tier", ctx do
      handle = start_eval(ctx.fixture, "#{@read}.configuration_status()", "read")
      assert Fixture.await(handle) == "Result: " <> inspect(@baseline)

      handle =
        start_eval(ctx.fixture, "#{@write}.update_scheduler_config(%{paused: true})", "read")

      assert Fixture.await(handle) == "Error: " <> @restricted
      assert_no_approval(ctx.fixture)
      assert live_settings() == @baseline
    end

    test "denying exact configuration code prevents effects and late approval is rejected", ctx do
      code = "  # exact config: 中文\n#{@write}.update_scheduler_config(%{max_turns: 421})\n  "
      handle = start_eval(ctx.fixture, code, "write")
      request = await_request(ctx.fixture, code)
      assert live_settings() == @baseline
      assert_config_unchanged(ctx)
      assert :ok = CommandApproval.respond(request.request_id, :deny)

      assert Fixture.await(handle) ==
               "Error: Elixir evaluation denied by the user; code was not executed."

      assert_resolved(request, :deny)
      assert {:error, :not_found} = CommandApproval.respond(request.request_id, :approve)
      assert live_settings() == @baseline
      assert_config_unchanged(ctx)
    end

    test "approved exact configuration code returns runtime-only acknowledgement and dispatches once",
         ctx do
      code =
        "  # exact config: 中文\n#{@write}.update_scheduler_config(%{\"max_turns\" => 421})\n  "

      handle = start_eval(ctx.fixture, code, "write")
      request = await_request(ctx.fixture, code)
      assert live_settings() == @baseline
      assert_config_unchanged(ctx)

      {result, requests} =
        scheduler_requests(fn ->
          assert :ok = CommandApproval.respond(request.request_id, :approve)
          Fixture.await(handle)
        end)

      assert result == acknowledgement(%{max_turns: 421})
      assert Enum.filter(requests, &mutation?/1) == [{:update_config, [max_turns: 421]}]
      assert_resolved(request, :approve)
      assert {:error, :not_found} = CommandApproval.respond(request.request_id, :approve)
      assert live_settings() == %{@baseline | max_turns: 421}
      assert_config_unchanged(ctx)
    end

    test "authority invalidated during held configuration approval prevents dispatch", ctx do
      code = "#{@write}.update_scheduler_config(%{max_turns_root: 499})"
      handle = start_eval(ctx.fixture, code, "write")
      request = await_request(ctx.fixture, code)
      # No lifecycle broadcast: only post-approval revalidation can catch this.
      Fixture.update_state(ctx.fixture, &%{&1 | cancel_requested: true})

      {result, requests} =
        scheduler_requests(fn ->
          assert :ok = CommandApproval.respond(request.request_id, :approve)
          Fixture.await(handle)
        end)

      assert result == @denied
      assert Enum.filter(requests, &mutation?/1) == []
      assert_resolved(request, :approve)
      assert live_settings() == @baseline
      assert_config_unchanged(ctx)
    end
  end

  defp evaluate(fixture, code, tier \\ :read) do
    fixture
    |> Fixture.call_async(fn ->
      {:ok, authority} = Authorization.authorize()
      Engine.run(code, tier, authority, @limits)
    end)
    |> Fixture.await()
  end

  defp start_eval(fixture, code, tier) do
    Fixture.call_async(fixture, fn ->
      ElixirEval.execute(%{"code" => code, "tier" => tier}, "[system]", "[system]")
    end)
  end

  defp acknowledgement(settings) do
    "Result: " <>
      inspect(%{status: :updated, scope: :runtime, persisted: false, settings: settings})
  end

  defp live_settings do
    Map.new(@keys, &{&1, AgentScheduler.get_config(&1)})
  end

  defp assert_config_unchanged(ctx) do
    assert File.read!(ctx.config_path) === ctx.config_bytes
  end

  defp await_request(fixture, code) do
    task_id = fixture.task_id
    agent_id = Integer.to_string(fixture.agent_id)

    assert_receive {:approval_requested,
                    %{task_id: ^task_id, agent_id: ^agent_id, tier: :write, code: ^code} = request},
                   @deadline

    assert request.code === code
    assert request.args === code
    assert request.kind == :elixir_eval
    assert request.command == "elixir_eval"
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

  defp assert_no_approval(fixture) do
    task_id = fixture.task_id
    agent_id = Integer.to_string(fixture.agent_id)
    refute Enum.any?(CommandApproval.pending(), &(&1.task_id == task_id))
    # The wrapper has joined; no possible later request can race this assertion.
    refute_received {:approval_requested, %{task_id: ^task_id, agent_id: ^agent_id}}
  end

  defp mutation?(:pause), do: true
  defp mutation?(:resume), do: true
  defp mutation?({:update_config, _}), do: true
  defp mutation?(_), do: false

  defp scheduler_requests(fun) do
    scheduler = Process.whereis(AgentScheduler)
    session = :trace.session_create(:eval_configuration_scheduler, self(), [])

    try do
      assert :trace.process(session, scheduler, true, [:receive]) == 1
      result = fun.()
      barrier = :trace.delivered(session, scheduler)
      {result, collect_requests(scheduler, barrier, [])}
    after
      :trace.session_destroy(session)
    end
  end

  defp collect_requests(scheduler, barrier, acc) do
    receive do
      {:trace_delivered, ^scheduler, ^barrier} ->
        Enum.reverse(acc)

      {:trace, ^scheduler, :receive, {:"$gen_call", {caller, _}, request}} ->
        # The app-global sampler can request raw config during this trace.
        # Exclude only that known caller, not all raw-config requests: a facade
        # regression fetching :get_config must still fail the exact-read test.
        relevant? =
          caller != Process.whereis(EvoGit.SystemSampler) and
            (request in [:get_config, :pause, :resume] or
               match?({:get_config, key} when key in @keys, request) or
               match?({:update_config, _}, request))

        if relevant? do
          collect_requests(scheduler, barrier, [request | acc])
        else
          collect_requests(scheduler, barrier, acc)
        end

      {:trace, ^scheduler, :receive, _} ->
        collect_requests(scheduler, barrier, acc)
    after
      @deadline -> flunk("scheduler trace did not deliver its completion barrier")
    end
  end
end
