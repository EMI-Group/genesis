defmodule EvoGit.StoreTest do
  use ExUnit.Case, async: false

  alias EvoGit.Repo
  alias EvoGit.Store
  alias EvoGit.Store.Codec
  alias EvoGit.Store.RepoScope
  alias EvoGit.TaskInfo
  alias EvoGit.RecentProject

  # The 16 summary keys returned by select_tasks_changed_since/2 (same
  # projection as select_tasks_summary, plus the raw `updated_at` string;
  # `result` is deliberately excluded — no summary consumer reads it). `error`
  # IS included (nil except on :failed rows).
  @summary_keys [
    :id,
    :status,
    :review_status,
    :started_at,
    :finished_at,
    :type,
    :project_path,
    :opts,
    :branch_name,
    :model_id,
    :agent_count,
    :base_sha,
    :commit_sha,
    :lease_expires_at,
    :updated_at,
    :error
  ]

  # The production Store/TaskRegistry are owned by this module for its whole
  # run: they are terminated ONCE here (TaskRegistry depends on Store, so it
  # goes down first) and restored after the last test. This module is
  # `async: false` because it mutates that shared production supervision tree.
  #
  # It also builds a schema-complete SQLite TEMPLATE once. Creating a brand-new
  # SQLite file + running the DDL costs ~24ms per test (the single biggest cost
  # in this file); copying that checkpointed template costs ~2ms. Each test
  # still gets its own isolated DB file with the identical schema, so isolation
  # semantics are unchanged.
  setup_all do
    unique = System.unique_integer([:positive])
    # OS pid + wall-clock ms on top of the per-BEAM counter: the counter alone
    # restarts on a fresh node and would collide with a previous run's leftover
    # tmp file.
    stamp = "#{unique}_#{:os.getpid()}_#{System.system_time(:millisecond)}"
    template = Path.join(System.tmp_dir!(), "evogit_store_template_#{stamp}.sqlite")
    template_name = :"store_template_#{unique}"

    Supervisor.terminate_child(EvoGit.Supervisor, EvoGit.TaskRegistry)
    Supervisor.terminate_child(EvoGit.Supervisor, EvoGit.Store)

    # Register the restore BEFORE building the template, so a template-build
    # failure can never leave the production children down for the whole run.
    on_exit(fn ->
      File.rm(template)
      File.rm(template <> "-wal")
      File.rm(template <> "-shm")
      Supervisor.restart_child(EvoGit.Supervisor, EvoGit.Store)
      Supervisor.restart_child(EvoGit.Supervisor, EvoGit.TaskRegistry)
    end)

    # A real Store.init produces exactly the schema under test. Stopping the
    # template store closes the last connection to its WAL-mode database, and
    # SQLite's own implicit checkpointing on last-connection-close folds the
    # WAL back into the main file and removes the `-wal`/`-shm` sidecars (its
    # documented default behavior — the read-write connection PRAGMAs are
    # `journal_mode: :wal` / `synchronous: :normal`, and NOTHING in the store
    # runs an explicit `wal_checkpoint`). The result is a single self-contained
    # file that is safe to byte-copy.
    {:ok, _} = Store.start_link(data_dir: template, name: template_name)
    :ok = GenServer.stop(template_name)

    {:ok, %{template: template}}
  end

  # Fresh isolated Store per test on a unique tmp SQLite path, seeded by copying
  # the schema template. The production children are already down (see
  # setup_all), so the isolated store can claim the default `EvoGit.Store` name.
  setup %{template: template} do
    unique = System.unique_integer([:positive])
    stamp = "#{unique}_#{:os.getpid()}_#{System.system_time(:millisecond)}"
    root = Path.join(System.tmp_dir!(), "evogit_test_store_#{stamp}")
    File.mkdir_p!(root)
    sqlite_path = Path.join(root, "tasks.sqlite")
    File.cp!(template, sqlite_path)

    start_supervised({Store, data_dir: sqlite_path})

    on_exit(fn -> File.rm_rf(root) end)

    {:ok, %{store: Store, sqlite_path: sqlite_path, root: root}}
  end

  # One archived agent's entry in the PRODUCER's shape (atom keys), covering
  # every column of `task_agent_archives`. `depth` also picks the agent type so
  # a roster read has something distinct to order by.
  defp archive_entry(task_id, agent_id, depth) do
    %{
      task_id: task_id,
      agent_id: agent_id,
      parent_id: if(depth == 0, do: nil, else: agent_id - 1),
      depth: depth,
      agent_type: if(depth == 0, do: "manager", else: "executor"),
      context_node_path: "./",
      objective: "archive objective #{agent_id}",
      result: "archived result #{agent_id}",
      base_commit: "base-#{agent_id}",
      final_commit: "final-#{agent_id}",
      branch_name: "evogit-agent-T1-A#{agent_id}",
      archive_ref_start: "ref-start-#{agent_id}",
      archive_ref_final: "ref-final-#{agent_id}",
      repo_id: 0,
      repo_root: "/tmp/archive-repo",
      repo_path: "apps/demo",
      usage: %{"input_tokens" => 10 * agent_id, "total_cost" => 0.5},
      llm_settings: %{"model_id" => "test-model"},
      agent_settings: %{"turns" => 3},
      foreign_repos: [],
      compression_count: 1,
      started_at: "2026-01-01T00:00:00.000Z",
      completed_at: "2026-01-01T00:10:00.000Z"
    }
  end

  describe "task put/get round-trip" do
    test "all scalar fields survive a put/get round-trip" do
      task = %TaskInfo{
        id: "rt-1",
        type: :genesis,
        status: :completed,
        opts: [path: "/tmp/test", mode: "simple"],
        ref: nil,
        started_at: ~U[2026-06-26 07:19:44Z],
        finished_at: ~U[2026-06-26 08:00:00Z],
        logs: [],
        result: nil,
        review_status: :ignored,
        agent_count: 5,
        base_sha: "abc123",
        commit_sha: "def456",
        model_id: "gpt-4o"
      }

      :ok = Store.put_task(Store, task)
      fetched = Store.get_task(Store, "rt-1")

      assert %TaskInfo{} = fetched
      assert fetched.id == "rt-1"
      assert fetched.type == :genesis
      assert fetched.status == :completed
      assert fetched.review_status == :ignored
      assert fetched.agent_count == 5
      assert fetched.base_sha == "abc123"
      assert fetched.commit_sha == "def456"
      assert fetched.model_id == "gpt-4o"
      assert fetched.ref == nil
    end

    test "DateTime fields survive as proper DateTime structs" do
      task = %TaskInfo{
        id: "rt-dt",
        type: :genesis,
        status: :completed,
        opts: [path: "/tmp/test"],
        started_at: ~U[2026-06-26 07:19:44Z],
        finished_at: ~U[2026-06-26 08:00:00Z],
        logs: [],
        result: nil
      }

      :ok = Store.put_task(Store, task)
      fetched = Store.get_task(Store, "rt-dt")

      assert %DateTime{} = fetched.started_at
      assert %DateTime{} = fetched.finished_at
      assert DateTime.compare(fetched.started_at, fetched.finished_at) == :lt
    end

    test "opts keyword list round-trips with atom keys" do
      task = %TaskInfo{
        id: "rt-opts",
        type: :evolve,
        status: :completed,
        opts: [path: "/tmp/proj", mode: "complex", prompt: "hello world"],
        started_at: DateTime.utc_now(),
        finished_at: DateTime.utc_now(),
        logs: [],
        result: nil
      }

      :ok = Store.put_task(Store, task)
      fetched = Store.get_task(Store, "rt-opts")

      assert is_list(fetched.opts)
      assert fetched.opts[:path] == "/tmp/proj"
      assert fetched.opts[:mode] == "complex"
      assert fetched.opts[:prompt] == "hello world"
    end

    test "logs list round-trips" do
      task = %TaskInfo{
        id: "rt-logs",
        type: :genesis,
        status: :running,
        opts: [path: "/tmp/test"],
        started_at: DateTime.utc_now(),
        finished_at: nil,
        logs: ["line 1", "line 2", "line 3"],
        result: nil
      }

      :ok = Store.put_task(Store, task)
      fetched = Store.get_task(Store, "rt-logs")

      assert fetched.logs == ["line 1", "line 2", "line 3"]
    end

    test "result opaque term (tuple with atom keys) round-trips" do
      task = %TaskInfo{
        id: "rt-result",
        type: :evolve,
        status: :completed,
        opts: [path: "/tmp/test"],
        started_at: DateTime.utc_now(),
        finished_at: DateTime.utc_now(),
        logs: [],
        result:
          {:ok,
           %{
             commit_sha: "abc123def",
             branch_name: "evogit/test",
             result: "Agent summary",
             pr_url: nil,
             pr_title: nil
           }}
      }

      :ok = Store.put_task(Store, task)
      fetched = Store.get_task(Store, "rt-result")

      assert {:ok, %{commit_sha: "abc123def", branch_name: "evogit/test"}} = fetched.result
    end

    test "result {:ok, map} with embedded Usage struct round-trips faithfully" do
      usage = %EvoGit.Agent.Usage{
        input_tokens: 100,
        output_tokens: 50,
        total_tokens: 150,
        input_cost: 0.01,
        output_cost: 0.02,
        total_cost: 0.03,
        cached_tokens: 10,
        cache_creation_tokens: 5
      }

      task = %TaskInfo{
        id: "rt-result-usage",
        type: :evolve,
        status: :completed,
        opts: [path: "/tmp/test"],
        started_at: DateTime.utc_now(),
        finished_at: DateTime.utc_now(),
        logs: [],
        result:
          {:ok,
           %{
             commit_sha: "deadbeef",
             result: "All done",
             tag: "v1.0",
             branch_name: "evogit/feature",
             pr_url: nil,
             pr_title: nil,
             usage: usage,
             agent_count: 3
           }}
      }

      :ok = Store.put_task(Store, task)
      fetched = Store.get_task(Store, "rt-result-usage")

      assert {:ok, data} = fetched.result
      assert data.commit_sha == "deadbeef"
      assert data.result == "All done"
      assert data.tag == "v1.0"
      assert data.branch_name == "evogit/feature"
      assert data.pr_url == nil
      assert data.pr_title == nil
      assert data.agent_count == 3

      assert %EvoGit.Agent.Usage{} = data.usage
      assert data.usage.input_tokens == 100
      assert data.usage.output_tokens == 50
      assert data.usage.total_tokens == 150
      assert data.usage.total_cost == 0.03
      assert data.usage.cached_tokens == 10
      assert data.usage.cache_creation_tokens == 5
    end

    test "result {:ok, no_changes} round-trips" do
      task = %TaskInfo{
        id: "rt-result-nochanges",
        type: :evolve,
        status: :completed,
        opts: [path: "/tmp/test"],
        started_at: DateTime.utc_now(),
        finished_at: DateTime.utc_now(),
        logs: [],
        result:
          {:ok,
           %{
             commit_sha: "x",
             result: "Nothing to do",
             branch_name: nil,
             pr_url: nil,
             pr_title: nil,
             no_changes: true,
             usage: %EvoGit.Agent.Usage{},
             agent_count: 1
           }}
      }

      :ok = Store.put_task(Store, task)
      fetched = Store.get_task(Store, "rt-result-nochanges")

      assert {:ok, data} = fetched.result
      assert data.no_changes == true
      assert data.branch_name == nil
      assert data.result == "Nothing to do"
      assert %EvoGit.Agent.Usage{} = data.usage
    end

    test "result {:error, string} round-trips" do
      task = %TaskInfo{
        id: "rt-result-error",
        type: :evolve,
        status: :failed,
        opts: [path: "/tmp/test"],
        started_at: DateTime.utc_now(),
        finished_at: DateTime.utc_now(),
        logs: [],
        result: {:error, "something went wrong"}
      }

      :ok = Store.put_task(Store, task)
      fetched = Store.get_task(Store, "rt-result-error")

      assert fetched.result == {:error, "something went wrong"}
    end

    test "result {:exit, atom} round-trips" do
      task = %TaskInfo{
        id: "rt-result-exit",
        type: :evolve,
        status: :failed,
        opts: [path: "/tmp/test"],
        started_at: DateTime.utc_now(),
        finished_at: DateTime.utc_now(),
        logs: [],
        result: {:exit, :killed}
      }

      :ok = Store.put_task(Store, task)
      fetched = Store.get_task(Store, "rt-result-exit")

      assert fetched.result == {:exit, :killed}
    end

    test "result plain string round-trips" do
      task = %TaskInfo{
        id: "rt-result-string",
        type: :evolve,
        status: :failed,
        opts: [path: "/tmp/test"],
        started_at: DateTime.utc_now(),
        finished_at: DateTime.utc_now(),
        logs: [],
        result: "Process crashed while task was running"
      }

      :ok = Store.put_task(Store, task)
      fetched = Store.get_task(Store, "rt-result-string")

      assert fetched.result == "Process crashed while task was running"
    end

    test "result {:error, complex term} round-trips via inspect fallback" do
      task = %TaskInfo{
        id: "rt-result-complex-error",
        type: :evolve,
        status: :failed,
        opts: [path: "/tmp/test"],
        started_at: DateTime.utc_now(),
        finished_at: DateTime.utc_now(),
        logs: [],
        result: {:error, {:bad_match, [1, 2, 3]}}
      }

      :ok = Store.put_task(Store, task)
      fetched = Store.get_task(Store, "rt-result-complex-error")

      # The complex tuple can't be JSON-encoded directly, so it falls back to
      # inspect — but the tuple shape {:error, _} is preserved.
      assert {:error, reason} = fetched.result
      assert is_binary(reason)
    end

    test "result nil round-trips" do
      task = %TaskInfo{
        id: "rt-result-nil",
        type: :evolve,
        status: :completed,
        opts: [path: "/tmp/test"],
        started_at: DateTime.utc_now(),
        finished_at: DateTime.utc_now(),
        logs: [],
        result: nil
      }

      :ok = Store.put_task(Store, task)
      fetched = Store.get_task(Store, "rt-result-nil")

      assert fetched.result == nil
    end

    test "usage struct round-trips as EvoGit.Agent.Usage" do
      usage = %EvoGit.Agent.Usage{
        input_tokens: 100,
        output_tokens: 50,
        total_tokens: 150,
        input_cost: 0.01,
        output_cost: 0.02,
        total_cost: 0.03,
        cached_tokens: 10,
        cache_creation_tokens: 5
      }

      task = %TaskInfo{
        id: "rt-usage",
        type: :genesis,
        status: :completed,
        opts: [path: "/tmp/test"],
        started_at: DateTime.utc_now(),
        finished_at: DateTime.utc_now(),
        logs: [],
        result: nil,
        usage: usage
      }

      :ok = Store.put_task(Store, task)
      fetched = Store.get_task(Store, "rt-usage")

      assert %EvoGit.Agent.Usage{} = fetched.usage
      assert fetched.usage.input_tokens == 100
      assert fetched.usage.output_tokens == 50
      assert fetched.usage.total_tokens == 150
      assert fetched.usage.total_cost == 0.03
      assert fetched.usage.cached_tokens == 10
    end

    test "a task row carries no archive payload (the archive is its own table)" do
      :ok =
        Store.put_task(Store, %TaskInfo{
          id: "rt-no-archive",
          type: :genesis,
          status: :completed,
          opts: [path: "/tmp/test"],
          started_at: DateTime.utc_now(),
          finished_at: DateTime.utc_now(),
          logs: [],
          result: nil
        })

      fetched = Store.get_task(Store, "rt-no-archive")

      # `%TaskInfo{}` has no archive field at all any more: the per-agent
      # archive lives in the relational `task_agent_archives` table, read
      # through `list_task_archives/3` (see the archive describes below).
      refute Map.has_key?(fetched, :archive_metadata)
      assert Store.list_task_archives(Store, "rt-no-archive") == %{entries: [], total: 0}
    end

    test "nil fields stay nil" do
      task = %TaskInfo{
        id: "rt-nil",
        type: :genesis,
        status: :pending,
        opts: [path: "/tmp/test"],
        started_at: DateTime.utc_now(),
        finished_at: nil,
        logs: [],
        result: nil,
        usage: nil,
        error: nil
      }

      :ok = Store.put_task(Store, task)
      fetched = Store.get_task(Store, "rt-nil")

      assert fetched.finished_at == nil
      assert fetched.result == nil
      assert fetched.usage == nil
      assert fetched.error == nil
    end

    test "error map survives put/get round-trip with canonical atom keys" do
      error = %{
        kind: :force_kill,
        source: :force_kill_task,
        message: "Task force-killed by user",
        stacktrace: ["(elixir) lib/foo.ex:1: Foo.bar/0"]
      }

      task = %TaskInfo{
        id: "rt-err",
        type: :genesis,
        status: :failed,
        opts: [path: "/tmp/test"],
        started_at: DateTime.utc_now(),
        finished_at: DateTime.utc_now(),
        logs: [],
        result: nil,
        error: error
      }

      :ok = Store.put_task(Store, task)
      fetched = Store.get_task(Store, "rt-err")

      assert fetched.status == :failed
      assert fetched.error == error
      assert fetched.error.kind == :force_kill
      assert fetched.error.source == :force_kill_task
      assert fetched.error.message == "Task force-killed by user"

      # A fetched (decoded) task re-puts cleanly — the canonical atom payload
      # round-trips (the error is never dropped by a re-encode).
      assert :ok = Store.put_task(Store, fetched)
      fetched2 = Store.get_task(Store, "rt-err")
      assert fetched2.error == error
    end

    test "ref is always nulled before persistence" do
      task = %TaskInfo{
        id: "rt-ref",
        type: :genesis,
        status: :running,
        opts: [path: "/tmp/test"],
        ref: make_ref(),
        started_at: DateTime.utc_now(),
        finished_at: nil,
        logs: [],
        result: nil
      }

      :ok = Store.put_task(Store, task)
      fetched = Store.get_task(Store, "rt-ref")

      assert fetched.ref == nil
    end
  end

  describe "updated_at column" do
    # Force the store-internal updated_at column to a known value via raw SQL
    # (it is not part of %TaskInfo{}, so it can't be set through put_task).
    defp set_updated_at!(sqlite_path, id, iso_string) do
      {:ok, conn} = Xqlite.open(sqlite_path)

      {:ok, _} =
        XqliteNIF.execute(conn, "UPDATE tasks SET updated_at = ?1 WHERE id = ?2", [
          iso_string,
          id
        ])

      :ok = XqliteNIF.close(conn)
    end

    defp raw_updated_at(sqlite_path, id) do
      {:ok, conn} = Xqlite.open(sqlite_path)

      {:ok, %{rows: [[updated_at]]}} =
        XqliteNIF.query(conn, "SELECT updated_at FROM tasks WHERE id = ?1", [id])

      :ok = XqliteNIF.close(conn)
      updated_at
    end

    test "put_task stamps updated_at with a fixed-precision ISO timestamp ≈ now", %{
      sqlite_path: sqlite_path
    } do
      :ok =
        Store.put_task(Store, %TaskInfo{
          id: "upd-put",
          type: :genesis,
          status: :completed,
          opts: [path: "/tmp/test"],
          started_at: DateTime.utc_now(),
          finished_at: DateTime.utc_now(),
          logs: [],
          result: nil
        })

      # updated_at is store-internal — only visible via raw query (or the
      # summary projection), not via get_task/1's %TaskInfo{} decode.
      updated_at = raw_updated_at(sqlite_path, "upd-put")

      assert updated_at =~ ~r/^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}\.\d{3}Z$/
      {:ok, dt, _offset} = DateTime.from_iso8601(updated_at)
      diff_seconds = DateTime.diff(DateTime.utc_now(), dt, :second)
      # Load-robust: the store stamps "now", so the only meaningful assertion is
      # that it is recent (not a stale/bogus value). The bound is generous so a
      # descheduled test process under heavy machine load cannot fail it.
      assert diff_seconds >= 0 and diff_seconds <= 60
    end

    test "update_task_columns bumps updated_at to ≈ now", %{sqlite_path: sqlite_path} do
      :ok =
        Store.put_task(Store, %TaskInfo{
          id: "upd-col",
          type: :genesis,
          status: :pending,
          opts: [path: "/tmp/test"]
        })

      # Force updated_at to a known old value, then update a column.
      set_updated_at!(sqlite_path, "upd-col", "2000-01-01T00:00:00.000Z")
      :ok = Store.update_task_columns(Store, "upd-col", status: :running)

      updated_at = raw_updated_at(sqlite_path, "upd-col")
      refute updated_at == "2000-01-01T00:00:00.000Z"
      assert updated_at =~ ~r/^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}\.\d{3}Z$/
      {:ok, dt, _offset} = DateTime.from_iso8601(updated_at)
      diff_seconds = DateTime.diff(DateTime.utc_now(), dt, :second)
      # Load-robust (see the put_task case above): assert "recent", not an
      # exact instant.
      assert diff_seconds >= 0 and diff_seconds <= 60

      # The targeted update itself also took effect.
      assert Store.get_task_status(Store, "upd-col") == :running
    end

    test "update_lease_expires_at does NOT bump updated_at", %{sqlite_path: sqlite_path} do
      :ok =
        Store.put_task(Store, %TaskInfo{
          id: "upd-lease",
          type: :genesis,
          status: :running,
          opts: [path: "/tmp/test"]
        })

      set_updated_at!(sqlite_path, "upd-lease", "2000-01-01T00:00:00.000Z")

      # The 60s lease heartbeat must NOT bump updated_at.
      :ok = Store.update_lease_expires_at(Store, "upd-lease", 1_700_000_000)

      assert raw_updated_at(sqlite_path, "upd-lease") == "2000-01-01T00:00:00.000Z"

      # But the lease column itself was updated.
      {:ok, conn} = Xqlite.open(sqlite_path)

      {:ok, %{rows: [[lease]]}} =
        XqliteNIF.query(conn, "SELECT lease_expires_at FROM tasks WHERE id = ?1", ["upd-lease"])

      :ok = XqliteNIF.close(conn)
      assert lease == 1_700_000_000
    end

    test "select_tasks_changed_since returns only rows newer than the since boundary", %{
      sqlite_path: sqlite_path
    } do
      for {id, ts} <- [
            {"cs-1", "2026-01-01T00:00:00.000Z"},
            {"cs-2", "2026-01-02T00:00:00.000Z"},
            {"cs-3", "2026-01-03T00:00:00.000Z"}
          ] do
        :ok =
          Store.put_task(Store, %TaskInfo{
            id: id,
            type: :genesis,
            status: :completed,
            opts: [path: "/tmp/test"]
          })

        set_updated_at!(sqlite_path, id, ts)
      end

      # since before all rows → all three returned.
      all = Store.select_tasks_changed_since(Store, "2025-01-01T00:00:00.000Z")
      assert Enum.map(all, & &1.id) |> Enum.sort() == ["cs-1", "cs-2", "cs-3"]

      # since between cs-2 and cs-3 → only cs-3 (strict `>`: boundary-equal
      # cs-2 and older cs-1 are excluded).
      rows = Store.select_tasks_changed_since(Store, "2026-01-02T00:00:00.000Z")
      assert Enum.map(rows, & &1.id) == ["cs-3"]
      refute Enum.any?(rows, &(&1.id == "cs-2"))
      refute Enum.any?(rows, &(&1.id == "cs-1"))

      # Far-future since → empty.
      assert Store.select_tasks_changed_since(Store, "2099-01-01T00:00:00.000Z") == []

      # 16-key summary projection contract, with raw updated_at string.
      [row] = rows
      assert Map.keys(row) |> Enum.sort() == Enum.sort(@summary_keys)
      assert row.updated_at == "2026-01-03T00:00:00.000Z"
      assert row.status == :completed
      assert row.error == nil
    end
  end

  describe "Codec result/opts round-trips" do
    test "encode_result/decode_result round-trip tagged tuples and strings" do
      # {:ok, map} with atom keys (known result-data fields atomize back).
      assert Codec.decode_result(
               Codec.encode_result({:ok, %{commit_sha: "abc", branch_name: "b"}})
             ) == {:ok, %{commit_sha: "abc", branch_name: "b"}}

      # {:error, string} — an unknown reason stays a string.
      # The reason MUST be a unique string, never a fixed literal like "boom":
      # Codec.decode_reason/1 restores a PRE-EXISTING atom via String.to_existing_atom/1,
      # so the round-trip stays a string only while no module anywhere in the suite
      # happens to contain that atom literal (e.g. a test using `:boom` would flip it).
      reason = "boom_#{System.unique_integer([:positive])}"
      assert Codec.decode_result(Codec.encode_result({:error, reason})) == {:error, reason}

      # {:exit, reason} — existing atoms round-trip as atoms.
      assert Codec.decode_result(Codec.encode_result({:exit, :killed})) == {:exit, :killed}

      # Plain string crash fallback → canonical "string" tag, decoded back.
      assert Codec.decode_result(Codec.encode_result("raw fallback")) == "raw fallback"

      # Legacy raw string (no `{`/`[` prefix) — no longer canonical, raises.
      assert_raise ArgumentError, fn -> Codec.decode_result("no-json-here") end

      # Untagged JSON object — no longer canonical, raises.
      assert_raise ArgumentError, fn -> Codec.decode_result(Jason.encode!(%{"a" => 1})) end

      # Untagged JSON array — no longer canonical, raises.
      assert_raise ArgumentError, fn -> Codec.decode_result("[1,2,3]") end

      # Non-JSON-encodable term → string-tagged inspect fallback, decodes back
      # to the inspect string (not the original term).
      assert Codec.decode_result(Codec.encode_result({:weird_term, 1})) == "{:weird_term, 1}"

      # nil passthrough.
      assert Codec.encode_result(nil) == nil
      assert Codec.decode_result(nil) == nil
    end

    test "encode_opts/decode_opts round-trip keyword lists with boolean values" do
      opts = [path: "/tmp/p", archive: true, mode: "simple"]
      encoded = Codec.encode_opts(opts)

      # JSON object with STRING keys (not the legacy positional array).
      assert encoded == ~s({"archive":true,"mode":"simple","path":"/tmp/p"})

      decoded = Codec.decode_opts(encoded)
      # Decode iterates the JSON object's keys, so compare sorted (order of a
      # keyword list is not preserved through a JSON object).
      assert Enum.sort(decoded) == Enum.sort(opts)
      assert Keyword.get(decoded, :archive) == true
      assert Keyword.get(decoded, :path) == "/tmp/p"
      assert Keyword.get(decoded, :mode) == "simple"

      # Legacy positional pair-array encoding (array of [key, value] pairs) —
      # no longer canonical (only JSON objects with string keys are), raises.
      assert_raise ArgumentError, fn -> Codec.decode_opts(~s([["path","/x"]])) end

      # nil passthrough.
      assert Codec.encode_opts(nil) == nil
      assert Codec.decode_opts(nil) == nil
    end

    test ":attachments opts round-trip with the ATOM key and exact value (base64 string)" do
      attachments = [
        %{
          "type" => "image",
          "name" => "a.png",
          "media_type" => "image/png",
          "data" => Base.encode64("raw1")
        },
        %{
          "type" => "audio",
          "name" => "b.mp3",
          "media_type" => "audio/mpeg",
          "data" => Base.encode64("raw2")
        }
      ]

      opts = [path: "/tmp/p", attachments: attachments]

      decoded = Codec.decode_opts(Codec.encode_opts(opts))

      # The JSON object round-trip sorts keys (opts is a keyword list, decode
      # iterates the object's keys), so compare via Keyword.get.
      assert Keyword.has_key?(decoded, :attachments)
      assert decoded[:attachments] == attachments
      assert is_list(decoded[:attachments])
      assert hd(decoded[:attachments])["type"] == "image"
    end

    test ":attachments full task put/get round-trip keeps the atom key and base64 value" do
      attachments = [
        %{
          "type" => "image",
          "name" => "a.png",
          "media_type" => "image/png",
          "data" => Base.encode64("raw-bytes")
        }
      ]

      task = %TaskInfo{
        id: "rt-attachments",
        type: :evolve,
        status: :completed,
        opts: [path: "/tmp/proj", objective: "do it", attachments: attachments],
        started_at: DateTime.utc_now(),
        finished_at: DateTime.utc_now(),
        logs: [],
        result: nil
      }

      :ok = Store.put_task(Store, task)
      fetched = Store.get_task(Store, "rt-attachments")

      assert Keyword.get(fetched.opts, :attachments) == attachments
      assert hd(fetched.opts[:attachments])["data"] == Base.encode64("raw-bytes")
    end

    test "essential-keys fallback drops :attachments for a deliberately non-Jason-safe payload" do
      # Base64 data is Jason-safe by contract, so the full encode normally
      # succeeds. When an UNRELATED opt carries a non-Jason-safe term (a pid),
      # the fallback encodes only path/mode/prompt/objective and :attachments
      # is dropped — pinning the existing fallback behavior.
      opts = [
        path: "/tmp/p",
        objective: "obj",
        attachments: [
          %{"type" => "image", "name" => "a.png", "media_type" => "image/png", "data" => "aGk="}
        ],
        bad_term: self()
      ]

      encoded = Codec.encode_opts(opts)
      refute encoded =~ "attachments"
      decoded = Codec.decode_opts(encoded)
      refute Keyword.has_key?(decoded, :attachments)
      assert Keyword.get(decoded, :path) == "/tmp/p"
      assert Keyword.get(decoded, :objective) == "obj"
    end
  end

  describe "Codec error encode/decode" do
    # The canonical failed-task error payload: fixed key set, atom kind/source
    # (closed sets), string message, list-of-strings stacktrace or nil.
    defp canonical_error do
      %{
        kind: :force_kill,
        source: :force_kill_task,
        message: "Task force-killed by user",
        stacktrace: [
          "(elixir) lib/foo.ex:1: Foo.bar/0",
          "(stdlib) erl_eval.erl:1: :erl_eval.do_apply/6"
        ]
      }
    end

    test "nil encodes and decodes to nil" do
      assert Codec.encode_error(nil) == nil
      assert Codec.decode_error(nil) == nil
      assert Codec.decode_error(Codec.encode_error(nil)) == nil
    end

    test "full canonical map round-trips with atom keys and atom kind/source" do
      assert Codec.decode_error(Codec.encode_error(canonical_error())) == canonical_error()
    end

    test "storage JSON uses string keys and string kind/source values" do
      json = Codec.encode_error(canonical_error())
      assert is_binary(json)

      decoded = Jason.decode!(json)
      assert Map.keys(decoded) |> Enum.sort() == ["kind", "message", "source", "stacktrace"]
      assert decoded["kind"] == "force_kill"
      assert decoded["source"] == "force_kill_task"
      assert decoded["message"] == "Task force-killed by user"
      assert decoded["stacktrace"] |> length() == 2
    end

    test "kind/source values outside the closed set stay strings (lenient decode)" do
      json = Jason.encode!(%{"kind" => "exploded", "source" => "mystery", "message" => "m"})
      assert Codec.decode_error(json) == %{kind: "exploded", source: "mystery", message: "m"}
    end

    test "unknown keys keep their string keys, values pass through" do
      map = %{"extra" => "x", "num" => 42, kind: :error, source: :result_handler, message: "m"}
      decoded = Codec.decode_error(Codec.encode_error(map))
      assert decoded.kind == :error
      assert decoded.source == :result_handler
      assert decoded.message == "m"
      assert decoded["extra"] == "x"
      assert decoded["num"] == 42
      refute Map.has_key?(decoded, :extra)
      refute Map.has_key?(decoded, :num)
    end

    test "garbage and non-object JSON decode to nil (never raises)" do
      assert Codec.decode_error("not json {") == nil
      assert Codec.decode_error("[1,2,3]") == nil
      assert Codec.decode_error("42") == nil
      assert Codec.decode_error("null") == nil
      assert Codec.decode_error("\"just a string\"") == nil
    end

    test "encode_task/decode_task round-trip includes error" do
      with_error = %TaskInfo{
        id: "codec-err",
        type: :genesis,
        status: :failed,
        opts: [path: "/tmp/test"],
        logs: [],
        result: nil,
        error: canonical_error()
      }

      row = Codec.encode_task(with_error)
      assert length(row) == 18
      assert Codec.decode_task(row).error == canonical_error()

      without_error = %TaskInfo{
        id: "codec-no-err",
        type: :genesis,
        status: :completed,
        opts: [path: "/tmp/test"],
        logs: [],
        result: nil
      }

      row2 = Codec.encode_task(without_error)
      assert length(row2) == 18
      decoded2 = Codec.decode_task(row2)
      assert decoded2.error == nil
      assert decoded2.id == "codec-no-err"
    end
  end

  describe "project put/get round-trip" do
    test "RecentProject round-trips correctly" do
      project = %RecentProject{
        path: "/tmp/myproj",
        name: "My Project",
        last_opened_at: ~U[2026-06-26 07:19:44Z]
      }

      :ok = Store.put_project(Store, project)
      fetched = Store.get_project(Store, "/tmp/myproj")

      assert %RecentProject{} = fetched
      assert fetched.path == "/tmp/myproj"
      assert fetched.name == "My Project"
      assert %DateTime{} = fetched.last_opened_at
      assert DateTime.compare(fetched.last_opened_at, ~U[2026-06-26 07:19:44Z]) == :eq
    end
  end

  describe "validation" do
    test "put_task rejects non-struct input" do
      result = Store.put_task(Store, "not a struct")
      assert match?({:error, _}, result)
    end

    test "put_task rejects nil id" do
      result = Store.put_task(Store, %TaskInfo{id: nil, status: :pending})
      assert result == {:error, :missing_task_id}
    end

    test "put_task rejects nil status" do
      result = Store.put_task(Store, %TaskInfo{id: "x", status: nil})
      # status nil encoded via Atom.to_string would crash; validation catches it
      assert match?({:error, _}, result)
    end

    test "put_project rejects nil path" do
      result = Store.put_project(Store, %RecentProject{path: nil, name: "x"})
      assert result == {:error, :missing_project_path}
    end
  end

  describe "delete operations" do
    test "delete_task removes a single task" do
      task = %TaskInfo{id: "del-1", type: :genesis, status: :completed, opts: [path: "/t"]}
      :ok = Store.put_task(Store, task)
      assert Store.get_task(Store, "del-1") != nil

      :ok = Store.delete_task(Store, "del-1")
      assert Store.get_task(Store, "del-1") == nil
    end

    test "delete_tasks removes multiple tasks in batch" do
      for i <- 1..3 do
        :ok =
          Store.put_task(Store, %TaskInfo{
            id: "batch-#{i}",
            type: :genesis,
            status: :completed,
            opts: [path: "/t"]
          })
      end

      :ok = Store.delete_tasks(Store, ["batch-1", "batch-2"])
      assert Store.get_task(Store, "batch-1") == nil
      assert Store.get_task(Store, "batch-2") == nil
      assert Store.get_task(Store, "batch-3") != nil
    end

    # The per-agent archive used to be a COLUMN of `tasks`, so deleting the task
    # row dropped it implicitly. Now that the archive rows live in their own
    # table, the task deletes MUST cascade (`Archives.delete_by_task/2`,
    # `delete_by_tasks/2`, `delete_all/1` — the primitives the store CONTEXT
    # documents as "the cascade the task deletes use"); otherwise every deleted
    # task leaks its whole archived-conversation payload.
    test "delete_task cascades to that task's archive rows only" do
      for id <- ["casc-one", "casc-two"] do
        :ok = Store.put_task(Store, %TaskInfo{id: id, type: :evolve, status: :completed})
        :ok = Store.put_task_archive(Store, archive_entry(id, 1, 0))
      end

      assert %{total: 1} = Store.list_task_archives(Store, "casc-one")

      :ok = Store.delete_task(Store, "casc-one")

      # The deleted task's archive rows are gone …
      assert Store.list_task_archives(Store, "casc-one") == %{entries: [], total: 0}
      assert Store.get_agent_archive(Store, "casc-one", 1) == nil

      # … and another task's archive is untouched.
      assert %{total: 1} = Store.list_task_archives(Store, "casc-two")
      assert %{"agent_id" => 1} = Store.get_agent_archive(Store, "casc-two", 1)
    end

    test "delete_tasks cascades to every named task's archive rows" do
      for i <- 1..3 do
        :ok =
          Store.put_task(Store, %TaskInfo{id: "bcasc-#{i}", type: :evolve, status: :completed})

        :ok = Store.put_task_archive(Store, archive_entry("bcasc-#{i}", 1, 0))
        :ok = Store.put_task_archive(Store, archive_entry("bcasc-#{i}", 2, 1))
      end

      :ok = Store.delete_tasks(Store, ["bcasc-1", "bcasc-2"])

      assert Store.list_task_archives(Store, "bcasc-1") == %{entries: [], total: 0}
      assert Store.list_task_archives(Store, "bcasc-2") == %{entries: [], total: 0}
      assert %{total: 2} = Store.list_task_archives(Store, "bcasc-3")
    end
  end

  # The per-agent archive is a RELATIONAL table (`task_agent_archives`, one row
  # per agent) read through the Store facade — the replacement for the old
  # single `tasks.archive_metadata` JSON array. Coverage here pins the facade
  # surface (`put_task_archive/2`, `list_task_archives/3`,
  # `get_agent_archive/3`, `delete_task_archives/2`) and its cascade; the
  # Operations-level contracts live in `store/operations/archives_test.exs`.
  describe "per-agent archive (task_agent_archives)" do
    test "put_task_archive/2 + get_agent_archive/3 round-trip every column, string-keyed" do
      :ok = Store.put_task_archive(Store, archive_entry("arch-rt", 7, 2))

      assert entry = Store.get_agent_archive(Store, "arch-rt", 7)

      # Entries are STRING-KEYED maps (what the dashboard/RPC layers carry).
      assert entry["task_id"] == "arch-rt"
      assert entry["agent_id"] == 7
      assert entry["parent_id"] == 6
      assert entry["depth"] == 2
      assert entry["agent_type"] == "executor"
      assert entry["context_node_path"] == "./"
      assert entry["objective"] == "archive objective 7"
      assert entry["result"] == "archived result 7"
      assert entry["base_commit"] == "base-7"
      assert entry["final_commit"] == "final-7"
      assert entry["branch_name"] == "evogit-agent-T1-A7"
      assert entry["archive_ref_start"] == "ref-start-7"
      assert entry["archive_ref_final"] == "ref-final-7"
      assert entry["repo_id"] == 0
      assert entry["repo_root"] == "/tmp/archive-repo"
      assert entry["repo_path"] == "apps/demo"
      assert entry["compression_count"] == 1

      # The JSON columns are PLAIN decoded data (no Codec, no compression
      # envelope) and timestamps keep their stored ISO-8601 spelling.
      assert entry["usage"] == %{"input_tokens" => 70, "total_cost" => 0.5}
      assert entry["llm_settings"] == %{"model_id" => "test-model"}
      assert entry["agent_settings"] == %{"turns" => 3}
      assert entry["foreign_repos"] == []
      assert entry["started_at"] == "2026-01-01T00:00:00.000Z"
      assert entry["completed_at"] == "2026-01-01T00:10:00.000Z"
    end

    test "get_agent_archive/3 returns nil for an unknown agent or task" do
      :ok = Store.put_task_archive(Store, archive_entry("arch-miss", 1, 0))

      assert %{"agent_id" => 1} = Store.get_agent_archive(Store, "arch-miss", 1)
      assert Store.get_agent_archive(Store, "arch-miss", 2) == nil
      assert Store.get_agent_archive(Store, "no-such-task", 1) == nil
    end

    test "list_task_archives/3 orders by depth then agent_id and total ignores the page" do
      # Deliberately scrambled insertion order: the roster is the SPAWN TREE
      # (root first), ordered depth ASC, agent_id ASC.
      for {agent_id, depth} <- [{5, 2}, {3, 1}, {1, 0}, {2, 1}] do
        :ok = Store.put_task_archive(Store, archive_entry("arch-order", agent_id, depth))
      end

      # Another task's rows never leak into this task's roster.
      :ok = Store.put_task_archive(Store, archive_entry("arch-other", 9, 0))

      %{entries: entries, total: 4} = Store.list_task_archives(Store, "arch-order")
      assert Enum.map(entries, & &1["agent_id"]) == [1, 2, 3, 5]
      assert Enum.map(entries, & &1["depth"]) == [0, 1, 1, 2]

      # `total` counts EVERY row of the task, independent of limit/offset.
      %{entries: page, total: 4} =
        Store.list_task_archives(Store, "arch-order", limit: 2, offset: 1)

      assert Enum.map(page, & &1["agent_id"]) == [2, 3]

      assert Store.list_task_archives(Store, "arch-other") |> Map.get(:total) == 1
      assert Store.list_task_archives(Store, "no-such-task") == %{entries: [], total: 0}
    end

    test "list_task_archives/3 omits the heavy result unless include_results: true" do
      :ok = Store.put_task_archive(Store, archive_entry("arch-inc", 1, 0))

      # Default: the `result` column is never SELECTED — the key is ABSENT
      # (not nil, not ""), so a roster page never pays for the conversation.
      %{entries: [roster]} = Store.list_task_archives(Store, "arch-inc")
      refute Map.has_key?(roster, "result")
      assert roster["objective"] == "archive objective 1"

      %{entries: [with_result]} =
        Store.list_task_archives(Store, "arch-inc", include_results: true)

      assert with_result["result"] == "archived result 1"
    end

    test "re-putting the same (task_id, agent_id) replaces the row, never duplicates" do
      :ok = Store.put_task_archive(Store, archive_entry("arch-reput", 1, 0))

      :ok =
        Store.put_task_archive(Store, %{
          archive_entry("arch-reput", 1, 0)
          | result: "replaced result",
            objective: "replaced objective"
        })

      %{entries: entries, total: 1} =
        Store.list_task_archives(Store, "arch-reput", include_results: true)

      assert [entry] = entries
      assert entry["result"] == "replaced result"
      assert entry["objective"] == "replaced objective"
    end

    test "put_task_archive/2 rejects entries that cannot identify a row" do
      assert Store.put_task_archive(Store, %{agent_id: 1}) == {:error, :missing_task_id}
      assert Store.put_task_archive(Store, %{task_id: "arch-bad"}) == {:error, :missing_agent_id}
      assert Store.put_task_archive(Store, :not_a_map) == {:error, :invalid_entry}

      # Nothing was written for any of them.
      assert Store.list_task_archives(Store, "arch-bad") == %{entries: [], total: 0}
    end

    test "delete_task_archives/2 deletes one task's rows and is a no-op otherwise" do
      for task_id <- ["arch-del", "arch-keep"] do
        :ok = Store.put_task_archive(Store, archive_entry(task_id, 1, 0))
        :ok = Store.put_task_archive(Store, archive_entry(task_id, 2, 1))
      end

      assert :ok = Store.delete_task_archives(Store, "arch-del")

      assert Store.list_task_archives(Store, "arch-del") == %{entries: [], total: 0}
      assert Store.get_agent_archive(Store, "arch-del", 1) == nil

      # The other task's rows survive, and a second delete of the same task (or
      # of a task with no archive at all) is a successful no-op.
      assert %{total: 2} = Store.list_task_archives(Store, "arch-keep")
      assert :ok = Store.delete_task_archives(Store, "arch-del")
      assert :ok = Store.delete_task_archives(Store, "never-archived")
    end
  end

  describe "select and count" do
    test "select_all_tasks returns all tasks" do
      for i <- 1..3 do
        :ok =
          Store.put_task(Store, %TaskInfo{
            id: "sel-#{i}",
            type: :genesis,
            status: :completed,
            opts: [path: "/t"]
          })
      end

      tasks = Store.select_all_tasks(Store)
      ids = Enum.map(tasks, & &1.id)
      assert "sel-1" in ids
      assert "sel-2" in ids
      assert "sel-3" in ids
    end

    test "select_all_projects returns all projects" do
      :ok =
        Store.put_project(Store, %RecentProject{path: "/p1", name: "P1"})

      :ok =
        Store.put_project(Store, %RecentProject{path: "/p2", name: "P2"})

      projects = Store.select_all_projects(Store)
      paths = Enum.map(projects, & &1.path)
      assert "/p1" in paths
      assert "/p2" in paths
    end

    test "count_tasks returns correct count" do
      :ok =
        Store.put_task(Store, %TaskInfo{
          id: "cnt-1",
          type: :genesis,
          status: :completed,
          opts: [path: "/t"]
        })

      assert Store.count_tasks(Store) >= 1
    end

    test "count_projects returns correct count" do
      :ok =
        Store.put_project(Store, %RecentProject{path: "/cnt-p1", name: "P1"})

      assert Store.count_projects(Store) >= 1
    end

    test "size returns total across both tables" do
      tasks_before = Store.count_tasks(Store)
      projects_before = Store.count_projects(Store)

      :ok =
        Store.put_task(Store, %TaskInfo{
          id: "size-1",
          type: :genesis,
          status: :completed,
          opts: [path: "/t"]
        })

      :ok =
        Store.put_project(Store, %RecentProject{path: "/size-p1", name: "P1"})

      size = Store.size(Store)
      assert size == tasks_before + projects_before + 2
    end

    test "clear_tasks removes all tasks" do
      :ok =
        Store.put_task(Store, %TaskInfo{
          id: "clr-1",
          type: :genesis,
          status: :completed,
          opts: [path: "/t"]
        })

      :ok = Store.clear_tasks(Store)
      assert Store.count_tasks(Store) == 0
    end

    test "clear_tasks cascades to every archive row" do
      for i <- 1..2 do
        :ok =
          Store.put_task(Store, %TaskInfo{id: "clr-arch-#{i}", type: :evolve, status: :completed})

        :ok = Store.put_task_archive(Store, archive_entry("clr-arch-#{i}", 1, 0))
      end

      assert %{total: 1} = Store.list_task_archives(Store, "clr-arch-1")

      :ok = Store.clear_tasks(Store)

      assert Store.count_tasks(Store) == 0
      assert Store.list_task_archives(Store, "clr-arch-1") == %{entries: [], total: 0}
      assert Store.list_task_archives(Store, "clr-arch-2") == %{entries: [], total: 0}
      assert Store.get_agent_archive(Store, "clr-arch-1", 1) == nil
    end
  end

  describe "select_finished_task_ids / select_running_lease_info — :cancelling semantics" do
    test "select_finished_task_ids excludes :cancelling but includes :finalizing" do
      unique = System.unique_integer([:positive])

      for {id, status} <- [
            {"fin-#{unique}", :running},
            {"fin-#{unique}-pending", :pending},
            {"fin-#{unique}-cancelling", :cancelling},
            {"fin-#{unique}-finalizing", :finalizing},
            {"fin-#{unique}-completed", :completed}
          ] do
        :ok =
          Store.put_task(Store, %TaskInfo{
            id: id,
            type: :genesis,
            status: status,
            opts: [path: "/t"]
          })
      end

      ids = Store.select_finished_task_ids(Store)

      # :running / :pending / :cancelling are NOT finished.
      refute "fin-#{unique}" in ids
      refute "fin-#{unique}-pending" in ids
      refute "fin-#{unique}-cancelling" in ids

      # :finalizing and :completed ARE finished.
      assert "fin-#{unique}-finalizing" in ids
      assert "fin-#{unique}-completed" in ids
    end

    test "select_running_lease_info returns :running, :finalizing, and :cancelling rows" do
      unique = System.unique_integer([:positive])

      for {id, status} <- [
            {"rl-#{unique}-running", :running},
            {"rl-#{unique}-finalizing", :finalizing},
            {"rl-#{unique}-cancelling", :cancelling},
            {"rl-#{unique}-completed", :completed}
          ] do
        :ok =
          Store.put_task(Store, %TaskInfo{
            id: id,
            type: :genesis,
            status: status,
            opts: [path: "/t"],
            lease_expires_at: 1_000_000
          })
      end

      rows = Store.select_running_lease_info(Store)
      ids = Enum.map(rows, & &1.id)
      statuses = Map.new(rows, &{&1.id, &1.status})

      assert "rl-#{unique}-running" in ids
      assert "rl-#{unique}-finalizing" in ids
      assert "rl-#{unique}-cancelling" in ids
      refute "rl-#{unique}-completed" in ids

      assert statuses["rl-#{unique}-cancelling"] == :cancelling
    end
  end

  describe "safe_select_paginated_tasks" do
    # Helper: inserts a task with a distinct started_at so ordering is
    # deterministic. Index 0 is the oldest.
    defp insert_timed!(i) do
      started = ~U[2026-01-01 00:00:00Z] |> DateTime.add(i, :second)

      :ok =
        Store.put_task(Store, %TaskInfo{
          id: "page-#{i}",
          type: :genesis,
          status: :completed,
          opts: [path: "/t"],
          started_at: started,
          finished_at: nil,
          logs: [],
          result: nil
        })
    end

    test "returns {tasks, total_count} tuple" do
      insert_timed!(0)
      insert_timed!(1)

      result = Store.safe_select_paginated_tasks(Store, limit: 10, offset: 0)

      assert {tasks, total} = result
      assert is_list(tasks)
      assert length(tasks) == 2
      assert total == 2
    end

    test "respects LIMIT and OFFSET" do
      for i <- 0..4, do: insert_timed!(i)

      {page1, total1} = Store.safe_select_paginated_tasks(Store, limit: 2, offset: 0)
      assert length(page1) == 2
      assert total1 == 5

      {page3, total3} = Store.safe_select_paginated_tasks(Store, limit: 2, offset: 4)
      assert length(page3) == 1
      assert total3 == 5
    end

    test "orders most-recent-first (started_at DESC)" do
      for i <- 0..4, do: insert_timed!(i)

      {tasks, _total} = Store.safe_select_paginated_tasks(Store, limit: 10, offset: 0)
      ids = Enum.map(tasks, & &1.id)

      # page-4 has the latest started_at, so it should be first.
      assert hd(ids) == "page-4"
      # Followed by 3, 2, 1, 0.
      assert List.last(ids) == "page-0"
    end

    test "nil/invalid opts don't crash (default limit/offset)" do
      insert_timed!(0)

      {tasks, total} = Store.safe_select_paginated_tasks(Store, [])
      assert is_list(tasks)
      assert total >= 1

      {tasks2, total2} = Store.safe_select_paginated_tasks(Store, limit: nil, offset: nil)
      assert is_list(tasks2)
      assert total2 == total
    end

    test "offset beyond total returns empty list but total_count still correct" do
      for i <- 0..2, do: insert_timed!(i)

      {tasks, total} = Store.safe_select_paginated_tasks(Store, limit: 10, offset: 9999)
      assert tasks == []
      assert total == 3
    end
  end

  describe "safe_select_paginated_tasks with filters" do
    # Helper: inserts a task with configurable fields and a distinct started_at
    # (index 0 = oldest). Returns the task id.
    defp insert_filtered!(i, opts) do
      id = Keyword.get(opts, :id, "f-#{i}")
      started = ~U[2026-01-01 00:00:00Z] |> DateTime.add(i, :second)

      task =
        %TaskInfo{
          id: id,
          type: :genesis,
          status: :completed,
          opts: [path: "/tmp/proj"],
          ref: nil,
          started_at: started,
          finished_at: DateTime.add(started, 1, :second),
          logs: [],
          result: nil
        }
        |> Map.merge(Enum.into(opts, %{}))

      :ok = Store.put_task(Store, task)
      id
    end

    test "status filter returns correct count" do
      for _ <- 1..3, do: insert_filtered!(System.unique_integer([:positive]), status: :completed)
      for _ <- 1..2, do: insert_filtered!(System.unique_integer([:positive]), status: :failed)

      {tasks, total} =
        Store.safe_select_paginated_tasks(Store,
          limit: 50,
          offset: 0,
          filters: [status: "failed"]
        )

      assert length(tasks) == 2
      assert total == 2
      assert Enum.all?(tasks, &(&1.status == :failed))
    end

    test "status 'all' returns all tasks" do
      for _ <- 1..3, do: insert_filtered!(System.unique_integer([:positive]), status: :completed)
      for _ <- 1..2, do: insert_filtered!(System.unique_integer([:positive]), status: :failed)

      {tasks, total} =
        Store.safe_select_paginated_tasks(Store, limit: 50, offset: 0, filters: [status: "all"])

      assert length(tasks) == 5
      assert total == 5
    end

    test "status filter + pagination slicing" do
      for i <- 0..19, do: insert_filtered!(i, id: "comp-#{i}", status: :completed)
      for i <- 0..9, do: insert_filtered!(i, id: "fail-#{i}", status: :failed)

      {page1, total1} =
        Store.safe_select_paginated_tasks(Store,
          limit: 5,
          offset: 0,
          filters: [status: "failed"]
        )

      assert length(page1) == 5
      assert total1 == 10

      {page2, total2} =
        Store.safe_select_paginated_tasks(Store,
          limit: 5,
          offset: 5,
          filters: [status: "failed"]
        )

      assert length(page2) == 5
      assert total2 == 10

      {page3, total3} =
        Store.safe_select_paginated_tasks(Store,
          limit: 5,
          offset: 10,
          filters: [status: "failed"]
        )

      assert page3 == []
      assert total3 == 10
    end

    test "project path filter returns only matching tasks" do
      for i <- 0..2,
          do:
            insert_filtered!(i, id: "a-#{i}", opts: [path: "/tmp/proj_a", prompt: "proj a #{i}"])

      for i <- 0..1,
          do:
            insert_filtered!(i, id: "b-#{i}", opts: [path: "/tmp/proj_b", prompt: "proj b #{i}"])

      {tasks, total} =
        Store.safe_select_paginated_tasks(Store,
          limit: 50,
          offset: 0,
          filters: [project_path: "/tmp/proj_a"]
        )

      assert length(tasks) == 3
      assert total == 3

      ids = Enum.map(tasks, & &1.id)
      assert Enum.all?(ids, &String.starts_with?(&1, "a-"))
    end

    test "project path filter treats underscores literally (LIKE wildcard escaping)" do
      # Two paths that differ only by the underscore position: `/tmp/proj_a`
      # vs `/tmp/projXa`. Without LIKE escaping, the `_` in the filter would
      # act as a single-char wildcard and match BOTH rows.
      insert_filtered!(0, id: "underscore-a", opts: [path: "/tmp/proj_a"])
      insert_filtered!(1, id: "underscore-x", opts: [path: "/tmp/projXa"])

      {tasks, total} =
        Store.safe_select_paginated_tasks(Store,
          limit: 50,
          offset: 0,
          filters: [project_path: "/tmp/proj_a"]
        )

      assert length(tasks) == 1
      assert total == 1
      assert hd(tasks).id == "underscore-a"
    end

    test "search by id returns only matching tasks" do
      insert_filtered!(0, id: "search-aaa-001")
      insert_filtered!(1, id: "search-bbb-002")
      insert_filtered!(2, id: "search-aaa-003")

      {tasks, total} =
        Store.safe_select_paginated_tasks(Store,
          limit: 50,
          offset: 0,
          filters: [search: "aaa"]
        )

      assert length(tasks) == 2
      assert total == 2

      ids = Enum.map(tasks, & &1.id)
      assert "search-aaa-001" in ids
      assert "search-aaa-003" in ids
      refute "search-bbb-002" in ids
    end

    test "search by prompt text in opts returns matching tasks" do
      insert_filtered!(0, opts: [prompt: "build a web application"])
      insert_filtered!(1, opts: [prompt: "write a database migration"])
      insert_filtered!(2, opts: [prompt: "refactor the auth module"])

      {tasks, total} =
        Store.safe_select_paginated_tasks(Store,
          limit: 50,
          offset: 0,
          filters: [search: "database"]
        )

      assert length(tasks) == 1
      assert total == 1
      assert hd(tasks).opts[:prompt] == "write a database migration"
    end

    test "search by branch_name returns only matching tasks (result text is NOT searched)" do
      # Matches: the result carries branch_name "genesis/agent_1", which the
      # store denormalizes into the `branch_name` column — one of the searched
      # columns now. (A lowercase query still proves case-insensitive matching.)
      insert_filtered!(0,
        id: "result-oauth",
        result:
          {:ok,
           %{
             result: "Implemented the OAuth login flow and added tests.",
             commit_sha: "abc",
             branch_name: "genesis/agent_1"
           }}
      )

      # Does NOT match: a different response message and no branch.
      insert_filtered!(1,
        id: "result-other",
        result: {:ok, %{result: "Refactored the database migration layer.", commit_sha: "def"}}
      )

      # Does NOT match: no result at all.
      insert_filtered!(2, id: "result-nil", result: nil)

      {tasks, total} =
        Store.safe_select_paginated_tasks(Store,
          limit: 50,
          offset: 0,
          filters: [search: "agent_1"]
        )

      assert length(tasks) == 1
      assert total == 1
      assert hd(tasks).id == "result-oauth"

      # `result` is deliberately no longer searched: `result` is zlib-compressed
      # above 4 kB, so a LIKE over it was both a full-blob scan and unable to see
      # the user-visible text. A phrase that exists ONLY in the result text no
      # longer matches (the behaviour change documented on the shared WHERE
      # builder, `EvoGit.Store.Operations.Filters`).
      {by_result_text, by_result_total} =
        Store.safe_select_paginated_tasks(Store,
          limit: 50,
          offset: 0,
          filters: [search: "oauth login"]
        )

      assert by_result_text == []
      assert by_result_total == 0
    end

    test "empty search returns all (no filtering)" do
      insert_filtered!(0, opts: [prompt: "alpha task"])
      insert_filtered!(1, opts: [prompt: "beta task"])

      {tasks, total} =
        Store.safe_select_paginated_tasks(Store,
          limit: 50,
          offset: 0,
          filters: [search: ""]
        )

      assert length(tasks) == 2
      assert total == 2
    end

    test "review status exact match returns only matching tasks" do
      insert_filtered!(0, id: "rs-merged", status: :completed, review_status: :merged)
      insert_filtered!(1, id: "rs-rejected", status: :completed, review_status: :rejected)

      {tasks, total} =
        Store.safe_select_paginated_tasks(Store,
          limit: 50,
          offset: 0,
          filters: [review_status: "merged"]
        )

      assert length(tasks) == 1
      assert total == 1
      assert hd(tasks).id == "rs-merged"
    end

    test "review 'pending' composite: completed + null review + branch_name in result" do
      # Matches "pending": completed, review_status nil, result has branch_name.
      insert_filtered!(0,
        id: "pending-yes",
        status: :completed,
        review_status: nil,
        result: {:ok, %{branch_name: "feat-123", commit_sha: "abc", result: "done"}}
      )

      # Does NOT match "pending": completed, nil review, but nil result (no branch).
      insert_filtered!(1,
        id: "pending-no-result",
        status: :completed,
        review_status: nil,
        result: nil
      )

      # Does NOT match "pending": completed but already reviewed (merged).
      insert_filtered!(2,
        id: "pending-merged",
        status: :completed,
        review_status: :merged,
        result: {:ok, %{branch_name: "feat-456"}}
      )

      {tasks, total} =
        Store.safe_select_paginated_tasks(Store,
          limit: 50,
          offset: 0,
          filters: [review_status: "pending"]
        )

      assert length(tasks) == 1
      assert total == 1
      assert hd(tasks).id == "pending-yes"
    end

    test "combined filters (status AND project_path)" do
      insert_filtered!(0,
        id: "combo-1",
        status: :completed,
        opts: [path: "/tmp/alpha", prompt: "combo one"]
      )

      insert_filtered!(1,
        id: "combo-2",
        status: :failed,
        opts: [path: "/tmp/alpha", prompt: "combo two"]
      )

      insert_filtered!(2,
        id: "combo-3",
        status: :completed,
        opts: [path: "/tmp/beta", prompt: "combo three"]
      )

      {tasks, total} =
        Store.safe_select_paginated_tasks(Store,
          limit: 50,
          offset: 0,
          filters: [status: "completed", project_path: "/tmp/alpha"]
        )

      assert length(tasks) == 1
      assert total == 1
      assert hd(tasks).id == "combo-1"
    end

    test "backward compatibility — no filters key behaves as before (no WHERE clause)" do
      for i <- 0..2, do: insert_filtered!(i, status: :completed)
      for i <- 0..1, do: insert_filtered!(i + 10, id: "nf-#{i}", status: :failed)

      {tasks, total} =
        Store.safe_select_paginated_tasks(Store, limit: 50, offset: 0)

      assert length(tasks) == 5
      assert total == 5
    end
  end

  describe "skip-and-log on undecodable rows" do
    test "safe_select_all_tasks skips undecodable rows, logs a warning, and leaves the row in place",
         %{sqlite_path: sqlite_path} do
      # Two decodable tasks inserted through the store
      for i <- 1..2 do
        :ok =
          Store.put_task(Store, %TaskInfo{
            id: "good-task-#{i}",
            type: :genesis,
            status: :completed,
            opts: [path: "/tmp/test"]
          })
      end

      # Inject an undecodable row via raw SQL: valid JSON but the WRONG shape —
      # decode_opts/1 is a strict canonical codec (only JSON objects with
      # string keys are canonical), so a JSON array of non-pair elements
      # raises ArgumentError on decode.
      {:ok, conn} = Xqlite.open(sqlite_path)

      XqliteNIF.execute(
        conn,
        "INSERT OR REPLACE INTO tasks (id, status, opts) VALUES (?1, ?2, ?3)",
        ["bad-task-1", "completed", "[1,2]"]
      )

      :ok = XqliteNIF.close(conn)

      log =
        ExUnit.CaptureLog.capture_log(fn ->
          tasks = Store.safe_select_all_tasks(Store)

          # (a) The bad row is SKIPPED — only the good rows are returned.
          ids = Enum.map(tasks, & &1.id)
          assert Enum.sort(ids) == ["good-task-1", "good-task-2"]
          refute "bad-task-1" in ids
        end)

      # (c) A warning is logged identifying the skipped row.
      assert log =~ "skipping undecodable row in tasks"
      assert log =~ "bad-task-1"

      # (b) The bad row REMAINS in the live tasks table — no DELETE, no
      # data-movement is performed on undecodable rows.
      {:ok, conn2} = Xqlite.open(sqlite_path)

      {:ok, %{rows: remaining}} =
        XqliteNIF.query(conn2, "SELECT id FROM tasks WHERE id = ?1", ["bad-task-1"])

      assert remaining == [["bad-task-1"]]
      :ok = XqliteNIF.close(conn2)
    end

    test "safe_select_all_projects skips an undecodable row, logs a warning, and leaves the row in place",
         %{sqlite_path: sqlite_path} do
      :ok =
        Store.put_project(Store, %RecentProject{
          path: "/good/proj",
          name: "Good Project",
          last_opened_at: ~U[2026-06-26 07:19:44Z]
        })

      # Inject an undecodable project row via raw SQL. All `projects` columns
      # are TEXT, and SQLite's TEXT affinity converts inserted integers to
      # strings — so a plain garbage INSERT can never fail to decode. To
      # exercise the skip-and-log boundary we recreate the table with an
      # INTEGER `last_opened_at` column (a schema an old DB version could
      # plausibly have had), then insert a genuine INTEGER there —
      # decode_datetime/1 raises FunctionClauseError on non-binary values.
      {:ok, conn} = Xqlite.open(sqlite_path)

      XqliteNIF.execute(conn, "DROP TABLE projects", [])

      XqliteNIF.execute(
        conn,
        "CREATE TABLE projects (path TEXT PRIMARY KEY, name TEXT, last_opened_at INTEGER)",
        []
      )

      XqliteNIF.execute(
        conn,
        "INSERT OR REPLACE INTO projects (path, name, last_opened_at) VALUES (?1, ?2, ?3)",
        ["/good/proj", "Good Project", "2026-06-26T07:19:44.000Z"]
      )

      XqliteNIF.execute(
        conn,
        "INSERT OR REPLACE INTO projects (path, name, last_opened_at) VALUES (?1, ?2, ?3)",
        ["/bad/proj", "Bad Project", 12345]
      )

      :ok = XqliteNIF.close(conn)

      log =
        ExUnit.CaptureLog.capture_log(fn ->
          projects = Store.safe_select_all_projects(Store)

          # The bad row is SKIPPED — only the decodable project is returned.
          paths = Enum.map(projects, & &1.path)
          assert paths == ["/good/proj"]
          refute "/bad/proj" in paths
        end)

      # A warning is logged identifying the skipped row.
      assert log =~ "skipping undecodable row in projects"
      assert log =~ "/bad/proj"

      # The bad row REMAINS untouched in the live projects table.
      {:ok, conn2} = Xqlite.open(sqlite_path)

      {:ok, %{rows: remaining}} =
        XqliteNIF.query(
          conn2,
          "SELECT path, name, last_opened_at FROM projects WHERE path = ?1",
          ["/bad/proj"]
        )

      assert remaining == [["/bad/proj", "Bad Project", 12345]]

      # The skip-and-log boundary must never create the legacy quarantine table
      # (which no longer exists in the schema).
      {:ok, %{rows: q_tables}} =
        XqliteNIF.query(
          conn2,
          "SELECT name FROM sqlite_master WHERE type = 'table' AND name = 'projects_quarantine'",
          []
        )

      assert q_tables == []
      :ok = XqliteNIF.close(conn2)
    end
  end

  describe "atom field round-trip safety (regression)" do
    # Regression for the critical crash: encode_atom/1 only accepted nil and
    # atoms, but decode_atom/1 could return a string. If a decoded value
    # survived into a re-encode, encode_atom("merged") → FunctionClauseError.

    test "review_status :merged survives put/get and re-put (the crash scenario)" do
      task = %TaskInfo{
        id: "rs-merged",
        type: :evolve,
        status: :completed,
        opts: [path: "/tmp/test"],
        started_at: DateTime.utc_now(),
        finished_at: DateTime.utc_now(),
        logs: [],
        result: nil,
        review_status: :merged
      }

      :ok = Store.put_task(Store, task)
      fetched = Store.get_task(Store, "rs-merged")

      # Consumer needs an atom for pattern matching.
      assert fetched.review_status == :merged

      # Re-put the fetched task — this is exactly the crash scenario.
      assert :ok = Store.put_task(Store, fetched)
      fetched2 = Store.get_task(Store, "rs-merged")
      assert fetched2.review_status == :merged
    end

    test "all known review_status values round-trip as atoms" do
      for status <- [:merged, :rejected, :continued, :ignored, :open, :no_changes] do
        task = %TaskInfo{
          id: "rs-#{status}",
          type: :evolve,
          status: :completed,
          opts: [path: "/tmp/test"],
          started_at: DateTime.utc_now(),
          finished_at: DateTime.utc_now(),
          logs: [],
          result: nil,
          review_status: status
        }

        :ok = Store.put_task(Store, task)
        fetched = Store.get_task(Store, "rs-#{status}")
        assert is_atom(fetched.review_status), "review_status #{status} decoded as non-atom"
        assert fetched.review_status == status
      end
    end

    test "review_status nil round-trips" do
      task = %TaskInfo{
        id: "rs-nil",
        type: :evolve,
        status: :completed,
        opts: [path: "/tmp/test"],
        started_at: DateTime.utc_now(),
        finished_at: DateTime.utc_now(),
        logs: [],
        result: nil,
        review_status: nil
      }

      :ok = Store.put_task(Store, task)
      fetched = Store.get_task(Store, "rs-nil")
      assert fetched.review_status == nil
    end

    test "type field round-trips as atom for all known values" do
      for type <- [:genesis, :evolve, :extract_skills, :reflect] do
        task = %TaskInfo{
          id: "type-#{type}",
          type: type,
          status: :completed,
          opts: [path: "/tmp/test"],
          started_at: DateTime.utc_now(),
          finished_at: DateTime.utc_now(),
          logs: [],
          result: nil
        }

        :ok = Store.put_task(Store, task)
        fetched = Store.get_task(Store, "type-#{type}")
        assert is_atom(fetched.type)
        assert fetched.type == type
      end
    end

    test "type :reflect codec round-trips directly" do
      # Direct codec pin for the :reflect (repo-less self-reflective) type atom,
      # which lives in the Codec @known_atoms whitelist.
      assert Codec.encode_atom(:reflect) == "reflect"
      assert Codec.decode_atom("reflect") == :reflect
    end

    test "status field round-trips as atom for all known values" do
      for status <- [
            :pending,
            :running,
            :finalizing,
            :completed,
            :failed,
            :cancelled,
            :cancelling
          ] do
        task = %TaskInfo{
          id: "status-#{status}",
          type: :genesis,
          status: status,
          opts: [path: "/tmp/test"],
          started_at: DateTime.utc_now(),
          finished_at: DateTime.utc_now(),
          logs: [],
          result: nil
        }

        :ok = Store.put_task(Store, task)
        fetched = Store.get_task(Store, "status-#{status}")
        assert is_atom(fetched.status)
        assert fetched.status == status
      end
    end

    test "unknown status atom decodes as nil (whitelist safety)" do
      # Directly exercise the codec: a non-whitelisted atom must decode nil
      # rather than creating a new atom (avoids atom-table leaks).
      assert Codec.decode_atom("not_a_real_status") == nil
      assert Codec.decode_atom("cancelling") == :cancelling
    end

    test "review_status field round-trips as atom for all known values" do
      for review_status <- [:open, :merged, :rejected, :continued, :ignored, :no_changes] do
        task = %TaskInfo{
          id: "rs-#{review_status}",
          type: :genesis,
          status: :completed,
          opts: [path: "/tmp/test"],
          started_at: DateTime.utc_now(),
          finished_at: DateTime.utc_now(),
          logs: [],
          result: nil,
          review_status: review_status
        }

        :ok = Store.put_task(Store, task)
        fetched = Store.get_task(Store, "rs-#{review_status}")
        assert is_atom(fetched.review_status)
        assert fetched.review_status == review_status
      end
    end

    test "lease_expires_at integer round-trips" do
      task = %TaskInfo{
        id: "rt-lease",
        type: :genesis,
        status: :running,
        opts: [path: "/tmp/test"],
        started_at: DateTime.utc_now(),
        finished_at: nil,
        logs: [],
        result: nil,
        lease_expires_at: 1_234_567_890
      }

      :ok = Store.put_task(Store, task)
      fetched = Store.get_task(Store, "rt-lease")

      assert %TaskInfo{} = fetched
      assert fetched.lease_expires_at == 1_234_567_890
    end

    test "lease_expires_at nil round-trips" do
      task = %TaskInfo{
        id: "rt-lease-nil",
        type: :genesis,
        status: :completed,
        opts: [path: "/tmp/test"],
        started_at: DateTime.utc_now(),
        finished_at: DateTime.utc_now(),
        logs: [],
        result: nil,
        lease_expires_at: nil
      }

      :ok = Store.put_task(Store, task)
      fetched = Store.get_task(Store, "rt-lease-nil")

      assert %TaskInfo{} = fetched
      assert fetched.lease_expires_at == nil
    end

    test "unknown atom value in DB decodes to nil (never crashes)", %{sqlite_path: sqlite_path} do
      # Simulate the bug: inject a raw string that is not a known atom.
      {:ok, conn} = Xqlite.open(sqlite_path)

      XqliteNIF.execute(
        conn,
        "INSERT OR REPLACE INTO tasks (id, type, status, opts, review_status) VALUES (?1, ?2, ?3, ?4, ?5)",
        ["bad-rs", "evolve", "completed", "{}", "some_unknown_value"]
      )

      :ok = XqliteNIF.close(conn)

      fetched = Store.get_task(Store, "bad-rs")
      assert %TaskInfo{} = fetched
      # Unknown value decodes to nil, not a crash.
      assert fetched.review_status == nil
    end

    test "string value in atom field survives a full round-trip without crashing", %{
      sqlite_path: sqlite_path
    } do
      # The ultimate regression: inject a string that IS a known atom name into
      # the DB, read it (decode_atom returns the atom), then re-put the read
      # task. This must not crash even if the in-memory value were somehow a
      # string.
      {:ok, conn} = Xqlite.open(sqlite_path)

      XqliteNIF.execute(
        conn,
        "INSERT OR REPLACE INTO tasks (id, type, status, opts, review_status) VALUES (?1, ?2, ?3, ?4, ?5)",
        ["str-rs", "evolve", "completed", "{}", "merged"]
      )

      :ok = XqliteNIF.close(conn)

      fetched = Store.get_task(Store, "str-rs")
      assert fetched.review_status == :merged

      # Re-put — must not crash (this was the original FunctionClauseError).
      assert :ok = Store.put_task(Store, fetched)
      fetched2 = Store.get_task(Store, "str-rs")
      assert fetched2.review_status == :merged
    end
  end

  describe "terminate" do
    test "closes the connection gracefully on stop" do
      unique = System.unique_integer([:positive])
      # The tmp path additionally carries the OS pid + wall-clock ms: the
      # per-BEAM unique counter alone restarts on a fresh node and would
      # collide with a previous run's leftover file.
      stamp = "#{unique}_#{:os.getpid()}_#{System.system_time(:millisecond)}"
      sqlite_path = Path.join(System.tmp_dir!(), "evogit_term_#{stamp}.sqlite")
      store = :"term_test_#{unique}"

      {:ok, _} = Store.start_link(data_dir: sqlite_path, name: store)

      # Stop should not raise — terminate/2 closes the connection
      :ok = GenServer.stop(store)

      # The DB file should be accessible (not locked)
      {:ok, conn} = Xqlite.open(sqlite_path)
      :ok = XqliteNIF.close(conn)
      # Remove the file AND its WAL sidecars (`File.rm/1` tolerates an absent
      # path) so nothing is left behind in the tmpdir.
      File.rm(sqlite_path)
      File.rm(sqlite_path <> "-wal")
      File.rm(sqlite_path <> "-shm")
    end
  end

  # A full Store.start_link boot must migrate a LEGACY-shaped database before
  # the first read/write — the Ecto port of the old raw-SQL Schema repair
  # pipeline (schema adoption coverage per-shape lives in
  # `store/boot_migration_test.exs` against `Boot.start_dynamic/1` directly;
  # THIS test pins the same contract through the public GenServer entry).
  describe "boot migration on Store.start_link (legacy DB)" do
    # The real v0.9.0–v0.12.5 19-column shape: `updated_at` is the 19th
    # column and `error` does not exist yet — the "reported
    # crash-on-upgrade" database (DDL copied from boot_migration_test.exs).
    @ddl_19_col """
    CREATE TABLE tasks (
      id TEXT PRIMARY KEY,
      type TEXT,
      status TEXT NOT NULL,
      opts TEXT,
      started_at TEXT,
      finished_at TEXT,
      logs TEXT,
      result TEXT,
      review_status TEXT,
      usage TEXT,
      agent_count INTEGER,
      base_sha TEXT,
      commit_sha TEXT,
      archive_metadata TEXT,
      lease_expires_at INTEGER,
      model_id TEXT,
      project_path TEXT,
      branch_name TEXT,
      updated_at TEXT
    )
    """

    @projects_ddl """
    CREATE TABLE projects (
      path TEXT PRIMARY KEY,
      name TEXT,
      last_opened_at TEXT
    )
    """

    # The exact migration INVENTORY is pinned in
    # `store/boot_migration_test.exs`; here the expectation is DERIVED from the
    # migrations directory, so this end-to-end boot test keeps asserting "every
    # migration ran, in ascending order" without duplicating (and drifting from)
    # that inventory.
    defp expected_versions do
      EvoGit.Store.Boot.migration_source() |> Enum.map(&elem(&1, 0))
    end

    test "boots cleanly against a legacy 19-column DB, migrates, adopts `error`, and reads the legacy row",
         %{root: root} do
      unique = System.unique_integer([:positive])
      sqlite_path = Path.join(root, "evogit_legacy_boot_#{unique}.sqlite")
      store = :"legacy_boot_store_#{unique}"
      task_id = "legacy-boot-#{unique}"

      # Seed the legacy DB with RAW xqlite — exactly the file a pre-Ecto
      # release left on disk (legacy DDL, NO schema_migrations table, one
      # canonical-shaped row the data normalization must leave untouched).
      File.mkdir_p!(root)

      {:ok, conn} = Xqlite.open(sqlite_path, journal_mode: :wal, synchronous: :normal)
      {:ok, _} = XqliteNIF.query(conn, @ddl_19_col, [])
      {:ok, _} = XqliteNIF.query(conn, @projects_ddl, [])

      {:ok, _} =
        XqliteNIF.query(
          conn,
          "INSERT INTO tasks (id, type, status, opts, started_at, finished_at, logs, result, " <>
            "usage, agent_count, base_sha, commit_sha, archive_metadata, lease_expires_at, " <>
            "model_id, project_path, branch_name, updated_at) VALUES " <>
            "(?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9, ?10, ?11, ?12, ?13, ?14, ?15, ?16, ?17, ?18)",
          [
            task_id,
            "genesis",
            "completed",
            ~S({"mode":"new","path":"/tmp/legacy-boot"}),
            "2024-02-02T08:00:00.111Z",
            "2024-02-02T09:00:00.222Z",
            ~S(["seed log line"]),
            ~S({"__result_tag__":"ok","data":{"summary":"legacy seed"}}),
            ~S({"llm":{"total_cost":0.5}}),
            3,
            "base19",
            "commit19",
            ~S({"records":[]}),
            1_738_500_000_000,
            "kimi",
            "/tmp/legacy-boot",
            "genesis/agent_19ab",
            "2024-02-02T09:00:01.333Z"
          ]
        )

      :ok = XqliteNIF.close(conn)

      # The legacy file had no migrations table before boot.
      {:ok, pre} = Xqlite.open(sqlite_path)
      {:ok, pre_result} = XqliteNIF.query(pre, "PRAGMA table_info(tasks)", [])
      pre_columns = Enum.map(pre_result.rows, fn [_cid, name | _] -> name end)
      refute "error" in pre_columns
      :ok = XqliteNIF.close(pre)

      # Public GenServer entry: Store.start_link itself boots the dynamic
      # repo, runs ALL migrations, and comes up serving reads/writes.
      {:ok, pid} = Store.start_link(data_dir: sqlite_path, name: store)

      # The store is LINKED to this test process; a normal test exit would
      # kill it before on_exit can stop it cleanly. Unlink (same pattern as
      # boot_migration_test.exs's start_booted_repo!/1) and stop through an
      # alive-guarded on_exit.
      Process.unlink(pid)

      on_exit(fn ->
        case Process.whereis(store) do
          nil -> :ok
          pid -> :ok = GenServer.stop(pid)
        end
      end)

      # Every migration of the current inventory is stamped in
      # schema_migrations, ascending, observed through the same test seam the
      # disk-full tests use (__repo_pid__ + RepoScope/Repo against the store's
      # OWN dynamic instance).
      repo_pid = Store.__repo_pid__(store)

      versions =
        RepoScope.with_repo(repo_pid, fn ->
          Repo.query!("SELECT version FROM schema_migrations ORDER BY version").rows
          |> Enum.map(&hd/1)
        end)

      expected = expected_versions()
      assert length(expected) >= 6
      assert versions == expected

      # The relational per-agent archive table exists after the boot, with
      # EXACTLY the columns the schema declares (the archive is no longer a
      # column of `tasks`).
      archive_columns =
        RepoScope.with_repo(repo_pid, fn ->
          Repo.query!("PRAGMA table_info(task_agent_archives)").rows
          |> Enum.map(fn [_cid, name | _] -> name end)
        end)

      assert archive_columns == EvoGit.Store.Schemas.TaskAgentArchiveRow.columns()

      # The legacy row is readable through the PUBLIC API — every seeded
      # value round-trips, and the adopted `error` column reads as nil.
      assert %TaskInfo{} = task = Store.get_task(store, task_id)
      assert {task.id, task.type, task.status} == {task_id, :genesis, :completed}
      assert task.opts == [mode: "new", path: "/tmp/legacy-boot"]
      assert task.started_at == ~U[2024-02-02 08:00:00.111Z]
      assert task.finished_at == ~U[2024-02-02 09:00:00.222Z]
      assert task.logs == ["seed log line"]
      assert task.result == {:ok, %{"summary" => "legacy seed"}}
      assert {task.agent_count, task.lease_expires_at} == {3, 1_738_500_000_000}
      assert {task.base_sha, task.commit_sha} == {"base19", "commit19"}
      assert task.model_id == "kimi"
      assert task.project_path == "/tmp/legacy-boot"
      assert task.branch_name == "genesis/agent_19ab"
      assert task.error == nil

      # `error` was ADOPTED at the tail — writes through the public API now
      # persist it (the column exists and is writable post-migration).
      :ok =
        Store.update_task_columns(store, task_id,
          status: :failed,
          error: %{kind: :error, source: :recheck, message: "boot test"}
        )

      assert %TaskInfo{status: :failed, error: %{kind: :error, message: "boot test"}} =
               Store.get_task(store, task_id)

      # Clean stop through the on_exit above; the DB file is removed with the
      # per-test root.
    end
  end
end
