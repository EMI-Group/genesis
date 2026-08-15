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
end
