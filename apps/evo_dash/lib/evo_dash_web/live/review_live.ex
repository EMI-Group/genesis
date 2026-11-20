defmodule EvoDashWeb.ReviewLive do
  @moduledoc """
  Code review page for completed tasks.

  Displays agent-produced changes as a GitHub-style diff with merge,
  reject, and resume actions, plus optional GitHub PR creation.
  """
  use EvoDashWeb, :live_view

  # `RepoCards.repo_has_changes?/1` is the SINGLE source of the "does this repo
  # have changes?" test (also used by RepoCards' own merge-all gate).
  alias EvoDashWeb.ReviewComponents.RepoCards

  # Off-process action executors (merge / reject / PR / task start / diff
  # loads). Nothing here may run inside the LiveView process — a slow store or
  # Git call would block the page, and a `GenServer.call` timeout EXITS it.
  alias EvoDashWeb.ReviewLive.Actions

  # Socket/derived-state helpers: the DERIVED render assigns, the flat
  # per-repo projection, repo-resolution recording and the directory tree.
  alias EvoDashWeb.ReviewLive.State

  # The async action plumbing: every review action and lazy diff load runs
  # in a supervised task, never in this process (see Runner).
  alias EvoDashWeb.ReviewLive.Runner

  # The lazy per-file diff subsystem (on-demand diff + context-expansion
  # loads).
  alias EvoDashWeb.ReviewLive.Diffs

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
  def handle_event("switch_tab", %{"tab" => "conversation"}, socket) do
    {:noreply, assign(socket, :review_tab, :conversation)}
  end

  def handle_event("switch_tab", %{"tab" => "files_changed"}, socket) do
    {:noreply, assign(socket, :review_tab, :files_changed)}
  end

  def handle_event("switch_tab", %{"tab" => "objective"}, socket) do
    {:noreply, assign(socket, :review_tab, :objective)}
  end

  def handle_event("switch_tab", %{"tab" => "commits"}, socket) do
    {:noreply, assign(socket, :review_tab, :commits)}
  end

  # The Archive tab is only reachable for a task that opted into archiving
  # (`@archive_opt_in?`, from the task opts): for any other task the click is a
  # complete no-op — no tab switch, no fetch.
  def handle_event("switch_tab", %{"tab" => "archive"}, socket) do
    if Map.get(socket.assigns, :archive_opt_in?, false) do
      {:noreply,
       socket
       |> assign(:review_tab, :archive)
       |> EvoDashWeb.ReviewLive.ArchiveLoad.ensure_loaded()}
    else
      {:noreply, socket}
    end
  end

  def handle_event("switch_tab", _params, socket) do
    {:noreply, socket}
  end

  # Retry button inside the Archive tab's error state — re-arms the archive
  # state machine and starts one fresh first page (never a poll).
  @impl true
  def handle_event("retry_archive", _params, socket) do
    {:noreply, EvoDashWeb.ReviewLive.ArchiveLoad.retry(socket)}
  end

  # "Load more" (and its inline Retry after a failed append): appends the next
  # page. The support module owns every guard (already loaded, append in
  # flight, nothing left to load).
  @impl true
  def handle_event("load_more_archive", _params, socket) do
    {:noreply, EvoDashWeb.ReviewLive.ArchiveLoad.load_more(socket)}
  end

  # Per-agent lazy result: fetches ONE agent's heavy "result" on demand (also
  # the Retry path for a failed fetch). Never triggered by a render.
  # `phx-value-agent-id` arrives as the hyphenated key "agent-id" (LiveView
  # keeps the attribute suffix verbatim), so accept both spellings.
  @impl true
  def handle_event("load_archive_agent_result", %{"agent_id" => agent_id}, socket) do
    {:noreply, EvoDashWeb.ReviewLive.ArchiveLoad.load_agent_result(socket, agent_id)}
  end

  def handle_event("load_archive_agent_result", %{"agent-id" => agent_id}, socket) do
    {:noreply, EvoDashWeb.ReviewLive.ArchiveLoad.load_agent_result(socket, agent_id)}
  end

  def handle_event("load_archive_agent_result", _params, socket), do: {:noreply, socket}

  # Repo <select>s live inside components; each is wrapped in its own
  # <form phx-change="switch_repo">, so the payload arrives as
  # %{"repo_id" => repo_id}. A form-less select (legacy shape) delivers the
  # generic "value" key instead of the field name — accept both defensively.
  @impl true
  def handle_event("switch_repo", %{"repo_id" => repo_id}, socket) do
    {:noreply, State.switch_repo(socket, repo_id)}
  end

  def handle_event("switch_repo", %{"value" => repo_id}, socket) do
    {:noreply, State.switch_repo(socket, repo_id)}
  end

  @impl true
  def handle_event("toggle_dir", %{"dir" => dir}, socket) do
    # Tree-expansion state lives in @tree_expanded_dirs, keyed by repo_id on
    # the SHOW route (mirroring the repo-keyed diff-state maps — a dir toggle
    # in one repo must not clobber another repo's tree) and flat on the
    # :commit route (legacy convention). No re-projection needed: the template
    # reads the ACTIVE repo's submap via inline Map.get, same as the diff maps.
    tree = socket.assigns.tree_expanded_dirs || %{}

    tree =
      if socket.assigns.live_action == :commit do
        if Map.get(tree, dir), do: Map.delete(tree, dir), else: Map.put(tree, dir, true)
      else
        sub = Map.get(tree, socket.assigns.active_repo_id, %{})

        sub = if Map.get(sub, dir), do: Map.delete(sub, dir), else: Map.put(sub, dir, true)
        Map.put(tree, socket.assigns.active_repo_id, sub)
      end

    {:noreply, assign(socket, :tree_expanded_dirs, tree)}
  end

  @impl true
  def handle_event("collapse_all_dirs", _params, socket) do
    # Collapse the whole tree for the acting context: empty submap on SHOW,
    # empty flat map on :commit.
    tree = socket.assigns.tree_expanded_dirs || %{}

    tree =
      if socket.assigns.live_action == :commit do
        %{}
      else
        Map.put(tree, socket.assigns.active_repo_id, %{})
      end

    {:noreply, assign(socket, :tree_expanded_dirs, tree)}
  end

  @impl true
  def handle_event("expand_all_dirs", _params, socket) do
    # Expand every directory: ALL ancestor path segments of every file path
    # (except the "." root) are marked true. On SHOW the expansion applies to
    # the ACTIVE repo's file list; on :commit to the commit's files.
    files =
      if socket.assigns.live_action == :commit do
        (socket.assigns.commit_data && socket.assigns.commit_data.files) || []
      else
        (socket.assigns.review_data && socket.assigns.review_data.files) || []
      end

    all_dirs = State.dir_paths(files)
    tree = socket.assigns.tree_expanded_dirs || %{}

    tree =
      if socket.assigns.live_action == :commit do
        Map.merge(tree, all_dirs)
      else
        sub = Map.get(tree, socket.assigns.active_repo_id, %{})
        Map.put(tree, socket.assigns.active_repo_id, Map.merge(sub, all_dirs))
      end

    {:noreply, assign(socket, :tree_expanded_dirs, tree)}
  end

  @impl true
  def handle_event("filter_files", %{"filter" => value}, socket) do
    # The files-changed toolbar's filter input (debounced on the client).
    # The filter string is shared across repos and cleared on switch_repo.
    {:noreply, assign(socket, :file_filter, value || "")}
  end

  @impl true
  def handle_event("toggle_summary_view", %{"mode" => mode}, socket) do
    {:noreply, assign(socket, :summary_raw, mode == "raw")}
  end

  @impl true
  def handle_event("toggle_objective_view", %{"mode" => mode}, socket) do
    {:noreply, assign(socket, :objective_raw, mode == "raw")}
  end

  @impl true
  def handle_event("copied", _params, socket) do
    {:noreply, put_flash(socket, :info, gettext("Copied to clipboard"))}
  end

  @impl true
  def handle_event("retry_load", _params, socket) do
    # Retries the async review-data load from the error panel (the load is
    # exit-safe, so an error is a value the user can recover from without a
    # page refresh).
    {:noreply, start_async_load(socket, Map.get(socket.assigns, :inspect_commit_sha))}
  end

  @impl true
  def handle_event("retry_remote_connection", _params, socket) do
    EvoDashWeb.LiveHooks.NodeAware.initiate_remote_connect(socket, socket.assigns.current_node_id)
    {:noreply, socket}
  end

  @impl true
  def handle_event("switch_to_local", _params, socket) do
    send(self(), {:node_selected, "local"})
    {:noreply, socket}
  end

  @impl true
  def handle_event("select_file", %{"path" => path}, socket) do
    scope = Diffs.diff_scope(socket)

    if Diffs.file_present?(socket, scope, path) do
      socket =
        if scope == :commit do
          assign(socket,
            selected_file: path,
            expanded_files: Map.put(socket.assigns.expanded_files, path, true)
          )
        else
          selected = Map.put(socket.assigns.selected_file || %{}, scope, path)

          expanded =
            Map.update(socket.assigns.expanded_files, scope, %{path => true}, fn files ->
              Map.put(files, path, true)
            end)

          assign(socket,
            selected_file: selected,
            expanded_files: expanded,
            review_tab: :files_changed
          )
        end

      {:noreply,
       socket
       |> Diffs.maybe_start(path)
       |> push_event("scroll_to_file", %{
         target_id: EvoDashWeb.ReviewComponents.DiffViewer.file_section_id(path)
       })}
    else
      {:noreply, socket}
    end
  end

  @impl true
  def handle_event("toggle_file_expansion", %{"path" => path}, socket) do
    if socket.assigns.live_action == :commit do
      # :commit route keeps today's legacy flat path-keyed behavior.
      expanded_files = socket.assigns.expanded_files
      current = Map.get(expanded_files, path, false)
      new_expanded = Map.put(expanded_files, path, !current)
      socket = assign(socket, :expanded_files, new_expanded)

      # Expanding a file whose diff is nil fetches it off-process; collapsing
      # never triggers a load.
      if current do
        {:noreply, socket}
      else
        {:noreply, Diffs.maybe_start(socket, path)}
      end
    else
      # SHOW route: per-repo expansion map keyed by repo_id — toggle only the
      # ACTIVE repo's submap.
      expanded = socket.assigns.expanded_files || %{}
      sub = Map.get(expanded, socket.assigns.active_repo_id, %{})
      now_expanded? = not Map.get(sub, path, false)

      sub =
        if now_expanded?, do: Map.put(sub, path, true), else: Map.delete(sub, path)

      expanded = Map.put(expanded, socket.assigns.active_repo_id, sub)

      socket =
        socket
        |> assign(:expanded_files, expanded)
        |> State.project_active_repo()

      # Expanding a file whose diff is nil fetches it off-process; collapsing
      # never triggers a load.
      if now_expanded? do
        {:noreply, Diffs.maybe_start(socket, path)}
      else
        {:noreply, socket}
      end
    end
  end

  @impl true
  def handle_event("load_file_diff", %{"path" => path}, socket) do
    {:noreply, Diffs.maybe_start(socket, path)}
  end

  @impl true
  def handle_event("expand_context", %{"path" => path}, socket) do
    # SHOW route reads the context level from the ACTIVE repo's submap;
    # :commit keeps today's legacy flat path-keyed state.
    current_level = Diffs.context_level(socket, Diffs.diff_scope(socket), path)

    new_level =
      cond do
        current_level == :all -> :all
        current_level >= 30 -> :all
        true -> current_level + 20
      end

    opts = if new_level == :all, do: [context: :all], else: [context: new_level]

    # The re-fetch with a wider context window runs off-process; the level it
    # asks for travels in the action ref so the apply step writes it back.
    {:noreply, Diffs.start(socket, path, :expand_context, new_level, opts)}
  end

  @impl true
  def handle_event("merge", params, socket) do
    # Dispatched ONLY by a per-repo merge form submit: the hidden `repo_id`
    # names the ONE repo this submit acts on. Whitelist against the known
    # review-repo ids (never String.to_atom on client input); an unknown id, a
    # repo already in a TERMINAL resolution, OR a repo with NO changes (nil/blank
    # branch — nothing to merge) is a no-op — never fan out to the other repos.
    # The merge itself runs off-process (Actions.merge) and reports back as a
    # {:review_action_result, ...} message.
    repo_id = params["repo_id"]

    with nil <- socket.assigns.review_action,
         %{} = repo <- State.find_review_repo(socket.assigns.review_repos, repo_id),
         false <- State.repo_actionable?(repo) do
      target = State.resolve_merge_target(repo, params)
      {seq, socket} = State.next_action_seq(socket)

      socket =
        socket
        |> assign(:review_action, %{kind: :merge, repo_id: repo_id, seq: seq})
        |> assign(:busy_repos, MapSet.put(socket.assigns.busy_repos, repo_id))

      node = socket.assigns.current_node
      repo_path = repo.repo_path
      branch_name = repo.branch_name

      {:noreply,
       Runner.spawn(socket, :merge, %{repo_id: repo_id, target: target, seq: seq}, fn ->
         Actions.merge(node, repo_path, branch_name, target)
       end)}
    else
      _ -> {:noreply, socket}
    end
  end

  @impl true
  def handle_event("merge_all", _params, socket) do
    # Batch shortcut on a multi-repo review (rendered only when >= 2
    # CHANGE-BEARING repos are still unresolved): merge EVERY unresolved repo
    # that HAS changes into its own target, BEST-EFFORT per repo. A no-change
    # repo (nil/blank branch) is excluded — it has nothing to merge and needs no
    # action. Each repo settles independently — a conflict/error surfaces on THAT
    # repo's card while the others still merge, and the shared completion routine
    # (settle_repo_action/4) persists the aggregate review_status once the last
    # one reaches terminal. No navigation: the page stays mounted with one batch
    # summary flash.
    actionable =
      Enum.filter(
        socket.assigns.review_repos,
        &(Map.get(&1, :resolution) == nil and RepoCards.repo_has_changes?(&1))
      )

    case {socket.assigns.review_action, actionable} do
      {action, _} when action != nil ->
        # An action is already in flight — never stack a second batch on it.
        {:noreply, socket}

      {nil, []} ->
        # Nothing left to merge (the button is hidden in this state anyway).
        {:noreply, socket}

      {nil, repos} ->
        # The merge-target select writes the chosen branch back into the
        # repo's `default_merge_target` (MergeCheck.handle_target_change/2),
        # so that — then the first known target — is the batch target.
        entries =
          Enum.map(repos, fn repo ->
            %{
              repo_id: repo.repo_id,
              repo_path: repo.repo_path,
              branch_name: repo.branch_name,
              target: repo.default_merge_target || List.first(repo.merge_targets || [])
            }
          end)

        repo_ids = Enum.map(entries, & &1.repo_id)
        {seq, socket} = State.next_action_seq(socket)

        socket =
          socket
          |> assign(:review_action, %{kind: :merge_all, seq: seq})
          |> assign(:busy_repos, MapSet.union(socket.assigns.busy_repos, MapSet.new(repo_ids)))

        node = socket.assigns.current_node

        {:noreply,
         Runner.spawn(socket, :merge_all, %{repo_ids: repo_ids, seq: seq}, fn ->
           Actions.merge_all(node, entries)
         end)}
    end
  end

  @impl true
  def handle_event("merge_target_change", params, socket) do
    # The merge form's target-branch select changed: the support module
    # updates the changed repo's default target and re-runs its async dry-run
    # merge check. Re-project afterwards so the flat assigns read the ACTIVE
    # repo's @merge_status / @default_merge_target.
    socket = EvoDashWeb.ReviewLive.MergeCheck.handle_target_change(socket, params)
    {:noreply, State.project_active_repo(socket)}
  end

  @impl true
  def handle_event("auto_resolve", _params, socket) do
    # Starts a merge-resolution task (guarded on a detected conflict) — the
    # pure payload comes from MergeCheck.auto_resolve_payload/1, the I/O runs
    # off-process (Actions.auto_resolve/3).
    #
    # auto_resolve stays PRIMARY-scoped by design: it reads the `"primary"`
    # entry's conflict state. A conflict in a FOREIGN repo is surfaced on that
    # repo's own card (its per-repo resolution + async merge check) and must be
    # resolved there or in a new task — only the primary's conflict drives this
    # aggregate action.
    with nil <- socket.assigns.review_action,
         {:ok, payload} <- EvoDashWeb.ReviewLive.MergeCheck.auto_resolve_payload(socket) do
      {seq, socket} = State.next_action_seq(socket)

      socket =
        socket
        |> assign(:review_action, %{kind: :auto_resolve, seq: seq})
        |> assign(:action_loading, true)

      node = socket.assigns.current_node
      task_id = socket.assigns.task_id

      {:noreply,
       Runner.spawn(socket, :auto_resolve, %{to: payload.to, seq: seq}, fn ->
         Actions.auto_resolve(node, task_id, payload.opts)
       end)}
    else
      :unavailable ->
        {:noreply,
         put_flash(
           socket,
           :error,
           gettext("Auto-resolve unavailable — no merge conflict detected.")
         )}

      _action_in_flight ->
        {:noreply, socket}
    end
  end

  @impl true
  def handle_event("reject", params, socket) do
    # Dispatched ONLY by a per-repo reject button: `repo_id` names the ONE repo
    # this click acts on (whitelisted; unknown/Terminal/no-changes → no-op).
    # Never fan out to the other repos. The branch deletion runs off-process
    # (Actions.reject/3) on the node being viewed (local → direct call,
    # remote → RPC).
    repo_id = params["repo_id"]

    with nil <- socket.assigns.review_action,
         %{} = repo <- State.find_review_repo(socket.assigns.review_repos, repo_id),
         false <- State.repo_actionable?(repo) do
      {seq, socket} = State.next_action_seq(socket)

      socket =
        socket
        |> assign(:review_action, %{kind: :reject, repo_id: repo_id, seq: seq})
        |> assign(:busy_repos, MapSet.put(socket.assigns.busy_repos, repo_id))

      node = socket.assigns.current_node
      repo_path = repo.repo_path
      branch_name = repo.branch_name

      {:noreply,
       Runner.spawn(socket, :reject, %{repo_id: repo_id, seq: seq}, fn ->
         Actions.reject(node, repo_path, branch_name)
       end)}
    else
      _ -> {:noreply, socket}
    end
  end

  @impl true
  def handle_event("open_repo_diff", %{"repo_id" => repo_id}, socket) do
    # Per-repo "jump to this repo's diff" button on a repo card: switch the
    # active repo and land on the Files-changed tab. Whitelist the id against
    # the known review repos; an unknown id is a harmless no-op.
    if State.find_review_repo(socket.assigns.review_repos, repo_id) do
      {:noreply,
       socket
       |> assign(:active_repo_id, repo_id)
       |> assign(:review_tab, :files_changed)
       |> State.project_active_repo()}
    else
      {:noreply, socket}
    end
  end

  def handle_event("open_repo_diff", _params, socket) do
    {:noreply, socket}
  end

  @impl true
  def handle_event("resume", _params, socket) do
    # PRIMARY-scoped (documented limitation): repo-scoped fields come from the
    # "primary" entry explicitly, never from the flat (active-repo-projected)
    # assigns — a foreign repo tab must not change what resume prepares. The
    # entry itself is the CACHED derived assign (Aggregates.primary/1), so this
    # handler never re-walks the repo list. The review-status write runs
    # off-process (Actions.set_review_status/3); the navigation happens when
    # its result lands.
    primary = socket.assigns.primary_repo

    commit_sha = primary && primary.commit_sha
    branch_name = primary && primary.branch_name
    task_id = socket.assigns.task_id
    repo_path = primary && primary.repo_path

    query = [resume_from: task_id]
    query = if commit_sha, do: Keyword.put(query, :starting_commit, commit_sha), else: query
    # Include project query param so the dashboard re-opens the correct project
    query = if repo_path, do: Keyword.put(query, :project, repo_path), else: query

    # The target URL already carries a query string, so with_node_param's `?`
    # append does not apply — a manual `&node=` suffix preserves the node
    # context (same pattern as project_flow.ex's project_url/2).
    to =
      case socket.assigns.current_node_id do
        nil -> ~p"/projects?#{query}"
        node_id -> ~p"/projects?#{query}" <> "&node=" <> node_id
      end

    flash_msg =
      if commit_sha do
        gettext("Resuming from branch %{branch} at %{sha}",
          branch: branch_name,
          sha: String.slice(commit_sha, 0..7)
        )
      else
        gettext(
          "Resuming from investigation task. A new evolve task form has been prepared for you."
        )
      end

    if socket.assigns.review_action do
      {:noreply, socket}
    else
      {seq, socket} = State.next_action_seq(socket)

      socket =
        socket
        |> assign(:review_action, %{kind: :resume, seq: seq})
        |> assign(:action_loading, true)

      node = socket.assigns.current_node

      {:noreply,
       Runner.spawn(socket, :resume, %{to: to, flash_msg: flash_msg, seq: seq}, fn ->
         Actions.set_review_status(node, task_id, :continued)
       end)}
    end
  end

  @impl true
  def handle_event("ignore", _params, socket) do
    task_id = socket.assigns.task_id

    if socket.assigns.review_action do
      {:noreply, socket}
    else
      {seq, socket} = State.next_action_seq(socket)

      socket =
        socket
        |> assign(:review_action, %{kind: :ignore, seq: seq})
        |> assign(:action_loading, true)

      node = socket.assigns.current_node

      {:noreply,
       Runner.spawn(
         socket,
         :ignore,
         %{
           to: with_node_param(~p"/projects", socket.assigns.current_node_id),
           flash_msg: gettext("Review ignored and dismissed."),
           seq: seq
         },
         fn -> Actions.set_review_status(node, task_id, :ignored) end
       )}
    end
  end

  @impl true
  def handle_event("create_pr", _params, socket) do
    # PRIMARY-scoped (documented limitation): see the resume handler.
    primary = socket.assigns.primary_repo

    repo_path = primary && primary.repo_path
    branch_name = primary && primary.branch_name

    %{objective: objective, agent_summary: result} = socket.assigns

    if socket.assigns.review_action do
      {:noreply, socket}
    else
      {seq, socket} = State.next_action_seq(socket)

      socket =
        socket
        |> assign(:review_action, %{kind: :create_pr, seq: seq})
        |> assign(:action_loading, true)

      node = socket.assigns.current_node

      {:noreply,
       Runner.spawn(socket, :create_pr, %{seq: seq}, fn ->
         Actions.create_pr(node, repo_path, branch_name, objective || "", result || "")
       end)}
    end
  end

  @impl true
  def handle_event("extract_skills", _params, socket) do
    {:noreply, assign(socket, :show_extract_modal, true)}
  end

  @impl true
  def handle_event("cancel_extract_skills", _params, socket) do
    {:noreply, assign(socket, :show_extract_modal, false)}
  end

  @impl true
  def handle_event("confirm_extract_skills", %{"user_note" => user_note}, socket) do
    # PRIMARY-scoped (documented limitation): repo-scoped fields (incl. the
    # commit history for the PR description) come from the "primary" entry
    # explicitly, never from the flat (active-repo-projected) assigns.
    primary = socket.assigns.primary_repo

    %{
      title: title,
      objective: objective,
      agent_summary: summary
    } = socket.assigns

    repo_path = primary && primary.repo_path
    base_sha = primary && primary.base_sha
    commit_sha = primary && primary.commit_sha
    commits = (primary && primary.commits) || []

    # Build the commit history string from the CommitInfo list
    commit_history = format_commit_history(commits)

    opts = [
      path: repo_path,
      pr_title: title,
      pr_objective: objective,
      pr_summary: summary,
      pr_commit_history: commit_history,
      base_sha: base_sha,
      commit_sha: commit_sha
    ]

    opts =
      if user_note && user_note != "", do: Keyword.put(opts, :user_note, user_note), else: opts

    if socket.assigns.review_action do
      {:noreply, socket}
    else
      {seq, socket} = State.next_action_seq(socket)

      socket =
        socket
        |> assign(:review_action, %{kind: :extract_skills, seq: seq})
        |> assign(:action_loading, true)

      # Skill extraction runs on the node being viewed (local → direct call,
      # remote → RPC), so the git ops inside start_task execute against the
      # repo on the correct host. The modal stays open until the success
      # result lands.
      node = socket.assigns.current_node

      {:noreply,
       Runner.spawn(socket, :extract_skills, %{seq: seq}, fn ->
         Actions.start_task(node, :extract_skills, opts)
       end)}
    end
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
       |> apply_action_result(action, ref, result)
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

  # --- Async action layer ---
  #
  # Review actions never run in the LiveView process: a store/registry/Git call
  # can take many seconds and a `GenServer.call` timeout EXITS the caller. Each
  # handler computes a cheap plan, marks the in-progress state, and spawns the
  # work through `Runner.spawn/4`; the outcome arrives as
  # `{:review_action_result, task_id, node, action, action_ref, result}` and is
  # applied by `apply_action_result/4` (after the in-progress state is cleared).

  # Applies an action result. `result` is `{:ok, outcome}` (SafeCall's ok
  # wrapping of an `Actions` outcome) or `{:error, reason}` (an exit /
  # exception / throw captured by the boundary).
  defp apply_action_result(socket, :merge, ref, result) do
    repo_id = ref.repo_id
    branch = repo_branch(socket, repo_id)

    case result do
      {:ok, {:merged, target}} ->
        settle_repo_action(
          socket,
          repo_id,
          %{state: :merged, target: target},
          merged_flash(target, branch)
        )

      {:ok, {:conflict, details}} ->
        resolve_non_terminal(
          socket,
          repo_id,
          :conflict,
          truncate_string(details, 200),
          gettext(
            "Merge conflict in %{branch}. Resolve it in the repository, or start an auto-resolve task from the primary repo.",
            branch: branch
          )
        )

      other ->
        merge_failure(socket, repo_id, unwrap_error(other))
    end
  end

  defp apply_action_result(socket, :merge_all, _ref, result) do
    case result do
      {:ok, outcomes} when is_list(outcomes) ->
        # One batch: every repo settles on its own card (merged → resolution
        # recorded, conflict/error → non-terminal state) but the flash is a
        # SINGLE summary — no per-repo flashes.
        {socket, merged} = Enum.reduce(outcomes, {socket, 0}, &settle_batch_outcome/2)

        {kind, message} = merge_all_flash(merged, length(outcomes))

        socket
        |> put_flash(kind, message)
        |> maybe_persist_completion()

      _ ->
        put_flash(
          socket,
          :error,
          gettext("Could not merge the repositories — see the repository cards for details.")
        )
    end
  end

  defp apply_action_result(socket, :reject, ref, result) do
    branch = repo_branch(socket, ref.repo_id)

    case result do
      {:ok, :rejected} ->
        settle_repo_action(
          socket,
          ref.repo_id,
          %{state: :rejected},
          gettext("Changes rejected. Branch %{branch} has been deleted.", branch: branch)
        )

      other ->
        reason = inspect(unwrap_error(other))

        resolve_non_terminal(
          socket,
          ref.repo_id,
          :error,
          reason,
          gettext("Failed to reject changes: %{reason}", reason: reason)
        )
    end
  end

  # Resume/ignore navigate UNCONDITIONALLY: the click expresses user intent and
  # the review-status write is advisory. A dead/unknown remote node (or any
  # other write failure) must still take the user to the prepared target, with
  # an error flash carried across the redirect — the previous hard gate left
  # the user stranded on the review page.
  defp apply_action_result(socket, action, ref, result) when action in [:resume, :ignore] do
    case result do
      {:ok, :ok} ->
        socket
        |> State.invalidate_active_tasks()
        |> put_flash(:info, ref.flash_msg)
        |> push_navigate(to: ref.to)

      other ->
        socket
        |> put_flash(
          :error,
          gettext("Failed to update review status: %{reason}",
            reason: inspect(unwrap_error(other))
          )
        )
        |> push_navigate(to: ref.to)
    end
  end

  defp apply_action_result(socket, :create_pr, _ref, result) do
    case result do
      {:ok, {:pr, url, title}} ->
        socket
        |> assign(has_pr: true, pr_url: url)
        |> put_flash(:success, gettext("Pull request created: %{title}", title: title || url))

      {:ok, :no_pr} ->
        put_flash(
          socket,
          :error,
          gettext(
            "Failed to create pull request. Make sure 'gh' CLI is installed and authenticated."
          )
        )

      other ->
        put_flash(
          socket,
          :error,
          gettext("Failed to create pull request: %{reason}",
            reason: inspect(unwrap_error(other))
          )
        )
    end
  end

  defp apply_action_result(socket, :extract_skills, _ref, result) do
    case result do
      {:ok, {:ok, _task}} ->
        socket
        |> assign(:show_extract_modal, false)
        |> put_flash(
          :info,
          gettext("Skill extraction task started. You can monitor its progress on the dashboard.")
        )

      other ->
        put_flash(
          socket,
          :error,
          gettext("Failed to start skill extraction: %{reason}",
            reason: inspect(unwrap_error(other))
          )
        )
    end
  end

  defp apply_action_result(socket, :auto_resolve, ref, result) do
    case result do
      {:ok, {:ok, _task}} ->
        socket
        |> State.invalidate_active_tasks()
        |> put_flash(
          :success,
          gettext(
            "Auto-resolve task started. It will merge the changes and resolve conflicts; review its result when done."
          )
        )
        |> push_navigate(to: ref.to)

      other ->
        put_flash(
          socket,
          :error,
          gettext("Failed to start auto-resolve: %{reason}",
            reason: inspect(unwrap_error(other))
          )
        )
    end
  end

  defp apply_action_result(socket, :completion, _ref, result) do
    case result do
      {:ok, :ok} ->
        socket

      other ->
        put_flash(
          socket,
          :error,
          gettext("Failed to update review status: %{reason}",
            reason: inspect(unwrap_error(other))
          )
        )
    end
  end

  # Lazy file-diff loads (`:diff`) and their context expansions
  # (`:expand_context`): the result is applied only when it is still the CURRENT
  # request for its `{scope, path}` key and the file is still on screen in that
  # scope — see Diffs.apply_result/4.
  defp apply_action_result(socket, action, ref, result) when action in [:diff, :expand_context] do
    key = {Map.get(ref, :repo_id), Map.get(ref, :path)}

    # The in-flight entry holds the seq of the LATEST load started for this
    # {scope, path}. A different value means a newer request superseded this
    # one (and owns the entry), so the stale result is dropped untouched.
    if Map.get(socket.assigns.diff_in_flight, key) != Map.get(ref, :seq) do
      socket
    else
      Diffs.apply_result(socket, action, ref, result)
    end
  end

  # An unexpected action shape must never crash the page.
  defp apply_action_result(socket, _action, _ref, _result), do: socket

  # One batch outcome: a merged repo records its TERMINAL resolution and counts
  # toward the batch tally; a conflict/error repo lands in its non-terminal
  # state (detail only, no flash — the batch owns the single flash) and does
  # not abort the rest of the batch.
  defp settle_batch_outcome({repo_id, outcome}, {socket, merged}) when is_binary(repo_id) do
    case outcome do
      {:merged, target} ->
        {State.set_repo_resolution(socket, repo_id, %{state: :merged, target: target}),
         merged + 1}

      {:conflict, details} ->
        {State.set_repo_resolution(
           socket,
           repo_id,
           %{state: :conflict, detail: truncate_string(details, 200)}
         ), merged}

      {:error, reason} ->
        {State.set_repo_resolution(socket, repo_id, %{state: :error, detail: inspect(reason)}),
         merged}

      _other ->
        {socket, merged}
    end
  end

  defp settle_batch_outcome(_other, acc), do: acc

  # The batch result's error reason: an `{:error, reason}` wrapper unwraps to
  # `reason`, any other shape passes through for `inspect/1`.
  defp unwrap_error({:error, reason}), do: reason
  defp unwrap_error(other), do: other

  defp merge_failure(socket, repo_id, reason) do
    inspected = inspect(reason)

    resolve_non_terminal(
      socket,
      repo_id,
      :error,
      inspected,
      gettext("Merge failed: %{reason}", reason: inspected)
    )
  end

  # A repo's current branch name (nil when the repo is gone).
  defp repo_branch(socket, repo_id) do
    case State.find_review_repo(socket.assigns.review_repos, repo_id) do
      %{} = repo -> Map.get(repo, :branch_name)
      _ -> nil
    end
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

  defp format_commit_history([]), do: nil

  defp format_commit_history(commits) do
    commits
    |> Enum.map(fn commit ->
      "#{commit.short_sha || commit.sha} (#{commit.author_name}, #{commit.date}): #{commit.message}"
    end)
    |> Enum.join("\n")
  end

  # The batch summary flash for merge_all/1: all merged → success, otherwise an
  # error naming how many landed (the batch puts ONE flash, never per-repo ones).
  defp merge_all_flash(merged, total) when total > 0 and merged == total do
    {:success, gettext("Successfully merged %{count} repositories.", count: total)}
  end

  defp merge_all_flash(0, total) do
    {:error,
     gettext(
       "Could not merge any of the %{total} repositories — see the repository cards for details.",
       total: total
     )}
  end

  defp merge_all_flash(merged, total) do
    # 部分仓库合并失败，其余成功，请查看各仓库卡片
    {:error,
     gettext(
       "Merged %{merged} of %{total} repositories. The remaining repositories could not be merged — see their repository cards for details.",
       merged: merged,
       total: total
     )}
  end

  # Shared tail of a TERMINAL per-repo action (merge/reject succeeded): records
  # the resolution, then either COMPLETES the whole review (every repo TERMINAL
  # → persist the aggregate review_status + invalidate the sidebar hub snapshot)
  # or STAYS on the page with a success flash (other repos still pending).
  # Returns the updated socket.
  defp settle_repo_action(socket, repo_id, resolution, success_flash) do
    socket
    |> State.set_repo_resolution(repo_id, resolution)
    |> put_flash(:success, success_flash)
    |> maybe_persist_completion()
  end

  # Persists the aggregate review status when the review is COMPLETE (every
  # change-bearing repo terminal). The store write runs off-process
  # (`:completion` action, no in-progress marker — it is a background
  # bookkeeping write) and the sidebar hub snapshot is invalidated right away so
  # the destination mount is COLD and re-fetches instead of seeding the
  # pre-action state.
  defp maybe_persist_completion(socket) do
    # Reads the CACHED completion (put_derived/1 runs in set_repo_resolution/3,
    # i.e. before this function in the same action tail) instead of re-walking
    # the repo list.
    case socket.assigns.completion_status do
      nil ->
        socket

      status ->
        {seq, socket} = State.next_action_seq(socket)
        node = socket.assigns.current_node
        task_id = socket.assigns.task_id

        socket
        |> assign(:review_status, status)
        # review_status is one of the three inputs of the aggregate, so the
        # derived values are refreshed once it changed.
        |> State.put_derived()
        |> State.invalidate_active_tasks()
        |> Runner.spawn(:completion, %{status: status, seq: seq}, fn ->
          Actions.set_review_status(node, task_id, status)
        end)
    end
  end

  # Shared tail of a NON-terminal per-repo action (conflict / error): the repo
  # stays retryable, so record the outcome on its own card and STAY on the page.
  # Returns the updated socket (callers wrap it in {:noreply, _}).
  defp resolve_non_terminal(socket, repo_id, state, detail, error_flash) do
    socket = State.set_repo_resolution(socket, repo_id, %{state: state, detail: detail})
    put_flash(socket, :error, error_flash)
  end

  defp merged_flash(target, branch) when is_binary(target) and target != "" do
    gettext("Changes merged successfully into %{target}! Branch %{branch} has been deleted.",
      target: target,
      branch: branch
    )
  end

  defp merged_flash(_target, branch) do
    gettext("Changes merged successfully! Branch %{branch} has been deleted.", branch: branch)
  end

  defp previous_review_repo(%{
         live_action: :show,
         current_node: node,
         tasks_loaded_for: {node, :commit, _, repo_id}
       }),
       do: repo_id

  defp previous_review_repo(_), do: nil
end
