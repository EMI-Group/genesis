defmodule EvoDashWeb.AgentsLive.ProcessesSectionTest do
  @moduledoc """
  Focused coverage of the `/agents` detail panel's **Processes** section
  (`EvoDashWeb.AgentsLive.ProcessesSection`): the async fetch lifecycle wired
  through `select_agent` / `close_details`, and the pure render contract
  (count badge, compact rows, empty and error states, the node-aware deep
  link).

  Deliberately small — the rest of the AgentsLive matrix lives in
  `agents_live_test.exs` and is not duplicated here.
  """

  # async: false — the forcing global is the process-global app-env seam
  # `:agents_processes_runner`: `AgentsLive` reads it on every `select_agent`
  # (via `ProcessesSection.start/2`), so the ASYNC `agents_live_test.exs`
  # would call this file's injected fake whenever the two overlap. The
  # scheduler ETS rows (`:evogit_sched_meta` / `:evogit_agent_state`) this file
  # seeds use a UNIQUE per-test id and are deleted in `on_exit`, so they are
  # never the reason for the sync placement.
  use EvoDashWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias EvoDashWeb.AgentsLive.ProcessesSection
  alias EvoGit.AgentSpec
  alias EvoGit.AgentScheduler.AgentState
  alias EvoGit.AgentScheduler.SchedMeta
  alias EvoGit.Core.ContextNode
  alias EvoGit.Core.PhyloGraphNode
  alias EvoGit.ProcessManager.Execution

  # Exit-safe `:sys.get_state/2` timeout: the LiveView can be starved for
  # seconds on a loaded host, where the 5 s default would turn a state read
  # into an `(EXIT) time out` failure.
  @assigns_timeout_ms 30_000
  # Load-tolerant budget for the bounded, event-driven waits below (the shared
  # host's scheduling swings 10-30x — see test/CONTEXT.md).
  @async_wait_budget_ms 30_000
  # Poll cadence of the render wait (bounded, never a fixed sleep).
  @poll_ms 2

  setup do
    # The scheduler ETS tables are owned by the :evo_git application process
    # and survive the test process, i.e. they are SHARED across the whole async
    # cohort. Seed this test's agent under a UNIQUE id, far above the
    # scheduler's low monotonically increasing sequence.
    agent_id = System.unique_integer([:positive]) + 10_000_000
    Process.put(:processes_section_test_agent_id, agent_id)

    on_exit(fn ->
      for table <- [:evogit_sched_meta, :evogit_agent_state] do
        if :ets.whereis(table) != :undefined, do: :ets.delete(table, agent_id)
      end
    end)

    :ok
  end

  describe "select_agent — async fetch" do
    test "fetches the selected agent's processes off-process and renders the rows", %{
      conn: conn
    } do
      seed_agent(agent_id(), [])
      install_processes_runner(fake_executions())

      {:ok, view, _html} = live(conn, ~p"/agents")
      flush_agents_load(view)

      # The agent card is the ONLY select_agent trigger on the page.
      view |> element("#agent-card-#{agent_id()}") |> render_click()

      # The runner runs in an EvoDash.TaskSupervisor child (never on the
      # LiveView process) and receives the viewed BEAM node + the agent id.
      assert_receive {:processes_runner_called, runner_node, runner_agent_id},
                     @async_wait_budget_ms

      assert runner_node == node()
      assert runner_agent_id == agent_id()

      html = render_until(view, &(&1 =~ "agent-process-501"))

      doc = Floki.parse_document!(html)

      # Count badge: the heading's own badge (status badges live in the rows).
      badge = Floki.find(doc, "#agent-processes-section h4 .badge")

      assert [{"span", _attrs, _children} = badge_node] = badge
      assert badge_node |> Floki.text() |> String.trim() == "2"

      # One compact row per fake execution, carrying the status badge, the
      # command, the pid target and the human memory figure.
      for {id, status, command, target, memory} <- [
            {"501", "Running", "mix test", "pid 4242", "50.0 MB"},
            {"502", "Completed", "rg -n TODO lib", "pid 4243", "1.0 MB"}
          ] do
        assert [row] = Floki.find(doc, "#agent-process-#{id}")
        text = row |> Floki.text() |> String.trim()

        assert text =~ status
        assert text =~ command
        assert text =~ target
        assert text =~ memory
      end

      # The resolved fetch clears the loading line and the empty state.
      refute html =~ "Loading processes…"
      refute html =~ "No processes for this agent."
    end
  end

  describe "deep link" do
    test "targets /processes with the agent id and, only when set, the node param" do
      local_html = render_section(current_node_id: nil)

      assert link_href(local_html) == "/processes?agent_id=777"
      refute local_html =~ "&amp;node="
      assert local_html =~ "View in Processes"

      remote_html = render_section(current_node_id: "remote-target-1")

      assert link_href(remote_html) == "/processes?agent_id=777&node=remote-target-1"
    end
  end

  describe "close_details — section reset" do
    test "closing the detail panel resets the section and deselects the agent", %{conn: conn} do
      seed_agent(agent_id(), [])
      install_processes_runner(fake_executions())

      {:ok, view, _html} = live(conn, ~p"/agents")
      flush_agents_load(view)
      view |> element("#agent-card-#{agent_id()}") |> render_click()

      loaded_html = render_until(view, &(&1 =~ "agent-process-501"))
      assert loaded_html =~ "agent-processes-section"
      assert %{executions: executions} = assigns(view)[:agent_processes]
      assert is_list(executions) and executions != []

      # The detail panel's single close button (hero-x-mark header button).
      view |> element("button[phx-click='close_details']") |> render_click()

      assert assigns(view)[:agent_processes] == ProcessesSection.empty_state()
      assert assigns(view)[:selected_agent_id] == nil

      html = render(view)
      refute html =~ "agent-processes-section"
      refute html =~ "agent-process-501"
    end
  end

  describe "read-only render contract" do
    test "an empty loaded list renders the readable empty state and no controls" do
      html = render_section(executions: [])

      assert html =~ "No processes for this agent."
      # Read-only: no control affordances at all (the Processes PAGE owns
      # pause/resume/terminate/kill; this section only links out).
      refute html =~ "<button"
      refute html =~ "<form"
      refute html =~ "phx-click"
      refute html =~ "phx-submit"

      downcased = String.downcase(html)

      for control <- ["pause", "resume", "terminate", "kill"] do
        refute downcased =~ control, "read-only section must not offer #{control}"
      end
    end

    test "a failed fetch renders the reason instead of rows" do
      html = render_section(executions: nil, error: ":boom")

      assert html =~ "Failed to load processes: :boom"
      refute html =~ "No processes for this agent."
      refute html =~ "agent-process-"
    end

    # The core hands the section the registry's OWN records —
    # `%EvoGit.ProcessManager.Execution{}` structs, which do NOT implement
    # Access. A `record[:field]` read raises at render time (the production P0),
    # so this pins the struct shape end-to-end through the section.
    test "renders REAL Execution structs, not only plain atom-keyed maps" do
      html =
        render_section(
          executions: [
            %Execution{
              id: "proc-1",
              kind: :tool_call,
              tool: "bash",
              command: "mix test",
              agent_id: 777,
              task_id: "task-1",
              cwd: "/tmp/repo",
              repo_root: "/tmp/repo",
              backend: :systemd,
              runtime: :foreground,
              status: :running,
              unit: "genesis-tool-1.service",
              started_at: ~U[2026-11-09 10:00:00Z],
              stats: EvoGit.ProcessManager.Stats.empty()
            },
            %Execution{
              id: "proc-2",
              kind: :background_job,
              tool: "bash",
              command: "npm run dev",
              agent_id: 777,
              task_id: "task-2",
              cwd: "/tmp/repo",
              repo_root: "/tmp/repo",
              backend: :bwrap,
              runtime: :detached,
              status: :completed,
              os_pid: 4242,
              exit_code: 0,
              started_at: ~U[2026-11-09 10:00:00Z],
              ended_at: ~U[2026-11-09 10:02:05Z],
              stats: %{cpu_percent: 0.0, rss_bytes: 1_048_576}
            }
          ]
        )

      doc = Floki.parse_document!(html)

      # Count badge reflects both struct rows.
      assert [badge] = Floki.find(doc, "#agent-processes-section h4 .badge")
      assert badge |> Floki.text() |> String.trim() == "2"

      for {id, status, command, target} <- [
            {"proc-1", "Running", "mix test", "unit genesis-tool-1.service"},
            {"proc-2", "Completed", "npm run dev", "pid 4242"}
          ] do
        assert [row] = Floki.find(doc, "#agent-process-#{id}")
        text = row |> Floki.text() |> String.trim()

        assert text =~ status
        assert text =~ command
        assert text =~ target
      end

      assert html =~ "1.0 MB"
      refute html =~ "No processes for this agent."
    end
  end

  # ---------------------------------------------------------------------------
  # Test helpers
  # ---------------------------------------------------------------------------

  defp agent_id, do: Process.get(:processes_section_test_agent_id)

  # Installs the 2-arity `(node, agent_id)` runner seam, recording every call
  # to the TEST process as {:processes_runner_called, node, agent_id} and
  # answering `result` (a list, or an {:error, reason} tuple). The ORIGINAL
  # app-env value is restored in on_exit (absent stays absent).
  defp install_processes_runner(result) do
    test_pid = self()
    original = Application.get_env(:evo_dash, :agents_processes_runner)

    Application.put_env(:evo_dash, :agents_processes_runner, fn node, agent_id ->
      send(test_pid, {:processes_runner_called, node, agent_id})
      result
    end)

    on_exit(fn ->
      if is_nil(original) do
        Application.delete_env(:evo_dash, :agents_processes_runner)
      else
        Application.put_env(:evo_dash, :agents_processes_runner, original)
      end
    end)
  end

  # Two managed executions in the shape the ProcessManager entries take (atom
  # keys, read through the total EvoDashWeb.ProcessesLive.Format helpers).
  defp fake_executions do
    [
      %{
        id: 501,
        status: :running,
        command: "bash -lc 'mix test'",
        tool: "bash",
        os_pid: 4242,
        stats: %{rss_bytes: 52_428_800}
      },
      %{
        id: 502,
        status: :completed,
        command: "rg -n TODO lib",
        tool: "rg",
        os_pid: 4243,
        stats: %{rss_bytes: 1_048_576}
      }
    ]
  end

  # Renders `ProcessesSection.section/1` in isolation. `opts` are split: the
  # state keys (:agent_id, :executions, :loading, :error) build
  # `agent_processes`, everything else (:current_node_id) is a section assign.
  defp render_section(opts) do
    state =
      Map.merge(
        %{agent_id: 777, executions: [], loading: false, error: nil},
        opts |> Keyword.take([:agent_id, :executions, :loading, :error]) |> Map.new()
      )

    render_component(&ProcessesSection.section/1, %{
      agent_processes: state,
      current_node_id: Keyword.get(opts, :current_node_id, "remote-target-1"),
      selected_agent_id: state.agent_id
    })
  end

  # The "View in Processes" link's href (Floki decodes the `&amp;` entity).
  defp link_href(html) do
    case html |> Floki.parse_document!() |> Floki.find("#agent-processes-section a") do
      [{"a", attrs, _children}] -> Map.new(attrs)["href"]
      other -> flunk("expected exactly one link in the processes section, got: #{inspect(other)}")
    end
  end

  defp assigns(view), do: :sys.get_state(view.pid, @assigns_timeout_ms).socket.assigns

  defp flush_agents_load(view),
    do:
      EvoDashWeb.TestHelpers.flush_loading(
        view,
        "Loading agents…",
        "timed out waiting for the async agents load to finish",
        @async_wait_budget_ms
      )

  # Polls `render/1` until `predicate` matches (async results apply out of
  # band on this page) and returns the LAST render either way, so the caller's
  # assertion fails loudly with the real output instead of a timeout message.
  defp render_until(view, predicate) do
    deadline = System.monotonic_time(:millisecond) + @async_wait_budget_ms
    render_until_loop(view, predicate, deadline)
  end

  defp render_until_loop(view, predicate, deadline) do
    html = render(view)

    cond do
      predicate.(html) ->
        html

      System.monotonic_time(:millisecond) >= deadline ->
        html

      true ->
        Process.sleep(@poll_ms)
        render_until_loop(view, predicate, deadline)
    end
  end

  # Seeds one agent (sched_meta + agent_state) into the ETS tables the
  # RemoteAPI reads, so the page renders a real agent card.
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
end
