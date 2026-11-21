defmodule EvoGit.Agent.Session.StartRetryWaitTest do
  @moduledoc """
  The CRASH-RETRY WAIT must be VISIBLE while the session is still `:starting`.

  A crash retry re-runs the durable setup with `retries > 0`, so the start task
  sleeps `Application.get_env(:evo_git, :agent_retry_backoff_ms, 30_000) * retries`
  before the exchange begins. That sleep used to be invisible: the session
  published nothing, refused `{:watch, _}` and answered no `{:snapshot}` while
  `:starting`, so a consumer saw a stale projection for the whole wait.

  Pinned here, in ONE run of the real session (no stubs of the session or the
  stream layer):

    1. BOTH read paths (`EvoGit.Agent.Stream.snapshot/1` and `watch/1`) answer a
       PRE-STATE snapshot — `phase: :starting`, an empty transcript, turn 0 — and
       a `watch/1` REGISTRATION during `:starting` is what makes the wait
       publishable at all;
    2. the session's live `activity` becomes `:retry_wait` (captured
       unconditionally, `Setup.retry_wait/3` reports it BEFORE the sleep);
    3. the wait RELEASES into the exchange — the LLM seam runs, and the very same
       consumer then sees `phase: :running`;
    4. the start-task log line proves the seam VALUE and its linear growth
       (`@retry_backoff_ms * retries`).

  ## Why `async: false` — the forcing BEAM-GLOBALS

  * `:agent_retry_backoff_ms` is an app-env seam read at CALL time by the
    session's start task (`EvoGit.Agent.Session.Setup.retry_wait/3`) in ANOTHER
    process, so a concurrently running module would observe this module's value
    and have its own setup timing changed. It also needs a value of its own
    (300 ms — short enough to be cheap, still ~30 poll intervals of `:starting`
    window, so the observation below is reachable by construction) rather than
    one hoistable into the suite-wide constant block, so it stays a local
    `on_exit`-restored write.
  * the GLOBAL `Logger` level: `config/test.exs` pins it to `:warning`, so the
    start task's `:info` retry line is invisible unless a capture lowers the
    primary level (`capture_info_logs/1`, the `completion_logging_test` idiom)
    and restores it afterwards — a real BEAM-global window another concurrently
    running module could log inside.

  Every scheduler row is written under a per-test UNIQUE agent id taken from the
  `EvoGit.Agent.StreamCase` range (`9_960_000+`, disjoint from the other suites'
  ranges) and deleted in `on_exit`; the shared `:evogit_agent_summary` /
  `:evogit_sched_meta` tables are only ever touched through this test's own ids,
  and nothing asserts on a table as a whole.
  """

  use EvoGit.Agent.StreamCase, async: false

  # The retry wait this module arms. `retries: 1` makes the start task sleep
  # `@retry_backoff_ms * 1` ms, which is exactly what the log assertion pins.
  # Short enough to keep the test cheap, long enough that the `:starting` window
  # spans many `@poll_ms` polls of the snapshot below.
  @retry_backoff_ms 300

  # Every awaited event is reachable by construction (a 300 ms wait, then a
  # parked exchange worker), so this budget only absorbs the shared host's
  # scheduling latency: an expiry is a real failure and flunks.
  @wait_budget_ms 15_000
  @poll_ms 10

  test "the crash-retry wait is visible while the session is still :starting", %{
    agent_id: agent_id,
    tmp_dir: tmp_dir
  } do
    put_test_env(:agent_retry_backoff_ms, @retry_backoff_ms)

    dispatched =
      dispatch_ctx(agent_id, tmp_dir, llm_call: parked_llm_call())
      # BOTH are read from the TOP-LEVEL dispatch ctx (`Setup.request_worktree/2`
      # fetches `:retries`; `Session.build_state/2` reads `:persistent_state` — not
      # the spec opts), so this run also touches no durable agent-state database.
      |> Keyword.put(:retries, 1)
      |> Keyword.put(:persistent_state, false)

    {{:ok, pid, _ref}, log} =
      capture_info_logs(fn ->
        {:ok, pid, ref} = start_session(dispatched)

        # A `:starting` session is WATCHABLE (below) but not closable yet.
        assert Session.close(pid) == {:error, {:bad_state, :starting}}

        # BOTH read paths answer the PRE-STATE snapshot while `:starting`.
        assert {:ok, %Snapshot{} = snapshot, seq} = Stream.snapshot(agent_id)

        assert %Snapshot{
                 agent_id: ^agent_id,
                 phase: :starting,
                 messages: [],
                 turn: 0,
                 status: nil
               } = snapshot

        assert is_integer(seq)

        assert {:ok, %Snapshot{} = watched, watch_seq} = Stream.watch(agent_id)

        assert %Snapshot{
                 agent_id: ^agent_id,
                 phase: :starting,
                 messages: [],
                 turn: 0,
                 status: nil
               } = watched

        assert is_integer(watch_seq)

        deadline = deadline(@wait_budget_ms)

        # The start task's wait is CAPTURED into the session's live activity, so a
        # consumer attached during the start window sees it instead of `:idle`.
        retry_snapshot =
          await_snapshot(
            agent_id,
            "the :starting snapshot to carry the :retry_wait activity",
            &(&1.activity.phase == :retry_wait),
            deadline
          )

        assert %Snapshot{phase: :starting, activity: %{phase: :retry_wait}} = retry_snapshot

        # TWO legitimate interleavings, both honest (capture is UNCONDITIONAL,
        # publication is watcher-gated by `Session.buffer_events/1`):
        #
        #   * the start task reported BEFORE `Stream.watch/1` registered this
        #     consumer: the events were buffered away (no watcher), so NO delta is
        #     published — and the watch reply's own snapshot already carried
        #     `:retry_wait`, which is exactly what the snapshot assertions above
        #     prove. Nothing is weakened by not demanding a delta here.
        #   * the report landed AFTER the watch: this registered watcher then
        #     RECEIVES the pushed `{:activity, %{phase: :retry_wait}}` delta.
        #
        # In this environment the start task reports BEFORE the test's own public
        # calls return in every observed run, so the snapshot branch above is the
        # one exercised; this delta branch stays as the correctness guard for the
        # other ordering rather than being asserted unconditionally (which would
        # be a race, not a stronger pin).
        if watched.activity.phase != :retry_wait do
          assert_receive {:agent_delta, ^agent_id, delta_seq,
                          [{:activity, %{phase: :retry_wait}} | _events]},
                         remaining(deadline)

          # A published delta always advances the sequence cut the watch returned.
          assert delta_seq > watch_seq
        end

        # The wait really RELEASED into the exchange: the parked LLM seam ran.
        assert_receive {:llm_started, _worker_pid}, remaining(deadline)

        # ... and the SAME consumer sees the live run right after the wait. The
        # setup-wait projection is retired at the `:starting` -> `:running` edge,
        # so the session phase (not the stale activity) is what is asserted.
        running_snapshot =
          await_snapshot(
            agent_id,
            "the :running phase after the retry wait released",
            &(&1.phase == :running),
            deadline
          )

        assert %Snapshot{phase: :running, status: nil} = running_snapshot

        {:ok, pid, ref}
      end)

    # `delay_ms = retry_backoff_ms() * retries` — pins BOTH the seam value and the
    # linear per-attempt growth (`@retry_backoff_ms` x 1 attempt).
    assert log =~
             "AgentScheduler: Retrying agent #{agent_id}, attempt 1; " <>
               "waiting #{@retry_backoff_ms}ms before the next attempt"

    # The session is cleanly `:running` with a PARKED exchange worker: a force
    # cancel answers at once, and the `start_session/1` `on_exit` reaps anything
    # left over.
    assert :ok = Session.cancel(pid, :force)
  end

  # The engine's `:llm_call` seam runs in the exchange WORKER: it reports itself
  # once and then parks forever, so the run stays cleanly `:running` while the
  # test observes it. The test NEVER replies — teardown force-cancels instead.
  defp parked_llm_call do
    test_pid = self()

    fn _context, _tools, _params, _agent_id, _retries ->
      send(test_pid, {:llm_started, self()})

      receive do
        :never_reply -> :ok
      end
    end
  end

  # Bounded, event-driven poll of `Stream.snapshot/1` — the ONE resync path. Both
  # awaited states are reachable by construction, so an expired budget is a real
  # failure: flunk with the last observation instead of returning a sentinel.
  defp await_snapshot(agent_id, description, predicate, deadline) do
    case Stream.snapshot(agent_id) do
      {:ok, %Snapshot{} = snapshot, _seq} ->
        cond do
          predicate.(snapshot) ->
            snapshot

          remaining(deadline) > 0 ->
            Process.sleep(@poll_ms)
            await_snapshot(agent_id, description, predicate, deadline)

          true ->
            flunk("timed out waiting for #{description}; last snapshot: #{inspect(snapshot)}")
        end

      {:error, reason} ->
        if remaining(deadline) > 0 do
          Process.sleep(@poll_ms)
          await_snapshot(agent_id, description, predicate, deadline)
        else
          flunk("timed out waiting for #{description}; the last read failed: #{inspect(reason)}")
        end
    end
  end

  # `config/test.exs` pins the primary Logger level to `:warning` and
  # `ExUnit.CaptureLog` does NOT override it, so the start task's `:info` retry
  # line is only visible once the GLOBAL level is lowered for the capture window
  # (the `completion_logging_test` `capture_info_logs/1` idiom, restored in
  # `after`). See the moduledoc: this is one of the two forcing globals.
  defp capture_info_logs(fun) do
    prior = Logger.level()
    Logger.configure(level: :debug)

    try do
      ExUnit.CaptureLog.with_log(fun)
    after
      Logger.configure(level: prior)
    end
  end

  # `:agent_retry_backoff_ms` is read at CALL time by the session's start task, so
  # this is a BEAM-global write (see the moduledoc). Restore it NIL-AWARE: the
  # suite leaves the key ABSENT, where the production default applies.
  defp put_test_env(key, value) do
    previous = Application.get_env(:evo_git, key)

    Application.put_env(:evo_git, key, value)

    ExUnit.Callbacks.on_exit(fn -> restore_app_env(key, previous) end)
  end

  defp restore_app_env(key, nil), do: Application.delete_env(:evo_git, key)
  defp restore_app_env(key, value), do: Application.put_env(:evo_git, key, value)
end
