defmodule EvoGit.Store.SessionModeFilterTest do
  @moduledoc """
  The `:session_mode` predicate of the shared task-list WHERE builder
  (`EvoGit.Store.Operations.Filters.where_filters/2`), pinned through the
  LIGHTWEIGHT page read the dashboard actually uses
  (`EvoGit.Store.select_tasks_page/2`).

  The dashboard's Tasks page used to apply the session-kind filter by scanning
  the whole SQL-filtered result set in memory (50 rows per RPC). `tasks` carries
  a real TEXT `session_mode` column, so the filter belongs in SQL — and once it
  is there, the single read's `count(*) OVER ()` reports the FILTERED total, so
  the rendered rows, `total` and pagination must all agree.

  Pinned here:

    * `"oneshot"` admits a stored NULL cell (the canonical `"oneshot"` — see
      `EvoGit.Store.Codec.decode_session_mode/1`, which also normalizes a blank
      cell) and the stored `"oneshot"` TEXT, while excluding interactive rows;
    * `"interactive"` matches exactly the interactive rows, and its `total`
      excludes every other row;
    * absent / `"all"` / an unknown value mean NO clause (every row);
    * the predicate composes with `:status` and `:search`;
    * the limit/offset clamp still applies to the filtered set (an
      out-of-range offset lands on the LAST page of the FILTERED rows, with the
      filtered total unchanged).

  Isolation: every test starts its OWN uniquely-named `EvoGit.Store` GenServer
  on its own SQLite file, which is a byte copy of the module's schema-complete
  template (`EvoGit.TestSupport.StoreTemplate`), so no shared application state
  is touched and the module runs `async: true`.
  """

  use ExUnit.Case, async: true

  alias EvoGit.Repo
  alias EvoGit.Store
  alias EvoGit.Store.RepoScope
  alias EvoGit.TaskInfo
  alias EvoGit.TestSupport.StoreTemplate

  @base ~U[2024-06-06 06:06:06.000Z]

  setup_all do
    {:ok, %{copy_db: StoreTemplate.new!()}}
  end

  setup %{copy_db: copy_db} do
    Process.put(:store_template_copy, copy_db)
    :ok
  end

  describe "(filter semantics)" do
    test "\"oneshot\" admits a stored NULL cell and the stored value, never interactive" do
      store = start_store!()

      :ok = Store.put_task(store, task("one-a", 1, session_mode: "oneshot"))
      :ok = Store.put_task(store, task("one-b", 2, session_mode: "oneshot"))
      :ok = Store.put_task(store, task("int-a", 3, session_mode: "interactive"))
      legacy = insert_raw_null_session_mode!(store, "legacy-null", 4)

      # The raw cell really is NULL — not the "oneshot" value.
      assert [[nil]] = raw_rows(store, "SELECT session_mode FROM tasks WHERE id = ?", [legacy])

      assert %{rows: rows, total: 3} =
               Store.select_tasks_page(store,
                 filters: [session_mode: "oneshot"],
                 limit: 50
               )

      # `started_at DESC`: legacy-null (4), one-b (2)… and one-a (1).
      assert Enum.map(rows, & &1.id) == ["legacy-null", "one-b", "one-a"]
      assert Enum.all?(rows, &(&1.session_mode == "oneshot"))
    end

    test "a legacy BLANK cell counts as one-shot too (Codec.decode_session_mode/1)" do
      store = start_store!()

      :ok = Store.put_task(store, task("one-a", 1, session_mode: "oneshot"))
      :ok = Store.put_task(store, task("int-a", 2, session_mode: "interactive"))
      blank = task("legacy-blank", 3, session_mode: "oneshot")
      :ok = Store.put_task(store, blank)
      blank_session_mode!(store, blank.id)

      assert [[stored]] =
               raw_rows(store, "SELECT session_mode FROM tasks WHERE id = ?", [blank.id])

      # The public writer normalizes, the raw UPDATE leaves the blank cell.
      assert stored in [nil, ""]

      assert %{rows: rows, total: 2} =
               Store.select_tasks_page(store,
                 filters: [session_mode: "oneshot"],
                 limit: 50
               )

      assert Enum.map(rows, & &1.id) == ["legacy-blank", "one-a"]
      assert Enum.all?(rows, &(&1.session_mode == "oneshot"))
    end

    test "\"interactive\" matches only interactive rows and its total excludes the rest" do
      store = start_store!()

      :ok = Store.put_task(store, task("one-a", 1, session_mode: "oneshot"))
      :ok = Store.put_task(store, task("int-a", 2, session_mode: "interactive"))
      :ok = Store.put_task(store, task("int-b", 3, session_mode: "interactive"))
      _legacy = insert_raw_null_session_mode!(store, "legacy-null", 4)

      assert %{rows: rows, total: 2} =
               Store.select_tasks_page(store,
                 filters: [session_mode: "interactive"],
                 limit: 50
               )

      assert Enum.map(rows, & &1.id) == ["int-b", "int-a"]
      assert Enum.all?(rows, &(&1.session_mode == "interactive"))
    end

    test "absent, \"all\" and an unknown value mean no clause" do
      store = start_store!()

      :ok = Store.put_task(store, task("one-a", 1, session_mode: "oneshot"))
      :ok = Store.put_task(store, task("int-a", 2, session_mode: "interactive"))
      _legacy = insert_raw_null_session_mode!(store, "legacy-null", 3)

      for filters <- [[], [session_mode: "all"], [session_mode: "bogus"], [session_mode: nil]] do
        assert %{rows: rows, total: 3} =
                 Store.select_tasks_page(store, filters: filters, limit: 50),
               "expected no clause for #{inspect(filters)}"

        assert Enum.map(rows, & &1.id) == ["legacy-null", "int-a", "one-a"]
      end
    end
  end

  describe "(composition and pagination)" do
    test "composes with :status and :search over the same row set" do
      store = start_store!()

      :ok =
        Store.put_task(
          store,
          task("one-done", 1, session_mode: "oneshot", objective: "alpha objective")
        )

      :ok =
        Store.put_task(
          store,
          task("one-run", 2, session_mode: "oneshot", status: :running, objective: "alpha run")
        )

      :ok =
        Store.put_task(
          store,
          task("int-done", 3, session_mode: "interactive", objective: "alpha chat")
        )

      :ok =
        Store.put_task(
          store,
          task("int-run", 4,
            session_mode: "interactive",
            status: :running,
            objective: "beta chat"
          )
        )

      assert %{rows: [only], total: 1} =
               Store.select_tasks_page(store,
                 filters: [session_mode: "oneshot", status: "completed"],
                 limit: 50
               )

      assert only.id == "one-done"

      assert %{rows: rows, total: 1} =
               Store.select_tasks_page(store,
                 filters: [session_mode: "interactive", status: "running", search: "beta"],
                 limit: 50
               )

      assert Enum.map(rows, & &1.id) == ["int-run"]

      # `search` alone (no session_mode) still reaches the same rows.
      assert %{rows: searched, total: 1} =
               Store.select_tasks_page(store, filters: [search: "beta chat"], limit: 50)

      assert Enum.map(searched, & &1.id) == ["int-run"]

      assert %{rows: both, total: 1} =
               Store.select_tasks_page(store,
                 filters: [session_mode: "interactive", status: "completed"],
                 limit: 50
               )

      assert Enum.map(both, & &1.id) == ["int-done"]
    end

    test "the limit/offset clamp applies to the FILTERED set, not the whole table" do
      store = start_store!()

      for i <- 1..3 do
        :ok = Store.put_task(store, task("one-#{i}", i, session_mode: "oneshot"))
      end

      for i <- 4..6 do
        :ok = Store.put_task(store, task("int-#{i}", i, session_mode: "interactive"))
      end

      assert %{rows: page, total: 3} =
               Store.select_tasks_page(store,
                 filters: [session_mode: "oneshot"],
                 limit: 2,
                 offset: 0
               )

      assert Enum.map(page, & &1.id) == ["one-3", "one-2"]

      assert %{rows: second, total: 3} =
               Store.select_tasks_page(store,
                 filters: [session_mode: "oneshot"],
                 limit: 2,
                 offset: 2
               )

      assert Enum.map(second, & &1.id) == ["one-1"]

      # An out-of-range offset lands on the LAST page of the filtered set — with
      # the FILTERED total (3), never the table's 6.
      assert %{rows: clamped, total: 3} =
               Store.select_tasks_page(store,
                 filters: [session_mode: "oneshot"],
                 limit: 2,
                 offset: 999
               )

      assert Enum.map(clamped, & &1.id) == ["one-1"]

      # The same clamp for interactive rows picks interactive rows only.
      assert %{rows: int_clamped, total: 3} =
               Store.select_tasks_page(store,
                 filters: [session_mode: "interactive"],
                 limit: 2,
                 offset: 999
               )

      assert Enum.map(int_clamped, & &1.id) == ["int-4"]
    end
  end

  # ── Helpers ───────────────────────────────────────────────────────────────

  # Uniquely-named store GenServer on its own tmp SQLite file (the idiom
  # `awaiting_input_roundtrip_test.exs` uses). The file starts as a copy of the
  # module's schema template, so boot only runs the probe-guarded no-op
  # migrations.
  defp start_store! do
    unique =
      "#{System.pid()}_#{System.system_time(:millisecond)}_" <>
        "#{System.unique_integer([:positive, :monotonic])}_#{inspect(self())}"

    data_dir = Path.join(System.tmp_dir!(), "evogit_session_mode_#{unique}.sqlite")
    name = :"session_mode_store_#{unique}"

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

  defp task(id, seconds, overrides) do
    struct(
      %TaskInfo{
        id: id,
        type: :evolve,
        status: :completed,
        opts: [path: "/tmp/repo", objective: Keyword.get(overrides, :objective, "obj #{id}")],
        started_at: DateTime.add(@base, seconds, :second),
        finished_at: DateTime.add(@base, seconds, :second)
      },
      Keyword.drop(overrides, [:objective])
    )
  end

  # Raw INSERT that OMITS `session_mode`, so SQLite stores NULL — the exact
  # shape a row written before the column existed (or by an older build) has.
  defp insert_raw_null_session_mode!(store, id, seconds) do
    started_at =
      @base
      |> DateTime.add(seconds, :second)
      |> DateTime.to_iso8601()

    opts = ~s({"path":"/tmp/repo","objective":"legacy #{id}"})

    raw_query!(
      store,
      """
      INSERT INTO tasks (id, type, status, opts, started_at, updated_at)
      VALUES (?, ?, ?, ?, ?, ?)
      """,
      [id, "evolve", "completed", opts, started_at, started_at]
    )

    id
  end

  defp blank_session_mode!(store, id) do
    raw_query!(store, "UPDATE tasks SET session_mode = '' WHERE id = ?", [id])
    id
  end

  defp raw_rows(store, sql, params) do
    raw_query!(store, sql, params).rows
  end

  defp raw_query!(store, sql, params) do
    repo = Store.__repo_pid__(store)
    RepoScope.with_repo(repo, fn -> Repo.query!(sql, params) end)
  end
end
