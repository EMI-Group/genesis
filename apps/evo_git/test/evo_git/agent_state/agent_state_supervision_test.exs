defmodule EvoGit.AgentState.SupervisionTest do
  @moduledoc """
  CONTAINMENT coverage for the durable agent-state subsystem: a broken data dir
  starts a DEGRADED writer (never a fatal boot), the writer retries with
  backoff and RECOVERS once the directory becomes writable, a repo death is
  handled explicitly (degrade + reboot, never a live server on a dead repo),
  and the subsystem's own supervisor absorbs repeated writer crashes.

  Every case starts its OWN `EvoGit.AgentState` supervisor on a per-test
  database with a SHORT retry budget, so no test waits on wall-clock backoff
  beyond a bounded poll. The app-global `EvoGit.AgentState.Server` is never
  touched — hence `async: true`.
  """

  use ExUnit.Case, async: true
  import ExUnit.CaptureLog

  alias EvoGit.AgentState

  @moduletag :tmp_dir

  @poll_interval 10
  @poll_timeout 5_000

  ## Isolation helpers (duplicated per file on purpose: no shared support module)

  defp start_store!(tmp_dir, opts \\ []) do
    start_supervised!(
      {EvoGit.AgentState,
       Keyword.merge(
         [
           database: Path.join(tmp_dir, "agent_state.sqlite"),
           name: nil,
           prune_interval: 3_600_000,
           boot_retry_base: 20,
           boot_retry_max: 40
         ],
         opts
       )}
    )
  end

  # The isolated instance pid is a SUPERVISOR pid; its writer is the one child.
  defp server_pid(supervisor) do
    supervisor
    |> Supervisor.which_children()
    |> Enum.find_value(fn
      {EvoGit.AgentState.Server, pid, :worker, _modules} when is_pid(pid) -> pid
      _other -> nil
    end)
  end

  defp await(fun, timeout \\ @poll_timeout) do
    deadline = System.monotonic_time(:millisecond) + timeout
    do_await(fun, deadline)
  end

  defp do_await(fun, deadline) do
    case fun.() do
      {:ok, value} ->
        value

      :retry ->
        if System.monotonic_time(:millisecond) >= deadline do
          flunk("condition not met within #{@poll_timeout} ms")
        else
          Process.sleep(@poll_interval)
          do_await(fun, deadline)
        end
    end
  end

  defp message(text),
    do: %ReqLLM.Message{role: :user, content: [ReqLLM.Message.ContentPart.text(text)]}

  defp rewrite(messages),
    do: %{kind: :rewrite, messages: messages, fields: %{status: "running"}}

  ## 1. Non-fatal boot

  test "a broken data dir boots DEGRADED, every API stays total, and a retry RECOVERS",
       %{tmp_dir: tmp_dir} do
    # A database inside a path whose PARENT is a regular file: `mkdir_p` can
    # never succeed, so the boot fails on every attempt (reliable as root too).
    blocker = Path.join(tmp_dir, "blocker")
    File.write!(blocker, "not a directory")
    database = Path.join(blocker, "agent_state.sqlite")

    log =
      capture_log(fn ->
        supervisor = start_store!(tmp_dir, database: database, name: nil)
        assert Process.alive?(supervisor)

        server = await(fn -> if pid = server_pid(supervisor), do: {:ok, pid}, else: :retry end)
        assert Process.alive?(server)
        assert Process.alive?(supervisor)

        # DEGRADED but total: no public call raises and none claims durability.
        assert AgentState.repo(supervisor) == nil

        assert :ok =
                 AgentState.checkpoint("task-broken", 1, rewrite([message("dropped")]),
                   store: supervisor
                 )

        assert {:error, :store_unavailable} = AgentState.load("task-broken", 1, store: supervisor)
        assert AgentState.pause_commit("task-broken", 1, store: supervisor) == nil
        assert AgentState.resumable?("task-broken", store: supervisor) == false
        assert AgentState.root_agent_ids("task-broken", store: supervisor) == []
        assert {:ok, 0} = AgentState.prune(store: supervisor)
        assert {:error, :timeout} = AgentState.flush(store: supervisor)
        assert :ok = AgentState.mark_completed("task-broken", 1, store: supervisor)
        assert :ok = AgentState.delete("task-broken", 1, store: supervisor)
        assert :ok = AgentState.delete_task("task-broken", store: supervisor)
        assert :ok = AgentState.delete_tasks(["task-broken"], store: supervisor)

        # Several retry ticks have happened (the timer keeps rescheduling).
        Process.sleep(120)
        assert Process.alive?(server)
        assert AgentState.repo(supervisor) == nil

        # The directory becomes writable: the SAME server recovers on a retry.
        File.rm!(blocker)
        File.mkdir_p!(blocker)

        repo =
          await(fn ->
            case AgentState.repo(supervisor) do
              repo when is_pid(repo) -> {:ok, repo}
              nil -> :retry
            end
          end)

        assert Process.alive?(repo)

        # And it is a REAL store again.
        :ok =
          AgentState.checkpoint("task-broken", 1, rewrite([message("kept")]), store: supervisor)

        assert :ok = AgentState.flush(store: supervisor)

        assert {:ok, record} = AgentState.load("task-broken", 1, store: supervisor)
        assert record.messages == [message("kept")]
      end)

    assert log =~ "starting DEGRADED"
  end

  ## 2. The supervisor absorbs repeated writer crashes

  test "the agent-state supervisor keeps restarting a crashing writer within its budget",
       %{tmp_dir: tmp_dir} do
    supervisor = start_store!(tmp_dir)
    first = server_pid(supervisor)

    # Five restarts inside a few hundred ms — more than the 3/5 s intensity of
    # the application supervisor, so a writer parented directly by it would be
    # shut down. The subsystem's own supervisor (10/60) must absorb them.
    last =
      Enum.reduce(1..5, first, fn _index, previous ->
        Process.exit(previous, :kill)

        await(fn ->
          case server_pid(supervisor) do
            pid when is_pid(pid) and pid != previous -> {:ok, pid}
            _other -> :retry
          end
        end)
      end)

    assert is_pid(last)
    assert Process.alive?(supervisor)
    assert %{active: 1, supervisors: 0, workers: 1} = Supervisor.count_children(supervisor)
    assert :ok = AgentState.flush(store: supervisor)
  end

  ## 3. Repo death is handled, not swallowed

  test "a killed repo degrades the server and the reboot path re-establishes it",
       %{tmp_dir: tmp_dir} do
    supervisor =
      start_store!(tmp_dir, boot_retry_base: 300, boot_retry_max: 300)

    server = server_pid(supervisor)
    repo = await(fn -> if pid = AgentState.repo(supervisor), do: {:ok, pid}, else: :retry end)

    capture_log(fn ->
      Process.exit(repo, :kill)

      # Repo gone, server ALIVE and honest about it.
      await(fn -> if AgentState.repo(supervisor) == nil, do: {:ok, :gone}, else: :retry end)
      assert Process.alive?(server)

      assert {:error, :store_unavailable} =
               AgentState.load("task-dead-repo", 1, store: supervisor)

      assert AgentState.resumable?("task-dead-repo", store: supervisor) == false
      assert AgentState.root_agent_ids("task-dead-repo", store: supervisor) == []
      assert {:error, :timeout} = AgentState.flush(store: supervisor)

      # The same server boots a FRESH repo through the backoff path.
      new_repo =
        await(fn ->
          case AgentState.repo(supervisor) do
            pid when is_pid(pid) and pid != repo -> {:ok, pid}
            _other -> :retry
          end
        end)

      assert Process.alive?(new_repo)
      assert Process.alive?(server)

      :ok =
        AgentState.checkpoint("task-dead-repo", 1, rewrite([message("after reboot")]),
          store: supervisor
        )

      assert :ok = AgentState.flush(store: supervisor)
      assert {:ok, record} = AgentState.load("task-dead-repo", 1, store: supervisor)
      assert record.messages == [message("after reboot")]
    end)
  end

  ## 4. Both pids are accepted by the facade

  test "every public function resolves the supervisor pid to the writer", %{tmp_dir: tmp_dir} do
    supervisor = start_store!(tmp_dir)
    server = server_pid(supervisor)

    assert AgentState.repo(supervisor) == AgentState.repo(server)
    assert is_pid(AgentState.repo(supervisor))

    :ok =
      AgentState.checkpoint("task-both", 2, rewrite([message("via supervisor")]),
        store: supervisor
      )

    assert :ok = AgentState.flush(supervisor)

    assert {:ok, record} = AgentState.load("task-both", 2, store: server)
    assert record.messages == [message("via supervisor")]

    assert :ok = AgentState.mark_completed("task-both", 2, store: supervisor)
    assert :ok = AgentState.flush(server)
    assert {:ok, %{fields: fields}} = AgentState.load("task-both", 2, store: supervisor)
    assert fields[:status] == "done"
  end
end
