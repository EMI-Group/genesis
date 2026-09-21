defmodule EvoGit.Store.Operations.ProjectsTest do
  @moduledoc """
  Tests for `EvoGit.Store.Operations.Projects` — the Ecto port of the project
  CRUD handlers of the raw-SQL `EvoGit.Store` GenServer.

  Every test boots its OWN unnamed dynamic `EvoGit.Repo` instance
  (`EvoGit.Store.Boot.start_dynamic/1`) on a unique tmp database and drives
  the operations through the repo PID — exactly the call shape the wave-2
  store layer will use. Assertions pin the OLD public return shapes
  (`:ok` / struct-or-nil / list / integer) and the REPLACE semantics of the
  old `INSERT OR REPLACE`.

  Self-contained by design (R4a unit contract): no shared test helper files
  beyond `EvoGit.TestSupport.StoreBootLock`, which the boot helper below uses
  to serialize the migration compile across concurrent async modules.
  """

  use ExUnit.Case, async: true

  alias EvoGit.RecentProject
  alias EvoGit.Store.Boot
  alias EvoGit.Store.Operations.Projects, as: Ops
  alias EvoGit.TestSupport.StoreBootLock

  # ── Helpers ──────────────────────────────────────────────────────────────

  # Boots an unnamed dynamic repo on a UNIQUE tmp database (async: true safe)
  # and stops it on test exit. Unlinked: `on_exit/1` runs after the test
  # process exits, and the start_link link would tear the repo down mid-stop.
  defp start_repo!(tag) do
    unique = System.unique_integer([:positive, :monotonic])
    path = Path.join(System.tmp_dir!(), "evogit_r4a_#{tag}_#{unique}.sqlite")

    {:ok, pid} = StoreBootLock.with_boot_lock(fn -> Boot.start_dynamic(path) end)
    Process.unlink(pid)
    on_exit(fn -> if Process.alive?(pid), do: :ok = Boot.stop(pid) end)
    pid
  end

  defp project(path, name, dt \\ ~U[2026-06-26 07:19:44.123Z]) do
    %RecentProject{path: path, name: name, last_opened_at: dt}
  end

  # ── put_project/get_project ──────────────────────────────────────────────

  describe "put_project/2" do
    test "round-trips every field incl. last_opened_at DateTime ↔ ISO" do
      repo = start_repo!(:round_trip)

      assert :ok = Ops.put_project(repo, project("/tmp/myproj", "My Project"))
      assert {:error, :missing_project_path} = Ops.put_project(repo, project(nil, "x"))
      assert {:error, :invalid_project_struct} = Ops.put_project(repo, "not a struct")
      assert Ops.get_project(repo, "/tmp/myproj").name == "My Project"
    end

    test "round-trips a nil last_opened_at" do
      repo = start_repo!(:nil_dt)

      assert :ok =
               Ops.put_project(repo, %RecentProject{path: "/p", name: "P", last_opened_at: nil})

      assert Ops.get_project(repo, "/p").last_opened_at == nil
    end

    test "re-put with the same path REPLACES the row (delete+insert, not append)" do
      repo = start_repo!(:replace)

      :ok = Ops.put_project(repo, project("/p", "Old", ~U[2026-01-01 00:00:00Z]))
      :ok = Ops.put_project(repo, project("/p", "New", ~U[2027-02-02 00:00:00.500Z]))

      assert Ops.count_projects(repo) == 1
      assert Ops.get_project(repo, "/p").name == "New"
      assert Ops.get_project(repo, "/p").last_opened_at == ~U[2027-02-02 00:00:00.500Z]
    end
  end

  describe "get_project/2" do
    test "missing path returns nil (old shape: bare nil, no tuple)" do
      repo = start_repo!(:missing)
      assert Ops.get_project(repo, "/nope") == nil
    end

    test "nil argument never matches a row (NULL never equals under SQL)" do
      repo = start_repo!(:nil_arg)
      :ok = Ops.put_project(repo, project("/p", "P"))
      assert Ops.get_project(repo, nil) == nil
    end
  end

  describe "delete_project/2" do
    test "deletes an existing row" do
      repo = start_repo!(:del_found)
      :ok = Ops.put_project(repo, project("/p", "P"))

      assert :ok = Ops.delete_project(repo, "/p")
      assert Ops.get_project(repo, "/p") == nil
      assert Ops.count_projects(repo) == 0
    end

    test "missing row is still :ok (zero-row delete = success)" do
      repo = start_repo!(:del_missing)
      assert :ok = Ops.delete_project(repo, "/nope")
    end

    test "nil argument is a no-op :ok" do
      repo = start_repo!(:del_nil)
      :ok = Ops.put_project(repo, project("/p", "P"))
      assert :ok = Ops.delete_project(repo, nil)
      assert Ops.count_projects(repo) == 1
    end
  end

  describe "select_all_projects/1" do
    test "returns every row as RecentProject structs (old SQL had no ORDER BY)" do
      repo = start_repo!(:all)

      :ok = Ops.put_project(repo, project("/p1", "P1"))
      :ok = Ops.put_project(repo, project("/p2", "P2"))

      projects = Ops.select_all_projects(repo)
      assert length(projects) == 2
      assert Enum.all?(projects, &match?(%RecentProject{}, &1))
      paths = Enum.map(projects, & &1.path)
      assert "/p1" in paths and "/p2" in paths
    end
  end

  describe "count_projects/1" do
    test "counts rows and reports 0 on an empty database" do
      repo = start_repo!(:count)
      assert Ops.count_projects(repo) == 0
      :ok = Ops.put_project(repo, project("/p", "P"))
      assert Ops.count_projects(repo) == 1
    end
  end

  describe "empty database shapes" do
    test "select_all returns [] and get returns nil" do
      repo = start_repo!(:empty)
      assert Ops.select_all_projects(repo) == []
      assert Ops.get_project(repo, "/any") == nil
      assert Ops.count_projects(repo) == 0
    end
  end

  describe "instance isolation" do
    test "two dynamic instances hold disjoint data (repo pid is the routing key)" do
      repo_a = start_repo!(:iso_a)
      repo_b = start_repo!(:iso_b)

      :ok = Ops.put_project(repo_a, project("/a", "A"))

      assert Ops.count_projects(repo_a) == 1
      assert Ops.count_projects(repo_b) == 0
      assert Ops.select_all_projects(repo_b) == []
    end
  end
end
