defmodule EvoDashWeb.ReviewLive.FileActions do
  @moduledoc """
  Files-changed tree and per-file diff EVENTS of `EvoDashWeb.ReviewLive` — the
  directory tree toggles, the path filter, file selection/expansion and the
  context-expansion control.

  Every function here is an event handler in the shape the page's dispatcher
  expects — `(socket, params)` in, `{:noreply, socket}` out. Diff FETCHES go
  through `EvoDashWeb.ReviewLive.Diffs`, which spawns them off-process; nothing
  here runs git/RPC work in the LiveView.
  """
  alias EvoDashWeb.ReviewLive.Diffs
  alias EvoDashWeb.ReviewLive.State

  import Phoenix.Component, only: [assign: 2, assign: 3]
  import Phoenix.LiveView, only: [push_event: 3]

  def toggle_dir(socket, %{"dir" => dir}) do
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

  def collapse_all_dirs(socket, _params) do
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

  def expand_all_dirs(socket, _params) do
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

  def filter_files(socket, %{"filter" => value}) do
    # The files-changed toolbar's filter input (debounced on the client).
    # The filter string is shared across repos and cleared on switch_repo.
    {:noreply, assign(socket, :file_filter, value || "")}
  end

  def select_file(socket, %{"path" => path}) do
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

  def toggle_file_expansion(socket, %{"path" => path}) do
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

  def load_file_diff(socket, %{"path" => path}) do
    {:noreply, Diffs.maybe_start(socket, path)}
  end

  def expand_context(socket, %{"path" => path}) do
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
end
