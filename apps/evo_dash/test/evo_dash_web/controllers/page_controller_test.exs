defmodule EvoDashWeb.PageControllerTest do
  use EvoDashWeb.ConnCase

  # DashboardLive redirects first-time users to /welcome via server-based
  # detection (EvoGit.Config.VersionState.onboarding_needed?/0). Isolate the
  # config dir to a temp directory and mark onboarding complete so the GET /
  # renders the dashboard instead of redirecting.
  setup do
    tmp_config =
      Path.join(
        System.tmp_dir!(),
        "evogit_page_test_config_#{System.unique_integer([:positive])}"
      )

    File.mkdir_p!(tmp_config)
    original = System.get_env("XDG_CONFIG_HOME")
    System.put_env("XDG_CONFIG_HOME", tmp_config)
    # Windows: EvoGit.Config.config_dir/0 honours APPDATA instead of XDG.
    original_appdata = System.get_env("APPDATA")
    System.put_env("APPDATA", tmp_config)

    if Code.ensure_loaded?(EvoGit.Config.VersionState) do
      EvoGit.Config.VersionState.complete_onboarding()
    end

    on_exit(fn ->
      if original do
        System.put_env("XDG_CONFIG_HOME", original)
      else
        System.delete_env("XDG_CONFIG_HOME")
      end

      if original_appdata do
        System.put_env("APPDATA", original_appdata)
      else
        System.delete_env("APPDATA")
      end

      File.rm_rf!(tmp_config)
    end)

    :ok
  end

  test "GET /", %{conn: conn} do
    conn = get(conn, ~p"/")

    assert html_response(conn, 200) =~ "Genesis"
  end
end
