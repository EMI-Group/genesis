defmodule EvoDashWeb.LayoutsTest do
  @moduledoc """
  Render-level contracts for `EvoDashWeb.Layouts.app/1`: sidebar task grouping,
  Assistant navigation, keyboard focus, and the responsive configuration warning.

  `group_tasks_by_project/2` is private, so the grouping is exercised through
  the public `app/1` function component. `Layouts.app/1` needs a `flash`
  assign and an `inner_block` slot; everything else falls back to the
  component's declared defaults (including the empty `running_tasks` /
  `pending_tasks` lists).

  The sidebar lists are seeded from the shape-agnostic `EvoDash.ActiveTasks`
  hub, which means they can carry entries that are NOT task maps at all — the
  layout must omit those instead of crashing the whole page.
  """

  use ExUnit.Case, async: true

  import Phoenix.LiveViewTest

  alias EvoDashWeb.Layouts

  describe "app/1 — sidebar task grouping" do
    test "non-map sidebar entries are omitted instead of crashing the layout" do
      html =
        render_app(
          running_tasks: [
            :junk_atom,
            task(
              id: "task-1",
              status: :running,
              project_path: "/home/user/my-project",
              objective: "Fix the sidebar"
            )
          ],
          pending_tasks: ["not a task map"]
        )

      # The layout still renders its sidebar …
      assert html =~ "Active Tasks"

      # … the valid entry groups under its project basename …
      assert sidebar_group_names(html) == ["my-project"]
      assert sidebar_task_links(html) == 1
      assert html =~ "Fix the sidebar"
    end

    test "nil project_path groups as Other first, then case-insensitive alphabetical with running before pending" do
      html =
        render_app(
          running_tasks: [
            task(
              id: "b1",
              status: :running,
              project_path: "/home/user/Beta",
              objective: "Beta running"
            ),
            task(id: "o1", status: :running, project_path: nil, objective: "Other running")
          ],
          pending_tasks: [
            task(
              id: "a1",
              status: :pending,
              project_path: "/home/user/alpha",
              objective: "Alpha pending"
            ),
            task(
              id: "b2",
              status: :pending,
              project_path: "/home/user/Beta",
              objective: "Beta pending"
            )
          ]
        )

      assert sidebar_group_names(html) == ["Other", "alpha", "Beta"]
      assert sidebar_task_links(html) == 4

      assert sidebar_task_labels(html) == [
               "Other running",
               "Alpha pending",
               "Beta running",
               "Beta pending"
             ]
    end
  end

  describe "app/1 — Active Tasks ListEnter wiring" do
    # The `ListEnter` hook (assets/js/hooks/list_enter.js) owns the shared
    # insertion animation. Its markup half is: ONE hook on the LIST WRAPPER
    # (morphdom keeps the wrapper — and therefore the hook's baseline — mounted
    # while rows come and go), a NONEMPTY scope naming the viewed NODE only (the
    # list is cross-project, so a project must never enter the scope), and one
    # stable task-id key per row.
    test "the rows wrapper mounts ListEnter with the local node as a nonempty scope" do
      html =
        render_app(
          running_tasks: [
            task(id: "t1", status: :running, project_path: "/home/user/proj", objective: "One")
          ]
        )

      wrapper = html |> parse() |> active_tasks_rows_wrapper()
      assert Floki.attribute(wrapper, "data-list-enter-scope") == ["sidebar|local"]
    end

    test "a remote node scopes the list to that node, so a node change re-seeds the baseline" do
      html =
        render_app(
          current_node_id: "target-7",
          running_tasks: [
            task(id: "t1", status: :running, project_path: "/home/user/proj", objective: "One")
          ]
        )

      wrapper = html |> parse() |> active_tasks_rows_wrapper()
      assert Floki.attribute(wrapper, "data-list-enter-scope") == ["sidebar|target-7"]
    end

    test "every row is keyed by its task id — never by its href, sub-line or label" do
      html =
        render_app(
          running_tasks: [
            session_task(id: "s-1", status: :awaiting_input, objective: "Session one"),
            task(
              id: "t-run",
              status: :running,
              project_path: "/home/user/proj",
              objective: "Running"
            )
          ],
          pending_tasks: [
            task(
              id: "t-done",
              status: :completed,
              project_path: "/home/user/proj",
              objective: "Done"
            )
          ]
        )

      # Sessions group first, then the project group's live row before its
      # finished one.
      assert row_keys(html) == ["s-1", "t-run", "t-done"]

      # The SAME task keeps its key when its status changes (here live →
      # reviewable, which changes href, sub-line and title): a status change
      # must never replay the entrance animation.
      live = row_keys(render_app(running_tasks: [task_entry("t-run", :running)]))
      reviewable = row_keys(render_app(running_tasks: [task_entry("t-run", :completed)]))
      assert live == ["t-run"]
      assert reviewable == ["t-run"]

      # … and a task that becomes an interactive session (running →
      # :awaiting_input) keeps it too, because session rows use the same key.
      session = row_keys(render_app(running_tasks: [task_entry("t-run", :awaiting_input, true)]))
      assert session == ["t-run"]
    end

    test "keys are unique per render, one per row, and the group headers stay unkeyed" do
      html =
        render_app(
          running_tasks: [
            session_task(id: "s-1", status: :awaiting_input, objective: "Session one"),
            task(
              id: "a1",
              status: :running,
              project_path: "/home/user/alpha",
              objective: "A one"
            ),
            task(id: "b1", status: :running, project_path: "/home/user/Beta", objective: "B one")
          ],
          pending_tasks: [
            task(
              id: "a2",
              status: :completed,
              project_path: "/home/user/alpha",
              objective: "A two"
            )
          ]
        )

      keys = row_keys(html)
      # One key per rendered row and no duplicates: the hook keeps only the FIRST
      # element per key, so a duplicate would silently drop a row. Uniqueness is
      # structural — `session_tasks/2` keeps interactive entries only while
      # `group_tasks_by_project/2` rejects them, and the feed's running/pending
      # partitions are disjoint by status (`:completed` vs the live set).
      assert length(keys) == sidebar_task_links(html)
      assert length(keys) == length(Enum.uniq(keys))

      tree = parse(html)
      # Only rows carry a key: the "Sessions"/project group headers do not (and
      # they stay exactly where they are).
      keyed = Floki.find(tree, "#workbench-active-tasks [data-list-enter-key]")
      assert length(keyed) == length(keys)

      for header <- Floki.find(tree, "#workbench-active-tasks div.space-y-1 > div") do
        assert Floki.attribute(header, "data-list-enter-key") == []
      end
    end
  end

  describe "app/1 — paused/pausing tasks stay in the live partition" do
    # The task-level pause pair is NON-terminal: `:pausing` is still working (a
    # pause request drains the agents, wrapper + lease alive) and `:paused` is
    # stopped but resumable (`finished_at` nil). Neither may be rendered or routed
    # like a finished, reviewable task.
    test "a :pausing task is a live row: agents link, pulsing dot, 'Pausing' tooltip" do
      html =
        render_app(
          running_tasks: [
            task(
              id: "pa",
              status: :pausing,
              project_path: "/home/user/proj",
              objective: "Pausing task"
            )
          ]
        )

      assert sidebar_group_names(html) == ["proj"]
      assert sidebar_task_labels(html) == ["Pausing task"]

      [link] = html |> parse() |> Floki.find("[data-sidebar-task-link]")
      assert Floki.attribute(link, "href") == ["/agents"]

      [dot] = Floki.find(link, "span.rounded-full")
      # Still working → the row keeps its pulse; the wording names the drain.
      assert_classes(dot, ~w(animate-pulse))
      assert Floki.attribute(dot, "title") == ["Pausing"]

      refute html =~ "Pending Review"
    end

    test "a :paused task is a live, non-animated row: agents link, 'Paused' tooltip, before finished rows" do
      html =
        render_app(
          running_tasks: [
            task(
              id: "pz",
              status: :paused,
              project_path: "/home/user/proj",
              objective: "Paused task"
            )
          ],
          pending_tasks: [
            task(
              id: "done",
              status: :completed,
              project_path: "/home/user/proj",
              objective: "Finished task"
            )
          ]
        )

      assert sidebar_group_names(html) == ["proj"]
      # Live rows sort before their group's finished rows.
      assert sidebar_task_labels(html) == ["Paused task", "Finished task"]

      [paused_link, completed_link] = html |> parse() |> Floki.find("[data-sidebar-task-link]")

      # A paused task is NOT reviewable: it opens the agent inspector, never
      # `/review/<id>`, and it is never titled "Pending Review".
      assert Floki.attribute(paused_link, "href") == ["/agents"]
      assert Floki.attribute(completed_link, "href") == ["/review/done"]

      [paused_dot] = Floki.find(paused_link, "span.rounded-full")
      assert Floki.attribute(paused_dot, "title") == ["Paused"]
      # Stopped means stopped: no pulse animation on the dot.
      paused_classes = paused_dot |> Floki.attribute("class") |> Enum.join(" ") |> String.split()
      assert "rounded-full" in paused_classes
      refute "animate-pulse" in paused_classes

      [completed_dot] = Floki.find(completed_link, "span.rounded-full")
      assert Floki.attribute(completed_dot, "title") == ["Pending Review"]
    end
  end

  describe "app/1 — sidebar interactive sessions group" do
    # Interactive agent sessions get their OWN sidebar group ("Sessions", chat
    # icon, violet dot) above the per-project one-shot groups — a session must
    # never fall into "Other". A summary map without a `:session_mode` key is a
    # one-shot task (the defensive default is "oneshot").
    test "an interactive session renders in the Sessions group and never under Other" do
      html =
        render_app(
          running_tasks: [
            session_task(id: "s1", status: :awaiting_input, objective: "Session one")
          ]
        )

      assert sidebar_session_headers(html) == ["Sessions"]
      # No project/Other group for a path-less session.
      assert sidebar_group_names(html) == []
      assert sidebar_task_labels(html) == ["Session one"]

      # Sessions link to the task list and carry the violet idle-session dot,
      # pulsing like a running task.
      [link] = html |> parse() |> Floki.find("[data-sidebar-task-link]")
      assert Floki.attribute(link, "href") == ["/tasks"]
      assert [dot] = Floki.find(link, "span.rounded-full")
      assert_classes(dot, ~w(bg-violet-500 animate-pulse))
      assert Floki.text(link) =~ "Waiting for you"
    end

    test "one-shot tasks with no path still group under Other (with or without a session_mode key)" do
      without_key =
        task(id: "o1", status: :running, project_path: nil, objective: "No session_mode key")

      with_key =
        task(
          id: "o2",
          status: :running,
          project_path: nil,
          objective: "Explicit one-shot",
          session_mode: "oneshot"
        )

      refute Map.has_key?(without_key, :session_mode)

      html = render_app(running_tasks: [without_key, with_key])

      assert sidebar_session_headers(html) == []
      assert sidebar_group_names(html) == ["Other"]
      assert sidebar_task_labels(html) == ["No session_mode key", "Explicit one-shot"]
    end

    test "sessions keep feed order (running then pending) while project grouping is unchanged" do
      html =
        render_app(
          running_tasks: [
            session_task(id: "s-running", status: :running, objective: "Session running"),
            task(
              id: "b1",
              status: :running,
              project_path: "/home/user/Beta",
              objective: "Beta running"
            )
          ],
          pending_tasks: [
            session_task(id: "s-pending", status: :pending, objective: "Session pending"),
            task(
              id: "a1",
              status: :pending,
              project_path: "/home/user/alpha",
              objective: "Alpha pending"
            )
          ]
        )

      assert sidebar_session_headers(html) == ["Sessions"]
      assert sidebar_group_names(html) == ["alpha", "Beta"]

      assert sidebar_task_labels(html) == [
               "Session running",
               "Session pending",
               "Alpha pending",
               "Beta running"
             ]
    end

    test "non-map entries in either list are skipped without crashing" do
      html =
        render_app(
          running_tasks: [
            :junk_atom,
            session_task(id: "s1", status: :awaiting_input, objective: "Valid session")
          ],
          pending_tasks: ["not a task map", 42]
        )

      assert sidebar_session_headers(html) == ["Sessions"]
      assert sidebar_group_names(html) == []
      assert sidebar_task_labels(html) == ["Valid session"]
    end
  end

  describe "app/1 — sidebar Conversations section" do
    test "renders on a non-Assistant page, header directly above the section body, below Active Tasks" do
      html =
        render_app(
          current_page: :dashboard,
          running_tasks: [
            task(
              id: "task-1",
              status: :running,
              project_path: "/home/user/my-project",
              objective: "Active task"
            )
          ],
          session_list: [%{id: 3, title: "three", marker: :ended}]
        )

      tree = parse(html)

      # Below the Active Tasks block (layout order).
      labels = sidebar_label_texts(tree)
      assert "Active Tasks" in labels
      assert "Conversations" in labels

      assert Enum.find_index(labels, &(&1 == "Active Tasks")) <
               Enum.find_index(labels, &(&1 == "Conversations"))

      # Exactly ONE layout-owned "Conversations" header (chat icon) …
      assert conversations_headers(tree) == ["Conversations"]

      # … and it does NOT belong to the Active Tasks rows container, so the
      # Sessions-group helper keeps its pre-move meaning.
      assert sidebar_session_headers(html) == []

      # The header block and the section body are the Conversations block's
      # only two element children, in that order.
      assert [section] = conversations_sections(tree)
      assert [header, body] = element_children(section)

      assert Floki.text(header) |> String.trim() == "Conversations"
      assert [_] = Floki.find(header, ".hero-chat-bubble-left-right")
      assert Floki.attribute(body, "id") == ["chat-session-list"]

      assert [row] = Floki.find(body, "a[id^='chat-session-']")
      assert Floki.attribute(row, "id") == ["chat-session-3"]
    end

    test "rows navigate to /assistant and keep the viewed node param off the Assistant page" do
      for {node_id, href} <- [
            {nil, "/assistant?session=3"},
            {"remote-test", "/assistant?session=3&node=remote-test"}
          ] do
        html =
          render_app(
            current_page: :dashboard,
            current_node_id: node_id,
            session_list: [%{id: 3, title: "three", marker: :ended}]
          )

        tree = parse(html)
        assert [link] = Floki.find(tree, "a#chat-session-3")

        assert Floki.attribute(link, "href") == [href]
        # `<.link navigate>` renders `data-phx-link="redirect"` — a NAVIGATE
        # destination, never a patch (a patch to another LiveView is illegal).
        assert Floki.attribute(link, "data-phx-link") == ["redirect"]
        refute "patch" in Floki.attribute(link, "data-phx-link")
        assert Floki.attribute(link, "aria-current") == []
      end
    end

    test "on the Assistant page the same rows PATCH and the current session is highlighted" do
      html =
        render_app(
          current_page: :assistant,
          current_session_id: 4,
          session_list: [
            %{id: 3, title: "three", marker: :awaiting_input},
            %{id: 4, title: "four", marker: :running}
          ]
        )

      tree = parse(html)

      [current] = Floki.find(tree, "a#chat-session-4")
      assert Floki.attribute(current, "data-phx-link") == ["patch"]
      assert Floki.attribute(current, "href") == ["/assistant?session=4"]
      assert Floki.attribute(current, "aria-current") == ["page"]
      assert_classes(current, ["bg-primary/10", "text-primary-standalone"])

      [other] = Floki.find(tree, "a#chat-session-3")
      assert Floki.attribute(other, "data-phx-link") == ["patch"]
      assert Floki.attribute(other, "href") == ["/assistant?session=3"]
      assert Floki.attribute(other, "aria-current") == []

      refute other |> Floki.attribute("class") |> Enum.join(" ") =~ "bg-primary/10"

      # Only the current session row is marked current (the Assistant nav link
      # carries its own `aria-current="page"`).
      assert [marked] = Floki.find(tree, "a[id^='chat-session-'][aria-current='page']")
      assert Floki.attribute(marked, "id") == ["chat-session-4"]
    end

    test "empty, loading and error states all render inside the same section" do
      empty = render_app(current_page: :dashboard)

      assert conversations_section_text(empty) =~ "No conversations yet."
      refute conversations_section_text(empty) =~ "Loading…"

      loading = render_app(current_page: :dashboard, session_list_loading: true)

      assert conversations_section_text(loading) =~ "Loading…"
      refute conversations_section_text(loading) =~ "No conversations yet."

      errored =
        render_app(
          current_page: :dashboard,
          session_list: [%{id: 3, title: "three", marker: :ended}],
          session_list_error: {:error, :remote_not_connected}
        )

      tree = parse(errored)
      assert [alert] = Floki.find(tree, "#chat-session-list [role='alert']")
      assert Floki.text(alert) =~ "Could not load conversations."
      refute conversations_section_text(errored) =~ "No conversations yet."

      # Rows already shown survive a failed load.
      assert [link] = Floki.find(tree, "a#chat-session-3")
      assert Floki.attribute(link, "href") == ["/assistant?session=3"]
    end

    test "renders even when Active Tasks has no running or pending rows" do
      html = render_app(current_page: :dashboard, running_tasks: [], pending_tasks: [])
      tree = parse(html)

      refute Floki.text(tree) =~ "Active Tasks"
      # … and the section is structurally absent, not merely unlabelled.
      assert Floki.find(tree, "#workbench-active-tasks") == []
      assert conversations_headers(tree) == ["Conversations"]

      assert [list] = Floki.find(tree, "#chat-session-list")
      assert Floki.attribute(list, "class") == ["space-y-1"]

      assert conversations_section_text(html) =~ "No conversations yet."
    end

    test "authoring comments never reach the client HTML" do
      html =
        render_app(
          current_page: :dashboard,
          session_list: [%{id: 3, title: "three", marker: :ended}]
        )

      # `<%!-- … --%>` comments are compile-time only; a plain `<!-- … -->`
      # would be emitted verbatim into every rendered page.
      refute html =~ "<!--"

      # The Conversations block still renders its content after the conversion.
      tree = parse(html)
      assert conversations_headers(tree) == ["Conversations"]
      assert [body] = Floki.find(tree, "#chat-session-list")
      assert [row] = Floki.find(body, "a[id^='chat-session-']")
      assert Floki.attribute(row, "id") == ["chat-session-3"]
    end
  end

  describe "app/1 — Active Tasks is a first-class sidebar section" do
    # Active Tasks is its OWN sidebar section, never a child of the Tools (or
    # Conversations) disclosure: a running task stays reachable from every
    # sidebar page. Asserted structurally (ancestor walk), because "the text
    # appears somewhere" would also pass for a nested Tools row.
    test "sits in the sidebar nav, outside the Tools, Conversations and utilities" do
      html =
        render_app(
          current_page: :dashboard,
          running_tasks: [
            task(
              id: "task-1",
              status: :running,
              project_path: "/home/user/my-project",
              objective: "Active task"
            )
          ],
          session_list: [%{id: 3, title: "three", marker: :ended}]
        )

      tree = parse(html)

      # Exactly ONE Active Tasks section, and it owns EVERY task row on the page.
      assert [section] = Floki.find(tree, "#workbench-active-tasks")
      assert [row] = Floki.find(section, "[data-sidebar-task-link]")
      assert sidebar_task_links(html) == 1
      assert Floki.attribute(row, "href") == ["/agents"]
      assert Floki.attribute(row, "title") |> hd() =~ "Active task"

      ancestors = ancestors_where(tree, &has_id?(&1, "workbench-active-tasks"))

      refute Enum.any?(ancestors, &tools_details?/1)
      refute Enum.any?(ancestors, &has_id?(&1, "workbench-conversations"))
      refute Enum.any?(ancestors, &has_class?(&1, "workbench-sidebar-utilities"))

      nav = Enum.find(ancestors, &sidebar_nav?/1)
      assert nav, "Active Tasks must be a descendant of `#sidebar nav`"
      assert [_aside] = Enum.filter(ancestors, &sidebar_aside?/1)

      # Sidebar order: Active Tasks → Assistant → recent projects → utilities.
      assert [active, assistant, projects, utilities] = element_children(nav)
      assert has_id?(active, "workbench-active-tasks")
      assert match?({"a", _, _}, assistant)
      assert has_id?(projects, "workbench-projects")
      assert has_class?(utilities, "workbench-sidebar-utilities")

      # Tools (Agents/Tasks/Processes/System) AND Conversations live inside the
      # utilities wrapper, i.e. BELOW the shortcuts.
      assert [tools, conversations] = element_children(utilities)
      assert tools_details?(tools)
      assert Floki.find(tools, "a[href='/tasks']") != []
      assert has_id?(conversations, "workbench-conversations")
      assert contains?(conversations, "#chat-session-list")

      # The brand still comes first, above the nav, inside the same aside.
      aside = Enum.find(ancestors, &sidebar_aside?/1)
      aside_children = element_children(aside)
      brand = Enum.find(aside_children, &contains?(&1, "img[src='/images/logo.svg']"))
      assert brand, "the sidebar brand must render"

      assert Enum.find_index(aside_children, &(&1 == brand)) <
               Enum.find_index(aside_children, &(&1 == nav))
    end
  end

  describe "app/1 — recent-project shortcuts" do
    # `#workbench-projects` is a LiveComponent mounted by the layout, so through
    # `render_component(&Layouts.app/1, ...)` it renders its DEAD render: the
    # registry read is a `start_async` that only runs on a connected socket, so
    # `result` is nil and only the FORCED current project row exists
    # (`ensure_current_project/4` runs inside `render/1`). The registry-fed list
    # itself is covered by the `WorkbenchComponent` describe below.
    test "the active project is a real shortcut row, even with no registry data" do
      path = "/home/user/my-project"

      html = render_app(current_page: :dashboard, workbench_project: path)
      tree = parse(html)

      assert [section] = Floki.find(tree, "#workbench-projects")
      assert_classes(section, ["workbench-projects", "sidebar-label"])
      assert Floki.attribute(section, "aria-label") == ["Recent projects"]
      assert Floki.attribute(section, "data-workbench-projects-loading") == ["false"]

      # Shortcuts are first-class: not nested in the utilities disclosures.
      ancestors = ancestors_where(tree, &has_id?(&1, "workbench-projects"))
      refute Enum.any?(ancestors, &tools_details?/1)
      refute Enum.any?(ancestors, &has_id?(&1, "workbench-conversations"))
      refute Enum.any?(ancestors, &has_class?(&1, "workbench-sidebar-utilities"))

      # Header actions, all inside the section.
      assert [recent] = Floki.find(section, "#workbench-recent-projects")
      assert [href] = Floki.attribute(recent, "href")
      assert href =~ "wb_open=1"
      assert [_] = Floki.find(section, "#workbench-open-directory")
      assert [_] = Floki.find(section, "#workbench-new-project")

      # The current project is FORCED into the list with no registry data.
      assert [row] = Floki.find(section, "[data-workbench-project-row]")
      assert [link] = Floki.find(row, "a.workbench-row.workbench-project-link")

      assert Floki.attribute(link, "data-workbench-project") == [path]
      assert Floki.attribute(link, "data-workbench-project-name") == ["my-project"]
      assert Floki.attribute(link, "data-workbench-node") == [""]
      assert Floki.attribute(link, "title") == [path]
      # `patch_links` on the dashboard page: the row is a PATCH destination.
      assert Floki.attribute(link, "data-phx-link") == ["patch"]
      assert_classes(link, ~w(workbench-row workbench-project-link is-current))
      assert Floki.attribute(link, "aria-current") == ["page"]
      assert Floki.text(link) =~ "my-project"

      # Name first, then the host label of the node the shortcut belongs to.
      assert [server] = Floki.find(link, ".workbench-project-server")
      assert Floki.text(server) == "Local"
      assert [_] = Floki.find(row, "[data-workbench-project-windows]")

      # A project row is a SHORTCUT: no task rows, no create actions …
      assert Floki.find(section, "[data-sidebar-task-link]") == []
      assert Floki.find(section, "[data-workbench-new-task]") == []
      assert Floki.find(section, "[data-workbench-new-conversation]") == []

      # … while the top bar still offers both, so the absence above is real.
      assert contains?(tree, "#workbench-create [data-workbench-new-task]")
      assert contains?(tree, "#workbench-create [data-workbench-new-conversation]")
    end
  end

  describe "WorkbenchComponent — recent-project list" do
    # The component's own `render/1` with the exact `result` assign its async
    # registry read produces (`%{host_id => [projects]}`) — a dead render can
    # never start that read, so handing the map in is the only way to cover the
    # real list (cap, recency, forced current row, current-marking rule).
    test "at most five shortcuts, newest first, unknown timestamps last" do
      base = ~U[2026-01-01 00:00:00Z]
      at = fn seconds -> DateTime.add(base, seconds, :second) end

      tree =
        render_workbench_projects(
          result: %{
            nil => [
              recent_mount("/p/a", at.(3)),
              recent_mount("/p/b", nil),
              recent_mount("/p/c", at.(1)),
              recent_mount("/p/d", at.(5)),
              recent_mount("/p/e", nil),
              recent_mount("/p/f", at.(2)),
              recent_mount("/p/g", at.(4))
            ]
          }
        )
        |> parse()

      assert length(Floki.find(tree, "[data-workbench-project-row]")) == 5
      assert project_row_paths(tree) == ["/p/d", "/p/g", "/p/a", "/p/f", "/p/c"]

      # An unknown timestamp sorts LAST, so it never displaces a recent project.
      refute contains?(tree, "[data-workbench-project='/p/b']")
      refute contains?(tree, "[data-workbench-project='/p/e']")

      # Nothing is active in this fixture.
      assert current_row_paths(tree) == []
      assert Floki.find(tree, ".is-current") == []
    end

    test "the active project is forced in, named by its basename" do
      base = ~U[2026-01-01 00:00:00Z]

      tree =
        render_workbench_projects(
          project: "/p/current",
          result: %{nil => [recent_mount("/p/a", base)]}
        )
        |> parse()

      assert project_row_paths(tree) == ["/p/current", "/p/a"]
      assert current_row_paths(tree) == ["/p/current"]

      [current, other] = project_links(tree)
      # No registry row for it, so the name falls back to `Path.basename/1`.
      assert Floki.attribute(current, "data-workbench-project-name") == ["current"]
      assert [server] = Floki.find(current, ".workbench-project-server")
      assert Floki.text(server) == "Local"

      assert Floki.attribute(current, "aria-current") == ["page"]
      assert Floki.attribute(other, "aria-current") == []
      refute has_class?(other, "is-current")
    end

    test "is-current needs BOTH the node and the path to match" do
      base = ~U[2026-01-01 00:00:00Z]
      result = %{nil => [recent_mount("/p/a", base)]}

      # Same path, same (local) host → current.
      local = render_workbench_projects(project: "/p/a", result: result) |> parse()
      assert project_row_paths(local) == ["/p/a"]
      assert current_row_paths(local) == ["/p/a"]

      # Same path, but the viewed node is a different one → NOT current, and
      # the registry row is not duplicated by the forced-current fallback.
      remote =
        render_workbench_projects(project: "/p/a", node_id: "remote-elsewhere", result: result)
        |> parse()

      assert project_row_paths(remote) == ["/p/a"]
      assert remote |> project_links() |> hd() |> Floki.attribute("data-workbench-node") == [""]
      assert current_row_paths(remote) == []
      assert Floki.find(remote, ".is-current") == []
    end
  end

  describe "app/1 — the per-project activity surface is gone" do
    test "project rows are shortcuts only, with no activity or task surface" do
      html =
        render_app(
          current_page: :dashboard,
          workbench_project: "/home/user/my-project",
          running_tasks: [
            task(
              id: "task-1",
              status: :running,
              project_path: "/home/user/my-project",
              objective: "Active task"
            )
          ],
          pending_tasks: [
            task(
              id: "task-2",
              status: :pending,
              project_path: "/home/user/my-project",
              objective: "Queued task"
            )
          ]
        )

      tree = parse(html)

      # NOT vacuous: a project IS active and the sidebar DOES render task rows.
      assert [section] = Floki.find(tree, "#workbench-projects")
      assert [row] = Floki.find(section, "[data-workbench-project-row]")
      assert has_class?(row, "workbench-project-entry")
      assert sidebar_task_links(html) == 2
      assert length(Floki.find(tree, "#workbench-active-tasks [data-sidebar-task-link]")) == 2

      # … yet no per-project activity surface exists anywhere on the page.
      assert Floki.find(tree, "[data-project-activity-id]") == []
      assert Floki.find(tree, "[data-project-activity-kind]") == []
      assert Floki.find(tree, ".workbench-project-activity") == []

      # And no nested task/conversation rows inside the shortcut list.
      assert Floki.find(section, "[data-sidebar-task-link]") == []
      assert Floki.find(section, "a[href^='/agents']") == []
      assert Floki.find(section, "a[href^='/review/']") == []
      assert Floki.find(section, "#chat-session-list") == []
    end
  end

  describe "app/1 — shell navigation" do
    test "settings opens a window on the local machine from either workbench node" do
      for node_id <- [nil, "remote-test"] do
        tree = render_app(current_node_id: node_id, current_page: :assistant) |> parse()

        assert [button] = Floki.find(tree, "[data-sidebar-bottom-bar] #workbench-settings")
        assert Floki.attribute(button, "data-workbench-settings") == ["/settings/window"]
        assert [_] = Floki.find(tree, "#workbench-settings-window iframe")
        assert Floki.find(tree, "#workbench-settings-window .workbench-window-location") == []
        assert [_] = Floki.find(tree, "#workbench-new-project")
        assert Floki.find(tree, "#node-selector") == []
        assistant = if node_id, do: "/assistant?node=" <> node_id, else: "/assistant"
        assert [_] = Floki.find(tree, "nav a[href='#{assistant}']")
        assert [_] = Floki.find(tree, "#workbench-recent-projects[href*='wb_open=1']")
      end
    end

    test "active and inactive sidebar links retain visible keyboard focus" do
      tree = render_app(current_page: :agents) |> parse()

      for path <- ~w(/agents /tasks /system) do
        assert [link] = Floki.find(tree, "nav a[href='#{path}']")

        assert_classes(
          link,
          ~w(focus-visible:outline-2 focus-visible:outline-offset-2 focus-visible:outline-primary-standalone)
        )

        assert Floki.attribute(link, "aria-current") ==
                 if(path == "/agents", do: ["page"], else: [])
      end
    end
  end

  describe "app/1 — configuration warning" do
    test "warning content is escaped and the configure link preserves node context" do
      warnings = ["No model configured", "Missing <credential> & provider"]

      for {node_id, href} <- [{nil, "/settings"}, {"remote-test", "/settings?node=remote-test"}] do
        tree =
          render_app(current_node_id: node_id, config_status: %{ok?: false, warnings: warnings})
          |> parse()

        assert [banner] = config_warning(tree)
        assert Floki.find(banner, "p") |> Floki.text() == "Missing Configuration"
        assert Floki.find(banner, "li") |> Enum.map(&Floki.text/1) == warnings
        assert Floki.find(banner, "credential") == []
        assert [link] = Floki.find(banner, "a")
        assert Floki.attribute(link, "href") == [href]
        assert Floki.text(link) == "Configure now →"
        assert [_] = Floki.find(banner, "button[aria-label='Close']")
      end
    end

    test "warning markup bounds narrow-screen width and lets long content wrap" do
      long_warning = String.duplicate("unbroken-credential-path", 30)

      tree =
        render_app(config_status: %{ok?: false, warnings: [long_warning]})
        |> parse()

      assert [banner] = config_warning(tree)
      # Render contracts only: actual viewport geometry belongs in browser tests.
      assert_classes(banner, ["w-[calc(100%-2rem)]", "max-w-sm"])

      assert [content] =
               banner
               |> Floki.find("div")
               |> Enum.filter(fn {_, _, children} ->
                 Enum.any?(children, &match?({"ul", _, _}, &1))
               end)

      assert_classes(content, ["flex-1", "min-w-0"])
      assert [warning] = Floki.find(content, "li")
      assert Floki.text(warning) == long_warning
      assert_classes(warning, ["break-words"])
    end

    test "unavailable or healthy configuration status renders no warning" do
      for status <- [nil, %{ok?: true, warnings: ["Should not be displayed"]}] do
        tree = render_app(config_status: status) |> parse()
        assert config_warning(tree) == []
        refute Floki.text(tree) =~ "Missing Configuration"
        refute Floki.text(tree) =~ "Should not be displayed"
      end
    end

    # A schema validation error ALONE makes the status `ok?: false` with no
    # warnings and nothing missing (the real-world "invalid timezone" report).
    # The banner must render the actual problem instead of an empty list plus
    # an unfounded accusation that the model is unconfigured.
    test "validation-error-only status renders the formatted error line and no model blame" do
      status = %{
        missing: [],
        warnings: [],
        ok?: false,
        validation_errors: [
          %EvoGit.Config.Schema.ValidationError{
            key_path: [:llm, :providers, 0, :timezone],
            message: ~s{invalid timezone: :no_time_zone_database (got "UTC")}
          }
        ]
      }

      for {node_id, href} <- [{nil, "/settings"}, {"remote-test", "/settings?node=remote-test"}] do
        tree = render_app(current_node_id: node_id, config_status: status) |> parse()

        assert [banner] = config_warning(tree)
        assert Floki.find(banner, "p") |> Floki.text() == "Missing Configuration"

        assert Floki.find(banner, "li") |> Enum.map(&Floki.text/1) == [
                 ~s{llm.providers.0.timezone: invalid timezone: :no_time_zone_database (got "UTC")}
               ]

        assert [link] = Floki.find(banner, "a")
        assert Floki.attribute(link, "href") == [href]
        assert Floki.text(link) == "Configure now →"

        # This banner is model-neutral: neither the settings page's
        # model-specific call to action nor any other model blame may appear.
        page_text = Floki.text(tree)

        refute page_text =~
                 "Configure your LLM model in the LLM category to resolve these issues."

        refute Floki.text(banner) =~ "LLM model"
      end
    end

    # Both kinds of problem in one status: warnings stay verbatim and first,
    # then one line per validation error in core order (the shared
    # `EvoDashWeb.ConfigIssues.lines/1` contract pinned through the banner).
    test "warnings and validation errors render in that order" do
      warnings = ["No API key found.", "Provider endpoint is unreachable."]

      status = %{
        ok?: false,
        missing: [],
        warnings: warnings,
        validation_errors: [
          %{key_path: [:llm, :providers, 0, :timezone], message: "invalid timezone"},
          %EvoGit.Config.Schema.ValidationError{
            key_path: [:scheduler, :max_turns],
            message: "must be a positive integer"
          }
        ]
      }

      tree = render_app(config_status: status) |> parse()

      assert [banner] = config_warning(tree)

      assert Floki.find(banner, "li") |> Enum.map(&Floki.text/1) ==
               warnings ++
                 [
                   "llm.providers.0.timezone: invalid timezone",
                   "scheduler.max_turns: must be a positive integer"
                 ]
    end

    test "healthy status with validation errors still renders no warning" do
      status = %{
        ok?: true,
        missing: [],
        warnings: [],
        validation_errors: [
          %EvoGit.Config.Schema.ValidationError{
            key_path: [:llm, :providers, 0, :timezone],
            message: "invalid timezone"
          }
        ]
      }

      tree = render_app(config_status: status) |> parse()
      assert config_warning(tree) == []
      refute Floki.text(tree) =~ "Missing Configuration"
      refute Floki.text(tree) =~ "llm.providers.0.timezone"
    end

    # A status that reports the model itself as missing renders normally, and
    # this banner still shows only the neutral "Configure now →" link — it
    # never carries a model-specific call to action, so it does not branch on
    # `missing` at all.
    test "missing llm_model status renders the banner without a model call to action" do
      warnings = ["No API key found."]
      status = %{ok?: false, missing: [:llm_model], warnings: warnings}

      tree = render_app(config_status: status) |> parse()
      assert [banner] = config_warning(tree)
      assert Floki.find(banner, "p") |> Floki.text() == "Missing Configuration"
      assert Floki.find(banner, "li") |> Enum.map(&Floki.text/1) == warnings

      assert [link] = Floki.find(banner, "a")
      assert Floki.attribute(link, "href") == ["/settings"]
      assert Floki.text(link) == "Configure now →"

      refute Floki.text(banner) =~ "LLM model"
    end
  end

  # --- helpers ---

  defp config_warning(tree), do: Floki.find(tree, "div.fixed:has(a[href^='/settings'])")

  defp assert_classes(node, expected) do
    classes = node |> Floki.attribute("class") |> Enum.join(" ") |> String.split()
    for class <- expected, do: assert(class in classes)
  end

  # Renders the full app layout shell. `flash` + `inner_block` are the only
  # assigns a bare render needs; every other attribute is optional with a
  # default (see the `attr` declarations at the top of layouts.ex).
  defp render_app(assigns) do
    render_component(
      &Layouts.app/1,
      Keyword.merge(
        [
          flash: %{},
          inner_block: [%{inner_block: fn _changed, _argument -> "Page content" end}]
        ],
        assigns
      )
    )
  end

  # Project group headers, in sidebar order. Group headers are the only
  # `span.sidebar-label` elements carrying a folder icon.
  defp sidebar_group_names(html) do
    html
    |> parse()
    |> Floki.find("span.sidebar-label:has(.hero-folder)")
    |> Enum.map(&Floki.text/1)
    |> Enum.map(&String.trim/1)
  end

  # Session group headers, in sidebar order. The "Sessions" header is the only
  # `span.sidebar-label` carrying the chat icon INSIDE the Active Tasks rows
  # container (`div.space-y-1`, where the Assistant nav link's icon is a
  # SIBLING of its label span, not a descendant). The layout-owned
  # "Conversations" header carries the same icon but sits OUTSIDE that
  # container — it is a sibling of its own `#chat-session-list` body — so the
  # `:not(#chat-session-list)` scope keeps this helper meaning exactly what it
  # meant before the conversations moved into the shared sidebar.
  defp sidebar_session_headers(html) do
    html
    |> parse()
    |> Floki.find(
      "div.space-y-1:not(#chat-session-list) span.sidebar-label:has(.hero-chat-bubble-left-right)"
    )
    |> Enum.map(&Floki.text/1)
    |> Enum.map(&String.trim/1)
  end

  defp sidebar_task_links(html) do
    html |> parse() |> Floki.find("[data-sidebar-task-link]") |> length()
  end

  # The layout-owned Conversations block: the one sidebar section carrying the
  # `#chat-session-list` body (its own `pt-5 mt-4` block, a sibling of the
  # Active Tasks block).
  defp conversations_sections(tree), do: Floki.find(tree, "#workbench-conversations")

  # The layout-owned "Conversations" header(s), in sidebar order.
  defp conversations_headers(tree) do
    tree
    |> Floki.find("#workbench-conversations > summary")
    |> Enum.map(&Floki.text/1)
    |> Enum.map(&String.trim/1)
  end

  defp conversations_section_text(html) do
    html |> parse() |> conversations_sections() |> Floki.text()
  end

  # Sidebar label texts (`span.sidebar-label`) in document order.
  defp sidebar_label_texts(tree) do
    tree
    |> Floki.find("span.sidebar-label")
    |> Enum.map(&(&1 |> Floki.text() |> String.trim()))
  end

  # Element children of a parsed Floki node (text nodes dropped).
  defp element_children({_tag, _attrs, children}), do: Enum.reject(children, &is_binary/1)

  # --- workbench chrome helpers ---

  # Renders the sidebar project-shortcut component itself with the assigns
  # `Layouts.app/1` passes it plus the `result` map its async registry read
  # produces (`%{host_id => [projects]}`). A dead render never starts that read,
  # so the registry has to be handed in to exercise the list.
  defp render_workbench_projects(assigns) do
    render_component(
      EvoDashWeb.WorkbenchComponent,
      Enum.into(assigns, %{id: "workbench-projects", mode: :projects})
    )
  end

  # A VCT project mount as the registry read returns it.
  defp recent_mount(path, last_opened_at) do
    name = Path.basename(path)

    %EvoGit.VCT.Mount{
      point: "vct:///projects/" <> name,
      path: path,
      name: name,
      last_opened_at: last_opened_at
    }
  end

  defp project_links(tree),
    do: Floki.find(tree, "[data-workbench-project-row] a.workbench-project-link")

  # The path of every rendered project shortcut, in DOM order.
  defp project_row_paths(tree) do
    tree
    |> project_links()
    |> Enum.flat_map(&Floki.attribute(&1, "data-workbench-project"))
  end

  # The paths of the rows marked current (`aria-current="page"`).
  defp current_row_paths(tree) do
    tree
    |> project_links()
    |> Enum.filter(&(Floki.attribute(&1, "aria-current") == ["page"]))
    |> Enum.flat_map(&Floki.attribute(&1, "data-workbench-project"))
  end

  # Ancestor chain (root first) of the FIRST node matching `fun`, found by an
  # explicit tree walk because Floki exposes no parent accessor. This is what
  # turns "not nested in Tools" into a structural claim instead of a text check.
  defp ancestors_where(tree, fun) do
    case walk_to_match(tree, fun, []) do
      {:ok, ancestors} -> ancestors
      :error -> flunk("no node matched the structural search")
    end
  end

  defp walk_to_match(nodes, fun, ancestors) when is_list(nodes) do
    Enum.reduce_while(nodes, :error, fn node, :error ->
      case walk_to_match(node, fun, ancestors) do
        {:ok, ancestors} -> {:halt, {:ok, ancestors}}
        :error -> {:cont, :error}
      end
    end)
  end

  defp walk_to_match(node, fun, ancestors) when is_tuple(node) do
    if fun.(node) do
      {:ok, ancestors}
    else
      walk_to_match(element_children(node), fun, ancestors ++ [node])
    end
  end

  defp walk_to_match(_text_node, _fun, _ancestors), do: :error

  defp has_id?(node, id), do: Floki.attribute(node, "id") == [id]

  defp has_class?(node, class) do
    node
    |> Floki.attribute("class")
    |> Enum.join(" ")
    |> String.split()
    |> Enum.member?(class)
  end

  defp contains?(tree, selector), do: Floki.find(tree, selector) != []

  defp sidebar_nav?(node) do
    match?({"nav", _, _}, node) and has_class?(node, "workbench-sidebar-nav")
  end

  defp sidebar_aside?(node), do: match?({"aside", _, _}, node) and has_id?(node, "sidebar")

  # The Tools `<details>`: the `.workbench-tools` disclosure that owns the
  # Agents/Tasks/Processes/System links. The Conversations disclosure carries
  # the same class, so it is identified by its own id and by having no links.
  defp tools_details?(node) do
    match?({"details", _, _}, node) and has_class?(node, "workbench-tools") and
      contains?(node, "a[href^='/agents']")
  end

  # Task labels in sidebar order (the truncated label span inside each link).
  defp sidebar_task_labels(html) do
    html
    |> parse()
    |> Floki.find("[data-sidebar-task-link]")
    |> Enum.map(fn link ->
      link |> Floki.find("span.truncate") |> Floki.text() |> String.trim()
    end)
  end

  # A task summary entry as the Active Tasks hub hands it to the sidebar. The
  # `:session_mode` key is only added when a test supplies it, so the "missing
  # key = one-shot" defensive default stays exercised.
  defp task(attrs) do
    entry = %{
      id: Keyword.fetch!(attrs, :id),
      status: Keyword.fetch!(attrs, :status),
      project_path: Keyword.get(attrs, :project_path),
      started_at: DateTime.utc_now(),
      finished_at: nil,
      opts: [objective: Keyword.fetch!(attrs, :objective)]
    }

    case Keyword.fetch(attrs, :session_mode) do
      {:ok, session_mode} -> Map.put(entry, :session_mode, session_mode)
      :error -> entry
    end
  end

  # An interactive agent session (the summary `session_mode` string).
  defp session_task(attrs) do
    task(Keyword.put(attrs, :session_mode, "interactive"))
  end

  # The `ListEnter` wrapper: the Active Tasks rows container, never the
  # Conversations body (which is also a `div.space-y-1`).
  defp active_tasks_rows_wrapper(tree) do
    case Floki.find(tree, "#workbench-active-tasks div.space-y-1[phx-hook='ListEnter']") do
      [wrapper] -> wrapper
      other -> flunk("expected ONE ListEnter wrapper, got: #{inspect(length(other))}")
    end
  end

  # The `data-list-enter-key` of every Active Tasks row, in sidebar order.
  defp row_keys(html) do
    html
    |> parse()
    |> Floki.find("#workbench-active-tasks [data-sidebar-task-link]")
    |> Enum.map(fn link ->
      assert [key] = Floki.attribute(link, "data-list-enter-key")
      key
    end)
  end

  # A minimal project task for the key-stability tests: one id, any status (and
  # optionally the interactive session marker for the running →
  # `:awaiting_input` transition).
  defp task_entry(id, status, session? \\ false) do
    attrs = [id: id, status: status, project_path: "/home/user/proj", objective: "Objective"]
    if session?, do: session_task(attrs), else: task(attrs)
  end

  # Floki's find/2 + attribute/2 require a parsed tree, not a raw binary.
  defp parse(html), do: Floki.parse_document!(html)
end
