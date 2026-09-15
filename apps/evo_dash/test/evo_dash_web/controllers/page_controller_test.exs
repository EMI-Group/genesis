defmodule EvoDashWeb.PageControllerTest do
  use EvoDashWeb.ConnCase

  # ProjectsLive (GET /) and HomeLive (GET /help) both redirect first-time
  # users to /welcome via server-based detection
  # (EvoGit.Config.VersionState.onboarding_needed?/0). Isolate the config
  # dir to a temp directory and mark onboarding complete so both routes
  # render their pages instead of redirecting.
  setup do
    tmp_config =
      Path.join(
        System.tmp_dir!(),
        "evogit_page_test_config_#{System.unique_integer([:positive])}"
      )

    File.mkdir_p!(tmp_config)
    original = System.get_env("XDG_CONFIG_HOME")
    System.put_env("XDG_CONFIG_HOME", tmp_config)

    if Code.ensure_loaded?(EvoGit.Config.VersionState) do
      EvoGit.Config.VersionState.complete_onboarding()
    end

    on_exit(fn ->
      if original do
        System.put_env("XDG_CONFIG_HOME", original)
      else
        System.delete_env("XDG_CONFIG_HOME")
      end

      File.rm_rf!(tmp_config)
    end)

    :ok
  end

  test "GET / renders the Projects page", %{conn: conn} do
    conn = get(conn, ~p"/")

    html = html_response(conn, 200)
    # Projects page: command palette + task form present, no chat send form
    assert html =~ "project-omnibox"
    assert html =~ "AdaptiveInput"
    refute html =~ "chat-form"
  end

  test "GET /help renders the chat page", %{conn: conn} do
    conn = get(conn, ~p"/help")

    html = html_response(conn, 200)
    assert html =~ ~s(id="chat-form")
    assert html =~ "Chat with Genesis"
  end

  # Regression: the sidebar "Active Tasks" hub (`EvoDash.ActiveTasks`) is a
  # process-wide, shape-agnostic ETS table, so a non-map entry left in it by
  # another suite (e.g. `put(nil, node(), [:c], [])`) used to be seeded into
  # `@running_tasks`/`@pending_tasks` on mount and crash the whole page in
  # `Layouts.group_tasks_by_project/2` with
  # `** (BadMapError) expected a map, got: :c`. The mount hook now sanitizes
  # hub snapshots (`NodeAware.hub_snapshot/2`), so a polluted hub must not break
  # whole-page renders. The hub is a shared named table, so clear it before and
  # after this test to keep the junk from leaking to other suites.
  test "sidebar renders while the ActiveTasks hub holds malformed entries",
       %{conn: conn} do
    EvoDash.ActiveTasks.reset()

    on_exit(fn -> EvoDash.ActiveTasks.reset() end)

    # Sanity check that the seeded snapshot actually reaches the dead-render
    # path: a well-formed local snapshot makes the sidebar render its
    # "Active Tasks" section (proves `NodeAware.on_mount/4` seeds from the hub
    # on a plain HTTP render, not only on the connected mount).
    EvoDash.ActiveTasks.put(
      nil,
      node(),
      [
        %{
          id: "seeded-hub-task",
          status: :running,
          project_path: "/tmp/seeded_hub_project",
          started_at: DateTime.utc_now()
        }
      ],
      []
    )

    assert html_response(get(conn, ~p"/"), 200) =~ "Active Tasks"

    # Non-map entry in running_tasks — the exact shape that used to crash.
    EvoDash.ActiveTasks.put(nil, node(), [:c], [])

    assert html_response(get(conn, ~p"/"), 200)

    # Mixed case: a non-map entry in pending_tasks.
    EvoDash.ActiveTasks.put(nil, node(), [], [:c])

    assert html_response(get(conn, ~p"/help"), 200)
    assert html_response(get(conn, ~p"/tasks"), 200)
  end
end
