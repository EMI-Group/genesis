defmodule EvoGit.Store.BootMigrationLockTest do
  @moduledoc """
  Coverage for the `:aborted` (migration-lock) arm of `EvoGit.Store.Boot`.

  `:global.trans/2` retries until it is GRANTED on OTP 29, so the bare
  `:aborted` it answers when the lock cannot be taken was unreachable in
  production and untestable in the suite. `Boot` therefore reads its lock
  FUNCTION at the call site from the default-inert seam
  `Application.get_env(:evo_git, :store_boot_lock_fun, &:global.trans/2)` —
  the same call-time-seam pattern as `:store_boot_optimize_fun` and
  `EvoGit.Platform.config_dir/1`'s `:config_dir_fun`.

  Pinned contracts:

    * a lock that cannot be taken is NEVER a booted schema: `start_dynamic/2`
      answers `{:error, :migration_lock_unavailable}` (no pid) and NO migration
      ran on the file
    * the seam is consulted with the SAME lock id the production lock uses
      (`{:evo_git_store_migrations, <caller pid>}`) and with the wrapped
      zero-arity fun, which it does not run when it answers `:aborted`
    * `run_migrations/1` raises the ONE documented
      `"task-store migration lock unavailable; …"` message — the same
      `@migration_lock_unavailable` attribute `migration_source/0` now reports
      through, so the two lock-taking paths cannot diverge
    * the seam is DEFAULT-INERT: with the key unset the very same path
      migrates a fresh database normally and `migration_source/0` still answers
      its `[{version, module}]` list

  `async: false` — every test mutates the BEAM-GLOBAL app env
  `:evo_git, :store_boot_lock_fun` (`Application.put_env/3`), which a
  concurrently running module booting its own store WOULD observe (and would
  then see injected lock failures). Each test restores the previous value —
  deleting the key again when it was unset — in `on_exit`.
  """

  use ExUnit.Case, async: false

  alias EvoGit.Repo
  alias EvoGit.Store.Boot
  alias EvoGit.Store.RepoScope

  # The ONE lock-failure message (`@migration_lock_unavailable` in `Boot`), the
  # text `start_dynamic/2` matches to answer its error tuple.
  @lock_message "task-store migration lock unavailable; refusing to report a successful boot"

  # The call-time seam under test — the forcing global of this suite's
  # `async: false` (see the moduledoc).
  @seam :store_boot_lock_fun

  # The production lock id, whose first element is the GLOBAL constant `Boot`
  # passes to `:global.trans/2` (only the requester half is per-caller).
  @lock_name :evo_git_store_migrations

  # Every shipped migration version: 1–9 and 11 (version 10 is RETIRED).
  @migration_count 10

  setup do
    # Same per-test tmp root discipline as the sibling boot suites: pid +
    # wall-clock ms + a monotonic integer + the test pid keep the name unique
    # across BEAM restarts, and one recursive removal cleans the database file
    # with its WAL/SHM sidecars.
    root =
      Path.join(
        System.tmp_dir!(),
        "evogit_bootlock_#{:os.getpid()}_#{System.system_time(:millisecond)}_" <>
          "#{System.unique_integer([:positive, :monotonic])}_#{inspect(self())}"
      )

    on_exit(fn -> File.rm_rf(root) end)
    {:ok, %{root: root}}
  end

  # ── the lock cannot be taken ──────────────────────────────────────────────

  describe "a migration lock that cannot be taken" do
    test "start_dynamic/2 answers the error tuple, hands back NO pid and migrates nothing", %{
      root: root
    } do
      path = db_path(root, "aborted")
      parent = self()

      # The seam records the exact (lock id, wrapped fun) pair it is handed and
      # refuses the lock WITHOUT running the fun — precisely what `:global`
      # answers when the lock is unavailable.
      pin_lock_fun(fn lock_id, fun ->
        send(parent, {:lock_attempt, lock_id, is_function(fun, 0)})
        :aborted
      end)

      assert Boot.start_dynamic(path) == {:error, :migration_lock_unavailable}

      # The seam really is consulted, with the production lock id (a distinct
      # requester per caller) and the zero-arity fun that would have run the
      # migration.
      assert_receive {:lock_attempt, {@lock_name, owner}, true}, 2_000
      assert owner == parent

      # The fun never ran: the boot repo created the file but NO migration was
      # applied to it — this arm can never be mistaken for a booted schema.
      assert File.exists?(path)
      refute raw_table?(path, "schema_migrations")

      # …and the failed boot instance is gone: with the seam UNPINNED (back to
      # the default `&:global.trans/2`, restored by `on_exit` only for
      # hygiene), the SAME file boots cleanly and stamps every shipped
      # version — no pid, lock or half-open instance survives the aborted boot.
      Application.delete_env(:evo_git, @seam)
      assert Application.fetch_env(:evo_git, @seam) == :error

      assert %{versions: versions} = boot_ok!(path)
      assert length(versions) == @migration_count
    end

    test "run_migrations/1 raises the ONE documented lock message", %{root: root} do
      path = db_path(root, "raise")
      File.mkdir_p!(Path.dirname(path))

      # The exact call `complete_boot/3` makes: migrate an already-started
      # UNNAMED instance (never the app-global store).
      {:ok, boot} =
        Repo.start_link(Keyword.merge(Repo.start_opts(), database: path, name: nil, pool_size: 1))

      Process.unlink(boot)
      on_exit(fn -> stop_quietly(boot) end)

      pin_lock_fun(fn _lock_id, _fun -> :aborted end)

      # The public success contract stays the `[integer()]` version list, so the
      # lock failure must RAISE rather than answer a list for a database where
      # no migration ran — the same text `migration_source/0` reports through.
      assert_raise RuntimeError, @lock_message, fn -> Boot.run_migrations(boot) end

      refute raw_table?(path, "schema_migrations")
      # The caller's dynamic-repo binding was restored by `run_migrations/1`'s
      # `after`, so the failed run leaves no stale binding behind.
      assert Repo.get_dynamic_repo() != boot
    end
  end

  # ── the seam is default-inert ─────────────────────────────────────────────

  describe "the default lock seam" do
    test "is inert: with the key unset a fresh boot migrates and the source lists versions", %{
      root: root
    } do
      # No test in this module, and no production path, sets the key — it must
      # be absent here, i.e. `Boot` uses `&:global.trans/2` exactly as before.
      assert Application.fetch_env(:evo_git, @seam) == :error

      assert %{pid: pid, versions: versions} = boot_ok!(db_path(root, "default"))

      assert length(versions) == @migration_count
      assert versions == Enum.sort(versions)
      assert RepoScope.with_repo(pid, fn -> Repo.query!("SELECT 1").rows end) == [[1]]

      source = Boot.migration_source()
      assert is_list(source)
      assert Enum.map(source, &elem(&1, 0)) == versions
    end
  end

  # ── Helpers ───────────────────────────────────────────────────────────────

  defp db_path(root, tag), do: Path.join(root, "evogit_bootlock_#{tag}.sqlite")

  # Pins the call-time lock seam for ONE test and restores the previous state
  # in `on_exit` (deleting the key when it was unset), so the global app env
  # never leaks into another module.
  defp pin_lock_fun(fun) do
    previous = Application.fetch_env(:evo_git, @seam)
    Application.put_env(:evo_git, @seam, fun)

    on_exit(fn ->
      case previous do
        {:ok, value} -> Application.put_env(:evo_git, @seam, value)
        :error -> Application.delete_env(:evo_git, @seam)
      end
    end)
  end

  # Boots a dynamic repo on `path`, unlinks it (the `on_exit` guard runs after
  # the test process is gone, so `stop_quietly/1` — never a bare `Boot.stop/1`
  # — owns the cleanup) and returns the versions it stamped.
  defp boot_ok!(path) do
    {:ok, pid} = Boot.start_dynamic(path)
    Process.unlink(pid)
    on_exit(fn -> stop_quietly(pid) end)

    versions =
      RepoScope.with_repo(pid, fn ->
        Repo.query!("SELECT version FROM schema_migrations ORDER BY version").rows
        |> Enum.map(&hd/1)
      end)

    %{pid: pid, versions: versions}
  end

  defp stop_quietly(pid) do
    if Process.alive?(pid), do: :ok = Boot.stop(pid), else: :ok
  end

  # Raw xqlite probe (never the repo): does `table` exist in the file? A boot
  # whose migration lock was refused leaves NO `schema_migrations` behind.
  defp raw_table?(path, table) do
    {:ok, conn} = Xqlite.open(path)

    {:ok, %{rows: rows}} =
      XqliteNIF.query(
        conn,
        "SELECT name FROM sqlite_master WHERE type = 'table' AND name = ?1",
        [table]
      )

    :ok = XqliteNIF.close(conn)
    rows != []
  end
end
