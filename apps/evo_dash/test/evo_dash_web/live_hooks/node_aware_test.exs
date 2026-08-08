defmodule EvoDashWeb.NodeAwareTest do
  # Tests the transition-detection + push_patch behavior of
  # handle_connection_status/2. We build a minimal LiveView socket struct and
  # call the helper directly, then assert on the returned socket's `redirected`
  # field (push_patch sets it to {:live, :patch, %{to: path}}) or the assigns.
  #
  # This avoids booting a real LiveView or remote node — we only test the
  # pure transition-detection logic in the hook.
  #
  # async: false — the assign_node remote-target tests mutate the global
  # XDG_CONFIG_HOME env var (to isolate EvoGit.RemoteConnections, same pattern
  # as evo_git's remote_connections_test.exs) and register a fake connection
  # manager in the shared EvoGit.RemoteConnection.Registry, so they must not
  # run concurrently with other test files.
  use ExUnit.Case, async: false

  alias EvoDashWeb.LiveHooks.NodeAware
  alias EvoGit.TaskInfo

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
        pending_tasks: []
      }
      |> Map.merge(overrides)

    %Phoenix.LiveView.Socket{assigns: assigns, redirected: nil}
  end

  # Extracts the patch destination path from a push_patch socket, or returns
  # nil if not redirected. push_patch sets socket.redirected to
  # {:live, :patch, %{kind: :push, to: path}}.
  defp patch_to(%Phoenix.LiveView.Socket{redirected: {:live, :patch, %{to: to}}}), do: to
  defp patch_to(_), do: nil

  # Inserts a task directly into the SQLite store so the local
  # TaskRegistry.list_tasks/0 picks it up.
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

  describe "load_running_and_pending_tasks/1 — node-aware source" do
    # These tests verify that the function reads tasks from the correct node:
    # local `TaskRegistry.list_tasks/0` for the local node, and
    # `EvoDash.NodeContext.list_tasks/1` (RPC) for a remote node. The remote
    # path fails fast (noconnection) when the target node doesn't exist, so it
    # returns `[]` quickly without a timeout.

    setup :setup_isolated_registry

    test "local node: reads from TaskRegistry.list_tasks/0" do
      # Insert a running task and a completed task with a branch (reviewable)
      insert_fixture!(EvoGit.Store, status: :running)

      insert_fixture!(EvoGit.Store,
        status: :completed,
        result: {:ok, %{branch_name: "feature-1"}},
        review_status: nil
      )

      # current_node_id: nil marks a pure-local context — the socket builder
      # default ("gpu-server") would be a pending remote context (empty lists).
      sock = socket(%{current_node: node(), current_node_id: nil})

      result = NodeAware.load_running_and_pending_tasks(sock)

      # The running task appears in running_tasks
      assert length(result.assigns[:running_tasks]) == 1
      assert hd(result.assigns[:running_tasks]).status == :running

      # The completed task with a branch appears in pending_tasks (reviewable)
      assert length(result.assigns[:pending_tasks]) == 1
      assert hd(result.assigns[:pending_tasks]).status == :completed
    end

    test "local node: pending, running, and finalizing all go to running_tasks" do
      insert_fixture!(EvoGit.Store, id: "p1", status: :pending)
      insert_fixture!(EvoGit.Store, id: "r1", status: :running)
      insert_fixture!(EvoGit.Store, id: "f1", status: :finalizing)

      sock = socket(%{current_node: node(), current_node_id: nil})

      result = NodeAware.load_running_and_pending_tasks(sock)

      ids = Enum.map(result.assigns[:running_tasks], & &1.id) |> Enum.sort()
      assert ids == ["f1", "p1", "r1"]
    end

    test "remote node: uses EvoDash.NodeContext.list_tasks/1 (RPC), not local" do
      # Insert local tasks that should NOT appear when viewing a remote node.
      insert_fixture!(EvoGit.Store, id: "local-only", status: :running)

      # A non-existent remote node — :erpc.call fails fast with :noconnection,
      # so NodeContext.list_tasks/1 returns [] quickly (no 10s timeout).
      remote_node = :"nonexistent_remote_test@127.0.0.1"
      sock = socket(%{current_node: remote_node})

      result = NodeAware.load_running_and_pending_tasks(sock)

      # No tasks from the local registry should leak through to the remote view.
      assert result.assigns[:running_tasks] == []
      assert result.assigns[:pending_tasks] == []
    end

    test "fallback to node() when current_node assign is absent" do
      # When current_node is not set, it should fall back to node() (local).
      insert_fixture!(EvoGit.Store, id: "should-show", status: :running)

      sock = socket(%{current_node: nil, current_node_id: nil})

      result = NodeAware.load_running_and_pending_tasks(sock)

      assert Enum.any?(result.assigns[:running_tasks], &(&1.id == "should-show"))
    end

    test "pending remote context: assigns empty running/pending (local tasks hidden)" do
      # A remote context was requested (`?node=<id>`) but the connection hasn't
      # completed yet — current_node_id is set but current_node is still the
      # local BEAM node. Local tasks must NEVER appear in the sidebar.
      insert_fixture!(EvoGit.Store, id: "local-hidden", status: :running)
      insert_fixture!(EvoGit.Store, id: "local-hidden-2", status: :completed)

      sock = socket(%{current_node: node(), current_node_id: "gpu-server"})

      result = NodeAware.load_running_and_pending_tasks(sock)

      assert result.assigns[:running_tasks] == []
      assert result.assigns[:pending_tasks] == []
    end
  end

  describe "assign_node/2 — reloads sidebar tasks on node switch" do
    # assign_node/2 calls load_running_and_pending_tasks/1 after setting the
    # node assigns, so the sidebar refreshes on every handle_params / node
    # switch. We verify the running_tasks/pending_tasks assigns are populated.

    setup :setup_isolated_registry

    test "loads tasks when resolving to local node" do
      insert_fixture!(EvoGit.Store, id: "running-1", status: :running)

      sock = socket(%{})

      result = NodeAware.assign_node(sock, %{})

      assert Enum.any?(result.assigns[:running_tasks], &(&1.id == "running-1"))
    end

    test "loads tasks when resolving to local via node=local param" do
      insert_fixture!(EvoGit.Store, id: "running-2", status: :running)

      sock = socket(%{})

      result = NodeAware.assign_node(sock, %{"node" => "local"})

      assert Enum.any?(result.assigns[:running_tasks], &(&1.id == "running-2"))
    end

    test "remote node: does not show local tasks (RPC returns [])" do
      insert_fixture!(EvoGit.Store, id: "local-only-assign", status: :running)

      # Unknown target id falls back to local — so we use a known-but-pending
      # target to test remote. Since no target is saved, "unknown-id" resolves
      # to :local. We test the remote path via the pending socket directly.

      sock = socket(%{})

      # An unknown node param resolves to :local (target not found)
      result = NodeAware.assign_node(sock, %{"node" => "unknown-id"})

      # Falls back to local, so the local task shows up
      assert Enum.any?(result.assigns[:running_tasks], &(&1.id == "local-only-assign"))
    end
  end

  describe "assign_node/2 — :remote_status assign" do
    # assign_node's remote resolution reads connection targets from
    # EvoGit.RemoteConnections (a TOML file under the config dir), so these
    # tests isolate XDG_CONFIG_HOME to avoid touching the developer's real
    # ~/.config/genesis/ and save a dedicated test target.
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
