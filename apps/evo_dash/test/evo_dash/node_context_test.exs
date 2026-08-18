defmodule EvoDash.NodeContextTest do
  use EvoDashWeb.ConnCase, async: false

  alias EvoGit.TaskInfo
  alias EvoGit.TaskRegistry

  setup do
    # Terminate production children to prevent auto-restarts and use isolated stores.
    Supervisor.terminate_child(EvoGit.Supervisor, EvoGit.TaskRegistry)
    Supervisor.terminate_child(EvoGit.Supervisor, EvoGit.Store)

    unique = System.unique_integer([:positive])
    root = Path.join(System.tmp_dir!(), "evogit_test_node_context_#{unique}")
    File.mkdir_p!(root)
    sqlite_path = Path.join(root, "tasks.sqlite")

    start_supervised({EvoGit.Store, data_dir: sqlite_path})

    start_supervised(
      {TaskRegistry, task_store: EvoGit.Store, data_dir: root, name: EvoGit.TaskRegistry}
    )

    on_exit(fn ->
      File.rm_rf(root)
      Supervisor.restart_child(EvoGit.Supervisor, EvoGit.Store)
      Supervisor.restart_child(EvoGit.Supervisor, EvoGit.TaskRegistry)
    end)

    :ok
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

  describe "task-cancellation RPC delegates (local node, real paths)" do
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
end
