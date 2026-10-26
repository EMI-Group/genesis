defmodule EvoGit.Store.StoreInvariantsTest do
  @moduledoc """
  CROSS-MODULE INVARIANTS of the persisted wire contract — the three closed
  whitelists in `EvoGit.Store.Codec` that keep DB-sourced strings from being
  blindly atomized, and the liveness classification that hangs off the status
  one.

  Pinned here:

    * `EvoGit.Store.Types.Status.statuses/0`, `Codec.known_statuses/0` and the
      REAL set of statuses the registry persists are the SAME set — an explicit
      literal in this file, so adding a status in one place without the others
      fails instead of silently degrading a live task;
    * every opt key a persisted task row carries (`%TaskInfo{opts: [...]}`
      written through the store and read back) comes back ATOM-keyed and is a
      member of `Codec.known_opt_keys/0`; a key missing from the whitelist comes
      back STRING-keyed (the documented failure mode, pinned below);
    * a persisted status this build cannot interpret is `{:unknown, raw}` from
      `Store.get_task_status/2` (never `nil` — the row EXISTS), is masked to a
      LIVE status in the full `%TaskInfo{}` decode, and is classified by
      `EvoGit.TaskRegistry.Lease` as "renew its lease, never pronounced leaked".

  Every test starts its own uniquely-named `EvoGit.Store` GenServer, so nothing
  here touches the shared application store.
  """
  use ExUnit.Case, async: true

  import Ecto.Query
  import ExUnit.CaptureLog

  alias EvoGit.Repo
  alias EvoGit.Store
  alias EvoGit.Store.Codec
  alias EvoGit.Store.RepoScope
  alias EvoGit.Store.Schemas.TaskRowRaw
  alias EvoGit.Store.Types.Status
  alias EvoGit.TaskInfo
  alias EvoGit.TaskRegistry.Lease

  # The REAL `tasks.status` values the registry persists, enumerated by hand so
  # this is a check, not a tautology: `:pending` (create), `:running` (start),
  # `:finalizing` (`Runtime.Helpers.notify_finalizing/1`), `:cancelling`
  # (graceful cancel), `:completed` / `:failed` / `:cancelled` (terminal
  # mappings).
  @persisted_statuses [
    :pending,
    :running,
    :finalizing,
    :completed,
    :failed,
    :cancelled,
    :cancelling
  ]

  # One representative VALUE per opt key the data plane persists (CLI flags,
  # dashboard task form, `TaskRegistry.RuntimeOpts`, the merge/resume contexts
  # and the repo-less reflect task). Every value is Jason-encodable, so the
  # `encode_opts/1` essential-keys fallback never kicks in and mask a missing
  # key.
  @persisted_opts [
    path: "/repo/project",
    mode: "simple",
    prompt: "build the thing",
    objective: "build the thing",
    foreign_repos: [%{"id" => "docs", "path" => "/repo/docs", "writable" => false}],
    node_path: "lib/evo_git/",
    starting_commit: "abc1234",
    archive: true,
    task_id: "task-1",
    repo_path: "/repo/project",
    resume_from: "task-0",
    attachments: [
      %{
        "type" => "image",
        "name" => "diagram.png",
        "media_type" => "image/png",
        "data" => "iVBORw0KGgo="
      }
    ],
    quality_level: "fast",
    model_id: "deepseek-chat",
    model_id_locked: true,
    agent: "code_reviewer",
    build_system: "mix",
    merge_from: "task-0",
    merge_target: "main"
  ]

  # ── Status whitelist ─────────────────────────────────────────────────────

  test "the declared statuses are exactly the persisted statuses and the known statuses" do
    assert Enum.sort(Status.statuses()) == Enum.sort(@persisted_statuses)
    assert Enum.sort(Codec.known_statuses()) == Enum.sort(@persisted_statuses)

    # Every one of them is also a known ATOM (the `type`/`status`/`review_status`
    # union the full-row decode uses).
    for status <- @persisted_statuses do
      assert status in Codec.known_atoms(), "#{inspect(status)} is not in known_atoms/0"
    end
  end

  # ── Opts whitelist ───────────────────────────────────────────────────────

  test "every persisted opt key survives the store round trip ATOM-keyed" do
    store = start_store!()

    task = %TaskInfo{
      id: "opt-keys",
      type: :evolve,
      status: :running,
      opts: @persisted_opts,
      started_at: DateTime.utc_now(),
      logs: []
    }

    assert :ok = Store.put_task(store, task)

    assert %TaskInfo{opts: decoded} = Store.get_task(store, "opt-keys")

    keys = Keyword.keys(decoded)

    # Atom-keyed — a caller's `Keyword.get(opts, :key)` finds it.
    refute Enum.any?(keys, &is_binary/1), "an opt key came back as a STRING: #{inspect(decoded)}"

    # …and the full persisted set is covered (nothing was dropped by the
    # essential-keys fallback or by an unregistered key).
    assert Enum.sort(keys) == Enum.sort(Keyword.keys(@persisted_opts))

    # …and every one of them is registered in the Codec whitelist.
    known = MapSet.new(Codec.known_opt_keys())

    for key <- keys do
      assert MapSet.member?(known, key),
             "#{inspect(key)} is persisted but not in known_opt_keys/0"
    end
  end

  test "an opt key outside known_opt_keys/0 comes back STRING-keyed (the failure mode)" do
    # The whitelist is the ONLY atomizer: a key added to the data plane without
    # registering it in `Codec.known_opt_keys/0` persists fine but decodes as a
    # string, so every `Keyword.get(opts, :brand_new_opt)` silently misses.
    decoded = Codec.decode_opts(Codec.encode_opts(brand_new_opt: 1))

    assert decoded == [{"brand_new_opt", 1}]
    refute Keyword.has_key?(decoded, :brand_new_opt)
    refute :brand_new_opt in Codec.known_opt_keys()
  end

  # ── Unknown persisted status ─────────────────────────────────────────────

  test "an unknown persisted status is {:unknown, raw}, never absent and never leaked" do
    store = start_store!()
    id = "unknown-status-1"
    raw_status = "paused_by_a_newer_build"

    assert :ok =
             Store.put_task(store, %TaskInfo{
               id: id,
               type: :genesis,
               status: :running,
               opts: [path: "/repo/project"],
               started_at: DateTime.utc_now(),
               lease_expires_at: System.system_time(:second) + 60,
               logs: []
             })

    # Rewrite ONLY the status cell to a value this build cannot interpret — the
    # shape a downgrade (or a newer build's status) leaves behind.
    RepoScope.with_repo(Store.__repo_pid__(store), fn ->
      Repo.update_all(from(t in TaskRowRaw, where: t.id == ^id), set: [status: raw_status])
    end)

    log =
      capture_log(fn ->
        # The row EXISTS: the narrow status read says "unknown", not "absent".
        assert Store.get_task_status(store, id) == {:unknown, raw_status}
        # An id with no row at all is the ONLY `nil` answer.
        assert Store.get_task_status(store, "no-such-task") == nil
      end)

    assert log =~ "unrecognized task status in DB"
    assert log =~ raw_status

    # The full-row decode cannot carry `{:unknown, _}` in `%TaskInfo{status}`; it
    # masks it as a LIVE status, so no consumer can mistake the row for a
    # terminal/leaked task.
    {task, _log} = with_log(fn -> Store.get_task(store, id) end)
    assert %TaskInfo{status: :pending} = task

    # Liveness classification: renew the lease, never pronounce it leaked.
    assert Lease.lease_renewable?({:unknown, raw_status})
    refute Lease.leaked?({:unknown, raw_status}, true, nil)
    refute Lease.leaked?({:unknown, raw_status}, false, nil)
    refute Lease.leaked?({:unknown, raw_status}, false, 0)

    # …while a KNOWN `:running` row with an expired lease and no owner still is
    # (the classification is conservative, not permissive).
    assert Lease.leaked?(:running, false, 0)
    refute Lease.leaked?(:running, true, 0)
  end

  # ── Helpers ──────────────────────────────────────────────────────────────

  # Uniquely-named store GenServer on its own tmp SQLite file (the same shape
  # `operations/archives_test.exs` uses for its facade section).
  defp start_store! do
    unique =
      "#{System.pid()}_#{System.system_time(:millisecond)}_" <>
        "#{System.unique_integer([:positive, :monotonic])}_#{inspect(self())}"

    data_dir = Path.join(System.tmp_dir!(), "evogit_invariants_#{unique}.sqlite")
    name = :"invariants_store_#{unique}"

    {:ok, pid} = Store.start_link(data_dir: data_dir, name: name, pool_size: 1)
    Process.unlink(pid)

    on_exit(fn ->
      if Process.alive?(pid), do: GenServer.stop(pid, :normal, 5_000), else: :ok
      File.rm(data_dir)
      File.rm(data_dir <> "-wal")
      File.rm(data_dir <> "-shm")
    end)

    name
  end
end
