defmodule EvoGit.Store.Operations.VctMountsTest do
  @moduledoc """
  Tests for `EvoGit.Store.Operations.VctMounts` — the Ecto operations behind the
  Virtual Context Tree mount table.

  Pinned contracts:

    * `list/1` (and therefore `EvoGit.Store.list_vct_mounts/1`) is
      NEWEST-FIRST with a `nil` `last_opened_at` LAST and a deterministic
      `point ASC` tie-break, so callers never depend on SQLite's scan order;
    * `save/2` is an ATOMIC REPLACE-ALL inside ONE transaction: the caller's
      list becomes the whole table, a smaller list removes the rows that are
      no longer present, and a failure while writing the NEW rows rolls the
      delete back — the previous table survives intact;
    * the store facade maps a disk-full-class failure to
      `{:error, :disk_full}`.

  ## The disk-full arm

  Same technique as `test/evo_git/store_disk_full_test.exs`: `PRAGMA
  query_only = ON` on the store's OWN dynamic repo, reached through the
  sanctioned test seams `EvoGit.Store.__repo_pid__/1` +
  `XqliteEcto3.with_xqlite/2`. The pragma is CONNECTION-scoped, so the store is
  started with an explicit `pool_size: 1` — the armed connection IS the one
  every write is handed — and re-armed before each write because a read-only
  `BEGIN` failure makes the adapter tear the connection down.
  """

  use ExUnit.Case, async: true

  import ExUnit.CaptureLog

  alias EvoGit.Store
  alias EvoGit.Store.Boot
  alias EvoGit.Store.Operations.VctMounts, as: Ops
  alias EvoGit.TestSupport.StoreTemplate

  setup_all do
    {:ok, %{copy_db: StoreTemplate.new!()}}
  end

  setup %{copy_db: copy_db} do
    stamp =
      "#{System.unique_integer([:positive])}_#{:os.getpid()}_#{System.system_time(:millisecond)}"

    root = Path.join(System.tmp_dir!(), "evogit_vct_mounts_#{stamp}")
    File.mkdir_p!(root)
    sqlite_path = Path.join(root, "tasks.sqlite")
    copy_db.(sqlite_path)
    on_exit(fn -> File.rm_rf(root) end)

    {:ok, root: root, sqlite_path: sqlite_path}
  end

  ## Helpers

  # Boots a SUPERVISED store on this test's database file. `pool_size: 1` is
  # only required by the disk-full arm (a connection-scoped pragma must be the
  # connection every write is handed); every other case passes the default.
  defp start_store!(sqlite_path, opts \\ []) do
    name = :"vct_mounts_test_store_#{System.unique_integer([:positive])}"

    start_supervised!(
      Supervisor.child_spec(
        {Store, Keyword.merge([data_dir: sqlite_path, name: name], opts)},
        id: name
      )
    )

    name
  end

  defp entry(point, path, name, last_opened_at \\ nil) do
    %{
      "point" => point,
      "path" => path,
      "name" => name,
      "kind" => "git",
      "last_opened_at" => last_opened_at
    }
  end

  defp points(rows), do: Enum.map(rows, & &1["point"])

  ## Ordering

  describe "list/1 ordering" do
    test "is newest-first with nil last and a point ASC tie-break", %{sqlite_path: path} do
      store = start_store!(path)

      :ok =
        Store.save_vct_mounts(store, [
          entry("vct:///projects/nil_one", "/p/nil_one", "Nil One", nil),
          entry("vct:///projects/old", "/p/old", "Old", ~U[2020-01-01 00:00:00.000Z]),
          entry("vct:///projects/tie_b", "/p/tie_b", "Tie B", ~U[2023-05-05 10:00:00.500Z]),
          entry("vct:///projects/tie_a", "/p/tie_a", "Tie A", ~U[2023-05-05 10:00:00.500Z]),
          entry("vct:///projects/newest", "/p/newest", "Newest", ~U[2024-06-01 00:00:00.000Z]),
          entry("vct:///projects/nil_two", "/p/nil_two", "Nil Two", nil)
        ])

      assert points(Store.list_vct_mounts(store)) == [
               "vct:///projects/newest",
               "vct:///projects/tie_a",
               "vct:///projects/tie_b",
               "vct:///projects/old",
               "vct:///projects/nil_one",
               "vct:///projects/nil_two"
             ]
    end

    test "returns STRING-KEYED entries with a loaded DateTime", %{sqlite_path: path} do
      store = start_store!(path)
      at = ~U[2024-06-01 12:34:56.789Z]

      :ok = Store.save_vct_mounts(store, [entry("vct:///projects/alpha", "/p/a", "Alpha", at)])

      assert [
               %{
                 "point" => "vct:///projects/alpha",
                 "path" => "/p/a",
                 "name" => "Alpha",
                 "kind" => "git",
                 "last_opened_at" => %DateTime{} = loaded
               }
             ] = Store.list_vct_mounts(store)

      assert loaded == at
    end

    test "an empty table lists as []", %{sqlite_path: path} do
      store = start_store!(path)
      assert Store.list_vct_mounts(store) == []
    end
  end

  ## Replace-all writes

  describe "save/2 replace-all" do
    test "a smaller list removes the rows that are no longer present", %{sqlite_path: path} do
      store = start_store!(path)

      :ok =
        Store.save_vct_mounts(store, [
          entry("vct:///projects/alpha", "/p/a", "Alpha", ~U[2024-01-01 00:00:00Z]),
          entry("vct:///projects/beta", "/p/b", "Beta", ~U[2024-02-01 00:00:00Z]),
          entry("vct:///projects/gamma", "/p/c", "Gamma", ~U[2024-03-01 00:00:00Z])
        ])

      assert length(Store.list_vct_mounts(store)) == 3

      :ok =
        Store.save_vct_mounts(store, [
          entry("vct:///projects/beta", "/p/b", "Beta Renamed", ~U[2024-02-01 00:00:00Z])
        ])

      assert [%{"point" => "vct:///projects/beta", "name" => "Beta Renamed"}] =
               Store.list_vct_mounts(store)

      # An empty list empties the table (still one transaction).
      :ok = Store.save_vct_mounts(store, [])
      assert Store.list_vct_mounts(store) == []
    end

    test "a failure while writing the NEW rows rolls the delete back", %{sqlite_path: path} do
      # Operations-level, on a plain dynamic repo: the write path's non-disk-full
      # errors re-raise (by design), so the atomicity is asserted where it lives
      # — inside `save/2`'s single transaction — without killing a supervised
      # GenServer.
      {:ok, repo} = Boot.start_dynamic(path)

      :ok = Ops.save(repo, [entry("vct:///projects/kept", "/p/kept", "Kept", nil)])
      assert points(Ops.list(repo)) == ["vct:///projects/kept"]

      # `delete_all` runs FIRST, then building the new rows raises — the whole
      # transaction must roll back, restoring the previous table.
      assert_raise ArgumentError, ~r/invalid vct_mounts.last_opened_at/, fn ->
        Ops.save(repo, [
          entry("vct:///projects/broken", "/p/broken", "Broken", "not-a-timestamp")
        ])
      end

      assert points(Ops.list(repo)) == ["vct:///projects/kept"]
      assert [%{"path" => "/p/kept"}] = Ops.list(repo)

      # Stopped from the TEST process (the dynamic repo is linked to it, so an
      # `on_exit/1` stop would race the test process's own exit).
      :ok = Boot.stop(repo)
    end

    test "accepts atom-keyed entries too", %{sqlite_path: path} do
      store = start_store!(path)

      :ok =
        Store.save_vct_mounts(store, [
          %{point: "vct:///projects/atom", path: "/p/atom", name: "Atom"}
        ])

      assert [%{"point" => "vct:///projects/atom", "kind" => "git", "name" => "Atom"}] =
               Store.list_vct_mounts(store)
    end
  end

  ## Disk full

  describe "disk-full mapping" do
    test "save_vct_mounts/2 returns {:error, :disk_full} and changes nothing",
         %{sqlite_path: path} do
      store = start_store!(path, pool_size: 1)

      :ok = Store.save_vct_mounts(store, [entry("vct:///projects/kept", "/p/kept", "Kept")])

      set_query_only(store, "ON")

      log =
        capture_log(fn ->
          assert {:error, :disk_full} =
                   Store.save_vct_mounts(store, [
                     entry("vct:///projects/new", "/p/new", "New")
                   ])
        end)

      assert log =~ "disk", "expected an actionable disk-full warning, got: #{log}"

      set_query_only(store, "OFF")

      # The store survived the failed write and the previous table is intact.
      assert Process.alive?(Process.whereis(store))
      assert points(Store.list_vct_mounts(store)) == ["vct:///projects/kept"]

      # A retried write succeeds once the condition clears.
      assert :ok =
               Store.save_vct_mounts(store, [
                 entry("vct:///projects/new", "/p/new", "New")
               ])

      assert points(Store.list_vct_mounts(store)) == ["vct:///projects/new"]
    end
  end

  # See the moduledoc: a connection-scoped pragma on the store's one pooled
  # connection.
  defp set_query_only(store, value) do
    repo_pid = Store.__repo_pid__(store)

    :ok =
      XqliteEcto3.with_xqlite(repo_pid, fn conn ->
        {:ok, _} = XqliteNIF.query(conn, "PRAGMA query_only = #{value}", [])
        :ok
      end)
  end
end
