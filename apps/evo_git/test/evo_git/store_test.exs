defmodule EvoGit.StoreTest do
  use ExUnit.Case, async: false

  alias EvoGit.Store
  alias EvoGit.Store.Codec
  alias EvoGit.TaskInfo
  alias EvoGit.RecentProject

  # The 16 summary keys returned by select_tasks_changed_since/2 (same
  # projection as select_tasks_summary, plus the raw `updated_at` string).
  @summary_keys [
    :id,
    :status,
    :review_status,
    :result,
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
    :updated_at
  ]

  # Terminate production children (TaskRegistry depends on Store) and start
  # an isolated Store with a unique tmp SQLite path. `async: false` because
  # we mutate the shared production supervision tree.
  setup do
    Supervisor.terminate_child(EvoGit.Supervisor, EvoGit.TaskRegistry)
    Supervisor.terminate_child(EvoGit.Supervisor, EvoGit.Store)

    unique = System.unique_integer([:positive])
    root = Path.join(System.tmp_dir!(), "evogit_test_store_#{unique}")
    File.mkdir_p!(root)
    sqlite_path = Path.join(root, "tasks.sqlite")

    start_supervised({Store, data_dir: sqlite_path})

    on_exit(fn ->
      File.rm_rf(root)
      Supervisor.restart_child(EvoGit.Supervisor, EvoGit.Store)
      Supervisor.restart_child(EvoGit.Supervisor, EvoGit.TaskRegistry)
    end)

    {:ok, %{store: Store, sqlite_path: sqlite_path, root: root}}
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
             agent_count: 3,
             archive_records: [%{"agent_id" => "T1_A1"}]
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
      assert is_list(data.archive_records)

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
             agent_count: 1,
             archive_records: nil
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

    test "archive_metadata round-trips as list of maps" do
      archive = [
        %{"agent_id" => "T1_A1", "role" => "manager", "objective" => "Genesis"}
      ]

      task = %TaskInfo{
        id: "rt-archive",
        type: :genesis,
        status: :completed,
        opts: [path: "/tmp/test"],
        started_at: DateTime.utc_now(),
        finished_at: DateTime.utc_now(),
        logs: [],
        result: nil,
        archive_metadata: archive
      }

      :ok = Store.put_task(Store, task)
      fetched = Store.get_task(Store, "rt-archive")

      assert is_list(fetched.archive_metadata)
      assert length(fetched.archive_metadata) == 1
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
        archive_metadata: nil
      }

      :ok = Store.put_task(Store, task)
      fetched = Store.get_task(Store, "rt-nil")

      assert fetched.finished_at == nil
      assert fetched.result == nil
      assert fetched.usage == nil
      assert fetched.archive_metadata == nil
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
      assert diff_seconds >= 0 and diff_seconds <= 10
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
      assert diff_seconds >= 0 and diff_seconds <= 10

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
    end
  end

  describe "Codec result/opts round-trips" do
    test "encode_result/decode_result round-trip tagged tuples and strings" do
      # {:ok, map} with atom keys (known result-data fields atomize back).
      assert Codec.decode_result(
               Codec.encode_result({:ok, %{commit_sha: "abc", branch_name: "b"}})
             ) == {:ok, %{commit_sha: "abc", branch_name: "b"}}

      # {:error, string} — reason is not an existing atom, stays a string.
      assert Codec.decode_result(Codec.encode_result({:error, "boom"})) == {:error, "boom"}

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
      for type <- [:genesis, :evolve, :extract_skills] do
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

    test "status field round-trips as atom for all known values" do
      for status <- [:pending, :running, :finalizing, :completed, :failed, :cancelled] do
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
        ["bad-rs", "evolve", "completed", "[]", "some_unknown_value"]
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
        ["str-rs", "evolve", "completed", "[]", "merged"]
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
      sqlite_path = Path.join(System.tmp_dir!(), "evogit_term_#{unique}.sqlite")
      store = :"term_test_#{unique}"

      {:ok, _} = Store.start_link(data_dir: sqlite_path, name: store)

      # Stop should not raise — terminate/2 closes the connection
      :ok = GenServer.stop(store)

      # The DB file should be accessible (not locked)
      {:ok, conn} = Xqlite.open(sqlite_path)
      :ok = XqliteNIF.close(conn)
      File.rm(sqlite_path)
    end
  end
end
