defmodule EvoDashWeb.ProcessComponentsTest do
  @moduledoc """
  Regression coverage for `EvoDashWeb.ProcessComponents` over the records the
  core actually produces: `%EvoGit.ProcessManager.Execution{}` **structs**.

  A struct does NOT implement the Access behaviour, so a `record[:field]` read
  raises `UndefinedFunctionError` at render time — the P0 crash this suite
  pins (`compact_rows/1` in production, then `execution_row/1` and
  `execution_details/1`). The same components must keep working for the plain
  atom-keyed maps that PubSub payloads and existing fixtures use, so every
  case is rendered BOTH ways.

  Each test asserts real rendered content (element ids, status labels, command
  text, agent/task links, runtime/backend labels, the OS target, paths, times
  and control-log reasons) — never merely "it did not raise".
  """

  use EvoDashWeb.ConnCase, async: true

  import Phoenix.LiveViewTest

  alias EvoDashWeb.ProcessComponents
  alias EvoGit.ProcessManager.Execution

  @started_at ~U[2026-11-09 10:00:00Z]
  @ended_at ~U[2026-11-09 10:02:05Z]

  # ---------------------------------------------------------------------------
  # compact_rows/1 — the exact production crash (`/agents` panel)
  # ---------------------------------------------------------------------------

  describe "compact_rows/1 with Execution structs" do
    test "renders the status badge, command, target and memory of each struct row" do
      html =
        render_component(&ProcessComponents.compact_rows/1, %{
          executions: [running_execution(), completed_execution(unit: nil)]
        })

      doc = Floki.parse_document!(html)

      # The element id comes from `execution[:id]` — the crash site — and is
      # the deep-link anchor each row is found by.
      assert [running] = Floki.find(doc, "#agent-process-proc-1")
      running_text = running |> Floki.text() |> String.trim()

      assert running_text =~ "Running"
      assert running_text =~ "mix test"
      assert running_text =~ "unit genesis-tool-1.service"
      assert running_text =~ "50.0 MB"

      assert [completed] = Floki.find(doc, "#agent-process-proc-2")
      completed_text = completed |> Floki.text() |> String.trim()

      assert completed_text =~ "Completed"
      assert completed_text =~ "cargo build --release"
      assert completed_text =~ "pid 4242"
      assert completed_text =~ "1.0 MB"

      # Exactly one row per execution (no duplicate ids, no missing rows).
      assert length(Floki.find(doc, "div[id^='agent-process-']")) == 2
    end

    test "an emptied or degenerate list renders placeholders instead of raising" do
      assert render_component(&ProcessComponents.compact_rows/1, %{executions: []}) =~
               "space-y-1"

      # `nil` and a bare map are not records: the row degrades to the
      # "unknown" id and dash placeholders.
      html =
        render_component(&ProcessComponents.compact_rows/1, %{executions: [nil, %{}]})

      doc = Floki.parse_document!(html)
      assert length(Floki.find(doc, "div[id='agent-process-unknown']")) == 2
      assert html =~ "—"
      assert html =~ "Unknown"
    end
  end

  # ---------------------------------------------------------------------------
  # execution_row/1 — `/processes` table rows
  # ---------------------------------------------------------------------------

  describe "execution_row/1 with an Execution struct" do
    test "the collapsed row carries id, status, command, links and OS labels" do
      html = render_row(running_execution())

      assert html =~ ~s(id="process-row-proc-1")
      # Collapsed: no detail block.
      refute html =~ "Full Command"
      refute html =~ "Control Log"

      assert html =~ "Running"
      assert html =~ "bash"
      assert html =~ "mix test"

      # Agent/task cells are node-aware links with the record's ids.
      assert html =~ ~s(href="/agents")
      assert html =~ "#101"
      assert html =~ ~s(href="/tasks")
      assert html =~ "#task-1"

      assert html =~ "Foreground"
      assert html =~ "systemd"
      assert html =~ "unit genesis-tool-1.service"
      assert html =~ "12.3%"
      assert html =~ "50.0 MB"
      # A live row keeps its operator controls.
      assert html =~ ~s(aria-label="Pause")
      assert html =~ ~s(aria-label="Kill")
    end

    test "the expanded row renders the detail block: paths, times and control log" do
      html = render_row(completed_execution(), expanded: true)

      # Still the summary row itself.
      assert html =~ ~s(id="process-row-proc-2")
      assert html =~ "Completed"
      assert html =~ "cargo build --release"
      assert html =~ "unit genesis-tool-1.service"

      # ...plus the second latent crash site: every field of `execution_details`.
      assert html =~ "Full Command"
      assert html =~ "Working Directory"
      assert html =~ "/tmp/repo"
      assert html =~ "Repository Root"
      assert html =~ "/srv/repo"
      assert html =~ "Foreground"
      assert html =~ "systemd"
      assert html =~ "Started"
      assert html =~ "2026-11-09 10:00"
      assert html =~ "Ended"
      assert html =~ "2026-11-09 10:02"

      # Control log: action, signal, verbatim reason, time and actor.
      assert html =~ "Control Log"
      assert html =~ "Kill"
      assert html =~ "TERM"
      assert html =~ "operator killed it"
      assert html =~ "10:02:04"
      assert html =~ "Dashboard"

      # A terminal row offers no controls.
      refute html =~ ~s(aria-label="Kill")
      refute html =~ ~s(aria-label="Terminate")
    end

    test "a struct row with no ids, target or stats still renders placeholders" do
      html =
        render_row(%Execution{
          id: "proc-empty",
          status: :failed,
          command: "unknown command",
          backend: :none,
          runtime: :detached
        })

      assert html =~ ~s(id="process-row-proc-empty")
      assert html =~ "Failed"
      assert html =~ "unknown command"
      assert html =~ "Detached"
      assert html =~ "—"
    end
  end

  # ---------------------------------------------------------------------------
  # execution_details/1 — struct AND plain-map (PubSub payload) shapes
  # ---------------------------------------------------------------------------

  describe "execution_details/1" do
    test "renders an Execution struct's full command, paths, labels and log" do
      html = render_details(completed_execution())

      assert html =~ "cargo build --release"
      assert html =~ "Working Directory"
      assert html =~ "/tmp/repo"
      assert html =~ "Repository Root"
      assert html =~ "/srv/repo"
      assert html =~ "Foreground"
      assert html =~ "systemd"
      assert html =~ "2026-11-09 10:00"
      assert html =~ "2026-11-09 10:02"
      assert html =~ "operator killed it"
      assert html =~ "TERM"
      assert html =~ "Dashboard"
    end

    test "renders a plain atom-keyed map identically (PubSub payload shape)" do
      execution = %{
        id: "proc-map",
        status: :running,
        tool: "bash",
        command: "npm run dev",
        cwd: "/work/app",
        repo_root: "/work/app",
        runtime: :detached,
        backend: :bwrap,
        started_at: @started_at,
        ended_at: nil,
        reason: nil,
        control_log: [
          %{
            action: :pause,
            signal: "STOP",
            reason: "initial pause by operator",
            actor: :remote,
            at: ~U[2026-11-10 04:02:03Z]
          }
        ]
      }

      html = render_details(execution)

      assert html =~ "npm run dev"
      assert html =~ "/work/app"
      assert html =~ "Detached"
      assert html =~ "bwrap"
      assert html =~ "2026-11-09 10:00"
      # A nil `ended_at` is a placeholder, never a crash.
      assert html =~ "Ended"
      assert html =~ "—"
      assert html =~ "initial pause by operator"
      assert html =~ "Pause"
      assert html =~ "STOP"
      assert html =~ "04:02:03"
    end

    test "an empty control log says so instead of rendering a table" do
      html = render_details(running_execution())

      assert html =~ "No control actions recorded."
      refute html =~ "TERM"
    end
  end

  # ---------------------------------------------------------------------------
  # Fixtures — REAL structs (the authoritative field list is
  # `EvoGit.ProcessManager.Execution`)
  # ---------------------------------------------------------------------------

  defp running_execution(overrides \\ []) do
    struct!(
      %Execution{
        id: "proc-1",
        kind: :tool_call,
        tool: "bash",
        command: "mix test",
        label: nil,
        agent_id: 101,
        task_id: "task-1",
        owner_pid: nil,
        cwd: "/tmp/repo",
        repo_root: "/srv/repo",
        backend: :systemd,
        runtime: :foreground,
        status: :running,
        os_pid: nil,
        unit: "genesis-tool-1.service",
        job_id: nil,
        exit_code: nil,
        reason: nil,
        inserted_at: @started_at,
        started_at: @started_at,
        ended_at: nil,
        stats: %{cpu_percent: 12.3, rss_bytes: 52_428_800},
        control_log: []
      },
      overrides
    )
  end

  # The terminal record: a completed foreground tool call with one operator
  # control-log entry.
  defp completed_execution(overrides \\ []) do
    struct!(
      running_execution(),
      [
        id: "proc-2",
        command: "cargo build --release",
        agent_id: 202,
        task_id: "task-42",
        os_pid: 4242,
        status: :completed,
        exit_code: 0,
        started_at: @started_at,
        ended_at: @ended_at,
        stats: %{cpu_percent: 0.0, rss_bytes: 1_048_576},
        control_log: [
          %{
            action: :kill,
            signal: "TERM",
            reason: "operator killed it",
            actor: :remote,
            at: ~U[2026-11-09 10:02:04Z]
          }
        ]
      ] ++ overrides
    )
  end

  # ---------------------------------------------------------------------------
  # Render helpers
  # ---------------------------------------------------------------------------

  defp render_row(execution, opts \\ []) do
    render_component(&ProcessComponents.execution_row/1, %{
      execution: execution,
      expanded: Keyword.get(opts, :expanded, false),
      node_id: Keyword.get(opts, :node_id)
    })
  end

  defp render_details(execution) do
    render_component(&ProcessComponents.execution_details/1, %{execution: execution})
  end
end
