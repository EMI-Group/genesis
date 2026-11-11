defmodule EvoGit.AgentScheduler.SessionDispatchTest do
  @moduledoc """
  Pins the SESSION-based dispatch contract of `EvoGit.AgentScheduler.Dispatch`.

  Every agent now runs inside ONE `EvoGit.Agent.Session` process started under
  `EvoGit.Agent.Session.Supervisor` and registered in
  `EvoGit.Agent.Session.Registry` — never a bare
  `Task.Supervisor.async_nolink` run. The scheduler phase monitors the session,
  keys `ref_to_agent` on that monitor ref, mirrors `session_pid` / `mode` /
  `phase` on the `%SchedMeta{}` row, and admits the session's ONE
  `{:agent_session_result, agent_id, session_pid, result}` message.

  ## What is pinned here
    * `Dispatch.try_dispatch/2` starts the session, records `session_pid` +
      `phase: :starting` + `status: :running` on the sched-meta row, maps the
      session monitor ref to the agent id in `ref_to_agent`, and performs NO
      worktree I/O itself — the parked create probe proves the create request
      belongs to the SESSION, not to the scheduler;
    * a dispatched run executes as an exchange, delivers exactly ONE terminal
      `{:agent_session_result, ...}` to the dispatching process (`:scheduler` in
      the dispatch context) and recycles itself;
    * `Lifecycle.handle_agent_down/4` recycles on a `:normal` exit — both ETS
      rows gone, no retry;
    * a session START FAILURE (`:session_supervisor_not_started`) is routed
      through the bounded crash-retry path and ends in the documented
      `{:error, :agent_max_retries_exceeded}` reply instead of dropping the
      agent.

  ## Why `async: false`
  Three forcing GLOBALS:
    * the app-env seam `:worktree_create_fun`, read by the app-global
      `EvoGit.AgentScheduler.WorktreeManager` at create admission — a
      concurrently running module would observe this module's probe;
    * the app-env seam `:agent_exchange_llm_call`, read by EVERY session's
      exchange worker — it changes what an unrelated module's agent would send;
    * `EvoGit.Agent.Session.Supervisor` (an APP-booted `DynamicSupervisor`) is
      terminated for the start-failure case and restarted in `on_exit`.
  Every ETS row is per-test unique (`9_950_000 + unique_integer`) and deleted in
  `on_exit`; no test wipes a table, asserts on table size, or mutates the global
  scheduler's configuration.
  The `:checkpoint` seam is not used here: the summary row is the session's own
  read model and is not what this module pins.
  """

  use ExUnit.Case, async: false

  import ExUnit.CaptureLog

  alias EvoGit.Agent.Session
  alias EvoGit.AgentScheduler.Dispatch
  alias EvoGit.AgentScheduler.Lifecycle
  alias EvoGit.AgentScheduler.State
  alias EvoGit.AgentScheduler.Store
  alias EvoGit.AgentSpec
  alias EvoGit.Core.ContextNode
  alias EvoGit.Core.PhyloGraphNode

  @agent_id_base 9_950_000

  # A minimal `EvoGit.Agent` role. Dispatch never calls `run/2` any more — the
  # session builds the state from these callbacks and drives the exchange — so
  # the role is exactly a system prompt plus an EMPTY tool list (the scripted
  # model never asks for a tool).
  defmodule FakeAgent do
    use EvoGit.Agent

    @doc "The role's fixed system prompt."
    def system_prompt, do: "You are the session-dispatch test role."

    @doc "No tools: the scripted model always answers in plain text."
    def available_tools, do: []
  end

  setup do
    root =
      Path.join(
        System.tmp_dir!(),
        "evogit_session_dispatch_#{System.unique_integer([:positive])}"
      )

    File.mkdir_p!(root)

    old_create = Application.get_env(:evo_git, :worktree_create_fun)
    old_llm = Application.get_env(:evo_git, :agent_exchange_llm_call)

    on_exit(fn ->
      restore_app_env(:worktree_create_fun, old_create)
      restore_app_env(:agent_exchange_llm_call, old_llm)
      restart_session_supervisor()
      File.rm_rf!(root)
    end)

    # Safety net: unless a test scripts the create pipeline itself, ANY
    # accidental session start fails immediately (the session raises on the
    # create error and dies) — so no test in this module can reach a real LLM
    # call by accident.
    Application.put_env(:evo_git, :worktree_create_fun, &refusing_create/5)

    %{root: root}
  end

  describe "try_dispatch/2 starts the agent session" do
    test "registers the session and records it on the sched-meta row", %{root: root} do
      install_create_probe(self())
      {agent_id, state} = register(root)

      state = Dispatch.try_dispatch(state, agent_id)

      # The create request belongs to the SESSION: the probe runs inside
      # WorktreeManager's create task for THIS agent and path, and the
      # dispatched worktree does not exist while it is parked — i.e. the
      # scheduler's dispatch phase performed no worktree I/O at all.
      assert_receive {:create_parked, create_task, ^agent_id, worktree_path}, 5_000
      assert worktree_path == Path.join([root, ".genesis/workers", "worker_T1_A1"])
      refute File.exists?(worktree_path)

      {:ok, meta} = Store.get_sched_meta(agent_id)

      assert meta.status == :running
      assert meta.phase == :starting
      assert meta.mode == :oneshot
      assert is_pid(meta.session_pid)
      assert meta.worktree == worktree_path
      refute meta.result_sent

      # The recorded pid IS the session: registered under its agent id.
      assert [{session_pid, _value}] = Registry.lookup(Session.Registry, agent_id)
      assert session_pid == meta.session_pid
      assert Process.alive?(session_pid)

      # `ref_to_agent` is keyed on the SESSION MONITOR ref, and there is
      # exactly one dispatch in flight.
      assert map_size(state.ref_to_agent) == 1
      [ref] = Map.keys(state.ref_to_agent)
      assert is_reference(ref)
      assert Map.fetch!(state.ref_to_agent, ref) == agent_id

      # Refusing the parked create ends the session through its crash path (a
      # `:DOWN` the scheduler would crash-retry); the session is gone.
      capture_log(fn ->
        send(create_task, {:release, :fail})
        wait_until(fn -> Registry.lookup(Session.Registry, agent_id) == [] end, 5_000)
      end)

      refute Process.alive?(session_pid)
    end

    test "the dispatched run delivers exactly ONE terminal result to the scheduler pid",
         %{root: root} do
      # The REAL create pipeline runs here: the completion path reads the
      # worktree's HEAD, so the dispatcher's repo must be a genuine git repo.
      {:ok, sha} = init_repo(root)
      # Drop the safety-net seam so the manager's REAL create pipeline runs.
      Application.delete_env(:evo_git, :worktree_create_fun)
      install_llm_script(self(), "session dispatch report")
      {agent_id, state} = register(root, base_sha: sha)

      state = Dispatch.try_dispatch(state, agent_id)
      assert map_size(state.ref_to_agent) == 1

      {:ok, meta} = Store.get_sched_meta(agent_id)
      assert is_pid(meta.session_pid)
      worktree_path = meta.worktree

      assert_receive {:agent_session_result, ^agent_id, session_pid,
                      {:ok, %EvoGit.Agent.Result{} = result}},
                     30_000

      assert session_pid == meta.session_pid
      assert result.result == "session dispatch report"
      # The SESSION created the worktree (dispatch never does): the exchange
      # worker's own repo path IS the dispatched worktree, and it is a real
      # checkout of the dispatcher's repo at the dispatched base commit. The
      # check runs INSIDE the seam, so it can never race the worktree's
      # monitor-driven reclamation.
      assert_receive {:llm_called, ^worktree_path, {:ok, ^sha}}, 5_000

      # Exactly ONE terminal fact, then the session stops and unregisters.
      refute_receive {:agent_session_result, ^agent_id, _pid, _result}, 300
      wait_until(fn -> Registry.lookup(Session.Registry, agent_id) == [] end, 5_000)
      refute Process.alive?(session_pid)

      # Monitor-driven reclamation: the session's death releases the worktree.
      wait_until(fn -> not File.exists?(worktree_path) end, 10_000)
    end

    test "a session start failure is retried within the bound, never dropped", %{root: root} do
      # A runtime WITHOUT the application tree has no session supervisor; that
      # is the ONE prerequisite dispatch cannot provide, so a session start
      # fails with `:session_supervisor_not_started`.
      assert :ok = Supervisor.terminate_child(EvoGit.Supervisor, Session.Supervisor)
      assert Process.whereis(EvoGit.Agent.Session.Supervisor) == nil
      on_exit(fn -> restart_session_supervisor() end)

      tag = make_ref()
      {agent_id, state} = register(root, from: {self(), tag}, agent_max_retries: 1)

      log =
        capture_log(fn ->
          _state = Dispatch.try_dispatch(state, agent_id)

          # The root caller is replied the documented permanent-failure error.
          assert_receive {^tag, {:error, :agent_max_retries_exceeded}}, 5_000
        end)

      # The failure was routed through the crash-retry path with ONE retry and
      # then the bound: never an unbounded retry storm.
      assert log =~ "failed to start session for agent #{agent_id}"
      assert log =~ ":session_supervisor_not_started"
      assert log =~ "Agent #{agent_id} crashed"
      assert log =~ "Retry 0/1"
      assert log =~ "failed after 1 retries"

      # BOUNDED: exactly TWO start attempts (the initial one plus the single
      # allowed retry) — never an unbounded retry storm.
      assert length(String.split(log, "Agent #{agent_id} crashed")) - 1 == 2

      # Permanent failure removes BOTH rows and starts nothing.
      assert Store.get_sched_meta(agent_id) == :error
      assert Store.get_agent_state(agent_id) == :error
      assert Registry.lookup(Session.Registry, agent_id) == []
    end
  end

  describe "Lifecycle.handle_agent_down/4" do
    test "a :normal session exit recycles the agent without a retry", %{root: root} do
      {agent_id, state} = register(root)
      session_pid = self()
      ref = make_ref()

      # The dispatch-time shape: `:running` with the session recorded, and the
      # monitor ref driving `ref_to_agent`.
      {:ok, meta} = Store.get_sched_meta(agent_id)

      Store.put_sched_meta(agent_id, %{
        meta
        | status: :running,
          session_pid: session_pid,
          phase: :starting
      })

      state = %{state | ref_to_agent: %{ref => agent_id}}

      log =
        capture_log(fn ->
          assert {:noreply, %State{} = state} =
                   Lifecycle.handle_agent_down(ref, session_pid, :normal, state)

          assert state.ref_to_agent == %{}
          # Both rows are gone: recycle is terminal, and a retry would have
          # re-created a `:pending` row instead.
          assert Store.get_sched_meta(agent_id) == :error
          assert Store.get_agent_state(agent_id) == :error
        end)

      refute log =~ "Agent #{agent_id} crashed"
      # Nothing was re-dispatched: no session exists for the agent.
      assert Registry.lookup(Session.Registry, agent_id) == []
    end
  end

  # ---------------------------------------------------------------------------
  # Helpers
  # ---------------------------------------------------------------------------

  defp unique_agent_id, do: @agent_id_base + System.unique_integer([:positive])

  defp register(root, opts \\ []) do
    agent_id = unique_agent_id()
    task_id = "task-session-dispatch-#{System.unique_integer([:positive])}"
    base_sha = Keyword.get(opts, :base_sha, "abc123")

    # `model_id_locked: true` skips a user model-selection script, so the
    # resolved profile is deterministic even when the host has an agents.toml.
    spec = %AgentSpec{
      context_node: %ContextNode{path: "./", repo: root},
      phylo_node: %PhyloGraphNode{repo: root, base_commit: base_sha, current_commit: base_sha},
      agent_module: FakeAgent,
      objective: "session dispatch objective",
      repo_id: "primary",
      opts: [model_id_locked: true]
    }

    state = %{
      State.from_model_profiles([%{id: "session-dispatch", model: "test:model", concurrency: 1}])
      | next_agent_id: agent_id,
        agent_max_retries: Keyword.get(opts, :agent_max_retries, 3)
    }

    {^agent_id, state} =
      Dispatch.register_agent(state, spec, Keyword.get(opts, :from), nil, 0, task_id, 1)

    on_exit(fn ->
      Store.delete_agent_state(agent_id)
      Store.delete_sched_meta(agent_id)
    end)

    {agent_id, state}
  end

  # One committed commit in a fresh repo, so the REAL create pipeline and the
  # completion path's `rev_parse` have a git repository to work on.
  defp init_repo(root) do
    alias EvoGit.Adapters.Git

    {:ok, _} = Git.init(root)
    File.write!(Path.join(root, "README.md"), "initial\n")
    {:ok, _} = Git.add(root)
    {:ok, _} = Git.commit(root, "initial")
    Git.rev_parse(root)
  end

  # The default create seam: refuse every create, so an accidental session
  # start in a test that did not install a probe dies immediately (the session
  # raises on the create error) instead of running an exchange.
  defp refusing_create(_agent_id, _repo_root, _worktree_path, _spec, _meta) do
    {:error, {:worktree_create_failed, "no create expected in this test"}}
  end

  # A PARKED create probe: it reports the request it was handed (so the create
  # can be attributed to the session's dispatch rather than to the scheduler)
  # and then waits for `{:release, :materialize | :fail}`. The blocking wait is
  # what makes "the scheduler performed no worktree I/O" a handshake instead of
  # a race.
  defp install_create_probe(test_pid) do
    fun = fn agent_id, _repo_root, worktree_path, _spec, _meta ->
      send(test_pid, {:create_parked, self(), agent_id, worktree_path})

      receive do
        {:release, :materialize} ->
          File.mkdir_p!(worktree_path)
          {:ok, worktree_path}

        {:release, :fail} ->
          {:error, {:worktree_create_failed, "probe refused the create"}}
      after
        10_000 -> {:error, {:worktree_create_failed, "probe timed out"}}
      end
    end

    Application.put_env(:evo_git, :worktree_create_fun, fun)
    fun
  end

  # The app-env engine seam every session's exchange worker reads: a plain-text
  # reply with no tool calls ENDS the run, and its text is the report.
  defp install_llm_script(test_pid, text) do
    Application.put_env(
      :evo_git,
      :agent_exchange_llm_call,
      fn context, _tools, _params, _agent_id, _retries ->
        # Report the WORKER's own worktree identity and HEAD from inside the
        # run: that is the only place where both are guaranteed to still exist.
        repo_path = Process.get(:repo_path)
        send(test_pid, {:llm_called, repo_path, EvoGit.Adapters.Git.rev_parse(repo_path)})
        {:implicit_completion, response(context, text), text}
      end
    )
  end

  defp response(context, text) do
    message = %ReqLLM.Message{
      role: :assistant,
      content: [ReqLLM.Message.ContentPart.text(text)],
      tool_calls: nil
    }

    %ReqLLM.Response{
      id: "session-dispatch-response",
      model: "test:model",
      context: ReqLLM.Context.append(context, message),
      message: message,
      usage: %{input_tokens: 10, output_tokens: 2, total_tokens: 12}
    }
  end

  defp restart_session_supervisor do
    if Process.whereis(EvoGit.Agent.Session.Supervisor) == nil do
      {:ok, _pid} = Supervisor.restart_child(EvoGit.Supervisor, EvoGit.Agent.Session.Supervisor)
    end

    :ok
  end

  defp restore_app_env(key, nil), do: Application.delete_env(:evo_git, key)
  defp restore_app_env(key, value), do: Application.put_env(:evo_git, key, value)

  defp wait_until(fun, timeout) do
    deadline = System.monotonic_time(:millisecond) + timeout
    do_wait_until(fun, deadline, timeout)
  end

  defp do_wait_until(fun, deadline, original_timeout) do
    cond do
      fun.() ->
        :ok

      System.monotonic_time(:millisecond) >= deadline ->
        flunk("condition not met within #{original_timeout}ms")

      true ->
        Process.sleep(5)
        do_wait_until(fun, deadline, original_timeout)
    end
  end
end
