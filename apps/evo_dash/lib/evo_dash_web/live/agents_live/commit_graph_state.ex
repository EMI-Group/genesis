defmodule EvoDashWeb.AgentsLive.CommitGraphState do
  @moduledoc """
  Temporal (commit-history) view state for the Agents page.
  It owns the left-panel view switcher, the fold (collapse/expand) set and the
  throttled, fingerprint-gated async fetch behind
  `EvoDashWeb.AgentsLive.CommitGraph`.
  Every entry point returns the updated socket (or the liveview callback's
  `{:noreply, socket}` tuple) and never renders.
  """
  import Phoenix.Component, only: [assign: 2, assign: 3]
  alias EvoDash.SafeCall
  alias EvoDashWeb.AgentsLive.{CommitGraph, CommitGraphRefresh, Scope}

  # Minimum interval between commit-graph fetches. Refreshes are already coalesced
  # by the agent-event flush; this further throttles the (heavier) per-repo git
  # RPC. A throttled request arms ONE one-shot :commit_graph_tick — never a poll.
  # The window is read AT CALL TIME via commit_graph_min_interval_ms/0 (the
  # :agents_live_commit_graph_tick_ms test seam, production default 1000ms) so the
  # throttle check and the armed tick delay can never diverge.

  @doc """
  Rebuilds the graph for the CURRENT agents and maybe refetches it — a NO-OP
  unless the commits view is active; `force: true` bypasses the throttle and the
  fingerprint gate.
  """
  # Fetches (or refreshes) the commit graph, but ONLY while the commit-history
  # view is active — the tree view must never trigger a git RPC. Mirrors the
  # other async loads: the task runs in an EvoDash.TaskSupervisor child (never in
  # the LiveView process), the runner seam is resolved AT SPAWN TIME (inside the
  # task), and the result is stale-guarded on a monotonic seq + the viewed node.
  #
  # First keeps the rendered graph in sync with the CURRENT agent list (a
  # newly-spawned child's progress path/ring appears immediately), then
  # refetches — throttled to commit_graph_min_interval_ms/0; a throttled request
  # arms a one-shot tick. `force: true` bypasses the throttle AND the
  # fingerprint gate (first activation, the one-shot tick, a view re-switch).
  #
  # FINGERPRINT GATE (fingerprint-gated calls only, i.e. NOT force: true and
  # the graph is already loaded): a commit-relevance fingerprint of the
  # temporal view's agent set (CommitGraphRefresh.fingerprint/1 — the grouping
  # key, task/task_local ids, depth, parent, the base/tip shas and the ended
  # flag) is compared against the one stored by the last build. UNCHANGED →
  # the flush was status/token/usage/message-count-only, commit-irrelevant:
  # skip BOTH the rebuild and the refetch spawn (no git RPC). CHANGED →
  # rebuild + refetch as before and store the new fingerprint. A fetch already
  # in flight (@commit_graph_loading) is never skipped-changed: its result
  # applies through {:commit_graph_loaded, ...}, which re-stores the
  # fingerprint of the agent set it built from — so the in-flight fetch always
  # converges and no fetch/result loop can form (a result yielding identical
  # raw data stores the CURRENT fingerprint; the next flush then compares
  # equal and skips).
  def maybe_load(socket, opts) do
    if socket.assigns.left_view != :commits or not Scope.available?(socket.assigns) or
         socket.assigns[:scoped_task_state] in [:loading, :error, :missing] do
      socket
    else
      agents = commit_graph_agents(socket)
      force? = Keyword.get(opts, :force, false) or not socket.assigns.commit_graph_loaded

      # Skip the fingerprint work entirely on the bypass paths.
      cond do
        force? ->
          refresh_commit_graph(socket, agents, force: true, gate: false)

        # A fetch is already in flight: never gate (and never re-spawn) — its
        # result applies the freshest data and re-stores the fingerprint.
        socket.assigns.commit_graph_loading ->
          refresh_commit_graph(socket, agents, force: false, gate: false)

        true ->
          refresh_commit_graph(socket, agents, force: false, gate: true)
      end
    end
  end

  @doc """
  Applies an async commit-graph result, dropped when it is stale for the viewed
  node.
  """
  # Async commit-graph result (spawned by spawn_commit_graph_fetch/1). Applies the
  # fresh graph when it is the newest fetch for the node being viewed. An error
  # keeps the last good graph (the view never wedges on a spinner); a PARTIAL
  # success (≥1 group ok, others failed) is an {:ok, ...} carrying the successful
  # groups only — the failed groups' lanes still render from the agent set, their
  # commits just stop at the last fetch.
  def loaded(socket, scope, seq, result) do
    if Scope.available?(socket.assigns) and owns_result?(socket, scope, seq) do
      case result do
        {:ok, raw_by_repo} ->
          # Lanes come from the MERGED agent set (live + in-session retained) so
          # a recycled agent's lane/START-END markers survive; the agent tree
          # (@agents) is untouched. The fingerprint is re-stored for the agent
          # set THIS build consumed, so the next fingerprint-gated flush
          # compares against what was actually rendered.
          agents = commit_graph_agents(socket)

          {:noreply,
           assign(socket,
             commit_graph:
               CommitGraph.build(raw_by_repo, agents, socket.assigns.commit_fold_expanded),
             commit_graph_raw: raw_by_repo,
             commit_graph_loaded: true,
             commit_graph_loading: false,
             commit_graph_error: nil,
             commit_graph_fingerprint: CommitGraphRefresh.fingerprint(agents)
           )}

        {:error, reason} ->
          {:noreply,
           assign(socket,
             commit_graph_loading: false,
             commit_graph_error: reason
           )}
      end
    else
      {:noreply, socket}
    end
  end

  defp owns_result?(socket, {_, _, _} = scope, seq),
    do: scope == Scope.identity(socket.assigns) and seq == socket.assigns.commit_graph_seq

  # Older unscoped receipt shape is never admissible in a focused/target view.
  defp owns_result?(socket, node, seq),
    do:
      Scope.identity(socket.assigns) == {nil, node, nil} and
        seq >= Map.get(socket.assigns, :commit_graph_seq, 0)

  @doc """
  Serves a throttled request: re-attempts with the throttle bypassed.
  """
  # One-shot retry armed by schedule_commit_graph_tick/1 when a refresh request was
  # throttled: re-attempt with the throttle bypassed so a commit created inside
  # the throttle window (a new dot, or an agent ring that moved to a fresh tip)
  # is still reflected. Not periodic — it is armed ONLY by a throttled request.
  def tick(socket), do: tick(socket, socket.assigns[:commit_graph_tick_token])

  def tick(socket, token) do
    if is_reference(token) and token == socket.assigns[:commit_graph_tick_token] do
      socket = assign(socket, commit_graph_tick_scheduled: false, commit_graph_tick_token: nil)
      {:noreply, maybe_load(socket, force: true)}
    else
      {:noreply, socket}
    end
  end

  @doc """
  Switches the left panel between the agent tree and the commit history (only
  the two literal values are accepted).
  """
  # Left-panel view switcher (agent tree / commit history). Only the two literal
  # values are accepted; anything else is ignored (whitelist, no atom conversion).
  def switch_left_view(socket, "tree"), do: assign(socket, :left_view, :tree)

  def switch_left_view(socket, "commits") do
    socket |> assign(:left_view, :commits) |> maybe_load(force: true)
  end

  def switch_left_view(socket, _view), do: socket

  @doc """
  Toggles ONE fold key, rebuilding the view model from the already-fetched raw
  data (no git RPC).
  """
  # Commit-history FOLD (collapse/expand). The raw commit data is ALREADY in
  # @commit_graph_raw, so a fold change only re-runs the pure view-model
  # assembly in this process — no git RPC, no fetch spawn, no throttle/tick and
  # no fingerprint consultation. The fold key is whitelisted by shape only (a
  # binary straight from the rendered gap row — never atomized), and the params
  # key is the `phx-value-fold_key` attribute SUFFIX, which LiveView passes
  # verbatim (so a kebab attribute would arrive as "fold-key" and match nothing).
  def toggle_fold(socket, %{"fold_key" => key}) when is_binary(key) do
    if commit_folds_active?(socket) do
      expanded = socket.assigns.commit_fold_expanded

      expanded =
        if MapSet.member?(expanded, key),
          do: MapSet.delete(expanded, key),
          else: MapSet.put(expanded, key)

      socket |> assign(:commit_fold_expanded, expanded) |> rebuild_commit_graph_folds()
    else
      socket
    end
  end

  # Odd params (non-binary / missing key) are a no-op.
  def toggle_fold(socket, _params), do: socket

  @doc """
  Expands EVERY fold of the current raw data.
  """
  # Expands EVERY fold of the current raw data. `fold_keys/2` is the builder's
  # single source of the fold inventory, so the page never guesses key shapes.
  def expand_all(socket) do
    if commit_folds_active?(socket) do
      expanded =
        MapSet.union(
          socket.assigns.commit_fold_expanded,
          CommitGraph.fold_keys(socket.assigns.commit_graph_raw, commit_graph_agents(socket))
        )

      socket |> assign(:commit_fold_expanded, expanded) |> rebuild_commit_graph_folds()
    else
      socket
    end
  end

  @doc """
  Collapses every fold of the current raw data.
  """
  def collapse_all(socket) do
    if commit_folds_active?(socket) do
      socket |> assign(:commit_fold_expanded, MapSet.new()) |> rebuild_commit_graph_folds()
    else
      socket
    end
  end

  # Rebuild + (maybe) refetch. `gate: true` compares the agent set's
  # commit-relevance fingerprint against the stored one and short-circuits on
  # a match; `gate: false` always rebuilds. `force: true` additionally bypasses
  # the fetch throttle (view switch / tick fire); `force: false` follows the
  # throttle/tick rules.
  defp refresh_commit_graph(socket, agents, force: force?, gate: gate?) do
    if gate? do
      fingerprint = CommitGraphRefresh.fingerprint(agents)

      if MapSet.size(fingerprint) > 0 and fingerprint == socket.assigns.commit_graph_fingerprint do
        # Commit-irrelevant change — the view model would be identical.
        socket
      else
        socket
        |> rebuild_commit_graph(agents, fingerprint)
        |> fetch_commit_graph(agents, fingerprint, force?)
      end
    else
      socket
      |> rebuild_commit_graph(agents, nil)
      |> fetch_commit_graph(agents, nil, force?)
    end
  end

  # Rebuilds @commit_graph from the last fetched raw data + the given agents,
  # so the overlay (progress paths, ring positions) tracks agents without a
  # git RPC. A no-op before the first successful fetch. `fingerprint` (nil on
  # the bypass paths) is stored so the NEXT fingerprint-gated call compares
  # against what was actually built. The user's fold (collapse/expand) set is
  # threaded through, so a refresh never resets the fold state.
  defp rebuild_commit_graph(socket, agents, fingerprint) do
    if socket.assigns.commit_graph_loaded do
      assign(socket,
        commit_graph:
          CommitGraph.build(
            socket.assigns.commit_graph_raw,
            agents,
            socket.assigns.commit_fold_expanded
          ),
        commit_graph_fingerprint: fingerprint || CommitGraphRefresh.fingerprint(agents)
      )
    else
      socket
    end
  end

  # Fold events are inert unless the commits view is the ACTIVE view over an
  # already-fetched graph: there are no gap rows to click and nothing to
  # re-fold — and critically, they must never start a fetch of their own.
  defp commit_folds_active?(socket) do
    socket.assigns.left_view == :commits and socket.assigns.commit_graph_loaded
  end

  # Rebuilds @commit_graph in place for a FOLD (collapse/expand) change — the
  # raw commit data is already in memory, so this is pure view-model work: no
  # git RPC, no fetch spawn, no throttle/fingerprint consultation. A no-op
  # before the first successful fetch (there is nothing to re-fold).
  defp rebuild_commit_graph_folds(socket) do
    if socket.assigns.commit_graph_loaded do
      assign(socket,
        commit_graph:
          CommitGraph.build(
            socket.assigns.commit_graph_raw,
            commit_graph_agents(socket),
            socket.assigns.commit_fold_expanded
          )
      )
    else
      socket
    end
  end

  # Spawns the refetch (or arms the one-shot tick when throttled) and stores
  # `fingerprint` so the fetch's result path knows which agent set it captured.
  # `force?` bypasses the throttle (view switch / tick fire).
  defp fetch_commit_graph(socket, agents, fingerprint, force?) do
    groups = commit_graph_groups(agents)

    cond do
      groups == [] ->
        assign(socket,
          commit_graph: [],
          commit_graph_loaded: true,
          commit_graph_loading: false,
          commit_graph_fingerprint: fingerprint || CommitGraphRefresh.fingerprint(agents)
        )

      force? or not commit_graph_throttled?(socket) ->
        spawn_commit_graph_fetch(socket, fingerprint)

      true ->
        schedule_commit_graph_tick(socket)
    end
  end

  # The agent set the TEMPORAL view is built from: the LIVE agents (@agents)  # MERGED with the in-session RETAINED (ended) agents (@retained_agents),
  # de-duplicated by id with the LIVE copy winning. Retained agents contribute
  # lane metadata (and their START/END markers) but never tips, because their
  # commits already live in the task's durable ref ancestry. The agent TREE
  # (@agents) is deliberately NOT fed from here.
  defp commit_graph_agents(socket) do
    live = socket.assigns.agents
    live_ids = MapSet.new(live, & &1.id)

    retained =
      socket.assigns.retained_agents
      |> Map.values()
      |> Enum.reject(&MapSet.member?(live_ids, &1.id))

    live ++ retained
  end

  # Eligible agents' commit ranges grouped for the TASK-scoped commit-graph RPC.
  # A group is `{repo_key, task_id}` (both binaries — the durable task ref is
  # per task AND per repo) and carries only the NON-ended agents' tips
  # (`live_tips`): a retained/ended agent's commits are already in the task's
  # durable ref ancestry, so it contributes its lane but no tip. Agents lacking
  # a repo_key, base_commit, current_commit or task_id are skipped. Sorted by
  # `{repo_key, task_id}` for deterministic task input.
  defp commit_graph_groups(agents) do
    agents
    |> Enum.filter(fn a ->
      is_binary(Map.get(a, :repo_root)) and is_binary(Map.get(a, :base_commit)) and
        is_binary(Map.get(a, :current_commit)) and is_binary(Map.get(a, :task_id))
    end)
    |> Enum.group_by(fn a -> {Map.get(a, :repo_root), Map.get(a, :task_id)} end)
    |> Enum.map(fn {{repo_key, task_id}, group} ->
      live_tips =
        group
        |> Enum.reject(&(Map.get(&1, :ended) == true))
        |> Enum.map(&Map.get(&1, :current_commit))
        |> Enum.uniq()

      %{repo_key: repo_key, task_id: task_id, live_tips: live_tips}
    end)
    |> Enum.sort_by(fn %{repo_key: repo_key, task_id: task_id} -> {repo_key, task_id} end)
  end

  # The commit-graph minimum interval, resolved AT CALL TIME so both the throttle
  # check and the armed one-shot tick delay read the same value. The app-env seam
  # :agents_live_commit_graph_tick_ms lets tests shrink the window; production
  # behaviour is unchanged (default 1000ms) when it is unset.
  defp commit_graph_min_interval_ms do
    Application.get_env(:evo_dash, :agents_live_commit_graph_tick_ms, 1000)
  end

  # True when the last fetch is inside the minimum interval.
  defp commit_graph_throttled?(socket) do
    case socket.assigns.commit_graph_fetched_at do
      nil -> false
      at -> System.monotonic_time(:millisecond) - at < commit_graph_min_interval_ms()
    end
  end

  # Arms ONE one-shot tick (never a repeating timer) so a throttled refresh is
  # eventually served. The boolean assign guarantees a single timer per window.
  defp schedule_commit_graph_tick(socket) do
    if socket.assigns.commit_graph_tick_scheduled do
      socket
    else
      token = make_ref()
      Process.send_after(self(), {:commit_graph_tick, token}, commit_graph_min_interval_ms())
      assign(socket, commit_graph_tick_scheduled: true, commit_graph_tick_token: token)
    end
  end

  # Spawns the async commit-graph fetch: ONE runner call per `{repo_key, task_id}`
  # group, passing that task's live tips + the limit. The seam
  # :agents_commit_graph_runner (default &EvoDash.NodeContext.list_task_commit_graph/5)
  # is resolved AT SPAWN TIME so tests can stub it. The per-group replies are
  # folded by CommitGraphRefresh.fetch_result/3 with PARTIAL-SUCCESS semantics:
  # a failing group drops only ITS data (recorded as a
  # {:commit_graph_repo_failed, {repo_key, task_id}, reply} failure) while the
  # successful groups still fold into ONE %{repo_key => %{commits, refs}} map —
  # the keying the pure assembler expects (it groups agents by
  # `repo_root || repo_id`); {:error, _} surfaces ONLY when EVERY group fails.
  # The `fingerprint` captured at spawn time rides along as the fetch's
  # bookkeeping value (see fetch_commit_graph/3).
  defp spawn_commit_graph_fetch(socket, fingerprint) do
    parent = self()
    {_, node, _} = scope = Scope.identity(socket.assigns)
    seq = Map.get(socket.assigns, :commit_graph_seq, 0) + 1
    groups = commit_graph_groups(commit_graph_agents(socket))

    socket =
      assign(socket,
        commit_graph_seq: seq,
        commit_graph_loading: true,
        commit_graph_fingerprint: fingerprint,
        commit_graph_fetched_at: System.monotonic_time(:millisecond),
        commit_graph_tick_scheduled: false,
        commit_graph_tick_token: nil
      )

    Task.Supervisor.start_child(EvoDash.TaskSupervisor, fn ->
      runner =
        Application.get_env(
          :evo_dash,
          :agents_commit_graph_runner,
          &EvoDash.NodeContext.list_task_commit_graph/5
        )

      # Exit-safe boundary: the commit-graph RPC targets a possibly-dead remote
      # daemon (or a node that disconnected mid-flight). `SafeCall.run/1`
      # captures an exit (which `rescue` cannot catch) as an error value, so the
      # result message is ALWAYS sent and the commit view can never wedge on a
      # spinner. A folded per-group `{:error, failure}` passes through verbatim
      # (the renderer's stale-warning strip / first-load error strip).
      result =
        case SafeCall.run(fn -> CommitGraphRefresh.fetch_result(groups, runner, node) end) do
          {:ok, folded_result} -> folded_result
          {:error, _reason} -> {:error, :commit_graph_fetch_failed}
        end

      send(parent, {:commit_graph_loaded, scope, seq, result})
    end)

    socket
  end
end
