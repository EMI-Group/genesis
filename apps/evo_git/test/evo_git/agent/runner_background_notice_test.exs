defmodule EvoGit.Agent.RunnerBackgroundNoticeTest do
  @moduledoc """
  Runner-side coverage of the background-job completion NOTICE.

  A `bash` call with `run_in_background: true` detaches a process that outlives
  the tool call. At the top of each turn (after compression and the pending
  user-message drain, before the LLM call) the runner claims its own
  finished-but-unannounced jobs (`EvoGit.BackgroundJobs.claim_finished_notices/1`
  — exactly-once, owner-scoped) and appends ONE combined `[NOTICE]` user message
  (`EvoGit.Agent.BackgroundJobNotice.notice/1`).

  `Runner.inject_background_job_notices/1` is public (`@doc false`) so it can be
  driven directly here, the same convention as
  `Runner.drain_and_inject_user_messages/1`.

  `async: false` — the cases seed the global named `:evogit_agent_state` ETS
  table and an isolated `EvoGit.BackgroundJobs` registry.
  """

  use ExUnit.Case, async: false

  alias EvoGit.Agent.LoopState
  alias EvoGit.Agent.Runner
  alias EvoGit.AgentScheduler.AgentState
  alias EvoGit.AgentScheduler.Store
  alias EvoGit.BackgroundJobs
  alias EvoGit.Core.ContextNode
  alias EvoGit.Core.PhyloGraphNode

  @moduletag :tmp_dir

  @agent_id 1
  @turn 5
  @deadline_ms 5_000

  setup %{tmp_dir: _tmp_dir} do
    create_ets_if_missing(:evogit_agent_state)
    create_ets_if_missing(:evogit_sched_meta)
    create_ets_if_missing(:evogit_archive_records)
    clear_ets()

    name = :"runner_bg_notice_#{System.unique_integer([:positive])}"
    start_supervised!({EvoGit.BackgroundJobs, [name: name]})

    Process.put(:evogit_background_jobs_server, name)
    Process.put(:evogit_agent_pid, self())

    seed_agent_state()

    on_exit(fn ->
      # `on_exit` runs in a different process, so these deletes touch THAT
      # process's dictionary; the test process's keys die with it. Kept as
      # belt-and-braces for the seam contract.
      Process.delete(:evogit_agent_pid)
      Process.delete(:evogit_background_jobs_server)
      clear_ets()
    end)

    :ok
  end

  # ---------------------------------------------------------------------------
  # Harness
  # ---------------------------------------------------------------------------

  defp create_ets_if_missing(name) do
    if :ets.whereis(name) == :undefined do
      :ets.new(name, [:set, :named_table, :public])
    end
  end

  defp clear_ets do
    [:evogit_agent_state, :evogit_sched_meta, :evogit_archive_records]
    |> Enum.each(fn name ->
      if :ets.whereis(name) != :undefined, do: :ets.delete_all_objects(name)
    end)
  end

  # A minimal registered agent — enough for `sync_context_to_ets/2` (a plain
  # ETS write-through) and for the loop's ETS expectations.
  defp seed_agent_state do
    Store.put_agent_state(@agent_id, %AgentState{
      context_node: %ContextNode{path: "./", repo: "/tmp/test"},
      phylo_node: %PhyloGraphNode{repo: "/tmp/test", base_commit: "abc", current_commit: "abc"},
      llm_model: "test:model",
      max_retries: 3,
      max_depth: 8,
      pending_user_messages: []
    })
  end

  defp loop_state(context \\ ReqLLM.Context.new([])) do
    %LoopState{
      agent_id: @agent_id,
      agent_module: __MODULE__,
      depth: 0,
      node_path: "./",
      context: context,
      turn: @turn
    }
  end

  defp start_job!(command, tmp_dir) do
    case BackgroundJobs.start_job(%{command: command, cwd: tmp_dir}) do
      {:ok, job} -> job
      {:error, message} -> flunk("start_job/1 failed: #{inspect(message)}")
    end
  end

  # Polls `job/2` until the record reaches a terminal status. `job/2` does NOT
  # mark a job announced (only `read/2` / `list/1` do), so the notice is still
  # claimable afterwards.
  defp await_terminal!(id, timeout \\ @deadline_ms) do
    wait_until(
      fn ->
        case BackgroundJobs.job(id) do
          {:ok, job} when job.status in [:completed, :killed, :failed] -> {:ok, job}
          _ -> :retry
        end
      end,
      timeout,
      "job #{id} never reached a terminal status"
    )
  end

  defp wait_until(fun, timeout, message) do
    deadline = System.monotonic_time(:millisecond) + timeout
    do_wait_until(fun, deadline, message)
  end

  defp do_wait_until(fun, deadline, message) do
    case fun.() do
      {:ok, value} ->
        value

      :retry ->
        if System.monotonic_time(:millisecond) >= deadline do
          flunk(message)
        else
          Process.sleep(20)
          do_wait_until(fun, deadline, message)
        end
    end
  end

  defp notice_messages(context), do: Enum.filter(context.messages, &notice_message?/1)

  defp notice_message?(%ReqLLM.Message{role: :user, content: content}) when is_list(content) do
    case content do
      [%ReqLLM.Message.ContentPart{type: :text, text: text} | _] when is_binary(text) ->
        String.starts_with?(text, "[NOTICE]")

      _ ->
        false
    end
  end

  defp notice_message?(_message), do: false

  defp text_of(%ReqLLM.Message{content: content}) do
    content
    |> Enum.map_join(fn
      %ReqLLM.Message.ContentPart{type: :text, text: text} -> text
      _other -> ""
    end)
  end

  # ---------------------------------------------------------------------------
  # The notice itself
  # ---------------------------------------------------------------------------

  test "a finished job is announced with exactly ONE turn-tagged [NOTICE] user message",
       %{tmp_dir: tmp_dir} do
    job = start_job!("echo done", tmp_dir)
    _ = await_terminal!(job.id)

    existing = ReqLLM.Context.user("already here")
    state = loop_state(ReqLLM.Context.append(ReqLLM.Context.new([]), existing))

    new_state = Runner.inject_background_job_notices(state)

    assert [first, notice] = new_state.context.messages
    # Everything before the notice is byte-identical (nothing is replaced).
    assert first.content == existing.content

    assert notice.role == :user
    assert notice.metadata[:turn] == @turn
    assert text_of(notice) =~ "[NOTICE]"
    assert text_of(notice) =~ job.id
    assert text_of(notice) =~ "1 background shell job finished"
  end

  test "the ETS context is synced with the notice (dashboard visibility)",
       %{tmp_dir: tmp_dir} do
    job = start_job!("echo done", tmp_dir)
    _ = await_terminal!(job.id)

    _state = Runner.inject_background_job_notices(loop_state())

    assert {:ok, %AgentState{context: context}} = Store.get_agent_state(@agent_id)
    assert [notice] = notice_messages(context)
    assert text_of(notice) =~ job.id
  end

  test "a second call appends nothing — the claim marked the job announced",
       %{tmp_dir: tmp_dir} do
    job = start_job!("echo done", tmp_dir)
    _ = await_terminal!(job.id)

    once = Runner.inject_background_job_notices(loop_state())
    assert [_notice] = notice_messages(once.context)
    assert length(once.context.messages) == 1

    twice = Runner.inject_background_job_notices(once)
    assert twice == once
    assert length(twice.context.messages) == 1

    # And the registry agrees: nothing left to claim.
    assert {:ok, []} = BackgroundJobs.claim_finished_notices()
  end

  test "no finished jobs leaves the context untouched" do
    state = loop_state(ReqLLM.Context.append(ReqLLM.Context.new([]), ReqLLM.Context.user("hi")))

    assert Runner.inject_background_job_notices(state) == state
  end

  test "a still-running job is not announced", %{tmp_dir: tmp_dir} do
    job = start_job!("sleep 30", tmp_dir)

    state = loop_state()
    assert Runner.inject_background_job_notices(state) == state
    assert state.context.messages == []

    assert {:ok, _} = BackgroundJobs.kill(job.id)
  end

  # ---------------------------------------------------------------------------
  # Grace period + dead registry
  # ---------------------------------------------------------------------------

  test "a grace period skips the notice AND leaves the job claimable",
       %{tmp_dir: tmp_dir} do
    job = start_job!("echo done", tmp_dir)
    _ = await_terminal!(job.id)

    grace_state = %{loop_state() | in_grace_period: true, grace_turns_remaining: 2}

    assert Runner.inject_background_job_notices(grace_state) == grace_state
    assert grace_state.context.messages == []

    # The job was NOT claimed: `job/2` still reports it unannounced, and a later
    # non-grace turn notices it.
    assert {:ok, %{announced: false}} = BackgroundJobs.job(job.id)

    resumed = Runner.inject_background_job_notices(%{grace_state | in_grace_period: false})
    assert [notice] = resumed.context.messages
    assert text_of(notice) =~ job.id
  end

  test "an unreachable registry leaves the state unchanged and never raises" do
    Process.put(:evogit_background_jobs_server, :runner_bg_notice_missing_registry)

    state = loop_state(ReqLLM.Context.append(ReqLLM.Context.new([]), ReqLLM.Context.user("hi")))

    assert Runner.inject_background_job_notices(state) == state
  end
end
