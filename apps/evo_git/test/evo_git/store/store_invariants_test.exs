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
      written through the store and read back) is a member of
      `Codec.known_opt_keys/0`, so a NEW unregistered key cannot slip in; a key
      missing from the whitelist comes back STRING-keyed (the documented
      failure mode, pinned below);
    * the persisted opt keys split into TWO sets: `Codec.known_atomized_opt_keys/0`
      (⊆ the persisted set, always a strict subset) decodes ATOM-keyed for
      `Keyword.get(opts, :key)` callers, while the remaining data-plane keys
      (`model_id`, `agent`, …) decode STRING-keyed ON PURPOSE because the
      dashboard reads them with `Map.get(Map.new(opts), "key")`;
    * a persisted status this build cannot interpret is `{:unknown, raw}` from
      `Store.get_task_status/2` (never `nil` — the row EXISTS), is masked to a
      LIVE status in the full `%TaskInfo{}` decode, and is classified by
      `EvoGit.TaskRegistry.Lease` as "renew its lease, never pronounced leaked".

  Every test starts its own uniquely-named `EvoGit.Store` GenServer, so nothing
  here touches the shared application store; its database file is a byte copy of
  the module's schema-complete template
  (`EvoGit.TestSupport.StoreTemplate`), so the migrations' DDL is paid once per
  module instead of once per test.
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
  alias EvoGit.TestSupport.StoreTemplate

  # ONE schema-complete template per module; each test copies it and boots its
  # OWN database file from the copy.
  setup_all do
    {:ok, %{copy_db: StoreTemplate.new!()}}
  end

  setup %{copy_db: copy_db} do
    Process.put(:store_template_copy, copy_db)
    :ok
  end

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
  #
  # Split by DECODED SHAPE: `@atomized_opts` come back atom-keyed (read with
  # `Keyword.get/2` inside `evo_git`), `@string_opts` come back STRING-keyed on
  # purpose (read by the dashboard with `Map.get(Map.new(opts), "key")`).
  @atomized_opts [
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
    concurrency: 3,
    tool_concurrency: 2,
    resume_from: "task-0",
    attachments: [
      %{
        "type" => "image",
        "name" => "diagram.png",
        "media_type" => "image/png",
        "data" => "iVBORw0KGgo="
      }
    ],
    quality_level: "fast"
  ]

  @string_opts [
    model_id: "deepseek-chat",
    model_id_locked: true,
    agent: "code_reviewer",
    build_system: "mix",
    merge_from: "task-0",
    merge_target: "main"
  ]

  @persisted_opts @atomized_opts ++ @string_opts

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

  test "every persisted opt key survives the store round trip in its documented shape" do
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

    # Nothing was dropped by the essential-keys fallback or by an unregistered
    # key: the decoded set is exactly the persisted set (normalized to strings,
    # since the two shape families spell keys differently).
    keys = decode_keys(decoded)

    assert Enum.sort(keys) ==
             Enum.sort(Enum.map(@persisted_opts, fn {key, _value} -> Atom.to_string(key) end))

    # …and every one of them is registered in the Codec whitelist (the union of
    # the atomized and the intentionally string-keyed sets). A NEW data-plane
    # key that nobody registers fails HERE.
    known = MapSet.new(Codec.known_opt_keys(), &Atom.to_string/1)

    for key <- keys do
      assert MapSet.member?(known, key),
             "#{inspect(key)} is persisted but not in known_opt_keys/0"
    end

    # Atomized keys come back ATOMS — a caller's `Keyword.get(opts, :key)`
    # finds them…
    for {key, value} <- @atomized_opts do
      assert Keyword.has_key?(decoded, key),
             "#{inspect(key)} came back STRING-keyed but belongs in known_atomized_opt_keys/0"

      assert Keyword.get(decoded, key) == value
    end

    # …while the data-plane keys the dashboard owns stay STRINGS (its lookups
    # are `Map.get(Map.new(task.opts || []), "model_id")`).
    string_decoded = Map.new(decoded)

    for {key, value} <- @string_opts do
      assert Map.fetch(string_decoded, Atom.to_string(key)) == {:ok, value}
      refute Keyword.has_key?(decoded, key)
    end
  end

  test "the atomized opt-key set is a strict subset of the persisted opt-key set" do
    atomized = MapSet.new(Codec.known_atomized_opt_keys())
    persisted = MapSet.new(Codec.known_opt_keys())

    assert MapSet.subset?(atomized, persisted)

    # The two sets are genuinely different: the six dashboard-owned data-plane
    # keys are registered but deliberately NOT atomized.
    assert Enum.sort(MapSet.to_list(atomized)) == Enum.sort(Keyword.keys(@atomized_opts))

    assert Enum.sort(MapSet.to_list(MapSet.difference(persisted, atomized))) ==
             Enum.sort(Keyword.keys(@string_opts))
  end

  test "a row with data-plane and runtime opts decodes to BOTH key shapes (pinned contract)" do
    # This is the cross-app contract: `evo_dash` reads `"model_id"`/`"agent"`
    # by STRING key, `evo_git` reads `:path`/`:objective` by ATOM key. Changing
    # either half breaks the other app — promote a key to the atomized set only
    # together with the dashboard lookups.
    stored =
      Codec.encode_opts(
        path: "/repo/project",
        objective: "build the thing",
        quality_level: "fast",
        model_id: "profile-a",
        agent: "my-agent",
        build_system: "mix"
      )

    decoded = Codec.decode_opts(stored)
    as_map = Map.new(decoded)

    # ATOM-keyed runtime opts.
    assert decoded[:path] == "/repo/project"
    assert decoded[:objective] == "build the thing"
    assert decoded[:quality_level] == "fast"

    # STRING-keyed data-plane opts (the dashboard's form).
    assert as_map["model_id"] == "profile-a"
    assert as_map["agent"] == "my-agent"
    assert as_map["build_system"] == "mix"

    refute Keyword.has_key?(decoded, :model_id)
    refute Keyword.has_key?(decoded, :agent)
    refute Keyword.has_key?(decoded, :build_system)
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

  # Decoded opts mix atom keys (runtime opts) with string keys (data-plane
  # opts), so compare keys in their string spelling.
  defp decode_keys(decoded), do: Enum.map(decoded, fn {key, _value} -> to_string(key) end)

  # Uniquely-named store GenServer on its own tmp SQLite file (the same shape
  # `operations/archives_test.exs` uses for its facade section). The file starts
  # as a copy of the module's schema template.
  defp start_store! do
    unique =
      "#{System.pid()}_#{System.system_time(:millisecond)}_" <>
        "#{System.unique_integer([:positive, :monotonic])}_#{inspect(self())}"

    data_dir = Path.join(System.tmp_dir!(), "evogit_invariants_#{unique}.sqlite")
    name = :"invariants_store_#{unique}"

    # The module's template copy function, put in the test's process dictionary
    # by `setup/1` (a `setup_all` value cannot reach a helper called from a
    # test body). Boot then only has to run the probe-guarded no-op migrations.
    Process.get(:store_template_copy).(data_dir)

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
