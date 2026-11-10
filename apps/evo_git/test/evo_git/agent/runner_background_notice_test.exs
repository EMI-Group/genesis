defmodule EvoGit.Agent.RunnerBackgroundNoticeTest do
  @moduledoc """
  Exchange-engine coverage of the background-job completion NOTICE.

  A `bash` call with `run_in_background: true` detaches a process that outlives
  the tool call. At the top of each turn (after compression and the pending
  user-message drain, before the LLM call) the exchange claims its own
  finished-but-unannounced jobs (`EvoGit.BackgroundJobs.claim_finished_notices/1`
  — exactly-once, owner-scoped) and appends ONE combined `[NOTICE]` user message
  (`EvoGit.Agent.BackgroundJobNotice.notice/1`).

  `EvoGit.Agent.Exchange.Pending.inject_background_job_notices/2` is driven
  directly here, so the engine runs in this plain ExUnit process with no
  scheduler and no ETS row. The RETURNED state is the authority (the engine
  publishes it at the next turn boundary through `:checkpoint`); nothing here
  writes ETS.
  The background jobs themselves are REAL detached children in this test's OWN
  isolated `EvoGit.BackgroundJobs` registry (the tool plane, not the scheduler
  seam), under a unique name with uniquely named job log files, so they never
  collide across modules.

  `async: true` — nothing global is touched: the scheduler seam is in-memory and
  each test's registry/rows are its own.
  """

  use ExUnit.Case, async: true

  alias EvoGit.Agent.Exchange.Pending
  alias EvoGit.Agent.State
  alias EvoGit.BackgroundJobs

  @moduletag :tmp_dir

  @turn 5
  @deadline_ms 5_000

  setup %{tmp_dir: _tmp_dir} do
    # This file's own id range keeps the agent identity unshared with every
    # other module. No ETS row is written: the scheduler seam is in-memory.
    agent_id = 9_961_000 + :erlang.unique_integer([:positive])

    name = :"runner_bg_notice_#{System.unique_integer([:positive])}"
    start_supervised!({EvoGit.BackgroundJobs, [name: name]})

    Process.put(:evogit_background_jobs_server, name)
    Process.put(:evogit_agent_pid, self())

    on_exit(fn ->
      # `on_exit` runs in a different process, so these deletes touch THAT
      # process's dictionary; the test process's keys die with it. Kept as
      # belt-and-braces for the seam contract.
      Process.delete(:evogit_agent_pid)
      Process.delete(:evogit_background_jobs_server)
    end)

    %{agent_id: agent_id}
  end

  # ---------------------------------------------------------------------------
  # Harness
  # ---------------------------------------------------------------------------

  # Builds the pure `:scheduler` seam (`EvoGit.Agent.Exchange.Seams`) for one
  # test: an IN-MEMORY stand-in for the scheduler's per-agent control plane, so
  # the engine runs with no scheduler and no ETS row.
  #
  #   * `calls` — every `{kind, payload}` interaction, in order.
  #
  # A background-notice turn performs NO control-plane interaction at all (the
  # notice is a tool-plane claim), so `kinds/1` stays `[]`.
  defp scheduler_stub do
    {:ok, pid} = Agent.start_link(fn -> %{calls: []} end)
    {fn kind, payload, _state -> record(pid, kind, payload) end, pid}
  end

  defp record(pid, kind, payload) do
    Agent.get_and_update(pid, fn stub ->
      stub = %{stub | calls: stub.calls ++ [{kind, payload}]}
      {:ok, stub}
    end)
  end

  defp calls(pid), do: Agent.get(pid, & &1.calls)
  defp kinds(pid), do: for({kind, _payload} <- calls(pid), do: kind)

  defp loop_state(agent_id, context \\ ReqLLM.Context.new([])) do
    %State{
      agent_id: agent_id,
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

  # The output file is written by the detached process; poll it (bounded) so a
  # sanity check on a job's output cannot race the final flush.
  defp await_output!(output_path, marker) do
    wait_until(
      fn ->
        case File.read(output_path) do
          {:ok, text} -> if text =~ marker, do: {:ok, text}, else: :retry
          {:error, _reason} -> :retry
        end
      end,
      @deadline_ms,
      "job output at #{output_path} never contained the expected marker"
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
       %{agent_id: agent_id, tmp_dir: tmp_dir} do
    job = start_job!("echo done", tmp_dir)
    _ = await_terminal!(job.id)

    existing = ReqLLM.Context.user("already here")
    state = loop_state(agent_id, ReqLLM.Context.append(ReqLLM.Context.new([]), existing))
    {seam, _stub} = scheduler_stub()

    new_state = Pending.inject_background_job_notices(state, scheduler: seam)

    assert [first, notice] = new_state.context.messages
    # Everything before the notice is byte-identical (nothing is replaced).
    assert first.content == existing.content

    assert notice.role == :user
    assert notice.metadata[:turn] == @turn
    assert text_of(notice) =~ "[NOTICE]"
    assert text_of(notice) =~ job.id
    assert text_of(notice) =~ "1 background shell job finished"
  end

  test "the returned state carries the notice and touches no scheduler control plane",
       %{agent_id: agent_id, tmp_dir: tmp_dir} do
    job = start_job!("echo done", tmp_dir)
    _ = await_terminal!(job.id)

    {seam, stub} = scheduler_stub()
    state = loop_state(agent_id)
    new_state = Pending.inject_background_job_notices(state, scheduler: seam)

    # The ONE observable side effect: the state now carries the notice appended
    # to its own context (the engine publishes it at the turn boundary).
    assert [notice] = notice_messages(new_state.context)
    assert text_of(notice) =~ job.id
    assert new_state == %{state | context: ReqLLM.Context.append(state.context, notice)}
    assert kinds(stub) == []
  end

  test "a second call appends nothing — the claim marked the job announced",
       %{agent_id: agent_id, tmp_dir: tmp_dir} do
    job = start_job!("echo done", tmp_dir)
    _ = await_terminal!(job.id)

    {seam, stub} = scheduler_stub()

    once = Pending.inject_background_job_notices(loop_state(agent_id), scheduler: seam)
    assert [_notice] = notice_messages(once.context)
    assert length(once.context.messages) == 1

    twice = Pending.inject_background_job_notices(once, scheduler: seam)
    assert twice == once
    assert length(twice.context.messages) == 1

    # The second call claimed nothing, so it changed nothing either.
    assert kinds(stub) == []

    # And the registry agrees: nothing left to claim.
    assert {:ok, []} = BackgroundJobs.claim_finished_notices()
  end

  test "no finished jobs leaves the context untouched", %{agent_id: agent_id} do
    state =
      loop_state(
        agent_id,
        ReqLLM.Context.append(ReqLLM.Context.new([]), ReqLLM.Context.user("hi"))
      )

    {seam, stub} = scheduler_stub()

    assert Pending.inject_background_job_notices(state, scheduler: seam) == state
    # Nothing claimed → no control-plane interaction at all.
    assert kinds(stub) == []
  end

  test "a still-running job is not announced", %{agent_id: agent_id, tmp_dir: tmp_dir} do
    job = start_job!("sleep 30", tmp_dir)

    {seam, _stub} = scheduler_stub()
    state = loop_state(agent_id)

    assert Pending.inject_background_job_notices(state, scheduler: seam) == state
    assert state.context.messages == []

    assert {:ok, _} = BackgroundJobs.kill(job.id)
  end

  # ---------------------------------------------------------------------------
  # One batch, notification-only
  # ---------------------------------------------------------------------------

  test "two jobs finished before the turn boundary get ONE combined [NOTICE] message",
       %{agent_id: agent_id, tmp_dir: tmp_dir} do
    first = start_job!("echo first", tmp_dir)
    second = start_job!("echo second", tmp_dir)
    _ = await_terminal!(first.id)
    _ = await_terminal!(second.id)

    existing = ReqLLM.Context.user("already here")
    state = loop_state(agent_id, ReqLLM.Context.append(ReqLLM.Context.new([]), existing))
    before = length(state.context.messages)
    {seam, _stub} = scheduler_stub()

    new_state = Pending.inject_background_job_notices(state, scheduler: seam)

    # Exactly ONE message is appended, and it is the single combined notice.
    assert length(new_state.context.messages) == before + 1
    assert [notice] = notice_messages(new_state.context)
    assert notice.metadata[:turn] == @turn

    text = text_of(notice)
    assert text =~ "2 background shell jobs finished"
    assert text =~ first.id
    assert text =~ second.id
    # One job line per job — not one message per job.
    assert length(String.split(text, "\n- ")) == 3

    # Exactly-once: nothing is left to claim, so a second turn appends nothing.
    again = Pending.inject_background_job_notices(new_state, scheduler: seam)
    assert again == new_state
    assert length(again.context.messages) == before + 1
    assert {:ok, []} = BackgroundJobs.claim_finished_notices()
  end

  test "the notice is notification-only — it never carries the job's output",
       %{agent_id: agent_id, tmp_dir: tmp_dir} do
    marker = "SECRET_OUTPUT_MARKER"

    # stdout gets the marker only by DECODING it, so it never appears literally
    # in the command string (which is also the default label).
    command = "printf %s #{Base.encode64(marker)} | base64 -d"
    refute command =~ marker

    job = start_job!(command, tmp_dir)
    job = await_terminal!(job.id)

    # Sanity: the output really did carry the marker, so the negative assertion
    # below cannot pass vacuously.
    await_output!(job.output_path, marker)

    {seam, _stub} = scheduler_stub()
    state = Pending.inject_background_job_notices(loop_state(agent_id), scheduler: seam)

    assert [notice] = notice_messages(state.context)
    text = text_of(notice)

    refute text =~ marker
    assert text =~ job.id
    assert text =~ "completed (exit code: 0)"
    assert text =~ "`job_output`"
    assert text =~ "`job_list`"
  end

  # ---------------------------------------------------------------------------
  # Grace period + dead registry
  # ---------------------------------------------------------------------------

  test "a grace period skips the notice AND leaves the job claimable",
       %{agent_id: agent_id, tmp_dir: tmp_dir} do
    job = start_job!("echo done", tmp_dir)
    _ = await_terminal!(job.id)

    grace_state = %{loop_state(agent_id) | in_grace_period: true, grace_turns_remaining: 2}
    {seam, stub} = scheduler_stub()

    assert Pending.inject_background_job_notices(grace_state, scheduler: seam) == grace_state
    assert grace_state.context.messages == []
    # Skipped BEFORE any interaction: not even a control-plane call.
    assert kinds(stub) == []

    # The job was NOT claimed: `job/2` still reports it unannounced, and a later
    # non-grace turn notices it.
    assert {:ok, %{announced: false}} = BackgroundJobs.job(job.id)

    resumed =
      Pending.inject_background_job_notices(%{grace_state | in_grace_period: false},
        scheduler: seam
      )

    assert [notice] = resumed.context.messages
    assert text_of(notice) =~ job.id
    assert kinds(stub) == []
  end

  test "an unreachable registry leaves the state unchanged and never raises", %{
    agent_id: agent_id
  } do
    Process.put(:evogit_background_jobs_server, :runner_bg_notice_missing_registry)

    state =
      loop_state(
        agent_id,
        ReqLLM.Context.append(ReqLLM.Context.new([]), ReqLLM.Context.user("hi"))
      )

    {seam, _stub} = scheduler_stub()

    assert Pending.inject_background_job_notices(state, scheduler: seam) == state
  end
end
