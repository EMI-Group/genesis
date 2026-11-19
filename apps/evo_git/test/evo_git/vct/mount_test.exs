defmodule EvoGit.VCT.MountTest do
  @moduledoc """
  Pure, BEAM-global-free: exercises the mount value object only (workspace
  mounts added beside the unchanged `"git"` kind), so `async: true`.
  """
  use ExUnit.Case, async: true

  alias EvoGit.VCT.Mount

  @workspace_point "vct:///workspaces/frontend"

  describe "new/3 — git mounts (unchanged)" do
    test "builds a git mount from a point and an absolute path" do
      mount = Mount.new("vct:///projects/foo", "/src/foo")

      assert %Mount{} = mount
      assert mount.point == "vct:///projects/foo"
      assert mount.path == "/src/foo"
      assert mount.name == "foo"
      assert mount.kind == "git"
      assert Mount.git?(mount)
      refute Mount.workspace?(mount)
      assert mount.members == []
      assert mount.description == nil
    end

    test "accepts a %Path{}, a name and an explicit timestamp" do
      now = ~U[2026-01-02 03:04:05Z]

      mount =
        Mount.new(EvoGit.VCT.Path.parse!("vct:///projects/foo/"), "/src/foo",
          name: "Foo",
          last_opened_at: now
        )

      assert mount.point == "vct:///projects/foo"
      assert mount.name == "Foo"
      assert mount.last_opened_at == now
    end

    test "raises without a non-empty path" do
      for path <- [nil, "", 123] do
        assert_raise ArgumentError, ~r/invalid VCT mount path/, fn ->
          Mount.new("vct:///projects/foo", path)
        end
      end
    end

    test "raises on an invalid point" do
      assert_raise ArgumentError, ~r/invalid VCT URL/, fn ->
        Mount.new("nope", "/src/foo")
      end
    end

    test "raises for a workspace point used as a git mount" do
      assert_raise ArgumentError, ~r/workspace point is never a file mount/, fn ->
        Mount.new(@workspace_point, "/src/foo")
      end
    end
  end

  describe "new/3 — workspace mounts" do
    test "builds a path-less workspace with ordered members and a description" do
      members = [
        %{"point" => "vct:///projects/foo"},
        %{path: "/src/bar/"}
      ]

      mount =
        Mount.new(@workspace_point, nil,
          kind: "workspace",
          members: members,
          description: "Two repos, one feature",
          last_opened_at: ~U[2026-02-03 00:00:00Z]
        )

      assert mount.point == @workspace_point
      assert mount.path == nil
      assert mount.kind == "workspace"
      assert Mount.workspace?(mount)
      refute Mount.git?(mount)
      assert mount.name == "frontend"
      assert mount.description == "Two repos, one feature"
      assert mount.last_opened_at == ~U[2026-02-03 00:00:00Z]

      assert mount.members == [
               %{"point" => "vct:///projects/foo", "path" => nil},
               %{"point" => nil, "path" => "/src/bar"}
             ]
    end

    test "defaults members to [] and description to nil" do
      mount = Mount.new(@workspace_point, nil, kind: "workspace")

      assert mount.members == []
      assert mount.description == nil
      assert %DateTime{} = mount.last_opened_at
    end

    test "keeps a member order that differs from the alphabetical one" do
      mount =
        Mount.new(@workspace_point, nil,
          kind: "workspace",
          members: [%{path: "/z/last"}, %{path: "/a/first"}, %{point: "vct:///projects/m"}]
        )

      assert Enum.map(mount.members, &(&1["path"] || &1["point"])) ==
               ["/z/last", "/a/first", "vct:///projects/m"]
    end

    test "raises when a workspace carries an OS path" do
      assert_raise ArgumentError, ~r/invalid VCT workspace path/, fn ->
        Mount.new(@workspace_point, "/src/foo", kind: "workspace")
      end
    end

    test "raises for a non-workspace point" do
      for point <- ["vct:///projects/foo", "vct:///workspaces", "vct:///genesis-source"] do
        assert_raise ArgumentError, ~r/invalid VCT workspace point/, fn ->
          Mount.new(point, nil, kind: "workspace")
        end
      end
    end

    test "raises with a descriptive message on an invalid member" do
      assert_raise ArgumentError, ~r/workspaces never nest/, fn ->
        Mount.new(@workspace_point, nil,
          kind: "workspace",
          members: [%{point: "vct:///workspaces/other"}]
        )
      end

      assert_raise ArgumentError, ~r/invalid VCT workspace member/, fn ->
        Mount.new(@workspace_point, nil, kind: "workspace", members: [%{path: "relative/path"}])
      end

      assert_raise ArgumentError, ~r/invalid VCT workspace members/, fn ->
        Mount.new(@workspace_point, nil, kind: "workspace", members: :nope)
      end
    end
  end

  describe "normalize_members/1" do
    test "normalizes point-only, path-only and both-key members" do
      assert Mount.normalize_members([
               %{"point" => "vct:///projects/foo"},
               %{"path" => "/src/bar"},
               %{"point" => "vct:///projects/baz", "path" => "/src/qux"}
             ]) ==
               {:ok,
                [
                  %{"point" => "vct:///projects/foo", "path" => nil},
                  %{"point" => nil, "path" => "/src/bar"},
                  %{"point" => "vct:///projects/baz", "path" => "/src/qux"}
                ]}
    end

    test "accepts atom-keyed members" do
      assert {:ok, [%{"point" => "vct:///projects/foo", "path" => nil}]} =
               Mount.normalize_members([%{point: "vct:///projects/foo"}])

      assert {:ok, [%{"point" => nil, "path" => "/src/bar"}]} =
               Mount.normalize_members([%{path: "/src/bar"}])
    end

    test "canonicalizes the point and normalizes the path" do
      assert {:ok, [member]} =
               Mount.normalize_members([
                 %{point: "vct:////projects//foo/", path: "  /src/bar///  "}
               ])

      assert member == %{"point" => "vct:///projects/foo", "path" => "/src/bar"}
    end

    test "preserves order and does not collapse duplicates" do
      assert {:ok, members} =
               Mount.normalize_members([
                 %{path: "/z"},
                 %{path: "/z"},
                 %{path: "/a"}
               ])

      assert members == [
               %{"point" => nil, "path" => "/z"},
               %{"point" => nil, "path" => "/z"},
               %{"point" => nil, "path" => "/a"}
             ]
    end

    test "accepts an empty list and a %Path{} point" do
      assert Mount.normalize_members([]) == {:ok, []}

      assert {:ok, [%{"point" => "vct:///projects/foo", "path" => nil}]} =
               Mount.normalize_members([%{point: EvoGit.VCT.Path.parse!("vct:///projects/foo")}])
    end

    test "tolerates an unmounted member (existence is never required)" do
      assert {:ok, [%{"point" => nil, "path" => "/does/not/exist"}]} =
               Mount.normalize_members([%{path: "/does/not/exist"}])
    end

    test "refuses a workspace member" do
      assert Mount.normalize_members([%{point: "vct:///workspaces/other"}]) ==
               {:error, {:member_is_workspace, "vct:///workspaces/other"}}

      assert Mount.normalize_members([
               %{path: "/src/ok"},
               %{point: "vct:///workspaces/deep/nested"}
             ]) == {:error, {:member_is_workspace, "vct:///workspaces/deep/nested"}}
    end

    test "refuses an invalid member" do
      relative = %{path: "relative/path"}
      blank = %{path: "  "}
      non_binary = %{path: 42}
      garbage_point = %{point: "not-a-vct-url"}
      empty_map = %{}
      nil_both = %{point: nil, path: nil}

      for ref <- [relative, blank, non_binary, garbage_point, empty_map, nil_both, "nope", nil] do
        assert Mount.normalize_members([ref]) == {:error, {:invalid_member, ref}}
      end
    end

    test "refuses a non-list" do
      assert Mount.normalize_members(nil) == {:error, :invalid_members}

      assert Mount.normalize_members(%{point: "vct:///projects/foo"}) ==
               {:error, :invalid_members}

      assert Mount.normalize_members("/src/foo") == {:error, :invalid_members}
    end
  end

  describe "member/1" do
    test "returns a re-encodable, STRING-keyed, both-keys map" do
      assert Mount.member(%{point: "vct:///projects/foo"}) ==
               {:ok, %{"point" => "vct:///projects/foo", "path" => nil}}

      assert Mount.member(%{"path" => "/src/bar"}) ==
               {:ok, %{"point" => nil, "path" => "/src/bar"}}

      assert {:ok, member} = Mount.member(%{point: "vct:///projects/foo", path: "/src/bar"})
      assert Map.keys(member) |> Enum.sort() == ["path", "point"]
      assert member == %{"point" => "vct:///projects/foo", "path" => "/src/bar"}
    end

    test "is usable on its own output (idempotent)" do
      assert {:ok, member} = Mount.member(%{point: "vct:///projects/foo"})
      assert Mount.member(member) == {:ok, member}
    end

    test "rejects non-maps" do
      assert Mount.member("vct:///projects/foo") ==
               {:error, {:invalid_member, "vct:///projects/foo"}}
    end
  end

  describe "workspace?/1 and git?/1" do
    test "are total predicates over the struct" do
      workspace = Mount.new(@workspace_point, nil, kind: "workspace")
      git = Mount.new("vct:///projects/foo", "/src/foo")

      assert Mount.workspace?(workspace)
      refute Mount.workspace?(git)
      assert Mount.git?(git)
      refute Mount.git?(workspace)

      for other <- [nil, %{}, "vct:///workspaces/frontend", %Mount{kind: "other"}] do
        refute Mount.workspace?(other)
        refute Mount.git?(other)
      end
    end
  end

  describe "from_map/1 and to_map/1" do
    test "round-trips a workspace with a nil path, members and a description" do
      map = %{
        "point" => @workspace_point,
        "path" => nil,
        "name" => "Frontend",
        "kind" => "workspace",
        "last_opened_at" => "2026-03-04T05:06:07Z",
        "members" => [
          %{"point" => "vct:///projects/foo", "path" => nil},
          %{"point" => nil, "path" => "/src/bar"}
        ],
        "description" => "Feature workspace"
      }

      assert {:ok, mount} = Mount.from_map(map)
      assert mount.path == nil
      assert mount.kind == "workspace"
      assert mount.description == "Feature workspace"

      assert mount.members == [
               %{"point" => "vct:///projects/foo", "path" => nil},
               %{"point" => nil, "path" => "/src/bar"}
             ]

      assert %DateTime{} = mount.last_opened_at

      encoded = Mount.to_map(mount)
      assert encoded["path"] == nil
      assert encoded["kind"] == "workspace"
      assert encoded["members"] == mount.members
      assert encoded["description"] == "Feature workspace"
      assert {:ok, ^mount} = Mount.from_map(encoded)
    end

    test "decodes a workspace without path/members/description keys" do
      assert {:ok, mount} =
               Mount.from_map(%{"point" => @workspace_point, "kind" => "workspace"})

      assert mount.path == nil
      assert mount.members == []
      assert mount.description == nil
      assert mount.name == "frontend"
    end

    test "decodes atom-keyed member maps on a workspace row" do
      assert {:ok, mount} =
               Mount.from_map(%{
                 point: @workspace_point,
                 kind: "workspace",
                 members: [%{point: "vct:///projects/foo"}]
               })

      assert mount.members == [%{"point" => "vct:///projects/foo", "path" => nil}]
    end

    test "still decodes an old-style git map without members/description" do
      map = %{
        "point" => "vct:///projects/foo",
        "path" => "/src/foo",
        "name" => "Foo",
        "kind" => "git",
        "last_opened_at" => nil
      }

      assert {:ok, mount} = Mount.from_map(map)
      assert mount.members == []
      assert mount.description == nil
      assert mount.last_opened_at == nil

      encoded = Mount.to_map(mount)
      assert encoded["members"] == []
      assert encoded["description"] == nil
      assert encoded["path"] == "/src/foo"
      assert encoded["last_opened_at"] == nil
      assert {:ok, ^mount} = Mount.from_map(encoded)
    end

    test "an absent path decodes to nil (workspace) but a blank path does not" do
      assert {:ok, %Mount{path: nil}} =
               Mount.from_map(%{"point" => @workspace_point, "kind" => "workspace"})

      assert {:error, :invalid_path} =
               Mount.from_map(%{"point" => @workspace_point, "path" => ""})

      assert {:error, :invalid_path} =
               Mount.from_map(%{"point" => @workspace_point, "path" => 42})
    end

    test "loading PRESERVES a nested or unusable member (only creation refuses it)" do
      # Loading is LENIENT: a hand-written/legacy/corrupted row must survive the
      # store round trip so resolution can report `nested` / `missing`; the
      # strict validator is the CREATION path only.
      nested = %{
        "point" => @workspace_point,
        "kind" => "workspace",
        "members" => [%{"point" => "vct:///workspaces/other", "path" => nil}]
      }

      assert {:ok, %Mount{members: [nested_member]} = mount} = Mount.from_map(nested)
      assert nested_member == %{"point" => "vct:///workspaces/other", "path" => nil}
      assert Mount.to_map(mount)["members"] == [nested_member]
      assert {:ok, ^mount} = Mount.from_map(Mount.to_map(mount))

      unusable = %{
        "point" => @workspace_point,
        "kind" => "workspace",
        "members" => [%{"path" => "relative"}, %{"point" => "not-a-vct-url"}, %{"path" => 42}]
      }

      assert {:ok, %Mount{members: members} = mount} = Mount.from_map(unusable)

      # Values are kept verbatim, not parsed or absolutized; a non-string value
      # is `nil` (a member is always re-encodable as a string-or-nil pair).
      assert members == [
               %{"point" => nil, "path" => "relative"},
               %{"point" => "not-a-vct-url", "path" => nil},
               %{"point" => nil, "path" => nil}
             ]

      assert {:ok, ^mount} = Mount.from_map(Mount.to_map(mount))

      # The strict validator still refuses exactly those refs.
      assert Mount.normalize_members([%{"point" => "vct:///workspaces/other"}]) ==
               {:error, {:member_is_workspace, "vct:///workspaces/other"}}

      assert Mount.normalize_members([%{"path" => "relative"}]) ==
               {:error, {:invalid_member, %{"path" => "relative"}}}

      assert_raise ArgumentError, ~r/workspaces never nest/, fn ->
        Mount.new(@workspace_point, nil,
          kind: "workspace",
          members: [%{"point" => "vct:///workspaces/other"}]
        )
      end
    end

    test "keeps member order and drops only a non-map element" do
      assert {:ok, %Mount{members: members}} =
               Mount.from_map(%{
                 "point" => @workspace_point,
                 "kind" => "workspace",
                 "members" => [
                   %{"path" => "/z/last"},
                   "nope",
                   %{point: "vct:///projects/m"},
                   nil
                 ]
               })

      assert members == [
               %{"point" => nil, "path" => "/z/last"},
               %{"point" => "vct:///projects/m", "path" => nil}
             ]
    end

    test "rejects a non-list members value instead of raising" do
      assert {:error, :invalid_members} =
               Mount.from_map(%{
                 "point" => @workspace_point,
                 "kind" => "workspace",
                 "members" => Jason.encode!([])
               })

      assert {:error, :invalid_members} =
               Mount.from_map(%{
                 "point" => @workspace_point,
                 "kind" => "workspace",
                 "members" => %{"path" => "/src/foo"}
               })
    end

    test "keeps the existing point/kind/last_opened_at leniency" do
      assert {:error, :invalid_point} = Mount.from_map(%{"path" => "/src/foo"})
      assert {:error, :invalid_mount} = Mount.from_map("nope")

      assert {:ok, %Mount{last_opened_at: nil, kind: "git"}} =
               Mount.from_map(%{
                 "point" => "vct:///projects/foo",
                 "path" => "/p",
                 "last_opened_at" => "not-a-date"
               })
    end
  end
end
