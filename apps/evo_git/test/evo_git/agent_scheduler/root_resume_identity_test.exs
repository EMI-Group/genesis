defmodule EvoGit.AgentScheduler.RootResumeIdentityTest do
  @moduledoc """
  The ROOT-registration half of durable resume.

  Every durable read (`EvoGit.AgentState` rows, the transcript, the git anchor)
  is keyed `(task_id, agent_id)`, so a resumed run has to come back under the id
  its previous run PERSISTED. `AgentScheduler.register_root_agent/5` is the ONE
  helper both root registration sites (`handle_call({:run_agent, spec}, …)` and
  `do_start_session/2`) call: it passes `Dispatch.resume_registration_opts/1`
  (the `[agent_id: id]` of `spec.opts[:resume_agent_id]`) through
  `Dispatch.register_agent/8`, and DEGRADES to a fresh allocation with ONE
  `Logger.warning` when that id is still in use — `register_agent/8` fails
  closed with `{:error, {:agent_id_taken, id}}` BEFORE any ETS/counter mutation,
  so a taken id can never hijack a live agent.

  `async: true`: every test drives its OWN unnamed `EvoGit.AgentScheduler`
  instance (`GenServer.start/3` — the same idiom `agent_identity_test.exs` uses
  for its boot-seed cases), so the app-global scheduler is never touched, and
  the config directory is isolated PER PROCESS (`EvoGit.TestSupport.ConfigDir`),
  so that instance's `init/1` reads no developer config and loads no
  credentials. The rows it writes land in the app-global `:evogit_sched_meta` /
  `:evogit_agent_summary` tables under this module's own high id range
  (`70_100_0xx`) and are deleted BY ID in `on_exit`; nothing here asserts on a
  table as a whole, so a concurrently running module can never observe them.

  The injected instance state is `paused: true`, so the `{:run_agent, spec}`
  handler REGISTERS the root and then QUEUES it: no session is started, no
  worktree is created and no LLM is called. Registration (which happens BEFORE
  the paused branch) is exactly what these tests are about.
  """
  use ExUnit.Case, async: true

  @moduletag :tmp_dir

  import ExUnit.CaptureLog

  alias EvoGit.AgentScheduler.AgentState
  alias EvoGit.AgentScheduler.Dispatch
  alias EvoGit.AgentScheduler.SchedMeta
  alias EvoGit.AgentScheduler.State
  alias EvoGit.AgentScheduler.Store
  alias EvoGit.AgentSpec
  alias EvoGit.Core.ContextNode
  alias EvoGit.Core.PhyloGraphNode

  # A valid `EvoGit.Agent` role — never run (nothing in this module starts a
  # session or reaches a model).
  defmodule DummyAgent do
    use EvoGit.Agent
    def available_tools, do: []
  end

  # The id a PAUSED run persisted for this task's ROOT (`:resume_agent_id`) and
  # the counter the fresh instance is seeded with. The counter sits BELOW the
  # persisted id on purpose: an adoption has to win over allocation, and the
  # degraded case has to fall back to exactly the counter's value.
  @resumed_id 70_100_007
  @counter 70_100_001

  setup do
    # Per-PROCESS config dir: the scheduler instance started below inherits it
    # through `$callers`, so its `init/1` resolves an empty config directory
    # rather than this machine's real `~/.config/genesis`.
    EvoGit.TestSupport.ConfigDir.isolate!("evogit_root_resume")
    :ok
  end

  describe "the ROOT registration site adopts a persisted agent id" do
    test "a resumed one-shot root is registered under its persisted id", %{
      tmp_dir: dir
    } do
      task_id = unique_task_id("oneshot-resume")
      scheduler = start_scheduler!()

      dispatch_root!(scheduler, resumed_spec(dir, task_id))

      # The registered row IS the persisted identity — a fresh allocation would
      # have landed on @counter instead.
      assert wait_for_registered_id(task_id) == @resumed_id

      assert {:ok, %SchedMeta{id: @resumed_id, depth: 0, task_id: ^task_id, spec: stored}} =
               Store.get_sched_meta(@resumed_id)

      assert Store.get_sched_meta(@counter) == :error

      # The resume facts survived registration, so the dispatch can still resolve
      # the branch and the durable row by the SAME identity.
      assert %AgentSpec{opts: stored_opts} = stored
      assert Keyword.get(stored_opts, :resume_agent_id) == @resumed_id
      assert Keyword.get(stored_opts, :resume_kind) == :clean_pause

      assert {:ok, %AgentState{parent_id: nil, task_local_id: 1}} =
               Store.get_agent_state(@resumed_id)

      # The counter only ever moves PAST an adopted id.
      assert %State{next_agent_id: next} = :sys.get_state(scheduler)
      assert next == @resumed_id + 1

      cleanup_agent(@resumed_id)
    end

    test "a resumed INTERACTIVE root is registered under its persisted id too", %{
      tmp_dir: dir
    } do
      task_id = unique_task_id("interactive-resume")
      scheduler = start_scheduler!()

      # The public `start_session/1` entrance forces the interactive mode before
      # the call, so mirror it exactly.
      assert {:ok, spec} =
               EvoGit.AgentScheduler.SessionOpts.force_interactive(resumed_spec(dir, task_id))

      # `do_start_session/2` is the OTHER root registration site and answers
      # synchronously, so the id it registered is observable directly.
      assert {:ok, @resumed_id} = GenServer.call(scheduler, {:start_session, spec}, 5_000)

      assert {:ok, %SchedMeta{id: @resumed_id, task_id: ^task_id, mode: :interactive}} =
               Store.get_sched_meta(@resumed_id)

      assert Store.get_sched_meta(@counter) == :error

      cleanup_agent(@resumed_id)
    end
  end

  describe "a persisted id that is still in use degrades" do
    test "the root registers under a fresh id, untouched owner, ONE warning", %{
      tmp_dir: dir
    } do
      task_id = unique_task_id("taken")
      scheduler = start_scheduler!()

      # A LIVE holder under the persisted id — the authority `Dispatch` consults
      # (`EvoGit.Agent.Session.Registry`), exactly the mechanism a real session
      # uses.
      holder = hold_agent_id!(@resumed_id)

      output =
        capture_log(fn ->
          dispatch_root!(scheduler, resumed_spec(dir, task_id))
          assert wait_for_registered_id(task_id) != @resumed_id
        end)

      # ONE warning, naming the persisted id and the task it belongs to.
      assert output =~ "persisted agent id #{@resumed_id}"
      assert output =~ "is still in use"
      assert output =~ inspect(task_id)

      # The run still happens — under a FRESH id from the ordinary allocation.
      assert wait_for_registered_id(task_id) == @counter

      assert {:ok, %SchedMeta{id: @counter, task_id: ^task_id, depth: 0}} =
               Store.get_sched_meta(@counter)

      # FAIL CLOSED for the taken id: no scheduler row, no agent row, and the
      # pre-existing owner is untouched.
      assert Store.get_sched_meta(@resumed_id) == :error
      assert Store.get_agent_state(@resumed_id) == :error
      assert {:ok, ^holder} = EvoGit.Agent.Session.whereis(@resumed_id)
      assert Process.alive?(holder)

      cleanup_agent(@counter)
    end
  end

  describe "ordinary dispatch is unchanged" do
    test "a ROOT spec without a resume id allocates a fresh id", %{tmp_dir: dir} do
      task_id = unique_task_id("plain")
      scheduler = start_scheduler!()

      dispatch_root!(scheduler, spec(dir, task_id: task_id))

      assert wait_for_registered_id(task_id) == @counter

      assert {:ok, %SchedMeta{id: @counter, task_id: ^task_id, depth: 0, spec: stored}} =
               Store.get_sched_meta(@counter)

      # Nothing from the resume path leaks into an ordinary registration.
      assert %AgentSpec{opts: stored_opts} = stored
      refute Keyword.has_key?(stored_opts, :resume_agent_id)

      assert %State{next_agent_id: next} = :sys.get_state(scheduler)
      assert next == @counter + 1

      cleanup_agent(@counter)
    end
  end

  describe "Dispatch.resume_registration_opts/1" do
    test "passes a positive persisted id through", %{tmp_dir: dir} do
      assert Dispatch.resume_registration_opts(
               spec(dir, task_id: unique_task_id("opts"), resume_agent_id: 7)
             ) == [agent_id: 7]
    end

    test "answers no opts for an absent or invalid id, and is total", %{tmp_dir: dir} do
      task_id = unique_task_id("opts-invalid")
      assert Dispatch.resume_registration_opts(spec(dir, task_id: task_id)) == []

      for bogus <- [nil, 0, -1, "7"] do
        assert Dispatch.resume_registration_opts(
                 spec(dir, task_id: task_id, resume_agent_id: bogus)
               ) == [],
               "expected no registration opts for #{inspect(bogus)}"
      end

      # A non-spec input is total as well: only a real spec's opts are read.
      assert Dispatch.resume_registration_opts(%{opts: [resume_agent_id: 11]}) == []
      assert Dispatch.resume_registration_opts(nil) == []
      assert Dispatch.resume_registration_opts(%{}) == []
      assert Dispatch.resume_registration_opts(:nope) == []
    end
  end

  # --- Fixtures ------------------------------------------------------------

  # A spec whose ROOT was PAUSED in a previous run: the resume facts
  # `EvoGit.TaskRegistry.ResumeContext` threads onto the re-enqueued root.
  defp resumed_spec(dir, task_id) do
    spec(dir,
      task_id: task_id,
      resume_agent_id: @resumed_id,
      resume_branch: "evogit-agent-T2-A1",
      resume_kind: :clean_pause
    )
  end

  defp spec(dir, opts) do
    task_id = Keyword.fetch!(opts, :task_id)
    extra_opts = Keyword.delete(opts, :task_id)

    %AgentSpec{
      context_node: %ContextNode{path: "./", repo: dir},
      phylo_node: %PhyloGraphNode{repo: dir, base_commit: "abc123", current_commit: "abc123"},
      agent_module: DummyAgent,
      objective: "root resume identity test",
      repo_id: "primary",
      # A locked legacy selection skips the user model-selection script, so a
      # developer's own agents.toml can never change the resolved selection.
      opts: [model_id_locked: true, task_id: task_id] ++ extra_opts
    }
  end

  # One UNNAMED scheduler instance (the application already owns the registered
  # name), with the model pool this file's specs resolve against and the counter
  # this file's ids are aligned to. PAUSED: the `{:run_agent, spec}` handler
  # registers and then QUEUES, so no session/worktree/LLM work happens.
  defp start_scheduler! do
    {:ok, pid} = GenServer.start(EvoGit.AgentScheduler, [])
    Process.unlink(pid)

    on_exit(fn -> if Process.alive?(pid), do: GenServer.stop(pid, :normal, 5_000) end)

    :sys.replace_state(pid, fn _state ->
      %{
        State.from_model_profiles([%{id: "default", model: "provider:default"}])
        | next_agent_id: @counter,
          paused: true
      }
    end)

    pid
  end

  # A caller BLOCKED in the production root entrance. With the scheduler paused
  # the handler registers the root and then queues it, so the `GenServer.call`
  # never returns; the caller is killed at test exit rather than promised a
  # terminal term this fixture deliberately never produces.
  defp dispatch_root!(scheduler, spec) do
    caller = spawn(fn -> GenServer.call(scheduler, {:run_agent, spec}, :infinity) end)
    on_exit(fn -> Process.exit(caller, :kill) end)
    caller
  end

  # A live holder under `agent_id` — the SAME mechanism a real session uses
  # (`EvoGit.Agent.Session.Registry`, `keys: :unique`), which is the authority
  # `Dispatch` consults before adopting an id.
  defp hold_agent_id!(agent_id) do
    test_pid = self()

    holder =
      spawn(fn ->
        {:ok, _} = Registry.register(EvoGit.Agent.Session.Registry, agent_id, nil)
        send(test_pid, {:held, agent_id})

        receive do
          :stop -> :ok
        end
      end)

    assert_receive {:held, ^agent_id}, 1_000
    on_exit(fn -> send(holder, :stop) end)
    assert {:ok, ^holder} = EvoGit.Agent.Session.whereis(agent_id)
    holder
  end

  # The agent id registered for `task_id`, awaited event-driven (a bounded poll
  # whose beat starts at 1 ms and doubles to a 15 ms cap — only the interval
  # shrinks, never the deadline or an assertion).
  defp wait_for_registered_id(task_id) do
    wait_until(fn -> registered_id(task_id) != nil end)

    case registered_id(task_id) do
      nil -> flunk("no agent was registered for task #{inspect(task_id)}")
      id -> id
    end
  end

  defp registered_id(task_id) do
    Store.list_sched_meta()
    |> Enum.find_value(fn
      {id, %SchedMeta{task_id: ^task_id}} -> id
      _other_row -> nil
    end)
  end

  defp wait_until(fun, timeout \\ 5_000) do
    deadline = System.monotonic_time(:millisecond) + timeout
    do_wait_until(fun, deadline, timeout, 1)
  end

  defp do_wait_until(fun, deadline, original_timeout, interval) do
    cond do
      fun.() ->
        :ok

      System.monotonic_time(:millisecond) >= deadline ->
        flunk("condition not met within #{original_timeout}ms")

      true ->
        beat = min(interval, 15)
        Process.sleep(beat)
        do_wait_until(fun, deadline, original_timeout, beat * 2)
    end
  end

  defp unique_task_id(label), do: "#{label}-#{System.unique_integer([:positive])}"

  # Targeted cleanup: the app-global ETS tables outlive the test process, so the
  # EXACT ids this module wrote are deleted (never a wholesale wipe).
  defp cleanup_agent(agent_id) do
    on_exit(fn ->
      Store.delete_agent_state(agent_id)
      Store.delete_sched_meta(agent_id)
    end)
  end
end
