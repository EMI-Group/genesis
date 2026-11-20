defmodule EvoDashWeb.ProjectsLive.WorkspacesTest do
  @moduledoc """
  LiveView coverage for the VCT WORKSPACE surface of the Projects page: the
  palette's "Workspaces" section and the New Workspace form
  (`EvoDashWeb.ProjectComponents.palette_menu/1` + `palette_new_workspace/1`),
  the `workspaces` / `expanded_workspaces` / `new_workspace_members` assigns and
  the `toggle_workspace`, `toggle_workspace_member` and `create_workspace`
  events in `EvoDashWeb.ProjectsLive`, and the ASYNC
  `EvoDashWeb.ProjectsLive.AsyncLoad.load_workspaces/3` resolution.

  A workspace is a pure GROUPING point (`path: nil`): it lists its members,
  marks unresolvable refs as missing, and is never activatable as a project.

  `async: true` — nothing here mutates a BEAM-global another concurrently
  running module asserts on. The VCT mount table IS run-wide shared, so every
  project/workspace this file seeds carries a `System.unique_integer/1`
  basename/name plus an `on_exit` `EvoGit.VCT.forget/1`, and every assertion is
  scoped to THIS test's own unique points (row markup is extracted between row
  boundaries instead of being refuted page-wide).
  """

  use EvoDashWeb.ConnCase, async: true

  import Phoenix.LiveViewTest

  alias EvoGit.VCT

  # Load-tolerant budget for the page's ASYNC work (the workspace views ride the
  # same supervised task as the project batch). Bounded, so real breakage fails
  # loudly instead of hanging.
  @wait_budget_ms 30_000
  # `:sys.get_state/2` timeout for `assigns/1`: the LiveView can be starved for
  # seconds on a loaded host.
  @assigns_timeout_ms 30_000

  setup %{conn: conn} do
    # `ProjectsLive` redirects a first-time user to /welcome
    # (`EvoGit.Config.VersionState.onboarding_needed?/0` is true without a
    # version-state file), so isolate the config dir per test through the
    # process-local `:config_dir_fun` seam and mark onboarding complete — the
    # same isolation `EvoDashWeb.ProjectsLiveTest.Helpers.set_onboarding_completed/1`
    # applies. The mounted view and its supervised load tasks inherit the
    # override through `$callers`, and the path-keyed config caches stay
    # cache-safe because the directory is unique per test.
    dir = EvoDash.Test.ConfigDir.isolate!("evogit_workspaces_test_config")
    EvoGit.Config.VersionState.complete_onboarding()

    on_exit(fn -> File.rm_rf!(dir) end)

    tmp_dir =
      Path.join(System.tmp_dir!(), "evogit_workspaces_#{System.unique_integer([:positive])}")

    File.mkdir_p!(tmp_dir)

    on_exit(fn ->
      # Teardown-only rescue: a cleanup failure must never mask a test failure.
      forget_quietly(tmp_dir)
      File.rm_rf!(tmp_dir)
    end)

    {:ok, conn: Plug.Test.init_test_session(conn, %{}), tmp_dir: tmp_dir}
  end

  describe "workspace surface in the project palette" do
    test "the palette lists a workspace and expanding it reveals its resolved members", %{
      conn: conn,
      tmp_dir: tmp_dir
    } do
      alpha = seed_project!(tmp_dir, unique("alpha"))
      beta = seed_project!(tmp_dir, unique("beta"))
      name = unique("ws-inspect")
      description = "Grouping used by #{name}"

      workspace = seed_workspace!(name, [member_ref(alpha), member_ref(beta)], description)

      {:ok, view, _html} = live(conn, ~p"/projects")
      wait_for_workspaces(view, [workspace.point])

      html = render_click(view, "open_project_palette", %{})

      # The section header renders once workspaces exist, and the row carries
      # the name, the point and the description.
      assert html =~ "Workspaces"
      assert html =~ "A workspace groups projects"

      row = workspace_row(html, workspace.point)

      # The DOM hook (slug derived from the point: my name is alnum + dashes).
      assert html =~ ~s(id="workspace-row-#{name}")
      assert row =~ name
      assert row =~ workspace.point
      assert row =~ description
      assert row =~ "2 members"
      assert row =~ ~s(aria-expanded="false")

      # Collapsed: no member rows for THIS workspace (a fresh mount expands
      # nothing, so nothing else in the palette renders one either).
      refute row =~ "data-workspace-member"

      expanded = render_click(view, "toggle_workspace", %{"point" => workspace.point})
      row = workspace_row(expanded, workspace.point)

      assert row =~ ~s(aria-expanded="true")
      assert row =~ ~s(data-workspace-member="#{alpha.point}")
      assert row =~ ~s(data-workspace-member="#{beta.point}")
      # Resolved members render their display names, not just the refs.
      assert row =~ alpha.name
      assert row =~ beta.name
      refute row =~ "data-workspace-missing"
      refute row =~ "Missing"
    end

    test "a member ref that names no project renders as missing, its sibling stays resolved", %{
      conn: conn,
      tmp_dir: tmp_dir
    } do
      alpha = seed_project!(tmp_dir, unique("present"))
      gone_point = "vct:///projects/#{unique("gone")}"
      gone_ref = %{"point" => gone_point, "path" => Path.join(tmp_dir, "gone")}

      name = unique("ws-partial")
      workspace = seed_workspace!(name, [member_ref(alpha), gone_ref], "one member is gone")

      {:ok, view, _html} = live(conn, ~p"/projects")
      wait_for_workspaces(view, [workspace.point])

      render_click(view, "open_project_palette", %{})
      html = render_click(view, "toggle_workspace", %{"point" => workspace.point})
      row = workspace_row(html, workspace.point)

      # The dangling ref is surfaced as a visible warning marker...
      assert row =~ ~s(data-workspace-missing="#{gone_point}")
      assert row =~ "badge badge-warning"
      assert row =~ "Missing"

      # ...while the resolvable member still renders as a resolved project.
      assert row =~ ~s(data-workspace-member="#{alpha.point}")
      assert row =~ alpha.name
      assert row =~ "2 members"
    end

    test "creating a workspace from the form saves the ordered members and returns to the menu",
         %{conn: conn, tmp_dir: tmp_dir} do
      alpha = seed_project!(tmp_dir, unique("alpha"))
      beta = seed_project!(tmp_dir, unique("beta"))
      name = unique("ws-create")
      description = "Created from the form by #{name}"

      {:ok, view, _html} = live(conn, ~p"/projects")
      wait_for_projects(view, [alpha.path, beta.path])
      wait_for_workspaces(view, [])

      render_click(view, "open_project_palette", %{})
      html = render_click(view, "palette_mode", %{"mode" => "new_workspace"})

      assert html =~ ~s(id="new-workspace-form")
      assert html =~ ~s(id="new-workspace-name-input")
      assert html =~ ~s(id="new-workspace-description-input")
      assert html =~ "Create or update"

      # Both seeded projects are offered as pickable members.
      assert html =~ ~s(data-workspace-pick="#{alpha.point}")
      assert html =~ ~s(data-workspace-pick="#{beta.point}")

      # Pick BETA first, then ALPHA: the chips (and the stored members) must
      # keep the CLICK order, not the project-list order.
      html = render_click(view, "toggle_workspace_member", %{"point" => beta.point})
      # HEEx renders a TRUE boolean `data-selected` as an empty-value attribute
      # and omits it entirely when false, so presence/absence is the signal.
      assert pick_row(html, beta.point) =~ "data-selected"
      refute pick_row(html, alpha.point) =~ "data-selected"

      html = render_click(view, "toggle_workspace_member", %{"point" => alpha.point})

      assert selected_chips(html) == [beta.point, alpha.point]
      # Position numbers are rendered on the chips (1. / 2.).
      assert html =~ ">1.</span>"
      assert html =~ ">2.</span>"
      assert pick_row(html, beta.point) =~ "data-selected"
      assert pick_row(html, alpha.point) =~ "data-selected"

      view
      |> element("#new-workspace-form")
      |> render_submit(%{"name" => name, "description" => description})

      # The registry write + the authoritative reload are ASYNC: wait for the
      # menu to come back with the saved workspace loaded.
      expected_point = "vct:///workspaces/#{name}"

      wait_assigns(view, fn assigns ->
        assigns[:palette_mode] == :menu and
          expected_point in workspace_points(assigns[:workspaces])
      end)

      [mount] = Enum.filter(VCT.workspaces(), &(&1.point == expected_point))
      on_exit(fn -> forget_quietly(mount.point) end)

      # The point derives from the name; the members are stored verbatim in
      # click order.
      assert mount.name == name
      assert mount.description == description
      assert Enum.map(mount.members, & &1["point"]) == [beta.point, alpha.point]

      html = render(view)

      # Success flash, and the palette is back in MENU mode.
      assert html =~ "Workspace #{name} saved."
      assert html =~ ~s(id="palette-search-input")
      refute html =~ ~s(id="new-workspace-form")

      # The saved workspace is rendered, EXPANDED, with its identity + members.
      assert count_occurrences(html, ~s(data-workspace-point="#{expected_point}")) == 1

      row = workspace_row(html, expected_point)
      assert row =~ name
      assert row =~ description
      assert row =~ "2 members"
      assert row =~ ~s(aria-expanded="true")
      assert row =~ ~s(data-workspace-member="#{beta.point}")
      assert row =~ ~s(data-workspace-member="#{alpha.point}")
      # The form's member selection was cleared on success.
      assert assigns(view)[:new_workspace_members] == []
    end

    test "re-submitting the same name replaces the workspace instead of duplicating it", %{
      conn: conn,
      tmp_dir: tmp_dir
    } do
      alpha = seed_project!(tmp_dir, unique("alpha"))
      beta = seed_project!(tmp_dir, unique("beta"))
      gamma = seed_project!(tmp_dir, unique("gamma"))
      name = unique("ws-upsert")

      {:ok, view, _html} = live(conn, ~p"/projects")
      wait_for_projects(view, [alpha.path, beta.path, gamma.path])
      wait_for_workspaces(view, [])

      expected_point = "vct:///workspaces/#{name}"

      # ── first save: alpha + beta ────────────────────────────────────────
      render_click(view, "open_project_palette", %{})
      render_click(view, "palette_mode", %{"mode" => "new_workspace"})
      render_click(view, "toggle_workspace_member", %{"point" => alpha.point})
      render_click(view, "toggle_workspace_member", %{"point" => beta.point})

      view
      |> element("#new-workspace-form")
      |> render_submit(%{"name" => name, "description" => "first description"})

      wait_assigns(view, fn assigns ->
        assigns[:palette_mode] == :menu and
          expected_point in workspace_points(assigns[:workspaces])
      end)

      [first] = Enum.filter(VCT.workspaces(), &(&1.point == expected_point))
      on_exit(fn -> forget_quietly(first.point) end)

      assert first.description == "first description"
      assert Enum.map(first.members, & &1["point"]) == [alpha.point, beta.point]

      html = render(view)
      assert html =~ "first description"
      assert count_occurrences(html, ~s(data-workspace-point="#{expected_point}")) == 1

      # ── second save, SAME name: different description + member set ───────
      render_click(view, "palette_mode", %{"mode" => "new_workspace"})
      # Entering the form always starts from an empty member selection.
      assert assigns(view)[:new_workspace_members] == []
      render_click(view, "toggle_workspace_member", %{"point" => gamma.point})

      view
      |> element("#new-workspace-form")
      |> render_submit(%{"name" => name, "description" => "second description"})

      wait_assigns(view, fn assigns ->
        assigns[:palette_mode] == :menu and
          Enum.any?(assigns[:workspaces] || [], fn
            %{workspace: %{point: point, description: "second description"}} ->
              point == expected_point

            _entry ->
              false
          end)
      end)

      html = render(view)

      # Exactly ONE row for the point (an upsert, never a duplicate)...
      assert count_occurrences(html, ~s(data-workspace-point="#{expected_point}")) == 1
      assert count_occurrences(html, "Workspace #{name} saved.") == 1

      # ...showing the REPLACED description and member set.
      row = workspace_row(html, expected_point)
      assert row =~ "second description"
      refute row =~ "first description"
      assert row =~ "1 members"
      assert row =~ ~s(data-workspace-member="#{gamma.point}")
      refute row =~ ~s(data-workspace-member="#{alpha.point}")
      refute row =~ ~s(data-workspace-member="#{beta.point}")

      # The registry agrees: one mount for the point, newest values only.
      [mount] = Enum.filter(VCT.workspaces(), &(&1.point == expected_point))
      assert mount.description == "second description"
      assert Enum.map(mount.members, & &1["point"]) == [gamma.point]
    end

    test "project rows keep their actions while a workspace row offers none", %{
      conn: conn,
      tmp_dir: tmp_dir
    } do
      alpha = seed_project!(tmp_dir, unique("alpha"))
      name = unique("ws-not-runnable")
      workspace = seed_workspace!(name, [member_ref(alpha)], "metadata only")

      {:ok, view, _html} = live(conn, ~p"/projects")
      wait_for_projects(view, [alpha.path])
      wait_for_workspaces(view, [workspace.point])

      html = render_click(view, "open_project_palette", %{})

      # ── existing project behavior is unchanged ─────────────────────────
      row = project_row(html, alpha.path)
      assert row =~ ~s(phx-click="select_project")
      assert row =~ ~s(phx-value-path="#{alpha.path}")
      # The forget sibling (not nested in the select button).
      assert row =~ ~s(phx-click="forget_project")
      assert row =~ ~s(phx-value-point="#{alpha.point}")

      # Both existing palette actions survive, next to the new workspace action.
      assert html =~ "Open Project by Path"
      assert html =~ "Create New Project"
      assert html =~ ~s(phx-value-mode="open_path")
      assert html =~ ~s(phx-value-mode="new_project")
      assert html =~ ~s(phx-value-mode="new_workspace")

      # ── a workspace is never a runnable project ────────────────────────
      ws_row = workspace_row(html, workspace.point)
      refute ws_row =~ "select_project"
      refute ws_row =~ "forget_project"
      refute ws_row =~ "phx-value-path"

      # Expanding it only reveals members — still no activation affordance.
      expanded = render_click(view, "toggle_workspace", %{"point" => workspace.point})
      ws_row = workspace_row(expanded, workspace.point)
      assert ws_row =~ ~s(data-workspace-member="#{alpha.point}")
      refute ws_row =~ "select_project"
      refute ws_row =~ "forget_project"
    end
  end

  # ---------------------------------------------------------------------------
  # Fixtures
  # ---------------------------------------------------------------------------

  defp unique(prefix), do: "#{prefix}-#{System.unique_integer([:positive])}"

  # Mounts `path` under a per-test-unique name and forgets that point on exit —
  # the mount table is store-backed and run-wide, so mounts outlive the test.
  defp seed_project!(tmp_dir, basename) do
    path = Path.join(tmp_dir, basename)
    File.mkdir_p!(path)

    assert {:ok, mount} = VCT.mount(path, name: basename)

    on_exit(fn -> forget_quietly(mount.point) end)

    mount
  end

  defp seed_workspace!(name, members, description) do
    assert {:ok, mount} = VCT.create_workspace(name, members, description: description)

    on_exit(fn -> forget_quietly(mount.point) end)

    mount
  end

  # The stored member-ref shape the palette submits (`"point"` + this node's
  # OS path for that mount).
  defp member_ref(%{point: point, path: path}), do: %{"point" => point, "path" => path}

  defp forget_quietly(key) do
    try do
      VCT.forget(key)
    rescue
      # Teardown-only rescue: a cleanup failure must never mask a test failure.
      _ -> :ok
    end
  end

  # ---------------------------------------------------------------------------
  # Bounded waits (never `Process.sleep`, reuse: the peers' poll shape)
  # ---------------------------------------------------------------------------

  defp assigns(view), do: :sys.get_state(view.pid, @assigns_timeout_ms).socket.assigns

  defp wait_assigns(view, predicate, timeout_ms \\ @wait_budget_ms) do
    deadline = System.monotonic_time(:millisecond) + timeout_ms

    poll = fn poll ->
      current = assigns(view)

      cond do
        predicate.(current) ->
          :ok

        System.monotonic_time(:millisecond) >= deadline ->
          flunk(
            "wait_assigns timed out. Workspaces: " <>
              inspect(workspace_points(current[:workspaces])) <>
              ", projects: " <>
              inspect(for(%{path: path} <- current[:projects] || [], do: path))
          )

        true ->
          Process.sleep(2)
          poll.(poll)
      end
    end

    poll.(poll)
  end

  # `ProjectsLive.mount/3` seeds `projects: []`; the real list arrives one frame
  # later through the supervised async batch.
  defp wait_for_projects(view, paths) do
    wait_assigns(view, fn current ->
      loaded = for %{path: path} <- current[:projects] || [], do: path
      Enum.all?(List.wrap(paths), &(&1 in loaded))
    end)
  end

  # The VCT workspace VIEWS arrive through their own stale-guarded message
  # (`{:workspaces_loaded, seq, node, result}`), also off-process.
  defp wait_for_workspaces(view, points) do
    wait_assigns(view, fn current ->
      loaded = workspace_points(current[:workspaces])
      Enum.all?(List.wrap(points), &(&1 in loaded))
    end)
  end

  defp workspace_points(workspaces) do
    for %{workspace: %{point: point}} <- workspaces || [], is_binary(point), do: point
  end

  # ---------------------------------------------------------------------------
  # Scoped HTML extraction — assertions must never depend on (or be satisfied
  # by) a concurrently seeded workspace/project from another suite.
  # ---------------------------------------------------------------------------

  # ONE workspace row: from its `data-workspace-point` marker up to the NEXT
  # workspace row or the palette footer.
  defp workspace_row(html, point) do
    marker = ~s(data-workspace-point="#{point}")

    case index_of(html, marker) do
      nil ->
        flunk("no palette workspace row found for #{inspect(point)}")

      start ->
        rest = binary_part(html, start, byte_size(html) - start)

        candidates =
          [index_of(rest, ~s(id="workspace-row-), 1), index_of(rest, "project-palette-footer")]
          |> Enum.reject(&is_nil/1)

        binary_part(rest, 0, Enum.min(candidates ++ [byte_size(rest)]))
    end
  end

  # ONE project row (each is wrapped in `<div class="relative group">`), the
  # same split the peer suite's `palette_row/2` helper uses.
  defp project_row(html, path) do
    marker = ~s(phx-value-path="#{path}")

    html
    |> String.split(~s(<div class="relative group">))
    |> Enum.find(&String.contains?(&1, marker))
    |> case do
      nil -> flunk("no palette project row found for #{inspect(path)}")
      row -> row
    end
  end

  # The OPENING TAG of the element carrying `marker` (attribute assertions on
  # one picker row without depending on attribute adjacency).
  defp pick_row(html, point) do
    marker = ~s(data-workspace-pick="#{point}")

    with start when is_integer(start) <- index_of(html, marker),
         open when is_integer(open) <- last_index_of(html, "<", start),
         close when is_integer(close) <- index_of(html, ">", start) do
      binary_part(html, open, close - open + 1)
    else
      _ -> flunk("no palette member picker row found for #{inspect(point)}")
    end
  end

  # The `data-workspace-selected` chip values in DOCUMENT order (the click
  # order the form submitted).
  defp selected_chips(html) do
    ~r/data-workspace-selected="([^"]*)"/
    |> Regex.scan(html, capture: :all_but_first)
    |> Enum.map(&hd/1)
  end

  defp count_occurrences(html, pattern) do
    length(Regex.scan(Regex.compile!(Regex.escape(pattern)), html))
  end

  defp index_of(string, pattern, from \\ 0) do
    size = byte_size(string)

    if from >= size do
      nil
    else
      case :binary.match(string, pattern, scope: {from, size - from}) do
        {idx, _len} -> idx
        :nomatch -> nil
      end
    end
  end

  defp last_index_of(string, pattern, before) do
    case :binary.matches(binary_part(string, 0, before), pattern) do
      [] -> nil
      matches -> matches |> List.last() |> elem(0)
    end
  end
end
