defmodule EvoDash.StoreTest do
  use ExUnit.Case, async: false

  alias EvoDash.Store
  alias EvoDash.TaskInfo
  alias EvoDash.RecentProject

  # Terminate production children (TaskRegistry depends on Store) and start
  # an isolated Store with a unique tmp SQLite path. `async: false` because
  # we mutate the shared production supervision tree.
  setup do
    Supervisor.terminate_child(EvoDash.Supervisor, EvoDash.TaskRegistry)
    Supervisor.terminate_child(EvoDash.Supervisor, EvoDash.Store)

    unique = System.unique_integer([:positive])
    root = Path.join(System.tmp_dir!(), "evogit_test_store_#{unique}")
    File.mkdir_p!(root)
    sqlite_path = Path.join(root, "tasks.sqlite")

    start_supervised({Store, data_dir: sqlite_path})

    on_exit(fn ->
      File.rm_rf(root)
      Supervisor.restart_child(EvoDash.Supervisor, EvoDash.Store)
      Supervisor.restart_child(EvoDash.Supervisor, EvoDash.TaskRegistry)
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
        commit_sha: "def456"
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

  describe "integrity check" do
    test "returns :ok on a healthy store" do
      assert Store.integrity_check(Store) == :ok
    end

    test "safe_select_all_tasks never raises on bad data", %{sqlite_path: sqlite_path} do
      # Inject a row with invalid JSON in opts via raw SQL
      {:ok, conn} = Xqlite.open(sqlite_path)

      XqliteNIF.execute(
        conn,
        "INSERT OR REPLACE INTO tasks (id, status, opts) VALUES (?1, ?2, ?3)",
        ["bad-1", "completed", "<<invalid json>>"]
      )

      :ok = XqliteNIF.close(conn)

      # safe_select_all_tasks should not raise — it rescues bad rows
      tasks = Store.safe_select_all_tasks(Store)
      assert is_list(tasks)
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
