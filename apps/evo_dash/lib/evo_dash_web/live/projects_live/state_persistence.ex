defmodule EvoDashWeb.ProjectsLive.StatePersistence do
  @moduledoc """
  Session persistence helpers for the dashboard LiveView.

  Functions to serialize/deserialize LiveView state to/from browser localStorage
  via `push_event/2` and `assign/2` calls on the socket.
  """

  alias EvoGit.Core.ForeignRepo
  alias EvoDashWeb.DraftScope
  alias EvoDashWeb.LLMSelection
  alias EvoDashWeb.ProjectsLive.ProjectFlow
  alias EvoDashWeb.ProjectsLive.ModelSelectionScope
  import Phoenix.Component, only: [assign: 2, assign: 3]
  import Phoenix.LiveView, only: [push_event: 3]

  # Speed ↔ quality segmented control values (STRING, mirrors :mode).
  @quality_levels ~w(fast balanced high_quality)

  @doc """
  Returns the task form's draft SCOPE TOKEN for the current project: its VCT
  point (`vct:///projects/<name>`), else the raw absolute OS path, else nil.

  This is the ONE computation behind both the `data-task-draft-scope` render
  attribute and the `scope_token` field of the `persist_state` /
  `persist_model_selection` payloads, so the browser can never store a draft
  under a different scope than the DOM advertises.

  The project is resolved from the SAME source as the payloads' `project` field
  (`maybe_persist_state/1`): the URL/reconnect `"project"` param, else the
  active project path. The point lookup is PURE over already-loaded data — the
  active project's own point when it belongs to that path, else
  `ProjectFlow.mount_point_for/2` over `@projects`, which arrives through the
  page's async batch loader. No store/RPC read ever happens here, so the first
  frame may still carry the raw-path token; the JS hook migrates that path-keyed
  draft when the point lands (no server-side re-key needed).
  """
  @spec draft_scope(map()) :: DraftScope.token() | nil
  def draft_scope(assigns) do
    path = draft_path(assigns)

    case draft_point(assigns, path) do
      nil -> DraftScope.project(path)
      # A blank/invalid point degrades to the path token, never to nil.
      point -> DraftScope.project(point) || DraftScope.project(path)
    end
  end

  defp draft_point(_assigns, path) when not is_binary(path), do: nil

  defp draft_point(assigns, path) do
    case assigns[:active_project] do
      %{path: ^path, point: point} when is_binary(point) -> point
      _ -> ProjectFlow.mount_point_for(assigns[:projects] || [], path)
    end
  end

  @doc """
  Pushes current form state to the browser for localStorage persistence.
  """
  def maybe_persist_state(socket) do
    state = %{
      project: draft_path(socket.assigns),
      task_mode: socket.assigns.task_mode,
      selected_agent_id: socket.assigns.selected_agent_id,
      quality_level: socket.assigns[:quality_level],
      task_prompt: socket.assigns.task_prompt,
      task_node_path: socket.assigns.task_node_path,
      task_starting_commit: socket.assigns.task_starting_commit,
      task_resume_from: socket.assigns.task_resume_from,
      show_advanced: socket.assigns.show_advanced,
      show_project_settings: socket.assigns.show_project_settings,
      task_archive: socket.assigns.task_archive,
      persist_agent_state?: socket.assigns[:persist_agent_state?],
      foreign_repos: serialize_foreign_repos(socket.assigns[:foreign_repos]),
      # Per-node storage: the StatePersistence JS hook reads `data-node-id`
      # from #dashboard-root and merges `node` into sessionStorage, and the
      # `restore_state` handler gates on it so state saved on one node never
      # leaks into another node context.
      node: socket.assigns[:current_node_id] || "local"
    }

    push_event(
      socket,
      "persist_state",
      state
      |> Map.merge(model_selection_state(socket.assigns))
      |> put_scope_token(socket.assigns)
    )
  end

  @doc """
  Persists a reconciled canonical picker without replacing unrelated form state.

  The browser must merge this event's `model_spec` and `node` into its existing
  dashboard state, preserving the DOM-owned prompt and any pending restore.
  Do not send this through `persist_state`, whose browser handler replaces the
  whole stored object. An empty canonical map is an explicit Auto selection.
  """
  def maybe_persist_model_selection(socket) do
    if match?({:ok, _}, ModelSelectionScope.bundle(socket.assigns)) and
         is_map(socket.assigns[:selected_model_spec]) and
         is_nil(socket.assigns[:pending_model_selection]) do
      state =
        socket.assigns
        |> model_selection_state()
        |> Map.put(:node, socket.assigns[:current_node_id] || "local")
        |> put_scope_token(socket.assigns)

      state =
        case draft_param(socket.assigns) do
          project when is_binary(project) -> Map.put(state, :project, project)
          _ -> state
        end

      push_event(socket, "persist_model_selection", state)
    else
      socket
    end
  end

  # The scope the draft belongs to, stamped on every persisted payload so the
  # browser can verify the exact scope before adopting an entry.
  #
  # Only a VCT POINT is stamped: a raw-path token is already the payload's
  # `project` identity, the hook stamps path scopes on its own writes, and
  # keeping the path case byte-identical to the legacy payload shape avoids a
  # redundant key. Absent (not nil) with no project at all, where the hook falls
  # back to the un-scoped `dashboard_state` key.
  defp put_scope_token(state, assigns) do
    case draft_scope(assigns) do
      token when is_binary(token) ->
        if DraftScope.point?(token), do: Map.put(state, :scope_token, token), else: state

      nil ->
        state
    end
  end

  # The URL/reconnect `"project"` param (a Review-page resume landing or a
  # workbench reconnect) — the raw-path identity the merge-only
  # `persist_model_selection` event carries when it is set.
  defp draft_param(assigns), do: get_in(assigns, [:workbench_reconnect_params, "project"])

  # The project path the draft belongs to: that param, else the active project
  # path. ONE source for `maybe_persist_state/1`'s `project` field and for
  # `draft_scope/1`, so render and persist can never disagree.
  defp draft_path(assigns), do: draft_param(assigns) || assigns[:active_project_path]

  @doc """
  Serializes only the three canonical model-spec fields, never the picker
  bundle, credentials or resolved runtime options. Legacy page callers retain
  their old id until migrated; canonical state never writes that stale id.
  """
  def model_selection_state(%{pending_model_selection: spec}) when is_map(spec) do
    %{model_spec: Map.take(spec, ~w(provider_profile_id model reasoning_effort))}
  end

  def model_selection_state(%{pending_model_selection: legacy_id}) when is_binary(legacy_id),
    do: %{selected_model_id: legacy_id}

  def model_selection_state(%{selected_model_spec: spec}) when is_map(spec) do
    %{model_spec: Map.take(spec, ~w(provider_profile_id model reasoning_effort))}
  end

  def model_selection_state(assigns), do: %{selected_model_id: assigns[:selected_model_id]}

  @doc """
  Restores canonical `model_spec` or, when absent, an old `selected_model_id`.
  Key presence matters: an empty canonical map or legacy empty string is an
  explicit Auto choice, not a missing value. Canonical state wins over a stale
  legacy id left in browser storage.

  The page must perform its existing node-identity check BEFORE calling this.
  If the async picker load has not landed, the candidate is kept separately
  until that load can validate it (never against a different node's config).
  """
  def maybe_restore_model_selection(socket, state) when is_map(state) do
    candidate =
      cond do
        Map.has_key?(state, "model_spec") -> {:present, state["model_spec"]}
        Map.has_key?(state, "selected_model_id") -> {:present, state["selected_model_id"]}
        true -> :absent
      end

    case candidate do
      {:present, value} when is_map(value) or is_binary(value) ->
        case ModelSelectionScope.bundle(socket.assigns) do
          {:ok, data} ->
            socket
            |> assign(:selected_model_spec, LLMSelection.reconcile(data, value))
            |> assign(:pending_model_selection, nil)
            |> maybe_persist_model_selection()

          {:error, _reason} ->
            assign(socket, :pending_model_selection, value)
        end

      _ ->
        socket
    end
  end

  @doc """
  Clears per-node dashboard state when the node context changes (local↔remote
  or between remote targets). Each node has its own sessionStorage state, so
  switching nodes must reset every persisted/project assign and re-persist the
  cleared state under the new node key. Returns the socket unchanged when the
  node did not change.
  """
  def maybe_clear_state_on_node_switch(socket, prev_node_id, current_node_id)
      when prev_node_id == current_node_id do
    case socket.assigns[:model_selection_scope] do
      nil ->
        socket

      scope ->
        if scope == ModelSelectionScope.current(socket.assigns),
          do: socket,
          else: clear_node_state(socket)
    end
  end

  def maybe_clear_state_on_node_switch(socket, _prev_node_id, _current_node_id) do
    clear_node_state(socket)
  end

  defp clear_node_state(socket) do
    socket
    |> assign(
      projects: [],
      task_prompt: "",
      task_resume_from: "",
      task_starting_commit: "",
      show_advanced: false,
      task_archive: false,
      persist_agent_state?: true,
      selected_agent_id: nil,
      model_selection: nil,
      model_selection_scope: nil,
      model_selection_ready?: false,
      model_selection_error: nil,
      selected_model_spec: nil,
      selected_model_id: nil,
      provider_profiles: [],
      model_selections: [],
      pending_model_selection: nil,
      active_project: nil,
      active_project_path: nil,
      foreign_repos: [],
      show_add_foreign_repo_form: false,
      new_repo_id: "",
      new_repo_path: "",
      new_repo_description: "",
      new_repo_base_sha: "",
      editing_foreign_repo_id: nil,
      foreign_repo_edit_form: nil,
      show_project_settings: false,
      project_palette_open: false,
      palette_mode: :menu,
      palette_search: "",
      palette_selected_index: 0
    )
    |> maybe_persist_state()
  end

  @doc """
  Serializes a list of `ForeignRepo` structs to plain maps for JSON storage.
  """
  def serialize_foreign_repos(nil), do: []

  def serialize_foreign_repos(repos) do
    Enum.map(repos, fn repo ->
      %{
        "id" => repo.id,
        "path" => repo.root,
        "description" => repo.description,
        "writable" => repo.writable,
        "base_sha" => repo.base_sha
      }
    end)
  end

  @doc """
  Restores an assign from a persisted value (skips nil/empty strings).
  """
  def maybe_restore_assign(socket, _key, nil), do: socket
  def maybe_restore_assign(socket, _key, ""), do: socket

  def maybe_restore_assign(socket, key, value) when is_binary(value) do
    assign(socket, key, value)
  end

  @doc """
  Restores the `task_mode` assign from a persisted value, normalizing stale
  mode strings. The reflect ("Self-Reflective") mode was removed from the task
  form, so a `"reflect"` value persisted by an older session would restore
  with the mode `<select>` offering no selected option — it is mapped to
  `"evolve_simple"`. Nil/empty are skipped (same as `maybe_restore_assign/3`);
  all other binary values restore as-is.
  """
  def maybe_restore_task_mode(socket, nil), do: socket
  def maybe_restore_task_mode(socket, ""), do: socket

  def maybe_restore_task_mode(socket, "reflect"), do: assign(socket, :task_mode, "evolve_simple")

  def maybe_restore_task_mode(socket, mode) when is_binary(mode),
    do: assign(socket, :task_mode, mode)

  @doc """
  Restores the `quality_level` assign from a persisted value. Only a
  whitelisted value (`"fast"`/`"balanced"`/`"high_quality"`) is applied — a
  nil/empty/unknown value leaves the socket unchanged so the default
  `"balanced"` (set at mount) stays. Whitelist membership check, never
  `String.to_atom` on persisted input.
  """
  def maybe_restore_quality_level(socket, level) when level in @quality_levels,
    do: assign(socket, :quality_level, level)

  def maybe_restore_quality_level(socket, _), do: socket

  @doc """
  Restores the `show_project_settings` assign from a persisted boolean string.
  """
  def maybe_restore_show_project_settings(socket, "true"),
    do: assign(socket, :show_project_settings, true)

  def maybe_restore_show_project_settings(socket, "false"),
    do: assign(socket, :show_project_settings, false)

  def maybe_restore_show_project_settings(socket, _), do: socket

  @doc """
  Restores the `task_archive` assign from a persisted value.
  """
  def maybe_restore_task_archive(socket, "true"), do: assign(socket, :task_archive, true)
  def maybe_restore_task_archive(socket, true), do: assign(socket, :task_archive, true)
  def maybe_restore_task_archive(socket, _), do: assign(socket, :task_archive, false)

  @doc """
  Restores the `persist_agent_state?` assign from a persisted value.
  The default is ON (unlike `maybe_restore_task_archive/2`, which defaults
  false): only an explicit `true`/`false` (boolean or its string form) is
  applied, so a nil/absent/unknown value returns the socket unchanged and the
  mount-time `true` stays.
  """
  def maybe_restore_persist_agent_state(socket, "true"),
    do: assign(socket, :persist_agent_state?, true)

  def maybe_restore_persist_agent_state(socket, true),
    do: assign(socket, :persist_agent_state?, true)

  def maybe_restore_persist_agent_state(socket, "false"),
    do: assign(socket, :persist_agent_state?, false)

  def maybe_restore_persist_agent_state(socket, false),
    do: assign(socket, :persist_agent_state?, false)

  def maybe_restore_persist_agent_state(socket, _), do: socket

  @doc """
  Restores the `show_advanced` assign from a persisted value.
  """
  def maybe_restore_show_advanced(socket, "true"), do: assign(socket, :show_advanced, true)
  def maybe_restore_show_advanced(socket, true), do: assign(socket, :show_advanced, true)
  def maybe_restore_show_advanced(socket, _), do: socket

  @doc """
  Restores `foreign_repos` assign from persisted map data.
  """
  def maybe_restore_foreign_repos(socket, nil), do: socket
  def maybe_restore_foreign_repos(socket, repos) when is_list(repos) and repos == [], do: socket

  def maybe_restore_foreign_repos(socket, repos) when is_list(repos) do
    restored =
      repos
      |> Enum.filter(fn r -> is_map(r) and is_binary(r["path"]) and r["path"] != "" end)
      |> Enum.map(fn r ->
        id = if is_binary(r["id"]) and r["id"] != "", do: r["id"], else: "primary"

        # Read-write foreign repos: restore `writable` (tolerant
        # `true`/`"true"` — sessionStorage JSON yields booleans, defensive
        # against strings) and `base_sha` (only when a non-empty binary; blank
        # → nil = HEAD) exactly like `description` is handled.
        writable = r["writable"] == true or r["writable"] == "true"

        opts =
          if(is_binary(r["description"]) and r["description"] != "",
            do: [description: r["description"]],
            else: []
          )
          |> Keyword.put(:writable, writable)
          |> then(fn o ->
            if is_binary(r["base_sha"]) and r["base_sha"] != "",
              do: Keyword.put(o, :base_sha, r["base_sha"]),
              else: o
          end)

        # Node-aware construction: in a remote context the persisted root is a
        # REMOTE node path (a remote-added POSIX/Windows repo must survive the
        # persist/restore round-trip unmangled). `ForeignRepo.new/3` would
        # `Path.expand/1` it against the DASHBOARD's OS; remote contexts
        # rebuild raw structs via ProjectFlow.build_foreign_repo/4. Local
        # contexts keep `ForeignRepo.new/3` exactly as before — unified
        # through build_foreign_repo/4 (which delegates to ForeignRepo.new/3
        # for local nodes, so local semantics are byte-identical).
        node =
          if socket.assigns[:remote?] or socket.assigns[:current_node] != node(),
            do: socket.assigns[:current_node],
            else: node()

        ProjectFlow.build_foreign_repo(node, id, r["path"], opts)
      end)

    if restored != [] do
      sorted =
        Enum.sort_by(restored, fn repo ->
          {if(ForeignRepo.primary?(repo.id), do: 0, else: 1), repo.id}
        end)

      assign(socket, :foreign_repos, sorted)
    else
      socket
    end
  end
end
