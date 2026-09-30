defmodule EvoDash.Test.IsolatedTaskStore do
  require Logger

  @moduledoc """
  Deterministic Store/TaskRegistry isolation for `async: false` dashboard suites.

  Several dashboard suites need a *live* `EvoGit.Store` + `EvoGit.TaskRegistry`
  pair but must not touch the per-run production SQLite database. The
  established idiom is to terminate the production children under
  `EvoGit.Supervisor`, start isolated same-named instances against a temp
  sqlite file, and restart the production children afterwards.

  Doing that with `start_supervised/1` + a raw `on_exit/1` is racy and silent:

    * `start_supervised/1` children are torn down by ExUnit *around* the user
      `on_exit` callbacks, so the relative order of "isolated instance dies"
      and "production child restarted" is an ExUnit implementation detail, not
      a contract;
    * `Supervisor.restart_child/2` was called with its return value **ignored**,
      so a restore that failed (`{:error, {:already_started, pid}}` while a
      stray instance still held the singleton name, or `{:error, not_found}` if
      the child spec was gone) left the process-global `EvoGit.Store` /
      `EvoGit.TaskRegistry` names pointing at some *other* database — every
      later suite that relies on the production pair (e.g.
      `EvoDashWeb.ReviewLiveTest`, which does no isolation of its own) then
      reads and writes different stores, and a fixture row written by the test
      is invisible to the next read of the same id.

  `isolate!/1` removes the whole class of failure instead of racing it:

    * the isolated pair is started under a supervisor owned by this module and
      is stopped **explicitly and first** in the teardown, so the singleton
      names are provably free before the production children are restarted;
    * the restart results are **checked** — a failed restore raises (loud)
      rather than silently leaving the globals unrestored;
    * the restored identity is **verified** (production data dir / `task_store`)
      so a restore that "succeeded" onto the wrong instance cannot pass;
    * the stop/restore sequence runs inside `ExUnit.CaptureLog.capture_log/2`,
      because `on_exit/1` executes *outside* ExUnit's per-test log capture and
      killing a Store with in-flight offloaded Tasks makes those Tasks crash on
      the vanished ETS query cache — a crash report that is expected here and
      must not print to the console.

  Tests that need transactional isolation on top of this can still
  `EvoGit.Store.put_task/2` against the isolated pair as usual.

  ## Cost

  Measured over the whole `evo_dash` suite (~204 `isolate!/1` calls, two
  windows' worth of setup/teardown per `async: false` test): restarting the
  production pair is ~1.7 ms/call (its schema is already migrated, so the boot
  migrations are a verified no-op) and everything else — terminating the
  production pair, the temp-dir `mkdir_p!`/`rm_rf`, and `stop_isolated/1`,
  which takes its cheap `:ok` branch because the isolated supervisor (linked to
  the test process) is already dead by the time `on_exit` runs — is
  sub-millisecond. The isolated store boot was the remaining term.

  `EvoGit.Store` ALWAYS runs the Ecto migrations at boot
  (`EvoGit.Store.Boot.start_dynamic/2` → `Ecto.Migrator.run(…, all: true)`), and
  on a brand-new sqlite file that means executing the whole baseline-adoption
  DDL (3 tables, 8 indexes, the legacy-column `PRAGMA` probes) inside a
  migration transaction — measured ~10 ms of the ~11–16 ms fresh isolated boot,
  i.e. the dominant term (confirmed on this host, not assumed).

  Booting against an ALREADY-MIGRATED database makes that migrator run a
  verified no-op: measured ~0.9 ms for the same `EvoGit.Store.start_link/1`
  boot. So this helper builds the migrated template ONCE per run
  (`template_path/0`, lazily, before the production pair is touched) and every
  `isolate!/1` then seeds its private sqlite file with a ~0.07 ms `File.cp!/2`
  of that template instead of paying the DDL again — ~10 ms saved per call,
  ~2 s per suite run.

  The template is a plain output of the SAME `EvoGit.Store.Boot.start_dynamic/2`
  the isolated store uses, so nothing about the boot path is skipped or
  special-cased: the per-test store still opens its own file, runs the migrator
  (a no-op), reopens its pool at `default_pool_size/0`, and gets a private
  WAL/shm pair. Only the DDL that the template already carries is not repeated —
  and the two are schema-identical: `sqlite_master` (verbatim DDL), every
  table's `PRAGMA table_info`/`PRAGMA index_list`, `user_version`,
  `journal_mode`, the three `schema_migrations` rows and the zero row counts all
  compare equal between a template-derived database and a freshly migrated one
  (and against the per-run production database).

  The copy is safe by construction, and the construction is SELF-CHECKED:

    * the template build pushes the migrated schema out of the WAL into the main
      database file with an explicit `PRAGMA wal_checkpoint(TRUNCATE)` — that is
      required, not cosmetic: a plain clean close delivered a complete main file
      in only 5 of 30 measured builds (SQLite's last-close checkpoint is not
      reliable through the xqlite NIF handle), while the explicit checkpoint
      delivered 30 of 30;
    * the build then PROVES the result by copying the template's main file alone
      and asserting the copy reports every version in
      `EvoGit.Store.Boot.migration_source/0` as applied (0.2 ms, once per run).
      A template that fails the proof is discarded with a warning and the run
      boots fresh databases as before — correct either way;
    * each test gets its OWN file inside its OWN temp dir; the template is only
      ever read (`File.cp!/2`), never written, and sidecars are never shared;
    * a template whose content were ever older than expected is still CORRECT:
      the migrator is idempotent and would simply re-run the remaining
      migrations on the copy.
  """
  @doc """
  Terminate the production children, start an isolated Store + TaskRegistry
  under a supervisor owned by this helper, and register a teardown that stops
  the isolated pair *before* deterministically restoring (and verifying) the
  production children.

  `prefix` is used in the temp directory name (keep it stable per suite so a
  crash keeps the artifacts identifiable).
  """
  @spec isolate!(String.t()) :: :ok
  def isolate!(prefix) do
    # Resolve (or, on the first call of a run, build) the migrated sqlite
    # template BEFORE the production pair is touched, so a failure here can
    # never leave the process-global singletons terminated.
    template = template_path()

    # No log capture here: `isolate!/1` is called from a `setup` callback, and
    # ExUnit's `capture_log: true` wraps setup AND the test body in
    # `ExUnit.CaptureLog.with_log/2` (ExUnit.Runner `maybe_capture_log/3`), so
    # anything `terminate_production!/0` logs is already captured by the test's
    # own window. Only the `on_exit` teardown below runs outside it.
    terminate_production!()

    root =
      Path.join(System.tmp_dir!(), "evogit_test_#{prefix}_#{System.unique_integer([:positive])}")

    File.mkdir_p!(root)
    sqlite_path = Path.join(root, "tasks.sqlite")
    seed_isolated_database!(template, sqlite_path)

    {:ok, sup} =
      Supervisor.start_link(
        [
          {EvoGit.Store, data_dir: sqlite_path},
          {EvoGit.TaskRegistry,
           task_store: EvoGit.Store, data_dir: root, name: EvoGit.TaskRegistry}
        ],
        strategy: :one_for_one
      )

    ExUnit.Callbacks.on_exit(fn ->
      # The whole stop/restore sequence runs inside a log capture: `on_exit`
      # callbacks execute OUTSIDE ExUnit's per-test log capture, so anything
      # the teardown logs would otherwise print straight to the console.
      capture_teardown_noise(fn ->
        # Order matters: release the singleton names FIRST, then restore.
        stop_isolated(sup)
        File.rm_rf(root)
        restore_production!()
      end)
    end)

    :ok
  end

  # ── Migrated template database ──────────────────────────────────────────
  #
  # Built once per run (see the moduledoc's "Cost" section), then copied into
  # each per-test temp dir so the isolated store boots against an
  # already-migrated schema and the boot migrator becomes a verified no-op.
  #
  # Cached in `:persistent_term` under a BINARY path (or `nil` when no template
  # could be placed: see `template_destination/0`), with `:unset` as the
  # "never resolved" marker so a `nil` result is cached too and the decision is
  # made exactly once per run. One `put` per run: `:persistent_term` writes are
  # expensive, reads are not.
  @template_key {__MODULE__, :template_path}
  @template_basename "isolated_store_template.sqlite"
  @template_sidecars ["-wal", "-shm", "-journal"]

  defp template_path do
    case :persistent_term.get(@template_key, :unset) do
      :unset ->
        path = build_template!()
        :persistent_term.put(@template_key, path)
        path

      cached ->
        cached
    end
  end

  # The template is seeded into the ISOLATED sqlite path by a plain file copy.
  # `File.cp!/2` only READS the template, so the template itself stays
  # byte-identical for the whole run (and no sidecar is ever shared: the copy
  # lives in the test's own temp dir).
  defp seed_isolated_database!(nil, _sqlite_path), do: :ok
  defp seed_isolated_database!(template, sqlite_path), do: File.cp!(template, sqlite_path)

  # Build the migrated template through the SAME code path the isolated store
  # boots with (`EvoGit.Store.Boot.start_dynamic/2`, which opens a
  # single-connection boot repo, runs `Ecto.Migrator.run(…, all: true)` and
  # returns the repo), force the migrated schema out of the WAL into the main
  # file, stop the repo, and PROVE the resulting file is a fully-migrated
  # database. `nil` is returned when no template can be placed or the proof
  # fails — the caller then boots fresh databases exactly as before.
  #
  # `pool_size: 1` is deliberate: the returned repo IS the boot instance (no
  # pool reopen), so the whole build runs on ONE connection.
  defp build_template! do
    case template_destination() do
      nil ->
        nil

      path ->
        # A leftover artifact here is only possible if a previous run died with
        # an identical run-unique dir name; dropping the main file AND its
        # sidecars makes the template always the product of THIS run.
        remove_database_files(path)

        {:ok, repo} = EvoGit.Store.Boot.start_dynamic(path, pool_size: 1)
        :ok = checkpoint_into_main_file!(repo)
        :ok = EvoGit.Store.Boot.stop(repo)

        if main_file_carries_full_schema?(path), do: path, else: nil
    end
  end

  # Push every committed — but not yet checkpointed — WAL frame into the main
  # database file, so a main-file-ONLY copy of it is a COMPLETE database.
  #
  # This is NOT optional. SQLite normally checkpoints and deletes the WAL when
  # the last connection closes, but that clean-close path is NOT reliable here:
  # measured on this host, only 5 of 30 freshly built single-connection
  # templates ended up with the migrated schema in the main file — the rest kept
  # the ENTIRE DDL in a still-present `-wal` (the xqlite NIF resource can hold
  # the handle until it is collected, and a close cannot checkpoint while a
  # statement is unfinalized). With this explicit checkpoint: 30/30.
  # `wal_checkpoint(TRUNCATE)` waits for readers/writers, writes every frame
  # into the main file and truncates the WAL, so the main file is provably
  # complete afterwards.
  defp checkpoint_into_main_file!(repo) do
    previous = EvoGit.Repo.put_dynamic_repo(repo)

    try do
      EvoGit.Repo.query!("PRAGMA wal_checkpoint(TRUNCATE)")
      :ok
    after
      EvoGit.Repo.put_dynamic_repo(previous)
    end
  end

  # Where the run-scoped template lives: inside the run's own `:evo_git,
  # :data_dir` (set by `config/test.exs` to a per-run unique temp dir that
  # `test_helper.exs` removes in its `after_suite` hook).
  #
  # Deliberately NO fallback when the app env is unset: the next candidate is
  # `EvoGit.Platform.data_dir/0`, which on macOS resolves to the developer's
  # real `~/Library/Application Support/genesis` — writing a template there
  # would defeat the whole hermetic-test guarantee. Without a run-scoped data
  # dir the helper simply boots fresh databases exactly as before (correct,
  # just unoptimized).
  defp template_destination do
    case Application.fetch_env(:evo_git, :data_dir) do
      {:ok, dir} when is_binary(dir) -> Path.join(dir, @template_basename)
      _other -> nil
    end
  end

  # The proof that the template is usable: copy ONLY its main file to a scratch
  # path (exactly what every `isolate!/1` call will do) and check that the copy
  # reports every migration in `EvoGit.Store.Boot.migration_source/0` as
  # applied. Ecto inserts each migration's version into `schema_migrations`
  # inside the SAME transaction as its DDL, so "all versions applied" is exactly
  # equivalent to "the boot migrator would be a no-op" — the property the
  # template exists to provide.
  #
  # A copy that fails the check is still a VALID database (a consistent, merely
  # older snapshot): booting it just re-runs the remaining migrations on it. So
  # a failure is a loud WARNING plus a fall-back to freshly booted databases
  # (correct, unoptimized) — never a broken or silently wrong test run.
  defp main_file_carries_full_schema?(path) do
    scratch = path <> ".verify"
    remove_database_files(scratch)
    File.cp!(path, scratch)

    expected = EvoGit.Store.Boot.migration_source() |> Enum.map(&elem(&1, 0)) |> Enum.sort()

    result =
      case applied_migration_versions(scratch) do
        {:ok, ^expected} -> :ok
        {:ok, other} -> {:mismatch, expected, other}
        {:error, reason} -> {:unreadable, reason}
      end

    remove_database_files(scratch)

    case result do
      :ok ->
        true

      other ->
        Logger.warning(
          "IsolatedTaskStore: the migrated template at #{path} failed its self-check " <>
            "(#{inspect(other)}) — per-test stores will boot from a fresh database instead " <>
            "(correct, just without the template speedup)."
        )

        false
    end
  end

  # Opens the given database file and reads its applied migration versions.
  #
  # Justified rescue: the one failure mode this probe exists to detect — a copy
  # that does not carry the schema — is raised by the adapter ("no such table:
  # schema_migrations"), and there is no non-raising variant of that query. The
  # error is RETURNED (never swallowed: it is embedded in the warning above),
  # and the only consequence is falling back to a freshly migrated database.
  defp applied_migration_versions(path) do
    {:ok, repo} = EvoGit.Repo.start_link(database: path, name: nil, pool_size: 1)
    previous = EvoGit.Repo.put_dynamic_repo(repo)

    try do
      rows = EvoGit.Repo.query!("SELECT version FROM schema_migrations").rows
      {:ok, rows |> List.flatten() |> Enum.sort()}
    rescue
      error -> {:error, Exception.message(error)}
    after
      EvoGit.Repo.put_dynamic_repo(previous)
      EvoGit.Store.Boot.stop(repo)
    end
  end

  # Removes a sqlite database file together with any sidecar of its own. Used
  # for the template (so a stale artifact from a crashed run can never be
  # reused) and for the scratch verification copy (so the `-wal`/`-shm` the
  # verification connection may create are cleaned up too).
  defp remove_database_files(path) do
    Enum.each([path | Enum.map(@template_sidecars, &(path <> &1))], fn file ->
      if File.exists?(file), do: File.rm!(file)
    end)
  end

  # Killing a `EvoGit.Store` while offloaded read/write Tasks are still in
  # flight makes those Tasks crash on the vanished ETS query cache, and the
  # Task supervisor logs a `Task #PID<...> started from EvoGit.Store
  # terminating` crash report. That report is EXPECTED noise from tearing down
  # in-flight offloaded Store work — it is captured (and the captured string
  # deliberately discarded) so it never reaches the console from the `on_exit`
  # teardown gap that ExUnit does not capture. Nothing else about the teardown
  # changes: the same actions run, in the same order, with the same results.
  #
  # Used ONLY for the teardown. The setup-time `terminate_production!/0` needs
  # no capture: `setup` runs inside the test's own `capture_log` window (see
  # `isolate!/1`), so wrapping it here would only add the per-window capture
  # cost (measured ~4-5 ms) for no benefit.
  defp capture_teardown_noise(fun) do
    _captured = ExUnit.CaptureLog.capture_log(fun)
    :ok
  end

  @doc """
  The absolute sqlite path the per-run production `EvoGit.Store` is configured
  with (mirrors `EvoGit.Application.start/2`).
  """
  @spec production_sqlite_path() :: String.t()
  def production_sqlite_path do
    Path.join(
      Application.get_env(:evo_git, :data_dir, EvoGit.Platform.data_dir()),
      "tasks.sqlite"
    )
  end

  @doc """
  Assert that the process-global singletons are the production instances —
  i.e. the `EvoGit.Store` name is held by a store opened on
  `production_sqlite_path/0` and `EvoGit.TaskRegistry` is alive with
  `task_store: EvoGit.Store`.

  Raises with a descriptive message otherwise (never masks): a suite that
  depends on the production pair (like `EvoDashWeb.ReviewLiveTest`) must fail
  at the point of contamination instead of reading an empty foreign database.
  """
  @spec assert_production!() :: :ok
  def assert_production! do
    expected = production_sqlite_path()

    case Process.whereis(EvoGit.Store) do
      nil ->
        raise "EvoGit.Store is not running; the production store was never restored"

      store_pid ->
        actual = :sys.get_state(store_pid).data_dir

        if actual != expected do
          raise "EvoGit.Store is bound to #{inspect(actual)}, expected the production " <>
                  "store #{inspect(expected)} — a previous suite leaked an isolated store"
        end
    end

    case Process.whereis(EvoGit.TaskRegistry) do
      nil ->
        raise "EvoGit.TaskRegistry is not running"

      tr_pid ->
        task_store = :sys.get_state(tr_pid).task_store

        if task_store != EvoGit.Store do
          raise "EvoGit.TaskRegistry is bound to task_store #{inspect(task_store)}, " <>
                  "expected EvoGit.Store — a previous suite leaked an isolated registry"
        end
    end

    :ok
  end

  defp terminate_production! do
    Supervisor.terminate_child(EvoGit.Supervisor, EvoGit.TaskRegistry)
    Supervisor.terminate_child(EvoGit.Supervisor, EvoGit.Store)
    :ok
  end

  defp stop_isolated(sup) do
    if isolated_alive?(sup) do
      Supervisor.stop(sup, :normal, 30_000)
    else
      :ok
    end
  catch
    # The isolated supervisor may already be gone (it is linked to the test
    # process, which ExUnit has already terminated when `on_exit` runs, or an
    # earlier teardown step stopped it). Either way the names are released,
    # which is all this step exists to guarantee.
    :exit, _ -> :ok
  end

  # `Supervisor.start_link/2` returns a PID (not a registered name), so the
  # aliveness probe must not be `Process.whereis/1` — that raises
  # "1st argument: not an atom" on a PID. Support both shapes so this helper is
  # total.
  defp isolated_alive?(sup) when is_pid(sup), do: Process.alive?(sup)
  defp isolated_alive?(name) when is_atom(name), do: Process.whereis(name) != nil

  defp restore_production! do
    restart_child!(EvoGit.Store)
    restart_child!(EvoGit.TaskRegistry)
    verify_restored!()
    :ok
  end

  defp restart_child!(child) do
    case Supervisor.restart_child(EvoGit.Supervisor, child) do
      {:ok, _pid} ->
        :ok

      {:error, :running} ->
        :ok

      {:error, {:already_started, pid}} ->
        # The isolated supervisor was stopped before this restart, so this can
        # only happen if some *other* instance still holds the singleton name.
        # Silently ignoring it (the original defect) leaves the globals bound
        # to that instance — every later suite then reads/writes the wrong DB.
        # Fail loudly instead of racing it.
        raise "cannot restore #{inspect(child)}: the singleton name is still held by " <>
                "#{inspect(pid)} — a previous suite leaked an isolated instance"

      {:error, :not_found} ->
        raise "cannot restore #{inspect(child)}: its child spec is gone from " <>
                "EvoGit.Supervisor — the production singleton is unrecoverable " <>
                "for the rest of this test run"

      other ->
        raise "unexpected restart_child/2 result for #{inspect(child)}: #{inspect(other)}"
    end
  end

  defp verify_restored! do
    expected = production_sqlite_path()

    case Process.whereis(EvoGit.Store) do
      nil ->
        raise "EvoGit.Store was not restored after isolation"

      pid ->
        actual = :sys.get_state(pid).data_dir

        if actual != expected do
          raise "EvoGit.Store restored onto #{inspect(actual)}, expected #{inspect(expected)}"
        end
    end

    if Process.whereis(EvoGit.TaskRegistry) == nil do
      raise "EvoGit.TaskRegistry was not restored after isolation"
    end

    :ok
  end
end
