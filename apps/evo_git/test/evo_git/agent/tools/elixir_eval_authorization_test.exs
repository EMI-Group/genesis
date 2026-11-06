Code.require_file("elixir_eval_fixture_helper.exs", __DIR__)

defmodule EvoGit.Agent.Tools.ElixirEval.AuthorizationTest do
  @moduledoc """
  Async-safe authorization regressions: isolated Store/TaskRegistry instances,
  genuine held assistant Tasks and descendant tool Tasks, and unique ETS rows.
  No scheduler, approval service, environment or shared fixture is modified.
  """
  use EvoGit.TaskRegistryCase, async: true

  alias EvoGit.Agent.Tools.ElixirEval.{Ancestry, Authorization}
  alias EvoGit.Core.{ForeignRepo, PhyloGraphNode}
  alias EvoGit.Store
  alias EvoGit.TestSupport.ElixirEvalFixture, as: Fixture

  @denied {:error,
           "Elixir evaluation requires a live root reflective assistant on the local node."}

  setup %{store: store, registry: registry} do
    fixture = Fixture.start!(self(), store, registry)
    on_exit(fn -> Fixture.stop(fixture) end)
    {:ok, fixture: fixture}
  end

  describe "fixture cleanup" do
    test "the test supervisor owns the temporary fixture tree", %{fixture: fixture} do
      {:links, links} = Process.info(self(), :links)
      refute fixture.supervisor in links

      {:dictionary, dictionary} = Process.info(fixture.supervisor, :dictionary)
      [parent | _] = Keyword.fetch!(dictionary, :"$ancestors")
      refute parent == self()

      assert Enum.any?(Supervisor.which_children(parent), fn
               {{Fixture, id}, pid, :supervisor, _} ->
                 id == fixture.agent_id and pid == fixture.supervisor

               _ ->
                 false
             end)
    end

    for shutdown_reason <- [:shutdown, {:shutdown, :unexpected_fixture_failure}] do
      @shutdown_reason shutdown_reason
      test "cleanup during held-child supervisor termination: #{inspect(shutdown_reason)}", %{
        fixture: fixture
      } do
        test_pid = self()
        tag = make_ref()

        {:ok, child} =
          Task.Supervisor.start_child(
            fixture.supervisor,
            fn ->
              Process.flag(:trap_exit, true)
              send(test_pid, {tag, :ready})

              receive do
                {:EXIT, _, :shutdown} ->
                  send(test_pid, {tag, :stopping})
                  receive do: ({^tag, :release} -> :ok)
              end
            end,
            shutdown: 30_000
          )

        assert_receive {^tag, :ready}, 15_000
        child_monitor = Process.monitor(child)
        owner_monitor = Process.monitor(fixture.owner_pid)
        supervisor_monitor = Process.monitor(fixture.supervisor)
        shutdown_reason = @shutdown_reason
        shutdown = Task.async(fn -> Supervisor.stop(fixture.supervisor, shutdown_reason) end)

        try do
          assert_receive {^tag, :stopping}, 15_000

          cleanup =
            Task.async(fn ->
              # Capture the exact exit for the negative case; it must not become :ok.
              try do
                Fixture.stop(fixture)
              catch
                :exit, reason -> {:exit, reason}
              end
            end)

          await_stop_request(fixture.supervisor, System.monotonic_time(:millisecond) + 15_000)
          assert Process.alive?(cleanup.pid)
          send(child, {tag, :release})

          assert Task.await(shutdown, 15_000) == :ok
          result = Task.await(cleanup, 15_000)

          assert_cleanup_result(result, shutdown_reason, fixture)

          assert_receive {:DOWN, ^child_monitor, :process, ^child, :normal}, 15_000
          assert_receive {:DOWN, ^owner_monitor, :process, _, _}, 15_000
          assert_receive {:DOWN, ^supervisor_monitor, :process, _, ^shutdown_reason}, 15_000
          assert :ets.lookup(:evogit_agent_state, fixture.agent_id) == []
          assert :ets.lookup(:evogit_sched_meta, fixture.agent_id) == []
          assert Store.get_task(fixture.store, fixture.task_id) == nil
        after
          send(child, {tag, :release})
        end
      end
    end

    test "repeated cleanup stops live descendants and removes the fixture records", %{
      fixture: fixture
    } do
      handle = Fixture.call_async(fixture, fn -> receive do: (:release -> :ok) end)
      tool_monitor = Process.monitor(handle.tool_pid)
      owner_monitor = Process.monitor(fixture.owner_pid)
      supervisor_monitor = Process.monitor(fixture.supervisor)

      assert :ok = Fixture.stop(fixture)
      assert :ok = Fixture.stop(fixture)

      assert_receive {:DOWN, ^tool_monitor, :process, _, _}, 15_000
      assert_receive {:DOWN, ^owner_monitor, :process, _, _}, 15_000
      assert_receive {:DOWN, ^supervisor_monitor, :process, _, :normal}, 15_000
      assert :ets.lookup(:evogit_agent_state, fixture.agent_id) == []
      assert :ets.lookup(:evogit_sched_meta, fixture.agent_id) == []
      assert Store.get_task(fixture.store, fixture.task_id) == nil
    end

    test "cleanup remains repeat-safe after the private supervisor dies asynchronously", %{
      fixture: fixture
    } do
      supervisor = fixture.supervisor
      monitor = Process.monitor(supervisor)
      shutdown = Task.async(fn -> Supervisor.stop(supervisor, :shutdown) end)
      assert_receive {:DOWN, ^monitor, :process, ^supervisor, :shutdown}, 15_000
      assert Task.await(shutdown) == :ok

      assert :ok = Fixture.stop(fixture)
      assert :ok = Fixture.stop(fixture)
      assert :ets.lookup(:evogit_agent_state, fixture.agent_id) == []
      assert :ets.lookup(:evogit_sched_meta, fixture.agent_id) == []
      assert Store.get_task(fixture.store, fixture.task_id) == nil
    end
  end

  test "a real descendant captures the original assistant, tool and isolated registry", %{
    fixture: fixture
  } do
    test_pid = self()

    handle =
      Fixture.call_async(fixture, fn ->
        result = Authorization.authorize()
        send(test_pid, {:captured, self(), result, Authorization.assistant_owner?()})
        receive do: (:release -> result)
      end)

    assert_receive {:captured, tool, {:ok, context}, true}, 15_000
    assert tool == handle.tool_pid

    assert context == %{
             agent_id: fixture.agent_id,
             task_id: fixture.task_id,
             owner_pid: fixture.owner.pid,
             tool_pid: tool,
             target_node: node(),
             registry: fixture.registry
           }

    assert Ancestry.includes?(tool, fixture.owner.pid)
    assert Authorization.revalidate(context) == :ok
    monitor = Process.monitor(tool)
    send(tool, :release)
    assert Fixture.await(handle) == {:ok, context}
    assert_receive {:DOWN, ^monitor, :process, ^tool, :normal}, 15_000
    assert Authorization.revalidate(context) == @denied
  end

  test "nested runtime Task ancestry is accepted without inheriting role flags", %{
    fixture: fixture
  } do
    assert {:ok, true} ==
             call(fixture, fn ->
               identity = for key <- identity_keys(), do: {key, Process.get(key)}

               Task.async(fn ->
                 Enum.each(identity, fn {key, value} -> Process.put(key, value) end)
                 Process.put(:repo_less, false)
                 {:ok, context} = Authorization.authorize()
                 {:ok, context.tool_pid == self()}
               end)
               |> Task.await()
             end)
  end

  test "correct ids and forged tool role flags cannot authorize an unrelated process", %{
    fixture: fixture
  } do
    test_pid = self()
    ref = make_ref()

    {pid, monitor} =
      spawn_monitor(fn ->
        Process.put(:repo_less, true)
        Process.put(:agent_type, :read)
        Process.put(:agent_module, EvoGit.Agents.SelfReflective)
        Process.put(:evogit_agent_id, fixture.agent_id)
        Process.put(:evogit_task_id, fixture.task_id)
        Process.put(:evogit_agent_pid, fixture.owner_pid)
        Process.put(:evogit_task_registry_server, fixture.registry)
        send(test_pid, {ref, Authorization.authorize(), Authorization.assistant_owner?()})
      end)

    assert_receive {^ref, @denied, false}, 15_000
    assert_receive {:DOWN, ^monitor, :process, ^pid, :normal}, 15_000
  end

  test "missing or mismatched tool identity cannot borrow a live assistant's authority", %{
    fixture: fixture
  } do
    for {key, value} <- [
          {:evogit_agent_id, nil},
          {:evogit_agent_id, 0},
          {:evogit_agent_id, "forged"},
          {:evogit_task_id, nil},
          {:evogit_task_id, "another_task"},
          {:evogit_agent_pid, nil}
        ] do
      assert call(fixture, fn ->
               Process.put(key, value)
               Authorization.authorize()
             end) == @denied
    end

    assert call(fixture, fn ->
             Process.put(:evogit_agent_pid, self())
             Authorization.authorize()
           end) == @denied
  end

  test "tool-local flags cannot repair a non-assistant owner's registered spec", %{
    fixture: fixture
  } do
    Fixture.update_meta(fixture, fn meta ->
      %{meta | spec: %{meta.spec | agent_module: EvoGit.Agents.Executor}}
    end)

    assert call(fixture, fn ->
             Process.put(:repo_less, true)
             Process.put(:agent_module, EvoGit.Agents.SelfReflective)
             Process.put(:agent_type, :read)
             Authorization.authorize()
           end) == @denied
  end

  describe "registered owner metadata" do
    for {label, changes} <- [
          {"non-root depth", %{depth: 1}},
          {"parent agent", %{parent_id: 123}},
          {"pending agent", %{status: :pending}},
          {"waiting agent", %{status: :waiting}},
          {"ready agent", %{status: :ready}},
          {"terminal agent", %{status: :completed}},
          {"cancelled agent", %{status: :cancelled}},
          {"completed result", %{result_sent: true}},
          {"wrong task identity", %{task_id: "another_task"}},
          {"missing Task", %{task_ref: nil}}
        ] do
      test "rejects #{label}", %{fixture: fixture} do
        Fixture.update_meta(fixture, &struct!(&1, unquote(Macro.escape(changes))))
        assert authorize(fixture) == @denied
      end
    end

    test "blocked root assistants remain authorized", %{fixture: fixture} do
      Fixture.update_meta(fixture, &%{&1 | status: :blocked})
      assert {:ok, _} = authorize(fixture)
    end

    test "the metadata's embedded agent id must match its ETS key", %{fixture: fixture} do
      [{id, meta}] = :ets.lookup(:evogit_sched_meta, fixture.agent_id)
      :ets.insert(:evogit_sched_meta, {id, %{meta | id: id + 1}})
      assert authorize(fixture) == @denied
    end

    test "a different live Task cannot replace the captured owner's Task", %{fixture: fixture} do
      replacement = Task.async(fn -> receive do: (:release -> :ok) end)

      on_exit(fn ->
        if Process.alive?(replacement.pid), do: Process.exit(replacement.pid, :kill)
      end)

      Fixture.update_meta(fixture, &%{&1 | task_ref: replacement})
      assert authorize(fixture) == @denied
      send(replacement.pid, :release)
      assert Task.await(replacement) == :ok
    end

    test "missing metadata fails closed", %{fixture: fixture} do
      :ets.delete(:evogit_sched_meta, fixture.agent_id)
      assert authorize(fixture) == @denied
    end
  end

  describe "registered spec" do
    for {label, changes} <- [
          {"non-assistant module", %{agent_module: EvoGit.Agents.Investigator}},
          {"custom agent module", %{agent_module: EvoGit.Agents.Custom}},
          {"foreign repository", %{repo_id: "foreign"}},
          {"missing opts", %{opts: nil}},
          {"non-keyword opts", %{opts: ["repo_less"]}}
        ] do
      test "rejects #{label}", %{fixture: fixture} do
        Fixture.update_meta(fixture, fn meta ->
          %{meta | spec: struct!(meta.spec, unquote(Macro.escape(changes)))}
        end)

        assert authorize(fixture) == @denied
      end
    end

    for {label, key, value} <- [
          {"repo-backed assistant", :repo_less, false},
          {"truthy but nonboolean repo-less flag", :repo_less, "true"},
          {"wrong spec task", :task_id, "another_task"},
          {"custom agent id", :custom_agent_id, "custom"},
          {"custom root selection", :agent, "custom"}
        ] do
      test "rejects #{label}", %{fixture: fixture} do
        Fixture.update_meta(fixture, fn meta ->
          opts = Keyword.put(meta.spec.opts, unquote(key), unquote(value))
          %{meta | spec: %{meta.spec | opts: opts}}
        end)

        assert authorize(fixture) == @denied
      end
    end

    test "missing repo-less and task-id options cannot authorize", %{fixture: fixture} do
      original = fixture.spec.opts

      for key <- [:repo_less, :task_id] do
        Fixture.update_meta(
          fixture,
          &%{&1 | spec: %{&1.spec | opts: Keyword.delete(original, key)}}
        )

        assert authorize(fixture) == @denied
      end
    end

    test "foreign repositories are refused in both spec and options", %{fixture: fixture} do
      foreign = %ForeignRepo{id: "foreign", root: "[foreign]", description: "Test foreign repo"}
      Fixture.update_meta(fixture, &%{&1 | spec: %{&1.spec | foreign_repos: [foreign]}})
      assert authorize(fixture) == @denied

      Fixture.update_meta(fixture, fn meta ->
        opts = Keyword.put(fixture.spec.opts, :foreign_repos, [foreign])
        %{meta | spec: %{fixture.spec | opts: opts}}
      end)

      assert authorize(fixture) == @denied
    end

    test "a phylogenetic worktree node disqualifies an otherwise reflective spec", %{
      fixture: fixture
    } do
      phylo = %PhyloGraphNode{base_commit: "base", current_commit: "tip"}
      Fixture.update_meta(fixture, &%{&1 | spec: %{&1.spec | phylo_node: phylo}})
      assert authorize(fixture) == @denied
    end
  end

  describe "projected live agent state" do
    for {label, changes} <- [
          {"cancellation requested", %{cancel_requested: true}},
          {"malformed cancellation flag", %{cancel_requested: "false"}},
          {"nested agent", %{parent_id: 123}},
          {"foreign agent", %{repo_id: "foreign"}}
        ] do
      test "rejects #{label}", %{fixture: fixture} do
        Fixture.update_state(fixture, &struct!(&1, unquote(Macro.escape(changes))))
        assert authorize(fixture) == @denied
      end
    end

    test "an unset cancellation flag is valid", %{fixture: fixture} do
      Fixture.update_state(fixture, &%{&1 | cancel_requested: nil})
      assert {:ok, _} = authorize(fixture)
    end

    test "state foreign repositories cannot be hidden by a clean spec", %{fixture: fixture} do
      foreign = %ForeignRepo{id: "foreign", root: "[foreign]", description: "Test foreign repo"}
      Fixture.update_state(fixture, &%{&1 | foreign_repos: [foreign]})
      assert authorize(fixture) == @denied
    end

    test "missing live state fails closed", %{fixture: fixture} do
      :ets.delete(:evogit_agent_state, fixture.agent_id)
      assert authorize(fixture) == @denied
    end
  end

  describe "persisted task authority" do
    for status <- [:pending, :finalizing, :cancelling, :completed, :failed, :cancelled] do
      test "rejects a #{status} task", %{fixture: fixture} do
        Fixture.update_task(fixture, &%{&1 | status: unquote(status)})
        assert authorize(fixture) == @denied
      end
    end

    test "a running non-reflect task is insufficient", %{fixture: fixture} do
      Fixture.update_task(fixture, &%{&1 | type: :evolve})
      assert authorize(fixture) == @denied
    end

    test "stale agent rows cannot authorize a deleted task", %{fixture: fixture} do
      :ok = Store.delete_task(fixture.store, fixture.task_id)
      assert authorize(fixture) == @denied
    end
  end

  describe "captured identities and lifecycle revalidation" do
    test "revalidation uses captured identities, not the current caller's dictionary", %{
      fixture: fixture
    } do
      {handle, context} = held_context(fixture)
      original = context

      for key <- identity_keys(), do: Process.put(key, :forged)
      Process.put(:repo_less, false)
      assert Authorization.revalidate(context) == :ok
      assert context == original

      send(handle.tool_pid, {:dictionary, self()})
      assert_receive {:dictionary_changed, tool, :ok}, 15_000
      assert tool == handle.tool_pid
      assert Authorization.revalidate(context) == :ok
      release(handle)
    end

    test "captured authority does not migrate to new task/agent identities", %{fixture: fixture} do
      {handle, context} = held_context(fixture)
      other = Fixture.start!(self(), fixture.store, fixture.registry)
      on_exit(fn -> Fixture.stop(other) end)

      assert Authorization.revalidate(%{context | agent_id: other.agent_id}) == @denied
      assert Authorization.revalidate(%{context | task_id: other.task_id}) == @denied
      assert Authorization.revalidate(%{context | owner_pid: other.owner_pid}) == @denied
      assert Authorization.revalidate(%{context | tool_pid: self()}) == @denied

      Fixture.update_meta(fixture, &%{&1 | task_ref: other.owner})
      assert Authorization.revalidate(context) == @denied
      release(handle)
    end

    test "cancelled agent and terminal task invalidate an already captured context", %{
      fixture: fixture
    } do
      {handle, context} = held_context(fixture)
      Fixture.update_state(fixture, &%{&1 | cancel_requested: true})
      assert Authorization.revalidate(context) == @denied
      Fixture.update_state(fixture, &%{&1 | cancel_requested: false})
      assert Authorization.revalidate(context) == :ok
      Fixture.update_task(fixture, &%{&1 | status: :cancelled})
      assert Authorization.revalidate(context) == @denied
      release(handle)
    end

    test "dead original tool invalidates the context even with a live owner", %{fixture: fixture} do
      {handle, context} = held_context(fixture)
      monitor = Process.monitor(handle.tool_pid)
      Process.exit(handle.tool_pid, :kill)
      assert_receive {:DOWN, ^monitor, :process, _, :killed}, 15_000
      assert Fixture.await(handle) == {:exit, :killed}
      assert Process.alive?(fixture.owner_pid)
      assert Authorization.revalidate(context) == @denied
    end

    test "dead owner invalidates a still-live original tool", %{fixture: fixture} do
      {handle, context} = held_context(fixture)
      monitor = Process.monitor(fixture.owner_pid)
      Process.exit(fixture.owner_pid, :kill)
      assert_receive {:DOWN, ^monitor, :process, _, :killed}, 15_000
      assert Process.alive?(handle.tool_pid)
      assert Authorization.revalidate(context) == @denied
      assert Fixture.await(handle) == {:exit, {:owner_down, :killed}}
    end

    for invalidation <- [:metadata_changed, :state_cancelled] do
      test "rechecks #{invalidation} after the task lookup returns", %{fixture: fixture} do
        {handle, context} = held_context(fixture)
        test_pid = self()

        # A one-shot local forwarding process holds only the reply, never forges
        # a task: the projection comes from this test's real isolated registry.
        proxy =
          spawn(fn ->
            receive do
              {:"$gen_call", from, {:get_task_lite, id} = request} ->
                task = GenServer.call(fixture.registry, request)
                send(test_pid, {:lookup_ready, self(), id, task})
                receive do: (:reply -> GenServer.reply(from, task))
            end
          end)

        on_exit(fn -> if Process.alive?(proxy), do: Process.exit(proxy, :kill) end)

        revalidation =
          Task.async(fn -> Authorization.revalidate(%{context | registry: proxy}) end)

        task_id = fixture.task_id

        assert_receive {:lookup_ready, ^proxy, ^task_id, %{status: :running, type: :reflect}},
                       15_000

        case unquote(invalidation) do
          :metadata_changed -> Fixture.update_meta(fixture, &%{&1 | depth: 1})
          :state_cancelled -> Fixture.update_state(fixture, &%{&1 | cancel_requested: true})
        end

        send(proxy, :reply)
        assert Task.await(revalidation, 15_000) == @denied
        release(handle)
      end
    end

    test "malformed captured identities fail closed without leaking exceptions", %{
      fixture: fixture
    } do
      {handle, context} = held_context(fixture)

      for changes <- [
            %{agent_id: nil},
            %{agent_id: 0},
            %{agent_id: -1},
            %{agent_id: "1"},
            %{task_id: nil},
            %{task_id: ""},
            %{owner_pid: nil},
            %{tool_pid: nil},
            %{target_node: :other_node}
          ] do
        assert Authorization.revalidate(Map.merge(context, changes)) == @denied
      end

      for malformed <- [nil, [], %{}, Map.delete(context, :registry)] do
        assert Authorization.revalidate(malformed) == @denied
      end

      release(handle)
    end
  end

  describe "target and registry selection" do
    test "only explicit local spellings and the exact current node name are accepted", %{
      fixture: fixture
    } do
      for target <- [nil, :current, :local, "current", "local", Atom.to_string(node())] do
        assert {:ok, %{target_node: target_node}} =
                 call(fixture, fn -> Authorization.authorize(target) end)

        assert target_node == node()
      end

      for target <- ["remote@host", "", :remote, %{}, [], 1] do
        assert call(fixture, fn -> Authorization.authorize(target) end) == @denied
      end
    end

    test "missing and invalid captured registries fail closed", %{fixture: fixture} do
      {handle, context} = held_context(fixture)
      dead = spawn(fn -> :ok end)
      monitor = Process.monitor(dead)
      assert_receive {:DOWN, ^monitor, :process, ^dead, _}, 15_000

      for registry <- [nil, :elixir_eval_no_such_registry, 42, {}, dead] do
        assert Authorization.revalidate(%{context | registry: registry}) == @denied
      end

      release(handle)
    end

    test "authorize captures a bad registry rather than falling back to the global one", %{
      fixture: fixture
    } do
      for registry <- [:elixir_eval_no_such_registry, 42, {}] do
        assert call(fixture, fn ->
                 Process.put(:evogit_task_registry_server, registry)
                 Authorization.authorize()
               end) == @denied
      end
    end

    test "registry death after capture cannot preserve authorization", %{fixture: fixture} do
      {handle, context} = held_context(fixture)
      assert stop_supervised(fixture.registry) == :ok
      assert Authorization.revalidate(context) == @denied
      release(handle)
    end

    test "a stalled isolated registry fails closed at its bounded lookup", %{fixture: fixture} do
      {handle, context} = held_context(fixture)
      registry = GenServer.whereis(fixture.registry)
      :ok = :sys.suspend(registry)
      on_exit(fn -> if Process.alive?(registry), do: :sys.resume(registry) end)
      assert Authorization.revalidate(context) == @denied
      :ok = :sys.resume(registry)
      assert Authorization.revalidate(context) == :ok
      release(handle)
    end
  end

  defp assert_cleanup_result(result, :shutdown, _fixture), do: assert(result == :ok)

  defp assert_cleanup_result(result, shutdown_reason, fixture) do
    supervisor = fixture.supervisor

    assert {:exit,
            {{^shutdown_reason, {:sys, :terminate, [^supervisor, :normal, :infinity]}},
             {GenServer, :stop, [^supervisor, :normal, :infinity]}}} = result

    # A failed stop must not pretend teardown succeeded or erase evidence.
    assert :ets.lookup(:evogit_agent_state, fixture.agent_id) != []
    assert :ets.lookup(:evogit_sched_meta, fixture.agent_id) != []
    assert Store.get_task(fixture.store, fixture.task_id) != nil
    assert Fixture.stop(fixture) == :ok
  end

  defp await_stop_request(supervisor, deadline) do
    {:messages, messages} = Process.info(supervisor, :messages)

    if Enum.any?(messages, fn
         {:system, _, {:terminate, :normal}} -> true
         _ -> false
       end) do
      :ok
    else
      assert System.monotonic_time(:millisecond) < deadline,
             "fixture cleanup did not enqueue its supervisor stop request"

      Process.sleep(1)
      await_stop_request(supervisor, deadline)
    end
  end

  defp authorize(fixture), do: call(fixture, &Authorization.authorize/0)
  defp call(fixture, fun), do: fixture |> Fixture.call_async(fun) |> Fixture.await()

  defp identity_keys do
    [:evogit_agent_id, :evogit_task_id, :evogit_agent_pid, :evogit_task_registry_server]
  end

  defp held_context(fixture) do
    test_pid = self()

    handle =
      Fixture.call_async(fixture, fn ->
        {:ok, context} = Authorization.authorize()
        send(test_pid, {:context, self(), context})
        hold_context(context)
      end)

    tool = handle.tool_pid
    assert_receive {:context, ^tool, context}, 15_000
    {handle, context}
  end

  defp hold_context(context) do
    receive do
      {:dictionary, test_pid} ->
        for key <- identity_keys(), do: Process.put(key, :forged)
        Process.put(:repo_less, false)
        send(test_pid, {:dictionary_changed, self(), Authorization.revalidate(context)})
        hold_context(context)

      :release ->
        :released
    end
  end

  defp release(handle) do
    send(handle.tool_pid, :release)
    assert Fixture.await(handle) == :released
  end
end

defmodule EvoGit.Agent.Tools.ElixirEval.AncestryTest do
  @moduledoc "Pure local process ancestry checks; no shared runtime state is changed."
  use ExUnit.Case, async: true

  alias EvoGit.Agent.Tools.ElixirEval.Ancestry

  test "real nested Tasks discover ancestors and the nearest broker" do
    # Broker markers are test-local; the ancestry itself is supplied by Task.
    Process.put(:evogit_eval_broker, self())
    owner = self()

    task =
      Task.async(fn ->
        assert Ancestry.includes?(self(), owner)
        assert Ancestry.broker(self()) == owner
        Process.put(:evogit_eval_broker, self())
        parent = self()

        Task.async(fn ->
          assert Ancestry.includes?(self(), owner)
          assert Ancestry.includes?(self(), parent)
          assert Ancestry.broker(self()) == parent
        end)
        |> Task.await()
      end)

    assert Task.await(task) == true
  end

  test "invalid and dead process identities are not ancestors or brokers" do
    {dead, ref} = spawn_monitor(fn -> :ok end)
    assert_receive {:DOWN, ^ref, :process, ^dead, :normal}, 15_000

    for pid <- [nil, :not_a_pid, 42, dead] do
      refute Ancestry.includes?(pid, self())
      refute Ancestry.includes?(self(), pid)
      assert Ancestry.broker(pid) == nil
    end
  end

  test "unrelated local processes and native links alone confer no ancestry" do
    owner = self()

    {pid, monitor} =
      spawn_monitor(fn ->
        Process.link(owner)

        send(
          owner,
          {:unrelated, self(), Ancestry.includes?(self(), owner), Ancestry.broker(self())}
        )
      end)

    assert_receive {:unrelated, ^pid, false, nil}, 15_000
    assert_receive {:DOWN, ^monitor, :process, ^pid, :normal}, 15_000
  end

  test "malformed runtime ancestry dictionaries are ignored and cycles terminate" do
    owner = self()

    {pid, monitor} =
      spawn_monitor(fn ->
        # Only negative robustness tests forge runtime ancestry dictionaries.
        Process.put(:"$callers", :malformed)
        Process.put(:"$ancestors", [self(), :not_a_pid, self()])
        Process.put(:evogit_eval_broker, :not_a_pid)
        send(owner, {:cycle, self(), Ancestry.includes?(self(), owner), Ancestry.broker(self())})
      end)

    assert_receive {:cycle, ^pid, false, nil}, 15_000
    assert_receive {:DOWN, ^monitor, :process, ^pid, :normal}, 15_000
  end
end
