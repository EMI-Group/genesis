# A minimal GenServer that stands in for a real connection manager in
# `EvoGit.RemoteConnection.Registry`, so `EvoGit.RemoteConnection.status/1`
# resolves a configured status for a target id without starting any SSH
# machinery. The process dies (and its Registry entry is auto-removed) at
# test end via `start_supervised!`.
#
# Defined FIRST in this file: an `async: true` test module starts running as
# soon as it is registered by the compiler, so a fake defined further down
# would not be loaded yet when the async tests call `start_supervised!/1`.
#
# Start args: `{target_id, status}` (status-only manager, kept for existing
# call sites), or `{target_id, status, connect_result}` where `connect_result`
# is what `handle_call(:connect, ...)` replies with (default
# `{:ok, :connecting}`, e.g. `{:ok, :connected}` or `{:error, reason}`).
#
# `:connect` records `{:connect, caller_pid}` (`elem(from, 0)`) in a `calls`
# list — BEFORE replying, so a polling test observes the caller even after the
# spawned Task has exited — and leaves the stored status untouched; tests drive
# phase transitions explicitly via `{:set_status, status}` (no broadcast).
# Getters: `:status` (current stored status), `:calls` (recorded
# `{:connect, pid}` entries), and `:callers` (just the recorded pids).
defmodule EvoDashWeb.NodeAwareTest.ConnectionManager do
  use GenServer

  def start_link(args) do
    GenServer.start_link(__MODULE__, args)
  end

  @impl true
  def init({target_id, status}) do
    init({target_id, status, {:ok, :connecting}})
  end

  def init({target_id, status, connect_result}) do
    Registry.register(EvoGit.RemoteConnection.Registry, target_id, :status)

    {:ok,
     %{
       target_id: target_id,
       status: status,
       connect_result: connect_result,
       calls: []
     }}
  end

  @impl true
  def handle_call(:status, _from, state), do: {:reply, state.status, state}

  def handle_call(:connect, from, state) do
    caller = elem(from, 0)

    {:reply, state.connect_result, %{state | calls: [{:connect, caller} | state.calls]}}
  end

  def handle_call({:set_status, status}, _from, state) do
    {:reply, :ok, %{state | status: status}}
  end

  def handle_call(:calls, _from, state), do: {:reply, Enum.reverse(state.calls), state}

  def handle_call(:callers, _from, state) do
    callers = Enum.map(state.calls, fn {_call, pid} -> pid end)
    {:reply, Enum.reverse(callers), state}
  end
end

defmodule EvoDashWeb.NodeAwareRunWideTest do
  # NodeAware hook tests that mutate NO process-global, so they run
  # `async: true`.
  #
  # ISOLATION TECHNIQUE — the run-wide store + unique fixtures: every task a
  # test needs is inserted into the RUN-WIDE per-run sqlite store (`EvoGit.Store`,
  # started once for the whole run and never terminated) under a per-test unique
  # id, deleted again from `on_exit`, and every assertion is scoped through
  # `mine/2` to the ids THIS test inserted — never to the store's global
  # contents, which the other async suites also use.
  #
  # Sidebar loads are ASYNC: `load_running_and_pending_tasks/1` / `assign_node/2`
  # spawn a fetch on `EvoDash.TaskSupervisor` whose captured `view_pid` IS the
  # test process, so tests assert on the tagged
  # `{:node_aware_active_tasks, seq, node_id, node, {:ok, {running, pending}} |
  # {:error, reason}}` message (`assert_receive`/`refute_receive`), and the
  # stale-guard seam `handle_tasks_result/2` is exercised as a pure socket
  # in/out function.
  #
  # The fake ConnectionManager registers in the SHARED
  # `EvoGit.RemoteConnection.Registry`, but only under target ids unique to this
  # file, so no concurrently running suite can resolve one.
  #
  # Everything that must MUTATE a process-global — `XDG_CONFIG_HOME`, the
  # LOCAL `EvoDash.ActiveTasks` hub key, the `EvoGit.TaskRegistry` name, the
  # production Store/TaskRegistry pair — lives in the `async: false`
  # `EvoDashWeb.NodeAwareTest` module below.
  use ExUnit.Case, async: true

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
        remote_targets: [],
        remote_context_seq: 0,
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

  # Inserts a task DIRECTLY into the run-wide store under a per-test unique id,
  # and registers its removal in `on_exit` as a direct Store delete (never a
  # `TaskRegistry` cast, so no broadcast can reach a concurrently running
  # suite). Returns the task so tests reference `task.id` instead of a literal.
  defp insert_fixture!(overrides) do
    id = "fixture_#{System.unique_integer([:positive])}"
    on_exit(fn -> EvoGit.Store.delete_task(EvoGit.Store, id) end)

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

    EvoGit.Store.put_task(EvoGit.Store, task)
    task
  end

  # The summaries of THIS test's fixture ids, in the given bucket. Every
  # classification assertion goes through it: filtering keeps the assertion
  # exact for the rows this test owns while the run-wide store also carries
  # other async suites' rows.
  defp mine(summaries, ids) when is_list(ids), do: Enum.filter(summaries, &(&1.id in ids))

  describe "handle_connection_status/2 — recomputes :remote_status" do
    # A fake connection manager is registered in the shared
    # EvoGit.RemoteConnection.Registry under a target id unique to this file, so
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

  describe "load_running_and_pending_tasks/1 — node-aware source" do
    # These tests verify that the function spawns an async fetch from the
    # correct node: local `TaskRegistry.list_tasks_summary([:running, :pending,
    # :finalizing, :cancelling, :completed])` for the local node, and
    # `EvoDash.NodeContext.list_tasks_summary(node, statuses)` (RPC) for a
    # remote node. The spawned task's captured `view_pid` IS the test process,
    # so the assertions use `assert_receive {:node_aware_active_tasks, seq,
    # node_id, node, {:ok, {running, pending}}}` on the message payload (the
    # socket itself comes back unchanged — the load is async). The remote path
    # fails fast (noconnection) when the target node doesn't exist, so it
    # returns [] quickly without a timeout.

    test "local node: reads from TaskRegistry.list_tasks_summary/1" do
      # A running task and a completed task with a branch (reviewable)
      running_task = insert_fixture!(status: :running)
      reviewable = insert_fixture!(status: :completed, result: {:ok, %{branch_name: "feature-1"}})

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

      assert_receive {:node_aware_active_tasks, 1, nil, ^current_node, {:ok, {running, pending}}},
                     1000

      # Each fixture lands in exactly ONE bucket — the correct one.
      assert [%{status: :running}] = mine(running, [running_task.id])
      assert mine(pending, [running_task.id]) == []

      assert [%{status: :completed}] = mine(pending, [reviewable.id])
      assert mine(running, [reviewable.id]) == []
    end

    test "local node: pending, running, and finalizing all go to running_tasks" do
      p1 = insert_fixture!(status: :pending)
      r1 = insert_fixture!(status: :running)
      f1 = insert_fixture!(status: :finalizing)
      ids = [p1.id, r1.id, f1.id]

      current_node = node()
      sock = socket(%{current_node: current_node, current_node_id: nil})

      NodeAware.load_running_and_pending_tasks(sock)

      assert_receive {:node_aware_active_tasks, 1, nil, ^current_node, {:ok, {running, pending}}},
                     1000

      ids_in_running = running |> mine(ids) |> Enum.map(& &1.id) |> Enum.sort()
      assert ids_in_running == Enum.sort(ids)
      assert mine(pending, ids) == []
    end

    test "local node: a :cancelling task shows in running_tasks" do
      # :cancelling is non-terminal — the task stays visible in the sidebar
      # while it winds down, so it must land in running_tasks. finished_at must
      # be nil for in-flight statuses (the fixture helper defaults it to now).
      c1 = insert_fixture!(status: :cancelling, finished_at: nil)

      current_node = node()
      sock = socket(%{current_node: current_node, current_node_id: nil})

      NodeAware.load_running_and_pending_tasks(sock)

      assert_receive {:node_aware_active_tasks, 1, nil, ^current_node, {:ok, {running, pending}}},
                     1000

      assert [%{status: :cancelling}] = mine(running, [c1.id])
      assert mine(pending, [c1.id]) == []
    end

    test "remote node: uses EvoDash.NodeContext.list_tasks_summary/2 (RPC), not local" do
      # Insert a local task that must NOT appear when viewing a remote node.
      insert_fixture!(status: :running)

      # A non-existent remote node — :erpc.call fails fast with :noconnection,
      # so NodeContext.list_tasks_summary/2 returns [] quickly (no 10s timeout),
      # whatever the local store holds.
      remote_node = :"nonexistent_remote_test@127.0.0.1"
      sock = socket(%{current_node: remote_node})

      NodeAware.load_running_and_pending_tasks(sock)

      assert_receive {:node_aware_active_tasks, 1, "gpu-server", ^remote_node,
                      {:ok, {running, pending}}},
                     1000

      # No tasks from the local registry should leak through to the remote view.
      assert running == []
      assert pending == []
    end

    test "fallback to node() when current_node assign is absent" do
      # When current_node is not set, it should fall back to node() (local).
      should_show = insert_fixture!(status: :running)

      current_node = node()
      sock = socket(%{current_node: nil, current_node_id: nil})

      NodeAware.load_running_and_pending_tasks(sock)

      assert_receive {:node_aware_active_tasks, 1, nil, ^current_node,
                      {:ok, {running, _pending}}},
                     1000

      assert [%{status: :running}] = mine(running, [should_show.id])
    end

    test "pending remote context: assigns empty running/pending (local tasks hidden)" do
      # A remote context was requested (`?node=<id>`) but the connection hasn't
      # completed yet — current_node_id is set but current_node is still the
      # local BEAM node. Local tasks must NEVER appear in the sidebar. The
      # guard short-circuits BEFORE any store read, so the empty lists hold
      # whatever else the run-wide store contains.
      insert_fixture!(status: :running)
      insert_fixture!(status: :completed)

      current_node = node()
      sock = socket(%{current_node: current_node, current_node_id: "gpu-server"})

      NodeAware.load_running_and_pending_tasks(sock)

      assert_receive {:node_aware_active_tasks, 1, "gpu-server", ^current_node,
                      {:ok, {running, pending}}},
                     1000

      assert running == []
      assert pending == []
    end
  end

  describe "assign_node/2 — reloads sidebar tasks on node switch" do
    # assign_node/2 sets the node-context assigns synchronously and triggers the
    # ASYNC sidebar load after them (dedup-guarded by :tasks_node_loaded). The
    # spawned task's captured view_pid IS the test process, so we assert on the
    # `{:node_aware_active_tasks, seq, node_id, node, {:ok, {running, pending}}}`
    # message payload instead of the returned socket's assigns.

    test "loads tasks when resolving to local node" do
      running_1 = insert_fixture!(status: :running)

      current_node = node()
      sock = socket(%{current_node: current_node, current_node_id: nil})

      result = NodeAware.assign_node(sock, %{})

      # Node-context assigns are set synchronously...
      assert result.assigns[:current_node_id] == nil
      assert result.assigns[:current_node] == current_node
      assert result.assigns[:tasks_node_loaded] == {nil, current_node}

      # ...and the sidebar load arrives asynchronously.
      assert_receive {:node_aware_active_tasks, 1, nil, ^current_node, {:ok, {running, pending}}},
                     1000

      assert [%{status: :running}] = mine(running, [running_1.id])
      assert mine(pending, [running_1.id]) == []
    end

    test "loads tasks when resolving to local via node=local param" do
      running_2 = insert_fixture!(status: :running)

      current_node = node()
      sock = socket(%{current_node: current_node, current_node_id: nil})

      NodeAware.assign_node(sock, %{"node" => "local"})

      assert_receive {:node_aware_active_tasks, 1, nil, ^current_node,
                      {:ok, {running, _pending}}},
                     1000

      assert [%{status: :running}] = mine(running, [running_2.id])
    end

    test "unknown node param falls back to local and loads local tasks" do
      local_only = insert_fixture!(status: :running)

      current_node = node()
      sock = socket(%{current_node: current_node, current_node_id: nil})

      NodeAware.assign_node(sock, %{"node" => "unknown-id"})

      # An unknown node param resolves to :local (target not found), so the
      # local task shows up.
      assert_receive {:node_aware_active_tasks, 1, nil, ^current_node,
                      {:ok, {running, _pending}}},
                     1000

      assert [%{status: :running}] = mine(running, [local_only.id])
    end
  end

  describe "async sidebar delivery + stale-guard" do
    # End-to-end async pipeline: load → `{:node_aware_active_tasks, ...}`
    # message → `handle_tasks_result/2` (the attached `:handle_info` hook's
    # stale-guard seam) → assigns. NOTE: an APPLIED local result also writes the
    # LOCAL `EvoDash.ActiveTasks` key — tolerated here because no concurrently
    # running suite asserts on that key's contents (agents_live_test and
    # guide_test only ever render whatever rows it holds).

    test "async delivery populates the sidebar (previous content kept until the result arrives)" do
      running_task = insert_fixture!(status: :running)
      reviewable = insert_fixture!(status: :completed, result: {:ok, %{branch_name: "feature-1"}})

      current_node = node()
      sock = socket(%{current_node: current_node, current_node_id: nil})

      result = NodeAware.load_running_and_pending_tasks(sock)

      # The socket is returned unchanged — previous sidebar content stays
      # visible until the fresh result arrives.
      assert result.assigns[:running_tasks] == []
      assert result.assigns[:pending_tasks] == []

      assert_receive {:node_aware_active_tasks, 1, nil, ^current_node, {:ok, {running, pending}}},
                     1000

      assert [%{status: :running}] = mine(running, [running_task.id])
      assert [%{status: :completed}] = mine(pending, [reviewable.id])
      assert mine(running, [reviewable.id]) == []

      # Applying the message through the stale-guard populates the assigns.
      socket =
        NodeAware.handle_tasks_result(
          result,
          {:node_aware_active_tasks, 1, nil, current_node, {:ok, {running, pending}}}
        )

      assert [%{status: :running}] = mine(socket.assigns[:running_tasks], [running_task.id])
      assert [%{status: :completed}] = mine(socket.assigns[:pending_tasks], [reviewable.id])
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
           {:ok, {[%{id: "stale"}], []}}}
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
          {:node_aware_active_tasks, 2, nil, current_node, {:ok, {[%{id: "stale"}], []}}}
        )

      assert result.assigns[:running_tasks] == [%{id: "keep"}]
      assert result.assigns[:pending_tasks] == []
    end

    test "node switch triggers a fresh load; same context does not re-spawn" do
      running_1 = insert_fixture!(status: :running)

      current_node = node()
      sock = socket(%{current_node: current_node, current_node_id: nil})

      # First assign_node with the local context spawns a load.
      result = NodeAware.assign_node(sock, %{})
      assert result.assigns[:tasks_node_loaded] == {nil, current_node}

      assert_receive {:node_aware_active_tasks, 1, nil, ^current_node,
                      {:ok, {running, _pending}}},
                     1000

      assert [%{status: :running}] = mine(running, [running_1.id])

      # A second assign_node with the SAME context must NOT re-spawn (the
      # :tasks_node_loaded dedup guard skips it — the seq stays 1, so no new
      # fetch was spawned and no message can arrive).
      second = NodeAware.assign_node(result, %{})
      assert second.assigns[:tasks_load_seq] == 1

      # Belt-and-braces only: the seq backstop above deterministically proves
      # no spawn, so no message can ever be in flight (hence the 0 ms window —
      # the backstop, not the wait, is the evidence).
      refute_receive {:node_aware_active_tasks, _, _, _, _}, 0
    end
  end

  describe "handle_tasks_result/2 — an applied REMOTE result writes the hub; a stale one never does" do
    # handle_tasks_result/2 is the testable stale-guard seam of the attached
    # :handle_info hook. Every APPLIED result (matching seq + node context)
    # ALSO writes the EvoDash.ActiveTasks hub — keyed by the MESSAGE's own node
    # context (the authoritative context of the fetch) — so a remounting
    # LiveView on that context seeds last-known state. Stale/dropped results
    # NEVER write the hub.
    #
    # Only the REMOTE-context half lives here: each test keys the hub by its own
    # per-test UNIQUE context, which no other suite can touch. The
    # local-context half (a stale write must leave the LOCAL key cold) stays in
    # the `async: false` module — every concurrently mounting page writes that
    # key.

    test "an applied result (matching seq + node context) writes the hub under the message's context" do
      # A remote context key — proves the write is keyed by the message's node
      # context, not by any local default.
      target = "hub-target-#{System.unique_integer([:positive])}"
      remote_node = :"hub_remote_#{System.unique_integer([:positive])}@127.0.0.1"
      running = [%{id: "applied-running", status: :running}]
      pending = [%{id: "applied-pending", status: :completed, branch_name: "applied-b"}]

      sock = socket(%{current_node: remote_node, current_node_id: target, tasks_load_seq: 2})

      result =
        NodeAware.handle_tasks_result(
          sock,
          {:node_aware_active_tasks, 2, target, remote_node, {:ok, {running, pending}}}
        )

      assert result.assigns.running_tasks == running
      assert result.assigns.pending_tasks == pending
      assert EvoDash.ActiveTasks.get(target, remote_node) == {:ok, {running, pending}}
    end

    test "a stale result (superseded seq) is dropped and never writes the hub" do
      target = "hub-target-#{System.unique_integer([:positive])}"
      remote_node = :"hub_remote_#{System.unique_integer([:positive])}@127.0.0.1"
      sock = socket(%{current_node: remote_node, current_node_id: target, tasks_load_seq: 4})

      result =
        NodeAware.handle_tasks_result(
          sock,
          {:node_aware_active_tasks, 2, target, remote_node, {:ok, {[%{id: "stale"}], []}}}
        )

      assert result == sock
      assert EvoDash.ActiveTasks.get(target, remote_node) == :empty
    end
  end
end

defmodule EvoDashWeb.NodeAwareTest do
  # NodeAware hook tests that MUST mutate a process-global, so they run
  # `async: false`:
  #
  #   * `XDG_CONFIG_HOME` (`isolate_config_dir/1`) — process-global with NO
  #     app-env seam (`EvoGit.Platform.base_dir/3` reads it at call time), so a
  #     suite that WRITES a connection target must not overlap another module's
  #     config reads.
  #   * the LOCAL `EvoDash.ActiveTasks` hub key (`{nil, node()}`) — every
  #     concurrently mounting page seeds AND writes it, so only a sync suite can
  #     assert it is cold.
  #   * the `EvoGit.TaskRegistry` NAME — one test unregisters it to make a
  #     `GenServer.call` EXIT deterministic.
  #   * `EvoDash.Test.IsolatedTaskStore.isolate!/1` — terminates the
  #     process-global Store/TaskRegistry pair, for the describes whose
  #     assertions depend on a store that holds NOTHING.
  #
  # These describes invoke `on_mount/4` directly on a boot-shaped socket
  # (`mount_socket/1` = dead render, `connected_mount_socket/1` = connected) and
  # pin the sidebar no-blink / no-leak / staleness-catch-up contract plus the
  # hub-write rules (details on each describe). A connected mount also spawns
  # ONE node-context load, consumed explicitly via
  # `assert_remote_context_loaded/0` so it never leaks into a bare
  # `assert_receive`.
  use ExUnit.Case, async: false

  alias EvoDashWeb.LiveHooks.NodeAware

  setup do
    # Reset the shared EvoDash.ActiveTasks hub (a boot-created named ETS table
    # shared by every evo_dash suite in the OS process — same isolation pattern
    # as home_live_test's ChatHistory reset) so a warm local snapshot can never
    # leak into the next test's hub-exactness assertion.
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
        remote_targets: [],
        remote_context_seq: 0,
        running_tasks: [],
        pending_tasks: [],
        tasks_load_seq: 0,
        tasks_reload_pending: false
      }
      |> Map.merge(overrides)

    %Phoenix.LiveView.Socket{assigns: assigns, redirected: nil}
  end

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
  # `transport_pid != nil`, so a non-nil transport_pid fakes a connected mount.
  # on_mount/4 also needs the boot-time :lifecycle private key (attach_hook/4).
  defp connected_mount_socket(overrides \\ %{}) do
    %{mount_socket(overrides) | transport_pid: self()}
  end

  # Consumes the connected-mount node-context load result
  # (`{:node_aware_remote_context, seq, node_id, node,
  #   {:ok, {targets, statuses}} | {:error, reason}}`) that `on_mount/4` spawns
  # on EVERY connected mount (never on a dead render). Returns the payload
  # result. Tests that only care about the sidebar still call this so the
  # message never lingers in the test process's mailbox.
  defp assert_remote_context_loaded do
    assert_receive {:node_aware_remote_context, 1, _node_id, _node, result}, 1000
    result
  end

  # Saves a connection target into the (per-test isolated) config dir so
  # remote/pending `?node=` resolution finds it.
  defp save_target!(id, ssh_target \\ "test-host") do
    {:ok, target} = EvoGit.RemoteConnections.save(%{ssh_target: ssh_target, id: id})
    target
  end

  # Sets up an isolated Store + TaskRegistry against a temp sqlite file. The
  # helper owns teardown: it stops the isolated pair FIRST, then restores and
  # VERIFIES the production children. Used by describe blocks that need a real
  # TaskRegistry backing the local node path.
  def setup_isolated_registry(_context) do
    :ok = EvoDash.Test.IsolatedTaskStore.isolate!("node_aware")
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

  # The `EvoDash.TaskSupervisor` children spawned by `owner` — `Task.Supervisor`
  # records the spawning process in each child's `:"$callers"` process-dictionary
  # entry (same idiom as tasks_live_test.exs's drain helpers), so this lists
  # exactly the async work `owner` started. `Task.Supervisor.start_child/2` is
  # a synchronous call, so the child is already visible when the spawning
  # function returns: an empty list right after a call deterministically proves
  # NO spawn.
  defp spawned_view_tasks(owner) when is_pid(owner) do
    EvoDash.TaskSupervisor
    |> Task.Supervisor.children()
    |> Enum.filter(fn
      pid when is_pid(pid) ->
        case Process.info(pid, :dictionary) do
          {:dictionary, dict} -> owner in Keyword.get(dict, :"$callers", [])
          nil -> false
        end

      _other ->
        false
    end)
  end

  # Polls `fun` every 1ms until it returns truthy or the timeout (default
  # 2000ms) elapses. Used to observe the fake ConnectionManager's recorded
  # calls without fixed sleeps — the spawned connect Task's timing is
  # nondeterministic. The 1 ms tick only bounds how long a satisfied predicate
  # takes to be noticed (the deadline, not the tick, is the safety margin).
  defp await_until(fun, timeout \\ 2000) do
    deadline = System.monotonic_time(:millisecond) + timeout
    await_until_loop(fun, deadline, timeout)
  end

  defp await_until_loop(fun, deadline, timeout) do
    cond do
      fun.() ->
        :ok

      System.monotonic_time(:millisecond) >= deadline ->
        flunk("await_until/2 did not become true within #{timeout}ms")

      true ->
        Process.sleep(1)
        await_until_loop(fun, deadline, timeout)
    end
  end

  describe "assign_node/2 — :remote_status assign" do
    # assign_node's remote resolution reads connection targets from
    # EvoGit.RemoteConnections (a TOML file under the config dir), so these
    # tests isolate XDG_CONFIG_HOME to avoid touching the developer's real
    # ~/.config/genesis/ and save a dedicated test target — a config WRITE,
    # hence async: false even for the two tests that only read.
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

  describe "on_mount/4 — hub-seeded sidebar: no-blink / no-leak / no-remote-mount-fetch" do
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
    # * remote/pending pages NEVER fetch on mount (a mount fetch would query
    #   the pre-assign_node LOCAL assigns; assign_node/2's context-change
    #   reload fires their one correct fetch), and dead renders never query
    #   at all. LOCAL pages DO fetch on every connected mount — the
    #   staleness catch-up covered in the next describe.
    #
    # async: false — the LOCAL-key seed assertions here are exact, and the
    # config dir is isolated per test (`save_target!` writes it) because
    # resolve_node_context reads remote_connections.toml.
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

      # Nothing is spawned on the dead render — the seq backstop proves it
      # deterministically (no fetch was spawned, so no message can arrive).
      assert socket.assigns[:tasks_load_seq] == 0
      refute_receive {:node_aware_active_tasks, _, _, _, _}, 0
    end

    test "a malformed hub snapshot is SANITIZED on the mount seed (non-maps dropped)" do
      # The hub is shape-agnostic and lives outside this node, so a stored
      # snapshot may carry non-map entries (e.g. written by an older/foreign
      # writer). The mount seed must sanitize on read — a non-map entry would
      # otherwise reach Layouts.app/1's group_tasks_by_project/2 and raise
      # BadMapError on project_path dot-access.
      valid_map = %{status: :running, project_path: "/tmp/proj"}

      EvoDash.ActiveTasks.put(nil, node(), [:c, valid_map], [])

      assert {:cont, socket} = NodeAware.on_mount(:default, %{}, %{}, mount_socket())

      assert socket.assigns.running_tasks == [valid_map]
      assert socket.assigns.pending_tasks == []

      # Dead render → still no mount fetch (the seq backstop proves it).
      assert socket.assigns[:tasks_load_seq] == 0
      refute_receive {:node_aware_active_tasks, _, _, _, _}, 0
    end

    test "a stored {[], []} snapshot for a PENDING context seeds [] and still renders (no crash, no leak)" do
      # A pending-remote context whose last fetch applied {[], []} (the
      # pending-remote guard's empty result). Stored-empty IS a real snapshot
      # — get/3 returns {:ok, {[], []}} — so a remount seeds [] rather than
      # crashing, leaking another context's data, or re-fetching (pending
      # pages never fetch on mount — assign_node/2's context-change reload
      # is their one correct fetch).
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

      # The connected mount still runs its ONE node-context load (node-
      # independent bookkeeping) — consumed here so it never lingers.
      assert {:ok, {_targets, _statuses}} = assert_remote_context_loaded()

      # Pending context → no mount fetch (the seq backstop proves it).
      assert socket.assigns[:tasks_load_seq] == 0
      refute_receive {:node_aware_active_tasks, _, _, _, _}, 0
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

      # Connected mount → the node-context load runs (consumed here).
      assert {:ok, {_targets, _statuses}} = assert_remote_context_loaded()

      # Remote context → no mount fetch (assign_node/2's context-change reload
      # is the single source of remote fetches; the seq backstop proves it).
      assert socket.assigns[:tasks_load_seq] == 0
      refute_receive {:node_aware_active_tasks, _, _, _, _}, 0
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

      # Connected mount → the node-context load runs (consumed here).
      assert {:ok, {_targets, _statuses}} = assert_remote_context_loaded()

      assert socket.assigns[:tasks_load_seq] == 0
      refute_receive {:node_aware_active_tasks, _, _, _, _}, 0
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
      # Dead render → no mount fetch (the seq backstop proves it).
      assert socket.assigns[:tasks_load_seq] == 0
      refute_receive {:node_aware_active_tasks, _, _, _, _}, 0
    end
  end

  describe "on_mount/4 — connected-mount LOCAL fetch is unconditional (staleness catch-up)" do
    # The connected-mount fetch fires on EVERY connected LOCAL mount, warm hub
    # or not. Terminal task broadcasts are one-shot fire-and-forget (no replay,
    # no polling backstop), so a LiveView generation that missed the terminal
    # event leaves the hub warm-but-stale — the mount fetch is the catch-up that
    # heals it (stale-guarded apply + hub write-back). The sync hub seed still
    # paints the first render blink-free; the fresh result lands via the
    # attached :handle_info hook. Remote/pending pages NEVER fetch on mount.
    #
    # async: false — `save_target!` writes the config dir, and the payload
    # assertions require a store that holds NOTHING (the isolated pair).
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

      # The node-context load fires too (node-independent bookkeeping).
      assert {:ok, {_targets, _statuses}} = assert_remote_context_loaded()

      local_node = node()

      assert_receive {:node_aware_active_tasks, 1, nil, ^local_node, {:ok, {running, pending}}},
                     1000

      assert running == []
      assert pending == []
    end

    test "WARM but STALE hub on a connected LOCAL mount still fetches and the fresh result heals the sidebar" do
      # THE BUG REGRESSION: the hub's last snapshot shows a task as :running,
      # but the task actually ENDED and its one-shot terminal broadcast was
      # missed (tab refresh / suspended WebView during the run). The old
      # cold-only gate skipped the mount fetch on a warm hub, so every local
      # mount rendered the ended task as "running" forever. Now the mount
      # fetch runs unconditionally and its applied result corrects the lists
      # (via the attached :handle_info hook) AND the hub.
      stale_running = [%{id: "ended-task", status: :running}]
      EvoDash.ActiveTasks.put(nil, node(), stale_running, [])

      # The isolated registry holds no tasks — the task is really gone.
      assert {:cont, socket} = NodeAware.on_mount(:default, %{}, %{}, connected_mount_socket())

      # The first render is still blink-free: the stale snapshot seeds
      # synchronously, before the fresh result lands.
      assert socket.assigns.running_tasks == stale_running

      # The fetch is spawned despite the warm hub, and the fresh (empty)
      # result heals the sidebar and the hub.
      assert {:ok, {_targets, _statuses}} = assert_remote_context_loaded()

      local_node = node()

      assert_receive {:node_aware_active_tasks, 1, nil, ^local_node, {:ok, {running, pending}}},
                     1000

      assert running == []
      assert pending == []

      assert {:halt, healed} =
               NodeAware.handle_info(
                 {:node_aware_active_tasks, 1, nil, local_node, {:ok, {[], []}}},
                 socket
               )

      assert healed.assigns.running_tasks == []
      assert healed.assigns.pending_tasks == []
      assert EvoDash.ActiveTasks.get(nil, node()) == {:ok, {[], []}}
    end

    test "WARM hub with fresh data on a connected LOCAL mount still re-fetches (refresh, not just heal)" do
      # The fetch is unconditional, not freshness-aware: even a warm-and-correct
      # hub is re-verified. The seed still paints the warm snapshot first.
      running = [%{id: "warm-running", status: :running}]
      pending = [%{id: "warm-pending", status: :completed, branch_name: "warm-b"}]
      EvoDash.ActiveTasks.put(nil, node(), running, pending)

      assert {:cont, socket} = NodeAware.on_mount(:default, %{}, %{}, connected_mount_socket())

      assert socket.assigns.running_tasks == running
      assert socket.assigns.pending_tasks == pending

      assert {:ok, {_targets, _statuses}} = assert_remote_context_loaded()

      local_node = node()
      assert_receive {:node_aware_active_tasks, 1, nil, ^local_node, {:ok, _}}, 1000
    end

    test "WARM REMOTE hub on a connected REMOTE mount does NOT fetch (assign_node owns remote fetches)" do
      save_target!("target-warm")
      remote_node = :"genesis_remote_warm@127.0.0.1"

      start_supervised!(
        {EvoDashWeb.NodeAwareTest.ConnectionManager,
         {"target-warm",
          %{phase: :connected, node: "genesis_remote_warm@127.0.0.1", last_error: nil}}}
      )

      EvoDash.ActiveTasks.put(
        "target-warm",
        remote_node,
        [%{id: "remote-only", status: :running}],
        []
      )

      assert {:cont, socket} =
               NodeAware.on_mount(
                 :default,
                 %{"node" => "target-warm"},
                 %{},
                 connected_mount_socket()
               )

      # Remote context → no sidebar mount fetch, warm or cold (the seq backstop
      # proves it deterministically). The node-context load still runs.
      assert socket.assigns[:tasks_load_seq] == 0
      assert {:ok, {_targets, _statuses}} = assert_remote_context_loaded()
      refute_receive {:node_aware_active_tasks, _, _, _, _}, 0
    end

    test "warm PENDING hub on a connected PENDING mount does NOT fetch (assign_node owns pending fetches)" do
      save_target!("target-pending-warm")

      EvoDash.ActiveTasks.put(
        "target-pending-warm",
        node(),
        [%{id: "pending-seed", status: :running}],
        []
      )

      assert {:cont, socket} =
               NodeAware.on_mount(
                 :default,
                 %{"node" => "target-pending-warm"},
                 %{},
                 connected_mount_socket()
               )

      # The pending key's snapshot seeds synchronously (target id ≠ nil →
      # never the local key).
      assert socket.assigns.running_tasks == [%{id: "pending-seed", status: :running}]

      # Pending context → no sidebar mount fetch (the seq backstop proves it).
      assert socket.assigns[:tasks_load_seq] == 0
      assert {:ok, {_targets, _statuses}} = assert_remote_context_loaded()
      refute_receive {:node_aware_active_tasks, _, _, _, _}, 0
    end
  end

  describe "on_mount/4 — node-context load (`:remote_targets` / `:connection_statuses`)" do
    # The saved SSH targets + connection statuses are node-INDEPENDENT
    # bookkeeping. The dead render only seeds `[]`/`%{}` (a registry lookup can
    # block or EXIT — it must never run during the dead render); ONE connected
    # mount load refreshes both through `EvoDash.SafeCall` and sends
    # `{:node_aware_remote_context, seq, node_id, node, {:ok, {targets,
    # statuses}} | {:error, reason}}`, applied by the attached `:handle_info`
    # hook (`handle_remote_context_result/2` — seq-stale-guarded only, since a
    # node switch must not throw the target list away).
    #
    # async: false — `save_target!` writes the config dir.
    setup :isolate_config_dir

    test "the dead render spawns NO node-context load (:remote_context_seq stays 0)" do
      assert {:cont, socket} = NodeAware.on_mount(:default, %{}, %{}, mount_socket())

      # Dead-render seeds: empty bookkeeping, seq untouched → deterministically
      # no request was spawned (so no result message can arrive).
      assert socket.assigns.remote_targets == []
      assert socket.assigns.connection_statuses == %{}
      assert socket.assigns.remote_context_seq == 0
      refute_receive {:node_aware_remote_context, _, _, _, _}, 0
    end

    test "a connected mount loads the saved targets and its ok result applies both assigns" do
      save_target!("target-ctx")
      local_node = node()

      assert {:cont, socket} = NodeAware.on_mount(:default, %{}, %{}, connected_mount_socket())

      # Seeds before the async result lands.
      assert socket.assigns.remote_targets == []
      assert socket.assigns.connection_statuses == %{}
      assert socket.assigns.remote_context_seq == 1

      assert {:ok, {targets, statuses}} = assert_remote_context_loaded()
      assert Enum.any?(targets, &(&1.id == "target-ctx"))
      assert is_map(statuses)

      # Feeding the SAME tagged message through the attached hook applies it.
      assert {:halt, applied} =
               NodeAware.handle_info(
                 {:node_aware_remote_context, 1, nil, local_node, {:ok, {targets, statuses}}},
                 socket
               )

      assert Enum.any?(applied.assigns.remote_targets, &(&1.id == "target-ctx"))
      assert applied.assigns.connection_statuses == statuses
    end
  end

  describe "exit-safety — a failed fetch never crashes the hook or wedges the sidebar" do
    # `handle_tasks_result/2` keeps the last-known sidebar state on
    # `{:error, reason}` (a timed-out / dead store call — an EXIT that a
    # `rescue` cannot catch) and ALWAYS clears `:tasks_reload_pending` for an
    # APPLIED (non-stale) result, so the debounce flag can never stay set and
    # suppress every later broadcast's reload.
    #
    # async: false — these are the pure-seam tests that also assert the LOCAL
    # `EvoDash.ActiveTasks` key stays `:empty`, which only a sync suite can
    # check (any concurrently mounting page writes that key).

    test "an {:error, {:exit, _}} result through the attached hook keeps the lists and clears the flag" do
      running = [%{id: "keep-running", status: :running}]
      pending = [%{id: "keep-pending", status: :completed}]

      sock =
        socket(%{
          current_node: node(),
          current_node_id: nil,
          running_tasks: running,
          pending_tasks: pending,
          tasks_load_seq: 1,
          tasks_reload_pending: true
        })

      assert {:halt, result} =
               NodeAware.handle_info(
                 {:node_aware_active_tasks, 1, nil, node(), {:error, {:exit, :timeout}}},
                 sock
               )

      # Last-known state is kept — a failed load never empties the sidebar.
      assert result.assigns.running_tasks == running
      assert result.assigns.pending_tasks == pending
      # The fetch is over, so the debounce flag is released.
      assert result.assigns.tasks_reload_pending == false
      # A failed load is NOT last-known state — the hub stays untouched.
      assert EvoDash.ActiveTasks.get(nil, node()) == :empty
    end

    test "handle_tasks_result/2 on {:error, _} is a no-op for the lists (pure seam)" do
      running = [%{id: "keep-running", status: :running}]

      sock =
        socket(%{
          current_node: node(),
          current_node_id: nil,
          running_tasks: running,
          tasks_load_seq: 1,
          tasks_reload_pending: true
        })

      result =
        NodeAware.handle_tasks_result(
          sock,
          {:node_aware_active_tasks, 1, nil, node(), {:error, {:exit, :timeout}}}
        )

      assert result.assigns.running_tasks == running
      assert result.assigns.pending_tasks == []
      assert result.assigns.tasks_reload_pending == false
      assert EvoDash.ActiveTasks.get(nil, node()) == :empty
    end

    test "a stale (superseded-seq) result does NOT clear the newer request's debounce flag" do
      sock =
        socket(%{
          current_node: node(),
          current_node_id: nil,
          tasks_load_seq: 2,
          tasks_reload_pending: true,
          running_tasks: [%{id: "keep"}],
          pending_tasks: []
        })

      assert {:halt, result} =
               NodeAware.handle_info(
                 {:node_aware_active_tasks, 1, nil, node(), {:ok, {[%{id: "stale"}], []}}},
                 sock
               )

      # Dropped wholesale: the flag belongs to the NEWER in-flight request.
      assert result == sock
      assert result.assigns.tasks_reload_pending == true
      assert result.assigns.running_tasks == [%{id: "keep"}]
    end

    test "the legacy bare {running, pending} payload is still accepted (defensive shape)" do
      sock = socket(%{current_node: node(), current_node_id: nil, tasks_load_seq: 1})

      result =
        NodeAware.handle_tasks_result(
          sock,
          {:node_aware_active_tasks, 1, nil, node(), {[%{id: "legacy"}], []}}
        )

      assert result.assigns.running_tasks == [%{id: "legacy"}]
      assert result.assigns.pending_tasks == []
    end

    test "an {:error, _} remote-context result keeps the previous targets/statuses" do
      targets = [%{id: "prev-target", name: "Prev"}]
      statuses = %{"prev-target" => %{phase: :connected}}

      sock =
        socket(%{remote_targets: targets, connection_statuses: statuses, remote_context_seq: 1})

      assert {:halt, result} =
               NodeAware.handle_info(
                 {:node_aware_remote_context, 1, nil, node(), {:error, {:exit, :timeout}}},
                 sock
               )

      # A failed lookup must not empty the node selector / gate.
      assert result.assigns.remote_targets == targets
      assert result.assigns.connection_statuses == statuses
    end

    test "a stale remote-context result (superseded seq) is ignored" do
      targets = [%{id: "prev-target"}]
      sock = socket(%{remote_targets: targets, connection_statuses: %{}, remote_context_seq: 2})
      stale = {:ok, {[%{id: "stale"}], %{"stale" => %{phase: :error}}}}

      assert {:halt, result} =
               NodeAware.handle_info({:node_aware_remote_context, 1, nil, node(), stale}, sock)

      # Targets/statuses are node-INDEPENDENT, but a NEWER load superseded this
      # one, so it is dropped wholesale.
      assert result == sock
    end

    test "a malformed remote-context payload keeps the last-known values (never crashes)" do
      targets = [%{id: "prev-target"}]
      statuses = %{"prev-target" => %{phase: :connected}}

      sock =
        socket(%{remote_targets: targets, connection_statuses: statuses, remote_context_seq: 1})

      assert {:halt, result} =
               NodeAware.handle_info(
                 {:node_aware_remote_context, 1, nil, node(), {:ok, {:nope, :nope2}}},
                 sock
               )

      # Non-list targets / non-map statuses are rejected in favour of the
      # last-known value (the layout dot-accesses the assigns).
      assert result.assigns.remote_targets == targets
      assert result.assigns.connection_statuses == statuses
    end
  end

  describe "exit-safety — an EXITing sidebar fetch (unregistered store) reports back" do
    # async: false — the test unregisters the PROCESS-GLOBAL
    # `EvoGit.TaskRegistry` name, which would break any concurrently running
    # suite. The isolated pair makes the restore deterministic (no
    # kill/restart race once the name is re-registered).
    setup :setup_isolated_registry

    test "a GenServer.call to a dead/unregistered TaskRegistry yields an {:error, {:exit, _}} result" do
      # `GenServer.call/3` to an UNREGISTERED name EXITS the caller (`:noproc`) —
      # the exact failure mode a `rescue` cannot catch and `EvoDash.SafeCall`
      # exists for. Unregistering the ISOLATED TaskRegistry's name makes that
      # deterministic (no kill/restart race) and the name is re-registered
      # before the test ends.
      registry = Process.whereis(EvoGit.TaskRegistry)
      assert is_pid(registry)

      restore_registry = fn ->
        if Process.alive?(registry) and Process.whereis(EvoGit.TaskRegistry) == nil do
          Process.register(registry, EvoGit.TaskRegistry)
        end
      end

      # Belt-and-braces: never leak an unregistered TaskRegistry into teardown
      # even if an assertion below fails.
      on_exit(restore_registry)

      running = [%{id: "keep-running", status: :running}]
      pending = [%{id: "keep-pending", status: :completed}]

      sock =
        socket(%{
          current_node: node(),
          current_node_id: nil,
          running_tasks: running,
          pending_tasks: pending,
          tasks_reload_pending: true
        })

      Process.unregister(EvoGit.TaskRegistry)

      # The load still spawns (the task supervisor is healthy) — only the
      # FETCH exits.
      loaded = NodeAware.load_running_and_pending_tasks(sock)
      assert loaded.assigns[:tasks_load_seq] == 1

      assert_receive {:node_aware_active_tasks, 1, nil, _node, {:error, {:exit, _reason}}}, 1000

      # Restore the singleton name immediately — nothing else needs it gone.
      restore_registry.()

      # The EXIT became a VALUE, so the hook applies it without crashing:
      # the last-known sidebar state survives and the debounce flag clears.
      assert {:halt, result} =
               NodeAware.handle_info(
                 {:node_aware_active_tasks, 1, nil, node(), {:error, {:exit, :timeout}}},
                 loaded
               )

      assert result.assigns.running_tasks == running
      assert result.assigns.pending_tasks == pending
      assert result.assigns.tasks_reload_pending == false
      assert EvoDash.ActiveTasks.get(nil, node()) == :empty
    end
  end

  describe "handle_tasks_result/2 — the LOCAL hub key: stale results never write it" do
    # The local-context half of the hub-write contract (the remote-context half
    # lives in the `async: true` module above, keyed by unique contexts). Both
    # tests assert the LOCAL `{nil, node()}` key exactly, which requires
    # `async: false`: every concurrently mounting page writes that key.

    test "a stale result (node context no longer matches) is dropped and never writes the hub" do
      # The socket is viewing a DIFFERENT context than the in-flight fetch's —
      # the user switched nodes mid-flight.
      sock = socket(%{current_node: node(), current_node_id: nil, tasks_load_seq: 1})

      result =
        NodeAware.handle_tasks_result(
          sock,
          {:node_aware_active_tasks, 1, "other-target", :"other_remote@127.0.0.1",
           {:ok, {[%{id: "stale"}], []}}}
        )

      assert result == sock
      assert EvoDash.ActiveTasks.get("other-target", :"other_remote@127.0.0.1") == :empty
      # The socket's own (local) context is also untouched by the stale write.
      assert EvoDash.ActiveTasks.get(nil, node()) == :empty
    end

    test "an applied result drops non-map entries from the assigns AND the hub write" do
      # The hub is deliberately shape-agnostic (stores whatever lists it is
      # given, verbatim), so a malformed payload must be sanitized HERE —
      # before both the assigns (which Layouts.app/1 dot-accesses, raising
      # BadMapError on a non-map) and the hub write (which would otherwise
      # poison every later mount on this context). Only non-map entries are
      # dropped; well-formed summary maps pass through unchanged.
      valid_map = %{status: :running, project_path: "/tmp/proj"}

      sock = socket(%{current_node: node(), current_node_id: nil, tasks_load_seq: 1})

      result =
        NodeAware.handle_tasks_result(
          sock,
          {:node_aware_active_tasks, 1, nil, node(), {:ok, {[:c, valid_map], [:d]}}}
        )

      # Non-map entries are dropped from the applied assigns...
      assert result.assigns.running_tasks == [valid_map]
      assert result.assigns.pending_tasks == []

      # ...and the hub is written SANITIZED — never the malformed payload.
      assert EvoDash.ActiveTasks.get(nil, node()) == {:ok, {[valid_map], []}}
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
    #
    # async: false — `save_target!` writes the config dir.
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
      assert_receive {:node_aware_active_tasks, 1, "target-2", ^remote_node,
                      {:ok, {running, pending}}},
                     1000

      # The RPC to the (nonexistent) remote node fails fast → empty lists.
      assert running == []
      assert pending == []
    end
  end

  describe "initiate_remote_connect/2 — shared async connect helper" do
    # initiate_remote_connect/2 (node_aware.ex) spawns the connect resolution
    # on EvoDash.TaskSupervisor and returns the socket UNCHANGED — it never
    # blocks the LiveView/LiveComponent process. The spawned Task runs the real
    # resolution chain (EvoDash.NodeContext.connect/1 →
    # EvoGit.RemoteConnection.connect/1 → fetch_target → ensure_started →
    # GenServer.call(manager, :connect)), so a test target is saved per test
    # while the fake ConnectionManager stands in for the real manager in
    # EvoGit.RemoteConnection.Registry.
    #
    # async: false — `save_target!` writes the config dir.
    setup :setup_isolated_registry
    setup :isolate_config_dir

    test "spawns the connect off-process on EvoDash.TaskSupervisor and returns the socket unchanged" do
      id = "conn-spawn"
      save_target!(id)

      # No `delay_ms`: the fake records the caller BEFORE it replies, so the
      # recorded pid is observable after the spawned Task has already exited —
      # holding the call open would only add wall clock.
      manager =
        start_supervised!(
          {EvoDashWeb.NodeAwareTest.ConnectionManager,
           {id, %{phase: :disconnected}, {:ok, :connecting}}}
        )

      sock = socket(%{})
      assert NodeAware.initiate_remote_connect(sock, id) == sock

      # The connect resolution is ASYNC: poll the fake until its :connect call
      # is recorded (the spawned Task reached the manager)...
      await_until(fn -> GenServer.call(manager, :calls) != [] end)

      # ...then assert the recorded caller is a different process than the test
      # process — the GenServer.call never runs inline in the caller of
      # initiate_remote_connect/2.
      assert [caller] = GenServer.call(manager, :callers)
      assert is_pid(caller)
      refute caller == self()

      # The supervised Task exits normally after replying — wait for it so
      # teardown never stops the fake mid-call.
      await_until(fn -> not Process.alive?(caller) end)
    end

    test "terminal {:ok, _phase} connect results ({:connecting} and {:connected}) → NO self-message" do
      # Both terminal-reply phases run through the SAME `{:ok, {:ok, _phase}}`
      # arm (the terminal outcome arrives via the "remote_connections"
      # broadcast), so one test covers both payloads.
      for {id, status, result} <- [
            {"conn-ok-connecting", %{phase: :disconnected}, {:ok, :connecting}},
            {"conn-ok-connected", %{phase: :connected, node: "genesis_remote@127.0.0.1"},
             {:ok, :connected}}
          ] do
        save_target!(id)

        # A per-target child id, so both fakes can be supervised by one test.
        manager =
          start_supervised!(
            Supervisor.child_spec(
              {EvoDashWeb.NodeAwareTest.ConnectionManager, {id, status, result}},
              id: id
            )
          )

        sock = socket(%{})
        assert NodeAware.initiate_remote_connect(sock, id) == sock

        # Wait for the connect to be recorded — the spawned Task reached the fake.
        await_until(fn -> GenServer.call(manager, :calls) != [] end)

        # Deterministic backstop: capture the spawned Task and wait for it to
        # exit. Its {:error, reason} arm is its LAST expression, so once the
        # Task is dead, any self-message it would have sent is already in the
        # mailbox — the refute below can then never race a late send (0 ms
        # window: the dead Task IS the evidence).
        assert [caller] = GenServer.call(manager, :callers)
        await_until(fn -> not Process.alive?(caller) end)

        # {:ok, _phase} is a terminal-enough reply for the helper: only the
        # {:error, reason} arm sends the view a message, so none may arrive.
        refute_receive {:remote_connect_result, ^id, _}, 0
      end
    end

    test "{:error, reason} connect result → the {:remote_connect_result, ...} self-message is delivered" do
      id = "conn-error"
      save_target!(id)

      start_supervised!(
        {EvoDashWeb.NodeAwareTest.ConnectionManager,
         {id, %{phase: :disconnected}, {:error, :fake_connect}}}
      )

      sock = socket(%{})
      assert NodeAware.initiate_remote_connect(sock, id) == sock

      # The spawned Task resolves the connect to {:error, :fake_connect} and
      # sends the view (the test process) the sync-error self-message.
      assert_receive {:remote_connect_result, ^id, {:error, :fake_connect}}, 1000
    end

    test "nil target_id → no spawn, socket unchanged, no :connect reaches any fake" do
      id = "conn-nil-sentinel"
      save_target!(id)

      manager =
        start_supervised!(
          {EvoDashWeb.NodeAwareTest.ConnectionManager,
           {id, %{phase: :disconnected}, {:error, :should_never_connect}}}
        )

      sock = socket(%{})
      assert NodeAware.initiate_remote_connect(sock, nil) == sock

      # The nil clause returns the socket and spawns nothing. `start_child/2`
      # is synchronous, so an empty supervisor-children list for THIS process
      # deterministically proves no spawn happened (and a spawn that had
      # already finished would have left its self-message / :connect call
      # behind, both asserted below).
      assert spawned_view_tasks(self()) == []
      refute_receive {:remote_connect_result, _, _}, 0
      assert GenServer.call(manager, :calls) == []
    end
  end
end
