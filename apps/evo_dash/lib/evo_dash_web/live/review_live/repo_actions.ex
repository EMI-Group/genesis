defmodule EvoDashWeb.ReviewLive.RepoActions do
  @moduledoc """
  Per-repo review ACTIONS of `EvoDashWeb.ReviewLive` — merge (single and batch),
  the merge-target select, auto-resolve, reject, the repo `<select>` switch and
  the "jump to this repo's diff" button.

  Every function here is an event handler in the shape the page's dispatcher
  expects — `(socket, params)` in, `{:noreply, socket}` out. The work itself
  never runs in the LiveView process: each handler validates the submit,
  records the in-progress state and spawns the I/O through
  `EvoDashWeb.ReviewLive.Runner.spawn/4`; the outcome lands in
  `EvoDashWeb.ReviewLive.ActionResults`.
  """
  use Gettext, backend: EvoDashWeb.Gettext

  # `RepoCards.repo_has_changes?/1` is the SINGLE source of the "does this repo
  # have changes?" test (also used by RepoCards' own merge-all gate).
  alias EvoDashWeb.ReviewComponents.RepoCards
  alias EvoDashWeb.ReviewLive.Actions
  alias EvoDashWeb.ReviewLive.MergeCheck
  alias EvoDashWeb.ReviewLive.Runner
  alias EvoDashWeb.ReviewLive.State

  import Phoenix.Component, only: [assign: 3]
  import Phoenix.LiveView, only: [put_flash: 3]

  # Repo <select>s live inside components; each is wrapped in its own
  # <form phx-change="switch_repo">, so the payload arrives as
  # %{"repo_id" => repo_id}. A form-less select (legacy shape) delivers the
  # generic "value" key instead of the field name — accept both defensively.
  def switch_repo(socket, %{"repo_id" => repo_id}) do
    {:noreply, State.switch_repo(socket, repo_id)}
  end

  def switch_repo(socket, %{"value" => repo_id}) do
    {:noreply, State.switch_repo(socket, repo_id)}
  end

  def merge(socket, params) do
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

  def merge_all(socket, _params) do
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

  def merge_target_change(socket, params) do
    # The merge form's target-branch select changed: the support module
    # updates the changed repo's default target and re-runs its async dry-run
    # merge check. Re-project afterwards so the flat assigns read the ACTIVE
    # repo's @merge_status / @default_merge_target.
    socket = MergeCheck.handle_target_change(socket, params)
    {:noreply, State.project_active_repo(socket)}
  end

  def auto_resolve(socket, _params) do
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
         {:ok, payload} <- MergeCheck.auto_resolve_payload(socket) do
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

  def reject(socket, params) do
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

  # Per-repo "jump to this repo's diff" button on a repo card: switch the
  # active repo and land on the Files-changed tab. Whitelist the id against
  # the known review repos; an unknown id is a harmless no-op.
  def open_repo_diff(socket, %{"repo_id" => repo_id}) do
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

  def open_repo_diff(socket, _params) do
    {:noreply, socket}
  end
end
