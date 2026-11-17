defmodule EvoGit.BackgroundJobPermitsTest do
  # Serialized for the app-global AgentScheduler tool pool: these tests set its
  # max_tool_concurrency to one and inspect its permit map/queue. No env seams.
  use ExUnit.Case, async: false

  alias EvoGit.AgentScheduler
  alias EvoGit.BackgroundJobs
  alias EvoGit.ToolRuntime
  alias EvoGit.ToolRuntime.Request

  # Global scheduler capacity is set to one to prove saturation and FIFO release;
  # no environment or fake-tool registry overrides are used.
  @moduletag :tmp_dir

  @deadline 15_000

  setup %{tmp_dir: dir} do
    original = :sys.get_state(AgentScheduler).max_tool_concurrency
    :ok = AgentScheduler.update_config(max_tool_concurrency: 1)
    registry = :"job_permits_#{System.unique_integer([:positive])}"
    start_supervised!({BackgroundJobs, name: registry})
    Process.put(:evogit_background_jobs_server, registry)
    Process.put(:evogit_agent_pid, self())
    agent_id = 98_000_000 + System.unique_integer([:positive])

    on_exit(fn ->
      AgentScheduler.update_config(max_tool_concurrency: original)
    end)

    %{registry: registry, agent_id: agent_id, dir: dir}
  end

  for ending <- [:natural, :kill, :owner_death] do
    test "transferred permit survives launch and releases once on #{ending}", ctx do
      owner =
        spawn(fn ->
          receive do
            :stop -> :ok
          end
        end)

      on_exit(fn -> if Process.alive?(owner), do: Process.exit(owner, :kill) end)
      {:ok, permit} = AgentScheduler.acquire_tool_permit(ctx.agent_id)
      Process.put(:evogit_tool_permit, permit)
      job = start!(ctx, owner, held_command(ctx.dir))
      Process.delete(:evogit_tool_permit)

      assert job.tool_permit == permit
      assert %{owner: registry_pid, status: :granted} = permits()[permit]
      assert registry_pid == Process.whereis(ctx.registry)
      assert Enum.count(permits(), fn {_, p} -> p.agent_id == ctx.agent_id end) == 1

      # This is the stale launch caller's cleanup, not the registry's release.
      assert :ok = AgentScheduler.release_tool_permit(permit)
      assert Map.has_key?(permits(), permit)
      waiter = queued_permit(ctx.agent_id)
      refute_received {:granted, ^waiter, _}

      case unquote(ending) do
        :natural -> File.touch!(Path.join(ctx.dir, "exit"))
        :kill -> assert {:ok, _} = BackgroundJobs.kill(job.id)
        :owner_death -> Process.exit(owner, :kill)
      end

      assert_receive {:granted, ^waiter, next_permit}, @deadline
      eventually(fn -> not Map.has_key?(permits(), permit) end)
      # Re-observing the terminal record / stale release must not free the next
      # holder. A second competitor is provably queued, not merely slow.
      BackgroundJobs.list()
      BackgroundJobs.list()
      AgentScheduler.release_tool_permit(permit)
      assert permits()[next_permit].status == :granted
      second = queued_permit(ctx.agent_id)
      refute_received {:granted, ^second, _}
      send(waiter, :release)
      assert_receive {:granted, ^second, _}, @deadline
      send(second, :release)
      eventually(fn -> Enum.all?(permits(), fn {_, p} -> p.agent_id != ctx.agent_id end) end)
    end
  end

  test "launch failure after handoff returns capacity to a queued caller", ctx do
    {:ok, permit} = AgentScheduler.acquire_tool_permit(ctx.agent_id)
    Process.put(:evogit_tool_permit, permit)
    waiter = queued_permit(ctx.agent_id)
    # A dead agent passes spec normalization but acceptance fails AFTER handoff.
    {owner, monitor} = spawn_monitor(fn -> :ok end)
    assert_receive {:DOWN, ^monitor, :process, ^owner, :normal}

    assert {:error, message} =
             BackgroundJobs.start_job(%{
               command: "true",
               cwd: ctx.dir,
               owner_pid: owner,
               agent_id: ctx.agent_id
             })

    assert is_binary(message)
    Process.delete(:evogit_tool_permit)
    assert_receive {:granted, ^waiter, next_permit}, @deadline
    refute Map.has_key?(permits(), permit)
    AgentScheduler.release_tool_permit(permit)
    assert permits()[next_permit].status == :granted
    assert BackgroundJobs.list() == []
    send(waiter, :release)
    eventually(fn -> Enum.all?(permits(), fn {_, p} -> p.agent_id != ctx.agent_id end) end)
  end

  test "immediate process exit leaves no transferred permit", ctx do
    {:ok, permit} = AgentScheduler.acquire_tool_permit(ctx.agent_id)
    Process.put(:evogit_tool_permit, permit)
    job = start!(ctx, self(), "exit 0")
    Process.delete(:evogit_tool_permit)

    eventually(fn ->
      {:ok, observed} = BackgroundJobs.job(job.id)
      observed.status == :completed and not Map.has_key?(permits(), permit)
    end)
  end

  test "managed job controls progress while background launch saturates the pool", ctx do
    request =
      Request.new(
        agent_id: ctx.agent_id,
        agent_pid: self(),
        repo_path: ctx.dir,
        repo_root: ctx.dir,
        node_path: "./",
        max_timeout: @deadline
      )

    # Managed tasks do not inherit the isolated registry pdict; use the production
    # registry here, filtering every observation by this unique owning agent.
    [{0, _, "bash", output}] =
      managed(request, "bash", %{
        "command" => held_command(ctx.dir),
        "run_in_background" => true
      })

    refute output =~ "Error:"
    jobs = GenServer.call(BackgroundJobs, {:list, self()})
    [job] = Enum.filter(jobs, &(&1.agent_id == ctx.agent_id))
    on_exit(fn -> File.rm(job.output_path) end)
    assert permits()[job.tool_permit].owner == Process.whereis(BackgroundJobs)
    waiter = queued_permit(ctx.agent_id)

    for {name, args} <- [{"job_list", %{}}, {"job_output", %{"job_id" => job.id}}] do
      [{0, _, ^name, text}] = managed(request, name, args)
      if name == "job_list", do: assert(text =~ job.id), else: assert(text =~ "status: running")
      refute text =~ "Error:"
      assert Map.has_key?(permits(), job.tool_permit)
      refute_received {:granted, ^waiter, _}
    end

    [{0, _, "job_kill", text}] = managed(request, "job_kill", %{"job_id" => job.id})
    refute text =~ "Error:"
    assert_receive {:granted, ^waiter, _}, @deadline
    send(waiter, :release)
    eventually(fn -> Enum.all?(permits(), fn {_, p} -> p.agent_id != ctx.agent_id end) end)
  end

  defp managed(request, name, args) do
    ToolRuntime.execute_batch(
      [{ReqLLM.ToolCall.new("permit-#{name}", name, Jason.encode!(args)), 0}],
      request
    )
  end

  defp held_command(dir) do
    "while [ ! -f '#{Path.join(dir, "exit")}' ]; do sleep 0.02; done"
  end

  defp start!(ctx, owner, command) do
    assert {:ok, job} =
             BackgroundJobs.start_job(%{
               command: command,
               cwd: ctx.dir,
               owner_pid: owner,
               agent_id: ctx.agent_id
             })

    on_exit(fn -> File.rm(job.output_path) end)
    job
  end

  defp queued_permit(agent_id) do
    parent = self()

    pid =
      spawn(fn ->
        {:ok, permit} = AgentScheduler.acquire_tool_permit(agent_id)
        send(parent, {:granted, self(), permit})

        receive do
          :release -> AgentScheduler.release_tool_permit(permit)
        end
      end)

    on_exit(fn -> if Process.alive?(pid), do: Process.exit(pid, :kill) end)

    eventually(fn ->
      Enum.any?(permits(), fn {_, p} -> p.owner == pid and p.status == :waiting end)
    end)

    pid
  end

  defp permits, do: :sys.get_state(AgentScheduler).tool_permits

  defp eventually(fun), do: poll(fun, System.monotonic_time(:millisecond) + @deadline)

  defp poll(fun, deadline) do
    if fun.() do
      :ok
    else
      assert System.monotonic_time(:millisecond) < deadline, "condition never became reachable"
      Process.sleep(5)
      poll(fun, deadline)
    end
  end
end
