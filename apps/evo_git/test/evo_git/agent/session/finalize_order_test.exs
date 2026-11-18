defmodule EvoGit.Agent.Session.FinalizeOrderTest do
  @moduledoc """
  ORDERING of the ONE terminal path (`EvoGit.Agent.Session.finalize/1`).

  `docs/agent-run-durability.md` ("no synchronous barriers on life-critical
  processes") makes the order non-negotiable: the terminal RESULT leaves the
  session FIRST and every durable bookkeeping step follows, because the durable
  store is best effort — a slow or locked `agent_state.sqlite` must never delay
  the run's outcome for its scheduler or its finalizing watchdog.

  These tests assert the ORDER DIRECTLY instead of racing a stalled writer.
  `EvoGit.AgentState.mark_completed/3` is a CAST, so a `:sys.suspend`ed writer
  lets the run finish either way and could not discriminate the two orders:
  the observable difference is the ORDER OF SENDS out of the session process
  (result → durable marking → close), which `:erlang.trace/3` records exactly.
  The suite therefore never suspends the app-global writer — a shared singleton
  other concurrently running modules call — and stays `async: true`.

  The harness is `EvoGit.Agent.StreamCase` (per-test unique agent id, direct
  session start, scripted `:llm_call` seam, this process as the `:scheduler`
  and `:notify` sink), and the run is a one-shot role so a tool-free reply IS
  the terminal outcome.
  """

  use EvoGit.Agent.StreamCase, async: true

  alias EvoGit.Agent.Result
  alias EvoGit.Agent.Stream
  alias EvoGit.AgentState

  @timeout 5_000
  @report "finalize order report"
  # Quiet window for collecting trace events after the session is gone: a
  # bounded wait for the tracer's own delivery lag, never a timing assertion.
  @quiet 500

  describe "the terminal path" do
    test "delivers the RESULT before the durable completed marking and the close", ctx do
      writer = Process.whereis(EvoGit.AgentState.Server)
      assert is_pid(writer)
      test_pid = self()
      agent_id = ctx.agent_id
      task_id = "task-#{agent_id}"

      {:ok, session, ref} =
        start_session(
          dispatch_ctx(ctx.agent_id, ctx.tmp_dir,
            agent_module: EvoGit.Agent.StreamCase.OneshotAgent,
            llm_call: blocking_llm_call(test_pid)
          )
        )

      # The run parks INSIDE the LLM call, so tracing starts before any terminal
      # send can happen.
      assert_receive {:llm_blocked, worker}, @timeout
      assert 1 = :erlang.trace(session, true, [:send])

      started = System.monotonic_time(:millisecond)
      send(worker, :release)

      # PROMPT terminal delivery: a bounded wait, not a sleep.
      assert_receive {:agent_session_result, ^agent_id, ^session, {:ok, %Result{}}}, 1_000
      assert System.monotonic_time(:millisecond) - started < 1_000
      assert_receive {:DOWN, ^ref, :process, ^session, :normal}, @timeout

      sends = collect_sends(session)
      assert is_list(sends) and sends != []

      result_index = index_of(sends, &result_send?(&1, test_pid))
      completed_index = index_of(sends, &completed_cast?(&1, writer, task_id, ctx.agent_id))
      dropped_index = index_of(sends, &dropped_cast?(&1, writer, task_id, ctx.agent_id))
      closed_index = index_of(sends, &closed_send?(&1, test_pid, ctx.agent_id))

      assert is_integer(completed_index),
             "the terminal run never marked its durable row completed: #{inspect(sends)}"

      assert result_index < completed_index,
             "durable bookkeeping was sent BEFORE the terminal result"

      assert completed_index < closed_index,
             "the close notification must stay LAST (after result and marking)"

      # This run is a ROOT, so the done marking is immediately followed by the
      # row's deletion (nothing consumes a root's result) — still AFTER the
      # result and still BEFORE the close.
      assert is_integer(dropped_index),
             "the ROOT's done row was never dropped after its marking: #{inspect(sends)}"

      assert completed_index < dropped_index,
             "the ROOT's row must be deleted AFTER its done marking"

      assert dropped_index < closed_index,
             "the close notification must stay LAST (after result, marking and drop)"

      # Ordering must not cost durability: the marking RAN, which the ordered
      # sends above prove, and the row it left behind is gone by contract.
      :ok = AgentState.flush(store: writer)
      assert AgentState.load(task_id, ctx.agent_id, store: writer) == {:error, :not_found}
    end

    test "a watcher sees the terminal cut flash-free while the marking is still a cast", ctx do
      writer = Process.whereis(EvoGit.AgentState.Server)
      assert is_pid(writer)
      agent_id = ctx.agent_id

      {:ok, session, ref} =
        start_session(
          dispatch_ctx(ctx.agent_id, ctx.tmp_dir,
            agent_module: EvoGit.Agent.StreamCase.OneshotAgent,
            llm_call: blocking_llm_call(self())
          )
        )

      assert_receive {:llm_blocked, worker}, @timeout
      assert {:ok, _snapshot, seq} = Stream.watch(agent_id)
      assert is_integer(seq)
      send(worker, :release)

      assert_receive {:agent_session_result, ^agent_id, ^session, {:ok, %Result{}}}, 1_000
      assert_receive {:agent_delta, id, n, events}, @timeout
      assert id == agent_id
      assert n > seq
      assert {:finished, :completed} in events

      assert_receive {:DOWN, ^ref, :process, ^session, :normal}, @timeout
      # The inspector's terminal read model is published (and stays readable)
      # independently of the durable marking.
      assert {:error, _} = Stream.snapshot(agent_id)
    end
  end

  ## Fixtures

  # Blocks the FIRST exchange until the test releases THIS worker, so the test
  # can install a tracer before the run can reach its terminal sends.
  defp blocking_llm_call(test_pid) do
    fn context, _tools, _params, _agent_id, _retries ->
      unless Process.get(:finalize_order_released) do
        send(test_pid, {:llm_blocked, self()})

        receive do
          :release -> Process.put(:finalize_order_released, true)
        after
          30_000 -> Process.put(:finalize_order_released, true)
        end
      end

      {:implicit_completion, response(context, @report), @report}
    end
  end

  # Every `:send` event the session produced, in trace order. The session is
  # dead by now (its `:DOWN` was observed), so only tracer delivery lag remains.
  defp collect_sends(session, acc \\ []) do
    receive do
      {:trace, ^session, :send, message, to} -> collect_sends(session, [{message, to} | acc])
    after
      @quiet -> Enum.reverse(acc)
    end
  end

  defp index_of(sends, fun) do
    sends
    |> Enum.with_index()
    |> Enum.find_value(fn {send, index} -> if fun.(send), do: index end)
  end

  defp result_send?({{:agent_session_result, _id, _session, _result}, to}, test_pid),
    do: to == test_pid

  defp result_send?(_send, _test_pid), do: false

  # The terminal marking is ONE cast: the v2 `:mark_done` shape (which the
  # legacy `mark_completed/3` alias now sends) or the legacy
  # `:mark_completed` message itself.
  defp completed_cast?(
         {{:"$gen_cast", {:mark_done, task_id, agent_id, _result, _commit}}, to},
         writer,
         task_id,
         agent_id
       ),
       do: to == writer

  defp completed_cast?(
         {{:"$gen_cast", {:mark_completed, task_id, agent_id}}, to},
         writer,
         task_id,
         agent_id
       ),
       do: to == writer

  defp completed_cast?(_send, _writer, _task_id, _agent_id), do: false

  # The ROOT's row drop, sent by the SAME completion step through
  # `EvoGit.AgentState.delete/3` (a cast to the one serialized writer).
  defp dropped_cast?(
         {{:"$gen_cast", {:delete, task_id, agent_id}}, to},
         writer,
         task_id,
         agent_id
       ),
       do: to == writer

  defp dropped_cast?(_send, _writer, _task_id, _agent_id), do: false

  defp closed_send?({{:agent_session_closed, agent_id, _result}, to}, test_pid, agent_id),
    do: to == test_pid

  defp closed_send?(_send, _test_pid, _agent_id), do: false
end
