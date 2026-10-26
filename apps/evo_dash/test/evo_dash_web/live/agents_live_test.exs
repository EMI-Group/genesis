defmodule EvoDashWeb.AgentsLiveTest do
  # async: true — the scheduler ETS tables this file seeds
  # (:evogit_sched_meta / :evogit_agent_state) are shared across the whole
  # cohort, so each test seeds its agent under a UNIQUE id (see `agent_id/0`)
  # instead of a fixed literal. The `:agents_*` runner app-env seams are used
  # by NO other module, and the one real core write (send_agent_message)
  # contains its own broadcast.
  use EvoDashWeb.ConnCase, async: true
  import Phoenix.LiveViewTest

  alias EvoDashWeb.AgentsLive.HistoryGate
  alias EvoDashWeb.AgentsLive.LoadData
  alias EvoDashWeb.AgentsLive.ThresholdCache
  alias EvoDashWeb.Helpers
  alias EvoGit.AgentSpec
  alias EvoGit.AgentScheduler.AgentState
  alias EvoGit.AgentScheduler.SchedMeta
  alias EvoGit.Core.ContextNode
  alias EvoGit.Core.PhyloGraphNode

  # A fixed UTC instant: 2023-11-14 22:13:20Z
  @unix_seconds 1_700_000_000

  setup do
    # The scheduler ETS tables (:evogit_sched_meta / :evogit_agent_state) are
    # owned by the :evo_git application process and survive the test process,
    # i.e. they are SHARED across the whole async cohort. Seed this test's
    # agent under a UNIQUE id (never a fixed 1, which the global
    # AgentScheduler also hands out) so a concurrently-running suite can never
    # collide with it.
    # The offset keeps the id far above the scheduler's low, monotonically
    # increasing `next_agent_id` sequence (which starts at 1) and every fixed
    # secondary id this file uses (2, 3, 4, 99, 404, 405), so a collision is
    # impossible in practice while staying unique per test.
    agent_id = System.unique_integer([:positive]) + 10_000_000
    Process.put(:agents_live_test_agent_id, agent_id)

    # ActiveTasks is a global GenServer under EvoDash.Application that is NOT
    # terminated by the per-test isolation above — reset it so one test's
    # sidebar snapshot never leaks into the next.
    EvoDash.ActiveTasks.reset()

    on_exit(fn ->
      # Clean up only the rows this test seeded; the tables themselves are
      # owned by the :evo_git application process (survive the test process).
      for table <- [:evogit_sched_meta, :evogit_agent_state] do
        if :ets.whereis(table) != :undefined, do: :ets.delete(table, agent_id)
      end
    end)

    :ok
  end

  # The ETS id this test's seeded agent lives under — set per test in setup
  # (see above). Tests reference it instead of a fixed literal so the seeded
  # rows are unique across the async cohort.
  defp agent_id, do: Process.get(:agents_live_test_agent_id)

  describe "agents page" do
    test "starts in the async loading state with generation 1", %{conn: conn} do
      # Block the async load task so the initial render's loading state is
      # deterministic — the load runs in a TaskSupervisor child and could
      # otherwise finish before the assertion. The load runs in BOTH the dead
      # render and the connected mount, so the release latch is SHARED (a
      # per-pid barrier would free only one caller and leave the connected
      # mount's load wedged).
      latch = :atomics.new(1, [])

      Application.put_env(:evo_dash, :agents_config_runner, fn _node ->
        await_latch(latch)
        {:ok, %{}}
      end)

      on_exit(&clear_agents_env/0)

      {:ok, view, _html} = live(conn, ~p"/agents")

      assert assigns(view)[:load_generation] == 1
      assert assigns(view)[:agents_loading] == true

      # Release the blocked load(s) and flush — all INSIDE the test window.
      :atomics.put(latch, 1, 1)
      html = flush_agents_load(view)
      refute html =~ "Loading agents…"
    end

    test "renders the empty agent tree with a node-aware config status", %{conn: conn} do
      {:ok, view, html} = live(conn, ~p"/agents")

      assert html =~ "Agent Tree"

      # The agent list is loaded asynchronously — the initial render shows the
      # loading state, so wait for the load to finish before asserting.
      html = flush_agents_load(view)

      assert html =~ "No agents currently registered"

      # config_status is read per node by the async load through
      # node_config_status/1 (the layout config banner's source), so a mounted
      # page carries a fully evaluated status map — never nil. (Node-awareness
      # itself is the NodeAware hook's contract; here we pin that the page
      # actually populated the assign from its load.)
      assert %{ok?: ok?, missing: missing, warnings: warnings} = assigns(view)[:config_status]
      assert is_boolean(ok?)
      assert is_list(missing)
      assert is_list(warnings)
    end
  end

  describe "async agent load" do
    test "populates the tree and drops stale load generations and refresh sequences", %{
      conn: conn
    } do
      seed_agent(agent_id(), [
        %ReqLLM.Message{role: :user, content: [%{text: "hi"}], metadata: %{turn: 1}}
      ])

      {:ok, view, _html} = live(conn, ~p"/agents")
      html = flush_agents_load(view)
      assert assigns(view)[:load_generation] == 1

      # The tree renders the seeded agent's card under its repo root.
      assert html =~ "##{agent_id()}"
      assert html =~ "Primary Repo"

      # The async load carried the summary's :message_count through (the
      # history gate keys off it — see "history fetch gating").
      assert [agent] = assigns(view)[:agents]
      assert agent.id == agent_id()
      assert agent.message_count == 1
      assert agent.status == :running

      # ── stale LOAD GENERATION ─────────────────────────────────────────
      # A result from an older generation (0 < 1) must be dropped. The
      # trailing {:agents_updated, node()} event is only a FIFO
      # synchronization fence: once the refresh it spawned is observable
      # (refresh_seq bumped), the stale message was already processed.
      send(view.pid, {:agents_data_loaded, node(), 0, {:ok, %{agents: [marker_agent()]}}})
      send(view.pid, {:agents_updated, node()})
      flush_agent_events(view)
      wait_until(fn -> assigns(view)[:refresh_seq] == 1 end)

      assert assigns(view)[:agents] |> Enum.map(& &1.id) == [agent_id()]
      refute render(view) =~ "#99"

      # ── stale REFRESH SEQUENCE ────────────────────────────────────────
      # A stale refresh result (seq 0 < 1) must be dropped. FIFO fence: the
      # {:agents_updated, node()} event is processed after the stale message.
      send(view.pid, {:agents_refresh_result, 0, node(), {:ok, [marker_agent()], nil}})
      send(view.pid, {:agents_updated, node()})
      flush_agent_events(view)
      wait_until(fn -> assigns(view)[:refresh_seq] == 2 end)

      assert assigns(view)[:agents] |> Enum.map(& &1.id) == [agent_id()]
      refute render(view) =~ "#99"
    end
  end

  describe "history fetch gating" do
    # The HistoryGate suppresses full-history re-transfers while an agent's
    # :message_count is unchanged (see EvoDashWeb.AgentsLive.HistoryGate).

    test "re-fetches history only when the message count moved", %{conn: conn} do
      seed_agent(agent_id(), [
        %ReqLLM.Message{role: :user, content: [%{text: "hi"}], metadata: %{turn: 1}}
      ])

      counter = start_history_counter()
      Application.put_env(:evo_dash, :agents_history_runner, counting_history_runner(counter))
      on_exit(&clear_agents_env/0)

      {:ok, view, _html} = live(conn, ~p"/agents")
      flush_agents_load(view)

      # First selection fetches history (the gate has no last-seen entry).
      view |> element("#agent-card-#{agent_id()}") |> render_click()
      wait_until(fn -> render(view) =~ "fake message 1" end)
      assert Agent.get(counter, & &1) == 1

      # Make the next refresh observable: change the agent's status in ETS
      # while leaving its context (message_count) untouched.
      update_agent_status(agent_id(), :waiting)
      send(view.pid, {:agents_updated, node()})
      flush_agent_events(view)
      wait_until(fn -> render(view) =~ "WAITING" end)

      # The refresh applied but the count is unchanged — the carried history is
      # kept and the gate suppresses a re-fetch.
      assert Agent.get(counter, & &1) == 1

      # The conversation grows (2 messages) — the next refresh must drop the
      # carried history and re-fetch for the selected agent.
      update_agent_context(agent_id(), [
        %ReqLLM.Message{role: :user, content: [%{text: "hi"}], metadata: %{turn: 1}},
        %ReqLLM.Message{role: :assistant, content: [%{text: "world"}], metadata: %{turn: 2}}
      ])

      send(view.pid, {:agents_updated, node()})
      flush_agent_events(view)
      wait_until(fn -> render(view) =~ "Turn 2" end)

      assert Agent.get(counter, & &1) == 2
    end
  end

  describe "incremental history refresh (panel stays mounted)" do
    test "a batched message-count update keeps the mounted entries and appends the new tail (never blanked)",
         %{conn: conn} do
      seed_agent(agent_id(), [
        %ReqLLM.Message{role: :user, content: [%{text: "seed"}], metadata: %{turn: 0}}
      ])

      test_pid = self()
      Application.put_env(:evo_dash, :agents_history_runner, blocking_history_runner(test_pid))
      on_exit(&clear_agents_env/0)

      {:ok, view, _html} = live(conn, ~p"/agents")
      flush_agents_load(view)

      view |> element("#agent-card-#{agent_id()}") |> render_click()
      assert_receive {:history_fetch_called, first_task}, 2000

      send(
        first_task,
        {:history_release,
         [
           %ReqLLM.Message{
             role: :user,
             content: [%{text: "first entry"}],
             metadata: %{turn: 1}
           }
         ]}
      )

      wait_until(fn -> render(view) =~ "first entry" end)

      update_agent_context(agent_id(), [
        %ReqLLM.Message{role: :user, content: [%{text: "first entry"}], metadata: %{turn: 1}},
        %ReqLLM.Message{
          role: :assistant,
          content: [%{text: "second entry"}],
          metadata: %{turn: 2}
        }
      ])

      send(view.pid, {:agent_updated, agent_id(), [message_count: 2], node()})
      send(view.pid, {:agents_updated, node()})
      flush_agent_events(view)

      assert_receive {:history_fetch_called, second_task}, 2000

      mid_flight = render(view)
      assert mid_flight =~ "first entry"
      refute mid_flight =~ "Loading history"

      send(
        second_task,
        {:history_release,
         [
           %ReqLLM.Message{
             role: :user,
             content: [%{text: "first entry"}],
             metadata: %{turn: 1}
           },
           %ReqLLM.Message{
             role: :assistant,
             content: [%{text: "second entry"}],
             metadata: %{turn: 2}
           }
         ]}
      )

      wait_until(fn -> render(view) =~ "second entry" end)

      final = render(view)
      assert final =~ "first entry"
      assert final =~ "second entry"
      assert final =~ ~s{id="agent-history-entry-#{agent_id()}-0"}
      assert final =~ ~s{id="agent-history-entry-#{agent_id()}-1"}
    end

    test "a diverging refetch (compression/rewrite) still updates the panel", %{conn: conn} do
      seed_agent(agent_id(), [
        %ReqLLM.Message{role: :user, content: [%{text: "seed"}], metadata: %{turn: 0}}
      ])

      queue =
        start_history_queue([
          [%ReqLLM.Message{role: :user, content: [%{text: "old entry"}], metadata: %{turn: 1}}],
          [
            %ReqLLM.Message{role: :user, content: [%{text: "new entry A"}], metadata: %{turn: 5}},
            %ReqLLM.Message{
              role: :assistant,
              content: [%{text: "new entry B"}],
              metadata: %{turn: 6}
            }
          ]
        ])

      Application.put_env(:evo_dash, :agents_history_runner, queued_history_runner(queue))
      on_exit(&clear_agents_env/0)

      {:ok, view, _html} = live(conn, ~p"/agents")
      flush_agents_load(view)

      view |> element("#agent-card-#{agent_id()}") |> render_click()
      wait_until(fn -> render(view) =~ "old entry" end)

      update_agent_context(agent_id(), [
        %ReqLLM.Message{role: :user, content: [%{text: "old entry"}], metadata: %{turn: 1}},
        %ReqLLM.Message{role: :assistant, content: [%{text: "x"}], metadata: %{turn: 2}}
      ])

      send(view.pid, {:agents_updated, node()})
      flush_agent_events(view)

      wait_until(fn -> render(view) =~ "new entry B" end)

      html = render(view)
      assert html =~ "new entry A"
      assert html =~ "new entry B"
      refute html =~ "old entry"
    end

    test "does not carry a previous node's history into a newly applied agent (no gate entry)",
         %{conn: conn} do
      # Regression: on a node switch the history gate is RESET while @agents is
      # deliberately kept mounted. Agent ids are per-node, so a same-id row from
      # the previous node can still be found in @agents — but the gate has NO
      # entry for it (it was reset), so its history must NOT be carried into the
      # newly-applied (new node's) rows.
      Application.put_env(:evo_dash, :agents_history_runner, fn _node, _agent_id ->
        [
          %ReqLLM.Message{
            role: :user,
            content: [%{text: "NEW NODE HISTORY"}],
            metadata: %{turn: 1}
          }
        ]
      end)

      on_exit(&clear_agents_env/0)

      {:ok, view, _html} = live(conn, ~p"/agents")
      flush_agents_load(view)

      leaked = %ReqLLM.Message{
        role: :user,
        content: [%{text: "PREVIOUS NODE HISTORY"}],
        metadata: %{turn: 1}
      }

      # State left over by a node switch: @agents holds a row WITH its
      # already-fetched history, while the gate is empty (reset on the switch).
      send(
        view.pid,
        {:agents_data_loaded, node(), 1,
         {:ok,
          %{
            agents: [full_agent(id: agent_id(), history: [leaked], message_count: 5)],
            config_status: nil,
            threshold_cache: nil
          }}}
      )

      # The new node's async load lands: a fresh summary row for the SAME id
      # (agent ids are per-node) with no history of its own and no gate entry.
      send(
        view.pid,
        {:agents_data_loaded, node(), 1,
         {:ok,
          %{
            agents: [full_agent(id: agent_id(), history: [], message_count: 5)],
            config_status: nil,
            threshold_cache: nil
          }}}
      )

      render(view)

      # The apply path must NOT carry the previous node's history into the
      # new node's row (the gate never knew this id on the current node).
      [agent] = Enum.filter(assigns(view)[:agents], &(&1.id == agent_id()))
      assert agent.history == []
      assert assigns(view)[:history_gate] == %{}

      # Selecting the agent fetches ITS node's history — the previous node's
      # content must never appear in the panel.
      view |> element("#agent-card-#{agent_id()}") |> render_click()
      wait_until(fn -> render(view) =~ "NEW NODE HISTORY" end)

      refute render(view) =~ "PREVIOUS NODE HISTORY"
    end
  end

  describe "agent event broadcasts (node-identity contract)" do
    # The :evo_git emitters broadcast four node-identity event shapes on
    # EvoGit.PubSub topic "agents": {:agent_registered, id, summary, node},
    # {:agent_updated, id, changed_fields, node}, {:agent_removed, id, node},
    # and {:agents_updated, node}. AgentsLive applies them incrementally
    # in-memory through ONE shared path for local and remote viewing; events
    # whose node does not match the viewed node are dropped. These tests
    # inject the events directly (send/2) — the emitters are converted in
    # parallel and not available in this worktree yet.

    test "registered event merges the new row in-memory (local)", %{conn: conn} do
      seed_agent(agent_id(), [])

      {:ok, view, _html} = live(conn, ~p"/agents")
      flush_agents_load(view)

      summary =
        summary_agent(
          id: 2,
          parent_id: agent_id(),
          status: :pending,
          objective: "child objective"
        )

      send(view.pid, {:agent_registered, 2, summary, node()})
      flush_agent_events(view)

      assert assigns(view)[:new_agent_ids] |> MapSet.member?(2)

      agents = assigns(view)[:agents]
      # Isolated (per-test-unique) ids mean the seeded agent no longer has to
      # sort before the injected child 2 — only membership is meaningful here.
      assert Enum.map(agents, & &1.id) |> Enum.sort() == Enum.sort([agent_id(), 2])

      registered = Enum.find(agents, &(&1.id == 2))
      assert registered.parent_id == agent_id()
      assert registered.status == :pending
      assert registered.objective == "child objective"
      assert registered.compression_pct == 0

      # The parent's children list was recomputed from parent_id.
      parent = Enum.find(agents, &(&1.id == agent_id()))
      assert parent.children == [{2, :pending}]
      assert parent.has_children
    end

    test "registered event with an incomplete summary falls back to a full refresh", %{
      conn: conn
    } do
      id = agent_id()

      Application.put_env(:evo_dash, :agents_list_runner, fn _node ->
        [summary_agent(id: id), summary_agent(id: 2, objective: "from refresh")]
      end)

      on_exit(&clear_agents_env/0)

      {:ok, view, _html} = live(conn, ~p"/agents")
      flush_agents_load(view)

      # A summary missing fields the tree needs (status/depth/parent_id) —
      # the handler must fall back to a full async refresh instead of
      # merging a broken row.
      send(view.pid, {:agent_registered, 3, %{id: 3}, node()})
      flush_agent_events(view)

      wait_until(fn -> assigns(view)[:refresh_seq] == 1 end)
      wait_until(fn -> assigns(view)[:agents] |> Enum.any?(&(&1.id == 2)) end)

      refute Enum.any?(assigns(view)[:agents], &(&1.id == 3))
    end

    test "updated event merges changed fields in-memory (local)", %{conn: conn} do
      Application.put_env(:evo_dash, :agents_config_runner, fn _node ->
        {:ok, %{llm: %{compression_threshold_tokens: 42_000}}}
      end)

      on_exit(&clear_agents_env/0)

      seed_agent(agent_id(), [])

      {:ok, view, _html} = live(conn, ~p"/agents")
      flush_agents_load(view)

      send(
        view.pid,
        {:agent_updated, agent_id(), [status: :waiting, total_tokens: 21_000], node()}
      )

      flush_agent_events(view)

      assert assigns(view)[:previous_statuses][agent_id()] == :waiting

      agent = assigns(view)[:agents] |> Enum.find(&(&1.id == agent_id()))
      assert agent.status == :waiting
      assert agent.total_tokens == 21_000
      # The bar is recomputed from the changed :total_tokens against the
      # agent's OWN threshold: each agent summary carries a
      # `compression_threshold` (the core derives it from that model's context
      # window — 126_272 for the default 200k window) which takes precedence
      # over the node-level `[:llm, :compression_threshold_tokens]` fallback
      # (42_000 in this stub). 21_000 / 126_272 truncates to 16.
      assert agent.compression_threshold != 42_000
      assert agent.compression_pct == trunc(min(21_000 / agent.compression_threshold * 100, 100))
      assert assigns(view)[:changed_status_ids] |> MapSet.member?(agent_id())
    end

    test "updated event applies for remote viewing too", %{conn: conn} do
      seed_agent(agent_id(), [])
      remote_node = :remote@elsewhere

      {:ok, view, _html} = live(conn, ~p"/agents")
      flush_agents_load(view)

      # Simulate viewing the remote node (the NodeAware hook resolves
      # ?node= in handle_params; mutating the assign directly mirrors that
      # for message-handling tests — asserts read via :sys.get_state, not
      # the proxy's render cache).
      :sys.replace_state(view.pid, fn state ->
        %{
          state
          | socket: %{
              state.socket
              | assigns: Map.put(state.socket.assigns, :current_node, remote_node)
            }
        }
      end)

      send(view.pid, {:agent_updated, agent_id(), [status: :waiting], remote_node})
      flush_agent_events(view)

      assert assigns(view)[:agents] |> Enum.find(&(&1.id == agent_id())) |> Map.get(:status) ==
               :waiting
    end

    test "removed event drops the row (local)", %{conn: conn} do
      seed_agent(agent_id(), [])

      {:ok, view, _html} = live(conn, ~p"/agents")
      flush_agents_load(view)
      assert assigns(view)[:agents] |> Enum.map(& &1.id) == [agent_id()]

      send(view.pid, {:agent_removed, agent_id(), node()})
      flush_agent_events(view)

      assert assigns(view)[:agents] == []
      refute render(view) =~ "##{agent_id()}"
    end

    test "removed event drops the row for remote viewing (previously invisible)", %{conn: conn} do
      seed_agent(agent_id(), [])
      remote_node = :remote@elsewhere

      {:ok, view, _html} = live(conn, ~p"/agents")
      flush_agents_load(view)
      assert assigns(view)[:agents] |> Enum.map(& &1.id) == [agent_id()]

      :sys.replace_state(view.pid, fn state ->
        %{
          state
          | socket: %{
              state.socket
              | assigns: Map.put(state.socket.assigns, :current_node, remote_node)
            }
        }
      end)

      send(view.pid, {:agent_removed, agent_id(), remote_node})
      flush_agent_events(view)

      assert assigns(view)[:agents] == []
    end

    # NOTE: the "foreign-node events are ignored" contract is covered by
    # "agent event coalescing → foreign-node events are dropped before
    # buffering", which injects the same four event shapes and asserts the same
    # buffer / flush-timer / refresh / tree state (plus `foreign != node()`).
  end

  describe "agent_updated message_count gating" do
    # The {:agent_updated, id, changed_fields, node} broadcast carries
    # :message_count whenever the agent's context changed (the contract).
    # The selected-agent history refetch is gated on it via HistoryGate:
    # fetch only when the count moved vs the gate's last-seen entry.

    test "refetches selected history only when message_count moved on", %{conn: conn} do
      seed_agent(agent_id(), [
        %ReqLLM.Message{role: :user, content: [%{text: "hi"}], metadata: %{turn: 1}}
      ])

      counter = start_history_counter()
      Application.put_env(:evo_dash, :agents_history_runner, counting_history_runner(counter))
      on_exit(&clear_agents_env/0)

      {:ok, view, _html} = live(conn, ~p"/agents")
      flush_agents_load(view)

      view |> element("#agent-card-#{agent_id()}") |> render_click()
      wait_until(fn -> render(view) =~ "fake message 1" end)
      assert Agent.get(counter, & &1) == 1

      # ── (1) UNCHANGED count: the gate suppresses the refetch ────────────
      # Same :message_count — the merge still applies (proven by the status
      # change), but no history re-transfer is spawned.
      send(view.pid, {:agent_updated, agent_id(), [message_count: 1, status: :waiting], node()})
      flush_agent_events(view)

      assert render(view) =~ "WAITING"
      assert Agent.get(counter, & &1) == 1

      # ── (2) NO :message_count key: nothing context-related moved ────────
      send(view.pid, {:agent_updated, agent_id(), [status: :waiting], node()})
      flush_agent_events(view)

      assert render(view) =~ "WAITING"
      assert Agent.get(counter, & &1) == 1

      # ── (3) MOVED count: the refetch fires and the tail renders ─────────
      send(view.pid, {:agent_updated, agent_id(), [message_count: 2], node()})
      flush_agent_events(view)

      wait_until(fn -> Agent.get(counter, & &1) == 2 end)
      assert render(view) =~ "fake message 2"
    end
  end

  describe "agent event coalescing" do
    # The production fix buffers the high-frequency "agents" PubSub events and
    # applies them in ONE trailing-edge flush (EvoDashWeb.AgentsLive.PendingEvents,
    # coalescing window) instead of merging + re-rendering the whole tree per event.
    # These tests pin the buffer contract: coalescing, the single-timer rule,
    # node filtering BEFORE buffering, arrival-order drain, at-most-one
    # fallback refresh, at-most-one selected-agent history refetch, and the
    # real trailing-edge timer itself.
    #
    # `flush_agent_events/1` (private helper below) bypasses the timer: the
    # LiveView mailbox is FIFO, so events sent before the flush message are
    # already buffered when it is handled.

    test "a burst coalesces into one flush and spawns at most one fallback refresh", %{conn: conn} do
      # Count the authoritative list reads (the initial async load + refreshes).
      calls = start_supervised!({Agent, fn -> 0 end})
      id = agent_id()

      # Captured in the TEST process: the runner stub executes inside the async
      # load Task, where the process-dictionary test id is not available.
      Application.put_env(:evo_dash, :agents_list_runner, fn _node ->
        Agent.update(calls, &(&1 + 1))
        [summary_agent(id: id)]
      end)

      on_exit(&clear_agents_env/0)
      seed_agent(agent_id(), [])

      {:ok, view, _html} = live(conn, ~p"/agents")
      flush_agents_load(view)
      # The page load may be entered more than once (dead render + connected
      # mount), so count the DELTA caused by the bursts below.
      before = Agent.get(calls, & &1)
      assert assigns(view)[:refresh_seq] == 0
      assert assigns(view)[:agents] |> Enum.map(& &1.id) == [agent_id()]

      # Three rapid registrations: two direct sends (the injection shortcut the
      # node-identity tests use) and ONE REAL PubSub broadcast, proving the
      # true emitter path is coalesced too — not just direct send/2.
      send(
        view.pid,
        {:agent_registered, 2,
         summary_agent(id: 2, parent_id: agent_id(), status: :pending, objective: "child two"),
         node()}
      )

      send(
        view.pid,
        {:agent_registered, 3,
         summary_agent(id: 3, parent_id: 2, status: :pending, objective: "child three"), node()}
      )

      Phoenix.PubSub.broadcast(
        EvoGit.PubSub,
        "agents",
        {:agent_registered, 4,
         summary_agent(id: 4, parent_id: 3, status: :pending, objective: "child four"), node()}
      )

      # Coalescing contract: NOTHING is applied on receipt. The three events
      # sit in the newest-first buffer and the tree is still the pre-burst one.
      buffered = :sys.get_state(view.pid).socket.assigns
      assert length(buffered.pending_agent_events) == 3
      assert buffered.agent_flush_scheduled == true
      assert Enum.map(buffered.agents, & &1.id) == [agent_id()]

      # ONE flush applies all three, in arrival order.
      flush_agent_events(view)

      agents = assigns(view)[:agents]
      assert Enum.map(agents, & &1.id) |> Enum.sort() == Enum.sort([agent_id(), 2, 3, 4])
      assert MapSet.equal?(assigns(view)[:new_agent_ids], MapSet.new([2, 3, 4]))

      # children/has_children are recomputed per insertion (1 → 2 → 3 → 4).
      assert Enum.find(agents, &(&1.id == agent_id())).children == [{2, :pending}]
      assert Enum.find(agents, &(&1.id == 2)).children == [{3, :pending}]
      assert Enum.find(agents, &(&1.id == 3)).children == [{4, :pending}]
      assert Enum.find(agents, &(&1.id == 4)).children == []

      for agent <- agents do
        assert agent.has_children == (agent.children != [])
      end

      assert render(view) =~ "#4"

      # None of those three fell back: every summary was complete, so the burst
      # spawned NO authoritative refresh at all.
      assert assigns(view)[:refresh_seq] == 0

      # Two updates for agent ids NOT in the tree (each ⇒ :fallback) plus one
      # normal update that merges cleanly. All three coalesce into the SAME
      # flush, which must spawn exactly ONE async refresh (not one per event).
      send(view.pid, {:agent_updated, 404, [status: :waiting], node()})
      send(view.pid, {:agent_updated, 405, [status: :waiting], node()})
      send(view.pid, {:agent_updated, agent_id(), [status: :waiting], node()})

      flush_agent_events(view)

      # The flush handler spawns AT MOST ONE refresh and bumps the monotonic
      # :refresh_seq SYNCHRONOUSLY at the spawn, so right after the synchronous
      # flush round-trip the count is already final: exactly one (a second
      # spawn would have made it 2).
      assert assigns(view)[:refresh_seq] == 1

      # The single refresh's authoritative list read lands asynchronously; wait
      # for it, then assert it happened EXACTLY once — :refresh_seq (asserted
      # above and re-asserted below) is the deterministic proof that no second
      # spawn exists, so the counter cannot exceed before + 1.
      wait_until(fn -> Agent.get(calls, & &1) >= before + 1 end)
      assert assigns(view)[:refresh_seq] == 1
      assert Agent.get(calls, & &1) == before + 1
    end

    test "the trailing-edge timer is armed only once per window and then applies the buffer", %{
      conn: conn
    } do
      seed_agent(agent_id(), [])

      {:ok, view, _html} = live(conn, ~p"/agents")
      flush_agents_load(view)
      assert assigns(view)[:agents] |> Enum.map(& &1.id) == [agent_id()]

      # A registration (arms the timer) plus five rapid updates for the SAME
      # (already-present) agent — all in one window.
      send(
        view.pid,
        {:agent_registered, 2, summary_agent(id: 2, parent_id: agent_id(), status: :pending),
         node()}
      )

      for n <- 1..5 do
        send(view.pid, {:agent_updated, agent_id(), [total_tokens: n], node()})
      end

      # :sys.get_state is a mailbox fence — all six events were processed
      # before this reply. The FIRST event armed the single timer; the other
      # five only appended to the buffer (no second schedule), and nothing was
      # applied yet.
      state = :sys.get_state(view.pid).socket.assigns
      assert state.agent_flush_scheduled == true
      assert length(state.pending_agent_events) == 6
      assert state.agents |> Enum.map(& &1.id) == [agent_id()]

      # The buffer is newest-first (prepend); drain restores ARRIVAL order.
      assert hd(state.pending_agent_events) ==
               {:agent_updated, agent_id(), [total_tokens: 5], node()}

      assert EvoDashWeb.AgentsLive.PendingEvents.drain(state.pending_agent_events) ==
               [
                 {:agent_registered, 2,
                  summary_agent(id: 2, parent_id: agent_id(), status: :pending), node()}
               ] ++
                 for(n <- 1..5, do: {:agent_updated, agent_id(), [total_tokens: n], node()})

      # Let the REAL trailing-edge timer fire (no manual flush here): the
      # arrival of an empty buffer is the deterministic proof that the timer
      # (not a manual flush) applied it.
      wait_until(fn -> assigns(view)[:pending_agent_events] == [] end)

      assert assigns(view)[:agents] |> Enum.map(& &1.id) |> Enum.sort() ==
               Enum.sort([agent_id(), 2])

      assert assigns(view)[:agent_flush_scheduled] == false
      assert Enum.find(assigns(view)[:agents], &(&1.id == agent_id())).total_tokens == 5
      assert render(view) =~ "#2"
    end

    test "foreign-node events are dropped before buffering", %{conn: conn} do
      seed_agent(agent_id(), [])

      {:ok, view, _html} = live(conn, ~p"/agents")
      flush_agents_load(view)
      assert assigns(view)[:agents] |> Enum.map(& &1.id) == [agent_id()]

      foreign = :some_other_node@host
      assert foreign != node()

      send(view.pid, {:agent_updated, agent_id(), [status: :running], foreign})
      send(view.pid, {:agent_removed, agent_id(), foreign})
      send(view.pid, {:agent_registered, 2, summary_agent(id: 2), foreign})
      send(view.pid, {:agents_updated, foreign})

      # No flush call here: a flush would reset :agent_flush_scheduled itself
      # and make the assertion vacuous. :sys.get_state is the FIFO fence.
      state = :sys.get_state(view.pid).socket.assigns
      assert state.pending_agent_events == []
      assert state.agent_flush_scheduled == false
      assert state.pending_agents_refresh == false
      assert state.refresh_seq == 0
      assert Enum.map(state.agents, & &1.id) == [agent_id()]
      assert Enum.find(state.agents, &(&1.id == agent_id())).status == :running
    end

    test "a burst refetches the selected agent's history at most once — and never without :message_count",
         %{conn: conn} do
      seed_agent(agent_id(), [
        %ReqLLM.Message{role: :user, content: [%{text: "hi"}], metadata: %{turn: 1}}
      ])

      counter = start_history_counter()
      Application.put_env(:evo_dash, :agents_history_runner, counting_history_runner(counter))
      on_exit(&clear_agents_env/0)

      {:ok, view, _html} = live(conn, ~p"/agents")
      flush_agents_load(view)

      # Selecting the agent fetches its history once (no gate entry yet).
      view |> element("#agent-card-#{agent_id()}") |> render_click()
      wait_until(fn -> render(view) =~ "fake message 1" end)
      assert Agent.get(counter, & &1) == 1

      before = Agent.get(counter, & &1)

      # ── The inverse contract first: changed_fields WITHOUT :message_count
      # never means "the context grew", so no fetch is spawned even though the
      # row merges (tokens fold in, last status wins).
      send(view.pid, {:agent_updated, agent_id(), [status: :waiting], node()})
      send(view.pid, {:agent_updated, agent_id(), [total_tokens: 123], node()})
      send(view.pid, {:agent_updated, agent_id(), [status: :running], node()})
      flush_agent_events(view)

      assert assigns(view)[:previous_statuses][agent_id()] == :running
      assert Enum.find(assigns(view)[:agents], &(&1.id == agent_id())).total_tokens == 123
      # Exhaustive: refetch_selected_history/1 sets :history_loading_agent_id
      # synchronously at spawn (in-flight) and bumps the counter on completion
      # (finished), so both failure modes are caught without a timing window.
      assert assigns(view)[:history_loading_agent_id] == nil
      assert Agent.get(counter, & &1) == before

      # ── Three rapid context-growth updates for the SELECTED agent — each
      # carries :message_count (the contract). The flush must refetch ONCE for
      # the whole burst, not once per event.
      send(view.pid, {:agent_updated, agent_id(), [message_count: 2, status: :waiting], node()})
      send(view.pid, {:agent_updated, agent_id(), [message_count: 3], node()})
      send(view.pid, {:agent_updated, agent_id(), [message_count: 4], node()})

      flush_agent_events(view)

      # refetch_selected_history/1 has no other caller and the buffer is now
      # drained with no flush timer armed, so a second fetch is structurally
      # impossible (no timing window needed).
      wait_until(fn -> Agent.get(counter, & &1) >= before + 1 end)
      assert assigns(view)[:pending_agent_events] == []
      refute assigns(view)[:agent_flush_scheduled]
      assert Agent.get(counter, & &1) == before + 1
    end

    # NOTE: "the trailing-edge timer applies the buffer without a manual
    # flush" is the second half of "the trailing-edge timer is armed only once
    # per window and then applies the buffer" above (same real-timer wait).
  end

  describe "compression threshold" do
    # Each compression % bar prefers the agent summary's OWN
    # `compression_threshold` (the core derives it per model context window).
    # The node's [:llm, :compression_threshold_tokens] resolved-config value is
    # the fallback, and 180_000 is a LAST-RESORT fallback only (the setting is
    # optional — nil means "derive it per model").

    test "ThresholdCache.resolve chain: per-agent → node → 180_000 last resort" do
      # Node-level extraction (a resolved config, an error, and a non-map).
      assert ThresholdCache.threshold_from_config(
               {:ok, %{llm: %{compression_threshold_tokens: 42_000}}}
             ) == 42_000

      assert ThresholdCache.threshold_from_config({:error, :timeout}) == 180_000
      assert ThresholdCache.threshold_from_config({:ok, nil}) == 180_000

      # The setting is OPTIONAL in the core (nil = derive it from the model's
      # context window), so every unusable shape must fall through to the
      # 180_000 last resort — never crash the bar's division.
      for config <- [
            %{llm: %{compression_threshold_tokens: nil}},
            %{llm: nil},
            %{},
            %{llm: %{compression_threshold_tokens: 0}},
            %{llm: %{compression_threshold_tokens: -42_000}},
            %{llm: %{compression_threshold_tokens: "42_000"}}
          ] do
        assert ThresholdCache.threshold_from_config({:ok, config}) == 180_000
      end

      # Per-agent precedence: atom-keyed (native RemoteAPI summary) and
      # string-keyed (defensive read) BOTH win over the node-level value…
      assert ThresholdCache.threshold_for_agent(%{compression_threshold: 100_000}, 42_000) ==
               100_000

      assert ThresholdCache.threshold_for_agent(%{"compression_threshold" => 50_000}, 42_000) ==
               50_000

      # …while absent/nil/non-integer/non-positive per-agent values fall back,
      # and an unusable node-level fallback lands on the last resort.
      for summary <-
            [%{}, %{compression_threshold: nil}, %{compression_threshold: 0}] ++
              [
                %{compression_threshold: 12.5},
                %{compression_threshold: "1"},
                nil
              ] do
        assert ThresholdCache.threshold_for_agent(summary, 42_000) == 42_000
      end

      assert ThresholdCache.threshold_for_agent(%{}, nil) == 180_000
      assert ThresholdCache.threshold_for_agent(%{}, 0) == 180_000

      assert ThresholdCache.default_threshold() == 180_000
    end

    test "the bar divides by the per-agent threshold, else the configured node one", %{
      conn: conn
    } do
      # THREE agents, ONE mount: the node-level 42_000 must be used where the
      # summary carries no usable threshold (the old bug divided by the
      # 100_000 struct default), while an atom- or string-keyed per-agent value
      # overrides it.
      id = agent_id()

      install_agents([
        # No per-agent threshold ⇒ 21_000 / 42_000 = 50%.
        summary_agent(id: id, total_tokens: 21_000),
        # Atom-keyed 100_000 wins over the node's 42_000 (which would render 100%).
        summary_agent(id: 2, total_tokens: 50_000, compression_threshold: 100_000),
        # String-keyed 50_000 wins too (the node value would render 59%).
        summary_agent(id: 3, total_tokens: 25_000)
        |> Map.put("compression_threshold", 50_000)
      ])

      Application.put_env(:evo_dash, :agents_config_runner, fn _node ->
        {:ok, %{llm: %{compression_threshold_tokens: 42_000}}}
      end)

      on_exit(&clear_agents_env/0)

      {:ok, view, _html} = live(conn, ~p"/agents")
      flush_agents_load(view)

      # The computation itself, for all three agents.
      for {agent_id, threshold, pct} <- [{id, 42_000, 50}, {2, 100_000, 50}, {3, 50_000, 50}] do
        agent = assigns(view)[:agents] |> Enum.find(&(&1.id == agent_id))
        assert agent.compression_threshold == threshold
        assert agent.compression_pct == pct
      end

      # The rendered bar agrees (21_000 / 42_000 = 50%, never the 100_000 default's 21%).
      view |> element("#agent-card-#{id}") |> render_click()
      view |> element("button[phx-click='toggle_usage']") |> render_click()
      html = render(view)

      assert html =~ "(50%)"
      refute html =~ "(21%)"
    end

    test "a nil node threshold falls back to 180_000 and events recompute the bar", %{
      conn: conn
    } do
      id = agent_id()

      install_agents([summary_agent(id: id, total_tokens: 90_000)])

      # The core's OPTIONAL threshold: nil means "derive it per model".
      Application.put_env(:evo_dash, :agents_config_runner, fn _node ->
        {:ok, %{llm: %{compression_threshold_tokens: nil}}}
      end)

      on_exit(&clear_agents_env/0)

      {:ok, view, _html} = live(conn, ~p"/agents")
      flush_agents_load(view)

      current_node = node()
      assert {^current_node, 180_000, _} = assigns(view)[:threshold_cache]

      agent = assigns(view)[:agents] |> Enum.find(&(&1.id == id))
      assert agent.compression_threshold == 180_000
      assert agent.compression_pct == 50

      # 90_000 / 180_000 = 50% — a nil threshold must not crash the bar.
      view |> element("#agent-card-#{id}") |> render_click()
      view |> element("button[phx-click='toggle_usage']") |> render_click()
      assert render(view) =~ "(50%)"

      # A REGISTERED summary carries its own threshold (25_000 / 50_000 = 50%).
      send(
        view.pid,
        {:agent_registered, 2,
         summary_agent(id: 2, total_tokens: 25_000, compression_threshold: 50_000), node()}
      )

      flush_agent_events(view)

      registered = assigns(view)[:agents] |> Enum.find(&(&1.id == 2))
      assert registered.compression_threshold == 50_000
      assert registered.compression_pct == 50

      # An UPDATED threshold-only delta recomputes the bar: 25_000 / 25_000 = 100%.
      send(view.pid, {:agent_updated, 2, [compression_threshold: 25_000], node()})
      flush_agent_events(view)

      updated = assigns(view)[:agents] |> Enum.find(&(&1.id == 2))
      assert updated.compression_threshold == 25_000
      assert updated.compression_pct == 100

      # A nil threshold delta means "unknown" — the previous denominator is kept
      # (never a division by nil); total_tokens still drives the pct.
      send(
        view.pid,
        {:agent_updated, 2, [compression_threshold: nil, total_tokens: 12_500], node()}
      )

      flush_agent_events(view)

      updated = assigns(view)[:agents] |> Enum.find(&(&1.id == 2))
      assert updated.compression_threshold == 25_000
      assert updated.compression_pct == 50
    end
  end

  describe "context meter" do
    # The Context tile is ONE meter whose full width is the model's context
    # window (`:context_window` summary key, 200_000 when absent) with a tick at
    # the compression threshold, so the bar keeps showing the remaining headroom
    # after a compression has fired. The geometry/label contract is unit-tested
    # in the sibling agents_live/context_meter_test.exs; these tests pin the
    # RENDERED attribute contract the CSS/data consumers read.

    test "fill, tick and zone boundaries across agents (and the window fallback)", %{
      conn: conn
    } do
      id = agent_id()

      # Four agents, ONE mount — the meter reflects the SELECTED agent, so the
      # zone boundaries are read by switching selection instead of remounting.
      view =
        mount_context_meter(
          conn,
          [
            # 0 tokens → empty fill, success zone, tick at 63.1%.
            summary_agent(
              id: id,
              total_tokens: 0,
              compression_threshold: 126_272,
              context_window: 200_000
            ),
            # 110_000 / 200_000 = 55% of the WINDOW (not 87% of the threshold).
            summary_agent(
              id: 2,
              total_tokens: 110_000,
              compression_threshold: 126_272,
              context_window: 200_000
            ),
            # Reaching the threshold turns the fill red at the same 63.1%.
            summary_agent(
              id: 3,
              total_tokens: 126_272,
              compression_threshold: 126_272,
              context_window: 200_000
            ),
            # Older/remote summaries omit the optional :context_window — the meter
            # must still render against the core's 200_000 default.
            summary_agent(id: 4, total_tokens: 110_000, compression_threshold: 126_272)
          ],
          # `show_usage` is reset by every selection change, so each row below
          # selects AND expands explicitly instead of relying on the mount.
          expand: false
        )

      refute Map.has_key?(summary_agent(id: 4, total_tokens: 0), :context_window)

      expected = [
        {id, "0.0", "success", "0"},
        {2, "55.0", "warning", "110000"},
        {3, "63.1", "error", "126272"},
        # A zero-token summary WITHOUT :context_window composes the same way.
        {4, "55.0", "warning", "110000"}
      ]

      for {agent_id, fill, zone, current} <- expected do
        view |> element("#agent-card-#{agent_id}") |> render_click()
        view |> element("button[phx-click='toggle_usage']") |> render_click()

        attrs = context_meter_attrs(view)

        assert attrs["data-context-fill-pct"] == fill
        assert attrs["data-context-zone"] == zone
        assert attrs["data-context-tick-pct"] == "63.1"
        assert attrs["data-context-window-tokens"] == "200000"
        assert attrs["data-context-threshold-tokens"] == "126272"
        assert attrs["data-context-current-tokens"] == current
      end

      # The defaulted window is materialized on the agent map, not just rendered.
      assert assigns(view)[:agents] |> Enum.find(&(&1.id == 4)) |> Map.get(:context_window) ==
               200_000

      # The tick's caption carries the compression token count (never the
      # "threshold unknown" copy while a threshold is known).
      html = render(view)
      assert html =~ "Compression at 126,272"
      refute html =~ "Compression threshold unknown"
    end

    test "an agent without a usable threshold hides the tick", %{conn: conn} do
      id = agent_id()

      view =
        mount_context_meter(
          conn,
          [summary_agent(id: id, total_tokens: 110_000, compression_threshold: 126_272)],
          expand: false
        )

      # Every load path materializes a threshold (ThresholdCache's 180_000 last
      # resort), so the tick-hidden branch is only reachable for an agent map
      # that carries none — strip it from the selected agent, then render
      # through a REAL event (the toggle) because replace_state alone pushes no
      # diff to the test proxy.
      :sys.replace_state(view.pid, fn state ->
        agents =
          Enum.map(state.socket.assigns.agents, &Map.delete(&1, :compression_threshold))

        %{
          state
          | socket: %{state.socket | assigns: Map.put(state.socket.assigns, :agents, agents)}
        }
      end)

      view |> element("button[phx-click='toggle_usage']") |> render_click()

      html = render(view)
      attrs = context_meter_attrs(view)

      refute Map.has_key?(attrs, "data-context-tick-pct")
      refute Map.has_key?(attrs, "data-context-threshold-tokens")
      assert attrs["data-context-fill-pct"] == "55.0"
      assert attrs["data-context-window-tokens"] == "200000"
      assert html =~ "Compression threshold unknown"
      refute html =~ "Compression at "
    end
  end

  # NOTE: config_status node-awareness (BUG 3) is covered by the "renders the
  # empty agent tree with a node-aware config status" test in "agents page",
  # which asserts the assign shape directly — a strictly stronger check than
  # "the page renders without crashing".

  describe "format_history_timestamp/1" do
    # Session-memory messages carry a wall-clock timestamp in
    # metadata[:timestamp] (stamped at the source by the :evo_git runtime;
    # Unix-seconds integer or DateTime). The dashboard shows a short LOCAL
    # time next to "Turn x" when present, and renders nothing when absent.

    test "formats every supported input shape as the same short LOCAL time" do
      # Unix-seconds integer, DateTime and ISO8601 binary all resolve to the
      # SAME local rendering — computed independently of the helper under test.
      expected = expected_local_time(@unix_seconds)
      assert expected =~ ~r/^\d{2}:\d{2}:\d{2}$/

      for input <- [
            @unix_seconds,
            DateTime.from_unix!(@unix_seconds, :second),
            "2023-11-14T22:13:20Z"
          ] do
        assert Helpers.format_history_timestamp(input) == expected
      end

      # LOCAL, not UTC (unless the machine's offset happens to be zero).
      utc = Calendar.strftime(DateTime.from_unix!(@unix_seconds, :second), "%H:%M:%S")

      if local_offset_seconds() == 0 do
        assert expected == utc
      else
        refute expected == utc
      end
    end

    test "returns nil for an absent or unparseable timestamp" do
      for input <- [nil, "not-a-time", :bogus, %{}] do
        assert Helpers.format_history_timestamp(input) == nil
      end
    end
  end

  describe "history entry rendering in the agent detail panel" do
    # ONE seeded history per rendering contract, one mount per contract: these
    # are display-only assertions over the SAME joined-history panel, so the
    # page mount (not any interaction) is the expensive part.

    test "renders the short LOCAL time next to Turn x only when the message has one", %{
      conn: conn
    } do
      seed_agent(agent_id(), [
        %ReqLLM.Message{
          role: :assistant,
          content: [%{text: "hello"}],
          metadata: %{turn: 1, timestamp: @unix_seconds}
        },
        # Multimodal parts carry no text: image/audio render as a bracketed
        # label instead of the "<empty message>" fallback.
        %ReqLLM.Message{
          role: :user,
          content: [
            %ReqLLM.Message.ContentPart{
              type: :image,
              data: <<137, 80, 78, 71, 1, 2, 3>>,
              filename: "pic.png",
              media_type: "image/png"
            },
            %ReqLLM.Message.ContentPart{type: :text, text: " look"}
          ],
          metadata: %{turn: 2}
        },
        %ReqLLM.Message{
          role: :user,
          content: [
            %ReqLLM.Message.ContentPart{
              type: :file,
              data: <<1, 2, 3>>,
              filename: "clip.mp3",
              media_type: "audio/mpeg"
            }
          ],
          metadata: %{turn: 3}
        }
      ])

      {:ok, view, _html} = live(conn, ~p"/agents")
      flush_agents_load(view)

      view |> element("#agent-card-#{agent_id()}") |> render_click()
      # History is fetched asynchronously on selection — wait for it.
      expected = Helpers.format_history_timestamp(@unix_seconds)
      html = wait_for_text(view, "Turn 3")

      # Turn 1 carries metadata[:timestamp] ⇒ the local time rides next to it.
      assert html =~ ~r/Turn 1\s*<span[^>]*>#{expected}<\/span>/
      # Turn 2 has none ⇒ no time artifact (never a placeholder).
      refute html =~ ~r/Turn 2\s*<span[^>]*>\d{2}:\d{2}:\d{2}<\/span>/

      # Image part → "[image: pic.png]" joined (no separator) with the text
      # part's " look" — non-empty content, so no empty fallback.
      assert html =~ "[image: pic.png] look"
      # Audio :file part with audio/* media_type → "[audio: clip.mp3]".
      assert html =~ "[audio: clip.mp3]"
      refute html =~ "<empty message>"
    end

    test "renders tool-call rows and tool results inline, and the modal carries full commands",
         %{conn: conn} do
      # A 260-char command: the inline panel caps shell commands at 200 chars +
      # "…", the full-message modal renders the complete command.
      long_cmd = String.duplicate("x", 260)

      seed_agent(agent_id(), [
        %ReqLLM.Message{
          role: :assistant,
          content: [],
          metadata: %{turn: 1},
          tool_calls: [
            %ReqLLM.ToolCall{
              id: "call_1",
              function: %{name: "run_bash", arguments: ~s({"command":"ls -la","timeout":30})}
            },
            %ReqLLM.ToolCall{
              id: "call_2",
              function: %{name: "read_file", arguments: ~s({"path":"./README.md"})}
            },
            %ReqLLM.ToolCall{
              id: "call_bg",
              function: %{
                name: "bash",
                arguments: ~s({"command":"npm run dev","run_in_background":true})
              }
            },
            %ReqLLM.ToolCall{
              id: "call_long",
              function: %{name: "run_bash", arguments: Jason.encode!(%{"command" => long_cmd})}
            }
          ]
        },
        # One tool result per render kind: subagent report vs plain tool result
        # vs background-job output.
        %ReqLLM.Message{
          role: :tool,
          name: "subagent_investigator",
          content: [%ReqLLM.Message.ContentPart{type: :text, text: "SUBAGENT_REPORT_BODY"}],
          metadata: %{turn: 2}
        },
        %ReqLLM.Message{
          role: :tool,
          name: "read",
          content: [%ReqLLM.Message.ContentPart{type: :text, text: "PLAIN_READ_BODY"}],
          metadata: %{turn: 3}
        },
        %ReqLLM.Message{
          role: :tool,
          name: "job_output",
          content: [%ReqLLM.Message.ContentPart{type: :text, text: "JOB_OUTPUT_BODY"}],
          metadata: %{turn: 4}
        }
      ])

      {:ok, view, _html} = live(conn, ~p"/agents")
      flush_agents_load(view)
      view |> element("#agent-card-#{agent_id()}") |> render_click()
      panel = wait_for_text(view, "Background shell call")

      # Shell call: context label + command rendered inline. Non-shell call:
      # function name + (pretty) arguments inline.
      assert panel =~ "Shell call"
      assert panel =~ "ls -la"
      assert panel =~ "read_file"
      assert panel =~ "./README.md"
      # Background shell call: its own label, command still rendered.
      assert panel =~ "Background shell call"
      assert panel =~ "npm run dev"

      # Compact mode: the long command is capped at 200 chars + a trailing "…".
      assert panel =~ String.slice(long_cmd, 0, 200) <> "…"
      refute panel =~ long_cmd

      # ONE parse for all structural assertions below.
      tree = Floki.parse_document!(panel)

      rows =
        tree
        |> Floki.find("div")
        |> Enum.filter(&(class_string(&1) =~ "flex items-start gap-2"))

      bg_row = Enum.find(rows, &(Floki.text(&1) =~ "Background shell call"))
      fg_row = Enum.find(rows, &(Floki.text(&1) =~ "Shell call"))

      assert bg_row
      assert fg_row
      # Background accent (`info` chip + clock icon) vs the plain secondary row.
      assert class_string(bg_row) =~ "bg-info/10"
      assert Floki.find(bg_row, "span.hero-clock") != []
      refute class_string(fg_row) =~ "bg-info/10"
      assert Floki.find(fg_row, "span.hero-clock") == []

      # Distinct headers + accents per tool-result kind.
      assert panel =~ "Subagent Report: subagent_investigator"
      assert panel =~ "Tool Result: read"
      assert panel =~ "Background job: job_output"

      find_panel = fn class, body ->
        Enum.find(
          Floki.find(tree, "div"),
          &(class_string(&1) =~ class and Floki.text(&1) =~ body)
        )
      end

      subagent_panel = find_panel.("bg-accent/10", "SUBAGENT_REPORT_BODY")
      read_panel = find_panel.("bg-success/10", "PLAIN_READ_BODY")
      job_panel = find_panel.("bg-info/10", "JOB_OUTPUT_BODY")

      assert subagent_panel
      assert class_string(subagent_panel) =~ "text-accent"
      assert class_string(subagent_panel) =~ "border-l-2 border-accent/40"
      assert Floki.find(tree, "span.hero-user-group") != []

      assert read_panel
      assert class_string(read_panel) =~ "text-success"
      refute class_string(read_panel) =~ "border-l-2"

      assert job_panel
      assert class_string(job_panel) =~ "text-info"
      assert class_string(job_panel) =~ "border-l-2 border-info/40"

      # The full-message modal carries the SAME distinctions plus the complete
      # (untruncated) long command in a scrollable body.
      view |> element("#agent-history-entry-#{agent_id()}-0 button") |> render_click()
      modal = render(view)

      assert modal =~ "Background shell call"
      assert modal =~ "border-l-2 border-info/40"
      assert modal =~ long_cmd
      assert modal =~ "max-h-[60vh]"
    end

    test "thinking wraps in both render sites, keeps no template indent, and never leaks into the Response block",
         %{conn: conn} do
      # A LONG reasoning block must line-wrap instead of forcing a horizontal
      # scrollbar. Both render sites carry `whitespace-pre-wrap break-words`.
      # The modal's OUTER wrapper legitimately keeps `overflow-x-auto` (it
      # scrolls wide ancestor content), so the "no horizontal scroller"
      # assertion is SCOPED to the thinking <pre> itself.
      #
      # Regression (same message): on a reasoning turn the entry carries a
      # :thinking content part (mirrored into reasoning_details, which drives
      # the "Thinking" block) AND a :text part (the visible answer). The
      # Response block must be built from :text parts ONLY.
      #
      # Regression (same element): the inline thinking body is a
      # `whitespace-pre-wrap` element, so ANY newline/indentation the HEEx
      # template emits between the opening tag and the interpolation renders as
      # a spurious leading indent — the interpolation must stay flush.
      sentinel = "THINKING_SENTINEL" <> String.duplicate("A", 300)

      seed_agent(agent_id(), [
        %ReqLLM.Message{
          role: :assistant,
          content: [
            %ReqLLM.Message.ContentPart{type: :thinking, text: "REASONING_TOKEN"},
            %ReqLLM.Message.ContentPart{type: :text, text: "RESPONSE_TOKEN"}
          ],
          reasoning_details: [%{text: sentinel}],
          metadata: %{turn: 1}
        }
      ])

      {:ok, view, _html} = live(conn, ~p"/agents")
      flush_agents_load(view)
      view |> element("#agent-card-#{agent_id()}") |> render_click()
      panel = wait_for_text(view, "Thinking")

      # Inline panel: the thinking body wraps.
      assert panel =~ "whitespace-pre-wrap break-words"

      [thinking_body] =
        panel
        |> Floki.parse_document!()
        |> Floki.find("#agent-history-entry-#{agent_id()}-0 .whitespace-pre-wrap.break-words")

      assert Floki.attribute(thinking_body, "class") == ["whitespace-pre-wrap break-words"]

      # Floki.text/1 KEEPS the whitespace the template indents around the
      # content (see the `text/2` helper), so a leading whitespace character
      # here is exactly the bug — the pre-wrap element renders it verbatim.
      inline_text = Floki.text(thinking_body)
      refute inline_text =~ ~r/^\s/
      assert String.starts_with?(inline_text, "THINKING_SENTINEL")

      # Full-message modal: the Thinking <pre> wraps and never introduces its
      # own horizontal scroller; the Response <pre> carries the :text part only.
      view |> element("#agent-history-entry-#{agent_id()}-0 button") |> render_click()
      modal_html = render(view)

      assert modal_html =~ ~r/<pre class="text-sm whitespace-pre-wrap break-words bg-warning\/10/

      modal_pre_classes =
        modal_html
        |> Floki.parse_document!()
        |> Floki.find("pre")
        |> Enum.map(&List.first(Floki.attribute(&1, "class")))

      thinking_pre_class =
        Enum.find(modal_pre_classes, &(is_binary(&1) and &1 =~ "bg-warning/10"))

      refute is_nil(thinking_pre_class)
      assert thinking_pre_class =~ "whitespace-pre-wrap"
      assert thinking_pre_class =~ "break-words"
      refute thinking_pre_class =~ "overflow-x-auto"

      # No tool calls on this message, so the modal's only <pre> pair is
      # Thinking (from reasoning_details) then Response (from :text parts).
      [thinking_pre, response_pre] =
        modal_html
        |> Floki.parse_document!()
        |> Floki.find("#full-message-modal")
        |> Floki.find("pre")

      assert Floki.text(thinking_pre) =~ "THINKING_SENTINEL"
      assert Floki.text(response_pre) =~ "RESPONSE_TOKEN"
      refute Floki.text(response_pre) =~ "REASONING_TOKEN"
    end
  end

  describe "send_agent_message optimistic display" do
    # The optimistic-display flow (commit 04c82f82): sending a user message
    # appends it to the @optimistic_messages assign and it renders in the
    # agent's chat history with a pending hint until the agent drains it into
    # context on its next turn (see EvoDashWeb.AgentsLive.OptimisticMessages).
    # A missing agent must surface as a failure flash, not a false success.

    test "successfully sent message appears optimistically in the chat history", %{conn: conn} do
      seed_agent(agent_id(), [])

      {:ok, view, _html} = live(conn, ~p"/agents")
      flush_agents_load(view)

      # Select the agent to open its detail panel (renders the chat history).
      view |> element("#agent-card-#{agent_id()}") |> render_click()
      # Open the send-message modal for the running agent.
      view |> element("button[phx-click='open_send_message']") |> render_click()

      html =
        render_submit(view, "send_agent_message", %{
          "agent_id" => to_string(agent_id()),
          "message" => "hello optimistic world"
        })

      # The message text renders in the chat history...
      assert html =~ "hello optimistic world"
      # ...with the pending hint (apostrophe is HTML-escaped to &#39; in HEEx).
      assert html =~ "will be added on the agent&#39;s next turn"
      # ...and the success flash is shown.
      assert html =~ "Message sent to agent"

      # ── Flake containment (leak source) ───────────────────────────────
      # This is the ONE test in the file that performs a REAL core write:
      # `send_agent_message` → AgentScheduler → Store.put_agent_state/2,
      # which emits a synchronous {:agent_updated, agent_id(), [pending_user_messages:
      # ...]} delta AND (via broadcast_agents_updated/0) a THROTTLED
      # {:agents_updated, node} bulk signal ~200ms later
      # (EvoGit.AgentScheduler.PubSub @throttle_ms). Emitted into a LATER
      # test's socket, the bulk signal would set that test's
      # :pending_agents_refresh, arm a coalescing flush, and its authoritative
      # (ETS-backed) refresh would then ERASE that test's synthetic in-memory
      # merge — the historical cross-test flake on this file.
      #
      # Sleeping past the throttle and flushing here makes both broadcasts
      # land on THIS socket (which is torn down at the end of the test), so
      # nothing leaks past teardown. The assertions above already ran.
      Process.sleep(250)
      flush_agent_events(view)
    end

    test "missing agent shows a failure flash instead of a false success", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/agents")

      html =
        render_submit(view, "send_agent_message", %{
          "agent_id" => "999",
          "message" => "hello"
        })

      assert html =~ "Failed to send message"
      assert html =~ "not_found"
      refute html =~ "Message sent to agent"
    end
  end

  describe "optimistic message pruning after compression" do
    # BUG fix: an already-drained optimistic message used to come back as a
    # PERMANENT "Pending" ghost. The optimistic entry was deduped only at render
    # time against the fetched history, so once the core's context compression
    # folded the real user entry into a summary the ghost reappeared — forever.
    # The fix prunes `@optimistic_messages` TERMINALLY (see
    # EvoDashWeb.AgentsLive.OptimisticMessages.prune/4): on every fetched
    # history, and on every core `pending_user_messages` queue broadcast (a
    # KNOWN queue anchors "drained"), so a pruned entry can never be
    # resurrected. The second test pins the other direction — a genuinely
    # still-queued message must KEEP its pending hint.

    test "already-drained optimistic message does NOT resurrect as a pending ghost after compression",
         %{conn: conn} do
      msg = "hello optimistic world"
      seed_agent(agent_id(), [])

      {:ok, view, _html} = live(conn, ~p"/agents")
      flush_agents_load(view)

      # Select the agent to open its detail panel (renders the chat history).
      view |> element("#agent-card-#{agent_id()}") |> render_click()
      # Open the send-message modal for the running agent.
      view |> element("button[phx-click='open_send_message']") |> render_click()

      html =
        render_submit(view, "send_agent_message", %{
          "agent_id" => to_string(agent_id()),
          "message" => msg
        })

      # The message renders optimistically with the pending hint.
      assert html =~ msg
      assert html =~ "will be added on the agent&#39;s next turn"

      # ── Step 1: the realistic DRAIN ───────────────────────────────────
      # The core resets the agent's queue to [] AND the injected message lands
      # in the conversation context as a real user entry (turn 1). The
      # `pending_user_messages: []` in the delta is what anchors the queue to
      # KNOWN-drained: it is faithful to the real drain (the core broadcasts
      # the drained queue) and removes any dependence on the ordering of the
      # queue broadcast emitted by the real send above.
      update_agent_context(agent_id(), [
        %ReqLLM.Message{role: :user, content: [%{text: msg}], metadata: %{turn: 1}}
      ])

      send(
        view.pid,
        {:agent_updated, agent_id(), [message_count: 1, pending_user_messages: []], node()}
      )

      flush_agent_events(view)
      # The refetch the moved message count triggers renders the real entry.
      html = wait_for_text(view, "Turn 1")

      # Drained: the pending hint is gone for good and the optimistic bookkeeping
      # was terminally pruned — the entry is NOT merely hidden by the render-time
      # dedupe.
      refute html =~ "will be added on the agent&#39;s next turn"
      refute Map.has_key?(assigns(view)[:optimistic_messages], agent_id())

      # ── Step 2: COMPRESSION ───────────────────────────────────────────
      # The real user entry is folded into a summary and disappears from the
      # history entirely (the exact scenario that resurrected the ghost). The
      # queue stays KNOWN-drained.
      update_agent_context(agent_id(), [
        %ReqLLM.Message{role: :system, content: [%{text: "sys"}], metadata: %{turn: 0}},
        %ReqLLM.Message{role: :user, content: [%{text: "initial"}], metadata: %{turn: 0}},
        %ReqLLM.Message{
          role: :assistant,
          content: [%{text: "summary"}],
          metadata: %{turn: 1}
        }
      ])

      send(
        view.pid,
        {:agent_updated, agent_id(), [message_count: 3, pending_user_messages: []], node()}
      )

      flush_agent_events(view)
      html = wait_for_text(view, "summary")

      # No pending ghost resurfaced.
      refute html =~ "will be added on the agent&#39;s next turn"

      # ── Flake containment (leak source) ───────────────────────────────
      # This test performs a REAL core write (send_agent_message →
      # AgentScheduler → Store.put_agent_state/2), whose
      # broadcast_agents_updated/0 THROTTLED {:agents_updated, node} bulk signal
      # lands ~200ms later (EvoGit.AgentScheduler.PubSub @throttle_ms). Emitted
      # into a LATER test's socket, the bulk signal would set that test's
      # :pending_agents_refresh, arm a coalescing flush, and its authoritative
      # (ETS-backed) refresh would then ERASE that test's synthetic in-memory
      # merge — the historical cross-test flake on this file.
      #
      # Sleeping past the throttle and flushing here makes the broadcast land on
      # THIS socket (which is torn down at the end of the test), so nothing
      # leaks past teardown. The assertions above already ran.
      Process.sleep(250)
      flush_agent_events(view)
    end

    test "a genuinely queued (not-yet-drained) message STILL renders its pending hint",
         %{conn: conn} do
      msg = "hello optimistic world"
      seed_agent(agent_id(), [])

      {:ok, view, _html} = live(conn, ~p"/agents")
      flush_agents_load(view)

      view |> element("#agent-card-#{agent_id()}") |> render_click()
      view |> element("button[phx-click='open_send_message']") |> render_click()

      html =
        render_submit(view, "send_agent_message", %{
          "agent_id" => to_string(agent_id()),
          "message" => msg
        })

      assert html =~ msg
      assert html =~ "will be added on the agent&#39;s next turn"

      # A history refetch that does NOT contain the message while the core's
      # queue STILL holds it: the queue is the authority — the entry is kept.
      update_agent_context(agent_id(), [
        %ReqLLM.Message{
          role: :user,
          content: [%{text: "some other real message"}],
          metadata: %{turn: 1}
        }
      ])

      send(
        view.pid,
        {:agent_updated, agent_id(), [message_count: 1, pending_user_messages: [msg]], node()}
      )

      flush_agent_events(view)
      html = wait_for_text(view, "some other real message")

      # Still pending: the hint survives and the optimistic bookkeeping is kept.
      assert html =~ "will be added on the agent&#39;s next turn"
      assert Map.has_key?(assigns(view)[:optimistic_messages], agent_id())

      # ── Flake containment (leak source) ───────────────────────────────
      # Same REAL core write as above: its THROTTLED {:agents_updated, node}
      # bulk signal (~200ms, EvoGit.AgentScheduler.PubSub @throttle_ms) is
      # awaited and flushed here so it lands on THIS socket (torn down at
      # teardown) instead of into a later test, where its authoritative
      # ETS-backed refresh would erase that test's synthetic in-memory merge —
      # the historical cross-test flake on this file.
      Process.sleep(250)
      flush_agent_events(view)
    end
  end

  describe "safe_text/1" do
    # BUG fix: message content / tool-call arguments that are Maps (not strings)
    # crashed the LiveView with Protocol.UndefinedError: protocol
    # Phoenix.HTML.Safe not implemented for Map. safe_text/1 converts any value
    # to an HTML-safe string before it is rendered in HEEx.

    test "converts every scalar/list/term shape to an HTML-safe string" do
      # The crash report's exact value (a Map raised Phoenix.HTML.Safe) — the
      # regression this helper exists for.
      map = %{
        "commit_id" => "",
        "objective" => "Investigate and fix the GitHub Actions...",
        "path" => "./.github/workflows"
      }

      result = Helpers.safe_text(map)

      assert is_binary(result)
      assert result =~ "objective: Investigate"
      assert result =~ "path: ./.github/workflows"

      # Any value at all must survive html_escape/1 — a total function, never a
      # protocol crash in the HEEx template.
      for value <- [
            nil,
            "hello world",
            map,
            %{"a" => %{"n" => 1}},
            ["a", "b"],
            [1, 2, 3],
            :an_atom,
            42
          ] do
        assert is_binary(Helpers.safe_text(value))
        assert match?({:safe, _}, Phoenix.HTML.html_escape(Helpers.safe_text(value)))
      end
    end

    test "sorts map keys, joins list items and inspects non-string leaves" do
      # Flat map: alphabetically sorted `key: value` lines (an empty value stays
      # an empty string, not "nil").
      assert Helpers.safe_text(%{"commit_id" => "", "objective" => "foo", "path" => "./x"}) ==
               "commit_id: \nobjective: foo\npath: ./x"

      # Nested non-string leaf → inspect/1.
      nested = Helpers.safe_text(%{"args" => %{"limit" => 10}, "name" => "sub_agent"})

      assert nested =~ "args:"
      assert nested =~ "%{\"limit\" => 10}"
      assert nested =~ "name: sub_agent"

      # Lists join on newlines; non-string elements fall back to inspect/1.
      assert Helpers.safe_text(["a", "b", "c"]) == "a\nb\nc"
      assert Helpers.safe_text([1, 2, 3]) =~ "[1, 2, 3]"

      # Arbitrary terms fall back to inspect/1.
      assert Helpers.safe_text(:an_atom) == ":an_atom"
      assert Helpers.safe_text(42) == "42"
    end
  end

  describe "HistoryGate" do
    # The per-agent "which message count did I fetch" gate — the single reason
    # a burst of agent updates cannot stampede the history endpoint.

    test "need_fetch?/3 fetches on an unknown agent or a moved/nil count, and never otherwise" do
      # No entry yet (brand-new agent, or a row from a previous node — the gate
      # is reset on a node switch, agent ids are per-node).
      assert HistoryGate.need_fetch?(%{}, 1, 5)

      # A moved count.
      assert HistoryGate.need_fetch?(%{1 => 3}, 1, 5)

      # nil on EITHER side is "unknown" ⇒ fetch.
      assert HistoryGate.need_fetch?(%{1 => 5}, 1, nil)
      assert HistoryGate.need_fetch?(%{1 => nil}, 1, 5)

      # The suppression path — the whole point of the gate.
      refute HistoryGate.need_fetch?(%{1 => 5}, 1, 5)
    end

    test "record/3 stores the fetched count and known?/2 reports gate membership" do
      assert HistoryGate.record(%{}, 1, 5) == %{1 => 5}
      assert HistoryGate.record(%{1 => 3}, 1, 5) == %{1 => 5}

      # Only THIS agent's entry counts as known (whatever its count).
      refute HistoryGate.known?(%{}, 1)
      refute HistoryGate.known?(%{2 => 5}, 1)
      assert HistoryGate.known?(%{1 => 5}, 1)
      assert HistoryGate.known?(%{1 => nil}, 1)
    end
  end

  describe "LoadData" do
    test "load/2 builds the full result shape with the configured threshold" do
      Application.put_env(:evo_dash, :agents_list_runner, fn _node ->
        [summary_agent(id: 7, total_tokens: 21_000)]
      end)

      Application.put_env(:evo_dash, :agents_config_runner, fn _node ->
        {:ok, %{llm: %{compression_threshold_tokens: 42_000}}}
      end)

      on_exit(&clear_agents_env/0)

      assert {:ok, %{agents: [agent], config_status: _, threshold_cache: cache}} =
               LoadData.load(node(), nil)

      assert agent.id == 7
      assert agent.message_count == 0
      assert agent.compression_threshold == 42_000
      assert agent.compression_pct == 50
      current_node = node()
      assert {^current_node, 42_000, _} = cache
    end
  end

  describe "task broadcast handling" do
    # Every LiveView subscribes to the "tasks" PubSub topic via
    # EvoDashWeb.LiveHooks.NodeAware.on_mount/4 (registered by `use EvoDashWeb,
    # :live_view`). AgentsLive forwards the node-identity task broadcasts to
    # NodeAware.handle_task_info/2 — node-filtered (only the viewed node's
    # events schedule a reload) and debounced (trailing-edge debounce via
    # :node_aware_reload_tasks) — plus the :node_aware_reload_tasks
    # self-message. These tests guard the handle_info clauses against the
    # FunctionClauseError crash class that previously slipped through
    # (AgentsLive had NO task-broadcast clauses and crashed on any
    # {:task_updated, _, status, node} / {:task_deleted, _, node} message).

    test "matching-node task broadcasts never crash and each schedules a debounced reload",
         %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/agents")
      flush_agents_load(view)

      # The three matching-node shapes: the :finalizing status transition
      # (observed crashing in production), a deletion, and a review-only
      # mutation carried as status nil. All three run on ONE socket — the
      # crash class is per-clause, so one mount proves every clause, and the
      # two-phase wait proves the debounce was scheduled AND cleared each time.
      for event <- [
            {:task_updated, "test-finalizing", :finalizing, node()},
            {:task_deleted, "test-deleted", node()},
            {:task_updated, "test-review", nil, node()}
          ] do
        Phoenix.PubSub.broadcast(EvoGit.PubSub, "tasks", event)

        # Phase 1: the event is processed and the debounce is scheduled.
        wait_until(fn -> assigns(view)[:tasks_reload_pending] == true end)

        # Phase 2: the debounce fires and reload_tasks clears the flag.
        wait_until(fn -> assigns(view)[:tasks_reload_pending] == false end)
      end

      # render/1 flushes pending messages synchronously; a crash would propagate here.
      html = render(view)
      assert is_binary(html)
      assert html =~ "Agent Tree"
    end

    test "foreign-node {:task_updated, _, :finalizing, remote} is ignored (no crash, no reload)",
         %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/agents")
      flush_agents_load(view)

      # Event from a DIFFERENT BEAM node: the node filter must drop it BEFORE
      # the debounce is scheduled.
      Phoenix.PubSub.broadcast(
        EvoGit.PubSub,
        "tasks",
        {:task_updated, "test-finalizing", :finalizing, :remote@elsewhere}
      )

      # The :sys.get_state read behind assigns/1 is a mailbox round-trip, so it
      # returns only AFTER the LiveView processed the broadcast above — the
      # event was definitely handled, not still in flight.
      assert assigns(view)[:tasks_reload_pending] == false

      # Then sample across the debounce window (:node_aware_reload_debounce_ms,
      # 10ms in tests): the reload-pending flag must never become TRUE. 40ms is
      # 4x the debounce — the whole window in which a spurious schedule could
      # fire — where the previous 400ms window made this the slowest test in
      # the file without strengthening the assertion.
      deadline = System.monotonic_time(:millisecond) + 40

      check_no_reload = fn check_no_reload ->
        assert assigns(view)[:tasks_reload_pending] == false

        if System.monotonic_time(:millisecond) < deadline do
          Process.sleep(10)
          check_no_reload.(check_no_reload)
        end
      end

      check_no_reload.(check_no_reload)

      html = render(view)
      assert is_binary(html)
      assert html =~ "Agent Tree"
    end
  end

  describe "commit history view — switcher and lazy fetch" do
    # The left pane is a segmented switcher (@left_view): :tree (default) vs
    # :commits. Switching to :commits lazily fetches the TASK-SCOPED git commit
    # graph via the :agents_commit_graph_runner seam — ONE runner call per
    # {repo_root, task_id} GROUP, resolved AT SPAWN TIME inside the
    # EvoDash.TaskSupervisor child. Every call is recorded to the TEST process as
    # the 6-tuple
    # {:commit_graph_call, node, task_id, repo_root, live_tips, opts}.
    #
    # These tests stub the seam BEFORE live/3 (composition-time resolution) and
    # synchronize on the recorded messages; the real
    # EvoDash.NodeContext.list_task_commit_graph/5 is NEVER invoked.

    test "defaults to the agent tree view and renders the segmented switcher", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/agents")
      flush_agents_load(view)

      assert assigns(view)[:left_view] == :tree
      assert render(view) =~ "Agent Tree"
      assert has_element?(view, "#left-view-tree")
      assert has_element?(view, "#left-view-commits")
    end

    test "switching to commits renders the commit-graph root", %{conn: conn} do
      install_agents([
        summary_agent(
          id: agent_id(),
          repo_root: "/repo/a",
          base_commit: "b1",
          current_commit: "c1"
        )
      ])

      install_commit_graph_runner(graph_error_responder())

      {:ok, view, _html} = live(conn, ~p"/agents")
      flush_agents_load(view)

      render_click(view, "switch_left_view", %{"view" => "commits"})

      assert assigns(view)[:left_view] == :commits
      assert assigns(view)[:commit_graph_seq] == 1

      html = render(view)
      assert html =~ "commit-graph"
      assert html =~ ~s(phx-hook="CommitGraph")
      # The tree pane (empty state) is replaced by the commit-graph view.
      refute html =~ "No agents currently registered"
    end

    test "the segment buttons toggle the left view", %{conn: conn} do
      # Pin the agent list empty so switching to commits needs no fetch (it would
      # otherwise depend on whatever the shared ETS tables hold).
      install_agents([])
      install_commit_graph_runner(graph_error_responder())

      {:ok, view, _html} = live(conn, ~p"/agents")
      flush_agents_load(view)

      assert assigns(view)[:left_view] == :tree

      view |> element("#left-view-commits") |> render_click()
      assert assigns(view)[:left_view] == :commits

      view |> element("#left-view-tree") |> render_click()
      assert assigns(view)[:left_view] == :tree
    end

    test "an unknown switched view value is a no-op", %{conn: conn} do
      install_commit_graph_runner(graph_error_responder())

      {:ok, view, _html} = live(conn, ~p"/agents")
      flush_agents_load(view)

      render_click(view, "switch_left_view", %{"view" => "bogus"})

      assert assigns(view)[:left_view] == :tree
      # An unknown view value is a no-op: nothing spawns a fetch (which would set
      # :commit_graph_loading synchronously) and nothing arms a throttled one-shot
      # tick (which would set :commit_graph_tick_scheduled) — both failure modes
      # are synchronous assigns. The 0-timeout refute is the other, equally
      # deterministic half: it proves no runner call has ALREADY been delivered.
      # Neither check uses a wall clock. (No legit call exists here — the view
      # never switched — so the mailbox is clean and the refute cannot false-fail.)
      assert assigns(view)[:commit_graph_loading] == false
      assert assigns(view)[:commit_graph_tick_scheduled] == false
      refute_receive {:commit_graph_call, _, _, _, _, _}, 0
    end

    test "viewing the tree never invokes the commit runner", %{conn: conn} do
      install_agents([
        summary_agent(
          id: agent_id(),
          repo_root: "/repo/a",
          base_commit: "b1",
          current_commit: "c1"
        )
      ])

      install_commit_graph_runner(graph_error_responder())

      {:ok, view, _html} = live(conn, ~p"/agents")
      flush_agents_load(view)

      # The default tree view must never trigger a git RPC. Both failure modes of
      # a git RPC are synchronous assigns (a spawned fetch sets
      # :commit_graph_loading; an armed throttled tick sets
      # :commit_graph_tick_scheduled), and the 0-timeout refute adds the
      # "already delivered" half: the injected runner is a fast stub and
      # flush_agents_load/1 renders (draining the mailbox) for up to 5s, so a
      # fetch spawned by a bug would very likely have completed already — its
      # {:commit_graph_call, …} would then sit in the mailbox with BOTH assigns
      # back to false. The three checks together are exhaustive (in flight /
      # finished) and completely wall-clock free.
      assert assigns(view)[:commit_graph_loading] == false
      assert assigns(view)[:commit_graph_tick_scheduled] == false
      refute_receive {:commit_graph_call, _, _, _, _, _}, 0
    end

    test "switching to commits fetches once per {repo_root, task_id} group with its live tips and the limit",
         %{conn: conn} do
      install_agents([
        summary_agent(
          id: agent_id(),
          repo_root: "/repo/a",
          base_commit: "b1",
          current_commit: "c1"
        ),
        summary_agent(
          id: agent_id() + 1,
          repo_root: "/repo/b",
          base_commit: "b2",
          current_commit: "c2"
        ),
        # A SECOND agent in /repo/a on the SAME task → both of its live tips
        # travel in ONE call for that group (de-duplicated).
        summary_agent(
          id: agent_id() + 2,
          repo_root: "/repo/a",
          base_commit: "b1b",
          current_commit: "c1b"
        )
      ])

      install_commit_graph_runner(graph_partial_responder("/repo/a"))

      {:ok, view, _html} = live(conn, ~p"/agents")
      flush_agents_load(view)

      render_click(view, "switch_left_view", %{"view" => "commits"})

      # Exactly ONE call per {repo_root, task_id} group, carrying that group's
      # de-duplicated LIVE TIPS (the non-ended agents' current commits, in agent
      # order) and the limit.
      assert_receive {:commit_graph_call, _node, "task-1", "/repo/a", tips_a, opts_a}, 1000
      assert_receive {:commit_graph_call, _node, "task-1", "/repo/b", tips_b, opts_b}, 1000

      assert opts_a == [limit: 100]
      assert opts_b == [limit: 100]
      assert tips_a == ["c1", "c1b"]
      assert tips_b == ["c2"]

      # Every runner call of ONE fetch precedes its async result, so once the
      # loading flag clears the whole fetch is done: an extra call could only
      # come from a SECOND fetch, and no second fetch is in flight (loading
      # false) or armed as a throttled one-shot (tick false). Deterministic —
      # no window needed.
      wait_until(fn -> assigns(view)[:commit_graph_loading] == false end)
      assert assigns(view)[:commit_graph_tick_scheduled] == false
      refute_receive {:commit_graph_call, _, _, _, _, _}, 0
    end

    test "agents lacking commit metadata are skipped by the fetch", %{conn: conn} do
      install_agents([
        summary_agent(
          id: agent_id(),
          repo_root: "/repo/a",
          base_commit: "b1",
          current_commit: "c1"
        ),
        # repo_root nil → skipped
        summary_agent(id: agent_id() + 1, repo_root: nil),
        # missing base_commit → skipped
        summary_agent(id: agent_id() + 2, repo_root: "/repo/c", base_commit: nil),
        # missing current_commit → skipped
        summary_agent(id: agent_id() + 3, repo_root: "/repo/d", current_commit: nil),
        # missing task_id → skipped (the RPC is task-scoped; the durable task ref
        # is what makes a recycled agent's commits reachable)
        summary_agent(
          id: agent_id() + 4,
          repo_root: "/repo/e",
          base_commit: "b5",
          current_commit: "c5",
          task_id: nil
        )
      ])

      install_commit_graph_runner(graph_error_responder())

      {:ok, view, _html} = live(conn, ~p"/agents")
      flush_agents_load(view)

      render_click(view, "switch_left_view", %{"view" => "commits"})

      # Only the fully-eligible agent's group is fetched — exactly one call, and
      # never for a nil/blank repo_root, commit or task_id. Once the fetch's
      # loading flag clears the whole fetch is done, so an extra call could only
      # come from a second fetch — assert none is in flight or armed.
      assert_receive {:commit_graph_call, _node, "task-1", repo_root, _tips, _opts}, 1000
      assert repo_root == "/repo/a"
      wait_until(fn -> assigns(view)[:commit_graph_loading] == false end)
      assert assigns(view)[:commit_graph_tick_scheduled] == false
      refute_receive {:commit_graph_call, _, _, _, _, _}, 0
    end
  end

  describe "commit history view — task-scoped groups" do
    # The runner is called ONCE per {repo_key, task_id} GROUP (both binaries) —
    # the task-scoped RPC resolves a task's durable refs, so two tasks sharing a
    # repo are two groups and their replies are UNIONED into the ONE
    # %{repo_key => %{commits, refs}} entry the pure assembler consumes.

    test "two agents in ONE repo with different task ids fetch as two groups", %{conn: conn} do
      install_agents([
        summary_agent(
          id: agent_id(),
          repo_root: "/repo/a",
          base_commit: "b1",
          current_commit: "c1",
          task_id: "task-1"
        ),
        summary_agent(
          id: agent_id() + 1,
          repo_root: "/repo/a",
          base_commit: "b1",
          current_commit: "c2",
          task_id: "task-2"
        )
      ])

      install_commit_graph_runner(fn "/repo/a" -> {:ok, %{commits: [], refs: %{}}} end)

      {:ok, view, _html} = live(conn, ~p"/agents")
      flush_agents_load(view)

      render_click(view, "switch_left_view", %{"view" => "commits"})

      # Same repo_key, different task_id → TWO calls, each carrying only ITS
      # task's live tips. Groups are sorted by {repo_key, task_id}.
      assert_receive {:commit_graph_call, _node, "task-1", "/repo/a", ["c1"], [limit: 100]}, 1000
      assert_receive {:commit_graph_call, _node, "task-2", "/repo/a", ["c2"], [limit: 100]}, 1000

      # Both group calls precede the fetch's async result, so once its loading
      # flag clears the fetch is done: an extra call could only come from a
      # SECOND fetch — assert none is in flight or armed as a tick.
      wait_until(fn -> assigns(view)[:commit_graph_loading] == false end)
      assert assigns(view)[:commit_graph_tick_scheduled] == false
      refute_receive {:commit_graph_call, _, _, _, _, _}, 0
    end

    test "two groups sharing a repo_key are unioned into ONE repo entry", %{conn: conn} do
      install_agents([
        summary_agent(
          id: agent_id(),
          repo_root: "/repo/a",
          base_commit: "b1",
          current_commit: "c1",
          task_id: "task-1"
        ),
        summary_agent(
          id: agent_id() + 1,
          repo_root: "/repo/a",
          base_commit: "b1",
          current_commit: "c2",
          task_id: "task-2"
        )
      ])

      # The runner is called ONCE PER GROUP in sorted {repo_key, task_id} order,
      # so a queued responder can hand each task its own commit list (both tasks
      # share the "shared" commit — git's own view of a forked repo).
      payloads =
        start_supervised!(
          {Agent,
           fn ->
             [
               {:ok,
                %{
                  commits: [
                    commit("shared", ["b1"], "shared subject"),
                    commit("c1", ["shared"])
                  ],
                  refs: %{"shared" => ["main"], "c1" => ["tag-1"]}
                }},
               {:ok,
                %{
                  commits: [
                    commit("shared", ["b1"], "shared subject"),
                    commit("c2", ["shared"])
                  ],
                  refs: %{"shared" => ["other"], "c2" => ["tag-2"]}
                }}
             ]
           end}
        )

      install_commit_graph_runner(fn "/repo/a" ->
        Agent.get_and_update(payloads, fn
          [head | tail] -> {head, tail}
          [] -> {{:error, :exhausted}, []}
        end)
      end)

      {:ok, view, _html} = live(conn, ~p"/agents")
      flush_agents_load(view)

      render_click(view, "switch_left_view", %{"view" => "commits"})

      assert_receive {:commit_graph_call, _node, "task-1", "/repo/a", ["c1"], [limit: 100]}, 1000
      assert_receive {:commit_graph_call, _node, "task-2", "/repo/a", ["c2"], [limit: 100]}, 1000

      wait_until(fn -> assigns(view)[:commit_graph_loaded] end)

      # ONE repo entry under the SHARED repo_key…
      assert %{"/repo/a" => %{commits: commits, refs: refs}} = assigns(view)[:commit_graph_raw]

      # …with both tasks' commits unioned and de-duplicated by :sha (the first
      # occurrence wins — the payloads carry an identical "shared" commit)…
      assert Enum.map(commits, & &1.sha) == ["shared", "c1", "c2"]

      # …and the ref NAME lists unioned per sha.
      assert refs == %{"shared" => ["main", "other"], "c1" => ["tag-1"], "c2" => ["tag-2"]}

      # The unioned entry assembles into ONE repo graph holding both tasks'
      # commits as their own rows.
      assert [repo] = assigns(view)[:commit_graph]
      assert repo.repo_key == "/repo/a"

      assert Enum.map(repo.agents, & &1.agent_id) |> Enum.sort() ==
               Enum.sort([agent_id(), agent_id() + 1])

      # Both agents fork from the synthesized base "b1" and share the "shared"
      # commit, so the union assembles into four rows: the fork point, the shared
      # commit, then each task's tip.
      assert Enum.map(repo.nodes, & &1.sha) |> Enum.sort() == ["b1", "c1", "c2", "shared"]
      assert repo.row_count == 4
      assert repo.node_count == 4
      assert repo.edge_count == 3
    end

    test "an all-ended group is still fetched, with no live tips", %{conn: conn} do
      install_agents([
        summary_agent(
          id: agent_id(),
          repo_root: "/repo/a",
          base_commit: "b1",
          current_commit: "c1",
          task_id: "task-1"
        ),
        summary_agent(
          id: agent_id() + 1,
          repo_root: "/repo/b",
          base_commit: "b2",
          current_commit: "c2",
          task_id: "task-2"
        )
      ])

      install_commit_graph_runner(fn _repo_root -> {:ok, %{commits: [], refs: %{}}} end)

      {:ok, view, _html} = live(conn, ~p"/agents")
      flush_agents_load(view)

      render_click(view, "switch_left_view", %{"view" => "commits"})

      assert_receive {:commit_graph_call, _node, "task-1", "/repo/a", ["c1"], [limit: 100]}, 1000
      assert_receive {:commit_graph_call, _node, "task-2", "/repo/b", ["c2"], [limit: 100]}, 1000

      # The /repo/a agent ENDS (the core recycles it) → retained, ended.
      send(view.pid, {:agent_removed, agent_id(), node()})
      flush_agent_events(view)

      assert assigns(view)[:retained_agents][agent_id()].ended == true

      # Re-enter the commits view: the now all-ended group is STILL fetched (the
      # retained agent's task ref is what holds its commits), but it contributes
      # NO live tips — only its lane.
      view |> element("#left-view-tree") |> render_click()
      view |> element("#left-view-commits") |> render_click()

      assert_receive {:commit_graph_call, _node, "task-1", "/repo/a", [], [limit: 100]}, 1000
      assert_receive {:commit_graph_call, _node, "task-2", "/repo/b", ["c2"], [limit: 100]}, 1000
    end

    test "a payload that INCLUDES the base commit renders it as ONE normal commit node",
         %{conn: conn} do
      install_agents([
        summary_agent(
          id: agent_id(),
          repo_root: "/repo/a",
          base_commit: "b1",
          current_commit: "c1"
        )
      ])

      # A task-scoped fetch walks the task's durable ref ancestry, so the base
      # commit the agent forked from can be IN the payload. It must render as a
      # normal commit node — never a duplicated synthesized base node.
      install_commit_graph_runner(fn "/repo/a" ->
        {:ok,
         %{
           commits: [commit("c1", ["b1"], "tip subject"), commit("b1", [], "base subject")],
           refs: %{}
         }}
      end)

      {:ok, view, _html} = live(conn, ~p"/agents")
      flush_agents_load(view)

      render_click(view, "switch_left_view", %{"view" => "commits"})

      assert_receive {:commit_graph_call, _node, "task-1", "/repo/a", ["c1"], [limit: 100]}, 1000
      wait_until(fn -> assigns(view)[:commit_graph_loaded] end)

      assert [repo] = assigns(view)[:commit_graph]

      # ONE node for "b1" — and it is a NORMAL commit node carrying the fetched
      # message (a synthesized base node has kind: :base and message: "").
      assert [base_node] = Enum.filter(repo.nodes, &(&1.sha == "b1"))
      assert base_node.kind == :commit
      assert base_node.message == "base subject"

      # The fork annotation still lands on it (it IS the agent's base_commit).
      assert base_node.start_ids == [agent_id()]

      # Two fetched commits → two rows, no synthesized extra node and no extra
      # lane (both commits belong to the same depth-0 agent's lane).
      assert repo.node_count == 2
      assert repo.row_count == 2
      assert repo.column_count == 1
      assert Enum.map(repo.nodes, & &1.row) == [0, 1]
      assert Enum.all?(repo.nodes, &(&1.column == 0))

      # …and the DOM holds exactly one node element for "b1", with no base label
      # (`cg-base-label` is reserved for a synthesized kind: :base node).
      html = render(view)
      dom = repo.repo_dom_id
      assert length(Floki.find(Floki.parse_document!(html), "#commit-node-#{dom}-b1")) == 1
      refute html =~ "cg-base-label"
    end
  end

  describe "commit history view — async state and interactions" do
    # A loaded commit graph is renderable AT PAGE LEVEL: the vertical commit
    # list (`components/agents_components/commit_graph_view.ex`) carries no
    # `phx-update` mode — incremental patching relies on the stable, unique
    # child ids — so LiveViewTest renders the loaded markup directly and the
    # tests below assert it from the DOM. The sibling component suite
    # (test/evo_dash_web/components/commit_graph_view_test.exs) renders the
    # component in isolation via render_component/2 (bypassing the diff path).

    test "an applied commit graph is stored and rendered as the vertical commit list",
         %{conn: conn} do
      install_agents([
        summary_agent(
          id: agent_id(),
          repo_root: "/repo/a",
          base_commit: "b1",
          current_commit: "c1"
        )
      ])

      install_commit_graph_runner(fn "/repo/a" -> {:ok, single_commit_graph_payload()} end)

      {:ok, view, _html} = live(conn, ~p"/agents")
      flush_agents_load(view)

      render_click(view, "switch_left_view", %{"view" => "commits"})

      assert_receive {:commit_graph_call, _node, "task-1", "/repo/a", ["c1"], [limit: 100]}, 1000
      wait_until(fn -> assigns(view)[:commit_graph_loaded] end)

      # The stored socket state first (the rendered DOM is asserted below).
      assert assigns(view)[:commit_graph_loading] == false
      assert assigns(view)[:commit_graph_error] == nil

      # The raw per-repo payload is stored verbatim under the repo_root key
      # (the data layer OR-unions the core's per-repo truncation flags into
      # an explicit `truncated` boolean on each merged repo map).
      assert assigns(view)[:commit_graph_raw] == %{
               "/repo/a" => %{
                 commits: [
                   %{
                     sha: "c1",
                     short_sha: "c1",
                     message: "subject line\nbody",
                     parents: ["b1"],
                     author_name: "Ada",
                     date: nil
                   }
                 ],
                 refs: %{"c1" => ["main"]},
                 truncated: false
               }
             }

      assert [repo] = assigns(view)[:commit_graph]
      assert repo.repo_name == "a"
      assert repo.node_count == 2
      assert repo.edge_count == 1
      assert repo.row_count == 2
      assert repo.column_count == 1

      # Two rows, TOP → BOTTOM: the synthesized BASE/fork node ("b1", absent from
      # the fetch) then the single real commit ("c1"). Every row is unique, so the
      # rows are exactly `0 .. node_count - 1`.
      assert [base_node, commit_node] = repo.nodes
      assert Enum.map(repo.nodes, & &1.row) == [0, 1]

      assert Map.take(base_node, [
               :sha,
               :short_sha,
               :kind,
               :row,
               :column,
               :depth,
               :message,
               :date,
               :refs
             ]) == %{
               sha: "b1",
               short_sha: "b1",
               kind: :base,
               row: 0,
               column: 0,
               depth: 0,
               message: "",
               date: nil,
               refs: []
             }

      # The base node is the agent's fork point (and it is owned by that agent).
      assert base_node.start_ids == [agent_id()]
      assert base_node.end_ids == []
      assert base_node.owner_id == agent_id()

      # The message is truncated to its first line; refs come from the payload.
      # A node carries no `:parents` field — parent links live only in `:edges`.
      assert Map.take(commit_node, [
               :sha,
               :short_sha,
               :kind,
               :row,
               :column,
               :depth,
               :message,
               :refs,
               :author_name
             ]) == %{
               sha: "c1",
               short_sha: "c1",
               kind: :commit,
               row: 1,
               column: 0,
               depth: 0,
               message: "subject line",
               refs: ["main"],
               author_name: "Ada"
             }

      assert commit_node.date == nil

      # The single fetched commit IS the agent's tip.
      assert commit_node.owner_id == agent_id()
      assert commit_node.end_ids == [agent_id()]
      assert commit_node.start_ids == []

      # One child → parent edge: the tip points back at the fork point, one row
      # ABOVE it — both in the agent's own lane (lane 0, the only agent).
      assert [edge] = repo.edges

      assert Map.take(edge, [
               :from_sha,
               :to_sha,
               :from_column,
               :from_row,
               :to_column,
               :to_row,
               :kind
             ]) ==
               %{
                 from_sha: "c1",
                 to_sha: "b1",
                 from_column: 0,
                 from_row: 1,
                 to_column: 0,
                 to_row: 0,
                 kind: :parent
               }

      assert edge.owner_id == agent_id()

      # One AGENT entry per agent — metadata only (rows are globally interleaved
      # across agents; the agent's lane is the index, not a row band), carrying
      # the depth hue and its start → end shas.
      assert [agent] = repo.agents

      assert Map.take(agent, [
               :agent_id,
               :task_local_id,
               :status,
               :depth,
               :lane,
               :color,
               :start_sha,
               :end_sha,
               :ended
             ]) ==
               %{
                 agent_id: agent_id(),
                 task_local_id: nil,
                 status: :running,
                 depth: 0,
                 lane: 0,
                 color: "#7c38dc",
                 start_sha: "b1",
                 end_sha: "c1",
                 ended: false
               }

      # ── Page-level MARKUP assertions ─────────────────────────────────────
      # The loaded graph renders at page level. Derive every id FROM THE LIVE
      # SOCKET — the repo's `repo_dom_id` and the agent id — never a hardcoded
      # dom id.
      dom = repo.repo_dom_id
      aid = agent.agent_id
      akey = to_string(aid)

      html = render(view)

      assert has_element?(view, "#commit-graph")
      assert html =~ ~s(phx-hook="CommitGraph")

      assert has_element?(view, "##{dom}")
      assert has_element?(view, "#cg-scroll-#{dom}")
      assert has_element?(view, "#cg-lane-header-#{dom}")
      assert has_element?(view, "#cg-list-#{dom}")
      assert has_element?(view, "#cg-gutter-#{dom}")
      assert has_element?(view, "#commit-node-#{dom}-c1")
      assert has_element?(view, "#commit-node-#{dom}-b1")
      assert has_element?(view, "#commit-edge-#{dom}-c1-b1")
      assert has_element?(view, "#commit-row-#{dom}-c1")
      assert has_element?(view, "#commit-row-#{dom}-b1")
      # The single agent owns lane 0 (no unowned commit → no neutral lane
      # shift): its sticky header chip is a BUTTON firing `select_agent`.
      assert has_element?(view, "#cg-lane-#{dom}-0")
      # The fork point carries the agent's START chip, the tip its END chip.
      assert has_element?(view, "#commit-agent-tag-#{dom}-b1-start-#{akey}")
      assert has_element?(view, "#commit-agent-tag-#{dom}-c1-end-#{akey}")
      # The payload's ref lands as a chip on the tip row.
      assert has_element?(view, "#commit-ref-tag-#{dom}-c1-main")

      tree = Floki.parse_document!(html)

      # No phx-update mode anywhere — incremental patching rides the stable ids.
      assert Floki.find(tree, "[phx-update]") == []

      # The graph geometry lives in ONE absolute gutter overlay
      # `<svg class="cg-gutter">` at the top-left of the relative list wrapper;
      # its `viewBox` matches the derived width/height (1 SVG unit == 1 CSS px)
      # and there is NO pan/zoom viewport — vertical scrolling is native.
      assert html =~ "viewBox="
      assert [gutter_svg] = Floki.find(tree, "svg.cg-gutter")
      assert Floki.attribute(gutter_svg, "id") == ["cg-gutter-#{dom}"]
      # 1 agent lane × @col_w 24 + @gutter_pad 12 on each side = 48 wide.
      assert Floki.attribute(gutter_svg, "viewbox") == ["0 0 48 88"]
      assert Floki.find(tree, "g.cg-viewport") == []

      # The rows are left-padded by the gutter width so they never overlap it.
      assert [rows] = Floki.find(tree, "#cg-list-#{dom} .cg-rows")
      assert Floki.attribute(rows, "style") == ["padding-left: 48px"]

      # The real commit is a `g.cg-node` gutter dot carrying the node animation
      # marker plus the sha/owner data attributes. The click contract lives on
      # the ROW (the gutter overlay is `pointer-events: none`).
      assert [node_c1] = Floki.find(tree, "#commit-node-#{dom}-c1")
      assert {"g", _, _} = node_c1

      assert node_c1
             |> Floki.attribute("class")
             |> hd()
             |> String.split()
             |> Enum.member?("cg-node")

      assert Floki.attribute(node_c1, "data-commit-graph-anim") == ["node"]
      assert Floki.attribute(node_c1, "data-cg-sha") == ["c1"]
      assert Floki.attribute(node_c1, "data-cg-agent-id") == [to_string(aid)]
      assert Floki.attribute(node_c1, "phx-click") == []

      # The synthesized base node is a gutter node too.
      assert [node_b1] = Floki.find(tree, "#commit-node-#{dom}-b1")
      assert Floki.attribute(node_b1, "data-commit-graph-anim") == ["node"]
      assert Floki.attribute(node_b1, "data-cg-sha") == ["b1"]
      assert Floki.attribute(node_b1, "data-cg-agent-id") == [to_string(aid)]

      # The child → parent link is a `path.cg-edge` rounded route. Same lane → a
      # straight vertical segment here. It is SOLID — the dashes are reserved
      # for `:merge` side parents and the agent-level `:spawn` / `:merge_back`
      # connectors, none of which this single-parent payload has.
      assert [edge_node] = Floki.find(tree, "#commit-edge-#{dom}-c1-b1")
      assert {"path", _, _} = edge_node

      assert edge_node
             |> Floki.attribute("class")
             |> hd()
             |> String.split()
             |> Enum.member?("cg-edge")

      assert Floki.attribute(edge_node, "data-commit-graph-anim") == ["edge"]
      assert Floki.attribute(edge_node, "stroke-dasharray") == []
      assert [edge_d] = Floki.attribute(edge_node, "d")
      assert edge_d =~ "M "

      # The tip ROW carries the `select_agent` contract (its owner), the row
      # animation marker, the fixed height and the sha/owner data attributes.
      assert [row_c1] = Floki.find(tree, "#commit-row-#{dom}-c1")
      assert {"div", _, _} = row_c1

      assert row_c1
             |> Floki.attribute("class")
             |> hd()
             |> String.split()
             |> Enum.member?("cg-row")

      assert Floki.attribute(row_c1, "data-commit-graph-anim") == ["row"]
      assert Floki.attribute(row_c1, "data-cg-sha") == ["c1"]
      assert Floki.attribute(row_c1, "data-cg-agent-id") == [to_string(aid)]
      assert Floki.attribute(row_c1, "style") == ["height: 44px"]
      assert Floki.attribute(row_c1, "phx-click") == ["select_agent"]
      assert Floki.attribute(row_c1, "phx-value-id") == [to_string(aid)]

      # The row shows the truncated first-line message (the body line is dropped)
      # and the `author · date` meta (no date in the payload → author only).
      assert text(row_c1, ".cg-row-sha") == "c1"
      assert text(row_c1, ".cg-row-message") == "subject line"
      assert text(row_c1, ".cg-row-meta") == "Ada"

      # The agent chips are BUTTONs firing the same `select_agent` contract, and
      # the ref chip is a non-clickable span.
      assert [start_chip] = Floki.find(tree, "#commit-agent-tag-#{dom}-b1-start-#{akey}")
      assert {"button", _, _} = start_chip
      assert Floki.attribute(start_chip, "phx-click") == ["select_agent"]
      assert Floki.attribute(start_chip, "phx-value-id") == [to_string(aid)]
      assert hd(Floki.attribute(start_chip, "class")) =~ "cg-agent-tag-start"

      assert [end_chip] = Floki.find(tree, "#commit-agent-tag-#{dom}-c1-end-#{akey}")
      assert {"button", _, _} = end_chip
      assert Floki.attribute(end_chip, "phx-value-id") == [to_string(aid)]
      assert hd(Floki.attribute(end_chip, "class")) =~ "cg-agent-tag-end"

      assert [ref_chip] = Floki.find(tree, "#commit-ref-tag-#{dom}-c1-main")
      assert {"span", _, _} = ref_chip
      assert Floki.attribute(ref_chip, "phx-click") == []
      assert text(tree, "#commit-ref-tag-#{dom}-c1-main") == "main"

      # The agent's lane-0 header chip is a BUTTON (the neutral lane would be a
      # non-clickable span) firing the `select_agent` contract, labelled with
      # the raw agent id (this fixture agent has no task_local_id).
      assert [lane_chip] = Floki.find(tree, "#cg-lane-#{dom}-0")
      assert {"button", _, _} = lane_chip
      assert Floki.attribute(lane_chip, "phx-click") == ["select_agent"]
      assert Floki.attribute(lane_chip, "phx-value-id") == [to_string(aid)]
      assert text(tree, "#cg-lane-#{dom}-0") == "T#{aid}"

      # The base row is a row too — but it shows the `base` label instead of a
      # commit message.
      assert [row_b1] = Floki.find(tree, "#commit-row-#{dom}-b1")
      assert Floki.attribute(row_b1, "data-commit-graph-anim") == ["row"]
      assert text(tree, "#commit-row-#{dom}-b1 .cg-base-label") == "base"
      assert Floki.find(row_b1, ".cg-row-message") == []

      # Nothing selected → no selection readout above the list.
      assert Floki.find(tree, "#cg-selection-readout-#{dom}") == []
    end

    test "a stale commit-graph result is dropped", %{conn: conn} do
      view = mount_loaded_commit_graph(conn)

      graph_before = assigns(view)[:commit_graph]
      raw_before = assigns(view)[:commit_graph_raw]

      # seq 0 < the loaded fetch's seq (1) → the result is stale and must be
      # ignored. The synchronous assigns/1 round-trip guarantees the message was
      # processed (mailbox FIFO) before we read the state.
      send(
        view.pid,
        {:commit_graph_loaded, node(), 0, {:ok, %{"/repo/a" => %{commits: [], refs: %{}}}}}
      )

      assert assigns(view)[:commit_graph] == graph_before
      assert assigns(view)[:commit_graph_raw] == raw_before
    end

    test "a result from a foreign node is dropped", %{conn: conn} do
      view = mount_loaded_commit_graph(conn)

      graph_before = assigns(view)[:commit_graph]

      send(
        view.pid,
        {:commit_graph_loaded, :remote@elsewhere, 99,
         {:ok, %{"/repo/a" => %{commits: [], refs: %{}}}}}
      )

      assert assigns(view)[:commit_graph] == graph_before
    end

    test "a failed refresh keeps the last good graph and records the error", %{conn: conn} do
      view = mount_loaded_commit_graph(conn)

      graph_before = assigns(view)[:commit_graph]
      raw_before = assigns(view)[:commit_graph_raw]

      send(view.pid, {:commit_graph_loaded, node(), 2, {:error, :boom}})

      assert assigns(view)[:commit_graph_error] == :boom
      assert assigns(view)[:commit_graph_loading] == false
      assert assigns(view)[:commit_graph_loaded] == true

      # The previous good graph survives a failed refresh (the view never wedges
      # on a spinner and never loses the data it already had).
      assert assigns(view)[:commit_graph] == graph_before
      assert assigns(view)[:commit_graph_raw] == raw_before
    end

    test "a failed initial load renders the error state", %{conn: conn} do
      install_agents([
        summary_agent(
          id: agent_id(),
          repo_root: "/repo/a",
          base_commit: "b1",
          current_commit: "c1"
        )
      ])

      install_commit_graph_runner(graph_error_responder())

      {:ok, view, _html} = live(conn, ~p"/agents")
      flush_agents_load(view)

      render_click(view, "switch_left_view", %{"view" => "commits"})

      wait_until(fn -> assigns(view)[:commit_graph_error] != nil end)

      # A failed INITIAL load leaves @commit_graph empty, so the commit pane
      # renders its error state.
      html = render(view)
      assert html =~ "commit-graph-error"
      assert html =~ "Could not load commit history."
    end

    test "the right-hand agent detail panel is preserved across the view switch", %{conn: conn} do
      # repo_root nil → the agent is not eligible for a commit-graph fetch, so
      # @commit_graph stays empty and the commit pane renders its empty state.
      install_agents([summary_agent(id: agent_id(), repo_root: nil)])

      {:ok, view, _html} = live(conn, ~p"/agents")
      flush_agents_load(view)

      view |> element("#agent-card-#{agent_id()}") |> render_click()

      assert has_element?(view, "#agent-detail-#{agent_id()}")
      assert render(view) =~ "##{agent_id()}"

      render_click(view, "switch_left_view", %{"view" => "commits"})

      assert assigns(view)[:left_view] == :commits
      assert assigns(view)[:selected_agent_id] == agent_id()

      # The detail column is independent of the left view — the selection and
      # its rendered panel survive the switch.
      assert has_element?(view, "#agent-detail-#{agent_id()}")
      assert render(view) =~ "##{agent_id()}"

      render_click(view, "switch_left_view", %{"view" => "tree"})

      assert assigns(view)[:left_view] == :tree
      assert assigns(view)[:selected_agent_id] == agent_id()
      assert render(view) =~ "##{agent_id()}"
    end

    test "a node switch resets the commit-graph state but keeps the left view", %{conn: conn} do
      view = mount_loaded_commit_graph(conn)
      assert assigns(view)[:left_view] == :commits

      # Drive handle_params/3 directly (the LiveView is a plain socket here) and
      # force the node-changed reset branch by pointing previous_node at another
      # node than the one the (node-less) params resolve to — the local node.
      state = :sys.get_state(view.pid)
      socket = state.socket

      socket = %{socket | assigns: Map.put(socket.assigns, :previous_node, :some_other_node)}

      {:noreply, new_socket} = EvoDashWeb.AgentsLive.handle_params(%{}, "/agents", socket)

      # The user's view preference survives; the per-node commit data does not.
      assert new_socket.assigns.left_view == :commits
      assert new_socket.assigns.commit_graph == []
      assert new_socket.assigns.commit_graph_raw == %{}
      assert new_socket.assigns.commit_graph_loaded == false
      assert new_socket.assigns.commit_graph_loading == false
      assert new_socket.assigns.commit_graph_error == nil
      # Retained ended agents are per-node too (agent ids are per-node).
      assert new_socket.assigns.retained_agents == %{}
    end
  end

  describe "commit history view — retained ended agents" do
    # The core DELETES an agent's ETS rows (and its evogit-agent-* branch) when it
    # recycles it — the SAME {:agent_removed, id, node} broadcast fires in both
    # cases, so the page cannot tell a deleted agent from a finished one. It
    # therefore RETAINS the removed agent's last-known map (@retained_agents,
    # `ended: true`), which feeds the commit-history view ONLY: its graph AGENT
    # entry (drawn dim, `ended: true`) and the START/END annotation survive,
    # while the agent TREE (@agents) drops the row. In-session only — nothing
    # else remembers it.

    test "a removed agent stays in the graph (ended) with its selection annotation", %{conn: conn} do
      # `select: true` selects the agent BEFORE the commits switch (its card only
      # exists in the tree view) so the graph's START/END annotation for the
      # selection is observable afterwards.
      view = mount_loaded_commit_graph(conn, select: true)
      aid = agent_id()

      assert assigns(view)[:selected_agent_id] == aid
      assert [repo] = assigns(view)[:commit_graph]
      dom = repo.repo_dom_id
      assert has_element?(view, "#cg-selection-readout-#{dom}")

      send(view.pid, {:agent_removed, aid, node()})
      flush_agent_events(view)

      # Retained, marked ended…
      assert assigns(view)[:retained_agents][aid].ended == true

      # …its graph AGENT entry persists, marked ended…
      assert [repo] = assigns(view)[:commit_graph]
      assert [agent] = repo.agents
      assert agent.agent_id == aid
      assert agent.ended == true

      # …and the selection was NOT cleared, so its START/END annotation still
      # renders on the retained agent's rows (the detail panel itself degrades to
      # its "not found" state, which is the natural view of an agent that is
      # gone).
      assert assigns(view)[:selected_agent_id] == aid

      html = render(view)
      tree = Floki.parse_document!(html)

      assert has_element?(view, "#commit-row-#{dom}-b1")
      assert has_element?(view, "#commit-row-#{dom}-c1")
      assert has_element?(view, "#cg-selection-readout-#{dom}")

      # The readout names the retained agent with its start → end short shas…
      assert Floki.text(Floki.find(tree, "#cg-selection-readout-#{dom}")) =~
               "Selected T#{aid} · b1 → c1"

      # …its fork-point row wears the `start` marker and its tip row the `end`
      # marker (the rows are marked, not the gutter)…
      [start_row] = Floki.find(tree, "#commit-row-#{dom}-b1")
      [end_row] = Floki.find(tree, "#commit-row-#{dom}-c1")
      assert Floki.text(Floki.find(start_row, ".cg-row-marker")) =~ "start"
      assert Floki.text(Floki.find(end_row, ".cg-row-marker")) =~ "end"

      # …and both rows render DIM (the ended agent's rows drop to `opacity-50`).
      assert hd(Floki.attribute(start_row, "class")) =~ "opacity-50"
      assert hd(Floki.attribute(end_row, "class")) =~ "opacity-50"

      # The agent TREE, however, no longer lists it — the retained copy is
      # commit-graph-only (the tree pane is only rendered in the tree view).
      view |> element("#left-view-tree") |> render_click()
      assert assigns(view)[:agents] == []
      refute has_element?(view, "#agent-card-#{aid}")
    end

    test "a live agent supersedes its retained copy — exactly one agent entry", %{conn: conn} do
      view = mount_loaded_commit_graph(conn)
      aid = agent_id()

      send(view.pid, {:agent_removed, aid, node()})
      flush_agent_events(view)
      assert assigns(view)[:retained_agents][aid].ended == true

      # ── 1. re-registration (the incremental broadcast path) ──────────────
      send(
        view.pid,
        {:agent_registered, aid,
         summary_agent(id: aid, repo_root: "/repo/a", base_commit: "b1", current_commit: "c1"),
         node()}
      )

      flush_agent_events(view)

      # The retained copy is dropped (a live id always wins)…
      assert assigns(view)[:retained_agents] == %{}
      assert assigns(view)[:agents] |> Enum.map(& &1.id) == [aid]

      # …and the graph holds EXACTLY ONE agent entry for the id, live.
      assert [repo] = assigns(view)[:commit_graph]
      assert [agent] = repo.agents
      assert agent.agent_id == aid
      assert agent.ended == false

      # ── 2. a FULL REFRESH carrying the row (the authoritative path) ──────
      send(view.pid, {:agent_removed, aid, node()})
      flush_agent_events(view)
      assert assigns(view)[:retained_agents][aid].ended == true

      send(
        view.pid,
        {:agents_data_loaded, node(), 1,
         {:ok,
          %{
            agents: [
              full_agent(
                id: aid,
                repo_root: "/repo/a",
                base_commit: "b1",
                current_commit: "c1",
                ended: false
              )
            ],
            config_status: nil,
            threshold_cache: nil
          }}}
      )

      render(view)

      assert assigns(view)[:retained_agents] == %{}
      assert assigns(view)[:agents] |> Enum.map(& &1.id) == [aid]
      assert [repo] = assigns(view)[:commit_graph]
      assert [agent] = repo.agents
      assert agent.agent_id == aid
      assert agent.ended == false
    end

    test "a node switch resets the retained agents", %{conn: conn} do
      view = mount_loaded_commit_graph(conn)
      aid = agent_id()

      send(view.pid, {:agent_removed, aid, node()})
      flush_agent_events(view)
      assert map_size(assigns(view)[:retained_agents]) == 1

      # Mirror the commit-graph reset test's idiom: invoke handle_params/3
      # directly on the live socket with `previous_node` forced to differ —
      # :sys.replace_state on :current_node would NOT run the reset branch.
      state = :sys.get_state(view.pid)
      socket = state.socket
      socket = %{socket | assigns: Map.put(socket.assigns, :previous_node, :some_other_node)}

      {:noreply, new_socket} = EvoDashWeb.AgentsLive.handle_params(%{}, "/agents", socket)

      # Retained agents are keyed by PER-NODE agent ids, so the switch drops them
      # together with the rest of the per-node state…
      assert new_socket.assigns.retained_agents == %{}
      assert new_socket.assigns.commit_graph == []
      assert new_socket.assigns.commit_graph_raw == %{}
      assert new_socket.assigns.commit_graph_loaded == false
      assert new_socket.assigns.selected_agent_id == nil
      # …while the user's view preference survives.
      assert new_socket.assigns.left_view == :commits
    end
  end

  describe "commit history view — partial success and the fingerprint gate" do
    # Two behaviours landed with the CommitGraphRefresh extraction (the pure
    # halves are unit-tested in agents_live/commit_graph_refresh_test.exs):
    #
    #   * PARTIAL SUCCESS — one failing group no longer blanks the view: the
    #     fetch folds ONLY the successful groups into @commit_graph_raw and the
    #     page renders them ({:error, _} is reserved for an ALL-groups failure).
    #   * The FINGERPRINT GATE — a flush whose agent changes are
    #     commit-irrelevant (status/tokens/usage/message-count only) skips BOTH
    #     the view-model rebuild and the git-RPC refetch entirely; a
    #     commit-relevant change (a moved tip, a registered agent) refetches.
    #
    # Both are driven through the real flush path (send + :flush_agent_events),
    # with the runner-call recorder as the "did we hit the RPC" probe. The
    # 1000ms refetch throttle is bypassed the way the retained-agent tests
    # bypass coalescing: for the gate-SKIP case the throttle never matters (no
    # spawn is attempted at all), and for the gate-PASS case the one-shot
    # :commit_graph_tick (armed by the throttle) is fired directly.

    test "a failing group drops only its own data — the good repo still renders",
         %{conn: conn} do
      install_agents([
        summary_agent(
          id: agent_id(),
          repo_root: "/repo/a",
          base_commit: "b1",
          current_commit: "c1",
          task_id: "task-1"
        ),
        summary_agent(
          id: agent_id() + 1,
          repo_root: "/repo/b",
          base_commit: "b2",
          current_commit: "c2",
          task_id: "task-2"
        )
      ])

      # /repo/a replies a real payload; /repo/b replies ok-shaped garbage (a
      # non-list `commits` is a per-group failure — same drop semantics as an
      # {:error, _} reply).
      install_commit_graph_runner(fn
        "/repo/a" -> {:ok, single_commit_graph_payload()}
        "/repo/b" -> {:ok, %{commits: "garbage"}}
      end)

      {:ok, view, _html} = live(conn, ~p"/agents")
      flush_agents_load(view)

      render_click(view, "switch_left_view", %{"view" => "commits"})

      assert_receive {:commit_graph_call, _node, "task-1", "/repo/a", ["c1"], [limit: 100]}, 1000
      assert_receive {:commit_graph_call, _node, "task-2", "/repo/b", ["c2"], [limit: 100]}, 1000
      wait_until(fn -> assigns(view)[:commit_graph_loaded] end)

      # PARTIAL SUCCESS: an {:ok, _} result (not an error) holding ONLY the
      # good repo — the failed group's repo is absent from the raw map.
      assert assigns(view)[:commit_graph_error] == nil
      assert assigns(view)[:commit_graph_loading] == false

      assert Map.keys(assigns(view)[:commit_graph_raw]) == ["/repo/a"]
      assert assigns(view)[:commit_graph_raw]["/repo/a"].commits |> Enum.map(& &1.sha) == ["c1"]

      # …and the page renders the good repo's graph with NO error strip (the
      # error strip is reserved for an all-groups failure with nothing cached).
      # The FAILED repo still gets a repo view — its lanes/START-END come from
      # the agent set — but no fetched commits (they stop at the last fetch).
      repos = assigns(view)[:commit_graph]
      assert Enum.map(repos, & &1.repo_key) |> Enum.sort() == ["/repo/a", "/repo/b"]

      repo_a = Enum.find(repos, &(&1.repo_key == "/repo/a"))
      assert repo_a.nodes |> Enum.map(& &1.sha) |> Enum.sort() == ["b1", "c1"]
      assert has_element?(view, "##{repo_a.repo_dom_id}")

      repo_b = Enum.find(repos, &(&1.repo_key == "/repo/b"))
      assert repo_b.nodes |> Enum.map(& &1.sha) == ["b2"]

      refute has_element?(view, "#commit-graph-error")
      refute has_element?(view, "#commit-graph-stale-warning")
    end

    test "a commit-irrelevant flush (status/tokens only) skips the refetch",
         %{conn: conn} do
      view = mount_loaded_commit_graph(conn)

      # A status/token-only update — none of it is in the fingerprint.
      send(view.pid, {:agent_updated, agent_id(), [status: :waiting, total_tokens: 999], node()})
      flush_agent_events(view)

      # The tree merged the update (the flush really ran)…
      assert assigns(view)[:agents] |> Enum.map(& &1.status) == [:waiting]

      # …but the fingerprint gate skipped BOTH the rebuild and the refetch: a
      # non-gated path would have spawned a fetch (setting :commit_graph_loading
      # synchronously) or armed the throttled one-shot tick (setting
      # :commit_graph_tick_scheduled) — both failure modes are synchronous
      # assigns. A zero-timeout refute adds the "already delivered" half (the
      # stub is fast, so a bug's fetch would typically have completed before this
      # read, leaving both assigns false with the call sitting in the mailbox).
      # The mailbox is clean of commit_graph calls here: mount_loaded_commit_graph/2
      # asserts (and thereby drains) its OWN single legit call before returning —
      # verified against every caller, all of which either never touch the mailbox
      # or assert their own fresh call only AFTER a mutation.
      assert assigns(view)[:commit_graph_loading] == false
      assert assigns(view)[:commit_graph_tick_scheduled] == false
      refute_receive {:commit_graph_call, _, _, _, _, _}, 0
    end

    test "a commit-relevant flush (a moved tip) refetches", %{conn: conn} do
      view = mount_loaded_commit_graph(conn)

      # A new tip on the agent — a fingerprint change (a moved current_commit
      # means new commits may exist)…
      send(view.pid, {:agent_updated, agent_id(), [current_commit: "new_sha"], node()})
      flush_agent_events(view)

      # …so the flush rebuilds and wants a refetch. The last fetch is inside
      # the 1000ms throttle window, so the spawn is DEFERRED to the one-shot
      # :commit_graph_tick — fire it directly (the same way the throttle would)
      # and assert the refetch happens with the NEW tip as the live tip. (If
      # the window already elapsed under load the spawn fired directly and no
      # tick was armed — skip straight to the call assertion.)
      if assigns(view)[:commit_graph_tick_scheduled] do
        send(view.pid, :commit_graph_tick)
        render(view)
      end

      assert_receive {:commit_graph_call, _node, "task-1", "/repo/a", ["new_sha"], [limit: 100]},
                     1000

      wait_until(fn -> assigns(view)[:commit_graph_loading] == false end)

      # The refetched graph is applied (the stub still serves the same payload).
      assert assigns(view)[:commit_graph_error] == nil
    end

    test "a newly registered agent joins the rebuilt graph with its own lane",
         %{conn: conn} do
      view = mount_loaded_commit_graph(conn)

      child_id = agent_id() + 1

      # The child spawns in the same repo, on the same task, at depth 1.
      send(
        view.pid,
        {:agent_registered, child_id,
         summary_agent(
           id: child_id,
           repo_root: "/repo/a",
           base_commit: "c1",
           current_commit: "c9",
           depth: 1,
           parent_id: agent_id()
         ), node()}
      )

      flush_agent_events(view)

      # The registered agent's lane appears in the rebuilt view model WITHOUT
      # waiting for the refetch (the rebuild runs on the agent set alone)…
      assert [repo] = assigns(view)[:commit_graph]

      assert Enum.map(repo.agents, & &1.agent_id) |> Enum.sort() ==
               Enum.sort([agent_id(), child_id])

      assert repo.column_count == 2

      # …and the now-changed fingerprint means the flush ALSO refetches. The
      # throttle defers the spawn to the one-shot tick — fire it (if the 1000ms
      # window already elapsed under load, the spawn fired directly instead).
      if assigns(view)[:commit_graph_tick_scheduled] do
        send(view.pid, :commit_graph_tick)
        render(view)
      end

      # The group's live tips now carry BOTH agents' current commits.
      assert_receive {:commit_graph_call, _node, "task-1", "/repo/a", tips, [limit: 100]}, 1000
      assert Enum.sort(tips) == Enum.sort(["c1", "c9"])
    end

    test "selecting a row records no new runner call (selection is renderer-side)",
         %{conn: conn} do
      view = mount_loaded_commit_graph(conn)

      assert [repo] = assigns(view)[:commit_graph]
      dom = repo.repo_dom_id

      # Clicking a row selects the agent…
      view |> element("#commit-row-#{dom}-c1") |> render_click()

      assert assigns(view)[:selected_agent_id] == agent_id()
      assert has_element?(view, "#cg-selection-readout-#{dom}")

      # …and does NOT reload the graph — no rebuild, no refetch, no runner call.
      # Selection is renderer-side: neither failure mode of a git RPC happens
      # (no fetch spawn → :commit_graph_loading stays false; no throttled one-shot
      # → :commit_graph_tick_scheduled stays false), and the 0-timeout refute
      # covers the complementary "already delivered" mode. The mailbox is clean of
      # commit_graph calls because mount_loaded_commit_graph/2's own assert_receive
      # drained its single legit call before returning.
      assert assigns(view)[:commit_graph_loading] == false
      assert assigns(view)[:commit_graph_tick_scheduled] == false
      refute_receive {:commit_graph_call, _, _, _, _, _}, 0
    end
  end

  # ── Private helpers ─────────────────────────────────────────────

  # Reads the LiveView's CURRENT socket assigns directly (same pattern as
  # system_live_test / welcome_live_test / settings_live_agents_test).
  defp assigns(view), do: :sys.get_state(view.pid).socket.assigns

  # The trimmed text of `selector` within a parsed tree — Floki.text/1 keeps the
  # whitespace the HEEx template indents around the content.
  defp text(tree, selector) do
    tree |> Floki.find(selector) |> Floki.text() |> String.trim()
  end

  # Delegates to the shared flush helper (EvoDashWeb.TestHelpers.flush_loading/4).
  defp flush_agents_load(view, timeout \\ 5000),
    do:
      EvoDashWeb.TestHelpers.flush_loading(
        view,
        "Loading agents…",
        "timed out waiting for the async agents load to finish",
        timeout
      )

  # Triggers the AgentsLive coalescing flush directly (bypassing the
  # trailing-edge timer). The LiveView processes its mailbox in FIFO order,
  # so any agent events sent before this message have been buffered and are
  # applied by the time this flush is handled.
  defp flush_agent_events(view) do
    send(view.pid, :flush_agent_events)
    render(view)
  end

  # Blocks the caller until the TEST flips `latch` (an :atomics flag) — the
  # deterministic "the async load is still in flight" barrier used by the
  # initial-load test. It polls a SHARED atomic (not a message) because the page
  # load runs in BOTH the dead render and the connected mount, so several
  # callers block at once and a per-pid release would free only one.
  # Never raises: it returns after a generous 5s budget (mirrors
  # blocking_history_runner/1's `after` fallback) so a test bug can never wedge
  # a TaskSupervisor child at teardown — and a raise here would in any case be
  # swallowed by the load task's node-boundary rescue, silently degrading the
  # test instead of failing it.
  defp await_latch(latch, timeout \\ 5_000) do
    deadline = System.monotonic_time(:millisecond) + timeout
    await_latch_loop(latch, deadline)
  end

  defp await_latch_loop(latch, deadline) do
    cond do
      :atomics.get(latch, 1) == 1 ->
        :ok

      System.monotonic_time(:millisecond) >= deadline ->
        :ok

      true ->
        Process.sleep(1)
        await_latch_loop(latch, deadline)
    end
  end

  # Polls `fun` until it returns a truthy value (or the timeout elapses).
  # Used to synchronize on LiveView state changes that follow directly-sent
  # messages (mailbox FIFO guarantees the preceding messages were processed).
  defp wait_until(fun, timeout \\ 5000) do
    deadline = System.monotonic_time(:millisecond) + timeout

    wait_loop = fn wait_loop ->
      if fun.() do
        :ok
      else
        if System.monotonic_time(:millisecond) >= deadline do
          flunk("timed out waiting for condition after #{timeout}ms")
        else
          Process.sleep(10)
          wait_loop.(wait_loop)
        end
      end
    end

    wait_loop.(wait_loop)
  end

  # Polls the rendered HTML until `text` appears (async history fetches) and
  # returns the final HTML.
  defp wait_for_text(view, text, timeout \\ 5000) do
    wait_until(fn -> render(view) =~ text end, timeout)
    render(view)
  end

  # Joins an element's class attribute(s) into one searchable string (Floki
  # splits multiple `class` attributes; a well-formed element has exactly one).
  defp class_string(element) do
    element |> Floki.attribute("class") |> Enum.join(" ")
  end

  # Deletes ALL the AgentsLive env seams (each is resolved at call time inside
  # the async tasks, so a leaked value would leak into later tests). The
  # commit-graph seam is resolved at SPAWN time too, so it is cleared as well.
  defp clear_agents_env do
    for key <- [
          :agents_list_runner,
          :agents_history_runner,
          :agents_config_runner,
          :agents_commit_graph_runner
        ] do
      Application.delete_env(:evo_dash, key)
    end
  end

  # Installs the :agents_commit_graph_runner stub. The seam is ARITY 5 —
  # runner.(node, task_id, repo_key, live_tips, limit: 100), ONE call per
  # {repo_key, task_id} group (both binaries) — so the responder is keyed by the
  # repo_key the group belongs to. Every call is recorded to the TEST process as
  # the 6-tuple {:commit_graph_call, node, task_id, repo_root, live_tips, opts};
  # the result comes from responder.(repo_root), which may return
  # {:ok, %{commits: [...], refs: %{}}} or {:error, reason}.
  defp install_commit_graph_runner(responder) do
    test_pid = self()

    stub = fn node, task_id, repo_root, live_tips, opts ->
      send(test_pid, {:commit_graph_call, node, task_id, repo_root, live_tips, opts})
      responder.(repo_root)
    end

    Application.put_env(:evo_dash, :agents_commit_graph_runner, stub)
    on_exit(&clear_agents_env/0)
  end

  # Installs an :agents_list_runner stub returning the given crafted summaries
  # (build them with the existing summary_agent/1 helper).
  defp install_agents(summaries) when is_list(summaries) do
    Application.put_env(:evo_dash, :agents_list_runner, fn _node -> summaries end)
    on_exit(&clear_agents_env/0)
  end

  # Mounts /agents with ONE stubbed summary, selects its agent card (the only
  # place the detail panel renders) and — unless `expand: false` — expands the
  # "Token and Cost" panel, which is the only place the Context meter renders.
  # `:agents_config_runner` is stubbed to an EMPTY resolved config so the
  # node-level compression threshold is deterministic (the 180_000 last resort)
  # and never depends on the developer's real config; every fixture supplies its
  # own per-agent `compression_threshold`, which wins anyway.
  defp mount_context_meter(conn, summaries, opts) do
    install_agents(summaries)
    Application.put_env(:evo_dash, :agents_config_runner, fn _node -> {:ok, %{}} end)

    {:ok, view, _html} = live(conn, ~p"/agents")
    flush_agents_load(view)

    view |> element("#agent-card-#{agent_id()}") |> render_click()

    if Keyword.get(opts, :expand, true) do
      view |> element("button[phx-click='toggle_usage']") |> render_click()
    end

    view
  end

  # The rendered #agent-context-meter node's attributes as a map. Must run on a
  # PARSED document (Floki on the raw html binary confuses the LiveView
  # envelope), and only after the usage panel has been expanded.
  defp context_meter_attrs(view) do
    nodes =
      view
      |> render()
      |> Floki.parse_document!()
      |> Floki.find("#agent-context-meter")

    assert [meter] = nodes
    assert {"div", attrs, _children} = meter

    Map.new(attrs)
  end

  # An {:error, _} reply from EVERY group yields {:error, first-ish failure}
  # (an all-groups failure), keeping @commit_graph empty (the commit pane's
  # error state). With partial-success folding a failing group no longer halts
  # the loop — see graph_partial_responder/1. Loaded-graph DOM coverage lives
  # in the page test above; the sibling component suite still pins the DOM
  # markers in isolation.
  defp graph_error_responder, do: fn _repo_root -> {:error, :stub} end

  # Returns {:ok, _} for `first_repo_root` — letting the (sorted) fetch loop
  # continue to the NEXT group — and {:error, _} for every other repo. Since
  # fetch_result/3 folds with PARTIAL-SUCCESS semantics (a failing group drops
  # only its own data), the loop now reaches EVERY group and the successful
  # ones still fold into raw_by_repo. That keeps "one call per
  # {repo_root, task_id} group" observable.
  defp graph_partial_responder(first_repo_root) do
    fn
      ^first_repo_root -> {:ok, %{commits: [], refs: %{}}}
      _other -> {:error, :stub}
    end
  end

  # Reaches a LOADED commit graph through the REAL async path: one eligible agent
  # in /repo/a (task "task-1" — the summary_agent/1 default) with a stub runner
  # returning `single_commit_graph_payload/0`, then a switch to the commits view.
  # Returns the view. Callers MAY render the loaded graph (the commits container
  # carries no phx-update mode); the assigns-based stale / foreign-node /
  # failed-refresh tests use this helper to inspect state.
  # `select: true` selects the agent BEFORE the switch (its card only exists in
  # the tree view) so the graph's START/END annotation for the selection is
  # observable afterwards.
  defp mount_loaded_commit_graph(conn, opts \\ []) do
    install_agents([
      summary_agent(id: agent_id(), repo_root: "/repo/a", base_commit: "b1", current_commit: "c1")
    ])

    install_commit_graph_runner(fn "/repo/a" -> {:ok, single_commit_graph_payload()} end)

    {:ok, view, _html} = live(conn, ~p"/agents")
    flush_agents_load(view)

    if Keyword.get(opts, :select, false) do
      view |> element("#agent-card-#{agent_id()}") |> render_click()
    end

    render_click(view, "switch_left_view", %{"view" => "commits"})

    assert_receive {:commit_graph_call, _node, "task-1", "/repo/a", ["c1"], [limit: 100]}, 1000
    wait_until(fn -> assigns(view)[:commit_graph_loaded] end)

    view
  end

  # One fetched commit in the shape the payload uses (atom keys — the assembler
  # and the de-dupe both read :sha / :parents).
  defp commit(sha, parents, message \\ "") do
    %{
      sha: sha,
      short_sha: sha,
      message: message,
      parents: parents,
      author_name: "Ada",
      date: nil
    }
  end

  # The per-repo commit-graph payload for the single eligible /repo/a agent (base
  # "b1" → current "c1"). The message carries a body line to pin the first-line
  # truncation; "c1" is tagged with the "main" ref.
  defp single_commit_graph_payload do
    %{
      commits: [
        %{
          sha: "c1",
          short_sha: "c1",
          message: "subject line\nbody",
          parents: ["b1"],
          author_name: "Ada",
          date: nil
        }
      ],
      refs: %{"c1" => ["main"]}
    }
  end

  # Seeds a single agent (sched_meta + agent_state) directly into the ETS
  # tables the RemoteAPI reads, so the agents page renders a real agent with
  # the given conversation history. Cleaned up in on_exit.
  defp seed_agent(id, messages) do
    context_node = %ContextNode{path: "./", repo: "test"}
    phylo_node = %PhyloGraphNode{current_commit: "abc123", base_commit: "def456"}

    spec = %AgentSpec{
      context_node: context_node,
      phylo_node: phylo_node,
      agent_module: EvoGit.Agents.Manager,
      objective: "test objective"
    }

    meta = %SchedMeta{id: id, depth: 0, spec: spec, status: :running}

    state = %AgentState{
      context_node: context_node,
      llm_model: "test-model",
      max_retries: 1,
      max_depth: 1,
      phylo_node: phylo_node,
      objective: "test objective",
      context: %ReqLLM.Context{messages: messages}
    }

    :ets.insert(:evogit_sched_meta, {id, meta})
    :ets.insert(:evogit_agent_state, {id, state})
  end

  # Updates a seeded agent's scheduler status in ETS (leaves the context —
  # and therefore :message_count — untouched).
  defp update_agent_status(id, status) do
    case :ets.lookup(:evogit_sched_meta, id) do
      [{^id, meta}] -> :ets.insert(:evogit_sched_meta, {id, %{meta | status: status}})
      [] -> :ok
    end
  end

  # Replaces a seeded agent's conversation context in ETS (grows its
  # :message_count for the history gate).
  defp update_agent_context(id, messages) do
    case :ets.lookup(:evogit_agent_state, id) do
      [{^id, state}] ->
        :ets.insert(
          :evogit_agent_state,
          {id, %{state | context: %ReqLLM.Context{messages: messages}}}
        )

      [] ->
        :ok
    end
  end

  # A minimal RemoteAPI-shaped agent summary (the shape
  # EvoDashWeb.AgentsLive.LoadData.build_agents consumes). `task_id` defaults to a
  # non-nil BINARY because the task-scoped commit-graph RPC is grouped by
  # {repo_root, task_id} and SKIPS agents without one — callers override it to
  # exercise the grouping.
  defp summary_agent(overrides) do
    Map.merge(
      %{
        id: agent_id(),
        task_local_id: nil,
        repo_id: nil,
        status: :running,
        depth: 0,
        parent_id: nil,
        usage: nil,
        total_tokens: 0,
        compression_count: 0,
        message_count: 0,
        objective: "test objective",
        result: nil,
        agent_module: EvoGit.Agents.Manager,
        started_at: nil,
        model_id: nil,
        repo_root: nil,
        context_path: "./",
        worktree: nil,
        current_commit: "abc123",
        base_commit: "def456",
        task_id: "task-1",
        task_number: nil,
        retries: 0
      },
      Map.new(overrides)
    )
  end

  # A fully-shaped agent map for stale-result injection / direct apply-path
  # exercises. Distinctive id 99 (renders as "#99" in the tree) so a leaked
  # stale result fails loudly.
  defp marker_agent, do: full_agent([])

  # A fully-shaped agent map (all fields the tree/detail render + carry-over
  # path read), with `overrides` merged in so tests can set id/history/etc.
  # `task_id` is a non-nil BINARY (the task-scoped commit-graph grouping skips
  # agents without one).
  defp full_agent(overrides) do
    Map.merge(
      %{
        id: 99,
        task_local_id: nil,
        repo_id: "primary",
        repo_root: nil,
        task_id: "task-1",
        task_number: 99,
        status: :running,
        depth: 0,
        parent_id: nil,
        worktree: nil,
        retries: 0,
        agent_module: EvoGit.Agents.Manager,
        model_id: nil,
        objective: "STALE MARKER OBJECTIVE",
        context_path: "./stale-marker",
        current_commit: "abc123",
        base_commit: "def456",
        children: [],
        has_children: false,
        pending_sub_agents: [],
        sub_agent_results: %{},
        task_ref: nil,
        result_sent: false,
        history: [],
        usage: EvoGit.Agent.Usage.zero(),
        total_tokens: 0,
        compression_count: 0,
        compression_threshold: 100_000,
        compression_pct: 0,
        message_count: 0
      },
      Map.new(overrides)
    )
  end

  # A counter-backed :agents_history_runner fake. Each call returns one more
  # message than the last (call N returns N messages with turns 1..N), so the
  # display text reveals how many times history was fetched. MUST return
  # %ReqLLM.Message{} structs — the display path pattern-matches structs.
  defp counting_history_runner(counter) do
    fn _node, _agent_id ->
      count = Agent.get_and_update(counter, fn n -> {n + 1, n + 1} end)

      Enum.map(1..count, fn i ->
        %ReqLLM.Message{
          role: :user,
          content: [%{text: "fake message #{i}"}],
          metadata: %{turn: i}
        }
      end)
    end
  end

  defp start_history_counter do
    start_supervised!({Agent, fn -> 0 end})
  end

  defp blocking_history_runner(test_pid) do
    fn _node, _agent_id ->
      send(test_pid, {:history_fetch_called, self()})

      receive do
        {:history_release, messages} -> messages
      after
        5_000 -> []
      end
    end
  end

  defp start_history_queue(responses), do: start_supervised!({Agent, fn -> responses end})

  defp queued_history_runner(queue) do
    fn _node, _agent_id -> Agent.get_and_update(queue, fn [head | tail] -> {head, tail} end) end
  end

  # The expected local "HH:MM:SS" for a given UTC instant, computed
  # independently of the helper under test (via :calendar gregorian seconds +
  # the machine's current local offset).
  defp expected_local_time(unix_seconds) do
    base = :calendar.datetime_to_gregorian_seconds({{1970, 1, 1}, {0, 0, 0}})

    {_date, {h, m, s}} =
      :calendar.gregorian_seconds_to_datetime(base + unix_seconds + local_offset_seconds())

    :io_lib.format("~2..0B:~2..0B:~2..0B", [h, m, s]) |> IO.iodata_to_binary()
  end

  defp local_offset_seconds do
    local = :calendar.local_time()
    utc = :calendar.universal_time()
    :calendar.datetime_to_gregorian_seconds(local) - :calendar.datetime_to_gregorian_seconds(utc)
  end
end
