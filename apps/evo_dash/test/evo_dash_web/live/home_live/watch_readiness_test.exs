defmodule EvoDashWeb.HomeLive.WatchReadinessTest.Agent do
  use EvoGit.Agent
  def system_prompt, do: "Watch readiness fixture"
  def available_tools, do: []
end

defmodule EvoDashWeb.HomeLive.WatchReadinessTest do
  use ExUnit.Case, async: false

  alias EvoDash.NodeContext
  alias EvoDashWeb.HomeLive.Watch
  alias EvoGit.Agent.Session
  alias EvoGit.AgentScheduler.{AgentState, SchedMeta, Store}
  alias EvoGit.Core.{ContextNode, PhyloGraphNode}

  setup do
    old =
      for key <- [
            :home_agent_watch_runner,
            :home_agent_unwatch_runner,
            :home_agent_watch_start_timeout_ms
          ],
          into: %{},
          do: {key, Application.get_env(:evo_dash, key)}

    on_exit(fn ->
      for {key, value} <- old do
        if value == nil,
          do: Application.delete_env(:evo_dash, key),
          else: Application.put_env(:evo_dash, key, value)
      end
    end)

    :ok
  end

  test "a new real Session can finish slow setup before its first Watch snapshot" do
    parent = self()
    id = 98_000_000 + System.unique_integer([:positive])
    root = Path.join(System.tmp_dir!(), "watch_readiness_#{id}")
    worktree = Path.join(root, "worker")
    File.mkdir_p!(worktree)
    {_, 0} = System.cmd("git", ["init", "--quiet", root])
    context = %ContextNode{path: "./", repo: root}

    spec = %EvoGit.AgentSpec{
      context_node: context,
      phylo_node: %PhyloGraphNode{repo: root, base_commit: nil, current_commit: nil},
      agent_module: __MODULE__.Agent,
      objective: "first input",
      opts: [task_tmpdir: root]
    }

    meta = %SchedMeta{id: id, depth: 0, spec: spec, task_id: "watch-#{id}", task_number: 1}
    Store.put_sched_meta(id, meta)

    Store.put_agent_state(id, %AgentState{
      context_node: context,
      repo_root: root,
      parent_id: nil,
      archive: false,
      llm_model: nil,
      max_depth: nil,
      max_turns: 128,
      max_retries: 0,
      task_local_id: 1,
      llm_context_window: 200_000
    })

    original_create = Application.get_env(:evo_git, :worktree_create_fun)

    Application.put_env(:evo_git, :worktree_create_fun, fn ^id, _, ^worktree, _, _ ->
      send(parent, {:setup_held, self()})

      receive do
        :release_setup -> {:ok, worktree}
      after
        5000 -> {:error, :fixture_timeout}
      end
    end)

    ctx = [
      agent_id: id,
      depth: 0,
      repo_root: root,
      repo_id: "primary",
      worktree_path: worktree,
      retries: 0,
      spec: spec,
      meta: meta,
      scheduler: parent,
      session_mode: :interactive,
      exchange_opts: [
        llm_call: fn context, _, _, _, _ ->
          send(parent, {:model_entered, self()})

          receive do
            :finish_fixture ->
              answer = "Which project directory and task objective should I use?"

              message = %ReqLLM.Message{
                role: :assistant,
                content: [ReqLLM.Message.ContentPart.text(answer)]
              }

              response = %ReqLLM.Response{
                id: "watch-ready-answer",
                model: "test:model",
                context: ReqLLM.Context.append(context, message),
                message: message,
                usage: %{input_tokens: 10, output_tokens: 10, total_tokens: 20}
              }

              {:implicit_completion, response, answer}
          end
        end
      ]
    ]

    {:ok, session} = Session.start_link(ctx)
    Process.unlink(session)

    on_exit(fn ->
      Session.cancel(session, :force)
      await_manager_release(id, 100)

      if original_create == nil,
        do: Application.delete_env(:evo_git, :worktree_create_fun),
        else: Application.put_env(:evo_git, :worktree_create_fun, original_create)

      Store.delete_agent_state(id)
      Store.delete_sched_meta(id)
      File.rm_rf(root)
    end)

    assert_receive {:setup_held, setup_worker}, 3000
    on_exit(fn -> send(setup_worker, :release_setup) end)

    Application.put_env(:evo_dash, :home_agent_watch_runner, fn target, ^id, consumer ->
      result = NodeContext.register_agent_watcher(target, id, consumer)
      if result == {:error, {:bad_state, :starting}}, do: send(parent, :watch_observed_starting)
      result
    end)

    socket = socket(id) |> Watch.attach()

    on_exit(fn ->
      if Process.alive?(socket.assigns.chat_stream_worker),
        do: Process.exit(socket.assigns.chat_stream_worker, :kill)
    end)

    assert_receive :watch_observed_starting, 3000
    refute_receive {:chat_stream_ready, _, _, ^id, _}, 100
    send(setup_worker, :release_setup)
    assert_receive {:model_entered, model_worker}, 3000
    assert_receive {:chat_stream_ready, target, token, ^id, result}, 3000

    assert {:noreply, ready} =
             EvoDashWeb.HomeLive.handle_info(
               {:chat_stream_ready, target, token, id, result},
               socket
             )

    assert ready.assigns.chat_status == :running
    assert Watch.failure(ready.assigns) == nil
    assert Session.watching?(session)
    send(model_worker, :finish_fixture)
    settled = consume_until_idle(ready, id)
    assert settled.assigns.chat_status == :idle
    assert settled.assigns.chat_task_status == :awaiting_input

    assert Enum.any?(
             settled.assigns.transcript,
             &(&1.role == :assistant and
                 &1.text == "Which project directory and task objective should I use?")
           )

    refute Enum.any?(settled.assigns.transcript, &Map.get(&1, :streaming, false))
    assert {:ok, %{phase: :awaiting_input}} = Session.inspect(session)
    Watch.detach(settled)
  end

  test "detaching during setup cancels readiness retries without a late result" do
    parent = self()
    id = 98_000_000 + System.unique_integer([:positive])
    counter = :atomics.new(1, [])

    Application.put_env(:evo_dash, :home_agent_watch_runner, fn _, ^id, _ ->
      :atomics.add(counter, 1, 1)
      send(parent, :starting_attempt)
      {:error, {:bad_state, :starting}}
    end)

    Application.put_env(:evo_dash, :home_agent_unwatch_runner, fn _, _, _ -> :ok end)
    socket = socket(id) |> Watch.attach()
    on_exit(fn -> Process.exit(socket.assigns.chat_stream_worker, :kill) end)
    assert_receive :starting_attempt, 1000
    Watch.detach(socket)
    Process.sleep(100)
    count = :atomics.get(counter, 1)
    Process.sleep(100)
    assert :atomics.get(counter, 1) == count
    refute_receive {:chat_stream_ready, _, _, ^id, _}
  end

  test "ordinary errors fail once and diagnostic logs contain only the error category" do
    parent = self()
    id = 98_000_000 + System.unique_integer([:positive])

    Application.put_env(:evo_dash, :home_agent_watch_runner, fn _, ^id, _ ->
      send(parent, :failed_watch_attempt)
      {:error, {:transport_failure, "private provider detail"}}
    end)

    Application.put_env(:evo_dash, :home_agent_unwatch_runner, fn _, _, _ -> :ok end)

    logs =
      ExUnit.CaptureLog.capture_log(fn ->
        socket = socket(id) |> Watch.attach()
        assert_receive {:chat_stream_ready, _, _, ^id, _}, 1000
        assert_receive :failed_watch_attempt, 1000
        refute_receive :failed_watch_attempt, 100
        Process.exit(socket.assigns.chat_stream_worker, :kill)
      end)

    assert logs =~ "agent_id=#{id} reason=call_failed"
    refute logs =~ "private provider detail"
  end

  test "a session that stays starting reaches the deadline without an extra retry" do
    parent = self()
    id = 98_000_000 + System.unique_integer([:positive])
    Application.put_env(:evo_dash, :home_agent_watch_start_timeout_ms, 20)

    Application.put_env(:evo_dash, :home_agent_watch_runner, fn _, ^id, _ ->
      send(parent, :deadline_watch_attempt)
      {:error, {:bad_state, :starting}}
    end)

    Application.put_env(:evo_dash, :home_agent_unwatch_runner, fn _, _, _ -> :ok end)

    logs =
      ExUnit.CaptureLog.capture_log(fn ->
        socket = socket(id) |> Watch.attach()
        assert_receive :deadline_watch_attempt, 1000

        assert_receive {:chat_stream_ready, _, _, ^id, {:ok, {:error, {:bad_state, :starting}}}},
                       1000

        refute_receive :deadline_watch_attempt, 100
        Process.exit(socket.assigns.chat_stream_worker, :kill)
      end)

    assert logs =~ "reason=starting_timeout"
  end

  test "changing sessions cancels a pending startup registration" do
    parent = self()
    id = 98_000_000 + System.unique_integer([:positive])
    next_id = id + 1

    Application.put_env(:evo_dash, :home_agent_watch_runner, fn _, target, _ ->
      if target == id do
        send(parent, :old_session_starting)
        {:error, {:bad_state, :starting}}
      else
        {:ok, %EvoGit.Agent.Stream.Snapshot{agent_id: target, phase: :running}, 0}
      end
    end)

    Application.put_env(:evo_dash, :home_agent_unwatch_runner, fn _, _, _ -> :ok end)
    socket = socket(id) |> Watch.attach()
    assert_receive :old_session_starting, 1000
    changed = socket |> Phoenix.Component.assign(session_id: next_id) |> Watch.attach()
    assert_receive {:chat_stream_ready, _, _, ^next_id, {:ok, {:ok, _, 0}}}, 1000
    refute_receive {:chat_stream_ready, _, _, ^id, _}, 100
    Watch.detach(changed)
    Process.exit(socket.assigns.chat_stream_worker, :kill)
  end

  test "consumer death stops readiness retries and the serial registration worker" do
    parent = self()
    id = 98_000_000 + System.unique_integer([:positive])

    Application.put_env(:evo_dash, :home_agent_watch_runner, fn _, ^id, _ ->
      send(parent, :consumer_starting_attempt)
      {:error, {:bad_state, :starting}}
    end)

    consumer =
      spawn(fn ->
        socket = socket(id) |> Watch.attach()
        send(parent, {:readiness_worker, socket.assigns.chat_stream_worker})

        receive do
          :leave -> :ok
        end
      end)

    assert_receive {:readiness_worker, worker}, 1000
    assert_receive :consumer_starting_attempt, 1000
    monitor = Process.monitor(worker)
    send(consumer, :leave)
    assert_receive {:DOWN, ^monitor, :process, ^worker, :normal}, 1000
  end

  defp consume_until_idle(socket, id) do
    if socket.assigns.chat_status == :idle do
      socket
    else
      receive do
        {:agent_delta, ^id, _, _} = delta ->
          {:noreply, updated} = EvoDashWeb.HomeLive.handle_info(delta, socket)
          consume_until_idle(updated, id)
      after
        3000 -> flunk("the real session yield did not settle the assistant spinner")
      end
    end
  end

  defp await_manager_release(id, attempts) when attempts > 0 do
    if Map.has_key?(:sys.get_state(EvoGit.AgentScheduler.WorktreeManager).agents, id) do
      Process.sleep(10)
      await_manager_release(id, attempts - 1)
    end
  end

  defp await_manager_release(_, _), do: :ok

  defp socket(id) do
    %Phoenix.LiveView.Socket{
      transport_pid: self(),
      assigns: %{
        __changed__: %{},
        session_id: id,
        current_node: node(),
        current_node_id: nil,
        chat_stream: nil,
        stream_attach_seq: 0,
        chat_stream_worker: nil
      }
    }
  end
end
