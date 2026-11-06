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

  describe "app/1 — shell navigation" do
    test "Assistant is a chat link and preserves the selected remote node" do
      for {node_id, href} <- [{nil, "/help"}, {"remote-test", "/help?node=remote-test"}] do
        tree = render_app(current_node_id: node_id, current_page: :help) |> parse()
        assert [assistant_link] = Floki.find(tree, "nav a[href='#{href}']")
        assert Floki.text(assistant_link) |> String.trim() == "Assistant"
        assert [_] = Floki.find(assistant_link, ".hero-chat-bubble-left-right")
        assert Floki.attribute(assistant_link, "data-phx-link") == ["redirect"]
        assert Floki.attribute(assistant_link, "aria-current") == ["page"]
      end
    end

    test "active and inactive sidebar links retain visible keyboard focus" do
      tree = render_app(current_page: :help) |> parse()
      paths = ~w(/projects /agents /tasks /settings /system /help)

      for path <- paths do
        assert [link] = Floki.find(tree, "nav a[href='#{path}']")

        assert_classes(
          link,
          ~w(focus-visible:outline-2 focus-visible:outline-offset-2 focus-visible:outline-primary-standalone)
        )

        if path == "/help" do
          assert Floki.attribute(link, "aria-current") == ["page"]
        else
          refute Floki.attribute(link, "aria-current") == ["page"]
        end
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

  defp sidebar_task_links(html) do
    html |> parse() |> Floki.find("[data-sidebar-task-link]") |> length()
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

  defp task(attrs) do
    %{
      id: Keyword.fetch!(attrs, :id),
      status: Keyword.fetch!(attrs, :status),
      project_path: Keyword.get(attrs, :project_path),
      started_at: DateTime.utc_now(),
      finished_at: nil,
      opts: [objective: Keyword.fetch!(attrs, :objective)]
    }
  end

  # Floki's find/2 + attribute/2 require a parsed tree, not a raw binary.
  defp parse(html), do: Floki.parse_document!(html)
end
