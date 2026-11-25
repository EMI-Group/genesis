defmodule EvoDashWeb.ProjectsLive.ConfigReloadScopeTest do
  @moduledoc """
  Pins the CONFIG-DIR ownership guard of the Projects page's
  `{:config_reloaded, node, dir, generation}` handler.
  A broadcast refreshes the canonical picker bundle only when it names THIS
  page's own config dir (`EvoGit.Config.config_dir/0`): a FOREIGN dir belongs to
  another instance and must skip both the `AsyncLoad` batch and the
  `:load_config_status` self-send, so it can never clear the picker's ready
  state. Each test sends the message to `view.pid` directly, so the assertion
  never depends on another test's real broadcast.
  `async: true` — the config dir is isolated PER PROCESS through the test-only
  `:config_dir_fun` seam (`EvoDash.Test.ConfigDir.isolate!/1`), which the
  mounted view and its supervised load tasks inherit through `$callers`; a
  unique directory per test keeps the path-keyed config caches cache-safe and
  nothing BEAM-global is mutated.
  """
  use EvoDashWeb.ConnCase, async: true
  import Phoenix.LiveViewTest
  # Load-tolerant budget for the page's ASYNC work (bounded, so real breakage
  # fails loudly instead of hanging).
  @async_wait_budget_ms 30_000
  # `:sys.get_state/2` timeout for `assigns/1`: a loaded host can starve the
  # LiveView for seconds.
  @assigns_timeout_ms 30_000
  # A generation no real reload of this page can have produced.
  @generation 12_345
  setup %{conn: conn} do
    # `/projects` redirects a first-time user to /welcome
    # (`EvoGit.Config.VersionState.onboarding_needed?/0`) — the proven setup from
    # `EvoDashWeb.ProjectsLiveTest.Helpers.set_onboarding_completed/1`.
    EvoDash.Test.ConfigDir.isolate!("evogit_projects_config_reload_test")
    EvoGit.Config.VersionState.complete_onboarding()
    {:ok, conn: Plug.Test.init_test_session(conn, %{})}
  end

  test "a foreign config dir never re-spawns the picker batch", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/projects")
    await_async_loads(view)
    # Settle the connected mount first: its own batch and status reload must not
    # be mistaken for a reaction to the message below.
    assert assigns(view)[:config_generation] == nil

    foreign_dir =
      Path.join(System.tmp_dir!(), "evogit_foreign_config_#{System.unique_integer([:positive])}")

    refute foreign_dir == EvoGit.Config.config_dir()
    send(view.pid, {:config_reloaded, node(), foreign_dir, @generation})
    # A SECOND drain: a batch spawned by the message would be waited on here,
    # so the nil below cannot just be a not-yet-applied result.
    await_async_loads(view)
    # Nothing was drained into the assign — the foreign dir is not this page's
    # identity, so it never becomes the handled generation.
    assert assigns(view)[:config_generation] == nil
  end

  test "the page's own config dir re-spawns the picker batch", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/projects")
    await_async_loads(view)
    dir = EvoGit.Config.config_dir()
    send(view.pid, {:config_reloaded, node(), dir, @generation})
    wait_until(fn -> assigns(view)[:config_generation] == {dir, @generation} end)
    assert assigns(view)[:config_generation] == {dir, @generation}
  end

  # The view's live assigns (`Phoenix.LiveViewTest` exports no `assigns/1`).
  defp assigns(view), do: :sys.get_state(view.pid, @assigns_timeout_ms).socket.assigns
  # Drains this view's supervised load tasks: `EvoDash.TaskSupervisor` records
  # the spawning process in a child's `$callers`, so matching the view pid
  # targets exactly this page's tasks and never a concurrent module's.
  defp await_async_loads(view) do
    _ = assigns(view)

    view.pid
    |> mount_async_task_pids()
    |> Enum.map(&Process.monitor/1)
    |> Enum.each(fn ref ->
      # A task that already exited delivers its :DOWN immediately; its result
      # message is queued BEFORE the exit, so nothing is lost.
      receive do
        {:DOWN, ^ref, :process, _pid, _reason} -> :ok
      after
        @async_wait_budget_ms -> :ok
      end
    end)

    _ = render(view)
    :ok
  end

  defp mount_async_task_pids(view_pid) do
    EvoDash.TaskSupervisor
    |> DynamicSupervisor.which_children()
    |> Enum.flat_map(fn
      {_, pid, _, _} when is_pid(pid) ->
        if view_pid in task_callers(pid), do: [pid], else: []

      _ ->
        []
    end)
  end

  defp task_callers(pid) do
    case Process.info(pid, :dictionary) do
      {:dictionary, dictionary} -> Keyword.get(dictionary, :"$callers", [])
      _ -> []
    end
  end

  # Bounded poll on a monotonic deadline (a few ms cadence, never a fixed sleep
  # standing in for a synchronization point).
  defp wait_until(fun, budget_ms \\ 10_000) do
    deadline = System.monotonic_time(:millisecond) + budget_ms
    do_wait_until(fun, deadline)
  end

  defp do_wait_until(fun, deadline) do
    if fun.() do
      :ok
    else
      if System.monotonic_time(:millisecond) >= deadline do
        flunk("condition not met within the wait budget")
      else
        Process.sleep(5)
        do_wait_until(fun, deadline)
      end
    end
  end
end
