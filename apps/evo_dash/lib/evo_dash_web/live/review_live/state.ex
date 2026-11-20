defmodule EvoDashWeb.ReviewLive.State do
  @moduledoc """
  Pure socket/derived-state helpers for `EvoDashWeb.ReviewLive`.

  Everything here takes and returns a LiveView socket (or plain values): NO
  I/O, NO spawned work and NO flash text. The page's mutations of
  `@review_repos` / `@review_status` funnel through `put_derived/1`, the flat
  per-repo projections through `project_active_repo/1`, and a per-repo action
  outcome through `set_repo_resolution/3`.
  """

  # `RepoCards.repo_has_changes?/1` is the SINGLE source of the "does this repo
  # have changes?" test (also used by RepoCards' own merge-all gate).
  alias EvoDashWeb.ReviewComponents.RepoCards

  # The render-body derivations (aggregate stats, the PRIMARY lookup, the
  # aggregate completion status) — computed ONCE per data mutation, never in
  # the render. See put_derived/1.
  alias EvoDashWeb.ReviewLive.Aggregates

  import Phoenix.Component, only: [assign: 2, assign: 3]

  # A repo offers no action once its resolution is TERMINAL or it has no
  # changes (nil/blank branch — nothing to merge or reject).
  def repo_actionable?(repo) do
    Aggregates.terminal_resolution?(Map.get(repo, :resolution)) or
      not RepoCards.repo_has_changes?(repo)
  end

  # Monotonic action-ref counter (mirrors `load_generation`): every spawned
  # action carries the current sequence in its ref.
  def next_action_seq(socket) do
    seq = Map.get(socket.assigns, :action_seq, 0) + 1
    {seq, assign(socket, :action_seq, seq)}
  end

  # Refreshes the DERIVED assigns (`stats`, `primary_repo`,
  # `completion_status`) from the CURRENT `@review_repos` / `@review_status`.
  #
  # These used to be computed in the render body, so every tab switch, keystroke
  # in the file filter and debounced task broadcast re-walked the repo list.
  # Instead EVERY mutation of those two assigns funnels through here — the
  # event pays for the derivation once and the render just reads plain assigns.
  #
  # The single ordering rule: `set_repo_resolution/3` refreshes these BEFORE
  # `maybe_persist_completion/1` reads `completion_status`, which is guaranteed
  # because `settle_repo_action/4` runs them in exactly that order.
  def put_derived(socket) do
    review_repos = socket.assigns.review_repos
    review_status = socket.assigns.review_status

    assign(socket,
      stats: Aggregates.stats(review_repos),
      primary_repo: Aggregates.primary(review_repos),
      completion_status: Aggregates.completion_status(review_repos, review_status)
    )
  end

  # Projects the ACTIVE repo's per-repo data onto the flat assigns the template
  # and action components read (repo_path/branch_name/commit_sha/base_sha/
  # branch_exists/review_data/commits/merge_targets/default_merge_target/
  # merge_status). The :commit route is a NO-OP — it keeps today's legacy flat
  # path-keyed state (single repo, no review_repos). The diff-state maps
  # (selected_file / expanded_files / file_context_levels) are NOT re-projected
  # here: they hold the canonical repo-keyed per-repo state, and the template
  # reads the ACTIVE repo's submap via inline Map.get (see the :files_changed
  # tab in render/1). Falls back to the primary entry when the active id is not
  # found (defensive — switch_repo whitelists, so this only guards reloads).
  def project_active_repo(socket) do
    if socket.assigns.live_action == :commit do
      socket
    else
      active_repo_id = socket.assigns.active_repo_id

      repo =
        Enum.find(socket.assigns.review_repos, &(&1.repo_id == active_repo_id)) ||
          Aggregates.primary(socket.assigns.review_repos)

      assign(socket,
        repo_path: repo && repo.repo_path,
        branch_name: repo && repo.branch_name,
        commit_sha: repo && repo.commit_sha,
        base_sha: repo && repo.base_sha,
        branch_exists: (repo && repo.branch_exists) || false,
        review_data: repo && repo.review_data,
        commits: (repo && repo.commits) || [],
        merge_targets: (repo && repo.merge_targets) || [],
        default_merge_target: repo && repo.default_merge_target,
        merge_status: repo && repo.merge_status
      )
    end
  end

  # Whitelist-validate the submitted repo id against the known review repos
  # (never String.to_atom on client input). Per-repo diff state is keyed by
  # repo_id and persists across switches — only the active id, the flat
  # projections, and the shared file filter change. Shared by both switch_repo
  # handler clauses (%{"repo_id" => id} from form-wrapped selects and the
  # form-less %{"value" => id} legacy shape).
  def switch_repo(socket, repo_id) do
    if repo_id in Enum.map(socket.assigns.review_repos, & &1.repo_id) do
      socket
      |> assign(:active_repo_id, repo_id)
      # The filter string is shared across repos — reset it so switching
      # never leaves the new repo's file list filtered by stale text.
      |> assign(:file_filter, "")
      |> project_active_repo()
    else
      socket
    end
  end

  # Finds one review-repo entry by its whitelisted id: the untrusted client
  # string is compared against the known ids (never String.to_atom). A missing
  # or non-binary id finds nothing.
  def find_review_repo(review_repos, repo_id) when is_binary(repo_id) do
    Enum.find(review_repos, &(&1.repo_id == repo_id))
  end

  def find_review_repo(_review_repos, _repo_id), do: nil
  # Resolves the branch a per-repo merge submits into: the trimmed
  # `target_branch` param, validated against the repo's known target list
  # (falling back to its resolved default when the submitted value is not a
  # member — or when the param is blank/absent).
  def resolve_merge_target(repo, params) do
    submitted =
      case params["target_branch"] do
        target when is_binary(target) -> String.trim(target)
        _ -> ""
      end

    case submitted do
      "" ->
        repo.default_merge_target

      target ->
        if repo.merge_targets != [] and target not in repo.merge_targets do
          repo.default_merge_target
        else
          target
        end
    end
  end

  # Writes one repo's RESOLUTION into @review_repos (clearing branch_exists on a
  # TERMINAL outcome — the branch was deleted) and re-projects the flat assigns.
  # Reuses MergeCheck.update_repo/3 (the single per-entry update path).
  #
  # This is the SINGLE funnel written ONLY by the in-page action tail (merge /
  # reject / merge_all) — never by the load seeding or test fixtures — so it
  # ALSO records the resolution in the dedicated :local_repo_resolutions assign.
  # That assign lets a self-triggered reload (the page's own review-status
  # broadcast → 300ms debounce → load_data, which re-derives resolutions from
  # REPOSITORY state alone) keep the outcome the user just earned instead of
  # reverting the settled card (see carry_local_resolutions/2).
  def set_repo_resolution(socket, repo_id, resolution) do
    recorded = Map.put(socket.assigns.local_repo_resolutions, repo_id, resolution)

    socket
    |> assign(:local_repo_resolutions, recorded)
    |> EvoDashWeb.ReviewLive.MergeCheck.update_repo(repo_id, fn repo ->
      repo
      |> Map.put(:resolution, resolution)
      |> maybe_clear_branch(resolution)
    end)
    |> project_active_repo()
    # Refresh the derived completion BEFORE any caller reads it (see
    # maybe_persist_completion/1).
    |> put_derived()
  end

  defp maybe_clear_branch(repo, %{state: state}) when state in [:merged, :rejected],
    do: %{repo | branch_exists: false}

  defp maybe_clear_branch(repo, _resolution), do: repo
  # Applies a freshly loaded assigns map (from LoadData) with the in-page
  # action-earned TERMINAL resolutions overlaid onto @review_repos.
  #
  # load_data derives each repo's resolution from REPOSITORY state ONLY
  # (build_repo_entry/2: :handled when a non-blank branch no longer exists, else
  # nil). A reload triggered by the page's OWN review-status broadcast therefore
  # knows nothing about the action just taken and would revert the settled card
  # (dropping the completion banner for a fully-resolved review). Overlay the
  # dedicated :local_repo_resolutions entries — and ONLY those, never the
  # fixture/seeded values in @review_repos — for repos whose loaded resolution
  # is nil; when the load independently determined a resolution (e.g. a truly
  # gone branch → :handled) that value stays authoritative. Entries for repos no
  # longer in the loaded list are dropped so the map cannot grow unboundedly.
  def carry_local_resolutions(assigns_map, assigns) do
    local = Map.get(assigns, :local_repo_resolutions, %{})

    case {Map.get(assigns_map, :review_repos), is_map(local)} do
      {review_repos, true} when is_list(review_repos) and local != %{} ->
        {review_repos, local} = overlay_local_resolutions(review_repos, local)

        assigns_map
        |> Map.put(:review_repos, review_repos)
        |> Map.put(:local_repo_resolutions, local)

      _ ->
        assigns_map
    end
  end

  # Overlays the TERMINAL entries of `local` onto the loaded `review_repos`
  # (repo_id match, loaded resolution nil only) and returns the pruned `local`
  # (kept only for repos still present in the loaded list).
  defp overlay_local_resolutions(review_repos, local) do
    present_ids = review_repos |> Enum.map(&Map.get(&1, :repo_id)) |> MapSet.new()
    local = Map.take(local, MapSet.to_list(present_ids))

    overlaid =
      Enum.map(review_repos, fn repo ->
        resolution = Map.get(local, Map.get(repo, :repo_id))

        if Aggregates.terminal_resolution?(resolution) and Map.get(repo, :resolution) == nil do
          Map.put(repo, :resolution, resolution)
        else
          repo
        end
      end)

    {overlaid, local}
  end

  # Every ancestor directory path of every file path (each `Path.dirname`
  # chain segment), excluding the "." root — e.g. "a/b/c.ex" yields
  # ["a", "a/b"]. Drives expand_all_dirs: marking all ancestors true fully
  # opens the tree so every file is visible.
  def dir_paths(files) do
    files
    |> Enum.reduce(MapSet.new(), fn file, acc ->
      file.path
      |> dir_chain()
      |> Enum.reduce(acc, fn dir, acc -> MapSet.put(acc, dir) end)
    end)
    |> MapSet.to_list()
    |> Map.new(fn dir -> {dir, true} end)
  end

  defp dir_chain(path) do
    path
    |> Path.dirname()
    |> dir_chain([])
  end

  defp dir_chain(".", acc), do: acc

  defp dir_chain(dir, acc), do: dir_chain(Path.dirname(dir), [dir | acc])
  # Review actions on completed tasks (merge/reject/resume/ignore success
  # paths) change the task's review status, which removes it from the sidebar's
  # pending-review partition. Invalidate the `EvoDash.ActiveTasks` hub snapshot
  # for the ACTING node context ({current_node_id, current_node} — the same key
  # the hub keys on) right after the set_review_status call and before the
  # push_navigate, so the destination mount is COLD and re-fetches via the
  # existing machinery instead of seeding the pre-action snapshot (which would
  # keep the acted-on task listed until some unrelated task event). Only ever
  # called on status-change success paths that navigate away — partial-failure
  # branches that stay on the page must NOT invalidate (a still-mounted page
  # refreshes via the existing broadcast → 300ms debounce path).
  def invalidate_active_tasks(socket) do
    EvoDash.ActiveTasks.invalidate(socket.assigns.current_node_id, socket.assigns.current_node)
    socket
  end
end
