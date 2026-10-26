defmodule EvoGit.TestSupport.StoreTemplate do
  @moduledoc """
  A schema-complete SQLite TEMPLATE, built ONCE per test BEAM and copied per
  test.

  Creating a brand-new SQLite file plus running the six shipped store
  migrations costs ~23 ms of store boot (measured here: one real baseline DDL
  followed by five probe-guarded no-ops); copying the checkpointed template and
  booting a store on the copy costs ~2 ms. Every test still gets its own
  isolated database FILE with the identical schema, so isolation semantics are
  unchanged.

  The template used to be built once per test MODULE — but every module in one
  `mix test` BEAM runs the SAME `priv/repo/migrations` at the SAME version, so
  that build was pure duplication: a 29-module subset measured 29 builds /
  10.3 s of summed build time, all of it competing with the modules' own
  `async: true` tests. The template is therefore cached in `:persistent_term`
  for the whole BEAM: the first `setup_all/1` pays the build, every other
  module pays only the copy.

  This is the same idiom already pinned in `test/evo_git/store_test.exs`,
  `test/evo_git/store/pool_size_test.exs` and
  `test/evo_git/store/maintenance_test.exs`; this module is its single reusable
  home for the rest of the suite.

  ## Usage (from `setup_all/1`)

      setup_all do
        {:ok, %{copy_db: EvoGit.TestSupport.StoreTemplate.new!()}}
      end

      setup %{copy_db: copy_db} do
        copy_db.(Path.join(root, "tasks.sqlite"))
        # ...start the isolated Store on that path exactly as before.
      end

  ## Why the cache is safe for concurrently starting (`async: true`) modules

    * **One builder, atomically published.** Concurrent `setup_all/1` blocks
      (ExUnit starts up to `--max-cases` modules at once) are serialized with
      the same `:global.trans/2` idiom `EvoGit.Store.Boot` uses for the
      migration run: the first caller builds and publishes, the others block
      for that one build and then read the published path. Nothing ever
      observes a half-built template — the path is published only after the
      build finished, was checkpointed, had its `-wal`/`-shm` sidecars stripped
      and was validated (the "`sqlite_master` carries `tasks`" assertion
      below).
    * **The template file is IMMUTABLE.** It is never opened by a store after
      it is built; the only operation on it is `File.cp!/2`. No test can see
      another test's rows, because no two tests ever share a mutable database
      file: each test copies the template to its OWN path.
    * **Copies are complete.** The build folds the WAL back into the main file
      and deletes the sidecars, so the single copied file carries the whole
      schema (a template whose schema still sat in `-wal` would copy an EMPTY
      database — that is what the assertion is for).
    * **Lifetime is the BEAM's.** The shared template is removed by a
      `System.at_exit/1` handler, never by a module's `on_exit/1` (which would
      delete the file out from under a module still running). A killed VM
      leaves one file in the OS temp dir — exactly the leftover a killed
      per-module build leaves today.

  `build!/0` remains for a caller that wants an explicitly MODULE-scoped
  template with `on_exit/1` cleanup (it is what `new!/0` used before the cache);
  the suite does not use it.
  """

  import ExUnit.Assertions, only: [assert: 1]

  alias EvoGit.Store.Boot

  # One BEAM-wide cache slot holding the template's PATH (the file itself is
  # immutable, so the path never needs to change once published).
  @cache_key {__MODULE__, :template}

  @doc """
  Returns a `destination -> destination` copy function over the BEAM-wide
  template, building it on first use.

  Must be called from `setup_all/1`: the first call performs a real store boot.
  """
  @spec new!() :: (Path.t() -> Path.t())
  def new! do
    template = cached_template!()
    fn destination -> copy!(template, destination) end
  end

  @doc """
  Builds a MODULE-scoped migrated, checkpointed SQLite file and returns its
  path; its cleanup is registered with `ExUnit.Callbacks.on_exit/1`.

  Must be called from `setup_all/1`: the cleanup then runs after the module's
  last test. Prefer `new!/0`, which shares ONE template per BEAM.
  """
  @spec build!() :: Path.t()
  def build! do
    template = build_template!()
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

  # ── BEAM-wide template cache ──────────────────────────────────────────

  defp cached_template! do
    case :persistent_term.get(@cache_key, nil) do
      nil -> build_and_publish!()
      template -> template
    end
  end

  # Double-checked under a `:global` lock (the `EvoGit.Store.Boot` idiom): the
  # fast path above never takes it, and only the very first caller builds.
  defp build_and_publish! do
    :global.trans({{__MODULE__, :template}, self()}, fn ->
      case :persistent_term.get(@cache_key, nil) do
        nil ->
          template = build_template!()
          # The template outlives every module in this BEAM: it is removed when
          # the VM shuts down, never by a module's `on_exit/1`.
          System.at_exit(fn _status -> remove_db(template) end)
          :persistent_term.put(@cache_key, template)
          template

        template ->
          template
      end
    end)
  end

  # Builds a migrated, checkpointed, self-contained SQLite file and returns its
  # path.
  #
  # `EvoGit.Store.Boot.stop/1` checkpoints the WAL as its last connection
  # closes, but that is ASYNCHRONOUS with respect to the stop returning — so the
  # main file is checkpointed EXPLICITLY and the `-wal`/`-shm` sidecars are
  # removed, leaving one file that is safe to byte-copy. The assertion proves
  # the point: a template whose schema still sat in `-wal` would copy an EMPTY
  # database.
  defp build_template! do
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

    template
  end

  # Folds the WAL back into the main file. `TRUNCATE` leaves the WAL empty, so
  # the sidecars can go. (See `build_template!/0` for why an explicit checkpoint
  # is required.)
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
