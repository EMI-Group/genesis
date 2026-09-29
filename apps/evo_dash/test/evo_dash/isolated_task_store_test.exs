defmodule EvoDash.Test.IsolatedTaskStoreTest do
  # `async: false` — `isolate!/1` terminates the PROCESS-GLOBAL `EvoGit.Store` /
  # `EvoGit.TaskRegistry` children of `EvoGit.Supervisor`, so no other suite may
  # run concurrently (the same reason `node_context_test.exs` is a sync module).
  use ExUnit.Case, async: false

  alias EvoDash.Test.IsolatedTaskStore
  alias EvoGit.TaskInfo

  # The isolated temp dir is `<tmp>/evogit_test_<prefix>_<unique int>` (the
  # helper's own naming), so this prefix alone identifies this module's dirs.
  @prefix "isolated_task_store_test"

  # Mirrors the helper's private `@template_basename`/`@template_sidecars`: the
  # run-scoped, fully migrated sqlite file every `isolate!/1` copies its private
  # database FROM (built lazily by the first `isolate!/1` of a run).
  @template_basename "isolated_store_template.sqlite"
  @template_sidecars ["-wal", "-shm", "-journal"]

  # Witness for "two successive `isolate!/1` calls get DISTINCT database files",
  # shared by this module's tests (ExUnit may run them in either order).
  @observed_key {__MODULE__, :observed_sqlite_paths}

  setup do
    # Registered BEFORE any `isolate!/1` call below, and ExUnit runs `on_exit`
    # callbacks in REVERSE registration order — so this callback observes the
    # state AFTER the helper's own teardown has run, which is the only
    # deterministic way to check a post-teardown invariant from the test that
    # caused it.
    on_exit(fn ->
      # Teardown restored the production singletons (and verified them) …
      :ok = IsolatedTaskStore.assert_production!()

      # … and removed its own temp dir: no isolated database outlives its test.
      assert isolated_root_dirs() == [],
             "isolate!/1 left its temp dir behind: #{inspect(isolated_root_dirs())}"
    end)

    :ok
  end

  test "isolate!/1 hands this test its own private, fully migrated database" do
    before = template_snapshot()

    :ok = IsolatedTaskStore.isolate!(@prefix)

    db = isolated_sqlite_path()
    root = Path.dirname(db)

    # A private file in a private, per-call temp dir — never the shared template
    # and never inside the template's own (per-run) directory.
    assert File.exists?(db)
    assert Path.basename(db) == "tasks.sqlite"
    assert Path.basename(root) =~ ~r/^evogit_test_#{@prefix}_\d+$/
    refute db == template_path()
    refute Path.dirname(db) == Path.dirname(template_path())

    # … and no two `isolate!/1` calls ever get the same database file (the
    # witness is module-wide, so it holds whichever test ran first; a single-test
    # run just makes it vacuously true instead of failing).
    record_isolated_path!(db)

    # Fully migrated: the isolated store carries the run's whole schema, so the
    # boot migrator has nothing left to run — the property the template exists to
    # provide (a template that lost the schema would show up right here).
    assert applied_migration_versions() == expected_migration_versions()

    # … and it is a LIVE store: the migrated table answers.
    assert EvoGit.Store.safe_select_all_tasks(EvoGit.Store) == []

    # The setup hook's post-teardown dir check is not vacuous: this exact prefix
    # DOES match the isolated dir while the test runs.
    assert [^root] = isolated_root_dirs()

    # Whatever this call did, it did it to its OWN database: the shared template
    # is byte-identical. (Either test may run first, so both branches of
    # `assert_template_not_mutated/2` are exercised across the module.)
    assert_template_not_mutated(before, template_snapshot())
  end

  test "isolation and the writes through it leave the shared template byte-identical" do
    before = template_snapshot()

    :ok = IsolatedTaskStore.isolate!(@prefix)

    db = isolated_sqlite_path()
    record_isolated_path!(db)

    # A write through the isolated pair: if the isolated store were opened on the
    # SHARED template file, this row would land in that file's own `-wal`.
    id = put_task_in_isolated_store!()
    assert %TaskInfo{id: ^id} = EvoGit.Store.get_task(EvoGit.Store, id)

    assert_template_not_mutated(before, template_snapshot())

    # The row is provably IN the isolated database's own files (its main file or
    # its private WAL sidecar) — while the template above did not change by a
    # single byte, i.e. nothing was shared with it.
    assert File.exists?(db <> "-wal")
    assert File.read!(db) <> File.read!(db <> "-wal") =~ id
  end

  # ── Observing the isolated instance ────────────────────────────────────────

  # The sqlite FILE the isolated `EvoGit.Store` (which holds the singleton name
  # while a test isolates) is opened on.
  defp isolated_sqlite_path, do: :sys.get_state(EvoGit.Store).data_dir

  # The temp dirs this module's own `isolate!/1` calls created — asserted EMPTY
  # by the post-teardown hook above.
  defp isolated_root_dirs do
    Path.wildcard(Path.join(System.tmp_dir!(), "evogit_test_#{@prefix}_*"))
  end

  defp put_task_in_isolated_store! do
    id = "isolated_task_store_test_#{System.unique_integer([:positive])}"

    :ok =
      EvoGit.Store.put_task(EvoGit.Store, %TaskInfo{
        id: id,
        type: :genesis,
        status: :pending,
        opts: [path: "/tmp/isolated_task_store_test"],
        ref: nil,
        started_at: DateTime.utc_now(),
        finished_at: nil,
        logs: [],
        result: nil
      })

    id
  end

  defp record_isolated_path!(path) do
    seen = :persistent_term.get(@observed_key, [])

    refute path in seen, "isolate!/1 handed two tests the same sqlite file: #{path}"

    :persistent_term.put(@observed_key, [path | seen])
  end

  # ── Observing the shared template ──────────────────────────────────────────

  defp template_path do
    Path.join(Application.fetch_env!(:evo_git, :data_dir), @template_basename)
  end

  # Fingerprints the template's main file AND its sidecars: a SHARED template
  # would be mutated through a sidecar first (`-wal` frames), so the main file
  # alone is not a sufficient witness.
  defp template_snapshot do
    sidecars = Map.new(@template_sidecars, &{&1, fingerprint(template_path() <> &1)})
    Map.put(sidecars, :main, fingerprint(template_path()))
  end

  # `File.read/1` distinguishes the one EXPECTED absence (not built yet) from
  # every other failure, which would raise loudly instead of being swallowed.
  defp fingerprint(path) do
    case File.read(path) do
      {:ok, bytes} -> {:present, byte_size(bytes), :crypto.hash(:sha256, bytes)}
      {:error, :enoent} -> :absent
    end
  end

  defp assert_template_not_mutated(%{main: :absent}, after_snapshot) do
    # The template is built LAZILY by the first `isolate!/1` of the run, so the
    # test that happens to run first legitimately sees it APPEAR. It must be a
    # real, non-empty database — and the test that runs second then exercises the
    # byte-identity branch.
    assert match?(%{main: {:present, size, _}} when size > 0, after_snapshot),
           "isolate!/1 did not produce a migrated template: #{inspect(after_snapshot)}"
  end

  defp assert_template_not_mutated(before, after_snapshot) do
    assert after_snapshot == before, "isolate!/1 mutated the shared migrated template"
  end

  # ── Reading the isolated database through the store's own connection ───────

  defp applied_migration_versions do
    # `EvoGit.Repo` resolves its target through a PROCESS-LOCAL binding that is
    # unset in a test process, so a bare `EvoGit.Repo.query!/1` would address the
    # PRODUCTION database. The store's documented test seam +
    # `RepoScope.with_repo/2` bind these queries to the isolated instance.
    repo = EvoGit.Store.__repo_pid__(EvoGit.Store)

    EvoGit.Store.RepoScope.with_repo(repo, fn ->
      EvoGit.Repo.query!("SELECT version FROM schema_migrations").rows
    end)
    |> List.flatten()
    |> Enum.sort()
  end

  defp expected_migration_versions do
    EvoGit.Store.Boot.migration_source() |> Enum.map(&elem(&1, 0)) |> Enum.sort()
  end
end
