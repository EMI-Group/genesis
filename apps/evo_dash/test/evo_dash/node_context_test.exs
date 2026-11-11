# Three modules live in this file so the bulk of the suite can run in the ASYNC
# phase:
#
#   * `EvoDash.NodeContextTest` (`async: true`) — every describe that never
#     touches process-global state. It writes into the RUN-WIDE per-run store
#     with UNIQUE ids/paths (the idiom already used by the task-review
#     describe), so nothing has to be swapped or isolated.
#   * `EvoDash.NodeContextConfigTest` (`async: true`) — the two describes that
#     WRITE the viewed node's config dir (`agents.toml`, `tools/`). They isolate
#     the dir PER PROCESS through the test-only `:config_dir_fun` seam installed
#     by test/test_helper.exs (`EvoDash.Test.ConfigDir.isolate!/1`): the override
#     lives in the TEST process' dictionary and both the RPC code under test and
#     anything it spawns reach it through the OTP `:"$callers"` chain. Nothing
#     process-global is mutated, so both modules run in the async phase.
#   * `EvoDash.NodeContextSessionTest` (`async: false`, at the end of the file) —
#     the interactive-session passthroughs, which drive a REAL
#     `EvoGit.Agent.Session` off the app-global scheduler. Its forcing globals
#     are listed in its own header comment.
#
# The split itself stays: ExUnit parallelises across MODULES, never within one,
# so each async module runs on its own runner instead of one.
defmodule EvoDash.NodeContextTest do
  use EvoDashWeb.ConnCase, async: true

  import ExUnit.CaptureLog

  alias EvoGit.ProcessManager.Execution
  alias EvoGit.TaskInfo

  # Fixtures go into the RUN-WIDE test store (a per-run unique sqlite DB, see
  # `config/test.exs`). Every row is identified by an id (and, for the paged
  # reads, a project path) from `System.unique_integer/1`, so assertions can
  # stay EXACT on a shared table and no leftover row can ever satisfy a
  # "not_found"/"total: 0" assertion.
  #
  # `insert_fixture!/1` registers its own teardown: an `on_exit` callback
  # deletes exactly the id this test created (`EvoGit.Store.delete_task/2`
  # also drops that task's `task_agent_archives` rows), so no row of this
  # module's can leak into a peer suite's read.
  defp insert_fixture!(overrides) do
    id = "fixture_#{System.unique_integer([:positive])}"

    task =
      %TaskInfo{
        id: id,
        type: :genesis,
        status: :pending,
        opts: [path: "/tmp/test"],
        ref: nil,
        started_at: DateTime.utc_now(),
        finished_at: nil,
        logs: [],
        result: nil
      }
      |> Map.merge(Enum.into(overrides, %{}))

    EvoGit.Store.put_task(EvoGit.Store, task)
    on_exit(fn -> EvoGit.Store.delete_task(EvoGit.Store, id) end)
    id
  end

  # Unique project path = the exact-count anchor for the paged-read tests
  # (`list_tasks_page/2` applies `status` and `project_path` as AND-ed WHERE
  # clauses, so a filtered read sees only this test's rows).
  defp unique_project_path do
    "/tmp/node_ctx_#{System.unique_integer([:positive])}"
  end

  # An id that provably matches no row in the shared store.
  defp missing_id do
    "missing-#{System.unique_integer([:positive])}"
  end

  describe "task-cancellation RPC delegates (local node, real paths)" do
    test "cancel_task/2 returns {:error, :not_found} for a missing task" do
      assert EvoDash.NodeContext.cancel_task(node(), missing_id()) == {:error, :not_found}
    end

    test "force_kill_task/2 returns {:error, :not_found} for a missing task" do
      assert EvoDash.NodeContext.force_kill_task(node(), missing_id()) == {:error, :not_found}
    end

    test "cancel_task/2 on a :pending task marks it :cancelled immediately" do
      id = insert_fixture!(status: :pending)

      assert EvoDash.NodeContext.cancel_task(node(), id) == :ok
      assert EvoGit.Store.get_task_status(EvoGit.Store, id) == :cancelled
    end
  end

  describe "lightweight task reads (local node, real paths)" do
    # The summary/lite reads route through
    # `EvoGit.RemoteNode` → `RemoteAPI` → `EvoGit.TaskRegistry` → `EvoGit.Store`,
    # so they are served by the run-wide store with real rows. Each test pins
    # its own unique `project_path`, which keeps every count assertion exact.
    # The exact summary projection: 17 keys, all of them scalar/lite. The 17th
    # (`session_mode`) is the task's driver mode — `"oneshot"` / `"interactive"`
    # — decoded by the core through `Codec.decode_session_mode/1`.
    @summary_keys ~w(
      id status review_status started_at finished_at type project_path opts
      branch_name model_id agent_count base_sha commit_sha lease_expires_at
      updated_at error session_mode
    )a
    test "list_tasks_page/2 returns summary rows + the filtered total (no heavy blobs)" do
      project_path = unique_project_path()
      id = insert_fixture!(status: :completed, project_path: project_path)

      assert %{rows: [row], total: 1} =
               EvoDash.NodeContext.list_tasks_page(node(), project_path: project_path)

      assert row.id == id
      assert row.status == :completed
      assert row.project_path == project_path
      # The 17-key projection: heavy blobs are never part of a summary row.
      assert Enum.sort(Map.keys(row)) == Enum.sort(@summary_keys)
      refute Map.has_key?(row, :result)
      refute Map.has_key?(row, :usage)
      refute Map.has_key?(row, :logs)
      refute Map.has_key?(row, :archive_metadata)
    end

    test "list_tasks_page/2 forwards limit/offset and the filter opts" do
      project_path = unique_project_path()
      insert_fixture!(status: :completed, project_path: project_path)
      keep = insert_fixture!(status: :failed, project_path: project_path)

      # The core filter expects the status as its on-disk STRING (the summary
      # rows still decode it back to an atom); `status` and `project_path` are
      # AND-ed, so this sees only the failed row of THIS test's project.
      assert %{rows: [row], total: 1} =
               EvoDash.NodeContext.list_tasks_page(node(),
                 status: "failed",
                 project_path: project_path
               )

      assert row.id == keep
      assert row.status == :failed

      assert %{rows: [], total: 0} =
               EvoDash.NodeContext.list_tasks_page(node(),
                 project_path: unique_project_path()
               )

      assert %{rows: rows, total: 2} =
               EvoDash.NodeContext.list_tasks_page(node(),
                 project_path: project_path,
                 limit: 1,
                 offset: 0
               )

      assert length(rows) == 1
    end

    test "get_task_lite/2 and get_task/2 carry no archive key (the archive is its own table)" do
      archive = [%{"role" => "user", "content" => "archived"}]

      id =
        insert_fixture!(
          status: :completed,
          result: {:ok, %{commit_sha: "sha1", archive_records: archive}}
        )

      assert %EvoGit.TaskInfo{id: ^id} =
               lite =
               EvoDash.NodeContext.get_task_lite(node(), id)

      # The per-agent archive is NOT a task-row column any more — until the
      # `task_agent_archives` rebuild the field carried the whole archive. Both
      # reads decode the row identically and expose no archive key at all; the
      # archive is read through `list_task_archives/3` / `get_agent_archive/3`.
      refute Map.has_key?(lite, :archive_metadata)
      refute Map.has_key?(EvoDash.NodeContext.get_task(node(), id), :archive_metadata)

      assert {:ok, data} = lite.result
      assert data.commit_sha == "sha1"
    end

    test "get_task_lite/2 returns nil for a missing task" do
      assert EvoDash.NodeContext.get_task_lite(node(), missing_id()) == nil
    end
  end

  describe "paged task-archive reads (EvoGit.RemoteNode delegation)" do
    # `EvoGit.RemoteNode.list_task_archives/3` and `get_agent_archive/3` exist
    # in this tree; the `Code.ensure_loaded?` check below is only a defensive
    # availability guard, and there is no runner seam for the delegation — the
    # existing tests hit the real local path. These tests assert the observable
    # surface unconditionally: the documented arities (incl. the `opts \\ []`
    # default form) and the totality of the two normalization steps NodeContext
    # applies to EVERY payload, which is what makes the mirrors safe for
    # callers. None of them writes a row, so no isolation is needed.
    test "list_task_archives/3 and get_agent_archive/3 expose the documented arities" do
      # `function_exported?/3` does NOT load a module, so its answer would
      # depend on whether some other test happened to run first. Load it
      # explicitly (fails loudly if the module is gone) before checking.
      Code.ensure_loaded!(EvoDash.NodeContext)
      assert function_exported?(EvoDash.NodeContext, :list_task_archives, 2)
      assert function_exported?(EvoDash.NodeContext, :list_task_archives, 3)
      assert function_exported?(EvoDash.NodeContext, :get_agent_archive, 3)
      # The single-blob archive read is gone — no deprecation shim survives.
      refute function_exported?(EvoDash.NodeContext, :get_task_archive, 2)
    end

    test "the opts keyword is forwarded unchanged (observable once the core lands)" do
      # Same load-before-inspect rule as above: without it the branch taken
      # here depends on test order.
      core_available? = Code.ensure_loaded?(EvoGit.RemoteNode)

      if core_available? and function_exported?(EvoGit.RemoteNode, :list_task_archives, 3) do
        # Real local path: the opts keyword rides through untouched (an unknown
        # task id yields the empty page instead of an error for any opts).
        opts = [limit: 5, offset: 10, include_results: true]

        assert EvoDash.NodeContext.list_task_archives(node(), missing_id(), opts) ==
                 %{entries: [], total: 0}

        # The `opts \\ []` default form delegates with the same shape.
        assert EvoDash.NodeContext.list_task_archives(node(), missing_id()) ==
                 %{entries: [], total: 0}
      else
        # Defensive branch: EvoGit.RemoteNode is not loaded/available here, so
        # there is nothing to call. The documented default is part of the
        # function head, provable through the 2-arity export above.
        assert function_exported?(EvoDash.NodeContext, :list_task_archives, 2)
      end
    end

    test "normalize_archive_page/1 keeps a well-formed atom-keyed page untouched" do
      entries = [%{"agent_id" => "a1", "depth" => 0}, %{"agent_id" => "a2", "depth" => 1}]

      assert EvoDash.NodeContext.normalize_archive_page(%{entries: entries, total: 2}) ==
               %{entries: entries, total: 2}

      # Empty page (a task with no archive) is a well-formed payload too.
      assert EvoDash.NodeContext.normalize_archive_page(%{entries: [], total: 0}) ==
               %{entries: [], total: 0}
    end

    test "normalize_archive_page/1 normalizes a string-keyed page to atom keys" do
      entries = [%{"agent_id" => "a1", "depth" => 0}]

      assert EvoDash.NodeContext.normalize_archive_page(%{"entries" => entries, "total" => 7}) ==
               %{entries: entries, total: 7}
    end

    test "normalize_archive_page/1 degrades non-map payloads to the empty page" do
      empty = %{entries: [], total: 0}

      # nil / error tuples (a failed or unreachable remote call) / garbage.
      assert EvoDash.NodeContext.normalize_archive_page(nil) == empty
      assert EvoDash.NodeContext.normalize_archive_page({:error, :boom}) == empty
      assert EvoDash.NodeContext.normalize_archive_page({:error, {:erpc, :noconnection}}) == empty
      assert EvoDash.NodeContext.normalize_archive_page(:garbage) == empty
      assert EvoDash.NodeContext.normalize_archive_page([%{"agent_id" => "a1"}]) == empty
      assert EvoDash.NodeContext.normalize_archive_page("") == empty

      # A map without either key shape is degraded, never raised on.
      assert EvoDash.NodeContext.normalize_archive_page(%{}) == empty
      assert EvoDash.NodeContext.normalize_archive_page(%{rows: [], count: 3}) == empty
    end

    test "normalize_archive_page/1 coerces malformed fields instead of raising" do
      # Non-list entries → []; non-integer/negative total → 0.
      assert EvoDash.NodeContext.normalize_archive_page(%{entries: :bad, total: "x"}) ==
               %{entries: [], total: 0}

      assert EvoDash.NodeContext.normalize_archive_page(%{entries: nil, total: -4}) ==
               %{entries: [], total: 0}

      # Each field degrades independently: a good list survives a bad total.
      assert EvoDash.NodeContext.normalize_archive_page(%{entries: [%{"a" => 1}], total: nil}) ==
               %{entries: [%{"a" => 1}], total: 0}

      assert EvoDash.NodeContext.normalize_archive_page(%{"entries" => "nope", "total" => 3.0}) ==
               %{entries: [], total: 0}
    end

    test "normalize_archive_entry/1 passes a map through and nils everything else" do
      entry = %{"agent_id" => "a1", "depth" => 0, "result" => %{"objective" => "o"}}

      # Verbatim — including the full "result" the paged read omits.
      assert EvoDash.NodeContext.normalize_archive_entry(entry) == entry

      assert EvoDash.NodeContext.normalize_archive_entry(nil) == nil
      assert EvoDash.NodeContext.normalize_archive_entry({:error, :boom}) == nil
      assert EvoDash.NodeContext.normalize_archive_entry({:error, {:erpc, :noconnection}}) == nil
      assert EvoDash.NodeContext.normalize_archive_entry([%{"agent_id" => "a1"}]) == nil
      assert EvoDash.NodeContext.normalize_archive_entry("garbage") == nil
    end
  end

  describe "task-review RPC delegates (local node, real paths)" do
    test "get_task/2 returns nil for a missing task" do
      assert EvoDash.NodeContext.get_task(node(), missing_id()) == nil
    end

    test "get_task/2 returns the stored %TaskInfo{} for an existing task" do
      # `:completed` keeps the row out of the sidebar's active-task projection
      # (`:running`/`:pending`/`:cancelling`) while this async test is running.
      id = insert_fixture!(status: :completed)

      assert %EvoGit.TaskInfo{id: ^id} = EvoDash.NodeContext.get_task(node(), id)
    end

    test "set_review_status/3 and set_review_metadata/4 are fire-and-forget casts (:ok)" do
      assert EvoDash.NodeContext.set_review_status(node(), missing_id(), :completed) == :ok

      assert EvoDash.NodeContext.set_review_metadata(node(), missing_id(), "base", "commit") ==
               :ok
    end

    test "review git wrappers delegate with the node first (shape checks on the local path)" do
      # These run real EvoGit.Review calls against a nonexistent repo path, so
      # only the envelope shape is asserted (git fails with an error tuple —
      # never a raise).
      assert {:error, _} = EvoDash.NodeContext.default_merge_target(node(), "/nonexistent")

      assert {:error, _} =
               EvoDash.NodeContext.load_review_metadata(node(), "/nonexistent", "main")

      assert {:error, _} = EvoDash.NodeContext.load_commit_files(node(), "/nonexistent", "abc123")
    end
  end

  describe "GitHub issue delegates (local node, shape checks)" do
    # The GitHub delegates run the real EvoGit.Adapters.GitHub prelude against
    # a nonexistent repo path — the File.dir?/1 guard fails FIRST, so gh/git
    # are never invoked (no shell-out, no network). Only the passthrough
    # shapes are asserted, matching the "review git wrappers" convention
    # above.
    test "github_upstream/2 passes the adapter error through verbatim" do
      assert EvoDash.NodeContext.github_upstream(node(), "/nonexistent") ==
               {:error, {:enoent, "/nonexistent"}}
    end

    test "list_github_issues/3 with default opts passes the adapter error through verbatim" do
      assert EvoDash.NodeContext.list_github_issues(node(), "/nonexistent") ==
               {:error, {:enoent, "/nonexistent"}}
    end

    test "list_github_issues/3 accepts an explicit state opt" do
      assert EvoDash.NodeContext.list_github_issues(node(), "/nonexistent", state: "closed") ==
               {:error, {:enoent, "/nonexistent"}}
    end

    test "github_issue_markdown/3 passes the adapter error through verbatim" do
      assert EvoDash.NodeContext.github_issue_markdown(node(), "/nonexistent", 42) ==
               {:error, {:enoent, "/nonexistent"}}
    end
  end

  describe "get_resolved_config/1 (local node, real paths)" do
    test "returns the full resolved config map with scheduler/llm keys" do
      assert {:ok, config} = EvoDash.NodeContext.get_resolved_config(node())
      assert is_map(config[:scheduler])
      assert is_map(config[:llm])
      # The full resolved config carries the remaining sections too — this is
      # what makes the remote Settings page render every category.
      assert is_map(config[:tools])
      assert is_map(config[:sandbox])
    end
  end

  describe "get_recent_system_samples/1 (local node, real path)" do
    # The supervised EvoGit.SystemSampler runs in the test app, but its tick is
    # disabled in test env (config/test.exs: :system_sample_interval_ms,
    # 86_400_000), so the ring buffer is empty — the passthrough delegate must
    # surface the real sampler's {:ok, samples} shape verbatim.
    test "returns the real sampler's {:ok, samples} list" do
      assert {:ok, samples} = EvoDash.NodeContext.get_recent_system_samples(node())
      assert is_list(samples)
    end
  end

  describe "approval_response/3 (interactive command approvals)" do
    test "non-approve/deny decisions are rejected before any dispatch (whitelist is total)" do
      # The decision whitelist normalizes "approve"|"deny" binaries AND
      # :approve|:deny atoms; anything else returns the error tuple without
      # ever dispatching (never String.to_atom on raw input). node() is
      # irrelevant here — the invalid decision short-circuits first.
      assert EvoDash.NodeContext.approval_response(node(), "r1", "maybe") ==
               {:error, {:invalid_decision, "maybe"}}

      assert EvoDash.NodeContext.approval_response(node(), "r1", 42) ==
               {:error, {:invalid_decision, 42}}
    end

    test "valid decisions dispatch on the local path" do
      # EvoGit.CommandApproval exists in this tree; the `Code.ensure_loaded?`
      # guard is a defensive availability check (the module lives on the core
      # side), mirroring home_live_test.exs:63 and the node_context.ex
      # with_remote_connection/4 pattern. With the module loaded, responding on
      # an unknown request id must degrade to an error tuple rather than raise;
      # without it, the guarded local path answers
      # {:error, :command_approval_unavailable}.
      if Code.ensure_loaded?(EvoGit.CommandApproval) do
        assert match?({:error, _}, EvoDash.NodeContext.approval_response(node(), "r1", "approve"))
      else
        assert EvoDash.NodeContext.approval_response(node(), "r1", "approve") ==
                 {:error, :command_approval_unavailable}
      end

      # The atom-decision form is idempotent — same dispatch shape as the
      # binary form (whitelist maps :deny -> :deny unchanged).
      if Code.ensure_loaded?(EvoGit.CommandApproval) do
        assert match?({:error, _}, EvoDash.NodeContext.approval_response(node(), "r1", :deny))
      else
        assert EvoDash.NodeContext.approval_response(node(), "r1", :deny) ==
                 {:error, :command_approval_unavailable}
      end
    end

    test "remote path transport failure is normalized and never raises" do
      # No distribution to that node in the test env. The exact failure shape
      # depends on whether the LOCAL node is distributed (some dev machines
      # boot with [node] enabled + a free dist port — the boot attempt is
      # skipped/fails on CI and here, where port 9000 is busy):
      #   * non-distributed local node (:nonode@nohost) — :erpc.call RAISES
      #     {:erpc, :noconnection}, which the catch clause normalizes into
      #     {:error, {:error, {:erpc, :noconnection}}} (the same fast-fail
      #     :noconnection the node_aware_test.exs remote-node tests rely on);
      #   * distributed local node — :erpc.call returns {:badrpc, :nodedown},
      #     which the case unwraps to {:error, :nodedown}.
      # Either way the function is total: it returns an error tuple, never
      # raises from a LiveView call path.
      # Wrapped in CaptureLog: same between-test console-noise rationale as the
      # unreachable-remote custom_tools_status case in the config module below.
      {result, _log} =
        with_log(fn ->
          EvoDash.NodeContext.approval_response(:"nonexistent-node@nowhere", "r1", "approve")
        end)

      if node() == :nonode@nohost do
        assert result == {:error, {:error, {:erpc, :noconnection}}}
      else
        assert result == {:error, :nodedown}
      end
    end
  end

  describe "managed processes — local-first (isolated ProcessManager instance)" do
    # The viewed node IS this BEAM, so these four helpers call
    # `EvoGit.ProcessManager` DIRECTLY — no `EvoGit.RemoteNode`, no `:erpc`,
    # no RPC seam. Every manager call resolves its registry name at CALL time
    # via `EvoGit.ProcessManager.server/0`
    # (`Process.get(:evogit_process_manager_server) || EvoGit.ProcessManager`).
    #
    # So each test starts its OWN named instance and points this process at it:
    # the app-global `EvoGit.ProcessManager` (a child of `EvoGit.Application`) is
    # never reconfigured, and both the instance name and the process-dictionary
    # pointer are per-test — nothing process-global is mutated, so the module
    # stays `async: true`.
    setup do
      name = :"proc_mgr_test_#{System.unique_integer([:positive])}"
      start_supervised!({EvoGit.ProcessManager, [name: name]})
      Process.put(:evogit_process_manager_server, name)
      on_exit(fn -> Process.delete(:evogit_process_manager_server) end)
      :ok
    end

    # Seeds ONE `:tool_call` execution on the isolated instance. `:owner_pid` is
    # deliberately omitted: the record then outlives nobody and no monitor is
    # created for the test process.
    defp track_execution!(command, meta) do
      meta =
        Enum.into(meta, %{command: command, tool: "bash", runtime: :foreground})

      assert {:ok, id} = EvoGit.ProcessManager.track(:tool_call, meta)
      id
    end

    test "list_processes/2 returns the tracked executions, newest first" do
      first = track_execution!("echo first", %{agent_id: 4242, task_id: "task-x"})
      second = track_execution!("echo second", %{agent_id: 4242, task_id: "task-x"})

      # Exact: the isolated instance holds exactly these two records.
      assert [%Execution{} = newest, %Execution{} = oldest] =
               EvoDash.NodeContext.list_processes(node())

      assert newest.id == second
      assert oldest.id == first

      assert %Execution{
               id: ^second,
               kind: :tool_call,
               tool: "bash",
               command: "echo second",
               agent_id: 4242,
               task_id: "task-x",
               runtime: :foreground,
               backend: :none,
               status: :starting
             } = newest

      assert oldest.command == "echo first"
    end

    test "list_processes/2 passes the agent_id/task_id filters through exactly" do
      mine = track_execution!("echo mine", %{agent_id: 4242, task_id: "task-x"})
      _other = track_execution!("echo other", %{agent_id: 7777, task_id: "task-y"})

      assert [%Execution{id: ^mine}] = EvoDash.NodeContext.list_processes(node(), agent_id: 4242)

      assert [%Execution{id: ^mine}] =
               EvoDash.NodeContext.list_processes(node(), task_id: "task-x")

      # Filters are AND-ed and exact: no record matches a foreign identity.
      assert EvoDash.NodeContext.list_processes(node(), agent_id: 9999) == []
      assert EvoDash.NodeContext.list_processes(node(), agent_id: 7777, task_id: "task-x") == []
    end

    test "an unreachable manager degrades: list is [] and the id read unwraps its answer" do
      track_execution!("echo x", %{agent_id: 4242, task_id: "task-x"})

      # A NAME with no registered process: the local liveness guard fails, so
      # the documented degraded values come back instead of an exit (and
      # `list_processes/2` never leaks an envelope).
      Process.put(
        :evogit_process_manager_server,
        :"no_such_manager_#{System.unique_integer([:positive])}"
      )

      assert EvoDash.NodeContext.list_processes(node(), []) == []

      assert EvoDash.NodeContext.get_process(node(), "proc-1") ==
               {:error, :process_manager_unavailable}
    end

    test "get_process/2 returns the execution, or :not_found for unknown/non-binary ids" do
      id = track_execution!("echo x", %{agent_id: 4242, task_id: "task-x"})

      assert {:ok, %Execution{id: ^id, command: "echo x", agent_id: 4242, task_id: "task-x"}} =
               EvoDash.NodeContext.get_process(node(), id)

      # The envelope is unwrapped: the core's own `{:error, :not_found}` arrives
      # bare, never as `{:ok, {:error, :not_found}}`.
      assert EvoDash.NodeContext.get_process(node(), "proc-999999") == {:error, :not_found}
      assert EvoDash.NodeContext.get_process(node(), 123) == {:error, :not_found}

      # A non-binary id answers without any call: an unreachable manager would
      # report `:process_manager_unavailable`, so `:not_found` proves the
      # short-circuit.
      Process.put(
        :evogit_process_manager_server,
        :"no_such_manager_#{System.unique_integer([:positive])}"
      )

      assert EvoDash.NodeContext.get_process(node(), 123) == {:error, :not_found}
    end

    test "process_stats/2 is the core's own answer for a missing/unprobeable id" do
      missing = "proc-999999"

      # Verbatim core answer, both read the same isolated manager.
      assert EvoDash.NodeContext.process_stats(node(), missing) ==
               EvoGit.ProcessManager.sample(missing)

      assert EvoDash.NodeContext.process_stats(node(), missing) == {:error, :not_found}

      # A tracked record that never attached an OS handle: the manager's own
      # `{:error, :not_running}` reaches the caller unchanged.
      id = track_execution!("echo x", %{agent_id: 4242, task_id: "task-x"})

      assert EvoDash.NodeContext.process_stats(node(), id) ==
               EvoGit.ProcessManager.sample(id)

      assert EvoDash.NodeContext.process_stats(node(), id) == {:error, :not_running}

      assert EvoDash.NodeContext.process_stats(node(), 123) == {:error, :not_found}
    end

    test "process_control/4 unwraps core errors and never forwards an unknown action" do
      id = track_execution!("echo x", %{agent_id: 4242, task_id: "task-x"})

      assert EvoDash.NodeContext.process_control(node(), "proc-999999", :pause, "no such id") ==
               {:error, :not_found}

      # A tracked record with no OS handle: the manager's own `:no_handle`, not
      # `:process_manager_unavailable` — the answer is passed through verbatim.
      assert EvoDash.NodeContext.process_control(node(), id, :pause, "no handle yet") ==
               {:error, :no_handle}

      # An unrecognized action is answered by NodeContext itself (never
      # forwarded to the manager, so the isolated registry cannot crash).
      assert EvoDash.NodeContext.process_control(node(), id, :bogus, "bad action") ==
               {:error, {:unknown_action, :bogus}}

      assert EvoDash.NodeContext.process_control(node(), 123, :pause, "non-binary id") ==
               {:error, :not_found}

      # The manager survived the invalid action and still answers a valid read.
      assert {:ok, %Execution{id: ^id, status: :starting, control_log: []}} =
               EvoDash.NodeContext.get_process(node(), id)
    end
  end

  describe "managed processes — local node never touches the remote machinery" do
    # `Process.get(:node_context_process_rpc)` is the forcing mechanism: the
    # remote transport is resolved at CALL time inside the remote branch, so a
    # PROCESS-LOCAL override proves the local path never reaches it. This keeps
    # the module `async: true` (a `Task`-spawned caller would need `$callers`
    # to inherit the value).
    setup do
      name = :"proc_mgr_local_#{System.unique_integer([:positive])}"
      start_supervised!({EvoGit.ProcessManager, [name: name]})
      Process.put(:evogit_process_manager_server, name)
      test_pid = self()

      Process.put(:node_context_process_rpc, fn node, mod, fun, args ->
        send(test_pid, {:rpc_called, node, mod, fun, args})
        {:ok, :should_not_happen}
      end)

      on_exit(fn ->
        Process.delete(:evogit_process_manager_server)
        Process.delete(:node_context_process_rpc)
      end)

      :ok
    end

    test "list/get/stats/control all answer from the in-BEAM manager, with no RPC" do
      assert {:ok, id} =
               EvoGit.ProcessManager.track(:tool_call, %{
                 command: "echo local",
                 tool: "bash",
                 agent_id: 4242,
                 runtime: :foreground
               })

      assert [%Execution{id: ^id}] = EvoDash.NodeContext.list_processes(node())
      refute_received {:rpc_called, _, _, _, _}

      assert {:ok, %Execution{id: ^id}} = EvoDash.NodeContext.get_process(node(), id)
      refute_received {:rpc_called, _, _, _, _}

      # A tracked record with no OS handle: the manager's own `:no_handle`.
      assert EvoDash.NodeContext.process_stats(node(), id) == {:error, :not_running}
      refute_received {:rpc_called, _, _, _, _}

      assert EvoDash.NodeContext.process_control(node(), id, :pause, "operator pause") ==
               {:error, :no_handle}

      refute_received {:rpc_called, _, _, _, _}
    end

    test "control reaches the manager's real control layer (invalid signal, no OS work)" do
      assert {:ok, id} =
               EvoGit.ProcessManager.track(:tool_call, %{
                 command: "echo local",
                 tool: "bash",
                 runtime: :foreground
               })

      # A `:posix` handle with a pid that is never signalled: an unnormalizable
      # signal is rejected by `EvoGit.ProcessManager.Control` BEFORE any OS
      # call, so this proves the manager resolved the record + handle without
      # touching a live process.
      :ok = EvoGit.ProcessManager.attach(id, EvoGit.ProcessManager.Handle.posix(999_999_999))

      assert EvoDash.NodeContext.process_control(node(), id, {:signal, :bogus}, "bad signal") ==
               {:error, :invalid_signal}

      refute_received {:rpc_called, _, _, _, _}

      # Unchanged record: nothing was signalled and the log stays empty.
      assert {:ok, %Execution{status: :running, control_log: []}} =
               EvoDash.NodeContext.get_process(node(), id)

      # A terminal record is the idempotent `:ok` path — no signal either.
      :ok = EvoGit.ProcessManager.finish(id, :completed)
      assert EvoDash.NodeContext.process_control(node(), id, :kill, "operator kill") == :ok
      refute_received {:rpc_called, _, _, _, _}
    end

    test "an unknown action is answered locally and never forwarded" do
      assert {:ok, id} =
               EvoGit.ProcessManager.track(:tool_call, %{command: "echo local", tool: "bash"})

      assert EvoDash.NodeContext.process_control(node(), id, :bogus, "bad action") ==
               {:error, {:unknown_action, :bogus}}

      assert EvoDash.NodeContext.process_control(node(), id, "pause", "bad action") ==
               {:error, {:unknown_action, "pause"}}

      refute_received {:rpc_called, _, _, _, _}

      # Still answerable, so no control action was applied.
      assert {:ok, %Execution{control_log: []}} = EvoDash.NodeContext.get_process(node(), id)
    end

    test "a dead/absent manager degrades without raising" do
      Process.put(
        :evogit_process_manager_server,
        :"no_such_manager_#{System.unique_integer([:positive])}"
      )

      assert EvoDash.NodeContext.list_processes(node()) == []

      assert EvoDash.NodeContext.get_process(node(), "proc-1") ==
               {:error, :process_manager_unavailable}

      assert EvoDash.NodeContext.process_stats(node(), "proc-1") ==
               {:error, :process_manager_unavailable}

      assert EvoDash.NodeContext.process_control(node(), "proc-1", :kill, "operator kill") ==
               {:error, :process_manager_unavailable}

      # The action whitelist runs BEFORE the manager is consulted, so an
      # unknown action keeps its own answer even with no manager.
      assert EvoDash.NodeContext.process_control(node(), "proc-1", :bogus, "bad action") ==
               {:error, {:unknown_action, :bogus}}

      refute_received {:rpc_called, _, _, _, _}
    end
  end

  describe "managed processes — a remote viewed node routes through the RPC" do
    @remote_node :"remote@127.0.0.1"

    setup do
      test_pid = self()
      Process.put(:node_context_process_rpc, &send(test_pid, {:rpc_called, &1, &2, &3, &4}))
      on_exit(fn -> Process.delete(:node_context_process_rpc) end)
      :ok
    end

    test "list_processes/2 delegates and unwraps the envelope" do
      Process.put(:node_context_process_rpc, fn node, mod, fun, args ->
        send(self(), {:rpc_called, node, mod, fun, args})
        {:ok, [:remote_marker]}
      end)

      assert EvoDash.NodeContext.list_processes(@remote_node, agent_id: 4242) ==
               [:remote_marker]

      assert_received {:rpc_called, @remote_node, EvoGit.AgentScheduler.RemoteAPI,
                       :list_processes, [[agent_id: 4242]]}

      # `{:error, reason}` and a non-list payload both degrade to `[]`.
      Process.put(:node_context_process_rpc, fn _n, _m, _f, _a -> {:error, :nodedown} end)
      assert EvoDash.NodeContext.list_processes(@remote_node) == []

      Process.put(:node_context_process_rpc, fn _n, _m, _f, _a -> {:ok, %{not: :a_list}} end)
      assert EvoDash.NodeContext.list_processes(@remote_node) == []
    end

    test "get_process/2 and process_stats/2 delegate and unwrap" do
      parent = self()

      Process.put(:node_context_process_rpc, fn node, mod, fun, args ->
        send(parent, {:rpc_called, node, mod, fun, args})

        case fun do
          :get_process -> {:ok, {:ok, :remote_execution}}
          :process_stats -> {:ok, {:error, :not_running}}
        end
      end)

      assert EvoDash.NodeContext.get_process(@remote_node, "proc-7") == {:ok, :remote_execution}

      assert_received {:rpc_called, @remote_node, EvoGit.AgentScheduler.RemoteAPI, :get_process,
                       ["proc-7"]}

      assert EvoDash.NodeContext.process_stats(@remote_node, "proc-7") ==
               {:error, :not_running}

      assert_received {:rpc_called, @remote_node, EvoGit.AgentScheduler.RemoteAPI, :process_stats,
                       ["proc-7"]}

      # The core's own error unwraps bare; a transport failure passes through.
      Process.put(:node_context_process_rpc, fn _n, _m, _f, _a -> {:ok, {:error, :not_found}} end)

      assert EvoDash.NodeContext.get_process(@remote_node, "proc-7") == {:error, :not_found}

      Process.put(:node_context_process_rpc, fn _n, _m, _f, _a -> {:error, :timeout} end)

      assert EvoDash.NodeContext.process_stats(@remote_node, "proc-7") == {:error, :timeout}

      # Non-binary ids never reach the transport.
      Process.put(:node_context_process_rpc, fn _n, _m, _f, _a ->
        send(parent, :rpc_called)
        {:ok, :should_not_happen}
      end)

      assert EvoDash.NodeContext.get_process(@remote_node, 7) == {:error, :not_found}
      assert EvoDash.NodeContext.process_stats(@remote_node, 7) == {:error, :not_found}
      refute_received :rpc_called
    end

    test "process_control/4 delegates the action verbatim and unwraps" do
      parent = self()

      Process.put(:node_context_process_rpc, fn node, mod, fun, args ->
        send(parent, {:rpc_called, node, mod, fun, args})
        {:ok, :ok}
      end)

      assert EvoDash.NodeContext.process_control(
               @remote_node,
               "proc-7",
               {:signal, "TERM"},
               "operator reason"
             ) == :ok

      assert_received {:rpc_called, @remote_node, EvoGit.AgentScheduler.RemoteAPI,
                       :process_control, ["proc-7", {:signal, "TERM"}, "operator reason"]}

      Process.put(:node_context_process_rpc, fn _n, _m, _f, _a -> {:ok, {:error, :terminal}} end)

      assert EvoDash.NodeContext.process_control(@remote_node, "proc-7", :kill, "reason") ==
               {:error, :terminal}

      Process.put(:node_context_process_rpc, fn _n, _m, _f, _a -> {:error, :nodedown} end)

      assert EvoDash.NodeContext.process_control(@remote_node, "proc-7", :pause, "reason") ==
               {:error, :nodedown}

      Process.put(:node_context_process_rpc, fn _n, _m, _f, _a ->
        send(parent, :rpc_called)
        {:ok, :should_not_happen}
      end)

      assert EvoDash.NodeContext.process_control(@remote_node, 7, :pause, "reason") ==
               {:error, :not_found}

      refute_received :rpc_called
    end
  end
end

# `async: true` — this module writes the config dir (agents.toml, tools/), and
# that write is isolated PER PROCESS by the `:config_dir_fun` seam
# (`EvoDash.Test.ConfigDir.isolate!/1`), never by the BEAM-global
# `XDG_CONFIG_HOME`. Each test gets its own unique `<temp dir>/genesis` — the
# same layout the old env-var redirect produced — so no assertion changes and no
# process-global state is mutated.
defmodule EvoDash.NodeContextConfigTest do
  use EvoDashWeb.ConnCase, async: true

  import ExUnit.CaptureLog

  # Writes a MINIMAL valid custom-tool source module (a `.ex` file exporting
  # `schema/0`, `read_only?/0` and `execute/2`) into the ISOLATED temp
  # `<config_dir>/tools/` dir — mirrors the fixture shape used by evo_git's
  # custom_tools_rpc_test.exs. Returns `{module, path}`.
  defp custom_tool_fixture!(tool_name) do
    module =
      Module.concat([:"NodeContextCustomToolFixture#{System.unique_integer([:positive])}"])

    dir = EvoGit.CustomTools.tools_dir()
    File.mkdir_p!(dir)
    path = Path.join(dir, "#{tool_name}.ex")

    File.write!(path, """
    defmodule #{inspect(module)} do
      @behaviour EvoGit.CustomTools.Tool

      @impl true
      def schema do
        ReqLLM.tool(
          name: #{inspect(tool_name)},
          description: "node_context_test custom-tool fixture",
          parameter_schema: %{"type" => "object", "properties" => %{}},
          callback: fn _ -> {:ok, nil} end
        )
      end

      @impl true
      def read_only?, do: true

      @impl true
      def execute(_args, _ctx), do: "custom-tool-ran"
    end
    """)

    {module, path}
  end

  describe "custom-agents RPC delegates (local node, real paths)" do
    # The local path reads/writes the REAL agents.toml at
    # EvoGit.Config.config_dir(). Never touch the user's real file: give this
    # test its OWN `<temp dir>/genesis` through the per-process
    # `:config_dir_fun` seam (`<temp dir>/genesis`, the same layout a platform
    # config dir has).
    # A fresh dir has no agents.toml, which is exactly the hermetic "no
    # definition yet" state.
    #
    # No cache invalidation is needed: the `:persistent_term` config/agent
    # caches are keyed by FILE PATH and every test resolves a unique path.
    setup do
      dir = EvoDash.Test.ConfigDir.isolate!("evogit_node_context_config")
      on_exit(fn -> File.rm_rf!(dir) end)
      :ok
    end

    test "list_custom_agents/1 returns an empty result when no agents.toml exists" do
      assert EvoDash.NodeContext.list_custom_agents(node()) ==
               {:ok, %{agents: [], model_selection_script: nil, script_status: :ok}}
    end

    test "save_custom_agent/2 round-trips a definition through list_custom_agents/1" do
      assert {:ok, agent} =
               EvoDash.NodeContext.save_custom_agent(node(), %{name: "Reviewer", prompt: "p"})

      assert agent.id == "reviewer"

      assert {:ok, %{agents: [%{name: "Reviewer"}]}} =
               EvoDash.NodeContext.list_custom_agents(node())
    end

    test "save_custom_agent/2 rejects a duplicate auto-generated id" do
      assert {:ok, _first} =
               EvoDash.NodeContext.save_custom_agent(node(), %{name: "Reviewer", prompt: "p1"})

      assert {:error, :duplicate_id} =
               EvoDash.NodeContext.save_custom_agent(node(), %{name: "Reviewer", prompt: "p2"})
    end

    test "save_custom_agent/2 rejects invalid input with the core contract error" do
      # Core's EvoGit.CustomAgents.save/1 validates name before prompt, so an
      # empty map yields :missing_name (not :invalid_name).
      assert {:error, :missing_name} = EvoDash.NodeContext.save_custom_agent(node(), %{})
    end

    test "delete_custom_agent/2 removes an agent and reports :not_found for missing ids" do
      assert {:error, :not_found} = EvoDash.NodeContext.delete_custom_agent(node(), "missing")

      assert {:ok, agent} =
               EvoDash.NodeContext.save_custom_agent(node(), %{name: "Deletable", prompt: "p"})

      assert :ok = EvoDash.NodeContext.delete_custom_agent(node(), agent.id)

      assert {:ok, %{agents: []}} = EvoDash.NodeContext.list_custom_agents(node())
    end

    test "save_model_selection_script/2 round-trips, reports broken scripts via script_status, and empty clears" do
      script = ~s(if agent.depth == 0, do: "fast", else: nil)

      assert :ok = EvoDash.NodeContext.save_model_selection_script(node(), script)

      assert {:ok, %{model_selection_script: ^script, script_status: :ok}} =
               EvoDash.NodeContext.list_custom_agents(node())

      # Core's save_model_selection_script/1 only writes the file — it does
      # NOT compile. A broken script saves :ok and surfaces as a compile error
      # in the next list's script_status.
      assert :ok = EvoDash.NodeContext.save_model_selection_script(node(), "this is not elixir (")

      assert {:ok, %{script_status: {:error, {:compile_error, _message}}}} =
               EvoDash.NodeContext.list_custom_agents(node())

      # An empty script removes the key (core contract).
      assert :ok = EvoDash.NodeContext.save_model_selection_script(node(), "")

      assert {:ok, %{model_selection_script: nil, script_status: :ok}} =
               EvoDash.NodeContext.list_custom_agents(node())
    end

    test "reload_custom_agents/1 returns :ok and preserves stored agents" do
      assert {:ok, _agent} =
               EvoDash.NodeContext.save_custom_agent(node(), %{name: "Keeper", prompt: "p"})

      assert :ok = EvoDash.NodeContext.reload_custom_agents(node())

      assert {:ok, %{agents: [%{name: "Keeper"}]}} =
               EvoDash.NodeContext.list_custom_agents(node())
    end
  end

  describe "custom_tools_status/1 (node-first custom-tools RPC)" do
    # The local path reads the VIEWED node's own `<config_dir>/tools/`
    # directory. Never touch the user's real config: give this test its OWN
    # `<temp dir>/genesis` through the per-process `:config_dir_fun` seam (the
    # same layout a platform config dir has, so evo_git's
    # custom_tools_rpc_test.exs behaviour is mirrored). A fresh dir has no
    # `tools/` subdirectory, so the hermetic status is the empty shape.
    #
    # The loader's `:persistent_term` cache is keyed by the tools DIRECTORY and
    # every test resolves a unique one, so a cached entry can never leak in
    # from — or into — another test: no reload is needed around the setup.
    setup do
      dir = EvoDash.Test.ConfigDir.isolate!("evogit_node_context_tools")
      on_exit(fn -> File.rm_rf!(dir) end)
      :ok
    end

    test "returns the empty status map shape for a hermetic tools dir" do
      status = EvoDash.NodeContext.custom_tools_status(node())

      # Both documented atom keys, both lists; nothing configured → empty.
      assert %{ok: ok, errors: errors} = status
      assert is_list(ok) and is_list(errors)
      assert status == %{ok: [], errors: []}
    end

    test "is a verbatim pass-through of EvoGit.RemoteNode.custom_tools_status/1" do
      # There is NO local/remote branch inside NodeContext — the wrapper
      # delegates verbatim (identity: no re-keying, no degradation).
      assert EvoDash.NodeContext.custom_tools_status(node()) ==
               EvoGit.RemoteNode.custom_tools_status(node())
    end

    test "surfaces a populated tools status verbatim (documented entry keys)" do
      tool_name = "node_context_ct_#{System.unique_integer([:positive])}"
      {module, path} = custom_tool_fixture!(tool_name)
      EvoGit.CustomTools.reload()

      status = EvoDash.NodeContext.custom_tools_status(node())

      assert %{ok: [entry], errors: []} = status
      assert entry == %{name: tool_name, file: path, module: module, read_only?: true}

      # Verbatim: byte-identical to the core wrapper's map (no transformation).
      assert status == EvoGit.RemoteNode.custom_tools_status(node())
    end

    test "on an unreachable remote node surfaces the RPC failure, never an empty map" do
      # No distribution to that node in the test env, so :erpc.call fails fast
      # (:noconnection against a non-distributed local node) and the `defnode`
      # wrapper must pass the error tuple through — deliberately NOT swallowed
      # into `%{ok: [], errors: []}`, which would hide a real backend/RPC
      # problem.
      # Wrapped in CaptureLog: on a distributed local BEAM the real
      # distribution/net-kernel code path can emit Logger lines (e.g. "No
      # distribution cookie configured") from global processes; ExUnit's
      # window-based `capture_log: true` misses those emitted at the test
      # boundary, so capture them here to keep the console clean.
      {result, _log} =
        with_log(fn ->
          EvoDash.NodeContext.custom_tools_status(:"nonexistent-node@nowhere")
        end)

      assert match?({:error, _}, result)
      refute result == %{ok: [], errors: []}
    end
  end
end

# `async: false` — the forcing global is the `EvoGit.VCT` mount table: a
# BEAM-global singleton GenServer (`EvoGit.VCT`, started by `EvoGit.Application`)
# whose whole mount list is persisted on the run-wide test store
# (`vct_mounts`) and is a read cache of it. Other concurrently running modules
# observe and mutate that SAME table (the evo_git tool/command-shell suites
# mount their own rows), so these tests must not run in the async phase; they
# assert only their own per-test-unique mounts and never clear the table.
defmodule EvoDash.NodeContextVctTest do
  use EvoDashWeb.ConnCase, async: false

  import ExUnit.CaptureLog

  # A node atom that is never connected: `:erpc.call/5` against it fails fast in
  # the test env (the local BEAM is not distributed), which is exactly the
  # remote transport-failure path `NodeContext` must degrade through.
  @remote_node :"genesis_remote@127.0.0.1"

  # Mounts ONE unique absolute path (unique basename => unique VCT point, so it
  # can never collide with another suite's row) and forgets it on teardown.
  # The mount table caps at `EvoGit.VCT.max_projects/0`, so keeping every test
  # at ≤3 mounts and forgetting them is what keeps this module a good citizen.
  defp mount_unique!(name_prefix) do
    unique = System.unique_integer([:positive])
    path = "/tmp/node_context_vct_#{name_prefix}_#{unique}"
    name = "NodeContext #{name_prefix} #{unique}"
    assert {:ok, %EvoGit.VCT.Mount{} = mount} = EvoGit.VCT.mount(path, name: name)
    on_exit(fn -> EvoGit.VCT.forget(mount.point) end)
    mount
  end

  describe "projects/1 (VCT project-registry delegate)" do
    test "includes a newly mounted local project with its point/path/name" do
      mount = mount_unique!("projects")

      projects = EvoDash.NodeContext.projects(node())
      assert Enum.all?(projects, &match?(%EvoGit.VCT.Mount{}, &1))

      found = Enum.find(projects, &(&1.point == mount.point))
      assert %EvoGit.VCT.Mount{} = found
      assert found.path == mount.path
      assert found.name == mount.name
    end

    test "degrades to [] on a remote node" do
      # The core turns a failed remote RPC (and any non-list reply) into `[]`,
      # so the dashboard never crashes or blocks on the project list.
      {result, _log} = with_log(fn -> EvoDash.NodeContext.projects(@remote_node) end)
      assert result == []
    end
  end

  describe "mount_project/3 (VCT project-registry delegate)" do
    test "mounts a unique absolute path and re-mounting keeps the same point" do
      unique = System.unique_integer([:positive])
      path = "/tmp/node_context_vct_mount_#{unique}"
      name = "NodeContext mount #{unique}"

      assert {:ok, %EvoGit.VCT.Mount{} = mount} =
               EvoDash.NodeContext.mount_project(node(), path, name)

      on_exit(fn -> EvoGit.VCT.forget(mount.point) end)
      assert mount.path == path
      assert mount.name == name

      # Mounting is idempotent: the same OS path refreshes the mount and keeps
      # its point instead of accumulating a second row.
      assert {:ok, %EvoGit.VCT.Mount{point: same_point}} =
               EvoDash.NodeContext.mount_project(node(), path, name)

      assert same_point == mount.point
    end

    test "rejects a relative path with the core contract error" do
      assert EvoDash.NodeContext.mount_project(node(), "relative/repo", "rel") ==
               {:error, :relative_path}
    end

    test "surfaces a remote transport failure as an error tuple" do
      {result, _log} =
        with_log(fn -> EvoDash.NodeContext.mount_project(@remote_node, "/tmp/x", "x") end)

      assert {:error, {_kind, _reason}} = result
    end
  end

  describe "forget_project/2 (VCT project-registry delegate)" do
    test "forgets a local mount by point, then reports :not_found" do
      mount = mount_unique!("forget")

      assert :ok = EvoDash.NodeContext.forget_project(node(), mount.point)
      refute Enum.any?(EvoGit.VCT.projects(), &(&1.point == mount.point))

      assert EvoDash.NodeContext.forget_project(node(), mount.point) == {:error, :not_found}
    end

    test "distinguishes an unknown local point from a non-local VCT authority" do
      unique = System.unique_integer([:positive])

      assert EvoDash.NodeContext.forget_project(
               node(),
               "vct:///projects/does-not-exist-#{unique}"
             ) == {:error, :not_found}

      # A non-empty authority is reserved for a future remote form and is
      # rejected as a bad point, never treated as a local mount.
      assert EvoDash.NodeContext.forget_project(node(), "vct://host/x") ==
               {:error, :invalid_point}
    end

    test "surfaces a remote transport failure as an error tuple" do
      {result, _log} =
        with_log(fn -> EvoDash.NodeContext.forget_project(@remote_node, "/tmp/x") end)

      assert {:error, {_kind, _reason}} = result
    end
  end
end

# The tool-free role the interactive-session passthroughs start. `available_tools/0`
# is EMPTY and `session_mode/0` is `:interactive` (the Assistant shape): the
# scripted `:agent_exchange_llm_call` seam answers in plain text, so every
# exchange yields and no tool schema and no real LLM is ever involved.
# Defined at the TOP LEVEL of the file (not nested in the test module) so it is
# loaded before the module that starts sessions with it.
defmodule EvoDash.NodeContextSessionTest.StubAgent do
  use EvoGit.Agent

  @doc "The role's fixed system prompt."
  def system_prompt, do: "You are the NodeContext session test role."

  @doc "No tools: the scripted seam serves every model call."
  def available_tools, do: []

  @doc "Opt into interactive semantics (a tool-free reply parks the session)."
  def session_mode, do: :interactive
end

# `async: false` — the forcing GLOBALS are the interactive-session runtime:
#   * the app-env engine seam `:agent_exchange_llm_call`, read at CALL time by
#     every session's exchange worker, so a concurrently running module's agent
#     would observe this module's scripted replies;
#   * the app-global `EvoGit.AgentScheduler` GenServer, whose `model_profiles` /
#     `llm_model` are set for a resolvable selection and restored in `on_exit`;
#   * its BEAM-global ETS rows (`:evogit_sched_meta` / `:evogit_agent_summary`)
#     plus the `EvoGit.TaskRegistry` casts and `EvoGit.PubSub` broadcasts a
#     yield → close cycle emits.
# Every fixture is per-test unique (the task id is allocated here, the agent id
# by the scheduler), each started session is closed in `on_exit`, and the seam
# key is DELETED on exit when it was originally unset, so the production path
# stays byte-identical.
defmodule EvoDash.NodeContextSessionTest do
  use EvoDashWeb.ConnCase, async: false

  import ExUnit.CaptureLog

  alias EvoGit.Agent.Result

  # Every wait budget in one place. The awaited events are REAL scheduling
  # events (a session yield, a resumed exchange, a close), and the shared host's
  # scheduling swings several-fold under parallel load, so the budget absorbs
  # that latency — the wait still fails (never passes silently) when the event
  # never happens.
  @wait_budget_ms 30_000

  # The scheduler is ONE app-global GenServer shared with every other suite in
  # the run; `get_config`/`update_config` are ordinary `GenServer.call`s whose
  # default budget (5 s) the shared host's load can exceed. Pass the same
  # explicit budget the waits use — a bounded call, never a silent pass.
  @config_call_timeout 30_000

  # The scheduler reconfiguration is a ONE-TIME payment for the whole module:
  # the FIRST `update_config` that installs a model profile also initializes the
  # lazily loaded model catalog / LLM pool state (seconds on this shared host),
  # while every later call is sub-millisecond. It therefore lives in
  # `setup_all` — the tests only swap the per-test engine seam.
  #
  # A resolvable model profile is what `start_session/1` needs: it resolves a
  # concrete selection before an agent can be registered. This is the
  # established no-real-LLM idiom — the seam below serves every model call.
  setup_all do
    original_profiles =
      GenServer.call(
        EvoGit.AgentScheduler,
        {:get_config, :model_profiles},
        @config_call_timeout
      )

    original_model =
      GenServer.call(EvoGit.AgentScheduler, {:get_config, :llm_model}, @config_call_timeout)

    assert :ok =
             GenServer.call(
               EvoGit.AgentScheduler,
               {:update_config,
                [
                  model_profiles: [%{id: "default", model: "test:model", concurrency: 1}],
                  llm_model: "test:model"
                ]},
               @config_call_timeout
             )

    on_exit(fn -> restore_scheduler_config(original_profiles, original_model) end)

    :ok
  end

  setup do
    old_llm_call = Application.get_env(:evo_git, :agent_exchange_llm_call)
    on_exit(fn -> restore_env(:agent_exchange_llm_call, old_llm_call) end)
    :ok
  end

  describe "start_session/2 (interactive-session passthrough, local node)" do
    test "starts a repo-less Assistant session and close/await_close finish it" do
      counter = script_yields(["first yield"])
      task_id = unique_task_id()
      agent_id = start_session!(task_id)
      assert is_integer(agent_id) and agent_id > 0

      # The scheduler reports it as idle: ONE exchange paid, then parked.
      entry = await_idle(agent_id)
      assert %{agent_id: ^agent_id, task_id: ^task_id, mode: :interactive} = entry
      assert is_pid(entry.session_pid) and Process.alive?(entry.session_pid)
      assert :counters.get(counter, 1) == 1

      # The `reason \\ :normal` default form is the documented close route.
      assert :ok = EvoDash.NodeContext.close_session(node(), agent_id)

      assert {:ok, %Result{result: "first yield"}} =
               EvoDash.NodeContext.await_close(node(), agent_id, @wait_budget_ms)

      await_idle_gone(agent_id)
      # Closing finalizes the last yielded text — it is NOT another exchange.
      assert :counters.get(counter, 1) == 1
    end

    test "passes the core's start refusal through verbatim (never re-wrapped)" do
      # (a) A caller error: no session opts at all, answered by `SessionOpts`
      # itself (and its own wrap, which is the ONLY nesting the core adds).
      assert EvoDash.NodeContext.start_session(node(), []) ==
               {:error,
                {:start_session_failed, {:invalid_session_opts, {:invalid_agent_module, nil}}}}

      # (b) Interactive sessions are root-only in v1.
      assert {:error, {:start_session_failed, {:interactive_root_only, message}}} =
               EvoDash.NodeContext.start_session(node(),
                 agent_module: EvoDash.NodeContextSessionTest.StubAgent,
                 objective: "node context session objective",
                 depth: 1
               )

      assert message =~ "root-only"

      # A non-list/non-spec argument keeps the core's own reason too.
      assert EvoDash.NodeContext.start_session(node(), :not_a_spec) ==
               {:error,
                {:start_session_failed,
                 {:invalid_session_opts, {:not_a_session_spec, :not_a_spec}}}}

      # (c) An empty profile list is the scheduler's `:llm_not_configured`
      # admission refusal — the reason arrives unchanged.
      # The module-wide profile is restored in `on_exit` so this refusal cannot
      # disarm the other tests of this module.
      module_profiles =
        GenServer.call(
          EvoGit.AgentScheduler,
          {:get_config, :model_profiles},
          @config_call_timeout
        )

      on_exit(fn ->
        GenServer.call(
          EvoGit.AgentScheduler,
          {:update_config, [model_profiles: module_profiles]},
          @config_call_timeout
        )
      end)

      assert :ok =
               GenServer.call(
                 EvoGit.AgentScheduler,
                 {:update_config, [model_profiles: []]},
                 @config_call_timeout
               )

      task_id = unique_task_id()

      # The scheduler logs the refusal from ITS OWN process, so capture the line
      # with the triggering call instead of relying on the window-based
      # `capture_log: true`.
      {result, _log} =
        with_log(fn ->
          EvoDash.NodeContext.start_session(node(), session_opts(task_id))
        end)

      assert result == {:error, {:start_session_failed, :llm_not_configured}}

      # Nothing was registered, so nothing can be parked at `:awaiting_input`.
      refute idle_for_task?(task_id)
    end
  end

  describe "send_session_message/4 (interactive-session passthrough)" do
    test "delivers a binary and a message map to a LIVE session" do
      counter = script_yields(["one", "two", "three"])
      agent_id = start_session!(unique_task_id())
      first = await_idle(agent_id)

      # Binary form, 3-arity (policy defaults to `:queue`).
      assert :ok = EvoDash.NodeContext.send_session_message(node(), agent_id, "second message")
      wait_until(fn -> :counters.get(counter, 1) >= 2 and idle?(agent_id) end, @wait_budget_ms)

      # The resumed exchange runs on the SAME session (one agent id, one
      # worktree, one context) — only the message is appended.
      assert %{session_pid: resumed_pid} = await_idle(agent_id)
      assert resumed_pid == first.session_pid

      # Canonical message map (`EvoGit.Attachments.message/0`), explicit policy.
      assert :ok =
               EvoDash.NodeContext.send_session_message(
                 node(),
                 agent_id,
                 %{text: "third message", attachments: []},
                 :queue
               )

      wait_until(fn -> :counters.get(counter, 1) >= 3 and idle?(agent_id) end, @wait_budget_ms)

      assert :ok = EvoDash.NodeContext.close_session(node(), agent_id, :normal)

      assert {:ok, %Result{result: "three"}} =
               EvoDash.NodeContext.await_close(node(), agent_id, @wait_budget_ms)

      await_idle_gone(agent_id)
    end

    test "an unknown or already-finished target answers the documented envelope" do
      # Provably unknown agent id (no session can ever be registered for it).
      unknown = 9_000_000_000

      assert EvoDash.NodeContext.send_session_message(node(), unknown, "hello") ==
               {:error, {:session, :not_found}}

      assert EvoDash.NodeContext.close_session(node(), unknown, :normal) ==
               {:error, {:session, :not_found}}

      assert EvoDash.NodeContext.await_close(node(), unknown, 1_000) == {:error, :not_found}

      # A real session that has FINISHED: once its process is gone the same
      # documented `:not_found` envelope applies (the registry entry dies with
      # the session, so no call can be answered).
      script_yields(["finished"])
      agent_id = start_session!(unique_task_id())
      entry = await_idle(agent_id)
      assert :ok = EvoDash.NodeContext.close_session(node(), agent_id, :normal)

      assert {:ok, %Result{}} =
               EvoDash.NodeContext.await_close(node(), agent_id, @wait_budget_ms)

      wait_until(fn -> not Process.alive?(entry.session_pid) end, @wait_budget_ms)

      assert EvoDash.NodeContext.send_session_message(node(), agent_id, "after the end") ==
               {:error, {:session, :not_found}}

      assert EvoDash.NodeContext.close_session(node(), agent_id, :normal) ==
               {:error, {:session, :not_found}}
    end
  end

  describe "await_close/3 and list_awaiting_input/1" do
    test "an expired wait budget answers :timeout and the session keeps running" do
      counter = script_yields(["only yield"])
      agent_id = start_session!(unique_task_id())
      entry = await_idle(agent_id)

      # Nothing closes the session, so the bounded wait MUST expire.
      assert EvoDash.NodeContext.await_close(node(), agent_id, 50) == {:error, :timeout}

      # The expired wait is observation only: the session is still live, still
      # idle, and answering.
      assert Process.alive?(entry.session_pid)
      assert idle?(agent_id)
      assert :counters.get(counter, 1) == 1

      assert :ok = EvoDash.NodeContext.close_session(node(), agent_id)

      assert {:ok, %Result{result: "only yield"}} =
               EvoDash.NodeContext.await_close(node(), agent_id, @wait_budget_ms)
    end

    test "lists the parked session, then degrades to [] when the node cannot be asked" do
      task_id = unique_task_id()
      script_yields(["parked"])
      agent_id = start_session!(task_id)

      # The start is asynchronous, so park on the session's OWN idle signal
      # before reading the list. The local answer is always a list, and this
      # session is in it while it is parked at `:awaiting_input`.
      assert %{agent_id: ^agent_id, task_id: ^task_id} = await_idle(agent_id)
      assert is_list(EvoDash.NodeContext.list_awaiting_input(node()))

      assert :ok = EvoDash.NodeContext.close_session(node(), agent_id)

      assert {:ok, %Result{}} =
               EvoDash.NodeContext.await_close(node(), agent_id, @wait_budget_ms)

      # Degraded answer: an unreachable node is collapsed to `[]` (never raises,
      # never returns a non-list), exactly like the other list helpers here.
      # Wrapped in `with_log/2`: the real distribution/net-kernel code path can
      # emit Logger lines from global processes at the test boundary.
      {result, _log} =
        with_log(fn ->
          EvoDash.NodeContext.list_awaiting_input(:"nonexistent-node@nowhere")
        end)

      assert result == []
    end
  end

  describe "push-only agent-delta streaming (subscription + watcher registration)" do
    test "subscribe_agent_deltas/1 delivers to the caller and unsubscribe stops it" do
      # A provably non-live id: no session can broadcast on this topic, so every
      # message the test receives is the one it published itself.
      agent_id = 9_000_000_000 + System.unique_integer([:positive])
      topic = "agent:#{agent_id}"

      on_exit(fn -> EvoDash.NodeContext.unsubscribe_agent_deltas(agent_id) end)

      assert :ok = EvoDash.NodeContext.subscribe_agent_deltas(agent_id)

      # Idempotent per process: the core memoizes the topic, so a re-attach must
      # not buy a SECOND subscription (which would deliver every delta twice).
      assert :ok = EvoDash.NodeContext.subscribe_agent_deltas(agent_id)

      first = {:agent_delta, agent_id, 1, [{:text, "hi"}]}
      assert :ok = Phoenix.PubSub.broadcast(EvoGit.PubSub, topic, first)
      assert_receive ^first, @wait_budget_ms

      assert :ok = EvoDash.NodeContext.unsubscribe_agent_deltas(agent_id)

      second = {:agent_delta, agent_id, 2, [{:text, "after unsubscribe"}]}
      assert :ok = Phoenix.PubSub.broadcast(EvoGit.PubSub, topic, second)
      refute_receive ^second, 50

      # Total: unsubscribing again (or for an id never watched) is still `:ok`.
      assert :ok = EvoDash.NodeContext.unsubscribe_agent_deltas(agent_id)
    end

    test "register_agent_watcher/3 refuses an unknown agent without raising" do
      agent_id = 9_000_000_000 + System.unique_integer([:positive])
      watcher = self()

      assert {:error, {:not_found, _reason}} =
               EvoDash.NodeContext.register_agent_watcher(node(), agent_id, watcher)

      # A refusal leaves NO watcher residue: nothing was registered anywhere, and
      # the unregistration reports the same `{:not_found, :session_not_found}`
      # refusal (the core's idempotent `:ok` covers a LIVE session with a missing
      # watcher entry, which the parked-session test below pins).
      assert {:error, {:not_found, :session_not_found}} =
               EvoDash.NodeContext.unregister_agent_watcher(node(), agent_id, watcher)
    end

    test "register_agent_watcher/3 attaches to a parked session, unregister is idempotent" do
      script_yields(["watched"])
      agent_id = start_session!(unique_task_id())
      on_exit(fn -> EvoDash.NodeContext.unsubscribe_agent_deltas(agent_id) end)

      # The caller subscribes on ITS node first, then registers — the core's
      # documented ordering, so no delta can fall between the two.
      assert :ok = EvoDash.NodeContext.subscribe_agent_deltas(agent_id)
      assert %{agent_id: ^agent_id} = await_idle(agent_id)

      assert {:ok, %EvoGit.Agent.Stream.Snapshot{} = snapshot, seq} =
               EvoDash.NodeContext.register_agent_watcher(node(), agent_id, self())

      assert snapshot.agent_id == agent_id
      assert is_integer(seq)
      assert seq >= 0
      assert snapshot.seq == seq
      assert is_list(snapshot.messages)
      assert snapshot.messages != []
      assert snapshot.phase == :awaiting_input

      assert :ok = EvoDash.NodeContext.unregister_agent_watcher(node(), agent_id, self())
      # Idempotent: the watcher entry is already gone, which is not a failure.
      assert :ok = EvoDash.NodeContext.unregister_agent_watcher(node(), agent_id, self())

      assert :ok = EvoDash.NodeContext.close_session(node(), agent_id)

      assert {:ok, %Result{result: "watched"}} =
               EvoDash.NodeContext.await_close(node(), agent_id, @wait_budget_ms)
    end

    test "watch_agent_snapshot/2 reads a parked session and refuses an unknown id" do
      script_yields(["snapshotted"])
      agent_id = start_session!(unique_task_id())
      on_exit(fn -> EvoDash.NodeContext.unsubscribe_agent_deltas(agent_id) end)
      assert %{agent_id: ^agent_id} = await_idle(agent_id)

      assert {:ok, %EvoGit.Agent.Stream.Snapshot{} = snapshot, seq} =
               EvoDash.NodeContext.watch_agent_snapshot(node(), agent_id)

      assert snapshot.agent_id == agent_id
      assert snapshot.phase == :awaiting_input
      assert is_integer(seq)
      assert seq >= 0
      assert is_list(snapshot.messages)

      # The resync path registers/subscribes NOTHING: a delta published on the
      # topic is not delivered to this test process.
      delta = {:agent_delta, agent_id, seq + 1, [{:text, "not a subscription"}]}
      assert :ok = Phoenix.PubSub.broadcast(EvoGit.PubSub, "agent:#{agent_id}", delta)
      refute_receive ^delta, 50

      assert :ok = EvoDash.NodeContext.close_session(node(), agent_id)

      assert {:ok, %Result{}} =
               EvoDash.NodeContext.await_close(node(), agent_id, @wait_budget_ms)

      # An id with no session answers the core's documented refusal.
      unknown = 9_000_000_000 + System.unique_integer([:positive])

      assert {:error, {:not_found, _reason}} =
               EvoDash.NodeContext.watch_agent_snapshot(node(), unknown)
    end
  end

  # --- fixtures -------------------------------------------------------------

  defp unique_task_id do
    "node_ctx_session_#{System.unique_integer([:positive])}"
  end

  # A valid REPO-LESS Assistant spec (no `:path`): no worktree, no phylo node.
  defp session_opts(task_id) do
    [
      agent_module: EvoDash.NodeContextSessionTest.StubAgent,
      objective: "node context session objective",
      repo_less: true,
      session_mode: :interactive,
      task_id: task_id
    ]
  end

  # Starts a session through the passthrough under test and registers a
  # best-effort teardown, so a failing assertion can never leave an idle session
  # (or its sched-meta rows) behind for another test.
  defp start_session!(task_id) do
    assert {:ok, agent_id} = EvoDash.NodeContext.start_session(node(), session_opts(task_id))
    on_exit(fn -> force_kill!(task_id) end)
    agent_id
  end

  defp force_kill!(task_id) do
    # Guarded because a scheduler restart mid-teardown must never mask a real
    # test failure; the tests close their own sessions, so this only fires when
    # an assertion failed first.
    EvoGit.AgentScheduler.force_kill_task_agents_for_task(task_id)
  catch
    :exit, _reason -> :ok
  end

  # Every scripted turn answers with the next text in the list and YIELDS (an
  # interactive `{:implicit_completion, …}` is a `{:yield, …}`). The counter is
  # cross-process: the seam runs inside the exchange WORKER.
  defp script_yields(texts) do
    counter = :counters.new(1, [:atomics])

    Application.put_env(
      :evo_git,
      :agent_exchange_llm_call,
      fn context, _tools, _params, _agent_id, _retries ->
        :counters.add(counter, 1, 1)
        index = :counters.get(counter, 1) - 1
        text = Enum.at(texts, min(index, length(texts) - 1))
        {:implicit_completion, llm_response(context, text), text}
      end
    )

    counter
  end

  defp llm_response(context, text) do
    message = %ReqLLM.Message{
      role: :assistant,
      content: [ReqLLM.Message.ContentPart.text(text)],
      tool_calls: nil
    }

    %ReqLLM.Response{
      id: "node-context-session-response",
      model: "test:model",
      context: ReqLLM.Context.append(context, message),
      message: message,
      usage: %{input_tokens: 10, output_tokens: 2, total_tokens: 12}
    }
  end

  # --- observation helpers ---------------------------------------------------

  defp idle_entries, do: EvoDash.NodeContext.list_awaiting_input(node())

  defp idle?(agent_id), do: Enum.any?(idle_entries(), &(&1.agent_id == agent_id))

  defp idle_for_task?(task_id), do: Enum.any?(idle_entries(), &(&1.task_id == task_id))

  defp await_idle(agent_id, timeout \\ @wait_budget_ms) do
    wait_until(fn -> idle?(agent_id) end, timeout)

    idle_entries()
    |> Enum.find(&(&1.agent_id == agent_id)) ||
      flunk("expected an :awaiting_input session entry for agent #{agent_id}, got none")
  end

  defp await_idle_gone(agent_id, timeout \\ @wait_budget_ms) do
    wait_until(fn -> not idle?(agent_id) end, timeout)
  end

  # Bounded, event-driven wait: the predicate IS the assertion.
  defp wait_until(fun, timeout) do
    deadline = System.monotonic_time(:millisecond) + timeout
    do_wait_until(fun, deadline, timeout, 1)
  end

  defp do_wait_until(fun, deadline, original_timeout, interval) do
    cond do
      fun.() ->
        :ok

      System.monotonic_time(:millisecond) >= deadline ->
        flunk("condition not met within #{original_timeout}ms")

      true ->
        beat = min(interval, 5)
        Process.sleep(beat)
        do_wait_until(fun, deadline, original_timeout, beat * 2)
    end
  end

  # Restore a seam nil-aware: delete the key when it was originally unset.
  defp restore_env(key, nil), do: Application.delete_env(:evo_git, key)
  defp restore_env(key, value), do: Application.put_env(:evo_git, key, value)

  # Puts the app-global scheduler's model configuration back exactly as this
  # module found it (`update_config` rejects a nil `llm_model`, so that key is
  # skipped when it was nil).
  defp restore_scheduler_config(original_profiles, original_model) do
    GenServer.call(
      EvoGit.AgentScheduler,
      {:update_config, [model_profiles: original_profiles]},
      @config_call_timeout
    )

    if original_model != nil do
      GenServer.call(
        EvoGit.AgentScheduler,
        {:update_config, [llm_model: original_model]},
        @config_call_timeout
      )
    end

    :ok
  end
end
