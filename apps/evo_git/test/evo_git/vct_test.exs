defmodule EvoGit.VCTTest do
  @moduledoc """
  Isolated-instance tests for the DB-backed Virtual Context Tree mount store.

  Every case starts its OWN `EvoGit.Store` + `EvoGit.VCT` pair (see
  `EvoGit.VCTTest.Helpers`), so the app-global singletons are never touched and
  the module is `async: true`.

  Assertions on shared PubSub topics are EVENTUAL: sibling async tests may
  publish on the same topics, so the cases assert only the messages they need
  and never `refute_receive` broadly.
  """

  use ExUnit.Case, async: true

  import ExUnit.CaptureLog
  import EvoGit.VCTTest.Helpers

  alias EvoGit.VCT
  alias EvoGit.VCT.Mount
  alias EvoGit.VCT.Path, as: VctPath

  @moduletag :tmp_dir

  ## Mounting

  describe "mount/2" do
    test "mounts an absolute path without requiring it to exist", %{tmp_dir: tmp} do
      start_stack(tmp)
      path = Path.join(tmp, "does-not-exist")

      assert {:ok, %Mount{} = mount} = VCT.mount(path, name: "My Project")
      assert mount.point == "vct:///projects/does-not-exist"
      assert mount.path == path
      assert mount.name == "My Project"
      assert mount.kind == "git"
      assert %DateTime{} = mount.last_opened_at
      refute File.exists?(path)
      assert [^mount] = VCT.projects()
    end

    test "rejects a relative, blank or non-binary path", %{tmp_dir: tmp} do
      stack = start_stack(tmp)

      assert {:error, :relative_path} = VCT.mount("relative/dir")
      assert {:error, :invalid_path} = VCT.mount("  ")
      assert {:error, :invalid_path} = VCT.mount(nil)
      assert VCT.projects() == []
      assert EvoGit.Store.list_vct_mounts(stack.store) == []
    end

    test "is idempotent per OS path and keeps the point stable", %{tmp_dir: tmp} do
      start_stack(tmp)
      path = Path.join(tmp, "stable")

      assert {:ok, first} = VCT.mount(path, name: "Stable")
      # A trailing separator is the same OS path.
      assert {:ok, second} = VCT.mount(path <> "/")

      assert second.point == first.point
      assert second.path == path
      # An absent name keeps the previous display name.
      assert second.name == "Stable"
      assert length(VCT.projects()) == 1
    end

    test "refreshes last_opened_at and a non-blank name", %{tmp_dir: tmp} do
      old = ~U[2020-01-01 00:00:00.000Z]
      stack = start_stack(tmp)
      path = Path.join(tmp, "renamed")

      # Seed the mount with an OLD timestamp, then re-mount the same path.
      :ok =
        EvoGit.Store.save_vct_mounts(stack.store, [
          %{
            "point" => "vct:///projects/renamed",
            "path" => path,
            "name" => "First",
            "kind" => "git",
            "last_opened_at" => old
          }
        ])

      stop_vct!(stack)
      stack = restart_stack(tmp, stack)

      assert {:ok, first} = VCT.mount(path)
      assert first.name == "First"
      assert DateTime.compare(first.last_opened_at, old) == :gt

      assert {:ok, second} = VCT.mount(path, name: " Second ")
      assert second.point == first.point
      assert second.name == "Second"

      # A blank name is a no-op, not a rename to "".
      assert {:ok, third} = VCT.mount(path, name: "   ")
      assert third.name == "Second"
      assert length(VCT.projects()) == 1
      # The refresh is persisted, not just in-memory.
      assert [row] = EvoGit.Store.list_vct_mounts(stack.store)
      assert row["name"] == "Second"
      assert row["last_opened_at"] == ms(third.last_opened_at)
    end

    test "dedupes points for different paths sharing a basename", %{tmp_dir: tmp} do
      start_stack(tmp)

      first = dir!(Path.join(tmp, "a/foo"))
      second = dir!(Path.join(tmp, "b/foo"))
      third = dir!(Path.join(tmp, "c/foo"))

      assert {:ok, m1} = VCT.mount(first)
      assert {:ok, m2} = VCT.mount(second)
      assert {:ok, m3} = VCT.mount(third)

      assert m1.point == "vct:///projects/foo"
      assert m2.point == "vct:///projects/foo-2"
      assert m3.point == "vct:///projects/foo-3"
      assert length(VCT.projects()) == 3
    end

    test "mounts survive a server restart (DB-backed table)", %{tmp_dir: tmp} do
      stack = start_stack(tmp)
      path = Path.join(tmp, "persisted")

      assert {:ok, mount} = VCT.mount(path, name: "Persisted")
      stop_vct!(stack)
      restart_stack(tmp, stack)

      assert [loaded] = VCT.projects()
      assert loaded.point == mount.point
      assert loaded.path == mount.path
      assert loaded.name == "Persisted"
      assert ms(loaded.last_opened_at) == ms(mount.last_opened_at)
    end
  end

  describe "re-pointing (portability across machines)" do
    test "re-points a mount whose recorded OS path no longer exists", %{tmp_dir: tmp} do
      start_stack(tmp)

      gone = Path.join(tmp, "machine-a/foo")
      replacement = Path.join(tmp, "machine-b/foo")

      assert {:ok, first} = VCT.mount(gone)
      refute File.exists?(gone)

      assert {:ok, second} = VCT.mount(replacement)

      assert second.point == first.point
      assert second.path == replacement
      assert [mount] = VCT.projects()
      assert mount.point == first.point
      assert mount.path == replacement
    end

    test "does NOT re-point a mount whose OS path still exists", %{tmp_dir: tmp} do
      start_stack(tmp)

      kept = dir!(Path.join(tmp, "machine-a/foo"))
      other = dir!(Path.join(tmp, "machine-b/foo"))

      assert {:ok, first} = VCT.mount(kept)
      assert {:ok, second} = VCT.mount(other)

      assert second.point != first.point
      assert length(VCT.projects()) == 2
    end

    test "does not re-point a mount with a different name", %{tmp_dir: tmp} do
      start_stack(tmp)

      gone = Path.join(tmp, "machine-a/foo")
      replacement = Path.join(tmp, "machine-b/foo")

      assert {:ok, first} = VCT.mount(gone, name: "One")
      assert {:ok, second} = VCT.mount(replacement, name: "Two")

      assert second.point != first.point
      assert length(VCT.projects()) == 2
    end
  end

  ## Lookups and removal

  describe "resolve/1, mount_for_path/1 and vct_path_for/2" do
    test "resolves points and OS paths", %{tmp_dir: tmp} do
      start_stack(tmp)
      path = Path.join(tmp, "proj")

      assert {:ok, mount} = VCT.mount(path)

      assert {:ok, %Mount{point: point}} = VCT.resolve(mount.point)
      assert point == mount.point
      assert {:ok, %Mount{point: ^point}} = VCT.resolve(VctPath.parse!(mount.point))
      assert {:ok, %Mount{point: ^point}} = VCT.resolve(path)

      assert {:error, :not_found} = VCT.resolve("vct:///projects/nope")
      assert {:error, :invalid_point} = VCT.resolve("vct://host/projects/foo")
      assert {:error, :not_found} = VCT.resolve("/definitely/not/mounted")
    end

    test "mount_for_path uses the longest prefix with a path boundary", %{tmp_dir: tmp} do
      start_stack(tmp)

      outer = dir!(Path.join(tmp, "a"))
      inner = dir!(Path.join(tmp, "a/b"))

      assert {:ok, outer_mount} = VCT.mount(outer)
      assert {:ok, inner_mount} = VCT.mount(inner)

      assert %Mount{point: point} = VCT.mount_for_path(outer)
      assert point == outer_mount.point

      assert %Mount{point: point} = VCT.mount_for_path(Path.join(inner, "src/auth"))
      assert point == inner_mount.point

      # "/a/bc" is a SIBLING of "/a/b", not a child: the boundary must hold.
      assert VCT.mount_for_path(Path.join(tmp, "a") <> "bc") == nil
      # Separator-insensitive comparison (Windows-style spelling).
      assert %Mount{point: ^point} = VCT.mount_for_path(String.replace(inner, "/", "\\"))
    end

    test "vct_path_for builds canonical URLs under the containing mount", %{tmp_dir: tmp} do
      start_stack(tmp)
      repo = dir!(Path.join(tmp, "repo"))

      assert {:ok, mount} = VCT.mount(repo)

      assert VCT.vct_path_for(repo, "./") == mount.point
      assert VCT.vct_path_for(repo, "") == mount.point
      assert VCT.vct_path_for(repo, "./src/auth") == mount.point <> "/src/auth"
      assert VCT.vct_path_for(repo, "src/auth") == mount.point <> "/src/auth"
      assert VCT.vct_path_for(repo, "src/auth/") == mount.point <> "/src/auth"

      # Out-of-range / malformed relative paths.
      assert VCT.vct_path_for(repo, "../escape") == nil
      assert VCT.vct_path_for(repo, "./a/../b") == nil
      assert VCT.vct_path_for(repo, Path.join(tmp, "absolute")) == nil

      assert VCT.vct_path_for(Path.join(tmp, "unmounted"), "./") == nil
    end

    test "forget/1 removes by VCT point and by OS path", %{tmp_dir: tmp} do
      stack = start_stack(tmp)

      first = Path.join(tmp, "first")
      second = Path.join(tmp, "second")

      assert {:ok, m1} = VCT.mount(first)
      assert {:ok, m2} = VCT.mount(second)

      assert :ok = VCT.forget(m1.point)
      assert [%Mount{point: remaining}] = VCT.projects()
      assert remaining == m2.point
      assert length(EvoGit.Store.list_vct_mounts(stack.store)) == 1

      assert :ok = VCT.forget(VctPath.parse!(m2.point))
      assert VCT.projects() == []
      assert EvoGit.Store.list_vct_mounts(stack.store) == []

      assert {:ok, m3} = VCT.mount(second)
      assert :ok = VCT.forget(second)
      assert VCT.projects() == []
      assert m3.point == m2.point
    end

    test "forget/1 reports missing or invalid targets", %{tmp_dir: tmp} do
      start_stack(tmp)

      assert {:error, :not_found} = VCT.forget("vct:///projects/absent")
      assert {:error, :not_found} = VCT.forget("/not/mounted")
      assert {:error, :invalid_point} = VCT.forget("vct://host/projects/foo")
    end
  end

  ## Listing and search

  describe "projects/1 and search/2" do
    test "projects/1 is newest first with nil last and honours :limit", %{tmp_dir: tmp} do
      stack = start_stack(tmp)

      :ok =
        EvoGit.Store.save_vct_mounts(stack.store, [
          %{
            "point" => "vct:///projects/alpha",
            "path" => Path.join(tmp, "alpha"),
            "name" => "Alpha",
            "kind" => "git",
            "last_opened_at" => ~U[2020-01-01 00:00:00Z]
          },
          %{
            "point" => "vct:///projects/beta",
            "path" => Path.join(tmp, "beta"),
            "name" => "Beta",
            "kind" => "git",
            "last_opened_at" => nil
          },
          %{
            "point" => "vct:///projects/gamma",
            "path" => Path.join(tmp, "gamma"),
            "name" => "Gamma",
            "kind" => "git",
            "last_opened_at" => ~U[2024-06-01 00:00:00Z]
          }
        ])

      stop_vct!(stack)
      restart_stack(tmp, stack)

      assert points(VCT.projects()) == [
               "vct:///projects/gamma",
               "vct:///projects/alpha",
               "vct:///projects/beta"
             ]

      assert points(VCT.projects(limit: 2)) == [
               "vct:///projects/gamma",
               "vct:///projects/alpha"
             ]

      # The :limit is a projection concern only — every mount is retained.
      assert length(VCT.projects()) == 3
      assert length(VCT.projects(limit: 0)) == 3
    end

    test "search/2 is a case-insensitive substring match over name, path and point",
         %{tmp_dir: tmp} do
      start_stack(tmp)

      assert {:ok, _} = VCT.mount(Path.join(tmp, "AlphaRepo"), name: "First")
      assert {:ok, _} = VCT.mount(Path.join(tmp, "beta"), name: "Second Project")
      assert {:ok, _} = VCT.mount(Path.join(tmp, "gamma"), name: "Third")

      # By name, case-insensitively.
      assert points(VCT.search("first")) == ["vct:///projects/AlphaRepo"]
      assert points(VCT.search("SECOND")) == ["vct:///projects/beta"]
      # By OS path.
      assert points(VCT.search("alpharepo")) == ["vct:///projects/AlphaRepo"]
      # By VCT point.
      assert points(VCT.search("projects/gamma")) == ["vct:///projects/gamma"]

      # A blank query matches everything; a non-binary query matches nothing.
      assert length(VCT.search("")) == 3
      assert length(VCT.search("   ")) == 3
      assert VCT.search(nil) == []
      assert VCT.search(42) == []

      # Newest first, capped by :limit.
      assert length(VCT.search("", limit: 2)) == 2
      assert points(VCT.search("", limit: 1)) == VCT.projects() |> points() |> Enum.take(1)
    end
  end

  ## Reserved (system) mounts

  describe "ensure_mount/3 at a reserved point" do
    test "inserts a reserved mount without requiring the path to exist", %{tmp_dir: tmp} do
      stack = start_stack(tmp)
      path = Path.join(tmp, "genesis-source-does-not-exist")

      assert {:ok, %Mount{} = mount} =
               VCT.ensure_mount("vct:///genesis-source", path, name: "genesis-source")

      assert mount.point == "vct:///genesis-source"
      assert mount.path == path
      assert mount.name == "genesis-source"
      assert mount.kind == "git"
      # A system mount is not "opened": it carries no recency timestamp.
      assert mount.last_opened_at == nil
      refute File.exists?(path)

      # Persisted…
      assert [row] = EvoGit.Store.list_vct_mounts(stack.store)
      assert row["point"] == "vct:///genesis-source"
      assert row["path"] == path
      assert row["last_opened_at"] == nil

      # …but NOT part of the user's project list.
      assert VCT.projects() == []
      assert VCT.search("") == []
    end

    test "is idempotent for the same point and path (no write, no churn)", %{tmp_dir: tmp} do
      old = ~U[2020-01-01 00:00:00.000Z]
      stack = start_stack(tmp)
      path = Path.join(tmp, "source")

      :ok =
        EvoGit.Store.save_vct_mounts(stack.store, [
          %{
            "point" => "vct:///genesis-source",
            "path" => path,
            "name" => "Source",
            "kind" => "git",
            "last_opened_at" => old
          }
        ])

      stop_vct!(stack)
      restart_stack(tmp, stack)

      assert {:ok, first} = VCT.ensure_mount("vct:///genesis-source", path)
      assert first.name == "Source"
      assert ms(first.last_opened_at) == ms(old)

      # A second ensure — even with a trailing separator and a blank name — is a
      # no-op: same mount, unchanged name and timestamp.
      assert {:ok, second} =
               VCT.ensure_mount(VctPath.parse!("vct:///genesis-source"), path <> "/")

      assert second == first
      assert ms(second.last_opened_at) == ms(old)
      assert second.name == "Source"

      # Exactly one row, still at the original timestamp.
      assert [row] = EvoGit.Store.list_vct_mounts(stack.store)
      assert row["point"] == "vct:///genesis-source"
      assert row["name"] == "Source"
      assert row["last_opened_at"] == ms(old)
    end

    test "re-points an existing reserved point to a different path", %{tmp_dir: tmp} do
      stack = start_stack(tmp)
      first_path = Path.join(tmp, "machine-a/source")
      second_path = Path.join(tmp, "machine-b/source")

      assert {:ok, first} = VCT.ensure_mount("vct:///genesis-source", first_path, name: "Source")

      # No supplied name: the previous display name is kept.
      assert {:ok, second} = VCT.ensure_mount("vct:///genesis-source", second_path)
      assert second.point == first.point
      assert second.path == second_path
      assert second.name == "Source"
      assert second.last_opened_at == first.last_opened_at

      # A same-path ensure never renames (no churn)…
      assert {:ok, %Mount{name: "Source"}} =
               VCT.ensure_mount("vct:///genesis-source", second_path, name: " Ignored ")

      # …while a re-point to a new path takes a non-blank name.
      third_path = Path.join(tmp, "machine-c/source")

      assert {:ok, third} =
               VCT.ensure_mount("vct:///genesis-source", third_path, name: " Renamed ")

      assert third.name == "Renamed"
      assert third.path == third_path

      assert [row] = EvoGit.Store.list_vct_mounts(stack.store)
      assert row["point"] == "vct:///genesis-source"
      assert row["path"] == third_path
      assert row["name"] == "Renamed"
    end

    test "moves a mount that the same path holds at another point", %{tmp_dir: tmp} do
      stack = start_stack(tmp)
      path = dir!(Path.join(tmp, "shared-source"))

      assert {:ok, project} = VCT.mount(path, name: "Project")
      assert project.point == "vct:///projects/shared-source"

      assert {:ok, moved} = VCT.ensure_mount("vct:///genesis-source", path)
      assert moved.point == "vct:///genesis-source"
      assert moved.path == path
      assert moved.name == "Project"
      assert ms(moved.last_opened_at) == ms(project.last_opened_at)

      # The project row is gone — one OS path, one row.
      assert VCT.projects() == []
      assert [row] = EvoGit.Store.list_vct_mounts(stack.store)
      assert row["point"] == "vct:///genesis-source"
      assert VCT.resolve(path) == {:ok, moved}
    end

    test "removes a row that already mounts the new path elsewhere", %{tmp_dir: tmp} do
      stack = start_stack(tmp)
      first_path = Path.join(tmp, "first")
      shared = Path.join(tmp, "shared")

      assert {:ok, _} = VCT.ensure_mount("vct:///genesis-source", first_path)
      assert {:ok, other} = VCT.mount(shared)
      assert other.point == "vct:///projects/shared"

      assert {:ok, repointed} = VCT.ensure_mount("vct:///genesis-source", shared)
      assert repointed.point == "vct:///genesis-source"
      assert repointed.path == shared

      points_in_store =
        stack.store |> EvoGit.Store.list_vct_mounts() |> Enum.map(& &1["point"])

      assert points_in_store == ["vct:///genesis-source"]
      assert VCT.projects() == []
    end

    test "rejects an invalid point or path", %{tmp_dir: tmp} do
      start_stack(tmp)
      path = Path.join(tmp, "repo")

      assert {:error, :invalid_point} = VCT.ensure_mount("not-a-vct-url", path)
      assert {:error, :invalid_point} = VCT.ensure_mount("vct://host/genesis-source", path)
      assert {:error, :invalid_point} = VCT.ensure_mount(nil, path)
      assert {:error, :relative_path} = VCT.ensure_mount("vct:///genesis-source", "relative/dir")
      assert {:error, :invalid_path} = VCT.ensure_mount("vct:///genesis-source", "  ")
      assert EvoGit.Store.list_vct_mounts(start_stack(tmp).store) == []
    end
  end

  describe "reserved mounts and the project-facing API" do
    test "projects/1 and search/2 hide them while resolution finds them", %{tmp_dir: tmp} do
      start_stack(tmp)
      source = dir!(Path.join(tmp, "source"))
      project = Path.join(tmp, "project")

      assert {:ok, reserved} = VCT.ensure_mount("vct:///genesis-source", source, name: "Source")
      assert {:ok, project_mount} = VCT.mount(project)

      # Lists/searches see the project only — even a blank search, and even a
      # query that only the reserved mount would match.
      assert points(VCT.projects()) == [project_mount.point]
      assert points(VCT.search("")) == [project_mount.point]
      assert VCT.search("genesis-source") == []
      assert VCT.search("vct:///genesis-source") == []

      # Resolution includes the reserved mount.
      assert {:ok, ^reserved} = VCT.resolve("vct:///genesis-source")
      assert {:ok, ^reserved} = VCT.resolve(source)
      assert %Mount{point: "vct:///genesis-source"} = VCT.mount_for_path(source)

      assert VCT.mount_for_path(Path.join(source, "src/auth")).point == "vct:///genesis-source"
      assert VCT.vct_path_for(source, "./src") == "vct:///genesis-source/src"
      assert VCT.vct_path_for(source, "./") == "vct:///genesis-source"
      # The project mount still wins for paths under it.
      assert VCT.vct_path_for(project, "./src") == project_mount.point <> "/src"
    end

    test "forget/1 refuses a reserved point and its OS path", %{tmp_dir: tmp} do
      stack = start_stack(tmp)
      source = Path.join(tmp, "source")

      assert {:ok, reserved} = VCT.ensure_mount("vct:///genesis-source", source)

      # A reserved POINT is refused whether or not a row exists.
      assert {:error, :reserved_point} = VCT.forget("vct:///genesis-source")
      assert {:error, :reserved_point} = VCT.forget(VctPath.parse!("vct:///genesis-source"))
      assert {:error, :reserved_point} = VCT.forget("vct:///genesis-source/nested")
      assert {:error, :reserved_point} = VCT.forget("vct:///")
      assert {:error, :reserved_point} = VCT.forget("vct:///projects")
      assert {:error, :reserved_point} = VCT.forget("vct:///not-mounted-at-all")

      # …and so is the OS-path form.
      assert {:error, :reserved_point} = VCT.forget(source)

      # The mount survives and is still resolvable, and nothing was persisted away.
      assert VCT.resolve("vct:///genesis-source") == {:ok, reserved}
      assert [row] = EvoGit.Store.list_vct_mounts(stack.store)
      assert row["point"] == "vct:///genesis-source"

      # Project mounts keep today's behaviour.
      assert {:ok, project} = VCT.mount(Path.join(tmp, "project"))
      assert :ok = VCT.forget(project.point)
      assert {:error, :not_found} = VCT.forget("vct:///projects/absent")
      assert {:error, :invalid_point} = VCT.forget("vct://host/projects/foo")
    end
  end

  describe "Table.enforce_cap/2 (pure)" do
    test "caps project mounts only and retains reserved ones" do
      reserved = Mount.new("vct:///genesis-source", "/src/genesis-source", last_opened_at: nil)

      oldest =
        Mount.new("vct:///projects/oldest", "/p/oldest", last_opened_at: ~U[2020-01-01 00:00:00Z])

      middle =
        Mount.new("vct:///projects/middle", "/p/middle", last_opened_at: ~U[2022-01-01 00:00:00Z])

      newest =
        Mount.new("vct:///projects/newest", "/p/newest", last_opened_at: ~U[2024-01-01 00:00:00Z])

      mounts = [oldest, reserved, middle, newest]

      # cap 2 over 3 projects: exactly the oldest project is evicted, the
      # reserved mount survives, and surviving members keep their positions.
      assert EvoGit.VCT.Table.enforce_cap(mounts, 2) == [reserved, middle, newest]
      # A cap at (or above) the project count is a no-op.
      assert EvoGit.VCT.Table.enforce_cap(mounts, 3) == mounts
      assert EvoGit.VCT.Table.enforce_cap(mounts, 10) == mounts
      # Non-positive / non-integer caps leave the list untouched.
      assert EvoGit.VCT.Table.enforce_cap(mounts, 0) == mounts
      assert EvoGit.VCT.Table.enforce_cap(mounts, "many") == mounts
    end

    test "reserved mounts alone never trigger eviction" do
      reserved = [
        Mount.new("vct:///genesis-source", "/src/a"),
        Mount.new("vct:///", "/src/b")
      ]

      assert EvoGit.VCT.Table.enforce_cap(reserved, 1) == reserved
    end
  end

  describe "the :system_mounts init option" do
    test "ensures a host-declared reserved mount at boot", %{tmp_dir: tmp} do
      stack = start_stack(tmp)
      source = Path.join(tmp, "genesis-source")

      # Booted without system mounts first: the table is empty.
      assert VCT.projects() == []

      stop_vct!(stack)

      system_mounts = [
        %{point: "vct:///genesis-source", path: source, name: "genesis-source"},
        %{point: "vct:///extra-system", path: Path.join(tmp, "extra")}
      ]

      restart_stack(tmp, stack, system_mounts: system_mounts)

      assert {:ok, %Mount{} = mount} = VCT.resolve("vct:///genesis-source")
      assert mount.path == source
      assert mount.name == "genesis-source"
      assert {:ok, %Mount{name: "extra"}} = VCT.resolve("vct:///extra-system")

      # Persisted, but invisible to the project list.
      assert stack.store
             |> EvoGit.Store.list_vct_mounts()
             |> Enum.map(& &1["point"])
             |> Enum.sort() ==
               ["vct:///extra-system", "vct:///genesis-source"]

      assert VCT.projects() == []
      assert VCT.search("") == []

      # A SECOND boot with the same list must not duplicate the rows.
      stop_vct!(stack)
      restart_stack(tmp, stack, system_mounts: system_mounts)

      rows = EvoGit.Store.list_vct_mounts(stack.store)
      assert length(rows) == 2
      assert {:ok, %Mount{path: ^source}} = VCT.resolve("vct:///genesis-source")
    end

    test "skips malformed system mounts and never fails boot", %{tmp_dir: tmp} do
      good = Path.join(tmp, "good")

      {stack, log} =
        with_log(fn ->
          start_stack(tmp,
            system_mounts: [
              "garbage",
              %{point: "not-a-vct-url", path: good},
              %{point: "vct:///blank-path", path: "   "},
              %{path: good},
              %{point: "vct:///good", path: good}
            ]
          )
        end)

      assert {:ok, %Mount{path: ^good}} = VCT.resolve("vct:///good")
      assert log =~ "malformed system mount"

      # Only the well-formed entry reached the table (and the store).
      assert stack.store |> EvoGit.Store.list_vct_mounts() |> Enum.map(& &1["point"]) ==
               ["vct:///good"]
    end

    test "defaults to no system mounts", %{tmp_dir: tmp} do
      stack = start_stack(tmp)

      assert VCT.projects() == []
      assert VCT.search("") == []
      assert VCT.resolve("vct:///genesis-source") == {:error, :not_found}
      assert EvoGit.Store.list_vct_mounts(stack.store) == []
    end
  end

  ## Broadcasts

  describe "broadcasts" do
    test "publishes only on \"vct\" for mount, forget and put_global_context", %{tmp_dir: tmp} do
      start_stack(tmp)
      own_node = node()

      Phoenix.PubSub.subscribe(EvoGit.PubSub, "vct")
      Phoenix.PubSub.subscribe(EvoGit.PubSub, "recent_projects")

      path = Path.join(tmp, "broadcast")

      assert {:ok, mount} = VCT.mount(path)
      assert_receive {:vct_updated, ^own_node}, 2_000

      assert :ok = VCT.forget(mount.point)
      assert_receive {:vct_updated, ^own_node}, 2_000

      assert :ok = VCT.put_global_context("# Global context\n")
      assert_receive {:vct_updated, ^own_node}, 2_000

      # Mount mutations publish only `{:vct_updated, node}` on "vct": there is
      # no "recent_projects" topic, so nothing is ever published there (no
      # publisher exists, so this refute cannot observe a sibling test).
      refute_receive {:recent_projects_updated}, 200
    end

    test "does not publish when a mutation fails", %{tmp_dir: tmp} do
      start_stack(tmp)
      own_node = node()

      Phoenix.PubSub.subscribe(EvoGit.PubSub, "vct")

      # Failed mutations are answered BEFORE the broadcast point; drain anything
      # a sibling test published while this one was starting up, then assert the
      # failures themselves add nothing.
      refute_receive {:vct_updated, ^own_node}, 100

      assert {:error, :relative_path} = VCT.mount("relative/dir")
      assert {:error, :not_found} = VCT.forget("vct:///projects/absent")

      refute_receive {:vct_updated, ^own_node}, 100
    end
  end

  ## Degradation

  describe "a store that is unavailable" do
    test "degrades reads and mutations without crashing init", %{tmp_dir: tmp} do
      dead_store = :"vct_dead_store_#{System.unique_integer([:positive])}"

      # init must never crash on a dead store.
      start_stack(tmp, store: dead_store)

      path = Path.join(tmp, "repo")

      assert VCT.projects() == []
      assert VCT.projects(limit: 5) == []
      assert VCT.search("repo") == []
      assert VCT.mount_for_path(path) == nil
      assert VCT.vct_path_for(path, "./src") == nil
      assert VCT.resolve("vct:///projects/foo") == {:error, :not_found}

      assert {:error, :store_unavailable} = VCT.mount(path)
      # A failed persist leaves the in-memory table untouched: nothing was
      # mounted, so a forget finds nothing (and persists nothing).
      assert VCT.projects() == []
      assert {:error, :not_found} = VCT.forget(path)
    end

    test "a dead server degrades every call to its documented empty value", %{tmp_dir: tmp} do
      absent = :"vct_absent_#{System.unique_integer([:positive])}"
      Process.delete(:evogit_vct_server)
      Process.put(:evogit_vct_server, absent)

      assert VCT.projects() == []
      assert VCT.projects(limit: 5) == []
      assert VCT.search("x") == []
      assert VCT.mount_for_path(Path.join(tmp, "repo")) == nil
      assert VCT.vct_path_for(Path.join(tmp, "repo"), "./src") == nil
      assert VCT.resolve("vct:///projects/foo") == {:error, :not_found}
      assert VCT.global_context() == ""
      assert is_binary(VCT.global_context_path())
      assert VCT.mount(Path.join(tmp, "repo")) == {:error, :vct_unavailable}
      assert VCT.forget("vct:///projects/foo") == {:error, :vct_unavailable}
      assert VCT.put_global_context("x") == {:error, :vct_unavailable}

      # Leave the process dictionary clean (the app-global singleton is then
      # resolved again, so nothing else is asserted here).
      Process.delete(:evogit_vct_server)
    end
  end

  ## Global context

  describe "global context" do
    test "is absent and uninitialized before the first write", %{tmp_dir: tmp} do
      vct = start_stack(tmp)

      assert VCT.global_context_path() == Path.join(vct.vct_dir, "CONTEXT.md")
      assert VCT.global_context() == ""
      refute File.exists?(Path.join(vct.vct_dir, ".git"))
    end

    test "writes, lazily initializes git and commits once", %{tmp_dir: tmp} do
      vct = start_stack(tmp)

      assert :ok = VCT.put_global_context("# Global context\n\nBody.\n")
      assert VCT.global_context() == "# Global context\n\nBody.\n"
      assert File.exists?(Path.join(vct.vct_dir, "CONTEXT.md"))
      assert File.exists?(Path.join(vct.vct_dir, ".git"))

      gitignore = File.read!(Path.join(vct.vct_dir, ".gitignore"))
      assert gitignore =~ "*.tmp"

      assert {:ok, head_sha} = EvoGit.Adapters.Git.rev_parse(vct.vct_dir)

      # An identical write stages nothing, so HEAD must not move.
      assert :ok = VCT.put_global_context("# Global context\n\nBody.\n")
      assert {:ok, ^head_sha} = EvoGit.Adapters.Git.rev_parse(vct.vct_dir)

      # A real edit produces a new commit.
      assert :ok = VCT.put_global_context("# Global context\n\nChanged.\n")
      assert {:ok, changed_sha} = EvoGit.Adapters.Git.rev_parse(vct.vct_dir)
      assert changed_sha != head_sha
      assert VCT.global_context() == "# Global context\n\nChanged.\n"
    end

    test "blank content never initializes a repository", %{tmp_dir: tmp} do
      vct = start_stack(tmp)

      assert :ok = VCT.put_global_context("")
      refute File.exists?(Path.join(vct.vct_dir, ".git"))

      assert :ok = VCT.put_global_context("   \n\t\n")
      refute File.exists?(Path.join(vct.vct_dir, ".git"))
      assert VCT.global_context() == "   \n\t\n"
    end

    test "rejects non-binary content", %{tmp_dir: tmp} do
      start_stack(tmp)

      assert {:error, :invalid_content} = VCT.put_global_context(nil)
      assert {:error, :invalid_content} = VCT.put_global_context(123)
    end

    test "syncing a restored global context at boot is idempotent", %{tmp_dir: tmp} do
      data_dir = Path.join(tmp, "restored-#{System.unique_integer([:positive])}")
      vct_dir = Path.join(data_dir, "vct")
      File.mkdir_p!(vct_dir)
      content = "# Restored global context\n\nBody.\n"
      File.write!(Path.join(vct_dir, "CONTEXT.md"), content)

      vct = start_stack(tmp, data_dir: data_dir)

      # Boot created the lazy repository and committed the existing file.
      assert vct.vct_dir == vct_dir
      assert File.exists?(Path.join(vct_dir, ".git"))
      assert {:ok, ""} = EvoGit.Adapters.Git.status(vct_dir)

      assert {:ok, "Update global context"} =
               EvoGit.Adapters.Git.log(vct_dir, ["-1", "--pretty=%s"])

      assert {:ok, committed} = EvoGit.Adapters.Git.show(vct_dir, ["HEAD:CONTEXT.md"])
      assert String.trim(committed) == String.trim(content)

      assert {:ok, first_sha} = EvoGit.Adapters.Git.rev_parse(vct_dir)

      # A second boot over the SAME data dir stages nothing: no new commit.
      stop_vct!(vct)
      restart_stack(tmp, vct)
      assert {:ok, ^first_sha} = EvoGit.Adapters.Git.rev_parse(vct_dir)
      assert {:ok, ""} = EvoGit.Adapters.Git.status(vct_dir)
    end

    test "an absent or blank global context initializes no repository at boot", %{tmp_dir: tmp} do
      absent = start_stack(tmp)
      refute File.exists?(Path.join(absent.vct_dir, ".git"))

      data_dir = Path.join(tmp, "blank-#{System.unique_integer([:positive])}")
      vct_dir = Path.join(data_dir, "vct")
      File.mkdir_p!(vct_dir)
      File.write!(Path.join(vct_dir, "CONTEXT.md"), "   \n\t\n")

      blank = start_stack(tmp, data_dir: data_dir)
      refute File.exists?(Path.join(vct_dir, ".git"))
      assert blank.vct_dir == vct_dir
      assert VCT.global_context() == "   \n\t\n"
    end

    test "a boot-time git failure is logged and never crashes boot", %{tmp_dir: tmp} do
      data_dir = Path.join(tmp, "broken-#{System.unique_integer([:positive])}")
      vct_dir = Path.join(data_dir, "vct")
      File.mkdir_p!(vct_dir)
      File.write!(Path.join(vct_dir, "CONTEXT.md"), "# Restored context\n")
      # A `.git` that is not a usable repository, so every git command fails.
      File.write!(Path.join(vct_dir, ".git"), "not a git repository\n")

      {_stack, log} = with_log(fn -> start_stack(tmp, data_dir: data_dir) end)

      # Boot survived (the instance is up and the file is untouched)...
      assert VCT.projects() == []
      assert VCT.global_context() == "# Restored context\n"
      # ...and the git failure was reported, not raised.
      assert log =~ "global context git sync"
    end
  end

  ## Restart helpers

  defp stop_vct!(%{name: name}) do
    stop_supervised!(name)
    :ok
  end

  # Reboots the SAME store-backed VCT (fresh pid, same store, same data dir),
  # which re-reads the mount table from SQLite exactly like a process restart.
  defp restart_stack(_tmp, %{name: name, data_dir: data_dir, store: store} = stack, opts \\ []) do
    pid =
      start_supervised!(
        Supervisor.child_spec(
          {EvoGit.VCT, Keyword.merge([name: name, data_dir: data_dir, store: store], opts)},
          id: name
        ),
        restart: :temporary
      )

    %{stack | pid: pid}
  end
end

defmodule EvoGit.VCTTest.CapTest do
  @moduledoc """
  Capacity-cap tests for the VCT mount table.

  ## Why this module is `async: false`

  `EvoGit.VCT.max_projects/0` reads the BEAM-global app env key
  `:vct_max_projects` (`Application.get_env(:evo_git, :vct_max_projects)`), and
  the cap is applied inside the VCT server, so there is no per-process seam to
  override. These tests therefore mutate that global configuration and must not
  run alongside any other module that mounts projects — the documented forcing
  global is `:vct_max_projects` (restored in `on_exit/1`).
  """

  use ExUnit.Case, async: false

  import EvoGit.VCTTest.Helpers

  alias EvoGit.VCT

  @moduletag :tmp_dir

  setup do
    previous = Application.get_env(:evo_git, :vct_max_projects)

    on_exit(fn ->
      if previous == nil do
        Application.delete_env(:evo_git, :vct_max_projects)
      else
        Application.put_env(:evo_git, :vct_max_projects, previous)
      end
    end)

    :ok
  end

  test "max_projects/0 reads the app env with a positive-integer guard", %{tmp_dir: tmp} do
    start_stack(tmp)

    assert VCT.max_projects() == 100

    Application.put_env(:evo_git, :vct_max_projects, 7)
    assert VCT.max_projects() == 7

    # Non-positive / non-integer values fall back to the default.
    Application.put_env(:evo_git, :vct_max_projects, 0)
    assert VCT.max_projects() == 100
    Application.put_env(:evo_git, :vct_max_projects, "many")
    assert VCT.max_projects() == 100
  end

  test "mounting beyond the cap evicts the OLDEST mounts", %{tmp_dir: tmp} do
    Application.put_env(:evo_git, :vct_max_projects, 2)
    stack = start_stack(tmp)

    assert {:ok, oldest} = VCT.mount(Path.join(tmp, "oldest"))
    assert {:ok, middle} = VCT.mount(Path.join(tmp, "middle"))
    assert {:ok, newest} = VCT.mount(Path.join(tmp, "newest"))

    assert points(VCT.projects()) == [newest.point, middle.point]
    refute Enum.any?(VCT.projects(), &(&1.point == oldest.point))

    # The eviction is PERSISTED: the store holds exactly the surviving rows.
    assert stack.store |> EvoGit.Store.list_vct_mounts() |> Enum.map(& &1["point"]) |> Enum.sort() ==
             Enum.sort([newest.point, middle.point])
  end
end
