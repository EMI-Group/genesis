defmodule EvoGit.SystemSamplerTest do
  @moduledoc """
  Tests for `EvoGit.SystemSampler` — the supervised GenServer that samples
  scheduler status every `:system_sample_interval_ms` and broadcasts
  `{:system_sample, node, seq, sample}` on PubSub topic `"system"`.

  `async: false` because the tests touch the global `:evogit_sched_meta` ETS
  table, the global scheduler config (`AgentScheduler.update_config/1`), and
  the app-registered sampler instance.

  ## Why the app-registered sampler is restarted in `setup_all`

  The `:evo_git` application (and therefore the sampler) starts BEFORE
  `test_helper.exs` runs, so the interval env cannot be set there. This file
  therefore (1) sets `:system_sample_interval_ms` to a day-long interval and
  (2) restarts the sampler via `Supervisor.terminate_child/2` +
  `Supervisor.restart_child/2` so its `init/1` re-reads the env — after that
  the registered instance never self-ticks and every tick in this file is
  driven manually via `tick/0` / `GenServer.call`.

  NOTE: `terminate_child/2` alone does NOT auto-restart the child on this
  Elixir version (1.20.3, verified empirically — the child stays in the
  supervisor's `:undefined` state), so `restart_child/2` is called explicitly.
  """

  use ExUnit.Case, async: false

  alias EvoGit.AgentScheduler
  alias EvoGit.AgentScheduler.RemoteAPI
  alias EvoGit.AgentScheduler.SchedMeta
  alias EvoGit.AgentSpec
  alias EvoGit.Core.ContextNode
  alias EvoGit.Core.PhyloGraphNode

  # A day-long tick interval: the sampler never self-ticks during a test run.
  @high_interval 86_400_000

  # The exact 13-key sample contract, sorted (atom order == alphabetical).
  # `llm_slots` (the real per-model LLM slot occupancy map) sorts between the
  # aggregated `llm_capacity` and `llm_used` keys.
  @sorted_keys [
    :agents_blocked,
    :agents_pending,
    :agents_running,
    :agents_total,
    :agents_waiting,
    :llm_capacity,
    :llm_slots,
    :llm_used,
    :llm_waiting,
    :scheduler_alive,
    :tool_capacity,
    :tool_used,
    :tool_waiting
  ]

  # --- Shared fixtures (same shape as remote_api_test.exs) ---

  defp context_node do
    %ContextNode{path: "./", repo: "/tmp/test"}
  end

  defp phylo_node do
    %PhyloGraphNode{repo: "/tmp/test", base_commit: "abc", current_commit: "abc"}
  end

  defp agent_spec do
    %AgentSpec{
      context_node: context_node(),
      phylo_node: phylo_node(),
      agent_module: __MODULE__,
      objective: "test objective"
    }
  end

  # --- ETS helpers ---
  #
  # The :evogit_sched_meta table is app-owned (:public), so inserts from the
  # test process work. We NEVER :ets.delete the table (it would break the
  # running scheduler and sibling tests) — only delete_all_objects + restore,
  # the same pattern remote_api_test.exs uses. Other sched_meta-touching
  # tests (dispatch_test.exs, subagents_test.exs) are async: true and run
  # concurrently; remote_api_test.exs accepts this risk with exact assertions
  # and this file follows that precedent.

  defp clear_sched_meta do
    if :ets.whereis(:evogit_sched_meta) != :undefined,
      do: :ets.delete_all_objects(:evogit_sched_meta)
  end

  # Inserts one %SchedMeta{} per {id, status} pair. Only :status is read by
  # the sampler, so defaults suffice for everything else.
  defp seed_sched_meta(entries) do
    for {id, status} <- entries do
      :ets.insert(
        :evogit_sched_meta,
        {id, %SchedMeta{id: id, depth: 0, spec: agent_spec(), status: status}}
      )
    end
  end

  # --- Sampler instance helpers ---

  # Starts an UNREGISTERED sampler (never hits the app-registered instance)
  # with a day-long interval and stops it when the test finishes.
  defp start_unregistered_sampler do
    {:ok, pid} =
      EvoGit.SystemSampler.start_link(name: nil, interval_ms: @high_interval)

    on_exit(fn -> if Process.alive?(pid), do: GenServer.stop(pid) end)
    pid
  end

  # Restarts the app-registered sampler so its init re-reads the (already
  # high) interval and its ring buffer is deterministically empty.
  #
  # terminate_child alone leaves the child in the supervisor's `:undefined`
  # state (no auto-restart on Elixir 1.20.3 — verified empirically), so the
  # restart is driven explicitly with restart_child/2, which starts a fresh
  # process synchronously (returns the new pid after init completed).
  defp restart_registered_sampler do
    case Process.whereis(EvoGit.SystemSampler) do
      pid when is_pid(pid) ->
        :ok = Supervisor.terminate_child(EvoGit.Supervisor, EvoGit.SystemSampler)

      _ ->
        # Already dead/undefined — restart_child below starts it regardless.
        :ok
    end

    assert {:ok, pid} = Supervisor.restart_child(EvoGit.Supervisor, EvoGit.SystemSampler)
    assert Process.whereis(EvoGit.SystemSampler) == pid
    pid
  end

  defp last_sample(pid) do
    {:ok, samples} = GenServer.call(pid, :get_recent_samples)
    List.last(samples)
  end

  defp capacities_of(sample) do
    %{llm_capacity: sample.llm_capacity, tool_capacity: sample.tool_capacity}
  end

  # Registers an on_exit that restores the scheduler config to a pre-mutation
  # baseline cfg. Every test in this file that mutates the global scheduler
  # config via `AgentScheduler.update_config/1` MUST restore it (the scheduler
  # state is module-global and outlives this file).
  defp restore_config_on_exit(cfg) do
    on_exit(fn ->
      :ok =
        AgentScheduler.update_config(
          model_profiles: cfg.model_profiles,
          default_llm_max_concurrency: cfg.default_llm_max_concurrency,
          max_tool_concurrency: cfg.max_tool_concurrency
        )
    end)
  end

  # --- Setup ---

  # Silence the app-registered sampler for the whole module: set the env FIRST,
  # then restart the sampler so it re-reads the env at init. test_helper.exs
  # cannot do this — the app (and sampler) starts before it runs.
  setup_all do
    Application.put_env(:evo_git, :system_sample_interval_ms, @high_interval)

    pid = restart_registered_sampler()

    assert is_pid(pid)
    :ok
  end

  setup do
    clear_sched_meta()
    on_exit(fn -> clear_sched_meta() end)
    :ok
  end

  # ── Pure helpers ──────────────────────────────────────────────────

  describe "pure helpers" do
    test "status_counts/1 returns all-zero buckets for an empty list" do
      assert EvoGit.SystemSampler.status_counts([]) == %{
               total: 0,
               running: 0,
               blocked: 0,
               waiting: 0,
               pending: 0,
               ready: 0
             }
    end

    test "status_counts/1 counts unknown-status entries in total but excludes them from every named bucket" do
      counts =
        EvoGit.SystemSampler.status_counts([
          %{status: :unknown},
          %{status: :weird},
          %{},
          %{status: :running}
        ])

      assert counts.total == 4
      assert counts.running == 1
      assert counts.blocked == 0
      assert counts.waiting == 0
      assert counts.pending == 0
      assert counts.ready == 0
    end

    test "config_totals/1 sums per-profile concurrency and max_tool_concurrency" do
      assert EvoGit.SystemSampler.config_totals(%{
               model_profiles: [
                 %{id: "a", concurrency: 3},
                 %{id: "b", concurrency: 5},
                 %{id: "c"}
               ],
               max_tool_concurrency: 9
             }) == %{llm_capacity: 8, tool_capacity: 9}
    end

    test "config_totals/1 yields zero capacities for missing keys and non-maps" do
      assert EvoGit.SystemSampler.config_totals(%{}) == %{llm_capacity: 0, tool_capacity: 0}
      assert EvoGit.SystemSampler.config_totals(nil) == %{llm_capacity: 0, tool_capacity: 0}

      assert EvoGit.SystemSampler.config_totals("not a map") == %{
               llm_capacity: 0,
               tool_capacity: 0
             }
    end

    test "build_sample/3 composes counts, totals and liveness into the exact 13-key map with an empty llm_slots" do
      counts = %{total: 6, running: 2, blocked: 1, waiting: 1, pending: 1, ready: 1}
      totals = %{llm_capacity: 8, tool_capacity: 9}

      sample = EvoGit.SystemSampler.build_sample(counts, totals, true)

      assert Map.keys(sample) |> Enum.sort() == @sorted_keys
      # The backward-compat 3-arity carries no live slot data, so llm_slots
      # takes the scheduler-dead shape (%{}).
      assert sample.llm_slots == %{}
      assert sample.llm_used == 2
      assert sample.tool_used == 2
      assert sample.llm_waiting == 1
      assert sample.tool_waiting == 1
      assert sample.llm_capacity == 8
      assert sample.tool_capacity == 9
      assert sample.agents_total == 6
      assert sample.agents_running == 2
      assert sample.agents_blocked == 1
      assert sample.agents_waiting == 1
      assert sample.agents_pending == 1
      assert sample.scheduler_alive == true
    end

    test "build_sample/4 threads the live per-model llm_slots map through unchanged" do
      counts = %{total: 6, running: 2, blocked: 1, waiting: 1, pending: 1, ready: 1}
      totals = %{llm_capacity: 8, tool_capacity: 9}

      llm_slots = %{
        "model_a" => %{used: 2, waiting: 1, capacity: 3},
        "model_b" => %{used: 0, waiting: 2, capacity: 1}
      }

      sample = EvoGit.SystemSampler.build_sample(counts, totals, llm_slots, true)

      assert Map.keys(sample) |> Enum.sort() == @sorted_keys
      # The 4-arity stores the live per-model map verbatim (this is the shape
      # the sampler's tick path feeds it).
      assert sample.llm_slots == llm_slots
      assert sample.llm_used == 2
      assert sample.tool_used == 2
      assert sample.llm_waiting == 1
      assert sample.tool_waiting == 1
      assert sample.llm_capacity == 8
      assert sample.tool_capacity == 9
      assert sample.agents_total == 6
      assert sample.agents_running == 2
      assert sample.agents_blocked == 1
      assert sample.agents_waiting == 1
      assert sample.agents_pending == 1
      assert sample.scheduler_alive == true
    end

    test "push/3 keeps at most capacity samples, dropping the oldest" do
      assert EvoGit.SystemSampler.push([1, 2, 3], 4, 3) == [2, 3, 4]
      assert EvoGit.SystemSampler.push([], %{a: 1}) == [%{a: 1}]
      assert EvoGit.SystemSampler.push([1, 2], 3, 5) == [1, 2, 3]
    end
  end

  # ── Dead-scheduler branch ────────────────────────────────────────
  #
  # The integration-level dead branch (the sampler ticking while BOTH the
  # scheduler process and the :evogit_sched_meta table are gone) is NOT
  # testable in the shared test app: the :evo_git application owns both, so
  # stopping/deleting either would destabilize the running scheduler and every
  # sibling test that assumes they exist. The contract exposes the pure
  # helpers below instead, and they pin the exact zeroed sample the dead
  # branch produces (build_sample/3 with empty counts, zero totals, false).

  describe "dead-scheduler sample (pure helpers)" do
    test "build_sample/3 with a dead scheduler produces the zeroed 13-key contract map" do
      sample =
        EvoGit.SystemSampler.build_sample(
          EvoGit.SystemSampler.status_counts([]),
          EvoGit.SystemSampler.config_totals(nil),
          false
        )

      assert Map.keys(sample) |> Enum.sort() == @sorted_keys
      assert sample.scheduler_alive == false
      # Dead scheduler → no live slot data → the empty llm_slots shape.
      assert sample.llm_slots == %{}
      assert sample.agents_total == 0
      assert sample.agents_running == 0
      assert sample.agents_blocked == 0
      assert sample.agents_waiting == 0
      assert sample.agents_pending == 0
      assert sample.llm_used == 0
      assert sample.llm_waiting == 0
      assert sample.tool_used == 0
      assert sample.tool_waiting == 0
      assert sample.llm_capacity == 0
      assert sample.tool_capacity == 0
    end

    test "scheduler_alive?/0 is true in the running test app" do
      # Guards the liveness definition's live path (registered scheduler OR
      # existing ETS table — both hold in the test app).
      assert EvoGit.SystemSampler.scheduler_alive?() == true
    end
  end

  # ── Broadcast contract ───────────────────────────────────────────

  describe "broadcast contract (unregistered instance)" do
    test "one {:system_sample, node, seq, sample} per tick with the exact 13-key payload" do
      # Known status mix: total 6, running 2, blocked 1, waiting 1, pending 1,
      # ready 1 (ready is not exposed as a named sample key).
      seed_sched_meta([
        {1, :running},
        {2, :running},
        {3, :blocked},
        {4, :waiting},
        {5, :pending},
        {6, :ready}
      ])

      # Capacities come from the RESOLVED scheduler config — computed BEFORE
      # the ticks; the config is stable (all config-touching tests are
      # async: false) so the sampler's cached totals must match.
      expected_totals = EvoGit.SystemSampler.config_totals(RemoteAPI.get_config())

      :ok = Phoenix.PubSub.subscribe(EvoGit.PubSub, "system")
      on_exit(fn -> Phoenix.PubSub.unsubscribe(EvoGit.PubSub, "system") end)

      current_node = node()
      pid = start_unregistered_sampler()

      for expected_seq <- 1..3 do
        :ok = GenServer.call(pid, :tick)

        assert_receive {:system_sample, ^current_node, ^expected_seq, sample}, 1_000

        assert Map.keys(sample) |> Enum.sort() == @sorted_keys

        # Proxy semantics: running feeds both "used" lines, blocked feeds both
        # "waiting" lines.
        assert sample.llm_used == 2
        assert sample.tool_used == sample.llm_used
        assert sample.llm_waiting == 1
        assert sample.tool_waiting == sample.llm_waiting

        assert sample.agents_total == 6
        assert sample.agents_running == 2
        assert sample.agents_blocked == 1
        assert sample.agents_waiting == 1
        assert sample.agents_pending == 1
        assert sample.scheduler_alive == true

        assert sample.llm_capacity == expected_totals.llm_capacity
        assert sample.tool_capacity == expected_totals.tool_capacity
      end
    end

    test "sampled llm_slots reports per-model entries with live effective capacities on every broadcast" do
      # Deterministic two-profile scheduler config — real per-model pools with
      # known capacities (overrides any developer user config; restored below).
      #
      # Real holders/waiters (used/waiting > 0) are NOT fabricated here:
      # creating them would require running agents through the public slot
      # API, which is fragile in this file. This test pins per-model key
      # presence + effective capacity + used/waiting at their honest zero
      # baseline; real used/waiting occupancy values are covered by the
      # AgentScheduler-level (state-built) tests.
      cfg = RemoteAPI.get_config()
      restore_config_on_exit(cfg)

      expected_llm_slots = %{
        "sys-sampler-llm-slots-a" => %{used: 0, waiting: 0, capacity: 2},
        "sys-sampler-llm-slots-b" => %{used: 0, waiting: 0, capacity: 5}
      }

      :ok =
        AgentScheduler.update_config(
          model_profiles: [
            %{id: "sys-sampler-llm-slots-a", concurrency: 2},
            %{id: "sys-sampler-llm-slots-b", concurrency: 5}
          ],
          max_tool_concurrency: 4
        )

      :ok = Phoenix.PubSub.subscribe(EvoGit.PubSub, "system")
      on_exit(fn -> Phoenix.PubSub.unsubscribe(EvoGit.PubSub, "system") end)

      current_node = node()
      pid = start_unregistered_sampler()

      for expected_seq <- 1..2 do
        :ok = GenServer.call(pid, :tick)

        assert_receive {:system_sample, ^current_node, ^expected_seq, sample}, 1_000

        assert Map.keys(sample) |> Enum.sort() == @sorted_keys
        assert sample.llm_slots == expected_llm_slots
      end
    end
  end

  # ── Ring buffer ──────────────────────────────────────────────────

  describe "ring buffer (unregistered instance)" do
    test "keeps the last 60 samples, dropping the oldest" do
      pid = start_unregistered_sampler()

      # Tick N seeds exactly N entries (one fresh :running agent per tick), so
      # each sample is identifiable by its agents_total.
      for tick_n <- 1..65 do
        :ets.insert(
          :evogit_sched_meta,
          {tick_n, %SchedMeta{id: tick_n, depth: 0, spec: agent_spec(), status: :running}}
        )

        :ok = GenServer.call(pid, :tick)
      end

      {:ok, samples} = GenServer.call(pid, :get_recent_samples)

      assert length(samples) == 60
      # Oldest kept sample is from tick 6 (seqs 1-5 dropped); newest is tick 65.
      assert List.first(samples).agents_total == 6
      assert List.last(samples).agents_total == 65
    end

    test "ring-buffer samples carry per-model llm_slots entries with live capacities" do
      # Same deterministic two-profile config as the broadcast per-model test;
      # every stored sample must carry the live per-model llm_slots map
      # (see that test's comment about used/waiting key-presence coverage).
      cfg = RemoteAPI.get_config()
      restore_config_on_exit(cfg)

      expected_llm_slots = %{
        "sys-sampler-llm-slots-a" => %{used: 0, waiting: 0, capacity: 2},
        "sys-sampler-llm-slots-b" => %{used: 0, waiting: 0, capacity: 5}
      }

      :ok =
        AgentScheduler.update_config(
          model_profiles: [
            %{id: "sys-sampler-llm-slots-a", concurrency: 2},
            %{id: "sys-sampler-llm-slots-b", concurrency: 5}
          ],
          max_tool_concurrency: 4
        )

      pid = start_unregistered_sampler()

      for _ <- 1..3 do
        :ok = GenServer.call(pid, :tick)
      end

      {:ok, samples} = GenServer.call(pid, :get_recent_samples)
      assert length(samples) == 3

      Enum.each(samples, fn sample ->
        assert Map.keys(sample) |> Enum.sort() == @sorted_keys
        assert sample.llm_slots == expected_llm_slots
      end)
    end
  end

  # ── Config cache (10-tick rule) ──────────────────────────────────

  describe "capacity config cache" do
    test "caches capacity totals for 10 ticks and refreshes on tick 11" do
      # (a) Baseline config BEFORE any mutation.
      cfg = RemoteAPI.get_config()
      baseline_totals = EvoGit.SystemSampler.config_totals(cfg)
      # (f) Restore the original config.
      restore_config_on_exit(cfg)

      pid = start_unregistered_sampler()

      # (b) Tick 1: cache miss → loads the current (baseline) config.
      :ok = GenServer.call(pid, :tick)
      assert capacities_of(last_sample(pid)) == baseline_totals

      # (c) Mutate the runtime config (also triggers the ReqLLMPool reconcile,
      # which no-ops gracefully).
      :ok =
        AgentScheduler.update_config(
          model_profiles: [%{id: "sys-sampler-test", concurrency: 7}],
          max_tool_concurrency: 5
        )

      # After (c) the model_concurrency map holds exactly the new profile, so
      # its effective capacity is 7 (the profile's explicit concurrency).
      live_llm_slots = %{"sys-sampler-test" => %{used: 0, waiting: 0, capacity: 7}}

      # (d) Ticks 2..10 keep serving the STALE cached baseline — for the
      # AGGREGATE totals only. llm_slots is fetched LIVE every tick (never
      # part of the config cache), so the profile added at (c) already shows
      # up on tick 2 while llm_capacity/tool_capacity are still the stale
      # cached baseline.
      for tick_n <- 2..10 do
        :ok = GenServer.call(pid, :tick)

        if tick_n in [2, 10] do
          assert capacities_of(last_sample(pid)) == baseline_totals
          assert last_sample(pid).llm_slots == live_llm_slots
        end
      end

      # (e) Tick 11 (rem(11, 10) == 1) refreshes from the live config.
      :ok = GenServer.call(pid, :tick)
      assert capacities_of(last_sample(pid)) == %{llm_capacity: 7, tool_capacity: 5}
      assert last_sample(pid).llm_slots == live_llm_slots
    end
  end

  # ── App-registered instance public API ───────────────────────────

  describe "app-registered sampler (public API)" do
    # Fresh restart per test: the registered instance's ring buffer is
    # deterministically empty and it never self-ticks (high interval).
    setup do
      restart_registered_sampler()
      :ok
    end

    test "get_recent_samples/0 and tick/0 operate on the registered instance" do
      # (a) Freshly restarted → empty buffer.
      assert EvoGit.SystemSampler.get_recent_samples() == {:ok, []}

      # (b) One manual tick produces exactly one sample.
      assert EvoGit.SystemSampler.tick() == :ok
      assert {:ok, [sample]} = EvoGit.SystemSampler.get_recent_samples()

      assert Map.keys(sample) |> Enum.sort() == @sorted_keys
      assert sample.scheduler_alive == true
    end

    test "RemoteAPI.get_recent_system_samples/0 delegates to the running sampler" do
      assert EvoGit.SystemSampler.tick() == :ok
      assert {:ok, [sample]} = RemoteAPI.get_recent_system_samples()

      assert Map.keys(sample) |> Enum.sort() == @sorted_keys
      assert sample.scheduler_alive == true
    end

    test "unregistered sampler: get_recent_samples/tick return {:error, :not_found} and RemoteAPI returns {:error, :sampler_down}" do
      pid = Process.whereis(EvoGit.SystemSampler)
      assert is_pid(pid)

      # Unregistering only removes the name — the process stays alive (it is
      # a supervisor child, not linked to this test) and the supervisor does
      # not care about names. The sampler's self-timer fires only after a day,
      # so nothing ticks during the window.
      Process.unregister(EvoGit.SystemSampler)

      try do
        assert EvoGit.SystemSampler.get_recent_samples() == {:error, :not_found}
        assert EvoGit.SystemSampler.tick() == {:error, :not_found}
        assert RemoteAPI.get_recent_system_samples() == {:error, :sampler_down}
      after
        # The name is free after unregister — restore it immediately.
        assert Process.register(pid, EvoGit.SystemSampler) == true
      end

      assert Process.whereis(EvoGit.SystemSampler) == pid
    end
  end
end
