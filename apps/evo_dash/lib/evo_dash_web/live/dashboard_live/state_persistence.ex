defmodule EvoDashWeb.DashboardLive.StatePersistence do
  @moduledoc """
  Session persistence helpers for the dashboard LiveView.

  Functions to serialize/deserialize LiveView state to/from browser localStorage
  via `push_event/2` and `assign/2` calls on the socket.
  """

  alias EvoGit.Core.ForeignRepo
  import Phoenix.Component, only: [assign: 3]
  import Phoenix.LiveView, only: [push_event: 3]

  @doc """
  Pushes current form state to the browser for localStorage persistence.
  """
  def maybe_persist_state(socket) do
    state = %{
      project: socket.assigns.active_project_path,
      task_mode: socket.assigns.task_mode,
      selected_model_id: socket.assigns.selected_model_id,
      task_prompt: socket.assigns.task_prompt,
      task_node_path: socket.assigns.task_node_path,
      task_seeds: socket.assigns.task_seeds,
      task_starting_commit: socket.assigns.task_starting_commit,
      task_resume_from: socket.assigns.task_resume_from,
      show_advanced: socket.assigns.show_advanced,
      task_archive: socket.assigns.task_archive,
      foreign_repos: serialize_foreign_repos(socket.assigns[:foreign_repos])
    }

    push_event(socket, "persist_state", state)
  end

  @doc """
  Serializes a list of `ForeignRepo` structs to plain maps for JSON storage.
  """
  def serialize_foreign_repos(nil), do: []

  def serialize_foreign_repos(repos) do
    Enum.map(repos, fn repo ->
      %{"id" => repo.id, "path" => repo.root, "description" => repo.description}
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

        opts =
          if is_binary(r["description"]) and r["description"] != "",
            do: [description: r["description"]],
            else: []

        ForeignRepo.new(id, r["path"], opts)
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
