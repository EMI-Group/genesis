defmodule EvoDashWeb.NodeAwareTest do
  # Tests the transition-detection + push_patch behavior of
  # handle_connection_status/2. We build a minimal LiveView socket struct and
  # call the helper directly, then assert on the returned socket's `redirected`
  # field (push_patch sets it to {:live, :patch, %{to: path}}) or the assigns.
  #
  # This avoids booting a real LiveView or remote node — we only test the
  # pure transition-detection logic in the hook.
  #
  # The sidebar Active Tasks load is ASYNC: `load_running_and_pending_tasks/1`
  # / `assign_node/2` spawn a fetch on `EvoDash.TaskSupervisor` whose captured
  # `view_pid` IS the test process, so tests assert on the
  # `{:node_aware_active_tasks, seq, node_id, node, {running, pending}}`
  # message via `assert_receive`/`refute_receive` (send-pattern), and the
  # stale-guard seam `handle_tasks_result/2` is tested directly (pure socket
  # in/out).
  #
  # The debounced task-reload path (`handle_task_info/2`) uses the same
  # send-pattern: a matching-node event schedules `:node_aware_reload_tasks`
  # after 300ms (`assert_receive :node_aware_reload_tasks` — always drained so
  # late messages never leak into a later test), while foreign-node events are
  # dropped before the debounce (`refute_receive`).
  #
  # The hub-seeded on_mount describes (added with the EvoDash.ActiveTasks hub)
  # invoke `on_mount/4` directly on a boot-shaped socket — `mount_socket/1`
  # (dead render, transport_pid nil) and `connected_mount_socket/1` (a non-nil
  # transport_pid makes Phoenix.LiveView.connected?/1 true — see
  # deps/phoenix_live_view/lib/phoenix_live_view.ex) — and pin the sidebar
  # no-blink / no-leak / no-redundant-fetch contract: synchronous hub seeding
  # per node context, the connected-mount fetch firing ONLY for a cold LOCAL
  # context, applied `handle_tasks_result/2` results writing the hub (stale
  # ones never), and node switches to unseen remote contexts still fetching.
  #
  # async: false — the assign_node remote-target tests mutate the global
  # XDG_CONFIG_HOME env var (to isolate EvoGit.RemoteConnections, same pattern
  # as evo_git's remote_connections_test.exs) and register a fake connection
  # manager in the shared EvoGit.RemoteConnection.Registry, so they must not
  # run concurrently with other test files.
  use ExUnit.Case, async: false

  alias EvoDashWeb.LiveHooks.NodeAware
  alias EvoGit.TaskInfo

  setup do
    # Reset the shared EvoDash.ActiveTasks hub (a supervised GenServer shared
    # across all evo_dash tests in the OS process — same isolation pattern as
    # home_live_test.exs's ChatHistory.reset and update_status_test.exs's
    # UpdateStatus.reset) so an applied handle_tasks_result/2 from one test can
    # never warm the hub for the next.
    EvoDash.ActiveTasks.reset()
    :ok
  end

  # Build a minimal LiveView socket with the assigns the helper reads.
  # `redirected: nil` is required for push_patch to work (it raises if already
  # set). `assigns.__changed__` is required by Phoenix.LiveView.Socket's default.
  defp socket(overrides) do
    assigns =
      %{
        __changed__: nil,
        current_node: node(),
        current_node_name: "Local",
        current_node_id: "gpu-server",
        current_path: "/agents",
        connection_statuses: %{},
        running_tasks: [],
        pending_tasks: [],
        tasks_load_seq: 0,
        tasks_reload_pending: false
      }
      |> Map.merge(overrides)

    %Phoenix.LiveView.Socket{assigns: assigns, redirected: nil}
  end

  # Extracts the patch destination path from a push_patch socket, or returns
  # nil if not redirected. push_patch sets socket.redirected to
  # {:live, :patch, %{kind: :push, to: path}}.
  defp patch_to(%Phoenix.LiveView.Socket{redirected: {:live, :patch, %{to: to}}}), do: to
  defp patch_to(_), do: nil

  # ── Boot-shaped mount sockets (for the hub-seeded on_mount describes) ──
  #
  # on_mount/4 needs more than the bare socket/1 helper provides: it attaches
  # a :handle_info interceptor, and Phoenix.LiveView.attach_hook/4 reads the
  # boot-time :lifecycle key from socket.private (same boot internals as
  # appearance_test.exs's hook_socket). Unlike socket/1, these do NOT preset
  # :running_tasks/:pending_tasks — the whole point is that on_mount seeds
  # them from the EvoDash.ActiveTasks hub via assign_new.

  # Dead-render mount socket: transport_pid nil → connected?(socket) == false
  # (the on_mount dead-render path never queries the registry).
  defp mount_socket(overrides \\ %{}) do
    assigns = Map.merge(%{__changed__: %{}}, overrides)

    %Phoenix.LiveView.Socket{
      assigns: assigns,
      router: EvoDashWeb.Router,
      private: %{lifecycle: %Phoenix.LiveView.Lifecycle{}, live_temp: %{}},
      transport_pid: nil
    }
  end

  # Connected (websocket) mount socket. Phoenix.LiveView.connected?/1 is
  # `transport_pid != nil` (deps/phoenix_live_view/lib/phoenix_live_view.ex:
  # `def connected?(%Socket{transport_pid: transport_pid}), do: transport_pid
  # != nil`) — a non-nil transport_pid fakes a connected mount.
  defp connected_mount_socket(overrides \\ %{}) do
    %{mount_socket(overrides) | transport_pid: self()}
  end

  # Saves a connection target into the (per-test isolated) config dir so
  # remote/pending `?node=` resolution finds it. Same helper shape as the
  # "assign_node/2 — :remote_status assign" describe's setup.
  defp save_target!(id, ssh_target \\ "test-host") do
    {:ok, target} = EvoGit.RemoteConnections.save(%{ssh_target: ssh_target, id: id})
    target
  end

  # Inserts a task directly into the SQLite store so the local
  # TaskRegistry.list_tasks_summary/1 picks it up.
  defp insert_fixture!(store, overrides) do
    id = "fixture_#{System.unique_integer([:positive])}"

    task =
      %TaskInfo{
        id: id,
        type: :genesis,
        status: :completed,
        opts: Keyword.merge([path: "/tmp/test"], Keyword.get(overrides, :opts, [])),
        ref: nil,
        started_at: DateTime.utc_now(),
        finished_at: DateTime.utc_now(),
        logs: [],
        result: nil
      }
      |> Map.merge(Enum.into(overrides, %{}))

    EvoGit.Store.put_task(store, task)
    task
  end

  # Sets up an isolated Store + TaskRegistry (production children are terminated
  # so they don't auto-restart during the test). Used by describe blocks that
  # need a real TaskRegistry backing the local node path.
  def setup_isolated_registry(_context) do
    Supervisor.terminate_child(EvoGit.Supervisor, EvoGit.TaskRegistry)
    Supervisor.terminate_child(EvoGit.Supervisor, EvoGit.Store)

    unique = System.unique_integer([:positive])
    root = Path.join(System.tmp_dir!(), "evogit_test_node_aware_#{unique}")
    File.mkdir_p!(root)
    sqlite_path = Path.join(root, "tasks.sqlite")

    store = EvoGit.Store
    start_supervised!({EvoGit.Store, data_dir: sqlite_path})

    start_supervised!(
      {EvoGit.TaskRegistry, task_store: store, data_dir: root, name: EvoGit.TaskRegistry}
    )

    on_exit(fn ->
      File.rm_rf(root)
      Supervisor.restart_child(EvoGit.Supervisor, EvoGit.Store)
      Supervisor.restart_child(EvoGit.Supervisor, EvoGit.TaskRegistry)
    end)

    :ok
  end

  # Isolates the config dir via XDG_CONFIG_HOME so EvoGit.RemoteConnections
  # never touches the developer's real ~/.config/genesis/ directory. Same
  # pattern as evo_git's remote_connections_test.exs. Requires async: false
  # (mutates a global env var).
  defp isolate_config_dir(_context) do
    original_xdg = System.get_env("XDG_CONFIG_HOME")

    tmp_xdg =
      Path.join(
        System.tmp_dir!(),
        "evogit_test_node_aware_xdg_#{System.unique_integer([:positive])}"
      )

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

  describe "handle_connection_status/2 — meaningful transitions trigger push_patch" do
    test "local → remote: :connected for the selected node triggers push_patch" do
      # current_node is local (node()) — a :connected broadcast for the
      # selected node is a local→remote transition.
      socket =
        socket(%{
          current_node: node(),
          current_node_id: "gpu-server"
        })

      status = %{phase: :connected, node: "genesis_remote@127.0.0.1", last_error: nil}

      assert {:noreply, result} =
               NodeAware.handle_connection_status(
                 socket,
                 {:remote_connection_status, "gpu-server", status}
               )

      # push_patch sets socket.redirected to {:live, :patch, %{kind: :push, to: path}}
      assert patch_to(result) == "/agents?node=gpu-server"
    end

    test "remote → local: :disconnected for the selected node triggers push_patch" do
      # current_node is remote — a :disconnected broadcast is a remote→local
      # transition.
      socket =
        socket(%{
          current_node: :"genesis_remote@127.0.0.1",
          current_node_id: "gpu-server"
        })

      assert {:noreply, result} =
               NodeAware.handle_connection_status(
                 socket,
                 {:remote_connection_status, "gpu-server", %{phase: :disconnected}}
               )

      assert patch_to(result) == "/agents?node=gpu-server"
    end

    test "remote → local: :error for the selected node triggers push_patch" do
      socket =
        socket(%{
          current_node: :"genesis_remote@127.0.0.1",
          current_node_id: "gpu-server"
        })

      assert {:noreply, result} =
               NodeAware.handle_connection_status(
                 socket,
                 {:remote_connection_status, "gpu-server", %{phase: :error, last_error: "boom"}}
               )

      assert patch_to(result) == "/agents?node=gpu-server"

      # :remote_status is recomputed from the live connection manager (in the
      # test env no manager is registered, so it degrades to the disconnected
      # default map) — never stale.
      assert %{phase: :disconnected} = result.assigns[:remote_status]
    end
  end

  describe "handle_connection_status/2 — non-transitions do NOT push_patch" do
    test ":connecting for the selected node does not push_patch" do
      # current_node is local/pending — a :connecting status is NOT a
      # reload-worthy transition (page already showing local data).
      socket = socket(%{current_node: node(), current_node_id: "gpu-server"})

      assert {:noreply, result} =
               NodeAware.handle_connection_status(
                 socket,
                 {:remote_connection_status, "gpu-server", %{phase: :connecting}}
               )

      assert patch_to(result) == nil
    end

    test ":connected for the selected node when ALREADY remote does not push_patch" do
      # current_node is already remote — a duplicate :connected is not a
      # transition (no local→remote change).
      socket =
        socket(%{
          current_node: :"genesis_remote@127.0.0.1",
          current_node_id: "gpu-server"
        })

      status = %{phase: :connected, node: "genesis_remote@127.0.0.1"}

      assert {:noreply, result} =
               NodeAware.handle_connection_status(
                 socket,
                 {:remote_connection_status, "gpu-server", status}
               )

      assert patch_to(result) == nil
    end

    test ":disconnected for the selected node when ALREADY local does not push_patch" do
      # current_node is already local — a :disconnected is not a transition
      # (no remote→local change).
      socket = socket(%{current_node: node(), current_node_id: "gpu-server"})

      assert {:noreply, result} =
               NodeAware.handle_connection_status(
                 socket,
                 {:remote_connection_status, "gpu-server", %{phase: :disconnected}}
               )

      assert patch_to(result) == nil
    end

    test "status for a NON-selected node does not push_patch" do
      # The selected node is gpu-server, but the broadcast is for another node.
      socket = socket(%{current_node: node(), current_node_id: "gpu-server"})

      status = %{phase: :connected, node: "other_remote@127.0.0.1"}

      assert {:noreply, result} =
               NodeAware.handle_connection_status(
                 socket,
                 {:remote_connection_status, "other-host", status}
               )

      assert patch_to(result) == nil
    end

    test ":bootstrapping for the selected node does not push_patch" do
      socket = socket(%{current_node: node(), current_node_id: "gpu-server"})

      assert {:noreply, result} =
               NodeAware.handle_connection_status(
                 socket,
                 {:remote_connection_status, "gpu-server",
                  %{phase: :bootstrapping, bootstrap_stage: :uploading}}
               )

      assert patch_to(result) == nil
    end
  end

  describe "handle_connection_status/2 — always refreshes connection_statuses" do
    test "refreshes connection_statuses even when not a transition" do
      socket =
        socket(%{current_node: node(), current_node_id: "gpu-server", connection_statuses: %{}})

      # node() calls to EvoDash.NodeContext.connection_status/0 should be fine
      # even in test env (returns %{} when subsystem unavailable).
      assert {:noreply, result} =
               NodeAware.handle_connection_status(
                 socket,
                 {:remote_connection_status, "gpu-server", %{phase: :connecting}}
               )

      # connection_statuses was refreshed (it's now the value from NodeContext,
      # not the stale %{})
      assert Map.has_key?(result.assigns, :connection_statuses)
    end
  end

  describe "handle_connection_status/2 — recomputes :remote_status" do
    # A fake connection manager is registered in the shared
    # EvoGit.RemoteConnection.Registry under a unique target id, so
    # EvoDash.NodeContext.connection_status/1 resolves the manager's status
    # instead of the disconnected default. The process dies (and its Registry
    # entry is cleaned up) at test end.
    test "recomputes :remote_status for a pending context (broadcast phase ignored)" do
      start_supervised!(
        {EvoDashWeb.NodeAwareTest.ConnectionManager,
         {"test-err", %{phase: :error, last_error: "boom"}}}
      )

      # Pending remote context: selected node is test-err, not yet connected.
      socket = socket(%{current_node: node(), current_node_id: "test-err"})

      # The broadcast says :connecting — not a transition for a pending
      # context, so no push_patch. But :remote_status must be recomputed from
      # the live manager and now reflect the error.
      assert {:noreply, result} =
               NodeAware.handle_connection_status(
                 socket,
                 {:remote_connection_status, "test-err", %{phase: :connecting}}
               )

      assert patch_to(result) == nil
      assert result.assigns[:remote_status] == %{phase: :error, last_error: "boom"}
    end

    test "recomputes :remote_status during a local → remote transition (push_patch still fires)" do
      start_supervised!(
        {EvoDashWeb.NodeAwareTest.ConnectionManager,
         {"test-conn", %{phase: :connected, node: "genesis_remote@127.0.0.1", last_error: nil}}}
      )

      socket = socket(%{current_node: node(), current_node_id: "test-conn"})

      assert {:noreply, result} =
               NodeAware.handle_connection_status(
                 socket,
                 {:remote_connection_status, "test-conn",
                  %{phase: :connected, node: "genesis_remote@127.0.0.1", last_error: nil}}
               )

      assert patch_to(result) == "/agents?node=test-conn"

      assert result.assigns[:remote_status] == %{
               phase: :connected,
               node: "genesis_remote@127.0.0.1",
               last_error: nil
             }
    end

    test "recomputes :remote_status when no remote context is selected (assigns nil)" do
      socket = socket(%{current_node: node(), current_node_id: nil, remote_status: "stale"})

      assert {:noreply, result} =
               NodeAware.handle_connection_status(
                 socket,
                 {:remote_connection_status, "other-host", %{phase: :connected}}
               )

      assert patch_to(result) == nil
      assert result.assigns[:remote_status] == "stale"
    end
  end

  describe "handle_connection_status/2 — fallback clause" do
    test "unknown message shape just refreshes statuses" do
      socket = socket(%{})

      assert {:noreply, result} =
               NodeAware.handle_connection_status(socket, {:some_other_message, 1, 2})

      assert patch_to(result) == nil
    end
  end

  describe "partition_active_tasks/1 — pure partitioning" do
    # Pure function tests (no socket, no store) — partition_active_tasks/1 only
    # reads `status` for the running filter, and status/review_status/
    # branch_name for the pending (review-candidate) filter.

    test "a :cancelling summary lands in the running partition" do
      {running, pending} = NodeAware.partition_active_tasks([%{id: "t1", status: :cancelling}])

      assert Enum.map(running, & &1.id) == ["t1"]
      assert pending == []
    end

    test "a :cancelled summary does NOT land in the running partition" do
      # :cancelled is terminal — it is neither running (not in the in-flight
      # status list) nor pending (not :completed, so not a review candidate).
      {running, pending} = NodeAware.partition_active_tasks([%{id: "t2", status: :cancelled}])

      assert running == []
      assert pending == []
    end

    test ":running/:pending/:finalizing summaries land in the running partition (regression)" do
      summaries = [
        %{id: "r1", status: :running},
        %{id: "p1", status: :pending},
        %{id: "f1", status: :finalizing}
      ]

      {running, pending} = NodeAware.partition_active_tasks(summaries)

      assert Enum.map(running, & &1.id) |> Enum.sort() == ["f1", "p1", "r1"]
      assert pending == []
    end
  end

  describe "load_running_and_pending_tasks/1 — node-aware source" do
    # These tests verify that the function spawns an async fetch from the
    # correct node: local `TaskRegistry.list_tasks_summary([:running, :pending,
    # :finalizing, :cancelling, :completed])` for the local node, and
    # `EvoDash.NodeContext.list_tasks_summary(node, statuses)` (RPC) for a
    # remote node. The spawned task's captured `view_pid` IS the test process,
    # so the assertions use `assert_receive {:node_aware_active_tasks, seq,
    # node_id, node, {running, pending}}` on the message payload (the socket
    # itself comes back unchanged — the load is async). The remote path fails
    # fast (noconnection) when the target node doesn't exist, so it returns []
    # quickly without a timeout.

    setup :setup_isolated_registry

    test "local node: reads from TaskRegistry.list_tasks_summary/1" do
      # Insert a running task and a completed task with a branch (reviewable)
      insert_fixture!(EvoGit.Store, status: :running)

      insert_fixture!(EvoGit.Store,
        status: :completed,
        result: {:ok, %{branch_name: "feature-1"}},
        review_status: nil
      )

      # current_node_id: nil marks a pure-local context — the socket builder
      # default ("gpu-server") would be a pending remote context (empty lists).
      current_node = node()
      sock = socket(%{current_node: current_node, current_node_id: nil})

      result = NodeAware.load_running_and_pending_tasks(sock)

      # Async: the socket is returned unchanged (only the seq is bumped) —
      # previous sidebar content is kept until the result message arrives.
      assert result.assigns[:running_tasks] == []
      assert result.assigns[:pending_tasks] == []
      assert result.assigns[:tasks_load_seq] == 1

      assert_receive {:node_aware_active_tasks, 1, nil, ^current_node, {running, pending}}, 1000

      # The running task appears in running_tasks
      assert length(running) == 1
      assert hd(running).status == :running

      # The completed task with a branch appears in pending_tasks (reviewable)
      assert length(pending) == 1
      assert hd(pending).status == :completed
    end

    test "local node: pending, running, and finalizing all go to running_tasks" do
      insert_fixture!(EvoGit.Store, id: "p1", status: :pending)
      insert_fixture!(EvoGit.Store, id: "r1", status: :running)
      insert_fixture!(EvoGit.Store, id: "f1", status: :finalizing)

      current_node = node()
      sock = socket(%{current_node: current_node, current_node_id: nil})

      NodeAware.load_running_and_pending_tasks(sock)

      assert_receive {:node_aware_active_tasks, 1, nil, ^current_node, {running, pending}}, 1000

      ids = Enum.map(running, & &1.id) |> Enum.sort()
      assert ids == ["f1", "p1", "r1"]
      assert pending == []
    end

    test "local node: a :cancelling task shows in running_tasks" do
      # :cancelling is non-terminal — the task stays visible in the sidebar
      # while it winds down, so it must land in running_tasks. finished_at must
      # be nil for in-flight statuses (the fixture helper defaults it to now).
      insert_fixture!(EvoGit.Store, id: "c1", status: :cancelling, finished_at: nil)

      current_node = node()
      sock = socket(%{current_node: current_node, current_node_id: nil})

      NodeAware.load_running_and_pending_tasks(sock)

      assert_receive {:node_aware_active_tasks, 1, nil, ^current_node, {running, pending}}, 1000

      assert Enum.any?(running, &(&1.id == "c1"))
      assert hd(running).status == :cancelling
      assert pending == []
    end

    test "remote node: uses EvoDash.NodeContext.list_tasks_summary/2 (RPC), not local" do
      # Insert local tasks that should NOT appear when viewing a remote node.
      insert_fixture!(EvoGit.Store, id: "local-only", status: :running)

      # A non-existent remote node — :erpc.call fails fast with :noconnection,
      # so NodeContext.list_tasks_summary/2 returns [] quickly (no 10s timeout).
      remote_node = :"nonexistent_remote_test@127.0.0.1"
      sock = socket(%{current_node: remote_node})

      NodeAware.load_running_and_pending_tasks(sock)

      assert_receive {:node_aware_active_tasks, 1, "gpu-server", ^remote_node,
                      {running, pending}},
                     1000

      # No tasks from the local registry should leak through to the remote view.
      assert running == []
      assert pending == []
    end

    test "fallback to node() when current_node assign is absent" do
      # When current_node is not set, it should fall back to node() (local).
      insert_fixture!(EvoGit.Store, id: "should-show", status: :running)

      current_node = node()
      sock = socket(%{current_node: nil, current_node_id: nil})

      NodeAware.load_running_and_pending_tasks(sock)

      assert_receive {:node_aware_active_tasks, 1, nil, ^current_node, {running, _pending}}, 1000

      assert Enum.any?(running, &(&1.id == "should-show"))
    end

    test "pending remote context: assigns empty running/pending (local tasks hidden)" do
      # A remote context was requested (`?node=<id>`) but the connection hasn't
      # completed yet — current_node_id is set but current_node is still the
      # local BEAM node. Local tasks must NEVER appear in the sidebar.
      insert_fixture!(EvoGit.Store, id: "local-hidden", status: :running)
      insert_fixture!(EvoGit.Store, id: "local-hidden-2", status: :completed)

      current_node = node()
      sock = socket(%{current_node: current_node, current_node_id: "gpu-server"})

      NodeAware.load_running_and_pending_tasks(sock)

      assert_receive {:node_aware_active_tasks, 1, "gpu-server", ^current_node,
                      {running, pending}},
                     1000

      assert running == []
      assert pending == []
    end
  end

  describe "assign_node/2 — reloads sidebar tasks on node switch" do
    # assign_node/2 sets the node-context assigns synchronously and triggers the
    # ASYNC sidebar load after them (dedup-guarded by :tasks_node_loaded). The
    # spawned task's captured view_pid IS the test process, so we assert on the
    # `{:node_aware_active_tasks, seq, node_id, node, {running, pending}}`
    # message payload instead of the returned socket's assigns.

    setup :setup_isolated_registry

    test "loads tasks when resolving to local node" do
      insert_fixture!(EvoGit.Store, id: "running-1", status: :running)

      current_node = node()
      sock = socket(%{current_node: current_node, current_node_id: nil})

      result = NodeAware.assign_node(sock, %{})

      # Node-context assigns are set synchronously...
      assert result.assigns[:current_node_id] == nil
      assert result.assigns[:current_node] == current_node
      assert result.assigns[:tasks_node_loaded] == {nil, current_node}

      # ...and the sidebar load arrives asynchronously.
      assert_receive {:node_aware_active_tasks, 1, nil, ^current_node, {running, pending}}, 1000

      assert Enum.any?(running, &(&1.id == "running-1"))
      assert pending == []
    end

    test "loads tasks when resolving to local via node=local param" do
      insert_fixture!(EvoGit.Store, id: "running-2", status: :running)

      current_node = node()
      sock = socket(%{current_node: current_node, current_node_id: nil})

      NodeAware.assign_node(sock, %{"node" => "local"})

      assert_receive {:node_aware_active_tasks, 1, nil, ^current_node, {running, _pending}}, 1000

      assert Enum.any?(running, &(&1.id == "running-2"))
    end

    test "unknown node param falls back to local and loads local tasks" do
      insert_fixture!(EvoGit.Store, id: "local-only-assign", status: :running)

      current_node = node()
      sock = socket(%{current_node: current_node, current_node_id: nil})

      NodeAware.assign_node(sock, %{"node" => "unknown-id"})

      # An unknown node param resolves to :local (target not found), so the
      # local task shows up.
      assert_receive {:node_aware_active_tasks, 1, nil, ^current_node, {running, _pending}}, 1000

      assert Enum.any?(running, &(&1.id == "local-only-assign"))
    end
  end

  describe "async sidebar delivery + stale-guard" do
    # End-to-end async pipeline: load → `{:node_aware_active_tasks, ...}`
    # message → `handle_tasks_result/2` (the attached `:handle_info` hook's
    # stale-guard seam) → assigns.

    setup :setup_isolated_registry

    test "async delivery populates the sidebar (previous content kept until the result arrives)" do
      # Insert a running task and a completed task with a branch (reviewable)
      insert_fixture!(EvoGit.Store, status: :running)

      insert_fixture!(EvoGit.Store,
        status: :completed,
        result: {:ok, %{branch_name: "feature-1"}},
        review_status: nil
      )

      current_node = node()
      sock = socket(%{current_node: current_node, current_node_id: nil})

      result = NodeAware.load_running_and_pending_tasks(sock)

      # The socket is returned unchanged — previous sidebar content stays
      # visible until the fresh result arrives.
      assert result.assigns[:running_tasks] == []
      assert result.assigns[:pending_tasks] == []

      assert_receive {:node_aware_active_tasks, 1, nil, ^current_node, {running, pending}}, 1000

      assert length(running) == 1
      assert hd(running).status == :running
      assert length(pending) == 1
      assert hd(pending).status == :completed

      # Applying the message through the stale-guard populates the assigns.
      socket =
        NodeAware.handle_tasks_result(
          result,
          {:node_aware_active_tasks, 1, nil, current_node, {running, pending}}
        )

      assert length(socket.assigns[:running_tasks]) == 1
      assert hd(socket.assigns[:running_tasks]).status == :running
      assert length(socket.assigns[:pending_tasks]) == 1
      assert hd(socket.assigns[:pending_tasks]).status == :completed
    end

    test "stale result for a different node is dropped (assigns unchanged)" do
      current_node = node()

      sock =
        socket(%{
          current_node: current_node,
          current_node_id: nil,
          running_tasks: [%{id: "keep"}],
          pending_tasks: [%{id: "keep-pending"}]
        })

      result =
        NodeAware.handle_tasks_result(
          sock,
          {:node_aware_active_tasks, 1, "other-node", :"other_remote@127.0.0.1",
           {[%{id: "stale"}], []}}
        )

      assert result.assigns[:running_tasks] == [%{id: "keep"}]
      assert result.assigns[:pending_tasks] == [%{id: "keep-pending"}]
    end

    test "outdated seq is dropped (assigns unchanged)" do
      current_node = node()

      sock =
        socket(%{
          current_node: current_node,
          current_node_id: nil,
          tasks_load_seq: 3,
          running_tasks: [%{id: "keep"}],
          pending_tasks: []
        })

      # seq 2 < the current :tasks_load_seq (3) — a newer load was spawned.
      result =
        NodeAware.handle_tasks_result(
          sock,
          {:node_aware_active_tasks, 2, nil, current_node, {[%{id: "stale"}], []}}
        )

      assert result.assigns[:running_tasks] == [%{id: "keep"}]
      assert result.assigns[:pending_tasks] == []
    end

    test "matching seq and node context assigns the payload" do
      current_node = node()
      sock = socket(%{current_node: current_node, current_node_id: nil, tasks_load_seq: 1})

      result =
        NodeAware.handle_tasks_result(
          sock,
          {:node_aware_active_tasks, 1, nil, current_node, {[%{id: "fresh"}], []}}
        )

      assert result.assigns[:running_tasks] == [%{id: "fresh"}]
      assert result.assigns[:pending_tasks] == []
    end

    test "node switch triggers a fresh load; same context does not re-spawn" do
      insert_fixture!(EvoGit.Store, id: "running-1", status: :running)

      current_node = node()
      sock = socket(%{current_node: current_node, current_node_id: nil})

      # First assign_node with the local context spawns a load.
      result = NodeAware.assign_node(sock, %{})
      assert result.assigns[:tasks_node_loaded] == {nil, current_node}

      assert_receive {:node_aware_active_tasks, 1, nil, ^current_node, {running, _pending}}, 1000
      assert Enum.any?(running, &(&1.id == "running-1"))

      # A second assign_node with the SAME context must NOT re-spawn (the
      # :tasks_node_loaded dedup guard skips it — no new message arrives).
      NodeAware.assign_node(result, %{})
      refute_receive {:node_aware_active_tasks, _, _, _, _}, 150
    end
  end

  describe "handle_task_info/2 — node-filtered debounce" do
    # The node-identity PubSub contract: `{:task_updated, task_id, status,
    # node}` / `{:task_deleted, task_id, node}` where node is the BEAM node
    # atom of the publishing node. A matching-node event schedules the 300ms
    # trailing-edge debounce (`:node_aware_reload_tasks`); a foreign-node event
    # is dropped BEFORE the debounce — socket returned unchanged, no message.
    # Every scheduling test drains the message with `assert_receive` so a late
    # delivery can never leak into a later test's `refute_receive`.

    test "{:task_updated, _, _, node()} with matching node schedules the debounce" do
      sock = socket(%{current_node: node(), tasks_reload_pending: false})

      assert {:noreply, result} =
               NodeAware.handle_task_info(sock, {:task_updated, "t1", :running, node()})

      assert result.assigns[:tasks_reload_pending] == true
      assert_receive :node_aware_reload_tasks, 500
    end

    test "{:task_updated, _, _, foreign_node} is dropped (socket unchanged, no reload scheduled)" do
      sock = socket(%{current_node: node(), tasks_reload_pending: false})

      assert {:noreply, result} =
               NodeAware.handle_task_info(sock, {:task_updated, "t1", :running, :remote@other})

      assert result == sock
      assert result.assigns[:tasks_reload_pending] == false
      refute_receive :node_aware_reload_tasks, 150
    end

    test "{:task_deleted, _, node()} with matching node schedules the debounce" do
      sock = socket(%{current_node: node(), tasks_reload_pending: false})

      assert {:noreply, result} =
               NodeAware.handle_task_info(sock, {:task_deleted, "t1", node()})

      assert result.assigns[:tasks_reload_pending] == true
      assert_receive :node_aware_reload_tasks, 500
    end

    test "{:task_deleted, _, foreign_node} is dropped (socket unchanged, no reload scheduled)" do
      sock = socket(%{current_node: node(), tasks_reload_pending: false})

      assert {:noreply, result} =
               NodeAware.handle_task_info(sock, {:task_deleted, "t1", :remote@other})

      assert result == sock
      assert result.assigns[:tasks_reload_pending] == false
      refute_receive :node_aware_reload_tasks, 150
    end

    test "remote viewing: event from the viewed remote node schedules; a local event is dropped" do
      remote_node = :"genesis_remote@127.0.0.1"
      sock = socket(%{current_node: remote_node, tasks_reload_pending: false})

      # The remote daemon's own event matches the viewed node → reload.
      assert {:noreply, result} =
               NodeAware.handle_task_info(sock, {:task_updated, "t1", :completed, remote_node})

      assert result.assigns[:tasks_reload_pending] == true
      assert_receive :node_aware_reload_tasks, 500

      # A local-node event while viewing the remote node → dropped.
      sock2 = socket(%{current_node: remote_node, tasks_reload_pending: false})

      assert {:noreply, result2} =
               NodeAware.handle_task_info(sock2, {:task_updated, "t2", :completed, node()})

      assert result2 == sock2
      assert result2.assigns[:tasks_reload_pending] == false
      refute_receive :node_aware_reload_tasks, 150
    end

    test "review-only mutation (status nil) with matching node schedules the debounce" do
      sock = socket(%{current_node: node(), tasks_reload_pending: false})

      assert {:noreply, result} =
               NodeAware.handle_task_info(sock, {:task_updated, "t1", nil, node()})

      assert result.assigns[:tasks_reload_pending] == true
      assert_receive :node_aware_reload_tasks, 500
    end

    test "a second matching broadcast while a reload is pending is dropped (coalescing)" do
      sock = socket(%{current_node: node(), tasks_reload_pending: false})

      {:noreply, result} =
        NodeAware.handle_task_info(sock, {:task_updated, "t1", :running, node()})

      assert result.assigns[:tasks_reload_pending] == true

      # The second broadcast arrives while the reload is pending — dropped.
      {:noreply, result2} =
        NodeAware.handle_task_info(result, {:task_updated, "t2", :completed, node()})

      assert result2 == result

      # Exactly ONE :node_aware_reload_tasks message was scheduled.
      assert_receive :node_aware_reload_tasks, 500
      refute_receive :node_aware_reload_tasks, 150
    end
  end

  describe "event_from_current_node?/2 — node-identity filter" do
    test "local viewing: true for node(), false for a foreign atom" do
      assert NodeAware.event_from_current_node?(%{current_node: node()}, node())
      refute NodeAware.event_from_current_node?(%{current_node: node()}, :remote@other)
    end

    test "remote viewing: true for the viewed remote atom, false for node()" do
      remote_node = :genesis_remote@host
      assert NodeAware.event_from_current_node?(%{current_node: remote_node}, remote_node)
      refute NodeAware.event_from_current_node?(%{current_node: remote_node}, node())
    end

    test "missing :current_node assign falls back to node()" do
      assert NodeAware.event_from_current_node?(%{}, node())
      refute NodeAware.event_from_current_node?(%{}, :remote@other)
    end
  end

  describe "assign_node/2 — :remote_status assign" do
    # assign_node's remote resolution reads connection targets from
    # EvoGit.RemoteConnections (a TOML file under the config dir), so these
    # tests isolate XDG_CONFIG_HOME to avoid touching the developer's real
    # ~/.config/genesis/ and save a dedicated test target.
    #
    # The node-context assigns (current_node_id/current_node/remote_status) are
    # set synchronously and asserted directly. Each assign_node call ALSO
    # triggers an async sidebar load whose result message
    # (`{:node_aware_active_tasks, ...}`) lands in the test-process mailbox as
    # a stray message — harmless, but be aware.
    setup :setup_isolated_registry
    setup :isolate_config_dir

    setup do
      {:ok, target} = EvoGit.RemoteConnections.save(%{ssh_target: "test-host", id: "test-target"})
      %{target: target}
    end

    test "local node → :remote_status is nil" do
      result = NodeAware.assign_node(socket(%{}), %{})

      assert result.assigns[:current_node_id] == nil
      assert result.assigns[:remote_status] == nil
    end

    test "saved-but-disconnected (pending) target → disconnected status map" do
      # No connection manager registered for the target, so
      # connection_status/1 degrades to the disconnected default map.
      result = NodeAware.assign_node(socket(%{}), %{"node" => "test-target"})

      assert result.assigns[:current_node_id] == "test-target"
      assert result.assigns[:current_node] == node()
      assert %{phase: :disconnected} = result.assigns[:remote_status]
    end

    test "connected target → status map passes through" do
      start_supervised!(
        {EvoDashWeb.NodeAwareTest.ConnectionManager,
         {"test-target", %{phase: :connected, node: "genesis_remote@127.0.0.1", last_error: nil}}}
      )

      result = NodeAware.assign_node(socket(%{}), %{"node" => "test-target"})

      assert result.assigns[:current_node_id] == "test-target"
      assert result.assigns[:current_node] == :"genesis_remote@127.0.0.1"

      assert result.assigns[:remote_status] == %{
               phase: :connected,
               node: "genesis_remote@127.0.0.1",
               last_error: nil
             }
    end

    test "pending target with error status → error status map passes through" do
      # An error status is NOT connected, so the context stays pending — but
      # the gate must expose the live error status map.
      start_supervised!(
        {EvoDashWeb.NodeAwareTest.ConnectionManager,
         {"test-target", %{phase: :error, last_error: "boom"}}}
      )

      result = NodeAware.assign_node(socket(%{}), %{"node" => "test-target"})

      assert result.assigns[:current_node_id] == "test-target"
      assert result.assigns[:current_node] == node()
      assert result.assigns[:remote_status] == %{phase: :error, last_error: "boom"}
    end

    test "unknown target id → falls back to local with :remote_status nil" do
      result = NodeAware.assign_node(socket(%{}), %{"node" => "unknown-id"})

      assert result.assigns[:current_node_id] == nil
      assert result.assigns[:remote_status] == nil
    end
  end

  describe "on_mount/4 — hub-seeded sidebar: no-blink / no-leak / no-redundant-fetch" do
    # Regression coverage for the hub-seeded sidebar design (see node_aware.ex
    # moduledoc): on_mount seeds :running_tasks/:pending_tasks SYNCHRONOUSLY
    # from the EvoDash.ActiveTasks hub, keyed by the node context the page will
    # have after assign_node/2 runs — local {nil, node()}, remote {node_param,
    # remote_node}, pending {node_param, node()}.
    #
    # * no-blink: a remounting page renders the hub's last-known lists on its
    #   very first render (dead OR connected), before any async fetch result.
    # * no-leak: a page seeds ONLY its own context's hub key — a local snapshot
    #   can never appear on a remote/pending page (and vice versa).
    # * no-redundant-fetch: a WARM hub context never spawns the mount fetch
    #   (dead renders never query at all; the connected fetch fires only for a
    #   cold LOCAL context — covered in the next describe).
    #
    # on_mount also calls EvoDash.NodeContext.list_targets() (reads
    # remote_connections.toml), so the config dir is isolated per test (same
    # convention as the assign_node remote-target describes).
    setup :isolate_config_dir

    test "warm LOCAL hub seeds running/pending synchronously on the dead render (no blink premise)" do
      running = [%{id: "hub-running", status: :running}]
      pending = [%{id: "hub-pending", status: :completed, branch_name: "feature-1"}]

      EvoDash.ActiveTasks.put(nil, node(), running, pending)

      assert {:cont, socket} = NodeAware.on_mount(:default, %{}, %{}, mount_socket())

      # Seeded IMMEDIATELY (synchronously) — no async message is involved.
      assert socket.assigns.running_tasks == running
      assert socket.assigns.pending_tasks == pending

      # Sidebar-gate premise: Layouts.app renders the Active Tasks section when
      # either list is non-empty — both non-empty here means the gate is open.
      assert socket.assigns.running_tasks != [] or socket.assigns.pending_tasks != []

      # Nothing is spawned on the dead render — no fetch message ever arrives.
      refute_receive {:node_aware_active_tasks, _, _, _, _}, 150
    end

    test "a stored {[], []} snapshot for a PENDING context seeds [] and still renders (no crash, no leak)" do
      # A pending-remote context whose last fetch applied {[], []} (the
      # pending-remote guard's empty result). Stored-empty IS a real snapshot
      # — get/3 returns {:ok, {[], []}} — so a remount seeds [] rather than
      # crashing, leaking another context's data, or re-fetching.
      save_target!("target-empty")
      EvoDash.ActiveTasks.put("target-empty", node(), [], [])

      assert {:cont, socket} =
               NodeAware.on_mount(
                 :default,
                 %{"node" => "target-empty"},
                 %{},
                 connected_mount_socket()
               )

      assert socket.assigns.running_tasks == []
      assert socket.assigns.pending_tasks == []
      assert EvoDash.ActiveTasks.get("target-empty", node()) == {:ok, {[], []}}

      # Stored-empty is still a snapshot → no redundant fetch on the connected mount.
      refute_receive {:node_aware_active_tasks, _, _, _, _}, 150
    end

    test "warm REMOTE hub + remote mount seeds the REMOTE snapshot, never the local one" do
      save_target!("target-3")
      remote_node = :"genesis_remote_3@127.0.0.1"

      start_supervised!(
        {EvoDashWeb.NodeAwareTest.ConnectionManager,
         {"target-3", %{phase: :connected, node: "genesis_remote_3@127.0.0.1", last_error: nil}}}
      )

      local_running = [%{id: "local-running", status: :running}]
      remote_running = [%{id: "remote-running", status: :running}]
      remote_pending = [%{id: "remote-pending", status: :completed, branch_name: "remote-b"}]

      EvoDash.ActiveTasks.put(nil, node(), local_running, [])
      EvoDash.ActiveTasks.put("target-3", remote_node, remote_running, remote_pending)

      assert {:cont, socket} =
               NodeAware.on_mount(
                 :default,
                 %{"node" => "target-3"},
                 %{},
                 connected_mount_socket()
               )

      # The REMOTE page seeds the REMOTE snapshot — instant warm remote render —
      # and the local snapshot never leaks through.
      assert socket.assigns.running_tasks == remote_running
      assert socket.assigns.pending_tasks == remote_pending
      refute Enum.any?(socket.assigns.running_tasks, &(&1.id == "local-running"))

      # Warm remote → no mount fetch (assign_node/2's context-change reload is
      # the single source of remote fetches).
      refute_receive {:node_aware_active_tasks, _, _, _, _}, 150
    end

    test "a PENDING remote mount seeds [] — the local snapshot never leaks into the pending key" do
      # target-pending is saved but NOT connected (no manager registered) →
      # resolve_node_context returns {:pending, target} → context key
      # {"target-pending", node()}, distinct from the local {nil, node()} key.
      save_target!("target-pending")

      EvoDash.ActiveTasks.put(nil, node(), [%{id: "local-only", status: :running}], [])

      assert {:cont, socket} =
               NodeAware.on_mount(
                 :default,
                 %{"node" => "target-pending"},
                 %{},
                 connected_mount_socket()
               )

      # The hub is cold for the pending key → seeds [] — local tasks stay hidden.
      assert socket.assigns.running_tasks == []
      assert socket.assigns.pending_tasks == []
      refute_receive {:node_aware_active_tasks, _, _, _, _}, 150
    end

    test "an unknown node param (local fallback) with a cold hub seeds [] on the dead render" do
      # resolve_node_context("unknown-id") → :local (target not found) — with
      # an empty hub the local context seeds [] and the dead render never
      # queries the registry.
      assert {:cont, socket} =
               NodeAware.on_mount(:default, %{"node" => "unknown-id"}, %{}, mount_socket())

      assert socket.assigns.current_node_id == nil
      assert socket.assigns.running_tasks == []
      assert socket.assigns.pending_tasks == []
      refute_receive {:node_aware_active_tasks, _, _, _, _}, 150
    end
  end

  describe "on_mount/4 — connected-mount conditional fetch (cold LOCAL fetches; warm does not)" do
    # The connected-mount fetch is CONDITIONAL on a cold LOCAL context
    # ({nil, node()} with no hub snapshot): a cold start still queries the
    # registry so the sidebar populates, while a warm local hub renders
    # last-known state instead (the push-based PubSub cycle keeps it fresh) —
    # no redundant mount query. Remote/pending pages NEVER fetch on mount (the
    # fetch would target the pre-assign_node LOCAL assigns; assign_node/2's
    # context-change reload is guaranteed to fire the correct remote fetch).

    setup :setup_isolated_registry
    setup :isolate_config_dir

    test "cold LOCAL hub on a CONNECTED mount spawns the async fetch (cold start)" do
      # The hub is empty after the per-test reset — a connected local mount
      # must fire the fetch. The isolated registry holds no tasks → the
      # payload is empty lists, but the MESSAGE must arrive for the local
      # context.
      assert {:cont, socket} = NodeAware.on_mount(:default, %{}, %{}, connected_mount_socket())

      # Seeds first (cold → empty), then the async fetch fires.
      assert socket.assigns.running_tasks == []
      assert socket.assigns.pending_tasks == []

      local_node = node()
      assert_receive {:node_aware_active_tasks, 1, nil, ^local_node, {running, pending}}, 1000
      assert running == []
      assert pending == []
    end

    test "warm LOCAL hub on a CONNECTED mount seeds synchronously and does NOT re-fetch" do
      running = [%{id: "warm-running", status: :running}]
      pending = [%{id: "warm-pending", status: :completed, branch_name: "warm-b"}]
      EvoDash.ActiveTasks.put(nil, node(), running, pending)

      assert {:cont, socket} = NodeAware.on_mount(:default, %{}, %{}, connected_mount_socket())

      assert socket.assigns.running_tasks == running
      assert socket.assigns.pending_tasks == pending

      # Warm → no redundant mount query.
      refute_receive {:node_aware_active_tasks, _, _, _, _}, 150
    end
  end

  describe "handle_tasks_result/2 — applied results write the hub; stale never do" do
    # handle_tasks_result/2 is the testable stale-guard seam of the attached
    # :handle_info hook. Every APPLIED result (matching seq + node context)
    # ALSO writes the EvoDash.ActiveTasks hub — keyed by the MESSAGE's own
    # node context (the authoritative context of the fetch) — so a remounting
    # LiveView on that context seeds last-known state. Stale/dropped results
    # (superseded seq, or a node context that no longer matches the socket
    # assigns after a mid-flight switch) NEVER write the hub.

    test "an applied result (matching seq + node context) writes the hub under the message's context" do
      # A remote context key — proves the write is keyed by the message's node
      # context, not by any local default.
      remote_node = :"hub_remote_a@127.0.0.1"
      running = [%{id: "applied-running", status: :running}]
      pending = [%{id: "applied-pending", status: :completed, branch_name: "applied-b"}]

      sock = socket(%{current_node: remote_node, current_node_id: "target-1", tasks_load_seq: 2})

      result =
        NodeAware.handle_tasks_result(
          sock,
          {:node_aware_active_tasks, 2, "target-1", remote_node, {running, pending}}
        )

      assert result.assigns.running_tasks == running
      assert result.assigns.pending_tasks == pending
      assert EvoDash.ActiveTasks.get("target-1", remote_node) == {:ok, {running, pending}}
    end

    test "a stale result (superseded seq) is dropped and never writes the hub" do
      remote_node = :"hub_remote_b@127.0.0.1"
      sock = socket(%{current_node: remote_node, current_node_id: "target-1", tasks_load_seq: 4})

      result =
        NodeAware.handle_tasks_result(
          sock,
          {:node_aware_active_tasks, 2, "target-1", remote_node, {[%{id: "stale"}], []}}
        )

      assert result == sock
      assert EvoDash.ActiveTasks.get("target-1", remote_node) == :empty
    end

    test "a stale result (node context no longer matches) is dropped and never writes the hub" do
      # The socket is viewing a DIFFERENT context than the in-flight fetch's —
      # the user switched nodes mid-flight.
      sock = socket(%{current_node: node(), current_node_id: nil, tasks_load_seq: 1})

      result =
        NodeAware.handle_tasks_result(
          sock,
          {:node_aware_active_tasks, 1, "other-target", :"other_remote@127.0.0.1",
           {[%{id: "stale"}], []}}
        )

      assert result == sock
      assert EvoDash.ActiveTasks.get("other-target", :"other_remote@127.0.0.1") == :empty
      # The socket's own (local) context is also untouched by the stale write.
      assert EvoDash.ActiveTasks.get(nil, node()) == :empty
    end
  end

  describe "assign_node/2 — node switch to an unseen (cold-hub) connected remote still fetches" do
    # The mount-time fetch never fires for remote contexts (it would target the
    # pre-assign_node LOCAL assigns), so a cold REMOTE context must always be
    # fetched by assign_node/2's context-change reload on the first
    # handle_params — its dedup guard is :tasks_node_loaded, never the hub. A
    # warm remote hub makes that first render instant, but the reload heals any
    # gap; this pins that the reload fires for an UNSEEN (hub-cold) remote
    # context with the correct node_id/node in the fetch message.

    setup :setup_isolated_registry
    setup :isolate_config_dir

    setup do
      save_target!("target-2")
      :ok
    end

    test "switching local → unseen connected remote node spawns the fetch for that context" do
      remote_node = :"genesis_remote_2@127.0.0.1"

      start_supervised!(
        {EvoDashWeb.NodeAwareTest.ConnectionManager,
         {"target-2", %{phase: :connected, node: "genesis_remote_2@127.0.0.1", last_error: nil}}}
      )

      # The hub is cold for this remote context (never fetched before).
      assert EvoDash.ActiveTasks.get("target-2", remote_node) == :empty

      sock = socket(%{current_node: node(), current_node_id: nil})

      result = NodeAware.assign_node(sock, %{"node" => "target-2"})

      # Node-context assigns are set synchronously...
      assert result.assigns[:current_node_id] == "target-2"
      assert result.assigns[:current_node] == remote_node
      assert result.assigns[:tasks_node_loaded] == {"target-2", remote_node}

      # ...and the cold-context fetch arrives for the REMOTE context.
      assert_receive {:node_aware_active_tasks, 1, "target-2", ^remote_node, {running, pending}},
                     1000

      # The RPC to the (nonexistent) remote node fails fast → empty lists.
      assert running == []
      assert pending == []
    end
  end
end

# A minimal GenServer that stands in for a real connection manager in
# `EvoGit.RemoteConnection.Registry`, so `EvoGit.RemoteConnection.status/1`
# resolves a configured status for a target id without starting any SSH
# machinery. The process dies (and its Registry entry is auto-removed) at
# test end via `start_supervised!`.
defmodule EvoDashWeb.NodeAwareTest.ConnectionManager do
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
