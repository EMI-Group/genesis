defmodule EvoDashWeb.HomeReproTest do
  use EvoDashWeb.ConnCase, async: false
  import Phoenix.LiveViewTest

  alias EvoGit.TaskInfo
  alias EvoGit.TaskRegistry

  setup do
    Supervisor.terminate_child(EvoGit.Supervisor, EvoGit.TaskRegistry)
    Supervisor.terminate_child(EvoGit.Supervisor, EvoGit.Store)

    unique = System.unique_integer([:positive])
    root = Path.join(System.tmp_dir!(), "evogit_test_home_repro_#{unique}")
    File.mkdir_p!(root)
    sqlite_path = Path.join(root, "tasks.sqlite")

    start_supervised({EvoGit.Store, data_dir: sqlite_path})
    start_supervised({TaskRegistry, task_store: EvoGit.Store, data_dir: root, name: EvoGit.TaskRegistry})

    tmp_config = Path.join(System.tmp_dir!(), "evogit_home_repro_config_#{System.unique_integer([:positive])}")
    File.mkdir_p!(tmp_config)
    original_xdg = System.get_env("XDG_CONFIG_HOME")
    System.put_env("XDG_CONFIG_HOME", tmp_config)
    if Code.ensure_loaded?(EvoGit.Config.VersionState) do
      EvoGit.Config.VersionState.complete_onboarding()
    end

    on_exit(fn ->
      if original_xdg, do: System.put_env("XDG_CONFIG_HOME", original_xdg), else: System.delete_env("XDG_CONFIG_HOME")
      File.rm_rf!(tmp_config)
      try do
        File.rm_rf(root)
      rescue
        _ -> :ok
      end
      Supervisor.restart_child(EvoGit.Supervisor, EvoGit.Store)
      Supervisor.restart_child(EvoGit.Supervisor, EvoGit.TaskRegistry)
    end)

    :ok
  end

  defp insert_reflect!(overrides) do
    id = "reflect_#{System.unique_integer([:positive])}"

    task =
      %TaskInfo{
        id: id,
        type: :reflect,
        status: :running,
        opts: [mode: "reflect", objective: "New message: hi"],
        ref: nil,
        started_at: DateTime.utc_now(),
        finished_at: nil,
        logs: [],
        result: nil,
        project_path: nil
      }
      |> Map.merge(Enum.into(overrides, %{}))

    EvoGit.Store.put_task(EvoGit.Store, task)
    id
  end

  test "debounced reload after task_updated renders sidebar with reflect task", %{conn: conn} do
    id = insert_reflect!(status: :running)
    {:ok, view, _html} = live(conn, "/help")

    send(view.pid, {:task_updated, id, :pending, node()})
    send(view.pid, {:task_updated, id, :running, node()})

    # Let the 300ms debounce fire and the async fetch complete.
    Process.sleep(600)

    html = render(view)
    assert html =~ "Active Tasks"
    assert html =~ "New message"
  end

  test "failed reflect task broadcast after running", %{conn: conn} do
    id = insert_reflect!(status: :failed, finished_at: DateTime.utc_now(), result: {:error, "boom"})
    {:ok, view, _html} = live(conn, "/help")

    send(view.pid, {:task_updated, id, :failed, node()})
    Process.sleep(600)

    html = render(view)
    IO.puts("RENDERED OK: " <> String.slice(html, 0, 80))
  end
end
