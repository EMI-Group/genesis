defmodule EvoDashWeb.TaskExportControllerTest do
  # async: false — the `?node=` describe isolates XDG_CONFIG_HOME so the
  # `EvoGit.RemoteConnections.save/1` call cannot pollute the developer's real
  # `~/.config/genesis`. That env var is process-global and is the ONLY config-dir
  # seam (`EvoGit.Config.config_dir/0` derives the path from it; there is no
  # injectable override), so an async module reading config concurrently could
  # observe this suite's temp dir — the blocker. The two module-level runner
  # seams (`:task_export_task_runner` / `:task_export_archive_runner`) are NOT a
  # blocker: they live in the `:evo_dash` app env but are read only by this
  # controller, which no other suite exercises. It writes NOTHING to the shared
  # Store: the task and the archive pages come from the injected runners.
  use EvoDashWeb.ConnCase, async: false

  # The controller logs a warning for every degraded page; capture it so the
  # suite output stays readable (captured logs are printed on failure).
  @moduletag :capture_log

  alias EvoGit.TaskInfo

  @archive_runner :task_export_archive_runner
  @task_runner :task_export_task_runner

  describe "GET /tasks/:task_id/export" do
    test "returns 404 when the task is missing or its archive is empty", %{conn: conn} do
      # Case 1: the task runner keeps its DEFAULT (the real lite read) here — a
      # nonexistent id must resolve to nil through the real store path, and the
      # archive must never be paged.
      stub_archive_runner(fn node, task_id, opts ->
        send(self(), {:archive_page, node, task_id, opts})
        %{entries: [], total: 0}
      end)

      conn = get(conn, ~p"/tasks/nonexistent-task-id/export")

      assert response(conn, 404) =~ "Task not found"
      refute_received {:archive_page, _, _, _}

      # Case 2: the task exists but has no archive entries.
      task = task_fixture()
      stub_task_runner(fn _node, _task_id -> task end)

      conn = get(conn, ~p"/tasks/#{task.id}/export")

      assert response(conn, 404) =~ "No archive data"
      assert tmp_archive_files(task.id) == []
    end

    test "returns a downloadable JSON attachment with the flat envelope", %{conn: conn} do
      task = task_fixture()

      records = [
        %{
          agent_id: "T1_A1",
          parent_id: nil,
          objective: "Build the feature",
          role: :manager,
          status: :completed,
          # The export-only settings columns: requested from the store AND
          # shipped verbatim in the document.
          llm_settings: %{model: "test-model"},
          agent_settings: %{max_turns: 10},
          foreign_repos: [%{repo_id: "docs", writable: true}]
        },
        %{
          agent_id: "T2_A1",
          parent_id: "T1_A1",
          objective: "Implement module X",
          role: :executor,
          status: :completed
        }
      ]

      stub_task_runner(fn _node, _task_id -> task end)
      stub_archive_runner(fn _node, _task_id, _opts -> %{entries: records, total: 2} end)

      conn = get(conn, ~p"/tasks/#{task.id}/export")

      body = response(conn, 200)

      [content_disposition] = get_resp_header(conn, "content-disposition")
      assert content_disposition =~ "attachment"
      assert content_disposition =~ "archive-#{task.id}.json"

      [content_type] = get_resp_header(conn, "content-type")
      assert content_type =~ "application/json"

      decoded = Jason.decode!(body)
      assert is_map(decoded)

      assert MapSet.new(Map.keys(decoded)) ==
               MapSet.new(
                 ~w(task_id task_type repo_path status started_at finished_at agent_count usage archive_records)
               )

      assert decoded["task_id"] == task.id
      assert decoded["task_type"] == "genesis"
      assert decoded["repo_path"] == "/tmp/test"
      assert decoded["status"] == "completed"
      assert decoded["started_at"] == "2026-01-01T00:00:00Z"
      assert decoded["finished_at"] == "2026-01-01T00:10:00Z"
      assert decoded["agent_count"] == 3
      assert decoded["usage"] == nil

      exported = decoded["archive_records"]
      assert is_list(exported)
      assert length(exported) == 2

      first = Enum.find(exported, fn record -> record["agent_id"] == "T1_A1" end)
      assert first["objective"] == "Build the feature"
      assert first["role"] == "manager"
      assert first["parent_id"] == nil
      assert first["llm_settings"] == %{"model" => "test-model"}
      assert first["agent_settings"] == %{"max_turns" => 10}
      assert first["foreign_repos"] == [%{"repo_id" => "docs", "writable" => true}]

      second = Enum.find(exported, fn record -> record["agent_id"] == "T2_A1" end)
      assert second["parent_id"] == "T1_A1"
      assert second["objective"] == "Implement module X"

      # The temp file is deleted once the adapter has written the body.
      assert tmp_archive_files(task.id) == []
    end

    test "streams every page in order and asks for the full-fidelity projection",
         %{conn: conn} do
      task = task_fixture()

      page_one = for index <- 1..200, do: %{agent_id: "A#{index}"}
      page_two = for index <- 201..350, do: %{agent_id: "A#{index}"}

      stub_task_runner(fn _node, _task_id -> task end)

      stub_archive_runner(fn _node, _task_id, opts ->
        send(self(), {:archive_page, opts})

        case opts[:offset] do
          0 -> %{entries: page_one, total: 350}
          200 -> %{entries: page_two, total: 350}
        end
      end)

      conn = get(conn, ~p"/tasks/#{task.id}/export")

      decoded = Jason.decode!(response(conn, 200))

      assert Enum.map(decoded["archive_records"], & &1["agent_id"]) ==
               Enum.map(page_one ++ page_two, & &1.agent_id)

      assert_received {:archive_page, first_opts}
      assert first_opts[:offset] == 0
      assert first_opts[:limit] == 200
      assert first_opts[:include_results] == true
      # The export is the full-fidelity consumer: the export-only settings
      # columns are requested too, on EVERY page (not just the first).
      assert first_opts[:include_settings] == true
      # The `total` default is kept — the paging loop stops early on it.
      refute Keyword.has_key?(first_opts, :include_total)

      assert_received {:archive_page, second_opts}
      assert second_opts[:offset] == 200
      assert second_opts[:include_results] == true
      assert second_opts[:include_settings] == true

      refute_received {:archive_page, _opts}
      assert tmp_archive_files(task.id) == []
    end

    test "paging stops on the reported total, a short page or an empty page", %{conn: conn} do
      full = for index <- 1..200, do: %{agent_id: "A#{index}"}
      short = for index <- 201..260, do: %{agent_id: "A#{index}"}

      cases = [
        # A page source that would return a FULL page forever: only the
        # reported `total` (350) can stop the loop.
        {:total, fn _offset -> %{entries: full, total: 350} end, 350, [0, 200]},
        # A lean roster projection reports NO per-page COUNT(*): the short
        # second page is complete data — nothing truncated, no third RPC.
        {:short_second, fn offset -> %{entries: if(offset == 0, do: full, else: short)} end, 260,
         [0, 200]},
        # An empty page ends the loop — it can never spin without a total.
        {:empty_second, fn offset -> %{entries: if(offset == 0, do: full, else: [])} end, 200,
         [0, 200]},
        # A short FIRST page is already complete.
        {:short_first, fn _offset -> %{entries: short} end, 60, [0]}
      ]

      for {label, page_fun, expected_count, expected_offsets} <- cases do
        task = task_fixture()
        stub_task_runner(fn _node, _task_id -> task end)

        stub_archive_runner(fn _node, _task_id, opts ->
          send(self(), {:archive_page, opts[:offset]})
          page_fun.(opts[:offset])
        end)

        decoded = Jason.decode!(response(get(conn, ~p"/tasks/#{task.id}/export"), 200))
        assert length(decoded["archive_records"]) == expected_count, inspect(label)

        for expected_offset <- expected_offsets do
          assert_received {:archive_page, offset}
          assert offset == expected_offset, inspect(label)
        end

        # Exactly these pages — never one more.
        refute_received {:archive_page, _}, inspect(label)
        assert tmp_archive_files(task.id) == []
      end
    end

    test "normalizes non-JSON terms inside archive records", %{conn: conn} do
      task = task_fixture()
      naive = ~N[2026-02-03 04:05:06]
      pid = self()

      stub_task_runner(fn _node, _task_id -> task end)

      stub_archive_runner(fn _node, _task_id, _opts ->
        %{
          entries: [
            %{agent_id: "T1_A1", finished_at: naive, role: :manager, tags: {:a, 1}, pid: pid}
          ],
          total: 1
        }
      end)

      conn = get(conn, ~p"/tasks/#{task.id}/export")

      decoded = Jason.decode!(response(conn, 200))
      [record] = decoded["archive_records"]

      # NaiveDateTime -> ISO-8601 string
      assert record["finished_at"] == "2026-02-03T04:05:06"
      # atom values are encoded as strings (atom keys were stringified too)
      assert record["role"] == "manager"
      # tuples -> lists
      assert record["tags"] == ["a", 1]
      # PIDs -> inspect/1 string
      assert record["pid"] == inspect(pid)
      assert record["agent_id"] == "T1_A1"
    end

    test "a failing page mid-pagination degrades to a truncated but valid document",
         %{conn: conn} do
      task = task_fixture()

      stub_task_runner(fn _node, _task_id -> task end)

      stub_archive_runner(fn _node, _task_id, opts ->
        case opts[:offset] do
          0 -> %{entries: [%{agent_id: "A1"}, %{agent_id: "A2"}], total: 4}
          # A dead store / RPC exit: SafeCall turns this into an error value.
          2 -> raise "store went away"
        end
      end)

      conn = get(conn, ~p"/tasks/#{task.id}/export")

      # Chosen degradation: stop paging, keep what was already written, answer
      # 200 with a valid (truncated) JSON document.
      decoded = Jason.decode!(response(conn, 200))

      assert Enum.map(decoded["archive_records"], & &1["agent_id"]) == ["A1", "A2"]
      assert tmp_archive_files(task.id) == []
    end

    test "a failing first page or an unexpected page shape yields the empty-archive 404",
         %{conn: conn} do
      task = task_fixture()
      stub_task_runner(fn _node, _task_id -> task end)

      for page_fun <- [fn _opts -> raise "store went away" end, fn _opts -> :not_a_page end] do
        stub_archive_runner(fn _node, _task_id, opts -> page_fun.(opts) end)

        conn = get(conn, ~p"/tasks/#{task.id}/export")

        assert response(conn, 404) =~ "No archive data"
        assert tmp_archive_files(task.id) == []
      end
    end

    test "an unencodable record or head field yields a 500 and leaves no temp file",
         %{conn: conn} do
      # Invalid UTF-8 cannot be encoded by Jason. Two shapes: inside a record,
      # and in the document head (`repo_path` from the task's `:path` opt).
      for {task, entries} <- [
            {task_fixture(), [%{agent_id: <<0xFF>>}]},
            {task_fixture(opts: [path: <<0xFF>>]), [%{agent_id: "T1_A1"}]}
          ] do
        stub_task_runner(fn _node, _task_id -> task end)
        stub_archive_runner(fn _node, _task_id, _opts -> %{entries: entries, total: 1} end)

        conn = get(conn, ~p"/tasks/#{task.id}/export")

        assert response(conn, 500) =~ "Archive export failed"
        assert tmp_archive_files(task.id) == []
      end
    end
  end

  describe "GET /tasks/:task_id/export with ?node= param" do
    # The node-aware export resolves `?node=` through EvoGit.RemoteConnections
    # (a TOML file under the config dir), so XDG_CONFIG_HOME is isolated per
    # test — same pattern as page_controller_test / settings_live_test.
    setup do
      original = System.get_env("XDG_CONFIG_HOME")

      tmp_config =
        Path.join(
          System.tmp_dir!(),
          "evogit_test_config_export_" <> to_string(System.unique_integer([:positive]))
        )

      File.mkdir_p!(tmp_config)
      System.put_env("XDG_CONFIG_HOME", tmp_config)

      on_exit(fn ->
        File.rm_rf(tmp_config)

        if original do
          System.put_env("XDG_CONFIG_HOME", original)
        else
          System.delete_env("XDG_CONFIG_HOME")
        end
      end)

      :ok
    end

    test "returns 404 without any read for an unknown or disconnected node", %{conn: conn} do
      stub_task_runner(fn node, task_id ->
        send(self(), {:task_read, node, task_id})
        nil
      end)

      stub_archive_runner(fn node, task_id, opts ->
        send(self(), {:archive_page, node, task_id, opts})
        %{entries: [], total: 0}
      end)

      # Case 1: the target id is not configured at all.
      conn = get(conn, "/tasks/nonexistent-task-id/export?node=unknown-target-id")

      assert response(conn, 404) =~ "Task not found"
      refute_received {:task_read, _, _}
      refute_received {:archive_page, _, _, _}

      # Case 2: the target exists but no connection manager is registered for
      # it, so connection_status/1 degrades to :disconnected → the export must
      # 404 exactly like the local not-found path, without any read.
      id = "export-test-target-#{System.unique_integer([:positive])}"

      {:ok, _target} =
        EvoGit.RemoteConnections.save(%{
          ssh_target: "user@host",
          id: id,
          name: "Export Test Target"
        })

      conn = get(conn, "/tasks/nonexistent-task-id/export?node=" <> id)

      assert response(conn, 404) =~ "Task not found"
      refute_received {:task_read, _, _}
      refute_received {:archive_page, _, _, _}
    end

    test "?node=<connected target> propagates the remote node to both runners", %{conn: conn} do
      id = "export-node-target-#{System.unique_integer([:positive])}"

      {:ok, _target} =
        EvoGit.RemoteConnections.save(%{
          ssh_target: "user@host",
          id: id,
          name: "Export Node Target"
        })

      start_supervised!(
        {EvoDashWeb.TaskExportControllerTest.ConnectionManager,
         {id, %{phase: :connected, node: "genesis_remote_export@127.0.0.1", last_error: nil}}}
      )

      task = task_fixture()

      stub_task_runner(fn node, task_id ->
        send(self(), {:task_read, node, task_id})
        task
      end)

      stub_archive_runner(fn node, task_id, opts ->
        send(self(), {:archive_page, node, task_id, opts})
        %{entries: [%{agent_id: "T1_A1"}], total: 1}
      end)

      conn = get(conn, "/tasks/#{task.id}/export?node=" <> id)

      decoded = Jason.decode!(response(conn, 200))
      assert length(decoded["archive_records"]) == 1

      remote_node = :"genesis_remote_export@127.0.0.1"

      assert_received {:task_read, ^remote_node, task_id}
      assert task_id == task.id

      assert_received {:archive_page, ^remote_node, archive_task_id, opts}
      assert archive_task_id == task.id
      assert opts[:include_results] == true
      assert opts[:include_settings] == true
    end

    test "?node=local keeps the local path working", %{conn: conn} do
      task = task_fixture()

      stub_task_runner(fn node, _task_id ->
        send(self(), {:task_read, node})
        task
      end)

      stub_archive_runner(fn _node, _task_id, _opts ->
        %{entries: [%{agent_id: "T1_A1", objective: "Build the feature"}], total: 1}
      end)

      conn = get(conn, "/tasks/#{task.id}/export?node=local")

      assert response(conn, 200)
      assert_received {:task_read, read_node}
      assert read_node == node()
    end
  end

  # ── helpers ────────────────────────────────────────────────────────

  # Injects a runner seam and restores the previous value on exit, so no
  # `:evo_dash` app-env state leaks into another suite.
  defp put_seam(key, fun) do
    previous = Application.get_env(:evo_dash, key)
    Application.put_env(:evo_dash, key, fun)

    on_exit(fn ->
      case previous do
        nil -> Application.delete_env(:evo_dash, key)
        value -> Application.put_env(:evo_dash, key, value)
      end
    end)

    :ok
  end

  defp stub_task_runner(fun), do: put_seam(@task_runner, fun)
  defp stub_archive_runner(fun), do: put_seam(@archive_runner, fun)

  defp task_fixture(overrides \\ []) do
    defaults = [
      id: "export_task_#{System.unique_integer([:positive])}",
      type: :genesis,
      status: :completed,
      opts: [path: "/tmp/test"],
      started_at: ~U[2026-01-01 00:00:00Z],
      finished_at: ~U[2026-01-01 00:10:00Z],
      agent_count: 3
    ]

    struct(TaskInfo, Keyword.merge(defaults, overrides))
  end

  # The controller's temp-file name is `archive-<task_id>-<unique>.json`; a
  # task id is unique per test, so this glob is test-private.
  defp tmp_archive_files(task_id) do
    Path.wildcard(Path.join(System.tmp_dir!(), "archive-#{task_id}-*.json"))
  end
end

# Fake connection manager: registering it under the target id in
# `EvoGit.RemoteConnection.Registry` is how the production `status/1` read is
# answered (same pattern as the LiveView suites).
defmodule EvoDashWeb.TaskExportControllerTest.ConnectionManager do
  use GenServer

  def start_link(args) do
    GenServer.start_link(__MODULE__, args)
  end

  @impl true
  def init({target_id, status}) do
    Registry.register(EvoGit.RemoteConnection.Registry, target_id, :status)
    {:ok, status}
  end

  @impl true
  def handle_call(:status, _from, status), do: {:reply, status, status}
end
