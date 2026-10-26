defmodule EvoGit.TestSupport.StoreTemplate do
  @moduledoc """
  A schema-complete SQLite TEMPLATE, built ONCE per test module and copied per
  test.

  Creating a brand-new SQLite file plus running the six shipped store
  migrations costs ~12 ms per boot (one real baseline DDL followed by five
  probe-guarded no-ops); a byte copy of the checkpointed template costs
  ~0.1 ms. Every test still gets its own isolated database FILE with the
  identical schema, so isolation semantics are unchanged.

  This is the same idiom already pinned in `test/evo_git/store_test.exs`,
  `test/evo_git/store/pool_size_test.exs` and
  `test/evo_git/store/maintenance_test.exs`; this module is its single reusable
  home for the rest of the suite.

  ## Usage (from `setup_all/1`, so the template is per MODULE)

      setup_all do
        {:ok, %{copy_db: EvoGit.TestSupport.StoreTemplate.new!()}}
      end

      setup %{copy_db: copy_db} do
        copy_db.(Path.join(root, "tasks.sqlite"))
        # ...start the isolated Store on that path exactly as before.
      end

  A per-module template is deliberately chosen over a per-BEAM cache: modules
  run concurrently (`async: true`), and a shared cache would need locking for a
  12 ms one-time win on the modules that do not skip it.
  """

  import ExUnit.Assertions, only: [assert: 1]

  alias EvoGit.Store.Boot

  @doc """
  Builds the module's template and returns a `destination -> destination`
  copy function.

  Must be called from `setup_all/1`: the template's own cleanup is registered
  with `ExUnit.Callbacks.on_exit/1`, which then runs after the module's last
  test.
  """
  @spec new!() :: (Path.t() -> Path.t())
  def new! do
    template = build!()
    fn destination -> copy!(template, destination) end
  end

  @doc """
  Builds a migrated, checkpointed SQLite file and returns its path.

  `EvoGit.Store.Boot.stop/1` checkpoints the WAL as its last connection
  closes, but that is ASYNCHRONOUS with respect to the stop returning — so the
  main file is checkpointed EXPLICITLY and the `-wal`/`-shm` sidecars are
  removed, leaving one self-contained file that is safe to byte-copy. The
  assertion proves the point: a template whose schema still sat in `-wal`
  would copy an EMPTY database.
  """
  @spec build!() :: Path.t()
  def build! do
    # OS pid + wall-clock ms on top of the per-BEAM counter: the counter alone
    # restarts on a fresh node and would collide with a previous run's leftover
    # template file.
    stamp =
      "#{System.unique_integer([:positive])}_#{:os.getpid()}_#{System.system_time(:millisecond)}"

    template = Path.join(System.tmp_dir!(), "evogit_store_template_#{stamp}.sqlite")

    {:ok, pid} = Boot.start_dynamic(template)
    :ok = Boot.stop(pid)
    checkpoint_and_strip_wal!(template)

    assert [[1]] =
             raw_query!(
               template,
               "SELECT count(*) FROM sqlite_master WHERE type = 'table' AND name = 'tasks'"
             )

    ExUnit.Callbacks.on_exit(fn -> remove_db(template) end)
    template
  end

  @doc """
  Copies the template to `destination`, creating the parent directory when
  missing. Returns `destination`.
  """
  @spec copy!(Path.t(), Path.t()) :: Path.t()
  def copy!(template, destination) do
    File.mkdir_p!(Path.dirname(destination))
    File.cp!(template, destination)
    destination
  end

  # Folds the WAL back into the main file. `TRUNCATE` leaves the WAL empty, so
  # the sidecars can go. (See `build!/0` for why an explicit checkpoint is
  # required.)
  defp checkpoint_and_strip_wal!(path) do
    {:ok, conn} = Xqlite.open(path)
    {:ok, _} = Xqlite.query(conn, "PRAGMA wal_checkpoint(TRUNCATE)", [])
    XqliteNIF.close(conn)
    File.rm(path <> "-wal")
    File.rm(path <> "-shm")
    :ok
  end

  # Reads the FILE (no live repo — the template's repo is already stopped).
  defp raw_query!(path, sql) do
    {:ok, conn} = Xqlite.open(path)

    try do
      {:ok, %{rows: rows}} = Xqlite.query(conn, sql, [])
      rows
    after
      XqliteNIF.close(conn)
    end
  end

  defp remove_db(path) do
    File.rm(path)
    File.rm(path <> "-wal")
    File.rm(path <> "-shm")
  end
end
