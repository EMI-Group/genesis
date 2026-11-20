defmodule Mix.Tasks.Vct.WorkspaceTest do
  @moduledoc """
  Tests for `mix vct.workspace` — the operator path for seeding and inspecting
  VCT workspaces.

  Every case drives the task DIRECTLY (`Mix.Tasks.Vct.Workspace.run/1`, with
  `Mix.Task.reenable/1` between runs) against a `--data-dir` under this test's
  `tmp_dir`, so the live database is never touched. The task boots and stops
  its own private store/VCT stack, and the assertions read the SAME database
  back through a second, uniquely-named isolated stack — what is verified is
  what was persisted, not what the task printed.

  `async: true`: every stack is uniquely named and bound to its own temp
  directory, and no app-global singleton is ever addressed.
  """

  use ExUnit.Case, async: true

  import ExUnit.CaptureIO

  alias EvoGit.VCT
  alias EvoGit.VCT.Mount
  alias Mix.Tasks.Vct.Workspace, as: Task

  @task "vct.workspace"

  @moduletag :tmp_dir

  describe "create" do
    test "two identical runs print identical output and keep ONE ordered workspace",
         %{tmp_dir: tmp} do
      data_dir = Path.join(tmp, "data")
      app_a = mount_project!(data_dir, Path.join(tmp, "app-a"))
      app_b = dir!(Path.join(tmp, "app-b"))

      args = [
        "create",
        "foobar",
        "--member",
        app_a.point,
        "--member",
        app_b,
        "--description",
        "Web apps",
        "--data-dir",
        data_dir
      ]

      first = run(args)
      second = run(args)

      assert first == second
      assert first =~ "Workspace: vct:///workspaces/foobar"
      assert first =~ "name: foobar"
      assert first =~ "description: Web apps"

      # Stored order survives the re-run, in the printed block AND in the row.
      assert first =~
               ~r/members \(stored order\):\n    - #{Regex.escape(app_a.point)}\n    - #{Regex.escape(app_b)}\n/

      assert [%Mount{} = workspace] = workspaces_in!(data_dir)
      assert workspace.point == "vct:///workspaces/foobar"
      assert workspace.name == "foobar"
      assert workspace.description == "Web apps"
      assert workspace.path == nil

      assert workspace.members == [
               %{"point" => app_a.point, "path" => nil},
               %{"point" => nil, "path" => app_b}
             ]
    end

    test "propagates a VCT validation error instead of reporting success", %{tmp_dir: tmp} do
      data_dir = Path.join(tmp, "data")
      create!(data_dir, "inner", [dir!(Path.join(tmp, "inner-app"))])

      error =
        assert_raise Mix.Error, fn ->
          run(["create", "outer", "--member", "vct:///workspaces/inner", "--data-dir", data_dir])
        end

      assert error.message =~ "cannot be a member"
      assert Enum.map(workspaces_in!(data_dir), & &1.point) == ["vct:///workspaces/inner"]
    end
  end

  describe "list" do
    test "prints the workspace, its resolved members and its MISSING refs", %{tmp_dir: tmp} do
      data_dir = Path.join(tmp, "data")
      app_a = mount_project!(data_dir, Path.join(tmp, "app-a"))
      create!(data_dir, "foobar", [app_a.point, "vct:///projects/ghost"])

      output = run(["list", "--data-dir", data_dir])

      assert output =~ "Workspaces: 1"
      assert output =~ "Workspace: vct:///workspaces/foobar"
      assert output =~ "  name: foobar"
      assert output =~ "    - #{app_a.point}"
      assert output =~ "    MISSING: vct:///projects/ghost"
    end

    test "reports an empty table", %{tmp_dir: tmp} do
      assert run(["list", "--data-dir", Path.join(tmp, "data")]) =~ "No workspaces."
    end
  end

  describe "show" do
    test "resolves present members and reports an unresolvable ref as MISSING", %{tmp_dir: tmp} do
      data_dir = Path.join(tmp, "data")
      # Mounted HERE, so the stored PATH ref below resolves to its mount point.
      app_a = mount_project!(data_dir, Path.join(tmp, "app-a"))
      create!(data_dir, "foobar", [app_a.path, "vct:///projects/ghost"])

      output = run(["show", "foobar", "--data-dir", data_dir])

      assert output =~ "Workspace: vct:///workspaces/foobar"
      assert output =~ "    - #{app_a.point}"
      refute output =~ "    - #{app_a.path}"
      assert output =~ "    MISSING: vct:///projects/ghost"
    end

    test "raises for a mount that is not a workspace and for an unknown name", %{tmp_dir: tmp} do
      data_dir = Path.join(tmp, "data")
      app_a = mount_project!(data_dir, Path.join(tmp, "app-a"))

      not_a_workspace =
        assert_raise Mix.Error, fn -> run(["show", app_a.point, "--data-dir", data_dir]) end

      assert not_a_workspace.message =~ "NOT a workspace"

      unknown = assert_raise Mix.Error, fn -> run(["show", "ghost", "--data-dir", data_dir]) end
      assert unknown.message =~ "no workspace row"
    end
  end

  describe "argument contract" do
    test "raises on a missing/unknown subcommand, a create without --member and a bad option",
         %{tmp_dir: tmp} do
      data_dir = Path.join(tmp, "data")

      assert_raise Mix.Error, fn -> run(["--data-dir", data_dir]) end
      assert_raise Mix.Error, fn -> run(["nope", "--data-dir", data_dir]) end
      assert_raise Mix.Error, fn -> run(["create", "group", "--data-dir", data_dir]) end
      assert_raise Mix.Error, fn -> run(["show", "--data-dir", data_dir]) end
      assert_raise Mix.Error, fn -> run(["list", "--bogus", "--data-dir", data_dir]) end
      assert_raise Mix.Error, fn -> run(["list", "--member", "x", "--data-dir", data_dir]) end
    end
  end

  ## Task driving

  defp create!(data_dir, name, members) do
    run(["create", name, "--data-dir", data_dir] ++ Enum.flat_map(members, &["--member", &1]))
  end

  defp run(args) do
    Mix.Task.reenable(@task)
    output = capture_io(fn -> Task.run(args) end)
    strip_banner(output)
  end

  # `Mix.Shell.IO.info/1` prints Mix's one-time "==> <app>" banner the first
  # time the shell is used in a session — Mix's own artifact, not task output.
  defp strip_banner("==> " <> _rest = output) do
    output |> String.split("\n", parts: 2) |> List.last()
  end

  defp strip_banner(output), do: output

  ## Isolated stacks on the SAME database

  # Reads the persisted workspaces back through a fresh, isolated stack.
  defp workspaces_in!(data_dir), do: with_vct(data_dir, fn -> VCT.workspaces() end)

  # Mounts `path` as a PROJECT mount in the task database `data_dir`, so a
  # stored member ref can resolve (or deliberately not, when no mount exists).
  defp mount_project!(data_dir, path) do
    File.mkdir_p!(path)
    {:ok, mount} = with_vct(data_dir, fn -> VCT.mount(path) end)
    mount
  end

  defp dir!(path) do
    File.mkdir_p!(path)
    path
  end

  defp with_vct(data_dir, fun) do
    unique = System.unique_integer([:positive])
    store = :"vct_workspace_task_test_store_#{unique}"
    vct = :"vct_workspace_task_test_vct_#{unique}"
    pubsub = :"vct_workspace_task_test_pubsub_#{unique}"

    children = [
      {Phoenix.PubSub, name: pubsub},
      Supervisor.child_spec(
        {EvoGit.Store, data_dir: Path.join(data_dir, "tasks.sqlite"), name: store, pool_size: 1},
        id: store
      ),
      Supervisor.child_spec(
        {EvoGit.VCT, name: vct, data_dir: data_dir, store: store, pubsub: pubsub},
        id: vct
      )
    ]

    {:ok, supervisor} = Supervisor.start_link(children, strategy: :one_for_one)
    previous = Process.put(:evogit_vct_server, vct)

    try do
      fun.()
    after
      Process.put(:evogit_vct_server, previous)
      Supervisor.stop(supervisor)
    end
  end
end
