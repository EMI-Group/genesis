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

  # Floki's find/2 + attribute/2 require a parsed tree, not a raw binary.
  defp parse(html), do: Floki.parse_document!(html)
end
