defmodule EvoDashWeb.WelcomeCompleteLiveTest do
  # async: true — this module mutates NO process-global state.
  #
  # The config directory is isolated PER PROCESS through the test-only
  # `:config_dir_fun` seam (`EvoDash.Test.ConfigDir.isolate!/1`, installed by
  # test/test_helper.exs), never through a BEAM-global `XDG_CONFIG_HOME` write.
  # `go_to_dashboard` runs `EvoGit.Config.VersionState.complete_onboarding/0`,
  # which writes `version_state.toml` into `EvoGit.Config.config_dir/0`; with the
  # seam that file lands in THIS test's own `<temp dir>/genesis`, so it can never
  # mark onboarding complete for another suite (projects_live_test asserts the
  # push_navigate to /welcome). VersionState's `:persistent_term` cache is keyed
  # by path, so each unique temp dir gets fresh state automatically (no manual
  # cache invalidation needed).
  #
  # `EvoDash.ActiveTasks` — the sidebar hub seeded on every mount — is reset by
  # `EvoDashWeb.ConnCase`'s setup and again in its `on_exit`, and no test here
  # reads it, so no reset of its own is needed.
  #
  # The "tasks" PubSub regression test lives in its own `async: false` module at
  # the end of this file: broadcasting `{:task_updated, …}` reaches EVERY mounted
  # page in the BEAM (it arms `NodeAware`'s reload debounce, which an async
  # page-mounting peer such as agents_live_test observes negatively).
  use EvoDashWeb.ConnCase, async: true
  import Phoenix.LiveViewTest

  setup do
    # Per-process config dir (see the module comment). `isolate!/1` creates a
    # unique temp dir, activates it for this process and registers the
    # `File.rm_rf!` cleanup itself.
    EvoDash.Test.ConfigDir.isolate!("evogit_welcome_complete_test_config")
    :ok
  end

  describe "welcome complete page rendering" do
    test "renders the explanation, example objective and copy button; copying flashes info",
         %{conn: conn} do
      {:ok, view, html} = live(conn, ~p"/welcome/complete")

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

      # Copying pushes an info flash.
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
      assert_redirect(view, "/projects")

      # Onboarding is marked complete: the version-state file now exists in
      # the temp config dir and records the current runtime version.
      assert EvoGit.Config.VersionState.onboarding_needed?() == false
      assert File.exists?(EvoGit.Config.VersionState.path())

      assert EvoGit.Config.VersionState.get_version() ==
               EvoGit.Config.VersionState.current_version()
    end
  end

  # The "task broadcast handling" regression guard (WelcomeCompleteLive had no
  # `handle_info` clauses for `{:task_updated, …}` / `{:task_deleted, …}` and
  # crashed with FunctionClauseError) lives in
  # `EvoDashWeb.WelcomeCompleteLiveTest.TaskBroadcast` — its own `async: false`
  # module at the end of this file, because it must PUBLISH on the
  # process-global "tasks" topic.
end

defmodule EvoDashWeb.WelcomeCompleteLiveTest.TaskBroadcast do
  # async: false — this test PUBLISHES `{:task_updated, …}` on the
  # process-global "tasks" `EvoGit.PubSub` topic. Every mounted page in the BEAM
  # subscribes to that topic through `NodeAware`, so the broadcast arms every
  # other page's reload debounce and emits `:node_aware_reload_tasks`; running it
  # concurrently with an async page-mounting peer (agents_live_test's negative
  # `:tasks_reload_pending` poll is the documented victim) is unsafe. Sync
  # modules run only after every async one drains, so nothing observes it.
  #
  # It stays a separate MODULE rather than making the whole file sync because the
  # two rendering tests above mutate no global at all.
  use EvoDashWeb.ConnCase, async: false
  import Phoenix.LiveViewTest

  setup do
    EvoDash.Test.ConfigDir.isolate!("evogit_welcome_complete_test_config")
    :ok
  end

  test "handle_info {:task_updated, _, :finalizing, node()} does not crash the LiveView", %{
    conn: conn
  } do
    {:ok, view, _html} = live(conn, ~p"/welcome/complete")

    # The broadcast shape observed crashing in production (the :finalizing
    # status transition).
    Phoenix.PubSub.broadcast(
      EvoGit.PubSub,
      "tasks",
      {:task_updated, "test-finalizing", :finalizing, node()}
    )

    # render/1 flushes pending messages synchronously; a crash would propagate here.
    html = render(view)
    assert is_binary(html)
    assert html =~ "Write high-level prompts, not code"
  end
end
