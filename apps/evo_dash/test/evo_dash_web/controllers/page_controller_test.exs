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
end
