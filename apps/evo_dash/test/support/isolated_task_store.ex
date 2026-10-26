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
    * that supervisor is **unlinked** from the test process: ExUnit ends the
      test process with `exit(:shutdown)` *before* any `on_exit` callback runs,
      so a linked pair would be torn down by the test's death, at a point where
      nothing can be ordered;
    * the shutdown itself is **ordered**: registry first (no new read can start),
      then the `TaskRegistry` read workers that registry already started are
      drained (they live under the long-lived `EvoGit.TaskRegistry.ReadSupervisor`
      and would otherwise be mid-`GenServer.call(EvoGit.Store, …)` when the
      store stops), and only then the store — so no read is ever interrupted;
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
  production pair, the temp-dir `mkdir_p!`/`rm_rf`, the read-worker drain
  (normally an empty `Task.Supervisor.children/1` list; one in-flight read
  costs that read's own sub-millisecond duration, not a fixed wait) and
  `stop_isolated/1` — is sub-millisecond. The isolated store boot was the
  remaining term.

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

  # Caller-local (`Process.get/1`) slot holding the PID of the supervisor that
  # owns the isolated pair, recorded by `isolate!/1` and read by
  # `isolated_supervisor/0`.
  @supervisor_key {__MODULE__, :isolated_supervisor}

  @doc """
  The PID of the isolated supervisor the LAST `isolate!/1` call started in the
  CALLING process (`nil` when that process never isolated).

  Exposed only so a suite can pin the lifetime contract that keeps the teardown
  deterministic (see `isolate!/1`): the pair must NOT be linked to the test
  process, because ExUnit ends the test process with `exit(:shutdown)` BEFORE
  any `on_exit` callback runs and a linked pair would be torn down there,
  unordered. Caller-local (`Process.get/1`), so it never crosses processes.
  """
  @spec isolated_supervisor() :: pid() | nil
  def isolated_supervisor, do: Process.get(@supervisor_key)

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

    # Unlink the isolated supervisor from the TEST PROCESS, deliberately —
    # AFTER `on_exit` is registered, so a test process that dies inside this
    # `setup` leaves a pair that is still LINKED (it dies with the test, as it
    # always did) rather than an orphaned unlinked pair holding the singleton
    # names for the rest of the run.
    #
    # ExUnit's test process ends with `exit(:shutdown)` (ExUnit.Runner
    # `spawn_test_monitor/4`) BEFORE `on_exit` callbacks run. A supervisor
    # started with `start_link/2` in `setup` is therefore killed by that exit
    # signal, i.e. the isolated pair is torn down by the TEST's death rather
    # than by this helper's ordered teardown below — and it is torn down at a
    # point where NOTHING can be ordered: a registry read worker still blocked
    # in its `GenServer.call(EvoGit.Store, …)` then sees the store vanish and
    # logs `TaskRegistry: store operation … FAILED` whenever the BEAM happens
    # to schedule it, which is after the between-test log-capture window has
    # already closed (the observed stray `[error]` line).
    #
    # Unlinking keeps the pair alive until `stop_isolated/1` stops it below, so
    # the shutdown becomes ordered (registry first, read workers drained, store
    # last) and deterministic. Nothing depends on the link: this helper's
    # `on_exit` always runs, and it is the one that stops the pair.
    Process.unlink(sup)

    # Cheap, caller-local record of the pair's supervisor, so a suite can pin
    # the lifetime contract without any message passing (see
    # `isolated_supervisor/0`). `Process.put/2` is a dictionary write in the
    # TEST process — nanoseconds, no coordination.
    Process.put(@supervisor_key, sup)

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
    # Same ordered shutdown as the teardown (see `stop_isolated/1`): release
    # the registry, let the read workers it started finish their store calls,
    # and only then stop the store. Setup runs inside the test's own capture
    # window, so an unordered stop would usually be captured — "usually" is
    # exactly the timing dependence this ordering removes.
    Supervisor.terminate_child(EvoGit.Supervisor, EvoGit.TaskRegistry)
    await_read_workers()
    Supervisor.terminate_child(EvoGit.Supervisor, EvoGit.Store)
    :ok
  end

  # Stop the isolated pair in an order that cannot produce a stray log line.
  #
  # Order is load-bearing:
  #
  #   1. stop `EvoGit.TaskRegistry` — it is the ONLY process that starts read
  #      workers, so after it is down no NEW worker can be spawned against the
  #      isolated store (a call queued behind it exits `:noproc` in the CALLER,
  #      which every dashboard call site already handles as a degraded value);
  #   2. `await_read_workers/0` — the workers the registry had already started
  #      live under the LONG-LIVED `EvoGit.TaskRegistry.ReadSupervisor` (a
  #      child of `EvoGit.Supervisor`, NOT of the isolated supervisor, so
  #      stopping the isolated supervisor does not stop them). A worker still
  #      blocked in `GenServer.call(EvoGit.Store, …)` when the store stops exits
  #      with `{:shutdown, {: … GenServer, :call …}}` and logs
  #      `TaskRegistry: store operation … FAILED` from its OWN process — a line
  #      that lands whenever the BEAM schedules it, i.e. typically just outside
  #      the `on_exit` capture window. Waiting here means the store only stops
  #      once no read of it is in flight;
  #   3. stop `EvoGit.Store` — no caller is mid-call, so nothing degrades;
  #   4. stop the (now childless) isolated supervisor, releasing the names.
  defp stop_isolated(sup) do
    if isolated_alive?(sup) do
      Supervisor.terminate_child(sup, EvoGit.TaskRegistry)
      await_read_workers()
      Supervisor.terminate_child(sup, EvoGit.Store)
      Supervisor.stop(sup, :normal, 30_000)
    else
      :ok
    end
  catch
    # The isolated supervisor may already be gone (stopped by an earlier
    # teardown step). Either way the names are released, which is all this step
    # exists to guarantee.
    :exit, _ -> :ok
  end

  # ── Read-worker drain ───────────────────────────────────────────────────
  #
  # `EvoGit.TaskRegistry` offloads every heavy read to a worker under the
  # named `EvoGit.TaskRegistry.ReadSupervisor`, and that supervisor is started
  # ONCE by `EvoGit.Supervisor` at application boot — it is NOT part of the
  # isolated supervisor, so its workers outlive both the isolated registry and
  # the isolated store unless they are waited for. `Task.Supervisor.children/1`
  # is the only handle on them (the registry's own `pending` map dies with the
  # registry), and a monitor is the only deterministic way to know a worker is
  # DONE: a worker replies to its caller only after its store call returned, and
  # exits right after, so the `:DOWN` is the "no store call in flight" proof.
  #
  # The wait is bounded because a wedged read must not wedge the teardown; the
  # bound is far above the slowest observed read (sub-millisecond here, the
  # store's own read deadline is 25 s).
  @read_supervisor EvoGit.TaskRegistry.ReadSupervisor
  @read_drain_timeout 10_000

  defp await_read_workers do
    drain_read_workers(System.monotonic_time(:millisecond) + @read_drain_timeout)
  end

  defp drain_read_workers(deadline) do
    case read_worker_pids() do
      # Nothing in flight: the store can stop without interrupting anybody.
      [] ->
        :ok

      pids ->
        refs = Enum.map(pids, &{Process.monitor(&1), &1})
        all_down? = await_down(refs, deadline)
        Enum.each(refs, fn {ref, _pid} -> Process.demonitor(ref, [:flush]) end)

        cond do
          all_down? ->
            # A second pass only PROVES the property (no new worker can appear:
            # the registry that spawns them is already down); it costs one
            # `children/1` call and leaves as soon as that list is empty.
            drain_read_workers(deadline)

          true ->
            # Bounded fallback for a read that cannot finish: kill the workers
            # the same way a supervisor shutdown would (they are `:temporary`,
            # so nothing restarts), so they can never log after the store is
            # gone. Every dashboard caller runs its read inside
            # `EvoDash.SafeCall`, which turns the missing reply into a degraded
            # value rather than a crash.
            Enum.each(pids, &Task.Supervisor.terminate_child(@read_supervisor, &1))
            :ok
        end
    end
  end

  defp await_down([], _deadline), do: true

  defp await_down([{ref, pid} | rest], deadline) do
    remaining = max(deadline - System.monotonic_time(:millisecond), 0)

    receive do
      {:DOWN, ^ref, :process, ^pid, _reason} -> await_down(rest, deadline)
    after
      remaining -> false
    end
  end

  defp read_worker_pids do
    if Process.whereis(@read_supervisor), do: Task.Supervisor.children(@read_supervisor), else: []
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
