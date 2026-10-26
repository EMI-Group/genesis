defmodule EvoGit.StoreTest do
  use ExUnit.Case, async: false

  alias EvoGit.Repo
  alias EvoGit.Store
  alias EvoGit.Store.Codec
  alias EvoGit.Store.RepoScope
  alias EvoGit.TaskInfo
  alias EvoGit.RecentProject

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
      repo_id: "primary",
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
    test "every field family round-trips through the facade" do
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
        id: "rt-all",
        type: :genesis,
        status: :completed,
        opts: [path: "/tmp/proj", mode: "complex", prompt: "hello world"],
        ref: nil,
        started_at: ~U[2026-06-26 07:19:44Z],
        finished_at: ~U[2026-06-26 08:00:00Z],
        logs: ["line 1", "line 2", "line 3"],
        result: nil,
        review_status: :ignored,
        usage: usage,
        agent_count: 5,
        base_sha: "abc123",
        commit_sha: "def456",
        model_id: "gpt-4o",
        lease_expires_at: 1_234_567_890
      }

      :ok = Store.put_task(Store, task)
      fetched = Store.get_task(Store, "rt-all")

      assert %TaskInfo{} = fetched
      assert {fetched.id, fetched.type, fetched.status} == {"rt-all", :genesis, :completed}
      assert fetched.review_status == :ignored

      assert {fetched.agent_count, fetched.base_sha, fetched.commit_sha} ==
               {5, "abc123", "def456"}

      assert fetched.model_id == "gpt-4o"
      assert fetched.ref == nil
      assert fetched.lease_expires_at == 1_234_567_890

      # opts come back as a keyword list with atom keys.
      assert is_list(fetched.opts)
      assert fetched.opts[:path] == "/tmp/proj"
      assert fetched.opts[:mode] == "complex"
      assert fetched.opts[:prompt] == "hello world"

      assert fetched.logs == ["line 1", "line 2", "line 3"]

      assert %DateTime{} = fetched.started_at
      assert %DateTime{} = fetched.finished_at
      assert DateTime.compare(fetched.started_at, fetched.finished_at) == :lt

      assert %EvoGit.Agent.Usage{} = fetched.usage
      assert fetched.usage.input_tokens == 100
      assert fetched.usage.output_tokens == 50
      assert fetched.usage.total_tokens == 150
      assert fetched.usage.total_cost == 0.03
      assert fetched.usage.cached_tokens == 10
      assert fetched.usage.cache_creation_tokens == 5
    end

    test "every result form round-trips through the facade" do
      cases = [
        {"rt-result",
         {:ok,
          %{
            commit_sha: "abc123def",
            branch_name: "evogit/test",
            result: "Agent summary",
            pr_url: nil,
            pr_title: nil
          }},
         fn result ->
           assert {:ok, %{commit_sha: "abc123def", branch_name: "evogit/test"}} = result
         end},
        {"rt-result-usage",
         {:ok,
          %{
            commit_sha: "deadbeef",
            result: "All done",
            tag: "v1.0",
            branch_name: "evogit/feature",
            pr_url: nil,
            pr_title: nil,
            usage: %EvoGit.Agent.Usage{
              input_tokens: 100,
              output_tokens: 50,
              total_tokens: 150,
              input_cost: 0.01,
              output_cost: 0.02,
              total_cost: 0.03,
              cached_tokens: 10,
              cache_creation_tokens: 5
            },
            agent_count: 3
          }},
         fn result ->
           assert {:ok, data} = result
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
         end},
        {"rt-result-nochanges",
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
          }},
         fn result ->
           assert {:ok, data} = result
           assert data.no_changes == true
           assert data.branch_name == nil
           assert data.result == "Nothing to do"
           assert %EvoGit.Agent.Usage{} = data.usage
         end},
        {"rt-result-error", {:error, "something went wrong"},
         fn result -> assert result == {:error, "something went wrong"} end},
        {"rt-result-exit", {:exit, :killed}, fn result -> assert result == {:exit, :killed} end},
        {"rt-result-string", "Process crashed while task was running",
         fn result -> assert result == "Process crashed while task was running" end},
        {"rt-result-complex-error", {:error, {:bad_match, [1, 2, 3]}},
         fn result ->
           # The complex tuple can't be JSON-encoded directly, so it falls back
           # to inspect — but the tuple shape {:error, _} is preserved.
           assert {:error, reason} = result
           assert is_binary(reason)
         end},
        {"rt-result-nil", nil, fn result -> assert result == nil end}
      ]

      for {id, result, check} <- cases do
        :ok =
          Store.put_task(Store, %TaskInfo{
            id: id,
            type: :evolve,
            status: :completed,
            opts: [path: "/tmp/test"],
            started_at: DateTime.utc_now(),
            finished_at: DateTime.utc_now(),
            logs: [],
            result: result
          })

        assert %TaskInfo{result: fetched_result} = Store.get_task(Store, id)
        check.(fetched_result)
      end
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

    test "update_task_columns bumps updated_at; update_lease_expires_at never does (heartbeat invariant)",
         %{sqlite_path: sqlite_path} do
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
      # Load-robust: assert "recent", not an exact instant.
      assert diff_seconds >= 0 and diff_seconds <= 60

      # The targeted update itself also took effect.
      assert Store.get_task_status(Store, "upd-col") == :running

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
    test "malformed input is rejected with the documented error tuples" do
      # A non-struct task never reaches the encoder.
      assert match?({:error, _}, Store.put_task(Store, "not a struct"))
      # status nil encoded via Atom.to_string would crash; validation catches it.
      assert match?({:error, _}, Store.put_task(Store, %TaskInfo{id: "x", status: nil}))

      assert Store.put_task(Store, %TaskInfo{id: nil, status: :pending}) ==
               {:error, :missing_task_id}

      assert Store.put_project(Store, %RecentProject{path: nil, name: "x"}) ==
               {:error, :missing_project_path}
    end
  end

  describe "delete operations" do
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

      # The task row itself and its archive rows are gone …
      assert Store.get_task(Store, "casc-one") == nil
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

      assert Store.get_task(Store, "bcasc-1") == nil
      assert Store.get_task(Store, "bcasc-3") != nil
      assert Store.list_task_archives(Store, "bcasc-1") == %{entries: [], total: 0}
      assert Store.list_task_archives(Store, "bcasc-2") == %{entries: [], total: 0}
      assert %{total: 2} = Store.list_task_archives(Store, "bcasc-3")
    end
  end

  describe "select and count" do
    test "facade read/count helpers (projects, size) and clear_tasks with its archive cascade" do
      :ok = Store.put_project(Store, %RecentProject{path: "/p1", name: "P1"})
      :ok = Store.put_project(Store, %RecentProject{path: "/p2", name: "P2"})

      for task_id <- ["clr-arch-1", "clr-arch-2"] do
        :ok =
          Store.put_task(Store, %TaskInfo{
            id: task_id,
            type: :evolve,
            status: :completed,
            opts: [path: "/t"]
          })

        :ok = Store.put_task_archive(Store, archive_entry(task_id, 1, 0))
      end

      assert Store.select_all_projects(Store) |> Enum.map(& &1.path) |> Enum.sort() ==
               ["/p1", "/p2"]

      assert Store.count_projects(Store) == 2
      # size/1 sums ROW COUNTS across both tables.
      assert Store.size(Store) == 4
      assert %{total: 1} = Store.list_task_archives(Store, "clr-arch-1")

      :ok = Store.clear_tasks(Store)

      assert Store.select_task_ids(Store) == []
      assert Store.list_task_archives(Store, "clr-arch-1") == %{entries: [], total: 0}
      assert Store.list_task_archives(Store, "clr-arch-2") == %{entries: [], total: 0}
      assert Store.get_agent_archive(Store, "clr-arch-1", 1) == nil
      # Projects are untouched by a task clear.
      assert Store.count_projects(Store) == 2
    end
  end

  describe "select_finished_task_ids / select_running_lease_info — :cancelling semantics" do
    test "both projections agree that :cancelling is NOT finished but IS lease-tracked" do
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
            opts: [path: "/t"],
            lease_expires_at: 1_000_000
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

      # The lease read the other way round: a gracefully-cancelling task still
      # owns a lease until it reaches :cancelled.
      rows = Store.select_running_lease_info(Store)
      lease_ids = Enum.map(rows, & &1.id)
      statuses = Map.new(rows, &{&1.id, &1.status})

      assert "fin-#{unique}" in lease_ids
      assert "fin-#{unique}-finalizing" in lease_ids
      assert "fin-#{unique}-cancelling" in lease_ids
      refute "fin-#{unique}-completed" in lease_ids

      assert statuses["fin-#{unique}-cancelling"] == :cancelling
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

    test "the facade paginates, orders newest-first, defaults invalid opts, and forwards filters" do
      for i <- 0..4, do: insert_timed!(i)

      # {tasks, total_count}, with total ignoring the page.
      {page1, total1} = Store.safe_select_paginated_tasks(Store, limit: 2, offset: 0)
      assert length(page1) == 2
      assert total1 == 5

      {page3, total3} = Store.safe_select_paginated_tasks(Store, limit: 2, offset: 4)
      assert length(page3) == 1
      assert total3 == 5

      # Most-recent-first: page-4 has the latest started_at.
      {tasks, _total} = Store.safe_select_paginated_tasks(Store, limit: 10, offset: 0)
      assert Enum.map(tasks, & &1.id) == ["page-4", "page-3", "page-2", "page-1", "page-0"]

      # Offset beyond the total: an empty page, total still correct.
      {beyond, beyond_total} = Store.safe_select_paginated_tasks(Store, limit: 10, offset: 9999)
      assert beyond == []
      assert beyond_total == 5

      # Nil/absent/invalid opts fall back to the documented defaults.
      {defaults, default_total} = Store.safe_select_paginated_tasks(Store, [])
      assert length(defaults) == 5
      assert default_total == 5

      {nil_opts, ^default_total} =
        Store.safe_select_paginated_tasks(Store, limit: nil, offset: nil)

      assert is_list(nil_opts)

      # Filters are forwarded to the shared WHERE builder — the full filter
      # matrix (LIKE escaping, the 'pending' review composite, every search
      # column) lives in `store/operations/tasks_test.exs`.
      insert_filtered!(0, id: "f-failed", status: :failed, opts: [path: "/tmp/proj_f"])
      insert_filtered!(1, id: "f-done", status: :completed, opts: [path: "/tmp/proj_f"])

      {filtered, filtered_total} =
        Store.safe_select_paginated_tasks(Store,
          limit: 50,
          offset: 0,
          filters: [status: "failed", project_path: "/tmp/proj_f"]
        )

      assert filtered_total == 1
      assert Enum.map(filtered, & &1.id) == ["f-failed"]
      assert hd(filtered).status == :failed
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

    test "every closed-set atom round-trips through the facade (type, status, review_status)" do
      columns = [
        {:type, :genesis, [:genesis, :evolve, :extract_skills, :reflect]},
        {:status, :genesis,
         [:pending, :running, :finalizing, :completed, :failed, :cancelled, :cancelling]},
        {:review_status, :completed,
         [:open, :merged, :rejected, :continued, :ignored, :no_changes]}
      ]

      for {field, type, values} <- columns, value <- values do
        id = "atom-#{field}-#{value}"

        task =
          %TaskInfo{
            id: id,
            type: type,
            status: :completed,
            opts: [path: "/tmp/test"],
            started_at: DateTime.utc_now(),
            finished_at: DateTime.utc_now(),
            logs: [],
            result: nil
          }
          |> Map.put(field, value)

        :ok = Store.put_task(Store, task)
        fetched = Store.get_task(Store, id)
        assert is_atom(Map.fetch!(fetched, field)), "#{field} #{value} decoded as non-atom"
        assert Map.fetch!(fetched, field) == value
      end
    end

    test "lease_expires_at round-trips both an integer and nil" do
      for {id, status, lease} <- [
            {"rt-lease", :running, 1_234_567_890},
            {"rt-lease-nil", :completed, nil}
          ] do
        :ok =
          Store.put_task(Store, %TaskInfo{
            id: id,
            type: :genesis,
            status: status,
            opts: [path: "/tmp/test"],
            started_at: DateTime.utc_now(),
            finished_at: nil,
            logs: [],
            result: nil,
            lease_expires_at: lease
          })

        assert %TaskInfo{lease_expires_at: ^lease} = Store.get_task(Store, id)
      end
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
