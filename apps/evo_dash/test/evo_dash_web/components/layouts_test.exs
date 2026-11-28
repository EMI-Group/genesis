Code.require_file("layouts_test_helper.exs", __DIR__)

defmodule EvoDashWeb.LayoutsTest do
  @moduledoc "Render contracts for the workbench shell and its controls."

  use ExUnit.Case, async: true

  import Phoenix.LiveViewTest

  import EvoDashWeb.LayoutsTest.Helpers

  describe "app/1 — Active Tasks is a first-class sidebar section" do
    # Active Tasks is its OWN sidebar section, never a child of a disclosure: a
    # running task stays reachable from every sidebar page. Asserted
    # structurally (ancestor walk), because "the text appears somewhere" would
    # also pass for a row nested inside the Conversations disclosure.
    test "sits in the sidebar nav, outside every disclosure and the utilities" do
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
      # A live task opens the run that focuses it on the tasks page.
      assert Floki.attribute(row, "href") == ["/agents?task=task-1"]
      assert Floki.attribute(row, "title") |> hd() =~ "Active task"

      ancestors = ancestors_where(tree, &has_id?(&1, "workbench-active-tasks"))

      refute Enum.any?(ancestors, &match?({"details", _, _}, &1))
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

      # The four destinations are ALWAYS-VISIBLE direct links inside the
      # utilities wrapper — no disclosure, no summary, no caret, no open state —
      # followed by the Conversations disclosure as the wrapper's last child.
      assert [agents, tasks, processes, system, conversations] = element_children(utilities)
      assert [agents, tasks, processes, system] |> Enum.all?(&match?({"a", _, _}, &1))
      assert Floki.attribute(agents, "href") == ["/agents"]
      assert Floki.attribute(tasks, "href") == ["/tasks"]
      assert Floki.attribute(processes, "href") == ["/processes"]
      assert Floki.attribute(system, "href") == ["/system"]
      assert Floki.attribute(processes, "data-nav") == ["processes"]
      assert contains?(processes, ".hero-cpu-chip")

      # The icons stay visible in the collapsed rail while the labels hide:
      # every direct link carries BOTH an icon and a `.sidebar-label` span.
      for link <- [agents, tasks, processes, system] do
        assert [icon] = Floki.find(link, "span[class^='hero-']")
        assert contains?(link, "span.sidebar-label")
        assert Floki.attribute(icon, "class") != []
      end

      # The old Tools disclosure is GONE — no element carries that id.
      assert Floki.find(tree, "#workbench-tools") == []

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

    test "the System direct link keeps its update notification dot" do
      html = render_app(current_page: :dashboard, update_status: %{phase: :available})
      tree = parse(html)

      assert [system] = Floki.find(tree, ".workbench-sidebar-utilities > a[href='/system']")
      assert [_dot] = Floki.find(system, "span.bg-warning")
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

      # Shortcuts are first-class: not nested in a disclosure or the utilities.
      ancestors = ancestors_where(tree, &has_id?(&1, "workbench-projects"))
      refute Enum.any?(ancestors, &match?({"details", _, _}, &1))
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
      # A project row carries NO open-view container: the tab rail is the ONE
      # open-view list, so the sidebar never grows a per-project window list.
      assert Floki.find(row, "[data-workbench-project-windows]") == []

      # A project row is a SHORTCUT: no task rows, no create actions …
      assert Floki.find(section, "[data-sidebar-task-link]") == []
      assert Floki.find(section, "[data-workbench-new-task]") == []
      assert Floki.find(section, "[data-workbench-new-conversation]") == []

      # … while the connected project gets both entry points in the top bar.
      assert [task_link] = Floki.find(tree, "#workbench-create a[data-workbench-new-task]")
      assert [href] = Floki.attribute(task_link, "href")
      assert %URI{path: "/projects", query: query} = URI.parse(href)
      assert URI.decode_query(query) == %{"project" => path, "wb_task" => "1"}
      assert Floki.attribute(task_link, "data-phx-link") == ["redirect"]

      assert [_] =
               Floki.find(
                 tree,
                 "#workbench-create button[type=button][data-workbench-new-conversation]"
               )

      assert Floki.find(tree, "#workbench-create [data-workbench-project-window]") == []
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

  describe "app/1 — workbench tab rail" do
    # The contextual heading sits beside the ONE open-view list. The server
    # renders that list empty and the Workbench hook owns its contents.
    test "the unscoped Agents heading precedes the tab list, create menu and hidden overflow" do
      tree = render_app(current_page: :agents) |> parse()

      assert [rail] = Floki.find(tree, ".workbench-tab-rail")
      heading = assert_context_title(tree, "Agents")
      assert [tabs] = Floki.find(rail, "#workbench-tabs")
      assert [create] = Floki.find(rail, "#workbench-create")

      assert Floki.attribute(tabs, "role") == ["navigation"]
      assert Floki.attribute(tabs, "phx-update") == ["ignore"]

      assert Floki.attribute(tabs, "aria-label") ==
               ["Open tabs — Alt+Left / Alt+Right cycles tabs"]

      assert element_children(tabs) == []

      # Exactly ONE overflow shell: a rail-end `<details>`, hidden until the
      # hook finds the rail overflowing and IGNORED by LiveView so the hook
      # owns both its children and the native `open` state.
      assert [overflow] = Floki.find(rail, "#workbench-tabs-overflow")
      assert has_class?(overflow, "workbench-tab-overflow")
      assert Floki.attribute(overflow, "hidden") == ["hidden"]
      assert Floki.attribute(overflow, "phx-update") == ["ignore"]

      assert [summary] = Floki.find(overflow, "summary.workbench-icon-button")
      assert Floki.attribute(summary, "aria-label") == ["All open tabs"]
      assert contains?(summary, "span.hero-ellipsis-horizontal")

      # The panel is the hook-populated list on the create menu's surface, and
      # it is EMPTY on a server render.
      assert [list] = Floki.find(overflow, "#workbench-tabs-overflow-list")
      assert_classes(list, ["workbench-create-menu"])
      assert element_children(list) == []

      assert element_children(rail) == [heading, tabs, create, overflow]
    end

    test "a scoped project uses its display name and falls back to the path basename" do
      for {name, expected} <- [
            {"Project display name", "Project display name"},
            {nil, "repo"},
            {"  ", "repo"}
          ] do
        render_app(
          current_page: :dashboard,
          workbench_project: "/repos/repo",
          workbench_context_name: name
        )
        |> parse()
        |> assert_context_title(expected)
      end
    end

    test "a supplied workspace name takes precedence over its execution member path" do
      render_app(
        current_page: :dashboard,
        workbench_project: "/repos/execution-member",
        workbench_context_name: "Workspace display name"
      )
      |> parse()
      |> assert_context_title("Workspace display name")
    end

    test "a pending remote target cannot supply a scope heading" do
      render_app(
        current_page: :dashboard,
        current_node_id: "pending-node",
        connection_statuses: %{"pending-node" => %{phase: :connecting}},
        workbench_project: "/repos/pending",
        workbench_context_name: "Unconfirmed project"
      )
      |> parse()
      |> assert_context_title("Projects")
    end

    test "Agents ignores a project name when there is no focused task" do
      render_app(
        current_page: :agents,
        workbench_project: "/repos/repo",
        workbench_context_name: "Unfocused project"
      )
      |> parse()
      |> assert_context_title("Agents")
    end

    test "the create menu offers project actions without an executable scope" do
      for assigns <- [[], [workbench_project: "/repos/pending", current_node_id: "pending-node"]] do
        tree = render_app(assigns) |> parse()
        assert [menu] = Floki.find(tree, "details#workbench-create")
        assert [_] = Floki.find(menu, "summary#workbench-create-toggle[aria-label=Create]")

        assert Floki.attribute(menu, "button[type=button]", "data-workbench-project-window") ==
                 ["create", "open"]

        assert Floki.find(menu, "[data-workbench-new-task], [data-workbench-new-conversation]") ==
                 []
      end
    end

    test "the shell ships the labels consumed by the client-owned rail" do
      tree = render_app(current_page: :dashboard) |> parse()

      assert [layout] = Floki.find(tree, "#app-layout[phx-hook=Workbench]")

      assert Floki.attribute(layout, "data-workbench-close") == ["Close tab"]
      assert Floki.attribute(layout, "data-workbench-keep-open") == ["Keep this tab open"]
      assert Floki.attribute(layout, "data-workbench-next-tab") == ["Next tab (Alt+Right)"]
      assert Floki.attribute(layout, "data-workbench-prev-tab") == ["Previous tab (Alt+Left)"]
    end
  end

  describe "app/1 — Source Control wiring" do
    test "the Git panel starts closed and its portal host is a sibling of the main scroll region" do
      path = "/repos/active"

      tree =
        render_app(
          workbench_project: path,
          workbench_git_project: path,
          github_status: %{state: :ok, owner: "acme", repo: "active"}
        )
        |> parse()

      assert [_] =
               Floki.find(
                 tree,
                 "#workbench-git-toggle[aria-controls=workbench-git][aria-expanded=false]"
               )

      assert [_] = Floki.find(tree, "#workbench-git-toggle-label[phx-update=ignore]")
      assert [pane] = Floki.find(tree, "aside#workbench-git[hidden][data-panel-state=closed]")
      assert [content] = Floki.find(pane, "#workbench-git-content[phx-hook=WorkbenchSection]")
      assert Floki.attribute(content, "data-workbench-git-target") == [Atom.to_string(node())]
      assert Floki.attribute(content, "h2", "title") == [path]
      assert [_] = Floki.find(content, ".workbench-git-github [phx-click=open_github_issues]")

      assert [_] =
               Floki.find(
                 tree,
                 ".workbench-content-stack > #main-scroll + #workbench-git-diff-host"
               )
    end

    test "a fresh shell with no project offers neither a Git toggle nor a portal host" do
      tree = render_app([]) |> parse()
      assert [_] = Floki.find(tree, "header.workbench-top")

      assert Floki.find(tree, "#workbench-git, #workbench-git-toggle, #workbench-git-diff-host") ==
               []
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

  describe "app/1 — desktop custom title bar" do
    # The browser shell must stay byte-identical: the dashboard renders its own
    # strip ONLY when the Tauri shell seeded `desktop?: true` (there is no
    # window frame to drag, no window controls to draw and no `data-desktop`
    # marker for the CSS/hooks to key off).
    test "the default (browser) render ships no title bar at all" do
      tree = render_app(current_page: :dashboard) |> parse()

      assert [layout] = Floki.find(tree, "#app-layout")
      assert Floki.attribute(layout, "data-desktop") == []

      assert Floki.find(tree, "#desktop-titlebar") == []
      assert Floki.find(tree, "[data-tauri-drag-region]") == []
      assert Floki.find(tree, "[id^='desktop-titlebar']") == []
    end

    # Desktop mode turns `#app-layout` into a column: the strip is layer 0 and
    # EVERYTHING else moves into `#shell-row` as one flex row.
    test "desktop mode makes the strip the FIRST row of the column shell" do
      tree = render_app(desktop?: true, os: :windows) |> parse()

      assert [layout] = Floki.find(tree, "#app-layout")
      assert Floki.attribute(layout, "data-desktop") == ["true"]
      assert_classes(layout, ~w(flex h-dvh overflow-hidden flex-col))

      assert [strip, shell_row | _rest] = element_children(layout)
      assert has_id?(strip, "desktop-titlebar")

      assert Floki.attribute(strip, "phx-hook") == ["DesktopTitlebar"]
      assert Floki.attribute(strip, "data-os") == ["windows"]
      assert Floki.attribute(strip, "role") == ["group"]
      assert [label] = Floki.attribute(strip, "aria-label")
      assert String.trim(label) != ""

      # The strip's NEXT element sibling is the shell row. The sidebar, its
      # resize handle and the main area are now siblings INSIDE it, which is
      # what keeps `#sidebar + #workbench-left-resize` and
      # `#sidebar ~ .workbench-main` resolving in workbench.css.
      assert has_id?(shell_row, "shell-row")
      assert_classes(shell_row, ~w(flex flex-1 min-h-0 min-w-0))

      assert [_sidebar] = Floki.find(shell_row, "#sidebar")
      assert [_resize] = Floki.find(shell_row, "#workbench-left-resize")
      assert [_main] = Floki.find(shell_row, ".workbench-main")

      # … and none of them is a DIRECT child of `#app-layout` any more.
      refute Enum.any?(element_children(layout), &has_id?(&1, "sidebar"))
      refute Enum.any?(element_children(layout), &has_class?(&1, "workbench-main"))
    end

    # Every OS except macOS is a windowed host WITH usable chrome: `:unknown` is
    # treated as windowed too, so a host we cannot identify never ends up with a
    # control-less (unclosable) strip.
    test "Windows, Linux and an unknown OS render exactly the minimize/maximize/close controls" do
      for os <- [:windows, :linux, :unknown] do
        tree = render_app(desktop?: true, os: os) |> parse()
        strip = titlebar(tree)

        assert [controls] = Floki.find(strip, ".desktop-titlebar-controls")
        assert [minimize, maximize, close] = element_children(controls)

        assert [
                 {minimize, "desktop-titlebar-minimize"},
                 {maximize, "desktop-titlebar-maximize"},
                 {close, "desktop-titlebar-close"}
               ]
               |> Enum.each(fn {button, id} ->
                 assert has_id?(button, id)
                 assert Floki.attribute(button, "type") == ["button"]

                 assert [label] = Floki.attribute(button, "aria-label")
                 assert String.trim(label) != ""
               end)

        # The maximize button ships BOTH glyphs; the hook toggles the `hidden`
        # CLASS because an SVG element ignores the `hidden` attribute.
        assert Floki.attribute(maximize, "data-maximized") == ["false"]

        assert [glyph_max] = Floki.find(maximize, ".desktop-titlebar-glyph-maximize")
        assert [glyph_restore] = Floki.find(maximize, ".desktop-titlebar-glyph-restore")
        refute has_class?(glyph_max, "hidden")
        assert has_class?(glyph_restore, "hidden")

        assert has_class?(close, "desktop-titlebar-control")
        assert has_class?(close, "desktop-titlebar-control-close")
        assert Floki.attribute(strip, "data-os") == [to_string(os)]
      end
    end

    # macOS draws native traffic lights OVER the strip (which reserves that
    # space in CSS), so it is the ONLY OS that renders no window controls.
    test "macOS renders no window controls" do
      strip = render_app(desktop?: true, os: :macos) |> parse() |> titlebar()

      # The strip itself still renders — only the controls are absent.
      assert Floki.find(strip, ".desktop-titlebar-controls") == []

      for id <- ~w(desktop-titlebar-minimize desktop-titlebar-maximize desktop-titlebar-close) do
        assert Floki.find(strip, "[id='#{id}']") == []
      end
    end

    # THE regression pin: an unidentified host OS used to render a strip with no
    # controls at all — a chrome-less desktop window that could not be closed.
    # An unknown OS must stay windowed, with the full closable control set.
    test "an unknown host OS still renders a complete, closable title bar" do
      strip = render_app(desktop?: true, os: :unknown) |> parse() |> titlebar()

      assert Floki.attribute(strip, "data-os") == ["unknown"]

      assert [_controls] = Floki.find(strip, ".desktop-titlebar-controls")

      for id <- ~w(desktop-titlebar-minimize desktop-titlebar-maximize desktop-titlebar-close) do
        assert [_button] = Floki.find(strip, "[id='#{id}']")
      end

      assert [close] = Floki.find(strip, "#desktop-titlebar-close")
      assert has_class?(close, "desktop-titlebar-control-close")
    end

    # The `DesktopTitlebar` JS hook owns pointer dragging, and Tauri injects its
    # OWN document-level drag handler whenever a `data-tauri-drag-region`
    # attribute is present — which would double-fire against the hook. So the
    # attribute must never come back: exactly ONE drag path (the hook), with the
    # `.desktop-titlebar-drag` spacer kept only as a flex spacer.
    test "no element advertises a Tauri drag region — the hook owns the one drag path" do
      for os <- [:macos, :windows, :linux, :unknown] do
        tree = render_app(desktop?: true, os: os) |> parse()
        strip = titlebar(tree)

        assert Floki.find(strip, "[data-tauri-drag-region]") == []
        assert Floki.find(tree, "[data-tauri-drag-region]") == []

        assert [drag] = Floki.find(strip, ".desktop-titlebar-drag")
        assert Floki.attribute(drag, "data-tauri-drag-region") == []
        assert Floki.attribute(drag, "aria-hidden") == ["true"]

        assert [brand] = Floki.find(strip, "a")
        assert Floki.attribute(brand, "data-tauri-drag-region") == []
        assert Floki.find(strip, "a[data-tauri-drag-region]") == []
        assert Floki.find(strip, "button[data-tauri-drag-region]") == []
      end
    end

    test "the strip carries the shared brand link and the sidebar keeps only its drawer close" do
      tree = render_app(desktop?: true, os: :windows) |> parse()
      strip = titlebar(tree)

      assert [brand] = Floki.find(strip, "a.desktop-titlebar-brand")
      assert Floki.attribute(brand, "href") == ["/"]
      assert [_logo] = Floki.find(brand, "img[src='/images/logo.svg']")
      assert [_logo_alt] = Floki.find(brand, "img[src='/images/logo-alt.svg']")
      assert Floki.attribute(brand, "img", "alt") == ["EvoX Genesis", "EvoX Genesis"]
      assert Floki.text(brand) =~ "EvoX Genesis"

      # The wordmark moved into the strip, so the sidebar brand row is gone …
      [sidebar] = Floki.find(tree, "#sidebar")
      assert Floki.find(sidebar, "img[src='/images/logo.svg']") == []
      refute Floki.text(sidebar) =~ "EvoX Genesis"

      # … but the drawer close stays INSIDE `#sidebar`, inside a `lg:hidden`
      # header, because the SidebarCollapse hook focuses it by id.
      assert [_close] = Floki.find(sidebar, "button#sidebar-mobile-close")

      ancestors = ancestors_where(tree, &has_id?(&1, "sidebar-mobile-close"))
      assert Enum.any?(ancestors, &has_class?(&1, "lg:hidden"))
    end

    test "in the browser render the sidebar keeps its brand row and drawer close" do
      tree = render_app(current_page: :dashboard) |> parse()
      [sidebar] = Floki.find(tree, "#sidebar")

      assert [_logo] = Floki.find(sidebar, "img[src='/images/logo.svg']")
      assert Floki.text(sidebar) =~ "EvoX Genesis"
      assert [_close] = Floki.find(sidebar, "button#sidebar-mobile-close")
    end
  end

  # --- helpers ---

  # The ONE desktop title bar strip of a parsed tree.
  defp titlebar(tree) do
    assert [strip] = Floki.find(tree, "#desktop-titlebar")
    strip
  end

  defp config_warning(tree), do: Floki.find(tree, "div.fixed:has(a[href^='/settings'])")

  # --- workbench chrome helpers ---

  defp assert_context_title(tree, expected) do
    assert [heading] = Floki.find(tree, ".workbench-tab-rail .workbench-context-title")
    assert String.trim(Floki.text(heading)) == expected
    assert Floki.attribute(heading, "title") == [expected]
    heading
  end

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

  defp contains?(tree, selector), do: Floki.find(tree, selector) != []

  defp sidebar_nav?(node) do
    match?({"nav", _, _}, node) and has_class?(node, "workbench-sidebar-nav")
  end

  defp sidebar_aside?(node), do: match?({"aside", _, _}, node) and has_id?(node, "sidebar")
end
