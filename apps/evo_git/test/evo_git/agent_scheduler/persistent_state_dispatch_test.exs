defmodule EvoGit.AgentScheduler.PersistentStateDispatchTest.StubAgent do
  use EvoGit.Agent

  @doc "The role's fixed system prompt."
  def system_prompt, do: "You are the persistent-state dispatch test role."

  @doc "No tools: these tests stop at the worktree-create request."
  def available_tools, do: []
end

defmodule EvoGit.AgentScheduler.PersistentStateDispatchTest do
  @moduledoc """
  Pins the SCHEDULER-side threading of the per-task `:persistent_state` option
  into the session `dispatch_ctx`.

  ## What is pinned here
    * `Dispatch.do_try_dispatch/4` (through the public
      `Dispatch.try_dispatch/2`) resolves `:persistent_state` from
      `spec.opts` with a `true` default, and a FIRST attempt never restores:
      the dispatched session's context carries
      `persistent_state: true | true | false` and `restore_agent_state: false`
      for an ABSENT / `true` / `false` spec opt respectively;
    * a crash RETRY of the SAME agent id (`Lifecycle.handle_agent_crash/3`
      under `agent_max_retries: 3`) re-dispatches that id with `retries: 1`
      and `restore_agent_state: true` when the task is durable, and with BOTH
      flags `false` when the task opted out via `persistent_state: false` —
      the durability opt-out must survive the retry policy unchanged;
    * an INTERACTIVE session (`%SchedMeta{mode: :interactive}`) is NEVER
      retried: the crash is terminal, both rows are deleted, no session stays
      registered, and the root caller receives exactly
      `{:error, {:session_crashed, reason}}` (not the one-shot
      `:agent_max_retries_exceeded`).

  The dispatch context is read from the STARTED CHILD — its own `dispatch_ctx`
  field — while the session is parked on the worktree-create probe, so the
  assertion observes what the session actually received rather than a
  re-derivation of the scheduler's intent.

  ## Why `async: false`
  Two forcing GLOBALS:
    * the app-env seam `:worktree_create_fun`, read by the app-global
      `EvoGit.AgentScheduler.WorktreeManager` at create admission — a
      concurrently running module would observe this module's probe (and this
      module would observe a sibling's);
    * these tests start REAL `EvoGit.Agent.Session` processes under the
      APP-booted `EvoGit.Agent.Session.Supervisor`, registered in the shared
      `EvoGit.Agent.Session.Registry`.
  Every ETS row is per-test unique (`9_960_000 + System.unique_integer/1`) and
  deleted in `on_exit` with targeted deletes; no test wipes a table or asserts
  on table size. No global scheduler GenServer is started or mutated — the
  `%State{}` is a plain in-process value.
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

  @agent_id_base 9_960_000

  setup do
    root =
      Path.join(
        System.tmp_dir!(),
        "evogit_persistent_state_dispatch_#{:os.getpid()}_" <>
          "#{System.unique_integer([:positive])}"
      )

    File.mkdir_p!(root)

    old_create = Application.get_env(:evo_git, :worktree_create_fun)

    on_exit(fn ->
      restore_app_env(:worktree_create_fun, old_create)
      # Tolerant removal: a red run must not fail its own teardown.
      File.rm_rf(root)
    end)

    # Safety net: unless a test installs its own probe, ANY accidental session
    # start fails immediately (the session raises on the create error and dies)
    # instead of running an exchange or reaching a real LLM call.
    Application.put_env(:evo_git, :worktree_create_fun, &refusing_create/5)

    %{root: root}
  end

  describe "the dispatch context carries :persistent_state" do
    test "a first attempt never restores, and the flag defaults to true", %{root: root} do
      for {label, spec_opts, expected} <- [
            {"absent", [], true},
            {"true", [persistent_state: true], true},
            {"false", [persistent_state: false], false}
          ] do
        install_create_probe(self())
        {agent_id, state} = register(root, spec_opts: spec_opts)

        _state = Dispatch.try_dispatch(state, agent_id)

        # The create request belongs to the SESSION: receiving it proves the
        # session is alive and parked BEFORE any worktree I/O completes, so the
        # context read below is stable.
        assert_receive {:create_parked, create_task, ^agent_id, _worktree_path}, 5_000

        {:ok, meta} = Store.get_sched_meta(agent_id)
        assert is_pid(meta.session_pid)

        ctx = dispatch_ctx(meta.session_pid)

        assert ctx[:agent_id] == agent_id
        assert ctx[:retries] == 0
        assert ctx[:persistent_state] == expected, "persistent_state for #{label}"
        assert ctx[:restore_agent_state] == false, "restore_agent_state for #{label}"

        release_and_await(create_task, agent_id)
      end
    end
  end

  describe "a crash retry re-dispatches the SAME agent id" do
    test "restores the durable state when the task did not opt out", %{root: root} do
      install_create_probe(self())
      {agent_id, state} = register(root, spec_opts: [persistent_state: true])

      log =
        capture_log(fn ->
          assert {:noreply, %State{}} =
                   Lifecycle.handle_agent_crash(state, agent_id, {:error, :boom})
        end)

      assert log =~ "Retry 0/3"

      assert_receive {:create_parked, create_task, ^agent_id, _worktree_path}, 5_000

      {:ok, meta} = Store.get_sched_meta(agent_id)
      assert meta.retries == 1
      assert meta.status == :running
      assert is_pid(meta.session_pid)

      ctx = dispatch_ctx(meta.session_pid)

      assert ctx[:agent_id] == agent_id
      assert ctx[:retries] == 1
      assert ctx[:persistent_state] == true
      assert ctx[:restore_agent_state] == true

      release_and_await(create_task, agent_id)
    end

    test "keeps BOTH flags false when the task opted out", %{root: root} do
      install_create_probe(self())
      {agent_id, state} = register(root, spec_opts: [persistent_state: false])

      log =
        capture_log(fn ->
          assert {:noreply, %State{}} =
                   Lifecycle.handle_agent_crash(state, agent_id, {:error, :boom})
        end)

      assert log =~ "Retry 0/3"

      assert_receive {:create_parked, create_task, ^agent_id, _worktree_path}, 5_000

      {:ok, meta} = Store.get_sched_meta(agent_id)
      assert meta.retries == 1
      assert meta.status == :running
      assert is_pid(meta.session_pid)

      ctx = dispatch_ctx(meta.session_pid)

      assert ctx[:agent_id] == agent_id
      assert ctx[:retries] == 1
      assert ctx[:persistent_state] == false
      assert ctx[:restore_agent_state] == false

      release_and_await(create_task, agent_id)
    end
  end

  describe "an interactive session crash is terminal" do
    test "is never retried and replies the crash itself", %{root: root} do
      tag = make_ref()

      {agent_id, state} =
        register(root, spec_opts: [session_mode: :interactive], from: {self(), tag})

      {:ok, meta} = Store.get_sched_meta(agent_id)
      assert meta.mode == :interactive

      log =
        capture_log(fn ->
          assert {:noreply, %State{}} =
                   Lifecycle.handle_agent_crash(state, agent_id, {:error, :session_boom})
        end)

      assert log =~ "Interactive sessions are never retried"

      # The root caller receives the crash term, NOT `:agent_max_retries_exceeded`.
      assert_received {^tag, {:error, {:session_crashed, {:error, :session_boom}}}}

      # Terminal on the FIRST attempt: both rows gone and nothing re-dispatched.
      assert Store.get_sched_meta(agent_id) == :error
      assert Store.get_agent_state(agent_id) == :error
      assert Registry.lookup(Session.Registry, agent_id) == []
    end
  end

  # ---------------------------------------------------------------------------
  # Helpers
  # ---------------------------------------------------------------------------

  # The STARTED session's own dispatch context. `EvoGit.Agent.Session` is a
  # `gen_statem` with `handle_event_function`, so `:sys.get_state/1` answers
  # `{phase, data}`; the map-only clause keeps the helper total.
  defp dispatch_ctx(session_pid) do
    case :sys.get_state(session_pid) do
      {_phase, %{dispatch_ctx: ctx}} -> ctx
      %{dispatch_ctx: ctx} -> ctx
    end
  end

  defp unique_agent_id, do: @agent_id_base + System.unique_integer([:positive])

  defp register(root, opts) do
    agent_id = unique_agent_id()
    task_id = "task-persistent-state-#{System.unique_integer([:positive])}"
    spec_opts = Keyword.merge([model_id_locked: true], Keyword.get(opts, :spec_opts, []))

    # `model_id_locked: true` skips a user model-selection script, so the
    # resolved profile is deterministic even when the host has an agents.toml.
    spec = %AgentSpec{
      context_node: %ContextNode{path: "./", repo: root},
      phylo_node: %PhyloGraphNode{repo: root, base_commit: "abc123", current_commit: "abc123"},
      agent_module: EvoGit.AgentScheduler.PersistentStateDispatchTest.StubAgent,
      objective: "persistent state dispatch objective",
      repo_id: "primary",
      opts: spec_opts
    }

    state = %{
      State.from_model_profiles([
        %{id: "persistent-state-dispatch", model: "test:model", concurrency: 1}
      ])
      | next_agent_id: agent_id,
        agent_max_retries: 3
    }

    {^agent_id, state} =
      Dispatch.register_agent(state, spec, Keyword.get(opts, :from), nil, 0, task_id, 1)

    on_exit(fn ->
      # `on_exit` runs in a DIFFERENT process, so the captured id is passed to
      # the module API explicitly. The kill is the FAILURE-ONLY path: it keeps a
      # red run from leaking a live session and its parked create task.
      case Store.get_sched_meta(agent_id) do
        {:ok, %{session_pid: pid}} when is_pid(pid) -> Process.exit(pid, :kill)
        _other -> :ok
      end

      Store.delete_agent_state(agent_id)
      Store.delete_sched_meta(agent_id)
    end)

    {agent_id, state}
  end

  # The default create seam: refuse every create, so an accidental session
  # start in a test that did not install a probe dies immediately.
  defp refusing_create(_agent_id, _repo_root, _worktree_path, _spec, _meta) do
    {:error, {:worktree_create_failed, "no create expected in this test"}}
  end

  # A PARKED create probe: it reports the request it was handed and then waits
  # for `{:release, :materialize | :fail}`. The blocking wait is what makes the
  # context read a handshake (the session cannot progress past its create)
  # instead of a race.
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

  # Refusing the parked create makes the session's start task raise, so the
  # session dies through its crash path. The release MUST run inside
  # `capture_log/1`: the death logs from processes outside the test's logger
  # window otherwise.
  defp release_and_await(create_task, agent_id) do
    capture_log(fn ->
      send(create_task, {:release, :fail})
      wait_until(fn -> Registry.lookup(Session.Registry, agent_id) == [] end, 5_000)
    end)
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
