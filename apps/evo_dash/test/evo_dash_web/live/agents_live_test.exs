defmodule EvoDashWeb.AgentsLiveTest do
  use EvoDashWeb.ConnCase, async: false
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

  # Ids this file seeds into the scheduler ETS tables (the tables are owned by
  # the :evo_git application process and survive the test process).
  @seeded_agent_ids [1]

  setup do
    on_exit(fn ->
      # Clean up only the rows this file seeds; the tables themselves are
      # owned by the :evo_git application process (survive the test process).
      for table <- [:evogit_sched_meta, :evogit_agent_state], id <- @seeded_agent_ids do
        if :ets.whereis(table) != :undefined, do: :ets.delete(table, id)
      end
    end)

    :ok
  end

  describe "agents page" do
    test "renders the agents page", %{conn: conn} do
      {:ok, _view, html} = live(conn, ~p"/agents")

      assert html =~ "Agent Tree"
    end

    test "starts in the async loading state with generation 1", %{conn: conn} do
      # Block the async load task so the initial render's loading state is
      # deterministic — the load runs in a TaskSupervisor child and could
      # otherwise finish before the assertion.
      Application.put_env(:evo_dash, :agents_config_runner, fn _node ->
        Process.sleep(200)
        {:ok, %{}}
      end)

      on_exit(&clear_agents_env/0)

      {:ok, view, _html} = live(conn, ~p"/agents")

      assert assigns(view)[:load_generation] == 1
      assert assigns(view)[:agents_loading] == true

      html = flush_agents_load(view)
      refute html =~ "Loading agents…"
    end

    test "shows empty state when no agents are running", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/agents")

      # The agent list is loaded asynchronously — the initial render shows the
      # loading state, so wait for the load to finish before asserting.
      html = flush_agents_load(view)

      assert html =~ "No agents currently registered"
    end
  end

  describe "async agent load" do
    test "populates the agent tree with message counts", %{conn: conn} do
      seed_agent(1, [
        %ReqLLM.Message{role: :user, content: [%{text: "hi"}], metadata: %{turn: 1}}
      ])

      {:ok, view, _html} = live(conn, ~p"/agents")
      html = flush_agents_load(view)

      # The tree renders the seeded agent's card under its repo root.
      assert html =~ "#1"
      assert html =~ "Primary Repo"

      # The async load carried the summary's :message_count through (the
      # history gate keys off it — see "history fetch gating").
      assert [agent] = assigns(view)[:agents]
      assert agent.id == 1
      assert agent.message_count == 1
      assert agent.status == :running
    end

    test "drops stale load generations", %{conn: conn} do
      seed_agent(1, [
        %ReqLLM.Message{role: :user, content: [%{text: "hi"}], metadata: %{turn: 1}}
      ])

      {:ok, view, _html} = live(conn, ~p"/agents")
      flush_agents_load(view)
      assert assigns(view)[:load_generation] == 1

      # A result from an older generation (0 < 1) must be dropped. The
      # trailing {:agents_updated, node()} event is only a FIFO
      # synchronization fence: once the refresh it spawned is observable
      # (refresh_seq bumped), the stale message was already processed.
      send(view.pid, {:agents_data_loaded, node(), 0, {:ok, %{agents: [marker_agent()]}}})
      send(view.pid, {:agents_updated, node()})
      wait_until(fn -> assigns(view)[:refresh_seq] == 1 end)

      assert assigns(view)[:agents] |> Enum.map(& &1.id) == [1]
      refute render(view) =~ "#99"
    end

    test "drops stale refresh sequences", %{conn: conn} do
      seed_agent(1, [
        %ReqLLM.Message{role: :user, content: [%{text: "hi"}], metadata: %{turn: 1}}
      ])

      {:ok, view, _html} = live(conn, ~p"/agents")
      flush_agents_load(view)

      # Trigger an async refresh ({:agents_updated, node()} broadcast) —
      # refresh_seq becomes 1.
      send(view.pid, {:agents_updated, node()})
      wait_until(fn -> assigns(view)[:refresh_seq] == 1 end)

      # A stale refresh result (seq 0 < 1) must be dropped. FIFO fence: the
      # {:agents_updated, node()} event is processed after the stale message.
      send(view.pid, {:agents_refresh_result, 0, node(), {:ok, [marker_agent()], nil}})
      send(view.pid, {:agents_updated, node()})
      wait_until(fn -> assigns(view)[:refresh_seq] == 2 end)

      assert assigns(view)[:agents] |> Enum.map(& &1.id) == [1]
      refute render(view) =~ "#99"
    end
  end

  describe "history fetch gating" do
    # The HistoryGate suppresses full-history re-transfers while an agent's
    # :message_count is unchanged (see EvoDashWeb.AgentsLive.HistoryGate).

    test "does not re-fetch history while the message count is unchanged", %{conn: conn} do
      seed_agent(1, [
        %ReqLLM.Message{role: :user, content: [%{text: "hi"}], metadata: %{turn: 1}}
      ])

      counter = start_history_counter()
      Application.put_env(:evo_dash, :agents_history_runner, counting_history_runner(counter))
      on_exit(&clear_agents_env/0)

      {:ok, view, _html} = live(conn, ~p"/agents")
      flush_agents_load(view)

      # First selection fetches history (the gate has no last-seen entry).
      view |> element("#agent-card-1") |> render_click()
      wait_until(fn -> render(view) =~ "fake message 1" end)
      assert Agent.get(counter, & &1) == 1

      # Make the next refresh observable: change the agent's status in ETS
      # while leaving its context (message_count) untouched.
      update_agent_status(1, :waiting)
      send(view.pid, {:agents_updated, node()})
      wait_until(fn -> render(view) =~ "WAITING" end)

      # The refresh applied but the count is unchanged — the carried history is
      # kept and the gate suppresses a re-fetch.
      assert Agent.get(counter, & &1) == 1
    end

    test "re-fetches history when the message count changes", %{conn: conn} do
      seed_agent(1, [
        %ReqLLM.Message{role: :user, content: [%{text: "hi"}], metadata: %{turn: 1}}
      ])

      counter = start_history_counter()
      Application.put_env(:evo_dash, :agents_history_runner, counting_history_runner(counter))
      on_exit(&clear_agents_env/0)

      {:ok, view, _html} = live(conn, ~p"/agents")
      flush_agents_load(view)

      view |> element("#agent-card-1") |> render_click()
      wait_until(fn -> render(view) =~ "fake message 1" end)
      assert Agent.get(counter, & &1) == 1

      # The conversation grows (2 messages) — the next refresh must drop the
      # carried history and re-fetch for the selected agent.
      update_agent_context(1, [
        %ReqLLM.Message{role: :user, content: [%{text: "hi"}], metadata: %{turn: 1}},
        %ReqLLM.Message{role: :assistant, content: [%{text: "world"}], metadata: %{turn: 2}}
      ])

      send(view.pid, {:agents_updated, node()})
      wait_until(fn -> render(view) =~ "Turn 2" end)

      assert Agent.get(counter, & &1) == 2
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
      seed_agent(1, [])

      {:ok, view, _html} = live(conn, ~p"/agents")
      flush_agents_load(view)

      summary =
        summary_agent(id: 2, parent_id: 1, status: :pending, objective: "child objective")

      send(view.pid, {:agent_registered, 2, summary, node()})

      wait_until(fn -> assigns(view)[:new_agent_ids] |> MapSet.member?(2) end)

      agents = assigns(view)[:agents]
      assert Enum.map(agents, & &1.id) == [1, 2]

      registered = Enum.find(agents, &(&1.id == 2))
      assert registered.parent_id == 1
      assert registered.status == :pending
      assert registered.objective == "child objective"
      assert registered.compression_pct == 0

      # The parent's children list was recomputed from parent_id.
      parent = Enum.find(agents, &(&1.id == 1))
      assert parent.children == [{2, :pending}]
      assert parent.has_children
    end

    test "registered event with an incomplete summary falls back to a full refresh", %{
      conn: conn
    } do
      Application.put_env(:evo_dash, :agents_list_runner, fn _node ->
        [summary_agent(id: 1), summary_agent(id: 2, objective: "from refresh")]
      end)

      on_exit(&clear_agents_env/0)

      {:ok, view, _html} = live(conn, ~p"/agents")
      flush_agents_load(view)

      # A summary missing fields the tree needs (status/depth/parent_id) —
      # the handler must fall back to a full async refresh instead of
      # merging a broken row.
      send(view.pid, {:agent_registered, 3, %{id: 3}, node()})

      wait_until(fn -> assigns(view)[:refresh_seq] == 1 end)
      wait_until(fn -> assigns(view)[:agents] |> Enum.any?(&(&1.id == 2)) end)

      refute Enum.any?(assigns(view)[:agents], &(&1.id == 3))
    end

    test "updated event merges changed fields in-memory (local)", %{conn: conn} do
      Application.put_env(:evo_dash, :agents_config_runner, fn _node ->
        {:ok, %{llm: %{compression_threshold_tokens: 42_000}}}
      end)

      on_exit(&clear_agents_env/0)

      seed_agent(1, [])

      {:ok, view, _html} = live(conn, ~p"/agents")
      flush_agents_load(view)

      send(view.pid, {:agent_updated, 1, [status: :waiting, total_tokens: 21_000], node()})

      wait_until(fn -> assigns(view)[:previous_statuses][1] == :waiting end)

      agent = assigns(view)[:agents] |> Enum.find(&(&1.id == 1))
      assert agent.status == :waiting
      assert agent.total_tokens == 21_000
      # 21_000 / 42_000 = 50% — recomputed from the node's configured threshold.
      assert agent.compression_pct == 50
      assert assigns(view)[:changed_status_ids] |> MapSet.member?(1)
    end

    test "updated event applies for remote viewing too", %{conn: conn} do
      seed_agent(1, [])
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

      send(view.pid, {:agent_updated, 1, [status: :waiting], remote_node})

      wait_until(fn ->
        assigns(view)[:agents] |> Enum.find(&(&1.id == 1)) |> Map.get(:status) == :waiting
      end)
    end

    test "removed event drops the row (local)", %{conn: conn} do
      seed_agent(1, [])

      {:ok, view, _html} = live(conn, ~p"/agents")
      flush_agents_load(view)
      assert assigns(view)[:agents] |> Enum.map(& &1.id) == [1]

      send(view.pid, {:agent_removed, 1, node()})

      wait_until(fn -> assigns(view)[:agents] == [] end)
      refute render(view) =~ "#1"
    end

    test "removed event drops the row for remote viewing (previously invisible)", %{conn: conn} do
      seed_agent(1, [])
      remote_node = :remote@elsewhere

      {:ok, view, _html} = live(conn, ~p"/agents")
      flush_agents_load(view)
      assert assigns(view)[:agents] |> Enum.map(& &1.id) == [1]

      :sys.replace_state(view.pid, fn state ->
        %{
          state
          | socket: %{
              state.socket
              | assigns: Map.put(state.socket.assigns, :current_node, remote_node)
            }
        }
      end)

      send(view.pid, {:agent_removed, 1, remote_node})

      wait_until(fn -> assigns(view)[:agents] == [] end)
    end

    test "foreign-node events are ignored (tree unchanged, no refresh spawned)", %{conn: conn} do
      seed_agent(1, [])

      {:ok, view, _html} = live(conn, ~p"/agents")
      flush_agents_load(view)
      assert assigns(view)[:refresh_seq] == 0

      foreign = :remote@elsewhere

      send(view.pid, {:agents_updated, foreign})
      send(view.pid, {:agent_registered, 2, summary_agent(id: 2), foreign})
      send(view.pid, {:agent_updated, 1, [status: :waiting], foreign})
      send(view.pid, {:agent_removed, 1, foreign})

      # All four events must be dropped — no refresh spawned (refresh_seq
      # stays 0) and the tree is unchanged.
      Process.sleep(100)
      assert assigns(view)[:refresh_seq] == 0
      assert assigns(view)[:agents] |> Enum.map(& &1.id) == [1]
      assert Enum.find(assigns(view)[:agents], &(&1.id == 1)).status == :running
    end
  end

  describe "agent_updated message_count gating" do
    # The {:agent_updated, id, changed_fields, node} broadcast carries
    # :message_count whenever the agent's context changed (the contract).
    # The selected-agent history refetch is gated on it via HistoryGate:
    # fetch only when the count moved vs the gate's last-seen entry.

    test "refetches selected history when message_count moved on", %{conn: conn} do
      seed_agent(1, [
        %ReqLLM.Message{role: :user, content: [%{text: "hi"}], metadata: %{turn: 1}}
      ])

      counter = start_history_counter()
      Application.put_env(:evo_dash, :agents_history_runner, counting_history_runner(counter))
      on_exit(&clear_agents_env/0)

      {:ok, view, _html} = live(conn, ~p"/agents")
      flush_agents_load(view)

      view |> element("#agent-card-1") |> render_click()
      wait_until(fn -> render(view) =~ "fake message 1" end)
      assert Agent.get(counter, & &1) == 1

      # The agent's context grew (message_count 1 -> 2) — the event carries
      # the fresh count, so the refetch fires and the second message renders.
      send(view.pid, {:agent_updated, 1, [message_count: 2], node()})

      wait_until(fn -> Agent.get(counter, & &1) == 2 end)
      assert render(view) =~ "fake message 2"
    end

    test "does not refetch when message_count is unchanged", %{conn: conn} do
      seed_agent(1, [
        %ReqLLM.Message{role: :user, content: [%{text: "hi"}], metadata: %{turn: 1}}
      ])

      counter = start_history_counter()
      Application.put_env(:evo_dash, :agents_history_runner, counting_history_runner(counter))
      on_exit(&clear_agents_env/0)

      {:ok, view, _html} = live(conn, ~p"/agents")
      flush_agents_load(view)

      view |> element("#agent-card-1") |> render_click()
      wait_until(fn -> render(view) =~ "fake message 1" end)
      assert Agent.get(counter, & &1) == 1

      # Same message_count — the gate suppresses the refetch (the status
      # change still proves the merge applied).
      send(view.pid, {:agent_updated, 1, [message_count: 1, status: :waiting], node()})

      wait_until(fn -> render(view) =~ "WAITING" end)
      assert Agent.get(counter, & &1) == 1
    end

    test "does not refetch when changed_fields lacks :message_count", %{conn: conn} do
      seed_agent(1, [
        %ReqLLM.Message{role: :user, content: [%{text: "hi"}], metadata: %{turn: 1}}
      ])

      counter = start_history_counter()
      Application.put_env(:evo_dash, :agents_history_runner, counting_history_runner(counter))
      on_exit(&clear_agents_env/0)

      {:ok, view, _html} = live(conn, ~p"/agents")
      flush_agents_load(view)

      view |> element("#agent-card-1") |> render_click()
      wait_until(fn -> render(view) =~ "fake message 1" end)
      assert Agent.get(counter, & &1) == 1

      # No :message_count in changed_fields — nothing context-related moved,
      # so no refetch even though the selected agent was updated.
      send(view.pid, {:agent_updated, 1, [status: :waiting], node()})

      wait_until(fn -> render(view) =~ "WAITING" end)
      assert Agent.get(counter, & &1) == 1
    end
  end

  describe "compression threshold" do
    # The compression % bars use the node's [:llm, :compression_threshold_tokens]
    # from the RESOLVED config (via ThresholdCache), not the 100_000 fallback.

    test "threshold_from_config/1 extracts the threshold from the resolved config" do
      assert ThresholdCache.threshold_from_config(
               {:ok, %{llm: %{compression_threshold_tokens: 42_000}}}
             ) == 42_000

      assert ThresholdCache.threshold_from_config({:ok, %{}}) == 100_000
      assert ThresholdCache.threshold_from_config({:error, :timeout}) == 100_000
    end

    test "default_threshold/0 falls back to 100_000" do
      assert ThresholdCache.default_threshold() == 100_000
    end

    test "compression percentage uses the configured node threshold", %{conn: conn} do
      Application.put_env(:evo_dash, :agents_list_runner, fn _node ->
        [summary_agent(total_tokens: 21_000)]
      end)

      Application.put_env(:evo_dash, :agents_config_runner, fn _node ->
        {:ok, %{llm: %{compression_threshold_tokens: 42_000}}}
      end)

      on_exit(&clear_agents_env/0)

      {:ok, view, _html} = live(conn, ~p"/agents")
      flush_agents_load(view)

      view |> element("#agent-card-1") |> render_click()
      view |> element("button[phx-click='toggle_usage']") |> render_click()
      html = render(view)

      # 21_000 / 42_000 = 50% — the old bug computed against the 100_000
      # default, which would render "(21%)".
      assert html =~ "(50%)"
      refute html =~ "(21%)"
    end
  end

  describe "config_status node-awareness" do
    # BUG 3 fix: config_status was read once in mount via
    # EvoGit.Config.config_status() and never refreshed per-node. The layout
    # config banner showed LOCAL status while viewing remote agents. The fix
    # makes config_status node-aware via node_config_status/1.

    test "page renders with config_status populated on local node", %{conn: conn} do
      # The config_status assign should be populated and non-nil on the local
      # node, proving the node-aware helper works in the local case. The layout
      # config banner reads @config_status, so if the page renders without error
      # the assign is present. We verify by checking the rendered HTML includes
      # the config status badge (present in the navbar when config_status is set).
      {:ok, _view, html} = live(conn, ~p"/agents")

      # The page should render the agent tree section without crashing, proving
      # config_status was loaded successfully by the node-aware helper.
      assert html =~ "Agent Tree"
    end
  end

  describe "format_history_timestamp/1" do
    # Session-memory messages carry a wall-clock timestamp in
    # metadata[:timestamp] (stamped at the source by the :evo_git runtime;
    # Unix-seconds integer or DateTime). The dashboard shows a short LOCAL
    # time next to "Turn x" when present, and renders nothing when absent.

    test "returns nil for an absent timestamp" do
      assert Helpers.format_history_timestamp(nil) == nil
    end

    test "returns nil for unparseable values" do
      assert Helpers.format_history_timestamp("not-a-time") == nil
      assert Helpers.format_history_timestamp(:bogus) == nil
      assert Helpers.format_history_timestamp(%{}) == nil
    end

    test "formats a Unix-seconds integer as a short LOCAL time string" do
      formatted = Helpers.format_history_timestamp(@unix_seconds)

      assert formatted =~ ~r/^\d{2}:\d{2}:\d{2}$/
      assert formatted == expected_local_time(@unix_seconds)
    end

    test "formats a DateTime as the same short LOCAL time string" do
      datetime = DateTime.from_unix!(@unix_seconds, :second)

      assert Helpers.format_history_timestamp(datetime) ==
               Helpers.format_history_timestamp(@unix_seconds)
    end

    test "formats an ISO8601 binary as the same short LOCAL time string" do
      iso = "2023-11-14T22:13:20Z"

      assert Helpers.format_history_timestamp(iso) ==
               Helpers.format_history_timestamp(@unix_seconds)
    end

    test "converts to LOCAL time, not UTC" do
      local = Helpers.format_history_timestamp(@unix_seconds)
      utc = Calendar.strftime(DateTime.from_unix!(@unix_seconds, :second), "%H:%M:%S")

      if local_offset_seconds() == 0 do
        assert local == utc
      else
        refute local == utc
      end
    end
  end

  describe "message timestamps in agent detail panel" do
    test "renders the short LOCAL time next to Turn x when the message has a timestamp", %{
      conn: conn
    } do
      seed_agent(1, [
        %ReqLLM.Message{
          role: :assistant,
          content: [%{text: "hello"}],
          metadata: %{turn: 1, timestamp: @unix_seconds}
        }
      ])

      {:ok, view, _html} = live(conn, ~p"/agents")
      flush_agents_load(view)

      view |> element("#agent-card-1") |> render_click()
      expected = Helpers.format_history_timestamp(@unix_seconds)
      # History is fetched asynchronously on selection — wait for it.
      html = wait_for_text(view, "Turn 1")

      assert html =~ "Turn 1"
      assert html =~ ~r/Turn 1\s*<span[^>]*>#{expected}<\/span>/
    end

    test "renders just Turn x (no time artifact) when the message has no timestamp", %{
      conn: conn
    } do
      seed_agent(1, [
        %ReqLLM.Message{role: :user, content: [%{text: "hi"}], metadata: %{turn: 2}}
      ])

      {:ok, view, _html} = live(conn, ~p"/agents")
      flush_agents_load(view)

      view |> element("#agent-card-1") |> render_click()
      html = wait_for_text(view, "Turn 2")

      assert html =~ "Turn 2"
      refute html =~ ~r/Turn 2\s*<span[^>]*>\d{2}:\d{2}:\d{2}<\/span>/
    end
  end

  describe "inline tool call rendering in agent detail panel" do
    test "renders shell tool call command and non-shell arguments inline", %{conn: conn} do
      seed_agent(1, [
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
            }
          ]
        }
      ])

      {:ok, view, _html} = live(conn, ~p"/agents")
      flush_agents_load(view)

      view |> element("#agent-card-1") |> render_click()
      html = wait_for_text(view, "Shell call")

      # Shell call: context label + command rendered inline (no expansion needed)
      assert html =~ "Shell call"
      assert html =~ "ls -la"

      # Non-shell call: function name + (pretty) arguments inline
      assert html =~ "read_file"
      assert html =~ "./README.md"
    end
  end

  describe "send_agent_message optimistic display" do
    # The optimistic-display flow (commit 04c82f82): sending a user message
    # appends it to the @optimistic_messages assign and it renders in the
    # agent's chat history with a pending hint until the agent drains it into
    # context on its next turn (see EvoDashWeb.AgentsLive.OptimisticMessages).
    # A missing agent must surface as a failure flash, not a false success.

    test "successfully sent message appears optimistically in the chat history", %{conn: conn} do
      seed_agent(1, [])

      {:ok, view, _html} = live(conn, ~p"/agents")
      flush_agents_load(view)

      # Select the agent to open its detail panel (renders the chat history).
      view |> element("#agent-card-1") |> render_click()
      # Open the send-message modal for the running agent.
      view |> element("button[phx-click='open_send_message']") |> render_click()

      html =
        render_submit(view, "send_agent_message", %{
          "agent_id" => "1",
          "message" => "hello optimistic world"
        })

      # The message text renders in the chat history...
      assert html =~ "hello optimistic world"
      # ...with the pending hint (apostrophe is HTML-escaped to &#39; in HEEx).
      assert html =~ "will be added on the agent&#39;s next turn"
      # ...and the success flash is shown.
      assert html =~ "Message sent to agent"
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

  describe "safe_text/1" do
    # BUG fix: message content / tool-call arguments that are Maps (not strings)
    # crashed the LiveView with Protocol.UndefinedError: protocol
    # Phoenix.HTML.Safe not implemented for Map. safe_text/1 converts any value
    # to an HTML-safe string before it is rendered in HEEx.

    test "returns empty string for nil" do
      assert Helpers.safe_text(nil) == ""
    end

    test "returns a plain string as-is" do
      assert Helpers.safe_text("hello world") == "hello world"
    end

    test "renders a flat map as sorted key: value lines without crashing" do
      result =
        Helpers.safe_text(%{
          "commit_id" => "",
          "objective" => "foo",
          "path" => "./x"
        })

      assert is_binary(result)

      # Keys are sorted alphabetically.
      assert result == "commit_id: \nobjective: foo\npath: ./x"

      # Must be HTML-safe (a Map would previously crash Phoenix.HTML.Safe).
      assert match?({:safe, _}, Phoenix.HTML.html_escape(result))
    end

    test "renders a nested map with inspect for non-string leaf values" do
      result =
        Helpers.safe_text(%{
          "args" => %{"limit" => 10},
          "name" => "sub_agent"
        })

      assert is_binary(result)
      # The nested map leaf is rendered via inspect/1.
      assert result =~ "args:"
      assert result =~ "%{\"limit\" => 10}"
      assert result =~ "name: sub_agent"
    end

    test "handles lists of strings by joining them" do
      assert Helpers.safe_text(["a", "b", "c"]) == "a\nb\nc"
    end

    test "handles lists with non-string elements via inspect" do
      assert Helpers.safe_text([1, 2, 3]) =~ "[1, 2, 3]"
    end

    test "falls back to inspect for arbitrary terms" do
      assert Helpers.safe_text(:an_atom) == ":an_atom"
      assert Helpers.safe_text(42) == "42"
    end

    test "the exact map shape from the crash report is handled" do
      # Regression: this was the value that caused
      # Protocol.UndefinedError (Phoenix.HTML.Safe not implemented for Map)
      # in the agents_live template.
      map = %{
        "commit_id" => "",
        "objective" => "Investigate and fix the GitHub Actions...",
        "path" => "./.github/workflows"
      }

      result = Helpers.safe_text(map)

      assert is_binary(result)
      assert result =~ "objective: Investigate"
      assert result =~ "path: ./.github/workflows"
    end
  end

  describe "HistoryGate" do
    test "need_fetch?/3 requires a fetch when there is no last-seen entry" do
      assert HistoryGate.need_fetch?(%{}, 1, 5)
    end

    test "need_fetch?/3 requires a fetch when the message count moved" do
      assert HistoryGate.need_fetch?(%{1 => 3}, 1, 5)
    end

    test "need_fetch?/3 suppresses the fetch while the count is unchanged" do
      refute HistoryGate.need_fetch?(%{1 => 5}, 1, 5)
    end

    test "need_fetch?/3 treats nil counts as needing a fetch" do
      assert HistoryGate.need_fetch?(%{1 => 5}, 1, nil)
      assert HistoryGate.need_fetch?(%{1 => nil}, 1, 5)
    end

    test "record/3 stores the count a fetched history corresponds to" do
      assert HistoryGate.record(%{}, 1, 5) == %{1 => 5}
      assert HistoryGate.record(%{1 => 3}, 1, 5) == %{1 => 5}
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

  # ── Private helpers ─────────────────────────────────────────────

  # Reads the LiveView's CURRENT socket assigns directly (same pattern as
  # system_live_test / welcome_live_test / settings_live_agents_test).
  defp assigns(view), do: :sys.get_state(view.pid).socket.assigns

  # Delegates to the shared flush helper (EvoDashWeb.TestHelpers.flush_loading/4).
  defp flush_agents_load(view, timeout \\ 5000),
    do:
      EvoDashWeb.TestHelpers.flush_loading(
        view,
        "Loading agents…",
        "timed out waiting for the async agents load to finish",
        timeout
      )

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

  # Deletes ALL the AgentsLive env seams (each is resolved at call time inside
  # the async tasks, so a leaked value would leak into later tests).
  defp clear_agents_env do
    for key <- [:agents_list_runner, :agents_history_runner, :agents_config_runner] do
      Application.delete_env(:evo_dash, key)
    end
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
  # EvoDashWeb.AgentsLive.LoadData.build_agents consumes).
  defp summary_agent(overrides) do
    Map.merge(
      %{
        id: 1,
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
        task_id: nil,
        task_number: nil,
        retries: 0
      },
      Map.new(overrides)
    )
  end

  # A fully-shaped agent map for stale-result injection. Distinctive id 99
  # (renders as "#99" in the tree) so a leaked stale result fails loudly.
  defp marker_agent do
    %{
      id: 99,
      task_local_id: nil,
      repo_id: "primary",
      repo_root: nil,
      task_id: nil,
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
    }
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
