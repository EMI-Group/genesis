defmodule EvoGit.VCT.PersistenceTest do
  @moduledoc """
  Tmp-dir-isolated: exercises the VCT mount struct and its JSON mount-table
  persistence only (no BEAM-global mutation), so `async: true`.
  """
  use ExUnit.Case, async: true

  import ExUnit.CaptureLog

  alias EvoGit.VCT.Mount
  alias EvoGit.VCT.Persistence

  @moduletag :tmp_dir

  @opened_at ~U[2026-01-02 03:04:05.123456Z]

  defp file(tmp_dir), do: Path.join(tmp_dir, "mounts.json")

  defp mount(tmp_dir, point \\ "vct:///projects/genesis", opts \\ []) do
    Mount.new(point, Path.join(tmp_dir, "genesis"), opts)
  end

  describe "Mount" do
    test "new/3 builds a canonical mount with defaults", %{tmp_dir: tmp_dir} do
      opened_at = DateTime.utc_now()
      mount = Mount.new("vct:////projects//genesis/", Path.join(tmp_dir, "genesis"))

      assert mount.point == "vct:///projects/genesis"
      assert mount.path == Path.join(tmp_dir, "genesis")
      assert mount.name == "genesis"
      assert mount.kind == "git"
      assert %DateTime{} = mount.last_opened_at
      assert DateTime.compare(mount.last_opened_at, opened_at) in [:gt, :eq]
    end

    test "new/3 honours the options", %{tmp_dir: tmp_dir} do
      mount = mount(tmp_dir, "vct:///projects/foo", name: "Foo", last_opened_at: @opened_at)

      assert mount.name == "Foo"
      assert mount.kind == "git"
      assert mount.last_opened_at == @opened_at
    end

    test "new/3 raises on an invalid point or path", %{tmp_dir: tmp_dir} do
      assert_raise ArgumentError, fn -> mount(tmp_dir, "vct://host/foo") end
      assert_raise ArgumentError, fn -> Mount.new("vct:///projects/foo", 123) end
      assert_raise ArgumentError, fn -> Mount.new("vct:///projects/foo", "") end
    end

    test "to_map/1 and from_map/1 round-trip through string-keyed maps", %{tmp_dir: tmp_dir} do
      mount = mount(tmp_dir, "vct:///projects/foo", name: "Foo", last_opened_at: @opened_at)
      map = Mount.to_map(mount)

      assert map == %{
               "point" => "vct:///projects/foo",
               "path" => Path.join(tmp_dir, "genesis"),
               "name" => "Foo",
               "kind" => "git",
               "last_opened_at" => "2026-01-02T03:04:05.123456Z"
             }

      assert {:ok, ^mount} = Mount.from_map(map)
    end

    test "from_map/1 tolerates missing optional fields and atom keys", %{tmp_dir: tmp_dir} do
      path = Path.join(tmp_dir, "genesis")

      assert {:ok, decoded} = Mount.from_map(%{"point" => "vct:///projects/foo", "path" => path})
      assert decoded.name == "genesis"
      assert decoded.kind == "git"
      assert decoded.last_opened_at == nil

      assert {:ok, decoded} =
               Mount.from_map(%{point: "vct:///projects/foo", path: path, kind: "git"})

      assert decoded.point == "vct:///projects/foo"
    end

    test "from_map/1 leaves an unparseable timestamp nil without crashing", %{tmp_dir: tmp_dir} do
      path = Path.join(tmp_dir, "genesis")

      assert {:ok, %Mount{last_opened_at: nil}} =
               Mount.from_map(%{
                 "point" => "vct:///projects/foo",
                 "path" => path,
                 "last_opened_at" => "not-a-date"
               })
    end

    test "from_map/1 returns tagged errors for invalid entries", %{tmp_dir: tmp_dir} do
      path = Path.join(tmp_dir, "genesis")

      assert {:error, :non_local_authority} =
               Mount.from_map(%{"point" => "vct://host/foo", "path" => path})

      assert {:error, :invalid_point} = Mount.from_map(%{"path" => path})
      assert {:error, :invalid_path} = Mount.from_map(%{"point" => "vct:///projects/foo"})
      assert {:error, :invalid_mount} = Mount.from_map("junk")
      assert {:error, :invalid_mount} = Mount.from_map(nil)
    end
  end

  describe "load/1" do
    test "returns the empty state when the file is missing", %{tmp_dir: tmp_dir} do
      assert Persistence.load(file(tmp_dir)) == %{mounts: [], legacy_projects_imported: false}
    end

    test "returns an empty table for an empty mounts list", %{tmp_dir: tmp_dir} do
      assert :ok = Persistence.save(file(tmp_dir), [], false)
      assert Persistence.load(file(tmp_dir)) == %{mounts: [], legacy_projects_imported: false}
    end

    test "round-trips mounts and the legacy flag", %{tmp_dir: tmp_dir} do
      path = file(tmp_dir)

      mounts = [
        mount(tmp_dir, "vct:///projects/foo", name: "Foo", last_opened_at: @opened_at),
        mount(tmp_dir, "vct:///projects/bar", name: "Bar", last_opened_at: @opened_at)
      ]

      assert :ok = Persistence.save(path, mounts, true)

      assert %{mounts: loaded, legacy_projects_imported: true} = Persistence.load(path)
      assert length(loaded) == 2

      assert Enum.map(loaded, & &1.point) == ["vct:///projects/foo", "vct:///projects/bar"]
      assert Enum.map(loaded, & &1.name) == ["Foo", "Bar"]
      assert Enum.all?(loaded, &(&1.kind == "git"))

      # DateTime fidelity through the ISO-8601 encoding.
      assert Enum.all?(loaded, &(&1.last_opened_at == @opened_at))

      assert Enum.all?(
               loaded,
               &(DateTime.to_iso8601(&1.last_opened_at) == "2026-01-02T03:04:05.123456Z")
             )
    end

    test "a nil timestamp round-trips as nil", %{tmp_dir: tmp_dir} do
      path = file(tmp_dir)

      assert :ok =
               Persistence.save(
                 path,
                 [mount(tmp_dir, "vct:///projects/foo", last_opened_at: nil)],
                 false
               )

      assert %{mounts: [loaded], legacy_projects_imported: false} = Persistence.load(path)
      assert loaded.last_opened_at == nil
    end

    test "writes the documented top-level JSON shape", %{tmp_dir: tmp_dir} do
      path = file(tmp_dir)
      assert :ok = Persistence.save(path, [mount(tmp_dir)], true)

      assert {:ok, %{"version" => 1, "legacy_projects_imported" => true, "mounts" => [entry]}} =
               path |> File.read!() |> Jason.decode()

      assert entry["point"] == "vct:///projects/genesis"
    end

    test "corrupt JSON yields the empty state with a warning and does not raise", %{
      tmp_dir: tmp_dir
    } do
      path = file(tmp_dir)
      File.write!(path, "{not json")

      log =
        capture_log(fn ->
          assert Persistence.load(path) == %{mounts: [], legacy_projects_imported: false}
        end)

      assert log =~ "VCT mount table is not valid JSON"
    end

    test "an unexpected top-level shape yields the empty state", %{tmp_dir: tmp_dir} do
      path = file(tmp_dir)
      File.write!(path, Jason.encode!([1, 2, 3]))

      log =
        capture_log(fn ->
          assert Persistence.load(path) == %{mounts: [], legacy_projects_imported: false}
        end)

      assert log =~ "unexpected shape"

      File.write!(path, Jason.encode!(%{"version" => 1}))

      capture_log(fn ->
        assert Persistence.load(path) == %{mounts: [], legacy_projects_imported: false}
      end)
    end

    test "skips invalid mount entries and keeps the valid ones", %{tmp_dir: tmp_dir} do
      path = file(tmp_dir)
      valid = Mount.to_map(mount(tmp_dir, "vct:///projects/foo", name: "Foo"))

      payload = %{
        "version" => 1,
        "legacy_projects_imported" => false,
        "mounts" => [
          valid,
          %{"point" => "vct://host/remote", "path" => "/remote"},
          %{"path" => "/missing-point"},
          "junk"
        ]
      }

      File.write!(path, Jason.encode!(payload))

      log =
        capture_log(fn ->
          assert %{mounts: [loaded], legacy_projects_imported: false} = Persistence.load(path)
          assert loaded.point == "vct:///projects/foo"
          assert loaded.name == "Foo"
        end)

      assert log =~ "Skipping invalid VCT mount entry"
    end

    test "a non-boolean legacy flag decodes as false", %{tmp_dir: tmp_dir} do
      path = file(tmp_dir)
      File.write!(path, Jason.encode!(%{"mounts" => [], "legacy_projects_imported" => "yes"}))
      assert %{legacy_projects_imported: false} = Persistence.load(path)
    end
  end

  describe "save/3" do
    test "creates the parent directory when needed", %{tmp_dir: tmp_dir} do
      path = Path.join([tmp_dir, "nested", "deeper", "mounts.json"])
      refute File.exists?(Path.dirname(path))

      assert :ok = Persistence.save(path, [mount(tmp_dir)], false)
      assert File.exists?(path)
    end

    test "overwrites an existing table", %{tmp_dir: tmp_dir} do
      path = file(tmp_dir)
      assert :ok = Persistence.save(path, [mount(tmp_dir, "vct:///projects/foo")], false)
      assert :ok = Persistence.save(path, [mount(tmp_dir, "vct:///projects/bar")], true)

      assert %{mounts: [loaded], legacy_projects_imported: true} = Persistence.load(path)
      assert loaded.point == "vct:///projects/bar"
    end

    test "leaves no temporary file behind", %{tmp_dir: tmp_dir} do
      path = file(tmp_dir)
      assert :ok = Persistence.save(path, [mount(tmp_dir)], false)

      assert File.ls!(tmp_dir) == ["mounts.json"]

      assert :ok = Persistence.save(path, [], true)
      assert File.ls!(tmp_dir) == ["mounts.json"]
    end

    test "returns a tagged error instead of raising", %{tmp_dir: tmp_dir} do
      blocker = Path.join(tmp_dir, "blocker")
      File.write!(blocker, "not a directory")

      assert {:error, _reason} = Persistence.save(Path.join(blocker, "mounts.json"), [], false)
      assert {:error, :invalid_input} = Persistence.save(nil, [], false)
      assert {:error, :invalid_input} = Persistence.save(file(tmp_dir), :nope, false)
    end
  end
end
