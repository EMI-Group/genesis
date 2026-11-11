defmodule EvoDashWeb.RedirectControllerTest do
  # async: true — every test issues a plain `GET` (no LiveView mount), so
  # nothing process-global is written: not `EvoDash.ChatHistory` (a connected
  # HomeLive mount is what writes it), not `EvoDash.ActiveTasks`, not the task
  # store. The config dir IS isolated per process through the test-only
  # `:config_dir_fun` seam (`EvoDash.Test.ConfigDir.isolate!/1`, installed by
  # test/test_helper.exs), which is what keeps the one `/assistant` dead render
  # below out of the developer's real `~/.config/genesis`.
  use EvoDashWeb.ConnCase, async: true

  # The Genesis Assistant page moved from `/help` to `/assistant`; `/help` stays
  # a 302 alias (`EvoDashWeb.RedirectController.assistant/2`) that preserves the
  # RAW query string, so bookmarked conversations (`/help?session=7`) and
  # remote-node views (`/help?node=<target>`) keep working.
  setup do
    # The `/assistant` dead render redirects first-time users to /welcome via
    # `EvoGit.Config.VersionState.onboarding_needed?/0`. Isolate the config dir
    # per process and mark onboarding complete so the page renders instead.
    EvoDash.Test.ConfigDir.isolate!("evogit_redirect_test_config")

    if Code.ensure_loaded?(EvoGit.Config.VersionState) do
      EvoGit.Config.VersionState.complete_onboarding()
    end

    :ok
  end

  test "bare GET /help redirects to /assistant (no trailing question mark)", %{conn: conn} do
    assert redirected_to(get(conn, ~p"/help"), 302) == "/assistant"
  end

  test "GET /help?session=7 keeps the session query param", %{conn: conn} do
    assert redirected_to(get(conn, "/help?session=7"), 302) == "/assistant?session=7"
  end

  test "GET /help?session=7&node=t1 keeps the whole raw query string", %{conn: conn} do
    assert redirected_to(get(conn, "/help?session=7&node=t1"), 302) ==
             "/assistant?session=7&node=t1"
  end

  test "GET /help?node=t1 keeps a lone node query param", %{conn: conn} do
    assert redirected_to(get(conn, "/help?node=t1"), 302) == "/assistant?node=t1"
  end

  test "GET /assistant answers 200", %{conn: conn} do
    # A plain (dead-render) GET only — mounting the LiveView here would write
    # the process-global `EvoDash.ChatHistory` table and break this module's
    # async isolation.
    html = html_response(get(conn, ~p"/assistant"), 200)

    assert html =~ ~s(id="chat-form")
    assert html =~ "Genesis Assistant"
  end
end
