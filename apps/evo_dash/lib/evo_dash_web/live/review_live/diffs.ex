defmodule EvoDashWeb.ReviewLive.Diffs do
  @moduledoc """
  The lazy file-diff subsystem of `EvoDashWeb.ReviewLive`.

  A file's diff is fetched on demand (first selection / expansion, or an
  explicit context expansion) OFF the LiveView process, through the shared
  action plumbing (`EvoDashWeb.ReviewLive.Runner` + `{:review_action_result,
  ...}`), so a slow git/RPC call can neither block the page nor exit the
  LiveView. The scope CAPTURED at spawn time (the active repo id on the SHOW
  route, the `:commit` atom on the `:commit` route) travels in the action ref,
  so a result landing after a repo switch is never written into the wrong repo.
  """
  use Gettext, backend: EvoDashWeb.Gettext

  alias EvoDashWeb.ReviewLive.Actions
  alias EvoDashWeb.ReviewLive.Runner
  alias EvoDashWeb.ReviewLive.State

  import Phoenix.Component, only: [assign: 2, assign: 3]
  import Phoenix.LiveView, only: [put_flash: 3]

  # Applies one lazy-diff outcome. The scope is the one CAPTURED at spawn time
  # (the active repo id on the SHOW route, the :commit atom on the :commit
  # route), never the scope that happens to be active now — a result landing
  # after a repo switch is dropped instead of written into the wrong repo.
  def apply_result(socket, action, ref, result) do
    scope = Map.get(ref, :repo_id)
    path = Map.get(ref, :path)
    level = if action == :expand_context, do: Map.get(ref, :level, 3), else: 3

    if diff_result_relevant?(socket, action, scope, path) do
      case result do
        {:ok, {:ok, diff_string}} ->
          update(socket, scope, path, diff_string, level)

        other ->
          put_flash(socket, :error, diff_error_message(action, path, other))
      end
    else
      socket
    end
  end

  # A diff result may be applied only while its scope and file are still on
  # screen: the route still shows that scope, the active repo is still the
  # captured one (:show), and the file still exists in that scope's file list.
  # Selection-driven loads additionally require the file to still be the
  # selection or still expanded; a context expansion applies whenever the file
  # is present (it may have been triggered from an unselected file).
  defp diff_result_relevant?(socket, action, scope, path) do
    scope_in_view?(socket, scope) and file_present?(socket, scope, path) and
      (action == :expand_context or file_selected_or_expanded?(socket, scope, path))
  end

  # The route/scope still on screen: :commit requires the commit route, a repo
  # id requires the SHOW route with that repo still active.
  defp scope_in_view?(socket, :commit), do: socket.assigns.live_action == :commit

  defp scope_in_view?(socket, scope),
    do: socket.assigns.live_action != :commit and socket.assigns.active_repo_id == scope

  def file_present?(socket, scope, path) do
    case scope_files(socket, scope) do
      files when is_list(files) -> Enum.any?(files, &(Map.get(&1, :path) == path))
      _ -> false
    end
  end

  defp file_selected_or_expanded?(socket, scope, path) do
    selected?(socket, scope, path) or expanded?(socket, scope, path)
  end

  defp selected?(socket, :commit, path), do: socket.assigns.selected_file == path

  defp selected?(socket, scope, path),
    do: Map.get(socket.assigns.selected_file || %{}, scope) == path

  defp expanded?(socket, :commit, path),
    do: Map.get(socket.assigns.expanded_files || %{}, path, false) == true

  defp expanded?(socket, scope, path) do
    expanded = socket.assigns.expanded_files || %{}

    expanded
    |> Map.get(scope, %{})
    |> Map.get(path, false) == true
  end

  # The scope's review data: @commit_data on the :commit route, the scoped
  # @review_repos entry's review_data on the SHOW route (nil when the repo is
  # gone or has no diff data).
  defp scope_files(socket, :commit) do
    case socket.assigns.commit_data do
      %{} = data -> Map.get(data, :files)
      _ -> nil
    end
  end

  defp scope_files(socket, scope) do
    case State.find_review_repo(socket.assigns.review_repos, scope) do
      %{} = repo ->
        case Map.get(repo, :review_data) do
          %{} = data -> Map.get(data, :files)
          _ -> nil
        end

      _ ->
        nil
    end
  end

  # The failure flash for a lazy-diff load, keeping the two established
  # strings: context expansion has its own message.
  defp diff_error_message(:expand_context, _path, result) do
    gettext("Failed to expand context: %{reason}", reason: inspect(diff_failure_reason(result)))
  end

  defp diff_error_message(_action, path, result) do
    gettext("Failed to load diff for %{path}: %{reason}",
      path: path,
      reason: inspect(diff_failure_reason(result))
    )
  end

  # The reason behind a failed diff load: the Actions outcome's `{:error,
  # reason}`, a SafeCall exit/exception wrapper, or an unexpected shape.
  defp diff_failure_reason({:ok, {:error, reason}}), do: reason
  defp diff_failure_reason({:error, reason}), do: reason
  defp diff_failure_reason(other), do: other

  # --- Lazy file-diff loads ---
  #
  # A file's diff is fetched on demand (first selection / expansion, or an
  # explicit context expansion) OFF the LiveView process, through the shared
  # action plumbing (`Runner.spawn/4` + `{:review_action_result, ...}`), so a
  # slow git/RPC call can neither block the page nor exit the LiveView.
  # The scope a lazy diff load belongs to: the ACTIVE repo id on the SHOW
  # route, the `:commit` atom on the `:commit` route. Captured at spawn time so
  # a result landing after a repo switch is never written into the wrong repo.
  def diff_scope(socket) do
    if socket.assigns.live_action == :commit, do: :commit, else: socket.assigns.active_repo_id
  end

  # Starts the load for `path` only when the current scope does not have its
  # diff yet (the lazy gate shared by every selection/expansion path). A file
  # missing from the scope's list is never fetched.
  def maybe_start(socket, path) do
    scope = diff_scope(socket)

    case scope_files(socket, scope) do
      files when is_list(files) ->
        case Enum.find(files, &(Map.get(&1, :path) == path)) do
          %{} = file ->
            if is_nil(Map.get(file, :diff)),
              do: start(socket, path, :diff, 3, []),
              else: socket

          _ ->
            socket
        end

      _ ->
        socket
    end
  end

  # Spawns one exit-safe diff load. The `{scope, path}` entry in
  # @diff_in_flight stores the seq of the LATEST request: a second request for
  # the same file is a no-op while one is in flight, and the apply step uses
  # the seq to discard a superseded result.
  def start(socket, path, action, level, opts) do
    scope = diff_scope(socket)
    key = {scope, path}

    if Map.has_key?(socket.assigns.diff_in_flight, key) do
      socket
    else
      {seq, socket} = State.next_action_seq(socket)
      socket = assign(socket, :diff_in_flight, Map.put(socket.assigns.diff_in_flight, key, seq))

      fun = diff_load_fun(socket, scope, path, opts)
      Runner.spawn(socket, action, %{repo_id: scope, path: path, level: level, seq: seq}, fun)
    end
  end

  # The off-process load for one scope, with every argument captured here (the
  # closure runs after the socket may have moved on). SHOW loads the reviewed
  # range (base → tip) of the scoped repo; :commit loads the inspected commit
  # (its plain diff, or — when the caller asked for more context — a diff
  # against its parent).
  defp diff_load_fun(socket, :commit, path, opts) do
    node = socket.assigns.current_node
    repo_path = socket.assigns.repo_path
    commit_sha = socket.assigns.inspect_commit_sha

    if opts == [] do
      fn -> Actions.load_commit_diff(node, repo_path, commit_sha, path) end
    else
      fn -> Actions.load_commit_diff_with_opts(node, repo_path, commit_sha, path, opts) end
    end
  end

  defp diff_load_fun(socket, scope, path, opts) do
    node = socket.assigns.current_node
    repo = State.find_review_repo(socket.assigns.review_repos, scope) || %{}

    repo_path = Map.get(repo, :repo_path) || socket.assigns.repo_path
    base_sha = Map.get(repo, :base_sha) || socket.assigns.base_sha
    commit_sha = Map.get(repo, :commit_sha) || socket.assigns.commit_sha

    fn -> Actions.load_review_diff(node, repo_path, base_sha, commit_sha, path, opts) end
  end

  # The context level currently shown for `path` in `scope` (default 3 lines
  # of context). SHOW reads the ACTIVE repo's submap; :commit keeps today's
  # legacy flat path-keyed state.
  def context_level(socket, :commit, path) do
    Map.get(socket.assigns.file_context_levels || %{}, path, 3)
  end

  def context_level(socket, scope, path) do
    levels = socket.assigns.file_context_levels || %{}

    levels
    |> Map.get(scope, %{})
    |> Map.get(path, 3)
  end

  # Never downgrade a file's context window: :all is unbounded, and an integer
  # level only grows (a plain `:diff` load landing after an expansion keeps the
  # expanded level).
  defp max_context_level(:all, _requested), do: :all
  defp max_context_level(_current, :all), do: :all

  defp max_context_level(current, requested) when is_integer(current) and is_integer(requested),
    do: max(current, requested)

  defp max_context_level(_current, requested), do: requested

  # Writes a loaded diff into the CAPTURED scope's data source (commit_data on
  # the :commit route, the scoped @review_repos entry's review_data on SHOW),
  # and records the context level. Expansion and selection belong to the controls
  # that requested the load and may have changed while Git was running.
  def update(socket, :commit, path, diff_string, context_level) do
    data = socket.assigns.commit_data

    updated_files =
      Enum.map(data.files, fn f ->
        if f.path == path do
          %{f | diff: diff_string}
        else
          f
        end
      end)

    levels = socket.assigns.file_context_levels || %{}
    level = max_context_level(Map.get(levels, path), context_level)

    assign(socket,
      commit_data: %{data | files: updated_files},
      file_context_levels: Map.put(levels, path, level)
    )
  end

  def update(socket, repo_id, path, diff_string, context_level) do
    review_repos =
      Enum.map(socket.assigns.review_repos, fn repo ->
        if repo.repo_id == repo_id do
          case repo.review_data do
            nil ->
              repo

            data ->
              updated_files =
                Enum.map(data.files, fn f ->
                  if f.path == path, do: %{f | diff: diff_string}, else: f
                end)

              %{repo | review_data: %{data | files: updated_files}}
          end
        else
          repo
        end
      end)

    levels = socket.assigns.file_context_levels || %{}
    levels_sub = Map.get(levels, repo_id, %{})
    level = max_context_level(Map.get(levels_sub, path), context_level)
    levels = Map.put(levels, repo_id, Map.put(levels_sub, path, level))

    socket
    |> assign(review_repos: review_repos, file_context_levels: levels)
    |> State.project_active_repo()
    # A lazily loaded diff rewrites the repo's review_data, so the aggregate
    # stats come from here (they never re-walk the repos in the render).
    |> State.put_derived()
  end
end
