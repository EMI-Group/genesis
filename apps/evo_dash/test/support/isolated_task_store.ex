defmodule EvoDash.Test.IsolatedTaskStore do
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
      so a restore that "succeeded" onto the wrong instance cannot pass.

  Tests that need transactional isolation on top of this can still
  `EvoGit.Store.put_task/2` against the isolated pair as usual.
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
    terminate_production!()

    root =
      Path.join(System.tmp_dir!(), "evogit_test_#{prefix}_#{System.unique_integer([:positive])}")

    File.mkdir_p!(root)
    sqlite_path = Path.join(root, "tasks.sqlite")

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
      # Order matters: release the singleton names FIRST, then restore.
      stop_isolated(sup)
      File.rm_rf(root)
      restore_production!()
    end)

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
    case Process.whereis(sup) do
      nil -> :ok
      _pid -> Supervisor.stop(sup, :normal, 30_000)
    end
  catch
    # The isolated supervisor may already be gone (test process died first, or
    # an earlier teardown step stopped it). Either way the names are released,
    # which is all this step exists to guarantee.
    :exit, _ -> :ok
  end

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
