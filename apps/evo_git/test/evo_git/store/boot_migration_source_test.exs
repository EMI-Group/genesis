defmodule EvoGit.Store.BootMigrationSourceTest do
  @moduledoc """
  Regression coverage for the PRE-LOADED migration source of `EvoGit.Store.Boot`
  — the source of truth for the `warning: redefining module
  EvoGit.Repo.Migrations.*` text a fresh test-Store boot must never print.

  `EvoGit.Store.Boot.migration_source/0` is the public seam: `[{version,
  module}]` ascending, compiled at most ONCE per BEAM with `Code.compile_file/1`
  and memoized in `:persistent_term`, handed to `Ecto.Migrator.run/4` INSTEAD of
  the migrations DIRECTORY. A directory source makes
  `Ecto.Migrator.load_migration!/1` compile every pending `.exs` on every run,
  redefining an already-loaded module in the BEAM and printing that warning once
  per boot.

  Pinned contracts:

    * the seam returns EXACTLY the two shipped migrations, ascending, with their
      modules loaded (`Code.ensure_loaded?/1` + `__migration__/0` exported), the
      versions agreeing with the REAL `priv/repo/migrations/*.exs` filenames
    * it is a pre-loaded MODULE list, never the directory/binary source that
      would make Ecto compile the files itself
    * repeated calls reuse the memoized list and recompile nothing
    * two consecutive fresh-database boots — the production path, both migration
      versions pending each time — emit no `redefining module` text and still
      stamp both versions

  ## Warning capture is deterministic under `async: true`

  `ExUnit.CaptureIO.capture_io(:stderr, fun)` is GROUP-LEADER scoped: it
  redirects only THIS test process's stderr (and the processes it spawns), so a
  concurrently running module's compiler warnings cannot leak into the capture
  and the capture cannot swallow another module's assertions. `Boot` compiles in
  the calling process, so the capture observes exactly this test's own compiles.
  """

  use ExUnit.Case, async: true

  import ExUnit.CaptureIO, only: [capture_io: 2]

  alias EvoGit.Repo
  alias EvoGit.Store.Boot
  alias EvoGit.Store.RepoScope

  # The shipped migration versions — the leading integers of
  # `priv/repo/migrations/20260815000001_baseline_adoption.exs` and
  # `20260815000002_data_normalization.exs`, as the sibling boot suites pin
  # them; `migration_file_versions/0` re-derives them from disk.
  @baseline_version 20_260_815_000_001
  @normalization_version 20_260_815_000_002

  @baseline_module EvoGit.Repo.Migrations.BaselineAdoption
  @normalization_module EvoGit.Repo.Migrations.DataNormalization

  # The `:persistent_term` memo slot `EvoGit.Store.Boot` fills with the
  # pre-loaded source (documented in `EvoGit.Store.Boot` / the store CONTEXT.md)
  # — read-only here, the production code owns the write.
  @memo_key {Boot, :migration_source}

  # ── setup ─────────────────────────────────────────────────────────────────

  setup do
    # Per-test root under the system tmp dir (the dynamic repos live here), so
    # cleanup is one recursive removal. The name embeds pid + wall-clock ms on
    # top of the per-BEAM unique integer + test pid: a counter + pid alone would
    # collide with a PREVIOUS run's leftover file and silently reopen it.
    root =
      Path.join(
        System.tmp_dir!(),
        "evogit_bootsource_#{:os.getpid()}_#{System.system_time(:millisecond)}_" <>
          "#{System.unique_integer([:positive, :monotonic])}_#{inspect(self())}"
      )

    on_exit(fn -> File.rm_rf(root) end)
    {:ok, %{root: root}}
  end

  # ── migration_source/0 ────────────────────────────────────────────────────

  describe "migration_source/0" do
    test "returns exactly the two shipped {version, module} pairs, ascending, modules loaded" do
      source = Boot.migration_source()

      assert source == [
               {@baseline_version, @baseline_module},
               {@normalization_version, @normalization_module}
             ]

      versions = Enum.map(source, &elem(&1, 0))
      assert versions == Enum.sort(versions)
      assert versions == Enum.uniq(versions)
      assert versions == migration_file_versions()
    end

    test "is a pre-loaded module list, never the migrations DIRECTORY Ecto compiles itself" do
      source = Boot.migration_source()
      directory = Ecto.Migrator.migrations_path(Repo)

      # A directory (binary) source is what sends `Ecto.Migrator` into
      # `load_migration!/1` → `Code.compile_file/1` for every pending file.
      assert File.dir?(directory)
      refute is_binary(source)
      refute source == directory
      assert is_list(source)

      for {version, module} <- source do
        assert is_integer(version)
        assert is_atom(module)
        assert Code.ensure_loaded?(module)
        assert function_exported?(module, :__migration__, 0)
      end
    end

    test "is memoized: repeated calls reuse the pre-loaded list and recompile nothing" do
      first = Boot.migration_source()

      output =
        capture_io(:stderr, fn ->
          assert Boot.migration_source() == first
          assert Boot.migration_source() == first
        end)

      # The documented BEAM-wide memo slot holds exactly the returned list.
      assert :persistent_term.get(@memo_key) == first
      refute output =~ "redefining module"
    end
  end

  # ── fresh-database boots ──────────────────────────────────────────────────

  describe "fresh-database boots" do
    test "two consecutive boots reuse the loaded source: no 'redefining module' text", %{
      root: root
    } do
      # Both migration modules are already loaded here (the app-booted store
      # migrated before the suite ran), so a regression to a directory source
      # would have to REDEFINE them — which is exactly what the capture looks
      # for.
      assert Boot.migration_source() == [
               {@baseline_version, @baseline_module},
               {@normalization_version, @normalization_module}
             ]

      assert Code.ensure_loaded?(@baseline_module)
      assert Code.ensure_loaded?(@normalization_module)

      output =
        capture_io(:stderr, fn ->
          assert booted_versions(db_path(root, "fresh_a")) ==
                   [@baseline_version, @normalization_version]

          assert booted_versions(db_path(root, "fresh_b")) ==
                   [@baseline_version, @normalization_version]
        end)

      refute output =~ "redefining module"
    end
  end

  # ── Helpers ───────────────────────────────────────────────────────────────

  defp db_path(root, tag), do: Path.join(root, "evogit_bootsource_#{tag}.sqlite")

  # Boots a dynamic repo on a FRESH database (both migration versions pending,
  # so the compile path under test is genuinely exercised), returns the versions
  # it stamped, and stops it. Mirrors the sibling suites: the repo is UNLINKED
  # (the `on_exit` guard runs after the test process is gone, so
  # `stop_quietly/1` — never a bare `Boot.stop/1` — owns the cleanup).
  defp booted_versions(path) do
    {:ok, pid} = Boot.start_dynamic(path)
    Process.unlink(pid)
    on_exit(fn -> stop_quietly(pid) end)

    versions =
      RepoScope.with_repo(pid, fn ->
        Repo.query!("SELECT version FROM schema_migrations ORDER BY version").rows
        |> Enum.map(&hd/1)
      end)

    stop_quietly(pid)
    versions
  end

  defp stop_quietly(pid) do
    if Process.alive?(pid), do: :ok = Boot.stop(pid), else: :ok
  end

  # Integer versions of the REAL shipped migration filenames
  # (`<version>_<name>.exs`, parsed the way `Ecto.Migrator.extract_migration_info/1`
  # does), so the seam's versions are cross-checked against the files on disk
  # rather than trusted on their own. A non-migration filename raises a
  # MatchError — loudly, because `migration_source/0` would silently ignore it.
  defp migration_file_versions do
    Repo
    |> Ecto.Migrator.migrations_path()
    |> Path.join("*.exs")
    |> Path.wildcard()
    |> Enum.map(fn file ->
      {version, "_" <> _name} = Integer.parse(Path.rootname(Path.basename(file)))
      version
    end)
    |> Enum.sort()
  end
end
