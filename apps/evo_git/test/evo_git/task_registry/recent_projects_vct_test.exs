defmodule EvoGit.TaskRegistry.RecentProjectsVctTest do
  @moduledoc """
  The TaskRegistry's "recently opened projects" API since it was wired onto the
  Virtual Context Tree mount store:

    * `add_recent_project/2` / `list_recent_projects/0` /
      `remove_recent_project/1` delegate to `EvoGit.VCT` and NEVER write the
      legacy SQLite `projects` table (proven by `EvoGit.Store.count_projects/1`
      staying at 0);
    * each returned `%EvoGit.RecentProject{}` keeps the OS `path`/`name` and
      gains the mount point as `vct_path`;
    * the 10-entry DISPLAY cap is a read-time limit — the VCT retains every
      mount.

  Isolation comes from `EvoGit.TaskRegistryCase`: an isolated Store, an
  ISOLATED `EvoGit.VCT` (fresh mount-table file, `legacy_projects: []`) and an
  isolated TaskRegistry wired to it via `vct:`.
  """

  use EvoGit.TaskRegistryCase, async: true

  alias EvoGit.RecentProject
  alias EvoGit.VCT
  alias EvoGit.VCT.Mount

  describe "add_recent_project/2 → list_recent_projects/0" do
    test "stores the mount in the VCT (not SQLite) and reports its vct_path",
         %{data_dir: data_dir, store: store} do
      base = Path.join(data_dir, "recent-proj-#{unique()}")
      basename = Path.basename(base)

      assert :ok = TaskRegistry.add_recent_project(base, "My Project")

      assert [%RecentProject{} = project] = TaskRegistry.list_recent_projects()
      assert project.path == base
      assert project.name == "My Project"
      assert project.vct_path == "vct:///projects/#{basename}"
      assert %DateTime{} = project.last_opened_at

      # Delegation proof: the legacy SQLite `projects` table is never written…
      assert EvoGit.Store.count_projects(store) == 0

      # …the mount store owns the entry instead.
      assert [%Mount{path: ^base, name: "My Project"}] = VCT.mounts()
    end

    test "the same OS path is idempotent; a same-basename path gets a deduped point",
         %{data_dir: data_dir, store: store} do
      id = unique()
      first_dir = Path.join([data_dir, "one", "#{id}", "alpha"])
      second_dir = Path.join([data_dir, "two", "#{id}", "alpha"])
      File.mkdir_p!(first_dir)
      File.mkdir_p!(second_dir)

      assert :ok = TaskRegistry.add_recent_project(first_dir, "Alpha")
      first_point = hd(TaskRegistry.list_recent_projects()).vct_path
      assert first_point == "vct:///projects/alpha"

      # Re-opening the SAME project keeps one entry and one stable point.
      assert :ok = TaskRegistry.add_recent_project(first_dir, "Alpha")

      assert [%RecentProject{path: ^first_dir, vct_path: ^first_point}] =
               TaskRegistry.list_recent_projects()

      # A DIFFERENT OS path with the same basename is a second mount with a
      # deduplicated (never colliding) point.
      assert :ok = TaskRegistry.add_recent_project(second_dir, "Alpha")

      projects = TaskRegistry.list_recent_projects()
      assert length(projects) == 2
      assert Enum.sort(Enum.map(projects, & &1.path)) == [first_dir, second_dir]

      points = projects |> Enum.map(& &1.vct_path) |> Enum.sort()
      assert points == ["vct:///projects/alpha", "vct:///projects/alpha-2"]
      assert EvoGit.Store.count_projects(store) == 0
    end
  end

  describe "remove_recent_project/1" do
    test "removes by OS path, is idempotent and unresolvable afterwards",
         %{data_dir: data_dir} do
      path = Path.join(data_dir, "removable-#{unique()}")

      assert :ok = TaskRegistry.add_recent_project(path, "Removable")
      assert [%RecentProject{vct_path: vct_path}] = TaskRegistry.list_recent_projects()
      assert {:ok, %Mount{path: ^path}} = VCT.resolve(vct_path)

      assert :ok = TaskRegistry.remove_recent_project(path)
      assert TaskRegistry.list_recent_projects() == []
      assert VCT.resolve(vct_path) == {:error, :not_found}

      # Removing an already-removed (unknown) path stays `:ok`.
      assert :ok = TaskRegistry.remove_recent_project(path)
      assert VCT.mounts() == []
    end
  end

  describe "durability" do
    test "recents survive a TaskRegistry restart over the same VCT",
         %{data_dir: data_dir, store: store, vct: vct, registry: registry} do
      path = Path.join(data_dir, "restart-#{unique()}")
      assert :ok = TaskRegistry.add_recent_project(path, "Restarted")

      assert :ok = stop_supervised(registry)

      start_supervised!(
        Supervisor.child_spec(
          {TaskRegistry, task_store: store, data_dir: data_dir, vct: vct, name: registry},
          id: registry
        )
      )

      assert [%RecentProject{path: ^path, name: "Restarted", vct_path: vct_path}] =
               TaskRegistry.list_recent_projects()

      assert vct_path == "vct:///projects/#{Path.basename(path)}"
    end
  end

  describe "notifications" do
    test "add_recent_project/2 broadcasts {:recent_projects_updated}", %{data_dir: data_dir} do
      Phoenix.PubSub.subscribe(EvoGit.PubSub, "recent_projects")
      drain_recent_projects_messages()

      path = Path.join(data_dir, "broadcast-#{unique()}")
      assert :ok = TaskRegistry.add_recent_project(path, "Broadcast")

      # The topic is shared with every other VCT instance in the run, so this
      # is a targeted positive assertion (no broad refute_receive).
      assert_receive {:recent_projects_updated}, 2_000
    end
  end

  describe "display cap" do
    test "12 projects display as the 10 newest while the VCT retains all 12",
         %{data_dir: data_dir} do
      paths = for i <- 1..12, do: Path.join(data_dir, "cap-#{unique()}-#{i}")
      Enum.each(paths, fn path -> assert :ok = TaskRegistry.add_recent_project(path, nil) end)

      projects = TaskRegistry.list_recent_projects()
      assert length(projects) == 10

      # Newest first: the displayed timestamps are non-increasing.
      displayed_timestamps = Enum.map(projects, & &1.last_opened_at)
      assert %DateTime{} = hd(displayed_timestamps)
      assert displayed_timestamps == Enum.sort(displayed_timestamps, {:desc, DateTime})

      mounts = VCT.mounts()
      assert length(mounts) == 12

      all_paths = MapSet.new(Enum.map(mounts, & &1.path))
      displayed_paths = MapSet.new(Enum.map(projects, & &1.path))
      assert MapSet.subset?(displayed_paths, all_paths)

      # Exactly the TWO oldest mounts fall outside the display window.
      excluded = MapSet.difference(all_paths, displayed_paths)
      assert MapSet.size(excluded) == 2

      oldest_displayed = Enum.min(displayed_timestamps, DateTime)

      excluded_timestamps =
        for mount <- mounts, MapSet.member?(excluded, mount.path), do: mount.last_opened_at

      assert Enum.all?(
               excluded_timestamps,
               &(DateTime.compare(&1, oldest_displayed) in [:lt, :eq])
             )
    end
  end

  ## Helpers

  defp unique, do: System.unique_integer([:positive])

  # A sibling VCT instance may have broadcast on the shared topic between the
  # subscribe and the add; drop those so the assertion below can only be
  # satisfied by THIS add.
  defp drain_recent_projects_messages do
    receive do
      {:recent_projects_updated} -> drain_recent_projects_messages()
    after
      0 -> :ok
    end
  end
end
