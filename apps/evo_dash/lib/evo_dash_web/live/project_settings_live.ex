defmodule EvoDashWeb.ProjectSettingsLive do
  use EvoDashWeb, :live_view

  alias EvoGit.Core.ForeignRepo

  @impl true
  def render(assigns) do
    ~H"""
    <EvoDashWeb.Layouts.app flash={@flash} current_page={:project_settings} config_status={@config_status}>
      <div class="flex items-center gap-3 mb-2">
        <div class="bg-accent/15 text-accent p-3 rounded-xl">
          <.icon name="hero-folder-open" class="size-6" />
        </div>
        <div>
          <h1 class="text-xl font-bold">Project Settings</h1>
          <p class="text-sm text-base-content/60">Per-project configuration &amp; foreign repositories</p>
        </div>
      </div>

      <%= if @project_root do %>
        <!-- Project Config Section -->
        <div class="mt-6 bg-base-100 rounded-2xl shadow-lg border border-base-200 overflow-hidden">
          <div class="bg-gradient-to-br from-accent/10 via-accent/5 to-transparent p-6">
            <h2 class="text-lg font-semibold flex items-center gap-2">
              <.icon name="hero-document-text" class="size-5 text-accent" /> evogit.toml Configuration
            </h2>
          </div>
          <div class="p-6 pt-2">
            <div class="grid grid-cols-1 sm:grid-cols-2 gap-4">
              <div class="bg-base-200/40 rounded-lg p-3 border border-base-200">
                <p class="text-xs text-base-content/50 font-medium uppercase tracking-wide">Project Root</p>
                <p class="text-sm font-mono mt-1">{@project_root}</p>
              </div>
              <div class="bg-base-200/40 rounded-lg p-3 border border-base-200">
                <p class="text-xs text-base-content/50 font-medium uppercase tracking-wide">Config File</p>
                <p class="text-sm mt-1">
                  <%= if @project_config do %>
                    <span class="badge badge-success badge-sm gap-1">
                      <.icon name="hero-check-circle" class="size-3" /> Present
                    </span>
                  <% else %>
                    <span class="badge badge-ghost badge-sm gap-1">
                      <.icon name="hero-x-circle" class="size-3" /> Not found
                    </span>
                  <% end %>
                </p>
              </div>
              <div class="bg-base-200/40 rounded-lg p-3 border border-base-200 sm:col-span-2">
                <p class="text-xs text-base-content/50 font-medium uppercase tracking-wide">Worktree Init Script</p>
                <p class="text-sm font-mono mt-1">
                  <%= if @worktree_script do %>
                    <span>{@worktree_script}</span>
                  <% else %>
                    <span class="text-base-content/30">Not configured</span>
                  <% end %>
                </p>
              </div>
            </div>
          </div>
        </div>

        <!-- Foreign Repos Section -->
        <div class="mt-6 bg-base-100 rounded-2xl shadow-lg border border-base-200 overflow-hidden">
          <div class="bg-gradient-to-br from-secondary/10 via-secondary/5 to-transparent p-6">
            <h2 class="text-lg font-semibold flex items-center gap-2">
              <.icon name="hero-server-stack" class="size-5 text-secondary" /> Foreign Repositories
            </h2>
          </div>
          <div class="p-6 pt-2">
            <%= if @foreign_repos == [] do %>
              <div class="text-center py-8 text-base-content/40">
                <.icon name="hero-folder-minus" class="size-12 mx-auto mb-2 opacity-30" />
                <p class="text-sm">No repositories registered</p>
              </div>
            <% else %>
              <div class="space-y-3">
                <%= for repo <- @foreign_repos do %>
                  <div class="flex items-center gap-3 bg-base-200/40 rounded-lg p-3 border border-base-200">
                    <span class={"badge #{if ForeignRepo.primary?(repo.id), do: "badge-primary", else: "badge-ghost"} badge-sm font-mono"}>
                      {repo.id}
                    </span>
                    <div class="flex-1 min-w-0">
                      <p class="text-sm font-mono truncate">{repo.root}</p>
                      <%= if repo.name && repo.name != Atom.to_string(repo.id) do %>
                        <p class="text-xs text-base-content/50">{repo.name}</p>
                      <% end %>
                    </div>
                    <%= unless ForeignRepo.primary?(repo.id) do %>
                      <button
                        class="btn btn-ghost btn-xs text-error"
                        phx-click="remove_foreign_repo"
                        phx-value-repo_id={repo.id}
                      >
                        <.icon name="hero-trash" class="size-3.5" />
                      </button>
                    <% end %>
                  </div>
                <% end %>
              </div>
            <% end %>
          </div>
        </div>

        <!-- Add Foreign Repo -->
        <div class="mt-6">
          <%= if @show_add_form do %>
            <div class="bg-base-100 rounded-2xl shadow-lg border border-base-200 overflow-hidden">
              <div class="bg-gradient-to-br from-success/10 via-success/5 to-transparent p-6">
                <h2 class="text-lg font-semibold flex items-center gap-2">
                  <.icon name="hero-plus-circle" class="size-5 text-success" /> Add Foreign Repository
                </h2>
              </div>
              <div class="p-6 pt-2">
                <.form for={%{}} phx-submit="add_foreign_repo" class="space-y-4">
                  <div class="grid grid-cols-1 sm:grid-cols-3 gap-4">
                    <div>
                      <label class="label">
                        <span class="label-text text-xs font-medium uppercase tracking-wide">Repo ID</span>
                      </label>
                      <input
                        type="text"
                        name="repo_id"
                        value={@new_repo_id}
                        placeholder="e.g., original"
                        class="input input-bordered input-sm w-full font-mono"
                        required
                      />
                    </div>
                    <div>
                      <label class="label">
                        <span class="label-text text-xs font-medium uppercase tracking-wide">Path</span>
                      </label>
                      <input
                        type="text"
                        name="path"
                        value={@new_repo_path}
                        placeholder="/absolute/path/to/repo"
                        class="input input-bordered input-sm w-full font-mono"
                        required
                      />
                    </div>
                    <div>
                      <label class="label">
                        <span class="label-text text-xs font-medium uppercase tracking-wide">Name (optional)</span>
                      </label>
                      <input
                        type="text"
                        name="name"
                        value={@new_repo_name}
                        placeholder="Human-readable name"
                        class="input input-bordered input-sm w-full"
                      />
                    </div>
                  </div>
                  <div class="flex gap-2">
                    <button type="submit" class="btn btn-primary btn-sm gap-2">
                      <.icon name="hero-plus" class="size-4" /> Add Repository
                    </button>
                    <button
                      type="button"
                      class="btn btn-ghost btn-sm"
                      phx-click="toggle_add_form"
                    >
                      Cancel
                    </button>
                  </div>
                </.form>
              </div>
            </div>
          <% else %>
            <button class="btn btn-outline btn-sm gap-2" phx-click="toggle_add_form">
              <.icon name="hero-plus-circle" class="size-4" /> Add Foreign Repo
            </button>
          <% end %>
        </div>
      <% else %>
        <!-- No Project Loaded -->
        <div class="mt-6 bg-base-100 rounded-2xl shadow-lg border border-base-200 overflow-hidden">
          <div class="p-8 text-center">
            <.icon name="hero-folder-minus" class="size-16 mx-auto mb-4 text-base-content/20" />
            <h2 class="text-lg font-semibold text-base-content/60">No project currently loaded</h2>
            <p class="text-sm text-base-content/40 mt-2">
              Open a project from the dashboard to view its configuration.
            </p>
            <.link navigate={~p"/"} class="btn btn-primary btn-sm mt-4 gap-2">
              <.icon name="hero-arrow-left" class="size-4" /> Go to Dashboard
            </.link>
          </div>
        </div>
      <% end %>
    </EvoDashWeb.Layouts.app>
    """
  end

  @impl true
  def mount(_params, _session, socket) do
    if connected?(socket) do
      :timer.send_interval(3000, self(), :refresh)
    end

    config_status =
      try do
        EvoGit.Config.config_status()
      rescue
        _ -> %{missing: [], warnings: [], ok?: true}
      catch
        _, _ -> %{missing: [], warnings: [], ok?: true}
      end

    {foreign_repos, project_root} = load_repos_and_root()
    {project_config, worktree_script} = load_project_config(project_root)

    socket =
      socket
      |> assign(:config_status, config_status)
      |> assign(:foreign_repos, foreign_repos)
      |> assign(:project_config, project_config)
      |> assign(:project_root, project_root)
      |> assign(:worktree_script, worktree_script)
      |> assign(:show_add_form, false)
      |> assign(:new_repo_id, "")
      |> assign(:new_repo_path, "")
      |> assign(:new_repo_name, "")

    {:ok, socket}
  end

  @impl true
  def handle_info(:refresh, socket) do
    {foreign_repos, project_root} = load_repos_and_root()
    {project_config, worktree_script} = load_project_config(project_root)

    {:noreply,
     socket
     |> assign(:foreign_repos, foreign_repos)
     |> assign(:project_config, project_config)
     |> assign(:project_root, project_root)
     |> assign(:worktree_script, worktree_script)}
  end

  @impl true
  def handle_event("toggle_add_form", _params, socket) do
    {:noreply,
     socket
     |> assign(:show_add_form, !socket.assigns.show_add_form)
     |> assign(:new_repo_id, "")
     |> assign(:new_repo_path, "")
     |> assign(:new_repo_name, "")}
  end

  @impl true
  def handle_event("add_foreign_repo", params, socket) do
    repo_id_str = String.trim(params["repo_id"] || "")
    path = String.trim(params["path"] || "")
    name = String.trim(params["name"] || "")

    cond do
      repo_id_str == "" ->
        {:noreply, put_flash(socket, :error, "Repo ID cannot be empty.")}

      path == "" ->
        {:noreply, put_flash(socket, :error, "Path cannot be empty.")}

      not String.starts_with?(path, "/") ->
        {:noreply, put_flash(socket, :error, "Path must be absolute (start with /).")}

      true ->
        repo_id = String.to_atom(repo_id_str)

        repo =
          if name != "" do
            ForeignRepo.new(repo_id, path, name: name)
          else
            ForeignRepo.new(repo_id, path)
          end

        try do
          case EvoGit.AgentScheduler.register_foreign_repo(repo) do
            :ok ->
              {foreign_repos, project_root} = load_repos_and_root()

              {:noreply,
               socket
               |> assign(:foreign_repos, foreign_repos)
               |> assign(:project_root, project_root)
               |> assign(:show_add_form, false)
               |> assign(:new_repo_id, "")
               |> assign(:new_repo_path, "")
               |> assign(:new_repo_name, "")
               |> put_flash(:info, "Foreign repo '#{repo_id_str}' registered successfully.")}

            {:error, {:already_exists, id}} ->
              {:noreply,
               socket
               |> put_flash(:error, "Repo '#{id}' is already registered.")}
          end
        rescue
          e ->
            {:noreply,
             socket
             |> put_flash(:error, "Failed to register repo: #{Exception.message(e)}")}
        catch
          _, _ ->
            {:noreply, put_flash(socket, :error, "Failed to register repo: scheduler not available.")}
        end
    end
  end

  @impl true
  def handle_event("remove_foreign_repo", %{"repo_id" => repo_id_str}, socket) do
    repo_id = String.to_atom(repo_id_str)

    try do
      case EvoGit.AgentScheduler.unregister_foreign_repo(repo_id) do
        :ok ->
          {foreign_repos, project_root} = load_repos_and_root()

          {:noreply,
           socket
           |> assign(:foreign_repos, foreign_repos)
           |> assign(:project_root, project_root)
           |> put_flash(:info, "Foreign repo '#{repo_id_str}' removed successfully.")}

        {:error, :cannot_unregister_primary} ->
          {:noreply, put_flash(socket, :error, "Cannot remove the primary repository.")}

        {:error, {:not_found, id}} ->
          {:noreply, put_flash(socket, :error, "Repo '#{id}' not found.")}
      end
    rescue
      e ->
        {:noreply,
         socket
         |> put_flash(:error, "Failed to remove repo: #{Exception.message(e)}")}
    catch
      _, _ ->
        {:noreply, put_flash(socket, :error, "Failed to remove repo: scheduler not available.")}
    end
  end

  # Helpers

  defp load_repos_and_root do
    try do
      repos = EvoGit.AgentScheduler.get_foreign_repos()

      # Sort: primary first, then alphabetically by id
      sorted =
        Enum.sort_by(repos, fn repo ->
          {if(ForeignRepo.primary?(repo.id), do: 0, else: 1), repo.id}
        end)

      project_root =
        case Enum.find(repos, &ForeignRepo.primary?(&1.id)) do
          %ForeignRepo{root: root} -> root
          nil -> nil
        end

      {sorted, project_root}
    rescue
      _ -> {[], nil}
    catch
      _, _ -> {[], nil}
    end
  end

  defp load_project_config(nil), do: {nil, nil}

  defp load_project_config(project_root) do
    try do
      config = EvoGit.ProjectConfig.read(project_root)

      worktree_script =
        case config do
          %{"worktree" => %{"script" => script}} when is_binary(script) -> script
          _ -> nil
        end

      {config, worktree_script}
    rescue
      _ -> {nil, nil}
    catch
      _, _ -> {nil, nil}
    end
  end
end
