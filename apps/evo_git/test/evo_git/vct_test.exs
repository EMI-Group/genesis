defmodule EvoGit.VCTTest do
  @moduledoc """
  Isolated-instance tests for the Virtual Context Tree mount store.

  Every case starts its OWN GenServer with a unique `:name`, `:data_dir` and
  JSON `:path` under this test's `tmp_dir`, then points the CALLING test process
  at it through the `:evogit_vct_server` process-dictionary seam — the
  app-global singleton is never touched, so the module is `async: true`.

  Assertions on shared PubSub topics are EVENTUAL: sibling async tests may
  publish on the same topics, so the cases assert only the messages they need
  and never `refute_receive` broadly.
  """

  use ExUnit.Case, async: true

  import ExUnit.CaptureLog

  alias EvoGit.VCT
  alias EvoGit.VCT.Mount
  alias EvoGit.VCT.Path, as: VctPath
  alias EvoGit.VCT.Persistence

  @moduletag :tmp_dir

  ## Helpers

  defp start_vct(context, opts \\ []) do
    name = :"vct_test_#{System.unique_integer([:positive])}"
    data_dir = Path.join(context.tmp_dir, "data-#{System.unique_integer([:positive])}")

    start_args =
      Keyword.merge([name: name, data_dir: data_dir, legacy_projects: []], opts)

    data_dir = Keyword.fetch!(start_args, :data_dir)
    vct_dir = Path.join(data_dir, "vct")

    Process.put(:evogit_vct_server, name)
    pid = start_supervised!({VCT, start_args}, id: name)

    %{
      name: name,
      pid: pid,
      data_dir: data_dir,
      vct_dir: vct_dir,
      path: Keyword.get(start_args, :path, Path.join(vct_dir, "virtual-tree.json"))
    }
  end

  defp dir!(path) do
    File.mkdir_p!(path)
    path
  end

  ## Registration

  describe "register_project/2" do
    test "registers a mount without requiring the OS path to exist", %{tmp_dir: tmp} do
      start_vct(%{tmp_dir: tmp})
      path = Path.join(tmp, "does-not-exist")

      assert {:ok, %Mount{} = mount} = VCT.register_project(path, "My Project")
      assert mount.point == "vct:///projects/does-not-exist"
      assert mount.path == path
      assert mount.name == "My Project"
      assert mount.kind == "git"
      assert %DateTime{} = mount.last_opened_at
      refute File.exists?(path)
      assert [^mount] = VCT.mounts()
    end

    test "rejects a relative path", %{tmp_dir: tmp} do
      start_vct(%{tmp_dir: tmp})

      assert {:error, :relative_path} = VCT.register_project("relative/dir", nil)
      assert {:error, :invalid_path} = VCT.register_project("  ", nil)
      assert {:error, :invalid_path} = VCT.register_project(nil, nil)
      assert VCT.mounts() == []
    end

    test "is idempotent per OS path and keeps the point stable", %{tmp_dir: tmp} do
      start_vct(%{tmp_dir: tmp})
      path = Path.join(tmp, "stable")

      assert {:ok, first} = VCT.register_project(path, "Stable")
      # A trailing separator is the same OS path.
      assert {:ok, second} = VCT.register_project(path <> "/", nil)

      assert second.point == first.point
      assert second.path == path
      # An absent name keeps the previous display name.
      assert second.name == "Stable"
      assert length(VCT.mounts()) == 1
    end

    test "updates the name when a non-blank name is supplied", %{tmp_dir: tmp} do
      start_vct(%{tmp_dir: tmp})
      path = Path.join(tmp, "renamed")

      assert {:ok, first} = VCT.register_project(path, "First")
      assert {:ok, second} = VCT.register_project(path, " Second ")

      assert second.point == first.point
      assert second.name == "Second"
      # A blank name is a no-op, not a rename to "".
      assert {:ok, third} = VCT.register_project(path, "   ")
      assert third.name == "Second"
      assert length(VCT.mounts()) == 1
    end

    test "dedupes points for different paths sharing a basename", %{tmp_dir: tmp} do
      start_vct(%{tmp_dir: tmp})

      first = dir!(Path.join(tmp, "a/foo"))
      second = dir!(Path.join(tmp, "b/foo"))
      third = dir!(Path.join(tmp, "c/foo"))

      assert {:ok, m1} = VCT.register_project(first, nil)
      assert {:ok, m2} = VCT.register_project(second, nil)
      assert {:ok, m3} = VCT.register_project(third, nil)

      assert m1.point == "vct:///projects/foo"
      assert m2.point == "vct:///projects/foo-2"
      assert m3.point == "vct:///projects/foo-3"
      assert length(VCT.mounts()) == 3
    end
  end

  describe "re-pointing (portability across machines)" do
    test "re-points a mount whose recorded OS path no longer exists", %{tmp_dir: tmp} do
      start_vct(%{tmp_dir: tmp})

      gone = Path.join(tmp, "machine-a/foo")
      replacement = Path.join(tmp, "machine-b/foo")

      assert {:ok, first} = VCT.register_project(gone, nil)
      refute File.exists?(gone)

      assert {:ok, second} = VCT.register_project(replacement, nil)

      assert second.point == first.point
      assert second.path == replacement
      assert [mount] = VCT.mounts()
      assert mount.point == first.point
      assert mount.path == replacement
    end

    test "does NOT re-point a mount whose OS path still exists", %{tmp_dir: tmp} do
      start_vct(%{tmp_dir: tmp})

      kept = dir!(Path.join(tmp, "machine-a/foo"))
      other = dir!(Path.join(tmp, "machine-b/foo"))

      assert {:ok, first} = VCT.register_project(kept, nil)
      assert {:ok, second} = VCT.register_project(other, nil)

      assert second.point != first.point
      assert length(VCT.mounts()) == 2
    end

    test "does not re-point a mount with a different name", %{tmp_dir: tmp} do
      start_vct(%{tmp_dir: tmp})

      gone = Path.join(tmp, "machine-a/foo")
      replacement = Path.join(tmp, "machine-b/foo")

      assert {:ok, first} = VCT.register_project(gone, "One")
      assert {:ok, second} = VCT.register_project(replacement, "Two")

      assert second.point != first.point
      assert length(VCT.mounts()) == 2
    end
  end

  ## Lookups and removal

  describe "resolve/1, mount_for_path/1 and vct_path_for/2" do
    test "resolves points and OS paths", %{tmp_dir: tmp} do
      start_vct(%{tmp_dir: tmp})
      path = Path.join(tmp, "proj")

      assert {:ok, mount} = VCT.register_project(path, nil)

      assert {:ok, %Mount{point: point}} = VCT.resolve(mount.point)
      assert point == mount.point
      assert {:ok, %Mount{point: ^point}} = VCT.resolve(VctPath.parse!(mount.point))
      assert {:ok, %Mount{point: ^point}} = VCT.resolve(path)

      assert {:error, :not_found} = VCT.resolve("vct:///projects/nope")
      assert {:error, :invalid_point} = VCT.resolve("vct://host/projects/foo")
      assert {:error, :not_found} = VCT.resolve("/definitely/not/mounted")
    end

    test "mount_for_path uses the longest prefix with a path boundary", %{tmp_dir: tmp} do
      start_vct(%{tmp_dir: tmp})

      outer = dir!(Path.join(tmp, "a"))
      inner = dir!(Path.join(tmp, "a/b"))

      assert {:ok, outer_mount} = VCT.register_project(outer, nil)
      assert {:ok, inner_mount} = VCT.register_project(inner, nil)

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
      start_vct(%{tmp_dir: tmp})
      repo = dir!(Path.join(tmp, "repo"))

      assert {:ok, mount} = VCT.register_project(repo, nil)

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

    test "removes by VCT point and by OS path", %{tmp_dir: tmp} do
      start_vct(%{tmp_dir: tmp})

      first = Path.join(tmp, "first")
      second = Path.join(tmp, "second")

      assert {:ok, m1} = VCT.register_project(first, nil)
      assert {:ok, m2} = VCT.register_project(second, nil)

      assert :ok = VCT.remove_project(m1.point)
      assert [%Mount{point: remaining}] = VCT.mounts()
      assert remaining == m2.point

      assert :ok = VCT.remove_project(VctPath.parse!(m2.point))
      assert VCT.mounts() == []

      assert {:ok, m3} = VCT.register_project(second, nil)
      assert :ok = VCT.remove_project(second)
      assert VCT.mounts() == []
      assert m3.point == m2.point
    end

    test "removal reports missing or invalid targets", %{tmp_dir: tmp} do
      start_vct(%{tmp_dir: tmp})

      assert {:error, :not_found} = VCT.remove_project("vct:///projects/absent")
      assert {:error, :not_found} = VCT.remove_project("/not/mounted")
      assert {:error, :invalid_point} = VCT.remove_project("vct://host/projects/foo")
    end
  end

  ## Persistence

  describe "persistence" do
    test "round-trips mounts across a server restart", %{tmp_dir: tmp} do
      first = start_vct(%{tmp_dir: tmp})
      path = Path.join(tmp, "persisted")

      assert {:ok, mount} = VCT.register_project(path, "Persisted")
      assert :ok = GenServer.stop(first.pid)

      %{vct_dir: _} = start_vct(%{tmp_dir: tmp}, data_dir: first.data_dir)

      assert [loaded] = VCT.mounts()
      assert loaded.point == mount.point
      assert loaded.path == mount.path
      assert loaded.name == "Persisted"
      assert loaded.last_opened_at == mount.last_opened_at
    end

    test "tolerates a corrupt mount table", %{tmp_dir: tmp} do
      data_dir = Path.join(tmp, "corrupt")
      vct_dir = Path.join(data_dir, "vct")
      File.mkdir_p!(vct_dir)
      File.write!(Path.join(vct_dir, "virtual-tree.json"), "{ this is not json")

      {_context, log} = with_log(fn -> start_vct(%{tmp_dir: tmp}, data_dir: data_dir) end)

      assert VCT.mounts() == []
      assert log =~ "not valid JSON"
    end
  end

  ## Listing

  describe "list_projects/1" do
    test "sorts by recency descending with nil last and honours :limit", %{tmp_dir: tmp} do
      data_dir = Path.join(tmp, "sorted")
      vct_dir = Path.join(data_dir, "vct")
      File.mkdir_p!(vct_dir)

      old = ~U[2020-01-01 00:00:00Z]
      newest = ~U[2024-06-01 00:00:00Z]

      mounts = [
        Mount.new("vct:///projects/alpha", Path.join(tmp, "alpha"),
          name: "Alpha",
          last_opened_at: old
        ),
        Mount.new("vct:///projects/beta", Path.join(tmp, "beta"),
          name: "Beta",
          last_opened_at: nil
        ),
        Mount.new("vct:///projects/gamma", Path.join(tmp, "gamma"),
          name: "Gamma",
          last_opened_at: newest
        )
      ]

      :ok = Persistence.save(Path.join(vct_dir, "virtual-tree.json"), mounts, true)
      start_vct(%{tmp_dir: tmp}, data_dir: data_dir)

      assert Enum.map(VCT.list_projects(), & &1.point) == [
               "vct:///projects/gamma",
               "vct:///projects/alpha",
               "vct:///projects/beta"
             ]

      assert Enum.map(VCT.list_projects(limit: 2), & &1.point) == [
               "vct:///projects/gamma",
               "vct:///projects/alpha"
             ]

      # The :limit is a projection concern only — every mount is retained.
      assert length(VCT.mounts()) == 3
      assert VCT.list_projects(limit: 0) |> length() == 3
    end
  end

  ## Legacy import

  describe "one-time legacy project import" do
    test "imports rows once, preserving names and timestamps", %{tmp_dir: tmp} do
      opened_at = ~U[2021-05-05 12:00:00Z]
      first_path = Path.join(tmp, "legacy-one")
      second_path = Path.join(tmp, "legacy-two")
      third_path = Path.join(tmp, "legacy-three")

      first =
        start_vct(%{tmp_dir: tmp},
          legacy_projects: [
            %{path: first_path, name: "First", last_opened_at: opened_at},
            %EvoGit.RecentProject{path: second_path, name: nil, last_opened_at: nil}
          ]
        )

      assert [imported_first, imported_second] = VCT.mounts()
      assert imported_first.path == first_path
      assert imported_first.name == "First"
      assert imported_first.last_opened_at == opened_at
      assert imported_second.path == second_path
      assert imported_second.name == Path.basename(second_path)
      assert imported_second.last_opened_at == nil

      # A restart with a DIFFERENT injected list must not import again.
      assert :ok = GenServer.stop(first.pid)

      start_vct(%{tmp_dir: tmp},
        data_dir: first.data_dir,
        legacy_projects: [%{path: third_path, name: "Third", last_opened_at: nil}]
      )

      assert length(VCT.mounts()) == 2
      refute Enum.any?(VCT.mounts(), &(&1.path == third_path))
    end

    test "skips rows whose path is not absolute, with a warning", %{tmp_dir: tmp} do
      log =
        capture_log(fn ->
          start_vct(%{tmp_dir: tmp},
            legacy_projects: [
              %{path: "relative/dir", name: "Relative"},
              %{path: Path.join(tmp, "absolute-one"), name: "Absolute"}
            ]
          )
        end)

      assert [mount] = VCT.mounts()
      assert mount.path == Path.join(tmp, "absolute-one")
      assert log =~ "non-absolute"
    end

    test "reads the task store when no legacy rows are injected", %{tmp_dir: tmp} do
      # The default source is the app-global task store; the point of this case
      # is that the boot path is total and never raises.
      start_vct(%{tmp_dir: tmp}, legacy_projects: nil, legacy_projects_fun: fn -> [] end)
      assert VCT.mounts() == []
    end

    test "prefers :legacy_projects_fun over :legacy_projects", %{tmp_dir: tmp} do
      fun_path = Path.join(tmp, "from-fun")
      other_path = Path.join(tmp, "from-list")

      start_vct(%{tmp_dir: tmp},
        legacy_projects: [%{path: other_path, name: "From list"}],
        legacy_projects_fun: fn -> [%{path: fun_path, name: "From fun"}] end
      )

      assert [mount] = VCT.mounts()
      assert mount.path == fun_path
      assert mount.name == "From fun"
    end
  end

  ## Broadcasts

  describe "broadcasts" do
    test "publishes on register, remove and put_global_context", %{tmp_dir: tmp} do
      start_vct(%{tmp_dir: tmp})
      own_node = node()

      Phoenix.PubSub.subscribe(EvoGit.PubSub, "vct")
      Phoenix.PubSub.subscribe(EvoGit.PubSub, "recent_projects")

      path = Path.join(tmp, "broadcast")

      assert {:ok, mount} = VCT.register_project(path, nil)

      assert_receive {:vct_updated, ^own_node}, 2_000
      assert_receive {:recent_projects_updated}, 2_000

      assert :ok = VCT.remove_project(mount.point)
      assert_receive {:vct_updated, ^own_node}, 2_000

      assert :ok = VCT.put_global_context("# Global context\n")
      assert_receive {:vct_updated, ^own_node}, 2_000
    end

    test "does not publish when a mutation fails", %{tmp_dir: tmp} do
      start_vct(%{tmp_dir: tmp})
      own_node = node()

      Phoenix.PubSub.subscribe(EvoGit.PubSub, "vct")

      assert {:error, :relative_path} = VCT.register_project("relative/dir", nil)
      assert {:error, :not_found} = VCT.remove_project("vct:///projects/absent")

      refute_receive {:vct_updated, ^own_node}, 100
    end
  end

  ## Global context

  describe "global context" do
    test "is absent and uninitialized before the first write", %{tmp_dir: tmp} do
      vct = start_vct(%{tmp_dir: tmp})

      assert VCT.global_context_path() == Path.join(vct.vct_dir, "CONTEXT.md")
      assert VCT.global_context() == ""
      refute File.exists?(Path.join(vct.vct_dir, ".git"))
    end

    test "writes, lazily initializes git and commits once", %{tmp_dir: tmp} do
      vct = start_vct(%{tmp_dir: tmp})

      assert :ok = VCT.put_global_context("# Global context\n\nBody.\n")
      assert VCT.global_context() == "# Global context\n\nBody.\n"
      assert File.exists?(Path.join(vct.vct_dir, "CONTEXT.md"))
      assert File.exists?(Path.join(vct.vct_dir, ".git"))

      gitignore = File.read!(Path.join(vct.vct_dir, ".gitignore"))
      assert gitignore =~ "virtual-tree.json"
      assert gitignore =~ "*.tmp"

      assert {:ok, head_sha} = EvoGit.Adapters.Git.rev_parse(vct.vct_dir)

      # The mount table is machine-local: it must never enter history.
      assert {:error, _reason} =
               EvoGit.Adapters.Git.rev_parse(
                 vct.vct_dir,
                 "HEAD:virtual-tree.json"
               )

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
      vct = start_vct(%{tmp_dir: tmp})

      assert :ok = VCT.put_global_context("")
      refute File.exists?(Path.join(vct.vct_dir, ".git"))

      assert :ok = VCT.put_global_context("   \n\t\n")
      refute File.exists?(Path.join(vct.vct_dir, ".git"))
      assert VCT.global_context() == "   \n\t\n"
    end

    test "rejects non-binary content", %{tmp_dir: tmp} do
      start_vct(%{tmp_dir: tmp})

      assert {:error, :invalid_content} = VCT.put_global_context(nil)
      assert {:error, :invalid_content} = VCT.put_global_context(123)
    end

    test "syncing a restored global context at boot is idempotent", %{tmp_dir: tmp} do
      data_dir = Path.join(tmp, "restored-#{System.unique_integer([:positive])}")
      vct_dir = Path.join(data_dir, "vct")
      File.mkdir_p!(vct_dir)
      content = "# Restored global context\n\nBody.\n"
      File.write!(Path.join(vct_dir, "CONTEXT.md"), content)

      vct = start_vct(%{tmp_dir: tmp}, data_dir: data_dir)

      # Boot created the lazy repository and committed the existing file.
      assert vct.vct_dir == vct_dir
      assert File.exists?(Path.join(vct_dir, ".git"))
      assert {:ok, ""} = EvoGit.Adapters.Git.status(vct_dir)

      assert {:ok, "Update global context"} =
               EvoGit.Adapters.Git.log(vct_dir, ["-1", "--pretty=%s"])

      assert {:ok, committed} = EvoGit.Adapters.Git.show(vct_dir, ["HEAD:CONTEXT.md"])
      assert String.trim(committed) == String.trim(content)

      # The machine-local mount table never enters history.
      assert {:error, _reason} = EvoGit.Adapters.Git.rev_parse(vct_dir, "HEAD:virtual-tree.json")

      assert {:ok, first_sha} = EvoGit.Adapters.Git.rev_parse(vct_dir)

      # A second boot over the SAME data dir stages nothing: no new commit.
      start_vct(%{tmp_dir: tmp}, data_dir: data_dir)
      assert {:ok, ^first_sha} = EvoGit.Adapters.Git.rev_parse(vct_dir)
      assert {:ok, ""} = EvoGit.Adapters.Git.status(vct_dir)
    end

    test "an absent or blank global context initializes no repository at boot", %{tmp_dir: tmp} do
      absent = start_vct(%{tmp_dir: tmp})
      refute File.exists?(Path.join(absent.vct_dir, ".git"))

      data_dir = Path.join(tmp, "blank-#{System.unique_integer([:positive])}")
      vct_dir = Path.join(data_dir, "vct")
      File.mkdir_p!(vct_dir)
      File.write!(Path.join(vct_dir, "CONTEXT.md"), "   \n\t\n")

      blank = start_vct(%{tmp_dir: tmp}, data_dir: data_dir)
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

      {_context, log} = with_log(fn -> start_vct(%{tmp_dir: tmp}, data_dir: data_dir) end)

      # Boot survived (the instance is up and the file is untouched)...
      assert VCT.mounts() == []
      assert VCT.global_context() == "# Restored context\n"
      # ...and the git failure was reported, not raised.
      assert log =~ "global context git sync"
    end
  end

  ## Total reads

  describe "total reads without a running server" do
    test "degrade to their documented empty values", %{tmp_dir: tmp} do
      absent = :"vct_absent_#{System.unique_integer([:positive])}"
      Process.delete(:evogit_vct_server)
      Process.put(:evogit_vct_server, absent)

      assert VCT.mounts() == []
      assert VCT.list_projects() == []
      assert VCT.list_projects(limit: 5) == []
      assert VCT.mount_for_path(Path.join(tmp, "repo")) == nil
      assert VCT.vct_path_for(Path.join(tmp, "repo"), "./src") == nil
      assert VCT.resolve("vct:///projects/foo") == {:error, :not_found}
      assert VCT.global_context() == ""
      assert is_binary(VCT.global_context_path())
      assert VCT.register_project(Path.join(tmp, "repo"), nil) == {:error, :vct_unavailable}
      assert VCT.remove_project("vct:///projects/foo") == {:error, :vct_unavailable}
      assert VCT.put_global_context("x") == {:error, :vct_unavailable}

      # Leave the process dictionary clean (the app-global singleton is then
      # resolved again, so nothing else is asserted here).
      Process.delete(:evogit_vct_server)
    end
  end
end
