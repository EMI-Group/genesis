defmodule EvoGit.ToolRuntimeTest do
  @moduledoc """
  Pins the contract of the MANAGED tool-call runtime `EvoGit.ToolRuntime`
  (`execute_batch/2` → `EvoGit.ToolRuntime.Executor`) by driving it DIRECTLY
  with an explicit `%EvoGit.ToolRuntime.Request{}`:

    * batch PARTITION — the serial (file-mutating) group runs in request order
      and BEFORE the concurrent group, and results come back sorted by index;
    * real PARALLEL overlap — two non-serial calls are provably inside their
      tool bodies at the same time (each fake parks on `receive` until the test
      releases it, so no fixed sleep is involved);
    * the scheduler TOOL SLOT gate — held under the request's `agent_id` for the
      batch and released afterwards;
    * per-call TIMEOUT — the exact `Error: Tool execution timed out after …`
      result plus a `:killed` tracking record;
    * CONTEXT PROPAGATION into the spawned tool tasks — tmpdir, owner identity
      (`:evogit_agent_id` / `:evogit_task_id` / `:evogit_agent_pid`), repo paths
      and the ROLE-GUARD inputs (`:repo_less` / `:foreign_repos` /
      `:evogit_repo_id`) — the gap this runtime closed, because a spawned task
      has an EMPTY process dictionary;
    * `EvoGit.ProcessManager` TRACKING — one `:tool_call` execution per call,
      `command` set only for the platform shell call, `:completed` / `:failed` /
      `:killed` terminal statuses.

  ## The fake-tool seam (app env, test-only)

  `EvoGit.Agent.Tools.execute/5` consults the app env
  `:evo_git, :tool_dispatch_test_tools` — a map of
  `internal_tool_key => fun.(args, repo_path, repo_root, node_path)` — AFTER the
  two write guards and BEFORE built-in dispatch, passing the fun's return value
  through verbatim. The env is unset in production, so dispatch is
  byte-identical there; it is installed per test and restored in `on_exit`.

  The registry is keyed by the INTERNAL dispatch key (`ToolNames.normalize/1`
  runs first), so the platform shell tool's key is
  `EvoGit.Agent.ToolNames.shell_tool_name/0` while the tool call the runtime
  receives is named `bash` — which is also what makes the shell-command tracking
  assertion (alias-aware `command` detection) meaningful.

  ## Tracking isolation

  Every assertion is FILTERED by a per-test UNIQUE `agent_id`
  (`9_900_000 + :erlang.unique_integer([:positive])`), so the app-global
  `EvoGit.ProcessManager` registry and the app-global
  `EvoGit.AgentScheduler`'s `tool_holders` set are read in isolation — the
  runtime resolves `EvoGit.ProcessManager.server/0` from the CALLING process,
  and the concurrent group runs in `Task.async_stream` workers that do not
  inherit a test process dictionary, so no per-process registry override is
  possible here.

  Serialized (`async: false`) by ONE global: the fake-tool registry app env
  `:evo_git, :tool_dispatch_test_tools` — a single BEAM-global key that needs a
  DIFFERENT value per test and is shared with `agent/tool_output_integration_test.exs`
  and `agent/tool_dispatch_containment_test.exs`, so the three modules must never
  overlap. Everything else here is concurrent-safe: no agent-state ETS rows are
  written at all (the runtime needs none — the slot gate is keyed by the request's
  `agent_id` and the tracking records are filtered by it).
  """

  use ExUnit.Case, async: false

  alias EvoGit.Agent.ToolNames
  alias EvoGit.AgentScheduler
  alias EvoGit.ProcessManager
  alias EvoGit.TaskTmpdir
  alias EvoGit.ToolRuntime

  alias ReqLLM.ToolCall

  # Non-existent on purpose: the fake tools never touch the filesystem, and the
  # runtime only records the paths (tool `cwd`, tracking `cwd`/`repo_root`).
  @repo_path "/nonexistent/genesis-tool-runtime/worktree"
  @repo_root "/nonexistent/genesis-tool-runtime/repo"
  @node_path "./src/auth"

  # Per-call ceiling the requests are built with. Generous so no case depends on
  # the ambient `[:scheduler, :max_tool_timeout]` configuration; the timeout case
  # uses an explicit `timeout` argument instead (which is what `resolve_timeout/4`
  # honours first).
  @max_timeout 30_000

  # Explicit per-call `timeout` for the timeout case: small enough that the case
  # costs ~50 ms, large enough that a timer can never fire early (timers fire
  # LATE, never early), and distinct from `@max_timeout` so the message below can
  # only be the explicit budget.
  @explicit_timeout 50

  # Upper bound for every "wait for another process" step. Event-driven (a
  # `receive` or a bounded poll), never a fixed sleep.
  @wait_ms 5_000

  setup do
    # Unique per test: every tracking / slot assertion filters on it.
    agent_id = 9_900_000 + :erlang.unique_integer([:positive])
    task_id = "tool_runtime_test_#{:erlang.unique_integer([:positive])}"

    %{agent_id: agent_id, task_id: task_id}
  end

  # ---------------------------------------------------------------------------
  # 1. Serial phase: request order, BEFORE the parallel phase
  # ---------------------------------------------------------------------------

  test "runs the serial (file-mutating) group in request order, before the parallel group", %{
    agent_id: agent_id,
    task_id: task_id
  } do
    parent = self()

    install_fake_tools(%{
      "write_file" => event_tool(parent, "write_file"),
      "edit_file" => event_tool(parent, "edit_file"),
      "read_file" => event_tool(parent, "read_file")
    })

    # Two SERIAL (`EvoGit.Agent.Tools.serial_tool?/1`) calls and one parallel
    # call, in request order.
    calls =
      indexed([
        tool_call("write_file", %{"file_path" => "./a.txt", "content" => "a"}),
        tool_call("edit_file", %{
          "file_path" => "./a.txt",
          "old_text" => "a",
          "new_text" => "b"
        }),
        tool_call("read_file", %{"file_path" => "./a.txt"})
      ])

    expected_ids = Enum.map(calls, fn {call, _index} -> call.id end)

    results = ToolRuntime.execute_batch(calls, request(agent_id, task_id))

    # The tool THE TEST observed running, in completion order: both file
    # mutations first (sequentially, in request order), then the concurrent one.
    assert collect_events() == ["write_file", "edit_file", "read_file"]

    assert [
             {0, write_id, "write_file", "write_file ok"},
             {1, edit_id, "edit_file", "edit_file ok"},
             {2, read_id, "read_file", "read_file ok"}
           ] = results

    assert [write_id, edit_id, read_id] == expected_ids
  end

  # ---------------------------------------------------------------------------
  # 2. Parallel phase: real overlap
  # ---------------------------------------------------------------------------

  test "overlaps two non-serial tool calls inside the concurrent group", %{
    agent_id: agent_id,
    task_id: task_id
  } do
    parent = self()

    # Two DISTINCT non-serial tools (`rg` and `glob`). Each fake announces that
    # it is inside the tool body and then PARKS until released, so receiving
    # BOTH announcements proves both were inside their tool at the same time.
    install_fake_tools(%{
      "rg" => blocking_tool(parent, "rg"),
      "glob" => blocking_tool(parent, "glob")
    })

    calls =
      indexed([
        tool_call("rg", %{"pattern" => "defmodule"}),
        tool_call("glob", %{"pattern" => "**/*.ex"})
      ])

    # `execute_batch/2` blocks its caller, so it runs in a task: the TEST process
    # has to stay free to release the parked tool bodies.
    batch =
      Task.async(fn -> ToolRuntime.execute_batch(calls, request(agent_id, task_id)) end)

    assert_receive {:tool_started, "rg", rg_pid}, @wait_ms
    assert_receive {:tool_started, "glob", glob_pid}, @wait_ms

    # Both tool tasks are alive and BLOCKED inside their tool body right now —
    # the concurrency is real, not merely an interleaving of fast calls.
    assert Process.alive?(rg_pid)
    assert Process.alive?(glob_pid)

    send(rg_pid, :release)
    send(glob_pid, :release)

    assert [{0, _, "rg", "rg ok"}, {1, _, "glob", "glob ok"}] =
             Task.await(batch, @wait_ms)
  end

  # ---------------------------------------------------------------------------
  # 3. Tool slot gate
  # ---------------------------------------------------------------------------

  test "holds the scheduler tool slot for the request's agent_id and releases it after the batch",
       %{
         agent_id: agent_id,
         task_id: task_id
       } do
    parent = self()

    install_fake_tools(%{
      "read_file" => blocking_tool(parent, "read_file")
    })

    # The unique id guarantees the slot is not held by anything else yet.
    refute slot_held?(agent_id)

    calls = indexed([tool_call("read_file", %{"file_path" => "./a.txt"})])

    batch =
      Task.async(fn -> ToolRuntime.execute_batch(calls, request(agent_id, task_id)) end)

    assert_receive {:tool_started, "read_file", tool_pid}, @wait_ms

    # While the tool body runs, the REAL scheduler has granted the slot to this
    # agent id (read-only assertion: nothing is mutated by `:sys.get_state/1`).
    assert slot_held?(agent_id)

    send(tool_pid, :release)

    assert [{0, _, "read_file", "read_file ok"}] = Task.await(batch, @wait_ms)

    # The release is a cast, so it is awaited with a bounded poll rather than
    # assumed to have landed.
    assert wait_until(fn -> not slot_held?(agent_id) end, @wait_ms)
  end

  # ---------------------------------------------------------------------------
  # 4. Timeout
  # ---------------------------------------------------------------------------

  test "kills a timed-out call and reports the exact timeout message", %{
    agent_id: agent_id,
    task_id: task_id
  } do
    install_fake_tools(%{"read_file" => never_returning_tool()})

    calls =
      indexed([
        tool_call("read_file", %{
          "file_path" => "./a.txt",
          "timeout" => @explicit_timeout
        })
      ])

    assert [{0, _, "read_file", output}] =
             ToolRuntime.execute_batch(calls, request(agent_id, task_id))

    assert output ==
             "Error: Tool execution timed out after #{@explicit_timeout}ms. " <>
               "Some output may have been partially captured by the tool."

    # The tracking record settles as `:killed` and names the real timeout.
    assert [%{id: execution_id, status: :killed}] = tool_executions(agent_id, "read_file")

    assert {:ok, %{status: :killed, reason: :timeout}} =
             ProcessManager.get(execution_id)
  end

  # ---------------------------------------------------------------------------
  # 5. Context propagation (the gap this runtime closes)
  # ---------------------------------------------------------------------------

  test "installs the request's role, owner and tmpdir context inside the tool task", %{
    agent_id: agent_id,
    task_id: task_id
  } do
    install_fake_tools(%{"read_file" => echo_context_tool()})

    taskdir = "/nonexistent/genesis-tool-runtime/taskdir_#{:erlang.unique_integer([:positive])}"

    request =
      request(agent_id, task_id,
        agent_pid: self(),
        taskdir: taskdir,
        role: %{
          repo_less: true,
          foreign_repos: [%{"id" => "lib", "path" => "/nonexistent/genesis-tool-runtime/lib"}],
          repo_id: "lib"
        }
      )

    assert [{0, _, "read_file", output}] =
             ToolRuntime.execute_batch(
               indexed([tool_call("read_file", %{"file_path" => "./a.txt"})]),
               request
             )

    assert output =~ "repo_less=true"
    assert output =~ "foreign_ids=lib"
    assert output =~ ~s(repo_id="lib")
    assert output =~ "agent_id=#{agent_id}"
    assert output =~ ~s(task_id="#{task_id}")
    # The AGENT pid, never the tool task's own pid.
    assert output =~ "agent_pid=#{inspect(self())}"
    assert output =~ ~s(repo_path="#{@repo_path}")
    assert output =~ ~s(repo_root="#{@repo_root}")
    assert output =~ ~s(taskdir="#{taskdir}")
  end

  test "installs the default empty role when the request carries none", %{
    agent_id: agent_id,
    task_id: task_id
  } do
    install_fake_tools(%{"read_file" => echo_context_tool()})

    assert [{0, _, "read_file", output}] =
             ToolRuntime.execute_batch(
               indexed([tool_call("read_file", %{"file_path" => "./a.txt"})]),
               request(agent_id, task_id)
             )

    assert output =~ "repo_less=false"
    assert output =~ "foreign_ids="
    refute output =~ "foreign_ids=lib"
    assert output =~ "repo_id=nil"
    assert output =~ "agent_id=#{agent_id}"
    assert output =~ ~s(task_id="#{task_id}")
    assert output =~ "agent_pid=#{inspect(self())}"
    assert output =~ ~s(taskdir=nil)
  end

  # ---------------------------------------------------------------------------
  # 6. ProcessManager tracking
  # ---------------------------------------------------------------------------

  test "records one :tool_call execution per call, with a command only for the shell call", %{
    agent_id: agent_id,
    task_id: task_id
  } do
    install_fake_tools(%{
      ToolNames.shell_tool_name() => fn _args, _repo_path, _repo_root, _node_path ->
        "On branch main"
      end,
      "read_file" => fn _args, _repo_path, _repo_root, _node_path -> "file body" end
    })

    calls =
      indexed([
        tool_call("bash", %{"command" => "git status"}),
        tool_call("read_file", %{"file_path" => "./a.txt"})
      ])

    assert [{0, _, "bash", "On branch main"}, {1, _, "read_file", "file body"}] =
             ToolRuntime.execute_batch(calls, request(agent_id, task_id))

    executions = ProcessManager.list(agent_id: agent_id)
    assert length(executions) == 2

    Enum.each(executions, fn execution ->
      assert execution.kind == :tool_call
      assert execution.agent_id == agent_id
      assert execution.task_id == task_id
      assert execution.status == :completed
      assert execution.runtime == :foreground
      assert execution.owner_pid == self()
      assert execution.cwd == @repo_path
      assert execution.repo_root == @repo_root
    end)

    # The shell call (model-facing `bash`, dispatch key `run_bash`/`run_powershell`)
    # is the ONLY one that carries the command text and a command label.
    shell = Enum.find(executions, &(&1.tool == "bash"))
    assert shell.command == "git status"
    assert shell.label == "bash: git status"

    # A non-shell call is tracked too, but never as a shell command.
    read = Enum.find(executions, &(&1.tool == "read_file"))
    assert read.command == nil
    assert read.label == "read_file"
  end

  test "records a crashing tool as :failed while the batch still returns the crash result", %{
    agent_id: agent_id,
    task_id: task_id
  } do
    install_fake_tools(%{
      "read_file" => fn _args, _repo_path, _repo_root, _node_path -> raise "boom" end
    })

    assert [{0, _, "read_file", output}] =
             ToolRuntime.execute_batch(
               indexed([tool_call("read_file", %{"file_path" => "./a.txt"})]),
               request(agent_id, task_id)
             )

    # Contained: the agent gets a normal, self-correcting tool result ...
    assert output =~ "Error: Tool execution crashed: ** (RuntimeError) boom"

    # ... and the call is recorded as a FAILED execution.
    assert [%{tool: "read_file", status: :failed}] =
             tool_executions(agent_id, "read_file")
  end

  # ---------------------------------------------------------------------------
  # 7. Result ordering + tool_call_id fallback
  # ---------------------------------------------------------------------------

  test "orders results by index and falls back to the tool name when the call has no id", %{
    agent_id: agent_id,
    task_id: task_id
  } do
    install_fake_tools(%{
      "rg" => fn _args, _repo_path, _repo_root, _node_path -> "rg ok" end,
      "glob" => fn _args, _repo_path, _repo_root, _node_path -> "glob ok" end
    })

    rg = tool_call("rg", %{"pattern" => "defmodule"})

    # A call with NO id: `tool_call_id` falls back to the tool NAME.
    no_id = %ToolCall{
      id: nil,
      type: "function",
      function: %{name: "glob", arguments: Jason.encode!(%{"pattern" => "**/*.ex"})}
    }

    # Deliberately handed over out of index order.
    calls = [{rg, 5}, {no_id, 2}]

    assert [
             {2, "glob", "glob", "glob ok"},
             {5, rg_id, "rg", "rg ok"}
           ] = ToolRuntime.execute_batch(calls, request(agent_id, task_id))

    assert rg_id == rg.id
  end

  # ---------------------------------------------------------------------------
  # Helpers
  # ---------------------------------------------------------------------------

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

  # The ONE request the runtime is driven with: everything is explicit so no case
  # depends on ambient agent state, and `max_timeout` is pinned.
  defp request(agent_id, task_id, overrides \\ []) do
    attrs =
      Keyword.merge(
        [
          agent_id: agent_id,
          task_id: task_id,
          agent_pid: self(),
          repo_path: @repo_path,
          repo_root: @repo_root,
          node_path: @node_path,
          taskdir: nil,
          max_timeout: @max_timeout,
          delegation_level: :high,
          agent_module: EvoGit.Agents.Executor
        ],
        overrides
      )

    EvoGit.ToolRuntime.Request.new(attrs)
  end

  # `indexed_calls` shape the runtime expects: `[{call, index}]`.
  defp indexed(calls), do: Enum.with_index(calls)

  defp tool_call(name, args) do
    id = "call_#{name}_#{:erlang.unique_integer([:positive])}"
    ReqLLM.ToolCall.new(id, name, Jason.encode!(args))
  end

  # A fake tool that reports, from INSIDE its tool task, that it ran.
  defp event_tool(parent, name) do
    fn _args, _repo_path, _repo_root, _node_path ->
      send(parent, {:tool_event, name})
      "#{name} ok"
    end
  end

  # A fake tool that announces it is inside the tool body and then PARKS until
  # the test releases it — the proof of real overlap.
  defp blocking_tool(parent, name) do
    fn _args, _repo_path, _repo_root, _node_path ->
      send(parent, {:tool_started, name, self()})

      receive do
        :release -> "#{name} ok"
      after
        # Belt and braces: if the test never releases, answer instead of wedging
        # the suite (the assertion has already failed by then).
        @wait_ms -> "#{name} never released"
      end
    end
  end

  # A fake tool that never returns — only the per-call timeout can end it.
  defp never_returning_tool do
    fn _args, _repo_path, _repo_root, _node_path ->
      receive do
        :never -> :ok
      end
    end
  end

  # A fake tool that echoes the CONTEXT the runtime installed in ITS tool task
  # (a spawned task starts with an empty process dictionary).
  defp echo_context_tool do
    fn _args, _repo_path, _repo_root, _node_path ->
      foreign_ids =
        :foreign_repos
        |> Process.get([])
        |> Enum.map_join(",", fn repo -> to_string(repo["id"] || repo[:id]) end)

      [
        "repo_less=#{inspect(Process.get(:repo_less))}",
        "foreign_ids=#{foreign_ids}",
        "repo_id=#{inspect(Process.get(:evogit_repo_id))}",
        "agent_id=#{inspect(Process.get(:evogit_agent_id))}",
        "task_id=#{inspect(Process.get(:evogit_task_id))}",
        "agent_pid=#{inspect(Process.get(:evogit_agent_pid))}",
        "repo_path=#{inspect(Process.get(:repo_path))}",
        "repo_root=#{inspect(Process.get(:genesis_repo_root))}",
        "taskdir=#{inspect(TaskTmpdir.current())}"
      ]
      |> Enum.join(";")
    end
  end

  # Drains the `{:tool_event, name}` messages the fake tools sent, in the order
  # the TEST process received them (the batch has already returned, so every
  # event is in the mailbox).
  defp collect_events(acc \\ []) do
    receive do
      {:tool_event, name} -> collect_events([name | acc])
    after
      0 -> Enum.reverse(acc)
    end
  end

  # True while the REAL app-global scheduler holds a tool slot for `agent_id`.
  defp slot_held?(agent_id) do
    %{tool_holders: holders} = :sys.get_state(AgentScheduler)
    MapSet.member?(holders, agent_id)
  end

  # Bounded poll for a cross-process condition (never a fixed sleep).
  defp wait_until(fun, timeout_ms) when is_function(fun, 0) do
    deadline = System.monotonic_time(:millisecond) + timeout_ms
    do_wait_until(fun, deadline)
  end

  defp do_wait_until(fun, deadline) do
    cond do
      fun.() ->
        true

      System.monotonic_time(:millisecond) >= deadline ->
        false

      true ->
        Process.sleep(1)
        do_wait_until(fun, deadline)
    end
  end

  # Every `:tool_call` execution this test's agent recorded for one tool.
  defp tool_executions(agent_id, tool) do
    agent_id
    |> then(&ProcessManager.list(agent_id: &1))
    |> Enum.filter(&(&1.kind == :tool_call and &1.tool == tool))
  end
end
