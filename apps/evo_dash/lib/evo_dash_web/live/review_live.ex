defmodule EvoDashWeb.ReviewLive do
  @moduledoc """
  Code review page for completed tasks.

  Displays agent-produced changes as a GitHub-style diff with merge,
  reject, and resume actions, plus optional GitHub PR creation.
  """
  use EvoDashWeb, :live_view

  # Socket/derived-state helpers: the DERIVED render assigns, the flat
  # per-repo projection, repo-resolution recording and the directory tree.
  alias EvoDashWeb.ReviewLive.State

  # The async action plumbing: every review action and lazy diff load runs
  # in a supervised task, never in this process (see Runner).
  alias EvoDashWeb.ReviewLive.Runner

  @impl true
  def render(assigns), do: EvoDashWeb.ReviewLive.Page.render(assigns)

  @impl true
  def mount(%{"task_id" => task_id} = params, _session, socket) do
    if connected?(socket) do
      Phoenix.PubSub.subscribe(EvoGit.PubSub, "tasks")
    end

    config_status = config_status()

    socket =
      socket
      |> assign(
        config_status: config_status,
        task_id: task_id,
        loading: true,
        error: nil,
        action_loading: false,
        selected_file: nil,
        expanded_files: %{},
        file_context_levels: %{},
        # Files-toolbar tree + filter state. NOT in the load-result map
        # (LoadData resets the three legacy diff maps but never these), so
        # they survive the debounced review-data reloads. On SHOW the tree
        # map is repo-keyed (like the diff-state maps); flat on :commit.
        tree_expanded_dirs: %{},
        file_filter: "",
        review_tab: :conversation,
        review_data: nil,
        title: "",
        task_type: :unknown,
        branch_name: nil,
        commit_sha: nil,
        agent_summary: nil,
        review_status: :open,
        branch_exists: false,
        can_resume: false,
        is_no_changes: false,
        has_pr: false,
        pr_url: nil,
        show_extract_modal: false,
        repo_path: nil,
        workbench_project: nil,
        base_sha: nil,
        objective: nil,
        inspect_commit_sha: params["commit_sha"],
        inspect_repo_id: params["repo"] || "primary",
        commit_data: nil,
        commit_header: nil,
        # Paged lazy archive load (see EvoDashWeb.ReviewLive.ArchiveLoad): the
        # page load is LITE (no archive transfer), so the Archive tab fetches
        # the archive in bounded pages, and one agent's heavy result on demand.
        # Cached for this task/node context.
        archive_records: [],
        archive_total: 0,
        archive_state: :idle,
        archive_error: nil,
        archive_loading_more?: false,
        archive_more_error: nil,
        archive_key: nil,
        archive_seq: 0,
        # Archiving opt-in ("archive: true" in the task opts, owned by
        # LoadData): a non-opt-in task has no per-agent archive at all, so the
        # Archive tab renders a disabled state and never fetches.
        archive_opt_in?: false,
        # Retention/offset counters for the paged archive: `archive_dropped` =
        # entries evicted by the retention window, `archive_fetched` = cumulative
        # RAW rows received (the next request offset), `archive_exhausted?` = a
        # short page ended the archive, `archive_server_total` = the raw server
        # count for the LABEL (nil when a page reported none).
        archive_dropped: 0,
        archive_fetched: 0,
        archive_exhausted?: false,
        archive_server_total: nil,
        # Per-agent lazy results, keyed by agent id:
        # %{agent_id => %{state: :loading | :ok | :error, entry:, error:}}.
        archive_agent_results: %{},
        archive_agent_seq: 0,
        # Cached archive LABEL (ArchiveLoad.put_label/1 owns it): the tab badge
        # reads this assign, so no render calls label_total/1.
        archive_label_total: 0,
        task_usage: nil,
        agent_count: nil,
        task_status: nil,
        model_id: nil,
        summary_raw: false,
        objective_raw: false,
        started_at: nil,
        finished_at: nil,
        merge_targets: [],
        default_merge_target: nil,
        merge_status: nil,
        review_repos: [],
        active_repo_id: "primary",
        # DERIVED-ONCE assigns over @review_repos / @review_status
        # (`EvoDashWeb.ReviewLive.Aggregates`): recomputed by LoadData on a load
        # and by put_derived/1 on every later mutation, NEVER in the render.
        stats: EvoDashWeb.ReviewLive.Aggregates.empty_stats(),
        primary_repo: nil,
        completion_status: nil,
        # SCOPED loading: false until the FIRST successful load result lands, so
        # a reload renders the shell (header/tabs/tab body) plus a compact
        # refresh strip instead of blanking the page.
        page_ready?: false,
        load_generation: 0,
        # Async ACTION plumbing (see Runner.spawn/4 +
        # handle_info({:review_action_result, ...})): `action_seq` is the
        # monotonic ref counter, `review_action` the in-progress marker (nil |
        # %{kind:, repo_id:, seq:}) that blocks double submits, `busy_repos` the
        # repo ids with a merge/reject in flight, `diff_in_flight` the
        # {repo_id, path}-keyed lazy-diff loads, and `action_loading` the
        # task-level (resume/ignore/PR/extract/auto-resolve) spinner.
        action_seq: 0,
        review_action: nil,
        busy_repos: MapSet.new(),
        diff_in_flight: %{},
        # Review-data reload trigger: the status of the latest reviewed-task
        # broadcast, evaluated when NodeAware's shared trailing-edge debounce
        # fires (nil = review-only mutation, the PubSub contract's nil status).
        review_broadcast_status: :none,
        # Resolutions EARNED by this page's own per-repo action tail
        # (set_repo_resolution/3), keyed %{repo_id => resolution}. Deliberately
        # NOT derived from @review_repos — that list is also seeded by the load
        # (and by test fixtures) and carrying those values would re-apply
        # stale/seeded resolutions over a fresh load. See
        # carry_local_resolutions/2 for how this survives a self-triggered reload.
        local_repo_resolutions: %{}
      )

    {:ok, socket}
  end

  @impl true
  def handle_params(params, _url, socket) do
    page_title =
      if socket.assigns.live_action == :commit,
        do: gettext("Commit details"),
        else: gettext("Review Changes")

    socket =
      socket
      |> EvoDashWeb.LiveHooks.NodeAware.assign_node(params)
      |> assign(:workbench_remote_requested, params["node"] not in [nil, "", "local"])
      |> assign(:current_path, ~p"/review/#{socket.assigns.task_id}")
      |> assign(:page_title, page_title)

    socket =
      if socket.assigns.live_action == :show and params["tab"] == "commits" do
        assign(socket, :review_tab, :commits)
      else
        socket
      end

    repo_id = params["repo"] || previous_review_repo(socket.assigns) || "primary"

    context =
      {socket.assigns.current_node, socket.assigns.live_action, params["commit_sha"], repo_id}

    # Node-aware task load. `@current_node` is only resolved by assign_node
    # above (at mount time it is still the on_mount local default), so the
    # task fetch MUST live here — handle_params runs after mount on initial
    # load too. Dedup guard: the load runs once per (node, route) context —
    # a node change (pending→connected transition, manual ?node= switch) or a
    # push_patch between the review and commit routes warrants a refetch. The
    # load itself runs asynchronously (see start_async_load/2); the result
    # arrives later as a {:review_data_loaded, ...} message.
    socket =
      if Map.get(socket.assigns, :tasks_loaded_for) == context do
        socket
      else
        socket
        # A genuine context change (node/task/route) discards the action-earned
        # resolutions — they belonged to the previous load context and must
        # never be overlaid onto a different node's freshly loaded repos.
        |> assign(:local_repo_resolutions, %{})
        # In-flight action state belongs to the previous context too: its
        # result message is dropped on arrival (task/node mismatch), so the
        # in-progress markers must not survive here.
        |> assign(
          review_action: nil,
          action_loading: false,
          busy_repos: MapSet.new(),
          diff_in_flight: %{},
          review_broadcast_status: :none,
          inspect_commit_sha: params["commit_sha"],
          inspect_repo_id: repo_id,
          tree_expanded_dirs: %{},
          file_filter: ""
        )
        |> start_async_load(params["commit_sha"])
        |> assign(:tasks_loaded_for, context)
      end

    {:noreply, socket}
  end

  @impl true
  def handle_event(event, params, socket),
    do: EvoDashWeb.ReviewLive.Events.dispatch(event, params, socket)

  # Retries the async review-data load from the error panel (the load is
  # exit-safe, so an error is a value the user can recover from without a page
  # refresh). Routed here from `EvoDashWeb.ReviewLive.Events` because the
  # spawner (`start_async_load/2`) lives in this module and is not duplicated.
  def retry_load(socket, _params) do
    {:noreply, start_async_load(socket, Map.get(socket.assigns, :inspect_commit_sha))}
  end

  @impl true
  def handle_info({:task_updated, task_id, status, node} = msg, socket) do
    # Node filter FIRST: only a broadcast from the viewed node can be
    # attributed to the reviewed task, so a foreign-node event never marks the
    # review-data reload as pending. For the reviewed task the event only
    # records its status: the actual reload rides NodeAware's shared
    # trailing-edge debounce (handle_info(:node_aware_reload_tasks, ...)), which
    # re-checks materiality when it fires, so a status the page already shows
    # never re-fetches the full task row.
    socket =
      if EvoDashWeb.LiveHooks.NodeAware.event_from_current_node?(socket.assigns, node) and
           task_id == socket.assigns.task_id do
        socket
        |> assign(:review_broadcast_status, status)
        # The reviewed task changed, so any lazily fetched per-agent result may
        # be stale: drop that cache (the loaded archive pages stay).
        |> EvoDashWeb.ReviewLive.ArchiveLoad.invalidate_agent_results()
      else
        socket
      end

    EvoDashWeb.LiveHooks.NodeAware.handle_task_info(socket, msg)
  end

  @impl true
  def handle_info({:task_deleted, _task_id, _node} = msg, socket) do
    # A deleted task can never be the reviewed task (there is nothing left to
    # review), so no review-data reload is armed here — only the sidebar reload
    # runs, and only when the event's node matches the viewed node (NodeAware
    # filters foreign-node events before scheduling the debounce).
    EvoDashWeb.LiveHooks.NodeAware.handle_task_info(socket, msg)
  end

  @impl true
  def handle_info(:node_aware_reload_tasks, socket) do
    # NodeAware's shared trailing-edge debounce fired: refresh the sidebar's
    # running/pending tasks (reload_tasks/1 also clears the debounce-pending
    # flag), then — ONLY when this page's own broadcast marker makes a
    # review-data reload material — re-fetch the reviewed task. Other tasks'
    # activity therefore never reloads this page's review data.
    socket = EvoDashWeb.LiveHooks.NodeAware.reload_tasks(socket)
    status = Map.get(socket.assigns, :review_broadcast_status, :none)
    socket = assign(socket, :review_broadcast_status, :none)

    if review_reload_material?(status, socket.assigns.task_status) do
      {:noreply, start_async_load(socket, Map.get(socket.assigns, :inspect_commit_sha))}
    else
      {:noreply, socket}
    end
  end

  @impl true
  def handle_info({:review_action_result, task_id, node, action, ref, result}, socket) do
    # Async action finished. A result for a different task/node belongs to a
    # load context that is already gone (the switch reset the in-progress
    # state) — drop it entirely.
    #
    # Apply BEFORE clearing: the lazy-diff actions must read the PRE-clear
    # @diff_in_flight seq to detect a request that superseded them, while
    # Runner.clear/3 only removes the in-flight entry this result owns.
    if task_id != socket.assigns.task_id or node != socket.assigns.current_node do
      {:noreply, socket}
    else
      {:noreply,
       socket
       |> EvoDashWeb.ReviewLive.ActionResults.apply(action, ref, result)
       |> Runner.clear(action, ref)}
    end
  end

  @impl true
  def handle_info({:review_data_loaded, task_id, node, generation, result}, socket) do
    # Async review-data load finished. Stale-guard: drop results for a
    # different task/node or from an older load generation (a newer load was
    # started since — `load_generation` only grows, so `generation < current`
    # means stale).
    stale? =
      task_id != socket.assigns.task_id or node != socket.assigns.current_node or
        generation < Map.get(socket.assigns, :load_generation, 0)

    if stale? do
      {:noreply, socket}
    else
      case result do
        {:ok, assigns_map} ->
          socket =
            socket
            # Loading is cleared EXPLICITLY (the loaded map already carries
            # loading: false) so no result shape can leave the spinner up.
            |> assign(:loading, false)
            |> assign(State.carry_local_resolutions(assigns_map, socket.assigns))
            # Ready: from now on a reload keeps the shell on screen instead of
            # blanking it. The DERIVED assigns are refreshed at the end of this
            # chain, i.e. AFTER the local-resolution overlay (which can change a
            # repo's resolution and therefore the aggregate completion).
            |> assign(:page_ready?, true)

          # The merge check MUST be sequenced here, after the loaded assigns
          # (merge_targets/branch_name/branch_exists/...) are in place. load_data
          # projects the primary flat assigns from the loaded data, but maybe_start
          # then marks the repos :checking — re-project so the flat @merge_status
          # reflects that immediately.
          {:noreply,
           socket
           |> EvoDashWeb.ReviewLive.MergeCheck.maybe_start()
           |> State.project_active_repo()
           |> State.put_derived()}

        {:error, reason} ->
          socket =
            assign(socket,
              loading: false,
              error: reason,
              repo_path: nil,
              workbench_project: nil,
              objective: nil,
              task_usage: nil,
              agent_count: nil,
              task_status: nil,
              model_id: nil,
              started_at: nil,
              finished_at: nil,
              merge_status: nil
            )
            # Back to the mount defaults: nothing on screen is derived from a
            # repo list any more (the error panel is what renders).
            |> State.put_derived()

          {:noreply, socket}
      end
    end
  end

  @impl true
  def handle_info({:review_archive_loaded, task_id, node, seq, offset, result}, socket) do
    # Lazy archive page finished. Stale-guard + state machine live in the
    # support module (a result for another task/node or from before the current
    # context generation is dropped; a first page normalizes to :loaded/:error,
    # an append failure keeps the loaded page — never a stuck spinner).
    {:noreply,
     EvoDashWeb.ReviewLive.ArchiveLoad.handle_result(
       socket,
       task_id,
       node,
       seq,
       offset,
       result
     )}
  end

  @impl true
  def handle_info({:review_archive_agent_loaded, task_id, node, agent_id, seq, result}, socket) do
    # One agent's lazily fetched result landed: cache it and fold it into the
    # loaded page. Every shape is terminal (:ok or a retry-able :error).
    {:noreply,
     EvoDashWeb.ReviewLive.ArchiveLoad.handle_agent_result(
       socket,
       task_id,
       node,
       agent_id,
       seq,
       result
     )}
  end

  @impl true
  def handle_info({:merge_check_result, task_id, node, repo_id, target, result}, socket) do
    # Async dry-run merge check finished (tagged per repo). Result-shape
    # validation and stale-message guarding live in the support module;
    # re-project afterwards so the flat assigns read the ACTIVE repo's
    # @merge_status.
    {:noreply,
     socket
     |> EvoDashWeb.ReviewLive.MergeCheck.handle_result(task_id, node, repo_id, target, result)
     |> State.project_active_repo()
     |> State.put_derived()}
  end

  @impl true
  def handle_info({:node_selected, node_id}, socket) do
    EvoDashWeb.LiveHooks.NodeAware.handle_node_selected(socket, node_id)
  end

  @impl true
  def handle_info({:remote_connection_status, _, _} = msg, socket) do
    EvoDashWeb.LiveHooks.NodeAware.handle_connection_status(socket, msg)
  end

  @impl true
  def handle_info({:remote_connect_result, _target_id, {:error, reason}}, socket) do
    # Sync-error fallback for the async remote-connect retry: these failures
    # (unknown target / subsystem unavailable / manager-start failure) never
    # emit a "remote_connections" broadcast, so the gate cannot reconcile on
    # its own — the error flash is the surfacing mechanism.
    message =
      case reason do
        :remote_connection_unavailable ->
          gettext("Remote connect unavailable — the remote connection subsystem is not running.")

        _ ->
          gettext("Remote connect failed: %{reason}", reason: format_remote_reason(reason))
      end

    {:noreply, put_flash(socket, :error, message)}
  end

  @impl true
  def handle_info(_msg, socket) do
    {:noreply, socket}
  end

  # --- Private Helpers ---

  # Spawns the async review-data load in a supervised Task (same pattern as
  # `MergeCheck.start/5` and SettingsLive's LLM connection test) and marks the
  # page as loading. The result arrives later as a
  # `{:review_data_loaded, task_id, node, generation, result}` message;
  # `load_generation` is monotonic (incremented per start), so stale results
  # from superseded loads are dropped by the handle_info stale-guard.
  #
  # The load runs behind `EvoDash.SafeCall.run/1`: the store/registry/Git calls
  # inside it can exit (a `GenServer.call` timeout EXITS the caller, which a
  # rescue cannot catch). Guarding there means the spawned closure never dies
  # before sending its result — a dead spawned task would wedge the page on the
  # spinner forever — and the outcome is normalized to the two shapes the
  # handle_info consumes.
  defp start_async_load(socket, inspect_commit_sha) do
    # Reconcile the lazily loaded archive with the (re)started load context:
    # a task/node change invalidates the cache, a same-context reload keeps it.
    socket = EvoDashWeb.ReviewLive.ArchiveLoad.sync_context(socket)

    parent = self()
    node = socket.assigns.current_node
    task_id = socket.assigns.task_id
    live_action = socket.assigns.live_action
    repo_id = socket.assigns.inspect_repo_id
    gen = Map.get(socket.assigns, :load_generation, 0) + 1

    socket = assign(socket, loading: true, error: nil, load_generation: gen)

    Task.Supervisor.start_child(EvoDash.TaskSupervisor, fn ->
      result =
        case EvoDash.SafeCall.run(fn ->
               EvoDashWeb.ReviewLive.LoadData.load(node, task_id,
                 live_action: live_action,
                 inspect_commit_sha: inspect_commit_sha,
                 repo_id: repo_id
               )
             end) do
          # LoadData's own outcome: an assigns map, or an already
          # gettext-wrapped error string.
          {:ok, {:ok, assigns_map}} -> {:ok, assigns_map}
          {:ok, {:error, reason}} -> {:error, reason}
          # Exit/exception/throw around the call, or an unexpected shape: the
          # page stays retry-able instead of hanging.
          _ -> {:error, gettext("Failed to load review data.")}
        end

      send(parent, {:review_data_loaded, task_id, node, gen, result})
    end)

    socket
  end

  # A review-data reload is material only when the broadcast can imply changed
  # loaded data: `:none` (no reviewed-task broadcast since the last evaluation)
  # is never material, a nil status (a review-status-only mutation) always is,
  # and a concrete status only when it differs from the status currently on
  # screen (nil loaded status → reload).
  defp review_reload_material?(:none, _loaded_status), do: false
  defp review_reload_material?(nil, _loaded_status), do: true
  defp review_reload_material?(status, loaded_status), do: status != loaded_status

  defp previous_review_repo(%{
         live_action: :show,
         current_node: node,
         tasks_loaded_for: {node, :commit, _, repo_id}
       }),
       do: repo_id

  defp previous_review_repo(_), do: nil
end
