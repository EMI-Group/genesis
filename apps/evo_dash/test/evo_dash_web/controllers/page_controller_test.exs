defmodule EvoDashWeb.PageControllerTest do
  # async: false — the "malformed ActiveTasks hub" test writes JUNK SENTINEL
  # SHAPES into the boot-created, process-global `EvoDash.ActiveTasks` hub under
  # the `{nil, node()}` LOCAL key, and every connected whole-page mount seeds
  # its sidebar from exactly that key (`NodeAware.hub_snapshot/2`). An
  # `async: true` page-mounting peer (`agents_live_test`, `desktop_quit_test`)
  # would seed the junk list into `Layouts.group_tasks_by_project/2` mid-run,
  # which is the crash this suite pins. The config directory is NOT a reason to
  # stay sync any more: it is isolated PER PROCESS through the test-only
  # `:config_dir_fun` seam (`EvoDash.Test.ConfigDir.isolate!/1`, installed by
  # test/test_helper.exs), never through a BEAM-global `XDG_CONFIG_HOME` write.
  use EvoDashWeb.ConnCase, async: false

  # ProjectsLive (GET /) and HomeLive (GET /help) both redirect first-time
  # users to /welcome via server-based detection
  # (EvoGit.Config.VersionState.onboarding_needed?/0). Isolate the config dir
  # to a per-test temp directory (the override lives in the TEST process'
  # dictionary and reaches the mounted pages through OTP's `:"$callers"` chain)
  # and mark onboarding complete so both routes render their pages instead of
  # redirecting.
  setup do
    # `isolate!/1` creates a unique temp dir, activates it for this process and
    # registers the `File.rm_rf!` cleanup itself. The layout is
    # `<temp dir>/genesis` — byte-identical to the old `XDG_CONFIG_HOME` redirect.
    EvoDash.Test.ConfigDir.isolate!("evogit_page_test_config")

    if Code.ensure_loaded?(EvoGit.Config.VersionState) do
      EvoGit.Config.VersionState.complete_onboarding()
    end

    :ok
  end

  test "GET / renders the Projects page and GET /help the chat page", %{conn: conn} do
    html = html_response(get(conn, ~p"/"), 200)
    # Projects page: command palette + task form present, no chat send form
    assert html =~ "project-omnibox"
    assert html =~ "AdaptiveInput"
    refute html =~ "chat-form"

    # The Home chat page is the other entry point (HomeLive at /help).
    chat_html = html_response(get(conn, ~p"/help"), 200)
    assert chat_html =~ ~s(id="chat-form")
    assert chat_html =~ "Chat with Genesis"
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
