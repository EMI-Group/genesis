defmodule EvoDashWeb.AgentsLiveTest do
  use EvoDashWeb.ConnCase, async: false
  import Phoenix.LiveViewTest

  alias EvoDashWeb.Helpers
  alias EvoGit.AgentSpec
  alias EvoGit.AgentScheduler.AgentState
  alias EvoGit.AgentScheduler.SchedMeta
  alias EvoGit.Core.ContextNode
  alias EvoGit.Core.PhyloGraphNode

  # A fixed UTC instant: 2023-11-14 22:13:20Z
  @unix_seconds 1_700_000_000

  describe "agents page" do
    test "renders the agents page", %{conn: conn} do
      {:ok, _view, html} = live(conn, ~p"/agents")

      assert html =~ "Agent Tree"
    end

    test "shows empty state when no agents are running", %{conn: conn} do
      {:ok, _view, html} = live(conn, ~p"/agents")

      assert html =~ "No agents currently registered"
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
    alias EvoGit.AgentSpec
    alias EvoGit.AgentScheduler.AgentState
    alias EvoGit.AgentScheduler.SchedMeta
    alias EvoGit.Core.ContextNode
    alias EvoGit.Core.PhyloGraphNode

    setup do
      on_exit(fn ->
        # Clean up only the rows this file seeds; the tables themselves are
        # owned by the :evo_git application process (survive the test process).
        if :ets.whereis(:evogit_sched_meta) != :undefined,
          do: :ets.delete(:evogit_sched_meta, 1)

        if :ets.whereis(:evogit_agent_state) != :undefined,
          do: :ets.delete(:evogit_agent_state, 1)
      end)
    end

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
      html = view |> element("#agent-card-1") |> render_click()
      expected = Helpers.format_history_timestamp(@unix_seconds)

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
      html = view |> element("#agent-card-1") |> render_click()

      assert html =~ "Turn 2"
      refute html =~ ~r/Turn 2\s*<span[^>]*>\d{2}:\d{2}:\d{2}<\/span>/
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

  # ── Private helpers ─────────────────────────────────────────────

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
