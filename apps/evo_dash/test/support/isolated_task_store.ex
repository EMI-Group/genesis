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
    * the build FINISHES materialization before it returns: immediately after
      `EvoGit.Store.Boot.stop/1` it deletes the leftover `-wal`/`-shm` sidecars.
      `stop/1` returns as soon as the pool is down, but SQLite's last-connection
      WAL cleanup — the step that UNLINKS those sidecars — runs asynchronously
      afterwards, at an arbitrary later moment. Measured on this host over 120
      builds: `-wal` (0 bytes) and `-shm` (32 KiB) were still on disk at the
      instant `stop/1` returned in 120 of 120 builds, and they vanished
      microseconds-to-milliseconds later (the template's main-file fd was *also*
      still open in 22 of 120). Left in place, that asynchronous deletion
      changes the template's on-disk fingerprint at a moment nobody controls —
      which is exactly what made the byte-identity assertion in
      `test/evo_dash/isolated_task_store_test.exs` flake. After the `TRUNCATE`
      checkpoint above the WAL is empty, so the sidecars hold no data and the
      last close can only ever UNLINK files (it never creates or writes one):
      deleting them here makes the template ONE immutable file for the whole
      run;
    * the build is ATOMIC: it runs at a private, run-unique build path in the
      DESTINATION's own directory, is PROVEN there, and only then is renamed onto
      the destination (`File.rename/2`, atomic within one directory / volume).
      No caller can ever observe a partially built artifact, and two builders can
      never migrate the same file — the destination name only ever comes into
      existence complete and read-only;
    * the build then PROVES the result by copying the template's main file alone
      and asserting the copy reports every version in
      `EvoGit.Store.Boot.migration_source/0` as applied (0.2 ms, once per run).
      A template that fails the proof is REMOVED (with ONE warning naming the
      attempt, the destination and the failure) and the run boots fresh
      databases as before — correct either way, and a rejected artifact can
      never be mistaken for a good one;
    * a FAILED build is NEVER cached: only a build that passed its self-check
      publishes a path, so a failure is retried (a bounded number of attempts,
      no sleeping) by the next caller instead of being handed to every caller
      for the rest of the run. That is the difference between one interrupted
      build and a whole-suite cascade of "the template is not there";
    * a proven template is then made READ-ONLY, so an accidental shared write
      (a store opened on the template instead of on a copy) fails loudly instead
      of silently corrupting every later isolation;
    * each test gets its OWN file inside its OWN temp dir; the template is only
      ever read (`File.cp/2`), never written, and sidecars are never shared;
    * a published path is re-checked with one `File.stat/1` per call, so an
      artifact deleted behind this module's back is REBUILT rather than handed
      out dead (the recorded cascade also had that shape: a cached path whose
      file no longer existed);
    * a template whose content were ever older than expected is still CORRECT:
      the migrator is idempotent and would simply re-run the remaining
      migrations on the copy.
  """

  # Caller-local (`Process.get/1`) slot holding the PID of the supervisor that
  # owns the isolated pair, recorded by `isolate!/1` and read by
  # `isolated_supervisor/0`.
  @supervisor_key {__MODULE__, :isolated_supervisor}

  # The store/registry state reads below can be starved for seconds on a loaded
  # host (a Store call path contends on the sqlite writer queue), where
  # `:sys.get_state/1`'s 5 s default exits the caller.
  @wait_budget_ms 30_000

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
    template = store_template_path()

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
  # Cached in `:persistent_term` under a BINARY path, with `:unset` as the
  # "never resolved" marker. A FAILED build is NEVER cached, so `:unset` is the
  # only non-path state the cache can hold: publishing the result of a failed
  # build (as this helper once did) handed a `nil`/dead path to every later
  # caller for the remainder of the run, which is exactly how one interrupted
  # build turned into a cascade of failures in suites that never touched the
  # template themselves. One `put` per run: `:persistent_term` writes are
  # expensive, reads are not.
  @template_key {__MODULE__, :template_path}
  @template_basename "isolated_store_template.sqlite"
  @template_sidecars ["-wal", "-shm", "-journal"]

  # How many times ONE resolution tries to PRODUCE a template before it reports
  # the failure. A build can lose its artifact to an actor outside this module
  # (the recorded failure was a `File.Error` on the final `chmod` of a freshly
  # written file, i.e. the file was gone before it could be published), so the
  # whole attempt — build at a NEW unique path, prove, rename — is repeated
  # instead of degrading the rest of the run to fresh databases. No
  # `Process.sleep`: every attempt is a real build (~10–15 ms), so the retries
  # only cost anything once something has already gone wrong.
  @build_attempts 3

  @doc """
  The absolute path of the run-scoped, already-migrated sqlite TEMPLATE, or
  `nil` when no template could be placed/proven (a caller then boots a fresh
  database, which is correct).

  Public because `EvoDash.Test.IsolatedVCT` seeds its PRIVATE per-test store from
  this SAME artifact: one artifact per run, built once, shared read-only.

  A path is published here ONLY after a build that PASSED its self-check, so a
  failure is never cached and the next caller rebuilds instead of inheriting
  it. A published path is re-checked per call (one `File.stat/1`), so an
  artifact deleted behind this module's back is rebuilt rather than returned
  dead.

  The build is serialized by a `:global` lock (a lock that cannot be taken
  answers `nil`, i.e. the fresh-database path) because the dashboard's
  `async: true` suites resolve it concurrently from their `setup` callbacks. The
  lock's requester id is `self/0`, so the lock really is process-scoped: with a
  constant requester every caller looks like the SAME requester and would be
  granted it concurrently.
  """
  @spec store_template_path() :: Path.t() | nil
  def store_template_path do
    case :persistent_term.get(@template_key, :unset) do
      :unset -> resolve_template()
      cached -> cached_template_path(cached)
    end
  end

  # The cached path is honoured only while its artifact is really there. It is
  # deleted behind this module's back in recorded failures (nothing in the suite
  # `rm_rf`s the run data dir, so the deleter is something else), and handing
  # such a path to a caller means the caller's `File.cp!/2` fails or, worse, a
  # suite asserts on a template that is not there. One `File.stat/1` per call
  # (microseconds) buys that guarantee.
  defp cached_template_path(path) when is_binary(path) do
    if File.regular?(path) do
      path
    else
      Logger.warning(
        "IsolatedTaskStore: the cached migrated template #{path} is gone (deleted " <>
          "outside this module); dropping the cache entry and rebuilding it before " <>
          "handing a path to a caller."
      )

      :persistent_term.erase(@template_key)
      resolve_template()
    end
  end

  # A failed build is never published, so anything that is not a path in the
  # cache can only be a leftover from an older revision of this helper. Never
  # honour it — treat it as "never resolved".
  defp cached_template_path(other) do
    Logger.warning(
      "IsolatedTaskStore: discarding a non-path template cache entry " <>
        "(#{inspect(other)}); rebuilding instead of handing it to a caller."
    )

    :persistent_term.erase(@template_key)
    resolve_template()
  end

  defp resolve_template do
    case :global.trans({{__MODULE__, :template_path}, self()}, &build_and_cache_template/0) do
      :aborted -> nil
      path -> path
    end
  end

  # The build itself, run while holding the `:global` lock `resolve_template/0`
  # takes. The cache is re-read INSIDE the lock, so concurrent first callers
  # (`EvoDash.Test.IsolatedVCT` reaches this from `async: true` setups) build the
  # artifact exactly ONCE.
  defp build_and_cache_template do
    case :persistent_term.get(@template_key, :unset) do
      :unset ->
        # PUBLISH ONLY A PASSED BUILD. A `nil` here is a failure the caller
        # already handled (fresh database); caching it would convert that ONE
        # failure into every later caller's result for the rest of the run, so
        # nothing is stored and the next caller retries.
        case build_template() do
          path when is_binary(path) ->
            :persistent_term.put(@template_key, path)
            path

          nil ->
            nil
        end

      cached ->
        cached
    end
  end

  @doc """
  Copy the run-scoped migrated template onto `sqlite_path`, so a private
  `EvoGit.Store` booted there runs the boot migrator as a verified no-op.

  Answers `:ok`. When no template is available, the target is left ABSENT and
  the caller's store migrates the fresh file itself — correct, just slower.
  """
  @spec seed_store!(Path.t()) :: :ok
  def seed_store!(sqlite_path) when is_binary(sqlite_path) do
    seed_isolated_database!(store_template_path(), sqlite_path)
  end

  # The template is seeded into the ISOLATED sqlite path by a plain file copy.
  # `File.cp/2` only READS the template, so the template itself stays
  # byte-identical for the whole run (and no sidecar is ever shared: the copy
  # lives in the test's own temp dir).
  #
  # `File.cp/2` ALSO carries the source's permissions, and the template is
  # READ-ONLY (see `publish_template/2`) — so the copy needs owner write back,
  # or the isolated store could not write a single row. 0600 keeps the copy as
  # private as its 0700 temp dir.
  defp seed_isolated_database!(nil, _sqlite_path), do: :ok

  defp seed_isolated_database!(template, sqlite_path), do: seed_copy(template, sqlite_path, 1)

  # The artifact can be deleted between `store_template_path/0`'s check and this
  # copy (the same unexplained deletion the build defends against). That ONE
  # outcome is not a caller's problem: drop the dead cache entry and let a
  # rebuild re-seed. Bounded, and it never turns a missing DESTINATION directory
  # into a rebuild (`File.cp/2` answers `:enoent` for both, so the two are told
  # apart by re-checking the template itself).
  defp seed_copy(nil, _sqlite_path, _attempt), do: :ok

  defp seed_copy(template, sqlite_path, attempt) do
    case File.cp(template, sqlite_path) do
      :ok ->
        File.chmod!(sqlite_path, 0o600)

      {:error, :enoent} when attempt < 2 ->
        if File.regular?(template) do
          raise "cannot seed #{sqlite_path} from the migrated template #{template}: " <>
                  "the destination could not be created (no such file or directory)"
        else
          :persistent_term.erase(@template_key)
          seed_copy(store_template_path(), sqlite_path, attempt + 1)
        end

      {:error, :enoent} ->
        # A template that keeps vanishing is handled exactly like one that could
        # not be built: leave the target ABSENT (the caller's store then migrates
        # the fresh file itself) and say so once.
        Logger.warning(
          "IsolatedTaskStore: the migrated template #{template} vanished again while " <>
            "seeding #{sqlite_path}; leaving the target absent so its store migrates " <>
            "a fresh database (correct, just without the template speedup)."
        )

        :ok

      {:error, reason} ->
        raise "cannot seed #{sqlite_path} from the migrated template #{template}: " <>
                inspect(reason)
    end
  end

  # Produce the migrated template, retrying the whole attempt a bounded number
  # of times (see `@build_attempts`). `nil` means "no template for this call":
  # either no destination exists, or the artifact could not be proven — a caller
  # then boots a fresh database exactly as before. A build that RAISES keeps
  # raising (with the attempt count and the destination in the message), because
  # an unreadable/unwritable destination is a real environment failure that a
  # silent fallback would hide.
  defp build_template do
    case template_destination() do
      nil -> nil
      destination -> attempt_build(destination, 1)
    end
  end

  defp attempt_build(destination, attempt) when attempt <= @build_attempts do
    case build_attempt(destination, attempt) do
      {:ok, path} ->
        path

      {:failed, kind, detail} ->
        cond do
          attempt < @build_attempts ->
            attempt_build(destination, attempt + 1)

          kind == :build_error ->
            raise_build_error(destination, attempt, detail)

          true ->
            # One warning for the failed resolution — naming HOW MANY attempts
            # were made, WHY the last one failed and the exact path, so a future
            # run's log says whether the artifact was deleted, unreadable or
            # failed its self-check.
            warn_build_failure(destination, attempt, kind, detail)
            nil
        end
    end
  end

  # ONE build attempt, at a PRIVATE path: the destination is never written, so
  # nothing half-built is visible under the published name and no concurrent
  # builder can touch the file this one is migrating. `build_path/2` is unique
  # per attempt, so there is never a stale artifact to clear first.
  defp build_attempt(destination, attempt) do
    temp = build_path(destination, attempt)

    try do
      build_migrated_database!(temp)

      case verify_template(temp) do
        :ok -> publish_template(temp, destination)
        {:error, detail} -> {:failed, :self_check, detail}
      end
    rescue
      # A raise anywhere in the build (an unwritable destination directory, a
      # vanished temp file, a SQLite I/O error) is a FAILED ATTEMPT, not a
      # crash: the retry loop above decides whether to try again or report.
      # Nothing is cached either way.
      error -> {:failed, :build_error, {error, __STACKTRACE__}}
    after
      # Never leave a half-built artifact (or its sidecars) behind for the next
      # attempt or caller. On the success path `publish_template/2` has already
      # RENAMED `temp` away, so this removes nothing.
      remove_database_files(temp)
    end
  end

  # A UNIQUE build path in the DESTINATION's own directory: same volume, so the
  # publish below is one atomic `File.rename/2` (never a cross-device copy); one
  # per attempt, so two builders can never migrate the same file; and
  # dot-PREFIXED, so it can never be mistaken for the published template (a
  # `Path.wildcard(template <> "*")` cannot see it).
  defp build_path(destination, attempt) do
    Path.join(
      Path.dirname(destination),
      ".#{Path.basename(destination)}.build-#{attempt}-#{System.unique_integer([:positive])}"
    )
  end

  # Build the migrated database at `path` through the SAME code path the isolated
  # store boots with (`EvoGit.Store.Boot.start_dynamic/2`, which opens a
  # single-connection boot repo, runs `Ecto.Migrator.run(…, all: true)` and
  # returns the repo), force the migrated schema out of the WAL into the main
  # file, stop the repo, and FINISH materialization (delete the leftover
  # sidecars) so the file is exactly ONE immutable artifact.
  #
  # `pool_size: 1` is deliberate: the returned repo IS the boot instance (no
  # pool reopen), so the whole build runs on ONE connection.
  defp build_migrated_database!(path) do
    {:ok, repo} = EvoGit.Store.Boot.start_dynamic(path, pool_size: 1)

    try do
      :ok = checkpoint_into_main_file!(repo)
    after
      # The repo must never stay open on a file this module is about to rename or
      # remove: a lingering handle keeps writing `-wal`/`-shm` and can recreate
      # what `finalize_template!/1` just deleted.
      :ok = EvoGit.Store.Boot.stop(repo)
    end

    :ok = finalize_template!(path)
    :ok
  end

  # Publish ATOMICALLY: the artifact is made read-only while it still has its
  # private build name, then renamed ONTO the destination. `File.rename/2` is
  # atomic within one directory, so a caller either sees no template at all or a
  # complete, proven, read-only one — never a partially built or half-deleted
  # file — and the read-only mode is in force from the instant the name exists.
  #
  # The race this handles explicitly: the destination's DIRECTORY disappearing
  # between the self-check and the rename (the run's `:evo_git` data dir removed
  # by a concurrent `after_suite` hook, or by whatever deleted the template in
  # the recorded failures) makes `File.rename/2` answer `{:error, :enoent}` even
  # though the artifact itself is fine. That is reported as a retryable
  # `:publish` failure; a retry rebuilds (re-creating the directory through
  # `EvoGit.Store.Boot.start_dynamic/2`) at a NEW path, and a directory that is
  # really gone for good ends as one warning plus the fresh-database fallback.
  defp publish_template(temp, destination) do
    File.chmod!(temp, 0o444)

    case File.rename(temp, destination) do
      :ok ->
        if File.regular?(destination) do
          {:ok, destination}
        else
          {:failed, :publish, {:vanished, destination}}
        end

      {:error, reason} ->
        {:failed, :publish, {:rename, reason}}
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

  # Finish materializing a built database: delete whatever sidecars the finished
  # build left behind, so it is exactly ONE file from the moment
  # `build_migrated_database!/1` returns (and, once renamed, from the moment
  # `publish_template/2` makes the template's name exist).
  #
  # This is NOT cosmetic, and it is the one thing `EvoGit.Store.Boot.stop/1`
  # cannot do for us. `stop/1` returns as soon as the pool is down, but SQLite's
  # LAST-CONNECTION WAL cleanup — the step that UNLINKS `-wal`/`-shm` — runs
  # afterwards, asynchronously, at a moment nobody controls. Measured on this
  # host over 120 template builds: `-wal` (0 bytes) and `-shm` (32 KiB) were
  # still on disk at the instant `stop/1` returned in 120 of 120 builds (and the
  # main-file descriptor was still open in 22 of 120), and they were gone
  # microseconds-to-milliseconds later. Left in place, that deletion changes the
  # template's on-disk fingerprint between two snapshots taken around an
  # unrelated `isolate!/1` call — which is precisely what made
  # `test/evo_dash/isolated_task_store_test.exs`'s byte-identity assertion flake
  # (once in a six-run sample of the full suite; the template is built by
  # whichever `async: false` suite isolates first, so the deferred deletion can
  # land inside a later suite's snapshot window).
  #
  # Deleting them here is safe and deterministic: the explicit
  # `TRUNCATE` checkpoint above already folded every committed frame into the
  # main file, so a 0-byte `-wal` and its `-shm` wal-index carry no data, and the
  # only thing the asynchronous last close can still do is UNLINK files — it
  # never creates or writes one. After this call the sidecars are absent for the
  # rest of the run, and no lingering handle can change the template again.
  defp finalize_template!(path) do
    Enum.each(@template_sidecars, &remove_file!(path <> &1))
    :ok
  end

  # Where the run-scoped template lives: inside the run's own `:evo_git,
  # :data_dir` (set by `config/test.exs` to a per-run unique temp dir that
  # `test_helper.exs` removes in its `after_suite` hook).
  #
  # The path is therefore unique PER BEAM RUN, which is what makes the artifact
  # safe to share between every suite of this run: `config/test.exs` derives the
  # data dir from the OS pid plus an Erlang-unique integer, so two concurrent
  # `mix test` runs (or two Genesis worker worktrees under one `TMPDIR`) can
  # never resolve the same template file.
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
  # Answers `:ok` or `{:error, detail}`; the DETAIL is what the caller's single
  # warning reports, so a failed build names the failure precisely (`mismatch`
  # with both version lists, or `unreadable` with the adapter's message). A copy
  # that fails the check is still a VALID database (a consistent, merely older
  # snapshot) — hence a warning plus the fresh-database fallback rather than a
  # raise.
  defp verify_template(path) do
    scratch = path <> ".verify"
    remove_database_files(scratch)
    File.cp!(path, scratch)

    expected = EvoGit.Store.Boot.migration_source() |> Enum.map(&elem(&1, 0)) |> Enum.sort()

    result =
      case applied_migration_versions(scratch) do
        {:ok, ^expected} -> :ok
        {:ok, other} -> {:error, {:mismatch, expected, other}}
        {:error, reason} -> {:error, {:unreadable, reason}}
      end

    remove_database_files(scratch)
    result
  end

  # ONE warning per failed resolution, naming HOW MANY attempts were made, WHY
  # the last one failed and the exact path. Deliberately one line: the failure is
  # not cached, so later callers retry (and log their own), and the run continues
  # with freshly migrated per-test databases.
  defp warn_build_failure(destination, attempts, kind, detail) do
    Logger.warning(
      "IsolatedTaskStore: no usable migrated template after #{attempts} build " <>
        "attempt(s) — #{failure_label(kind)}: #{describe_failure(detail)}; " <>
        "destination: #{destination}. Nothing was cached, so the next caller rebuilds " <>
        "and every per-test store boots from a fresh database meanwhile (correct, just " <>
        "without the template speedup)."
    )
  end

  # A build that RAISED on every attempt is a real environment failure (an
  # unwritable/missing destination directory, a SQLite I/O error, a file deleted
  # mid-build). It keeps raising — with the attempt count and the destination in
  # the banner — because a silent fallback would hide it. Nothing is cached, so
  # the raise is confined to the caller that hit it.
  defp raise_build_error(destination, attempts, {error, stacktrace}) do
    message =
      "IsolatedTaskStore: the migrated template build failed on all #{attempts} " <>
        "attempt(s) — nothing was cached, so a later caller will retry. " <>
        "destination: #{destination}; cause: " <> Exception.format_banner(:error, error)

    reraise RuntimeError.exception(message), stacktrace
  end

  defp failure_label(:self_check), do: "the artifact failed its self-check"
  defp failure_label(:publish), do: "the artifact could not be published"
  defp failure_label(:build_error), do: "the build raised"

  defp describe_failure({:mismatch, expected, actual}),
    do: "applied migration versions #{inspect(actual)} do not match #{inspect(expected)}"

  defp describe_failure({:unreadable, reason}), do: "the artifact was unreadable (#{reason})"

  defp describe_failure({:rename, reason}),
    do: "the rename into place failed (#{inspect(reason)})"

  defp describe_failure({:vanished, path}), do: "the published file is not there (#{path})"

  defp describe_failure(other), do: inspect(other)

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
  # for a failed/interrupted BUILD path (so a half-built artifact can never be
  # reused and the temp file never outlives its attempt), and for the scratch
  # verification copy (so the `-wal`/`-shm` the verification connection may
  # create are cleaned up too). The published template is never passed here:
  # publishing is a rename, and its sidecars are removed before that.
  #
  # Every removal tolerates `:enoent` (nothing there) and `:enotdir` (the path's
  # parent is not a directory, so no file can exist at the path — the state a
  # failed build in an unbuildable destination starts and ends in). SQLite's
  # last-close cleanup also UNLINKS the sidecars of a stopped database
  # asynchronously (see `finalize_template!/1`), so it can race this function
  # for the very files it is deleting: losing that race is the desired end state,
  # not an error.
  defp remove_database_files(path) do
    Enum.each([path | Enum.map(@template_sidecars, &(path <> &1))], &remove_file!/1)
  end

  defp remove_file!(path) do
    case File.rm(path) do
      :ok -> :ok
      {:error, :enoent} -> :ok
      {:error, :enotdir} -> :ok
      {:error, reason} -> raise "cannot remove #{path}: #{inspect(reason)}"
    end
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
        actual = :sys.get_state(store_pid, @wait_budget_ms).data_dir

        if actual != expected do
          raise "EvoGit.Store is bound to #{inspect(actual)}, expected the production " <>
                  "store #{inspect(expected)} — a previous suite leaked an isolated store"
        end
    end

    case Process.whereis(EvoGit.TaskRegistry) do
      nil ->
        raise "EvoGit.TaskRegistry is not running"

      tr_pid ->
        task_store = :sys.get_state(tr_pid, @wait_budget_ms).task_store

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
        actual = :sys.get_state(pid, @wait_budget_ms).data_dir

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
