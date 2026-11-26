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

  # Review loads, actions and lazy diffs run in supervised tasks.
  alias EvoDashWeb.ReviewLive.{LoadRequest, Runner}

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
        # Terminal-outcome facts (owned by LoadData): the outcome class, the
        # structured failure record and whether an agent report exists. Nil/false
        # here means "not loaded yet" — the outcome banner renders nothing then.
        outcome: nil,
        task_error: nil,
        has_report: false,
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
        history_scope_request: nil,
        workbench_loaded_scope: nil,
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
  def handle_params(%{"task_id" => task_id} = params, url, socket) do
    page_title =
      if socket.assigns.live_action == :commit,
        do: gettext("Commit details"),
        else: gettext("Review Changes")

    # NodeAware replaces only the node query pair on switches and reconnects.
    # Keep the actual route and raw query (not just the review landing path).
    %URI{path: path, query: query} = URI.parse(url)

    socket =
      socket
      |> EvoDashWeb.LiveHooks.NodeAware.assign_node(params)
      |> assign(
        task_id: task_id,
        workbench_remote_requested: params["node"] not in [nil, "", "local"],
        current_path: URI.to_string(%URI{path: path, query: query}),
        page_title: page_title
      )

    socket =
      if socket.assigns.live_action == :show and params["tab"] == "commits" do
        assign(socket, :review_tab, :commits)
      else
        socket
      end

    scope = LoadRequest.scope(socket.assigns)
    repo_id = params["repo"] || previous_review_repo(socket.assigns, scope) || "primary"
    context = {scope, socket.assigns.live_action, params["commit_sha"], repo_id}
    previous_context = socket.assigns[:tasks_loaded_for]

    # Load once per task, serving scope and review route. Query-only patches
    # (e.g. a tab change) do not re-read data. Even a switch between target IDs
    # sharing a BEAM node supersedes the prior load generation.
    socket =
      if previous_context == context do
        socket
      else
        socket
        |> reset_page_readiness(previous_context, scope)
        # Resolutions from the previous context must not overlay this load.
        |> assign(:local_repo_resolutions, %{})
        # Release the in-progress markers from the previous context.
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
        |> LoadRequest.start(params["commit_sha"])
        |> assign(:tasks_loaded_for, context)
      end

    {:noreply, socket}
  end

  @impl true
  def handle_event(event, params, socket),
    do: EvoDashWeb.ReviewLive.Events.dispatch(event, params, socket)

  # Retries the same scoped request from the error panel.
  def retry_load(socket, _params) do
    {:noreply, LoadRequest.start(socket, socket.assigns.inspect_commit_sha)}
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
      if task_id == socket.assigns.task_id and not LoadRequest.blocked?(socket.assigns) and
           EvoDashWeb.LiveHooks.NodeAware.event_from_current_node?(socket.assigns, node) do
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
      {:noreply, LoadRequest.start(socket, socket.assigns.inspect_commit_sha)}
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
    # The generation advances even when a scope change skipped the read
    # (e.g. disconnect), so an older same-BEAM result cannot settle this page.
    stale? =
      task_id != socket.assigns.task_id or node != socket.assigns.current_node or
        generation != socket.assigns.load_generation

    if stale? do
      {:noreply, socket}
    else
      socket = LoadRequest.settle(socket, result)

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
              merge_status: nil,
              # No loaded task means no subject for an outcome banner, and the
              # no-change dismissal belongs to the failed load, not to a task.
              outcome: nil,
              task_error: nil,
              has_report: false,
              is_no_changes: false
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

  # A review-data reload is material only when the broadcast can imply changed
  # loaded data: `:none` (no reviewed-task broadcast since the last evaluation)
  # is never material, a nil status (a review-status-only mutation) always is,
  # and a concrete status only when it differs from the status currently on
  # screen (nil loaded status → reload).
  defp review_reload_material?(:none, _loaded_status), do: false
  defp review_reload_material?(nil, _loaded_status), do: true
  defp review_reload_material?(status, loaded_status), do: status != loaded_status

  defp reset_page_readiness(socket, {scope, _, _, _}, scope), do: socket

  defp reset_page_readiness(socket, _previous_context, _scope),
    do: assign(socket, :page_ready?, false)

  defp previous_review_repo(
         %{live_action: :show, tasks_loaded_for: {scope, :commit, _, repo_id}},
         scope
       ),
       do: repo_id

  defp previous_review_repo(_, _), do: nil
end
