defmodule EvoDashWeb.ProjectsLive.StatePersistence do
  @moduledoc """
  Session persistence helpers for the dashboard LiveView.

  Functions to serialize/deserialize LiveView state to/from browser localStorage
  via `push_event/2` and `assign/2` calls on the socket.
  """

  alias EvoGit.Core.ForeignRepo
  alias EvoDashWeb.LLMSelection
  alias EvoDashWeb.ProjectsLive.ProjectFlow
  alias EvoDashWeb.ProjectsLive.ModelSelectionScope
  import Phoenix.Component, only: [assign: 2, assign: 3]
  import Phoenix.LiveView, only: [push_event: 3]

  # Speed ↔ quality segmented control values (STRING, mirrors :mode).
  @quality_levels ~w(fast balanced high_quality)
  @doc """
  Pushes current form state to the browser for localStorage persistence.
  """
  def maybe_persist_state(socket) do
    state = %{
      project: socket.assigns.active_project_path,
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
      foreign_repos: serialize_foreign_repos(socket.assigns[:foreign_repos]),
      # Per-node storage: the StatePersistence JS hook reads `data-node-id`
      # from #dashboard-root and merges `node` into sessionStorage, and the
      # `restore_state` handler gates on it so state saved on one node never
      # leaks into another node context.
      node: socket.assigns[:current_node_id] || "local"
    }

    push_event(socket, "persist_state", Map.merge(state, model_selection_state(socket.assigns)))
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

      push_event(socket, "persist_model_selection", state)
    else
      socket
    end
  end

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
      recent_projects: [],
      task_prompt: "",
      task_resume_from: "",
      task_starting_commit: "",
      show_advanced: false,
      task_archive: false,
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
      show_configure_dropdown: false,
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
