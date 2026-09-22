defmodule EvoGit.Store.RepoScopeTest do
  @moduledoc """
  Tests for `EvoGit.Store.RepoScope.with_repo/2` — the scoped dynamic-repo
  binding helper.

  `with_repo/2` itself only manipulates the process-dictionary binding, but the
  tests drive REAL unnamed dynamic repo instances
  (`EvoGit.Store.Boot.start_dynamic/1`) so the assertions cover the property
  that actually matters: repo calls made inside the scope target `pid`'s
  database, and the caller's binding is restored afterwards — on the happy
  path, on a raise, and across nesting.

  The default binding of a fresh test process is the canonical NAMED instance
  (the `EvoGit.Repo` module atom — `get_dynamic_repo/0` falls back to it when
  the pdict key is unset), so "restored" means back to that atom here.
  """

  use ExUnit.Case, async: true

  alias EvoGit.Repo
  alias EvoGit.Store.Boot
  alias EvoGit.Store.RepoScope
  alias EvoGit.Store.Schemas.ProjectRow

  @canonical_default Repo

  # ── Helpers ──────────────────────────────────────────────────────────────

  # Starts an unnamed dynamic repo on a UNIQUE tmp database file (per test
  # process, per call — `async: true` safe) and stops it on test exit.
  # Migration compilation inside `Boot.start_dynamic/1` is serialized by the
  # production `:global` lock (see `EvoGit.Store.Boot`).
  #
  # The repo is UNLINKED: `Boot.start_dynamic/1` uses `start_link`, which
  # links the repo to the CALLER (this test process). `on_exit/1` callbacks
  # run AFTER the test process has exited, and the link's exit signal would
  # tear the repo down mid-`Boot.stop/1`, so the unlink keeps ownership of
  # the shutdown with the `on_exit` cleanup.
  defp start_repo!(tag) do
    unique = System.unique_integer([:positive, :monotonic])

    # The name embeds the OS pid + wall-clock ms on top of the per-BEAM unique
    # integer + test pid: `System.unique_integer/1` restarts in every BEAM and
    # test pids are deterministic across runs, so without those a PREVIOUS
    # test run's stale tmp file gets silently adopted.
    path =
      Path.join(
        System.tmp_dir!(),
        "evogit_repo_scope_#{tag}_#{:os.getpid()}_#{System.system_time(:millisecond)}_" <>
          "#{unique}_#{inspect(self())}.sqlite"
      )

    {:ok, pid} = Boot.start_dynamic(path)
    Process.unlink(pid)
    on_exit(fn -> :ok = Boot.stop(pid) end)
    pid
  end

  # ProjectRow's `last_opened_at` is a `Types.TaskTimestamp` — a %DateTime{}
  # dumps to the fixed-ms ISO wire format, so insert_all through the TYPED
  # schema is the correct write path (raw schemas are read-projection only).
  defp insert_project(path, name) do
    Repo.insert_all(ProjectRow, [
      [path: path, name: name, last_opened_at: ~U[2024-05-05 05:05:05.555Z]]
    ])
  end

  defp project_count do
    Repo.aggregate(ProjectRow, :count)
  end

  # ── with_repo/2 happy path ───────────────────────────────────────────────

  describe "with_repo/2 happy path" do
    test "runs fun against pid's dynamic instance and returns fun's result" do
      pid = start_repo!(:happy)

      assert RepoScope.with_repo(pid, fn ->
               {insert_project("/tmp/x", "X"), project_count()}
             end) == {{1, nil}, 1}
    end

    test "writes made inside the scope are readable through the same pid" do
      pid = start_repo!(:readback)

      RepoScope.with_repo(pid, fn -> insert_project("/tmp/y", "Y") end)

      assert RepoScope.with_repo(pid, fn ->
               Repo.get(ProjectRow, "/tmp/y").name
             end) == "Y"
    end

    test "restores the caller's binding afterwards" do
      pid = start_repo!(:restore)

      before = Repo.get_dynamic_repo()
      assert before == @canonical_default

      assert RepoScope.with_repo(pid, fn -> :ok end) == :ok

      assert Repo.get_dynamic_repo() == before
    end
  end

  describe "with_repo/2 restore-on-raise" do
    test "restores the binding when fun raises (the raise still propagates)" do
      pid = start_repo!(:raise)

      before = Repo.get_dynamic_repo()

      assert_raise RuntimeError, "boom", fn ->
        RepoScope.with_repo(pid, fn -> raise "boom" end)
      end

      assert Repo.get_dynamic_repo() == before
    end

    test "restores the binding when fun throws" do
      pid = start_repo!(:throw)

      before = Repo.get_dynamic_repo()

      caught =
        try do
          RepoScope.with_repo(pid, fn -> throw(:thrown) end)
        catch
          :throw, value -> value
        end

      assert caught == :thrown
      assert Repo.get_dynamic_repo() == before
    end

    test "restores the binding when fun exits" do
      pid = start_repo!(:exit)

      before = Repo.get_dynamic_repo()

      catch_exit(RepoScope.with_repo(pid, fn -> exit(:shutdown) end))
      assert Repo.get_dynamic_repo() == before
    end
  end

  describe "with_repo/2 nesting" do
    test "inner with_repo restores the OUTER with_repo's binding, not the original" do
      pid_a = start_repo!(:outer)
      pid_b = start_repo!(:inner)

      original = Repo.get_dynamic_repo()

      RepoScope.with_repo(pid_a, fn ->
        # Inside the outer scope the binding is pid_a.
        assert Repo.get_dynamic_repo() == pid_a

        RepoScope.with_repo(pid_b, fn ->
          insert_project("/tmp/b", "B")

          # Inside the inner scope the binding is pid_b, and its writes land
          # in pid_b's database — NOT pid_a's.
          assert Repo.get_dynamic_repo() == pid_b
          assert project_count() == 1
        end)

        # The inner call restored the OUTER binding — still pid_a.
        assert Repo.get_dynamic_repo() == pid_a
        assert project_count() == 0
      end)

      # Only the outermost call returns the process to its original state.
      assert Repo.get_dynamic_repo() == original
    end

    test "two dynamic instances hold disjoint data" do
      pid_a = start_repo!(:iso_a)
      pid_b = start_repo!(:iso_b)

      RepoScope.with_repo(pid_a, fn -> insert_project("/tmp/a", "A") end)
      RepoScope.with_repo(pid_b, fn -> insert_project("/tmp/b", "B") end)

      assert RepoScope.with_repo(pid_a, fn ->
               {project_count(), Repo.get(ProjectRow, "/tmp/a").name}
             end) == {1, "A"}

      assert RepoScope.with_repo(pid_b, fn ->
               {project_count(), Repo.get(ProjectRow, "/tmp/b").name}
             end) == {1, "B"}
    end
  end

  describe "with_repo/2 argument guards" do
    # Both tests below feed `with_repo/2` DELIBERATELY wrong-typed arguments,
    # so the calls are dispatched through `apply/3`: the compiler's type
    # checker cannot infer the (intentionally invalid) argument types of an
    # indirect dispatch, and the call itself — same function, same arguments,
    # same FunctionClauseError — is unchanged.
    test "rejects a non-pid first argument" do
      bad = :not_a_pid

      assert_raise FunctionClauseError, fn ->
        apply(RepoScope, :with_repo, [bad, fn -> :ok end])
      end
    end

    test "rejects a non-zero-arity fun" do
      pid = start_repo!(:guard)
      fun = fn _arg -> :ok end

      assert_raise FunctionClauseError, fn ->
        apply(RepoScope, :with_repo, [pid, fun])
      end

      assert Repo.get_dynamic_repo() == @canonical_default
    end
  end
end
