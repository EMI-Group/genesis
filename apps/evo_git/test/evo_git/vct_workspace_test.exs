defmodule EvoGit.VCTWorkspaceTest do
  @moduledoc """
  Isolated-instance tests for the WORKSPACE half of the VCT GenServer surface:
  `create_workspace/3`, `workspaces/1`, `workspace_members/1`,
  `workspaces_for/1`, `workspace_point?/1`, the `:include_workspaces` listing
  option and the bare-name `forget/1` path.

  Every case starts its OWN `EvoGit.Store` + `EvoGit.VCT` + `Phoenix.PubSub`
  stack (see `EvoGit.VCTTest.Helpers`), so the app-global singletons are never
  touched and the module is `async: true`; broadcast assertions subscribe to
  `stack.pubsub`, never to `EvoGit.PubSub`.
  """

  use ExUnit.Case, async: true

  import EvoGit.VCTTest.Helpers

  alias EvoGit.VCT
  alias EvoGit.VCT.Mount
  alias EvoGit.VCT.Path, as: VctPath
  alias EvoGit.VCT.Table

  @moduletag :tmp_dir

  describe "create_workspace/3" do
    test "creates a workspace mount with no OS path and ordered members", %{tmp_dir: tmp} do
      start_stack(tmp)
      a = dir!(Path.join(tmp, "app-a"))
      b = dir!(Path.join(tmp, "app-b"))

      assert {:ok, %Mount{} = workspace} =
               VCT.create_workspace(
                 "Frontend",
                 [
                   %{"point" => "vct:///projects/web"},
                   %{"path" => a},
                   %{"point" => "vct:///projects/api", "path" => b}
                 ],
                 description: "  Web apps  "
               )

      assert workspace.point == "vct:///workspaces/Frontend"
      assert workspace.kind == "workspace"
      assert workspace.path == nil
      assert workspace.name == "Frontend"
      assert workspace.description == "Web apps"
      assert %DateTime{} = workspace.last_opened_at

      assert workspace.members == [
               %{"point" => "vct:///projects/web", "path" => nil},
               %{"point" => nil, "path" => a},
               %{"point" => "vct:///projects/api", "path" => b}
             ]

      assert [^workspace] = VCT.workspaces()
      # A workspace is neither a project nor a reserved mount.
      assert VCT.projects() == []
      refute File.exists?(workspace.point)
    end

    test "derives the point from the slugified name and keeps the display name", %{tmp_dir: tmp} do
      start_stack(tmp)
      name = "Web / App"

      assert {:ok, workspace} = VCT.create_workspace(name, [])

      assert workspace.point == "vct:///workspaces/" <> Table.point_segment(name)
      assert workspace.point == "vct:///workspaces/Web - App"
      assert workspace.name == "Web / App"
      assert workspace.members == []
      assert workspace.description == nil
    end

    test "an empty member list is a valid workspace", %{tmp_dir: tmp} do
      stack = start_stack(tmp)
      assert {:ok, workspace} = VCT.create_workspace("Empty", [])
      assert workspace.members == []
      assert [%Mount{point: point}] = VCT.workspaces()
      assert point == workspace.point
      assert [%{"point" => ^point}] = EvoGit.Store.list_vct_mounts(stack.store)
    end

    test "rejects a blank, non-binary or nil name", %{tmp_dir: tmp} do
      start_stack(tmp)

      assert VCT.create_workspace("", []) == {:error, :invalid_name}
      assert VCT.create_workspace("   ", []) == {:error, :invalid_name}
      assert VCT.create_workspace(nil, []) == {:error, :invalid_name}
      assert VCT.create_workspace(42, []) == {:error, :invalid_name}
      assert VCT.workspaces() == []
    end

    test "propagates member validation errors verbatim", %{tmp_dir: tmp} do
      start_stack(tmp)

      assert VCT.create_workspace("Group", "not-a-list") == {:error, :invalid_members}
      assert VCT.create_workspace("Group", nil) == {:error, :invalid_members}

      assert VCT.create_workspace("Group", [%{"point" => "not a point"}]) ==
               {:error, {:invalid_member, %{"point" => "not a point"}}}

      assert VCT.create_workspace("Group", [%{"path" => "relative/dir"}]) ==
               {:error, {:invalid_member, %{"path" => "relative/dir"}}}

      assert VCT.create_workspace("Group", [%{}]) == {:error, {:invalid_member, %{}}}
      assert VCT.workspaces() == []
    end

    test "refuses a workspace as a member (workspaces never nest)", %{tmp_dir: tmp} do
      start_stack(tmp)
      assert {:ok, inner} = VCT.create_workspace("Inner", [])

      assert VCT.create_workspace("Outer", [%{"point" => inner.point}]) ==
               {:error, {:member_is_workspace, inner.point}}

      assert {:ok, workspace} = VCT.create_workspace("Outer", [%{"path" => "/some/where"}])
      assert workspace.members == [%{"point" => nil, "path" => "/some/where"}]

      assert Enum.map(VCT.workspaces(), & &1.point) |> Enum.sort() ==
               Enum.sort([inner.point, workspace.point])
    end

    test "re-creating the same name is an idempotent upsert with ONE broadcast per write",
         %{tmp_dir: tmp} do
      stack = start_stack(tmp)
      :ok = Phoenix.PubSub.subscribe(stack.pubsub, "vct")
      a = dir!(Path.join(tmp, "a"))
      b = dir!(Path.join(tmp, "b"))

      assert {:ok, first} = VCT.create_workspace("Apps", [%{"path" => a}], description: "one")
      assert_receive {:vct_updated, node}, 500
      assert node == node()

      assert {:ok, second} = VCT.create_workspace("Apps", [%{"path" => b}], description: "two")

      assert second.point == first.point
      assert second.description == "two"
      assert second.members == [%{"point" => nil, "path" => b}]
      assert DateTime.compare(second.last_opened_at, first.last_opened_at) in [:gt, :eq]

      assert [only] = VCT.workspaces()
      assert only.point == first.point
      assert only.members == [%{"point" => nil, "path" => b}]

      # Exactly ONE broadcast for the second (real) mutation, and ONE row.
      assert_receive {:vct_updated, _node}, 500
      refute_receive {:vct_updated, _node}, 150
      assert [%{"point" => point}] = EvoGit.Store.list_vct_mounts(stack.store)
      assert point == first.point
    end
  end

  describe "workspace_members/1" do
    test "resolves point-only, path-only and point-first members in stored order",
         %{tmp_dir: tmp} do
      start_stack(tmp)
      a = dir!(Path.join(tmp, "app-a"))
      b = dir!(Path.join(tmp, "app-b"))
      {:ok, app_a} = VCT.mount(a)
      {:ok, app_b} = VCT.mount(b)

      assert {:ok, workspace} =
               VCT.create_workspace("Mixed", [
                 %{"path" => a},
                 %{"point" => app_b.point},
                 # A stale path next to a valid point: the POINT wins.
                 %{"point" => app_a.point, "path" => b},
                 %{"point" => "vct:///projects/never-existed"}
               ])

      assert {:ok, resolution} = VCT.workspace_members(workspace.point)
      assert resolution.workspace.point == workspace.point

      assert Enum.map(resolution.members, & &1.point) ==
               [app_a.point, app_b.point, app_a.point]

      assert resolution.missing == [%{"point" => "vct:///projects/never-existed", "path" => nil}]
      assert resolution.nested == []

      # The same workspace by BARE name.
      assert {:ok, ^resolution} = VCT.workspace_members("Mixed")
    end

    test "a member whose target was forgotten becomes missing, in stored order",
         %{tmp_dir: tmp} do
      start_stack(tmp)
      a = dir!(Path.join(tmp, "app-a"))
      b = dir!(Path.join(tmp, "app-b"))
      {:ok, app_a} = VCT.mount(a)
      {:ok, app_b} = VCT.mount(b)

      assert {:ok, workspace} =
               VCT.create_workspace("Mixed", [
                 %{"path" => a},
                 %{"point" => app_b.point},
                 %{"point" => app_a.point}
               ])

      assert :ok = VCT.forget(app_b.point)
      assert {:ok, resolution} = VCT.workspace_members(workspace.point)
      assert Enum.map(resolution.members, & &1.point) == [app_a.point, app_a.point]

      assert resolution.missing == [%{"point" => app_b.point, "path" => nil}]
    end

    test "reports a legacy nested-workspace member as nested instead of expanding it",
         %{tmp_dir: tmp} do
      stack = start_stack(tmp)
      assert {:ok, inner} = VCT.create_workspace("Inner", [])

      # A nested-member row cannot come from `create_workspace/3` (it refuses a
      # workspace point), so it is written STRAIGHT INTO THE STORE — a
      # hand-written/legacy/corrupted row. Loading is LENIENT and keeps it
      # (`Mount.from_map/1` preserves members as stored), so the honest
      # end-to-end path proves resolution reports the ref instead of the loader
      # dropping the whole workspace.
      nested = %{
        Mount.new("vct:///workspaces/Outer", nil,
          kind: "workspace",
          last_opened_at: ~U[2026-01-02 00:00:00Z]
        )
        | members: [%{"point" => inner.point, "path" => nil}]
      }

      :ok = EvoGit.Store.save_vct_mounts(stack.store, [Mount.to_map(inner), Mount.to_map(nested)])

      restart_vct!(stack)

      assert {:ok, resolution} = VCT.workspace_members("Outer")
      assert resolution.workspace.point == "vct:///workspaces/Outer"
      assert resolution.nested == [%{"point" => inner.point, "path" => nil}]
      assert resolution.members == []
      assert resolution.missing == []
    end

    test "reports an unusable stored member as missing instead of dropping the workspace",
         %{tmp_dir: tmp} do
      stack = start_stack(tmp)

      # A relative member path is refused by the creation validator, so the row
      # is written directly — the same leniency rule as the nested case: the
      # resolution, not the loader, decides that a ref resolves to nothing.
      broken = %{
        Mount.new("vct:///workspaces/Broken", nil,
          kind: "workspace",
          last_opened_at: ~U[2026-01-02 00:00:00Z]
        )
        | members: [%{"point" => nil, "path" => "relative/path"}]
      }

      :ok = EvoGit.Store.save_vct_mounts(stack.store, [Mount.to_map(broken)])

      restart_vct!(stack)

      assert {:ok, resolution} = VCT.workspace_members("Broken")
      assert resolution.workspace.point == "vct:///workspaces/Broken"
      assert resolution.nested == []
      assert resolution.members == []
      assert resolution.missing == [%{"point" => nil, "path" => "relative/path"}]
    end

    test "rejects non-workspace points, garbage and OS paths", %{tmp_dir: tmp} do
      start_stack(tmp)
      a = dir!(Path.join(tmp, "app-a"))
      {:ok, app_a} = VCT.mount(a)

      assert {:error, :not_a_workspace} = VCT.workspace_members(app_a.point)

      assert {:error, :not_a_workspace} =
               VCT.workspace_members(%VctPath{segments: ["projects", "app-a"]})

      assert {:error, :not_found} = VCT.workspace_members("vct:///workspaces/ghost")
      assert {:error, :not_found} = VCT.workspace_members("vct:///projects/ghost")
      assert {:error, :not_found} = VCT.workspace_members("Ghost")
      assert {:error, :invalid_point} = VCT.workspace_members("vct://")
      assert {:error, :invalid_point} = VCT.workspace_members(a)
      assert {:error, :invalid_point} = VCT.workspace_members(nil)
      assert {:error, :invalid_point} = VCT.workspace_members(42)
      assert {:error, :invalid_point} = VCT.workspace_members(%{})
    end
  end

  describe "workspaces_for/1" do
    test "matches a project by point, bare name and absolute OS path", %{tmp_dir: tmp} do
      start_stack(tmp)
      a = dir!(Path.join(tmp, "app-a"))
      {:ok, app_a} = VCT.mount(a)
      assert app_a.point == "vct:///projects/app-a"

      assert {:ok, frontend} =
               VCT.create_workspace("Frontend", [%{"point" => app_a.point, "path" => a}])

      assert {:ok, _backend} =
               VCT.create_workspace("Backend", [%{"point" => "vct:///projects/api"}])

      for project <- [app_a.point, VctPath.parse!(app_a.point), "app-a", a, a <> "/"] do
        assert [%Mount{point: point}] = VCT.workspaces_for(project)
        assert point == frontend.point
      end

      assert VCT.workspaces_for("vct:///projects/api") |> Enum.map(& &1.point) ==
               ["vct:///workspaces/Backend"]

      # A project in no workspace, and nothing usable at all.
      assert VCT.workspaces_for("vct:///projects/orphan") == []
      assert VCT.workspaces_for(Path.join(tmp, "unmounted")) == []
      assert VCT.workspaces_for(nil) == []
      assert VCT.workspaces_for(42) == []
      assert VCT.workspaces_for("") == []
      assert VCT.workspaces_for("vct://") == []
    end

    test "answers newest first and keeps membership through the member's mount",
         %{tmp_dir: tmp} do
      start_stack(tmp)
      a = dir!(Path.join(tmp, "app-a"))
      {:ok, app_a} = VCT.mount(a)

      assert {:ok, early} = VCT.create_workspace("Early", [%{"path" => a}])
      assert [%Mount{point: point}] = VCT.workspaces_for(app_a.point)
      assert point == early.point

      assert {:ok, late} = VCT.create_workspace("Late", [%{"path" => a}])
      assert Enum.map(VCT.workspaces_for(app_a.point), & &1.point) == [late.point, early.point]
      assert Enum.map(VCT.workspaces_for(a), & &1.point) == [late.point, early.point]

      # Membership is METADATA, never a filesystem probe: forgetting the mount
      # does not drop the workspace from the OS-path spelling of the project …
      assert :ok = VCT.forget(app_a.point)
      assert Enum.map(VCT.workspaces_for(a), & &1.point) == [late.point, early.point]

      # … while the POINT spelling now resolves to no OS path (nothing is
      # mounted there any more), so it no longer enriches to the same project.
      assert VCT.workspaces_for(app_a.point) == []

      # An unrelated path still matches nothing.
      assert VCT.workspaces_for(Path.join(tmp, "elsewhere")) == []
    end
  end

  describe "projects/1 and search/2 :include_workspaces" do
    test "default listing excludes workspaces; the option merges them by recency",
         %{tmp_dir: tmp} do
      start_stack(tmp)
      a = dir!(Path.join(tmp, "alpha"))
      {:ok, alpha} = VCT.mount(a)
      {:ok, workspace} = VCT.create_workspace("Frontend group", [%{"path" => a}])

      assert [%Mount{point: point}] = VCT.projects()
      assert point == alpha.point
      assert VCT.projects(limit: 5) |> Enum.map(& &1.point) == [alpha.point]

      assert [%Mount{point: first}, %Mount{point: second}] =
               VCT.projects(include_workspaces: true)

      assert first == workspace.point
      assert second == alpha.point

      # `:limit` applies AFTER the merge.
      assert [%Mount{point: ^first}] = VCT.projects(include_workspaces: true, limit: 1)

      # Search: excluded by default, matched by name/point when included.
      assert VCT.search("group") == []
      assert [%Mount{point: ^first}] = VCT.search("group", include_workspaces: true)
      assert [%Mount{point: ^first}] = VCT.search("workspaces/front", include_workspaces: true)

      # A blank query returns BOTH kinds, and still only projects by default.
      assert length(VCT.search("", include_workspaces: true)) == 2
      assert length(VCT.search("", [])) == 1
      assert length(VCT.search("alpha", include_workspaces: true)) == 1
      assert VCT.search(42, include_workspaces: true) == []
    end
  end

  describe "forget/1" do
    test "removes a workspace by point or bare name", %{tmp_dir: tmp} do
      stack = start_stack(tmp)
      assert {:ok, workspace} = VCT.create_workspace("Frontend", [])

      assert :ok = VCT.forget(workspace.point)
      assert VCT.workspaces() == []
      assert {:error, :not_found} = VCT.forget(workspace.point)
      assert EvoGit.Store.list_vct_mounts(stack.store) == []

      assert {:ok, second} = VCT.create_workspace("Backend", [])

      assert :ok = VCT.forget("Backend")
      assert VCT.workspaces() == []
      assert {:error, :not_found} = VCT.forget("Backend")
      assert {:error, :not_found} = VCT.forget(second.point)
      assert EvoGit.Store.list_vct_mounts(stack.store) == []
    end

    test "still refuses a reserved point, with or without a row", %{tmp_dir: tmp} do
      start_stack(tmp)

      assert {:error, :reserved_point} = VCT.forget("vct:///genesis-source")
      assert {:error, :reserved_point} = VCT.forget(VctPath.parse!("vct:///"))

      assert {:ok, _mount} = VCT.ensure_mount("vct:///genesis-source", Path.join(tmp, "source"))
      assert {:error, :reserved_point} = VCT.forget("vct:///genesis-source")
      assert {:ok, %Mount{}} = VCT.resolve("vct:///genesis-source")
    end
  end

  describe "workspace_point?/1" do
    # NO stack: the predicate is pure, so it must not need a running VCT.
    test "delegates totally, without the process" do
      refute Process.get(:evogit_vct_server)

      assert VCT.workspace_point?("vct:///workspaces/frontend")
      assert VCT.workspace_point?("vct:///workspaces/frontend/")
      assert VCT.workspace_point?(%VctPath{segments: ["workspaces", "frontend"]})

      refute VCT.workspace_point?("vct:///projects/foo")
      refute VCT.workspace_point?("vct:///genesis-source")
      refute VCT.workspace_point?("vct:///workspaces")
      refute VCT.workspace_point?("not a point")
      refute VCT.workspace_point?(nil)
      refute VCT.workspace_point?(42)
    end
  end

  describe "persistence" do
    test "a workspace round-trips through the store across a restart", %{tmp_dir: tmp} do
      stack = start_stack(tmp)
      a = dir!(Path.join(tmp, "app-a"))

      assert {:ok, workspace} =
               VCT.create_workspace(
                 "Group",
                 [%{"path" => a}, %{"point" => "vct:///projects/app-a"}],
                 description: "Docs"
               )

      restart_vct!(stack)

      assert [%Mount{point: point} = loaded] = VCT.workspaces()
      assert point == workspace.point
      assert loaded.name == "Group"
      assert loaded.kind == "workspace"
      assert loaded.path == nil
      assert loaded.description == "Docs"
      assert ms(loaded.last_opened_at) == ms(workspace.last_opened_at)

      assert loaded.members == [
               %{"point" => nil, "path" => a},
               %{"point" => "vct:///projects/app-a", "path" => nil}
             ]

      assert {:ok, %{members: [], missing: missing, nested: []}} =
               VCT.workspace_members("Group")

      assert missing == loaded.members
    end
  end

  describe "coexistence with git mounts" do
    test "a workspace never owns an OS path or shadows a git mount", %{tmp_dir: tmp} do
      start_stack(tmp)
      root = dir!(Path.join(tmp, "repo"))
      {:ok, repo} = VCT.mount(root, name: "Repo")
      {:ok, workspace} = VCT.create_workspace("Group", [%{"path" => root}])

      assert [%Mount{point: point}] = VCT.projects()
      assert point == repo.point

      assert %Mount{point: ^point, kind: "git"} = VCT.mount_for_path(Path.join(root, "src/auth"))
      assert VCT.vct_path_for(root, "./src") == repo.point <> "/src"

      # `resolve/1` answers the workspace for its POINT and the git mount for
      # its OS path — a workspace is never an OS-path owner.
      assert {:ok, %Mount{kind: "workspace"}} = VCT.resolve(workspace.point)
      assert {:ok, %Mount{point: ^point, kind: "git"}} = VCT.resolve(root)

      # Removing the git mount leaves the workspace with no path to answer with.
      assert :ok = VCT.forget(repo.point)
      assert VCT.projects() == []
      assert [%Mount{point: workspace_point}] = VCT.workspaces()
      assert workspace_point == workspace.point
      assert VCT.mount_for_path(root) == nil
      assert VCT.mount_for_path(Path.join(root, "src/auth")) == nil
      assert VCT.vct_path_for(root, "./src") == nil
      assert {:ok, %Mount{point: ^workspace_point}} = VCT.resolve(workspace_point)
      assert {:error, :not_found} = VCT.resolve(root)
    end
  end

  # Restarts the stack's VCT so its read cache reloads from the store. Returns
  # the NEW server pid (the previous one is dead).
  defp restart_vct!(stack) do
    :ok = ExUnit.Callbacks.stop_supervised(stack.name)

    pid =
      ExUnit.Callbacks.start_supervised!(
        {EvoGit.VCT,
         name: stack.name, data_dir: stack.data_dir, store: stack.store, pubsub: stack.pubsub},
        id: stack.name
      )

    Process.put(:evogit_vct_server, stack.name)
    pid
  end
end
