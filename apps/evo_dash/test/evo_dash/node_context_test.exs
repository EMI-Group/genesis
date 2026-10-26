defmodule EvoDash.NodeContextTest do
  use EvoDashWeb.ConnCase, async: false

  import ExUnit.CaptureLog

  alias EvoGit.TaskInfo

  # Isolated Store + TaskRegistry against a temp sqlite file. The helper owns
  # teardown: it stops the isolated pair FIRST, then restores and VERIFIES the
  # production children (no start_supervised/on_exit racing).
  #
  # Attached ONLY to the describes that actually reach the store/registry (the
  # summary/lite/cancel/archive reads): the pure delegation-shape describes
  # (GitHub adapter errors, resolved config, system samples, custom agents
  # tools + approvals) never touch SQLite, and an isolation round-trip per test
  # is pure overhead for them.
  def setup_isolated_registry(_context) do
    :ok = EvoDash.Test.IsolatedTaskStore.isolate!("node_context")
  end

  # Inserts a task directly into the SQLite store (bypasses the async
  # task spawn that `start_task/2` triggers). Deterministic fixture for
  # the cancellation round-trip.
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
    id
  end

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

  describe "task-cancellation RPC delegates (local node, real paths)" do
    setup :setup_isolated_registry

    test "cancel_task/2 returns {:error, :not_found} for a missing task" do
      assert EvoDash.NodeContext.cancel_task(node(), "missing-id") == {:error, :not_found}
    end

    test "force_kill_task/2 returns {:error, :not_found} for a missing task" do
      assert EvoDash.NodeContext.force_kill_task(node(), "missing-id") == {:error, :not_found}
    end

    test "cancel_task/2 on a :pending task marks it :cancelled immediately" do
      id = insert_fixture!(status: :pending)

      assert EvoDash.NodeContext.cancel_task(node(), id) == :ok
      assert EvoGit.Store.get_task_status(EvoGit.Store, id) == :cancelled
    end
  end

  describe "lightweight task reads (local node, real paths)" do
    setup :setup_isolated_registry

    # The summary/lite reads route through
    # `EvoGit.RemoteNode` → `RemoteAPI` → `EvoGit.TaskRegistry` → `EvoGit.Store`,
    # so the isolated pair from `setup` serves them with real rows.
    @summary_keys ~w(
      id status review_status started_at finished_at type project_path opts
      branch_name model_id agent_count base_sha commit_sha lease_expires_at
      updated_at error
    )a
    test "list_tasks_page/2 returns summary rows + the filtered total (no heavy blobs)" do
      id = insert_fixture!(status: :completed, project_path: "/tmp/proj_a")
      assert %{rows: [row], total: 1} = EvoDash.NodeContext.list_tasks_page(node())
      assert row.id == id
      assert row.status == :completed
      assert row.project_path == "/tmp/proj_a"
      # The 16-key projection: heavy blobs are never part of a summary row.
      assert Enum.sort(Map.keys(row)) == Enum.sort(@summary_keys)
      refute Map.has_key?(row, :result)
      refute Map.has_key?(row, :usage)
      refute Map.has_key?(row, :logs)
      refute Map.has_key?(row, :archive_metadata)
    end

    test "list_tasks_page/2 forwards limit/offset and the filter opts" do
      insert_fixture!(status: :completed, project_path: "/tmp/proj_a")
      keep = insert_fixture!(status: :failed, project_path: "/tmp/proj_b")

      # The core filter expects the status as its on-disk STRING (the summary
      # rows still decode it back to an atom).
      assert %{rows: [row], total: 1} =
               EvoDash.NodeContext.list_tasks_page(node(), status: "failed")

      assert row.id == keep
      assert row.status == :failed

      assert %{rows: [], total: 0} =
               EvoDash.NodeContext.list_tasks_page(node(), project_path: "/tmp/nowhere")

      assert %{rows: rows, total: 2} =
               EvoDash.NodeContext.list_tasks_page(node(), limit: 1, offset: 0)

      assert length(rows) == 1
    end

    test "get_task_lite/2 and get_task/2 carry no archive key (the archive is its own table)" do
      archive = [%{"role" => "user", "content" => "archived"}]
      id = insert_fixture!(result: {:ok, %{commit_sha: "sha1", archive_records: archive}})

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
      assert EvoDash.NodeContext.get_task_lite(node(), "missing-id") == nil
    end
  end

  describe "paged task-archive reads (EvoGit.RemoteNode delegation)" do
    setup :setup_isolated_registry

    # `EvoGit.RemoteNode.list_task_archives/3` and `get_agent_archive/3` ship as
    # parallel core work and do not exist in this tree yet, so the delegation
    # itself cannot be called here (there is no runner seam for RemoteNode
    # delegation — the existing tests hit the real local path). What IS asserted
    # unconditionally is the observable surface that does not need the core:
    # the documented arities (incl. the `opts \\ []` default form) and the
    # totality of the two normalization steps NodeContext applies to EVERY
    # payload, which is what makes the mirrors safe for callers.
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

        assert EvoDash.NodeContext.list_task_archives(node(), "missing-id", opts) ==
                 %{entries: [], total: 0}

        # The `opts \\ []` default form delegates with the same shape.
        assert EvoDash.NodeContext.list_task_archives(node(), "missing-id") ==
                 %{entries: [], total: 0}
      else
        # Core not in this tree yet: nothing to call. The documented default is
        # part of the function head, provable through the 2-arity export above.
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
      assert EvoDash.NodeContext.get_task(node(), "missing-id") == nil
    end

    test "get_task/2 returns the stored %TaskInfo{} for an existing task" do
      id = insert_fixture!(status: :pending)

      assert %EvoGit.TaskInfo{id: ^id} = EvoDash.NodeContext.get_task(node(), id)
    end

    test "set_review_status/3 and set_review_metadata/4 are fire-and-forget casts (:ok)" do
      assert EvoDash.NodeContext.set_review_status(node(), "missing-id", :completed) == :ok

      assert EvoDash.NodeContext.set_review_metadata(node(), "missing-id", "base", "commit") ==
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

  describe "custom-agents RPC delegates (local node, real paths)" do
    # The local path reads/writes the REAL agents.toml at
    # EvoGit.Config.config_dir(). Never touch the user's real file: isolate
    # with the same XDG pattern as evo_git's custom_agents_test.exs.
    setup do
      original_xdg = System.get_env("XDG_CONFIG_HOME")

      tmp_xdg =
        Path.join(System.tmp_dir!(), "evogit-test-xdg-#{System.unique_integer([:positive])}")

      File.mkdir_p!(tmp_xdg)
      System.put_env("XDG_CONFIG_HOME", tmp_xdg)

      on_exit(fn ->
        if original_xdg do
          System.put_env("XDG_CONFIG_HOME", original_xdg)
        else
          System.delete_env("XDG_CONFIG_HOME")
        end

        File.rm_rf!(tmp_xdg)
      end)

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
    # directory. Never touch the user's real config: isolate with the same XDG
    # pattern as the custom-agents describe above (and evo_git's
    # custom_tools_rpc_test.exs). A fresh temp config dir has no `tools/`
    # subdirectory, so the hermetic status is the empty shape.
    setup do
      original_xdg = System.get_env("XDG_CONFIG_HOME")

      tmp_xdg =
        Path.join(System.tmp_dir!(), "evogit-test-xdg-#{System.unique_integer([:positive])}")

      File.mkdir_p!(tmp_xdg)
      System.put_env("XDG_CONFIG_HOME", tmp_xdg)

      # The loader caches in :persistent_term keyed by the tools dir (which
      # follows XDG_CONFIG_HOME) — invalidate before and after for determinism.
      EvoGit.CustomTools.reload()

      on_exit(fn ->
        EvoGit.CustomTools.reload()

        if original_xdg do
          System.put_env("XDG_CONFIG_HOME", original_xdg)
        else
          System.delete_env("XDG_CONFIG_HOME")
        end

        File.rm_rf!(tmp_xdg)
      end)

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
      # EvoGit.CommandApproval ships as parallel core work and does not exist
      # in this tree, so the guarded local path degrades to
      # {:error, :command_approval_unavailable}. Guard on the backend's
      # presence (mirrors home_live_test.exs:63 and the node_context.ex
      # with_remote_connection/4 pattern) so this stays valid once the core
      # lands: with the real module present, responding on an unknown request
      # id must degrade to an error tuple rather than raise.
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
      # unreachable-remote custom_tools_status case above.
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
end
