defmodule EvoDashWeb.WelcomeCompleteLiveTest do
  use EvoDashWeb.ConnCase, async: false
  import Phoenix.LiveViewTest

  # Isolate the onboarding-completion test from the host's real user config —
  # same pattern as welcome_live_test.exs. The go_to_dashboard handler calls
  # EvoGit.Config.VersionState.complete_onboarding/0, which writes
  # version_state.toml into EvoGit.Config.config_dir/0. On Linux that honours
  # the XDG_CONFIG_HOME env var, so pointing it at an empty temp dir
  # guarantees the test only touches temp state. VersionState's
  # :persistent_term cache is keyed by path, so each unique temp dir gets
  # fresh state automatically (no manual cache invalidation needed).
  setup do
    tmp_config =
      Path.join(
        System.tmp_dir!(),
        "evogit_welcome_complete_test_config_#{System.unique_integer([:positive])}"
      )

    File.mkdir_p!(tmp_config)
    original = System.get_env("XDG_CONFIG_HOME")
    System.put_env("XDG_CONFIG_HOME", tmp_config)

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

  describe "welcome complete page rendering" do
    test "renders the explanation, example objective, and copy button", %{conn: conn} do
      {:ok, _view, html} = live(conn, ~p"/welcome/complete")

      # Heading + explanation
      assert html =~ "Write high-level prompts, not code"

      assert html =~
               "In Genesis you only write high-level prompts: describe the end goal, the features you want, and the framework to use. Genesis figures out the architecture, delegates agents, and writes the code."

      # Card title + body
      assert html =~ "Try an example task"

      assert html =~
               "You only need to describe the end goal like this — Genesis figures out the architecture, delegates agents, and writes the code."

      # The example objective is rendered verbatim in the <pre> block
      # (HTML-escaped via interpolation; asserted via distinctive lines that
      # contain no HTML-special characters)
      objective = EvoDashWeb.ExampleTask.example_objective()
      assert objective =~ "Build a simulated, web-based Windows desktop environment"
      assert html =~ ~s(<pre class="font-mono)

      assert html =~
               "Build a simulated, web-based Windows desktop environment using a single browser page."

      assert html =~
               "Taskbar containing a Start button, open application indicators, and a clock."

      # Copy button with the ClipboardCopy hook carrying the objective
      assert html =~ ~s(id="welcome-example-copy")
      assert html =~ ~s(phx-hook="ClipboardCopy")

      assert html =~
               ~s(data-content="Build a simulated, web-based Windows desktop environment using a single browser page.)
    end

    test "copied event shows an info flash", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/welcome/complete")

      html = render_click(view, "copied", %{})

      assert html =~ "Copied to clipboard"
    end
  end

  describe "go to dashboard" do
    test "completes onboarding and redirects to the dashboard", %{conn: conn} do
      {:ok, view, html} = live(conn, ~p"/welcome/complete")

      # Primary CTA is rendered
      assert html =~ ~s(phx-click="go_to_dashboard")
      assert html =~ "btn btn-primary rounded-xl px-8"
      assert html =~ "Go to Dashboard"

      # Fresh temp config dir → onboarding is needed before the click
      assert EvoGit.Config.VersionState.onboarding_needed?() == true

      render_click(view, "go_to_dashboard", %{})

      # Same redirect-assertion style as the skip/get_started tests
      assert_redirect(view, "/")

      # Onboarding is marked complete: the version-state file now exists in
      # the temp config dir and records the current runtime version.
      assert EvoGit.Config.VersionState.onboarding_needed?() == false
      assert File.exists?(EvoGit.Config.VersionState.path())

      assert EvoGit.Config.VersionState.get_version() ==
               EvoGit.Config.VersionState.current_version()
    end
  end
end
