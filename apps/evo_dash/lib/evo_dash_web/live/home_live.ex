defmodule EvoDashWeb.HomeLive do
  @moduledoc """
  The Pad home (`/`) — v3 design, see `docs/launchpad-frontend-spec.md`.

  No sidebar. A centered composer (620px) at the page's vertical center and a
  fixed right-edge rail of task squares. Review information is NOT here — it
  lives on the dedicated review page (`ReviewsLive` `/reviews`); the top bar
  only carries the awaiting-review count.

  Composer structure (top to bottom): "New / Modify" text tabs (New =
  `:genesis`, Modify = `:evolve` mode `"simple"`), the large prompt textarea
  (L1, `AdaptiveInput` autogrow, Enter submits / Shift+Enter newline /
  `isComposing` guard — all in the `PadFly` hook), the address row (FULL path
  input with `PathAutocomplete` + recent-project chips + the address options:
  "New directory" / "Existing directory" for New, "In place" for Modify), the
  Advanced block (EXPANDED by default, collapsible via the `@advanced_open`
  assign), and the Start button (the page's only solid element).

  Submit: opts assembly mirrors the archived Launchpad composer's whitelist
  pattern — the mode maps to `{task_type, backend_mode}` through
  `@submit_modes` (never `String.to_atom/1`), the build-system id is resolved
  against the loaded `build_systems` list (backend-owned atoms). "New
  directory" runs `File.mkdir_p/1` when the path doesn't exist yet and
  submits mode `"new"`; "Existing directory" submits mode `"existing"`;
  Modify requires an existing directory and submits `:evolve` `"simple"`. On
  success ONLY the prompt is cleared (`pad:clear_prompt` push event; path,
  mode and advanced params are kept for continuous input) and the project is
  recorded in the recent list. On failure the error shows inline.

  Rail: `list_tasks_summary/2` — active statuses + tasks finished within the
  last 24h, newest first, capped at 20. Squares arriving after the first
  render get the pop entrance (`@rail_new_ids`). Reloads on `"tasks"` PubSub
  broadcasts coalesce through the NodeAware 300ms trailing debounce.

  Deep links: `?project=<path>` fills the path input;
  `?resume_from=<task_id>&starting_commit=<sha>` switches to the Modify tab
  with the resume fields pre-filled (resume only applies to evolve tasks).
  """

  use EvoDashWeb, :live_view

  alias EvoDashWeb.DashboardLive.Project
  alias EvoDashWeb.LiveHooks.NodeAware
  alias EvoDashWeb.PadComponents
  alias EvoGit.TaskRegistry

  # {mode_tab, address_option} → {task_type, backend_mode} — whitelist, no
  # atom conversion on client input.
  @submit_modes %{
    {"new", "create"} => {:genesis, "new"},
    {"new", "existing"} => {:genesis, "existing"},
    {"modify", "in_place"} => {:evolve, "simple"}
  }

  @evolve_param_keys [:node_path, :starting_commit, :resume_from]

  @rail_statuses [:running, :pending, :finalizing, :completed, :failed, :cancelled]
  @rail_limit 20
  @rail_finished_window_seconds 86_400

  @impl true
  def mount(_params, _session, socket) do
    if connected?(socket) do
      Phoenix.PubSub.subscribe(EvoGit.PubSub, "tasks")
      Phoenix.PubSub.subscribe(EvoGit.PubSub, "recent_projects")
    end

    {model_profiles, selected_model_id} = Project.load_model_profiles()

    socket =
      socket
      |> assign(
        mode_tab: "new",
        address_option: "create",
        project_path: "",
        path_suggestions: [],
        advanced_open: true,
        model_profiles: model_profiles,
        selected_model_id: selected_model_id,
        build_systems: EvoGit.Runtime.WorktreeInitScript.build_systems(),
        selected_build_system: nil,
        node_path: "",
        starting_commit: "",
        resume_from: "",
        archive: false,
        recent_projects: TaskRegistry.list_recent_projects(),
        submit_error: nil,
        rail_new_ids: []
      )
      |> load_rail(initial: true)

    {:ok, socket}
  end

  @impl true
  def handle_params(params, _uri, socket) do
    socket = assign(socket, :current_path, ~p"/")

    socket =
      case params do
        %{"project" => path} when is_binary(path) and path != "" ->
          assign(socket, :project_path, path)

        _ ->
          socket
      end

    socket =
      case params do
        %{"resume_from" => resume_from} when is_binary(resume_from) and resume_from != "" ->
          # Resume only applies to evolve — force the Modify tab so the resume
          # fields are visible and used.
          assign(socket,
            mode_tab: "modify",
            resume_from: resume_from,
            starting_commit: params["starting_commit"] || ""
          )

        _ ->
          socket
      end

    {:noreply, socket}
  end

  # ---------------------------------------------------------------------------
  # Events
  # ---------------------------------------------------------------------------

  @impl true
  def handle_event("pad_tab", %{"tab" => tab}, socket) when tab in ["new", "modify"] do
    {:noreply, assign(socket, :mode_tab, tab)}
  end

  def handle_event("pad_tab", _params, socket), do: {:noreply, socket}

  def handle_event("pad_address_option", %{"option" => option}, socket)
      when option in ["create", "existing"] do
    {:noreply, assign(socket, :address_option, option)}
  end

  def handle_event("pad_address_option", _params, socket), do: {:noreply, socket}

  def handle_event("pad_path_change", %{"path" => path}, socket) when is_binary(path) do
    {:noreply,
     assign(socket,
       project_path: path,
       path_suggestions: Project.path_suggestions(path, socket.assigns.recent_projects)
     )}
  end

  def handle_event("pad_path_change", _params, socket), do: {:noreply, socket}

  def handle_event("pad_fill_path", %{"path" => path}, socket) when is_binary(path) do
    {:noreply,
     assign(socket, project_path: Path.expand(path), path_suggestions: [], submit_error: nil)}
  end

  def handle_event("pad_fill_path", _params, socket), do: {:noreply, socket}

  def handle_event("pad_model_change", %{"model_id" => model_id}, socket)
      when is_binary(model_id) do
    {:noreply, assign(socket, :selected_model_id, model_id)}
  end

  def handle_event("pad_model_change", _params, socket), do: {:noreply, socket}

  def handle_event("pad_tune_change", params, socket) do
    socket = merge_tune_params(socket, params)

    # The archive checkbox only reports when it is the change target — its
    # absence from the params otherwise means "some other field changed", not
    # "unchecked".
    socket =
      case params do
        %{"_target" => ["archive"]} -> assign(socket, :archive, params["archive"] == "true")
        _ -> socket
      end

    {:noreply, socket}
  end

  def handle_event("pad_toggle_advanced", _params, socket) do
    {:noreply, assign(socket, :advanced_open, !socket.assigns.advanced_open)}
  end

  def handle_event("pad_submit", params, socket) do
    {:noreply, submit(socket, params)}
  end

  # ---------------------------------------------------------------------------
  # PubSub
  # ---------------------------------------------------------------------------

  @impl true
  def handle_info({:tasks_updated}, socket) do
    {:noreply, NodeAware.debounce_task_reload(socket)}
  end

  def handle_info({:task_status, _task_id, _status}, socket) do
    {:noreply, NodeAware.debounce_task_reload(socket)}
  end

  def handle_info(:node_aware_reload_tasks, socket) do
    {:noreply, socket |> load_rail() |> NodeAware.reload_tasks()}
  end

  def handle_info({:recent_projects_updated}, socket) do
    {:noreply, assign(socket, :recent_projects, TaskRegistry.list_recent_projects())}
  end

  def handle_info({:remote_connection_status, _, _} = message, socket) do
    NodeAware.handle_connection_status(socket, message)
  end

  def handle_info({:node_selected, node_id}, socket) do
    NodeAware.handle_node_selected(socket, node_id)
  end

  # ---------------------------------------------------------------------------
  # Submit
  # ---------------------------------------------------------------------------

  defp submit(socket, params) do
    socket =
      socket
      |> merge_tune_params(params)
      |> merge_submit_params(params)

    prompt = String.trim(params["prompt"] || "")
    raw_path = String.trim(params["path"] || socket.assigns.project_path || "")

    cond do
      prompt == "" ->
        assign(socket, :submit_error, gettext("Nothing to start — the prompt is empty."))

      raw_path == "" ->
        assign(socket, :submit_error, gettext("Set a project path first."))

      true ->
        path = Path.expand(raw_path)
        socket = assign(socket, :project_path, path)
        start_task(socket, prompt, path)
    end
  end

  defp start_task(socket, prompt, path) do
    {task_type, mode} =
      Map.get(@submit_modes, {socket.assigns.mode_tab, address_mode(socket)}, {:evolve, "simple"})

    case ensure_path(socket, task_type, mode, path) do
      :ok ->
        opts = build_opts(socket, task_type, mode, path, prompt)

        case TaskRegistry.start_task(task_type, opts) do
          {:ok, _task} ->
            TaskRegistry.add_recent_project(path, Path.basename(path))

            socket
            |> assign(submit_error: nil, recent_projects: TaskRegistry.list_recent_projects())
            |> push_event("pad:clear_prompt", %{})
            |> load_rail()

          {:error, reason} ->
            socket
            |> assign(
              :submit_error,
              gettext("Failed to start task: %{reason}", reason: inspect(reason))
            )
            |> load_rail()
        end

      {:error, message} ->
        assign(socket, :submit_error, message)
    end
  end

  # "create" only exists on the New tab; Modify is always in-place.
  defp address_mode(socket) do
    if socket.assigns.mode_tab == "new", do: socket.assigns.address_option, else: "in_place"
  end

  # Path preparation per mode: "New directory" creates the directory when
  # missing (File.mkdir_p/1); "Existing directory" and "In place" require an
  # existing directory.
  defp ensure_path(_socket, :genesis, "new", path) do
    if File.dir?(path) do
      :ok
    else
      case File.mkdir_p(path) do
        :ok ->
          :ok

        {:error, reason} ->
          {:error,
           gettext("Could not create directory %{path} (%{reason})",
             path: path,
             reason: inspect(reason)
           )}
      end
    end
  end

  defp ensure_path(socket, _task_type, _mode, path) do
    if File.dir?(path) do
      :ok
    else
      message =
        if socket.assigns.mode_tab == "modify" do
          gettext("In-place modify needs an existing directory: %{path}", path: path)
        else
          gettext("Not a directory: %{path}", path: path)
        end

      {:error, message}
    end
  end

  # Builds opts for one task. Mirrors the (archived) Launchpad.Composer's
  # whitelist assembly: path/mode, prompt|objective, build_system (genesis,
  # resolved against the loaded list — backend-owned atoms), the evolve tune
  # fields, archive, model_id.
  defp build_opts(socket, task_type, mode, path, prompt) do
    opts = [path: path, mode: mode]

    opts =
      if task_type == :genesis do
        Keyword.put(opts, :prompt, prompt)
      else
        Keyword.put(opts, :objective, prompt)
      end

    opts = maybe_put_build_system(opts, task_type, socket)
    opts = maybe_put_evolve_params(opts, task_type, socket)
    opts = if socket.assigns.archive, do: Keyword.put(opts, :archive, true), else: opts

    case socket.assigns.selected_model_id do
      model_id when is_binary(model_id) and model_id != "" ->
        Keyword.put(opts, :model_id, model_id)

      _ ->
        opts
    end
  end

  defp maybe_put_build_system(opts, :genesis, socket) do
    case socket.assigns.selected_build_system do
      selected when is_binary(selected) and selected != "" ->
        case Enum.find(socket.assigns.build_systems, &(to_string(&1.id) == selected)) do
          nil -> opts
          %{id: id} -> Keyword.put(opts, :build_system, id)
        end

      _ ->
        opts
    end
  end

  defp maybe_put_build_system(opts, _task_type, _socket), do: opts

  defp maybe_put_evolve_params(opts, :evolve, socket) do
    Enum.reduce(@evolve_param_keys, opts, fn key, opts ->
      case Map.get(socket.assigns, key) do
        value when is_binary(value) ->
          trimmed = String.trim(value)
          if trimmed == "", do: opts, else: Keyword.put(opts, key, trimmed)

        _ ->
          opts
      end
    end)
  end

  defp maybe_put_evolve_params(opts, _task_type, _socket), do: opts

  # ---------------------------------------------------------------------------
  # Form param merging
  # ---------------------------------------------------------------------------

  # Merges present advanced-block keys (build_system + evolve fields) into the
  # assigns. Keys absent from the params are left untouched.
  defp merge_tune_params(socket, params) do
    socket =
      Enum.reduce(@evolve_param_keys, socket, fn key, socket ->
        string_key = Atom.to_string(key)

        case params do
          %{^string_key => value} when is_binary(value) -> assign(socket, key, value)
          _ -> socket
        end
      end)

    case params do
      %{"build_system" => ""} ->
        assign(socket, :selected_build_system, nil)

      %{"build_system" => value} when is_binary(value) ->
        assign(socket, :selected_build_system, value)

      _ ->
        socket
    end
  end

  # On submit every input is present in the params, so path / model / archive
  # are authoritative (the archive checkbox is always rendered — absent means
  # unchecked).
  defp merge_submit_params(socket, params) do
    socket =
      case params do
        %{"path" => path} when is_binary(path) -> assign(socket, :project_path, path)
        _ -> socket
      end

    socket =
      case params do
        %{"model_id" => model_id} when is_binary(model_id) ->
          assign(socket, :selected_model_id, model_id)

        _ ->
          socket
      end

    assign(socket, :archive, params["archive"] == "true")
  end

  # ---------------------------------------------------------------------------
  # Rail + review count
  # ---------------------------------------------------------------------------

  # Loads the rail (active statuses + tasks finished within the last 24h,
  # newest first, capped at @rail_limit) and the awaiting-review count. On the
  # initial load nothing pops; afterwards ids that weren't in the rail before
  # get the pop entrance.
  defp load_rail(socket, opts \\ []) do
    tasks = TaskRegistry.list_tasks_summary(@rail_statuses)
    cutoff = DateTime.add(DateTime.utc_now(), -@rail_finished_window_seconds, :second)

    rail =
      tasks
      |> Enum.filter(&rail_task?(&1, cutoff))
      |> Enum.sort_by(
        &(Map.get(&1, :finished_at) || Map.get(&1, :started_at)),
        {:desc, DateTime}
      )
      |> Enum.take(@rail_limit)

    review_count = Enum.count(tasks, &PadComponents.awaiting_review?/1)

    new_ids =
      if Keyword.get(opts, :initial, false) do
        []
      else
        previous_ids = MapSet.new(socket.assigns.rail_tasks, &Map.get(&1, :id))

        rail
        |> Enum.reject(&MapSet.member?(previous_ids, Map.get(&1, :id)))
        |> Enum.map(&Map.get(&1, :id))
      end

    assign(socket, rail_tasks: rail, rail_new_ids: new_ids, review_count: review_count)
  end

  defp rail_task?(task, cutoff) do
    case Map.get(task, :status) do
      status when status in [:running, :pending, :finalizing] ->
        true

      status when status in [:completed, :failed, :cancelled] ->
        case Map.get(task, :finished_at) do
          %DateTime{} = finished_at -> DateTime.compare(finished_at, cutoff) != :lt
          # A finished status without finished_at shouldn't happen — keep it
          # rather than silently dropping the task.
          _ -> true
        end

      _ ->
        false
    end
  end

  # ---------------------------------------------------------------------------
  # Render helpers
  # ---------------------------------------------------------------------------

  defp prompt_placeholder("modify"), do: gettext("Describe what you want to change...")
  defp prompt_placeholder(_), do: gettext("Describe the software you want to create...")

  defp model_label(profile) do
    case Map.get(profile, :concurrency) do
      nil -> profile.id
      concurrency -> "#{profile.id} ×#{concurrency}"
    end
  end

  defp radio_classes(active) do
    [
      "inline-flex items-center gap-1.5 text-[11.5px] transition-colors cursor-pointer border-none bg-none p-0",
      if(active, do: "text-base-content", else: "text-base-content/40 hover:text-base-content/70")
    ]
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div id="pad-root" class="bg-base-100 text-base-content">
      <PadComponents.pad_top_bar current={:home} review_count={@review_count} />

      <main class="pad-stage">
        <div class="pad-composer">
          <.form for={%{}} id="pad-form" phx-submit="pad_submit" phx-hook="PadFly">
            <%!-- Mode tabs: New = genesis, Modify = evolve simple --%>
            <div class="flex gap-6 mb-3">
              <button
                type="button"
                phx-click="pad_tab"
                phx-value-tab="new"
                aria-pressed={@mode_tab == "new"}
                class={["pad-tab", @mode_tab == "new" && "pad-tab-on"]}
              >
                {gettext("New")}
              </button>
              <button
                type="button"
                phx-click="pad_tab"
                phx-value-tab="modify"
                aria-pressed={@mode_tab == "modify"}
                class={["pad-tab", @mode_tab == "modify" && "pad-tab-on"]}
              >
                {gettext("Modify")}
              </button>
            </div>

            <%!-- Prompt textarea (L1) — draft is client-owned (phx-update="ignore");
                 PadFly: Enter submits, Shift+Enter newline, isComposing guard --%>
            <textarea
              name="prompt"
              id="pad-prompt"
              phx-update="ignore"
              phx-hook="AdaptiveInput"
              spellcheck="false"
              class="pad-prompt"
              placeholder={prompt_placeholder(@mode_tab)}
            ></textarea>

            <%!-- Address row: FULL path input + address options --%>
            <div class="mt-3.5">
              <div class="flex items-baseline gap-2.5">
                <span class="text-[11px] text-base-content/25 shrink-0">{gettext("Path")}</span>
                <input
                  type="text"
                  name="path"
                  id="pad-path"
                  value={@project_path}
                  list="pad-path-suggestions"
                  phx-hook="PathAutocomplete"
                  phx-change="pad_path_change"
                  phx-debounce="200"
                  autocomplete="off"
                  spellcheck="false"
                  placeholder={gettext("/absolute/path/to/project")}
                  class="pad-path-input flex-1 min-w-0 font-mono text-xs text-base-content/40"
                />
                <datalist id="pad-path-suggestions">
                  <option :for={path <- @path_suggestions} value={path} />
                </datalist>
              </div>

              <div class="flex flex-wrap items-center gap-x-3.5 gap-y-1 mt-2">
                <%!-- Recent projects — one-tap fill (max 4) --%>
                <button
                  :for={project <- Enum.take(@recent_projects, 4)}
                  type="button"
                  phx-click="pad_fill_path"
                  phx-value-path={project.path}
                  title={project.path}
                  class="font-mono text-[11px] text-base-content/25 hover:text-base-content/50 transition-colors border-none bg-none p-0 cursor-pointer"
                >
                  {project.name}
                </button>

                <%= if @mode_tab == "new" do %>
                  <button
                    type="button"
                    phx-click="pad_address_option"
                    phx-value-option="create"
                    aria-pressed={@address_option == "create"}
                    class={radio_classes(@address_option == "create")}
                  >
                    <span>{if @address_option == "create", do: "●", else: "○"}</span>
                    <span>{gettext("New directory")}</span>
                  </button>
                  <button
                    type="button"
                    phx-click="pad_address_option"
                    phx-value-option="existing"
                    aria-pressed={@address_option == "existing"}
                    class={radio_classes(@address_option == "existing")}
                  >
                    <span>{if @address_option == "existing", do: "●", else: "○"}</span>
                    <span>{gettext("Existing directory")}</span>
                  </button>
                <% else %>
                  <span class="inline-flex items-center gap-1.5 text-[11.5px] text-base-content">
                    <span>●</span>
                    <span>{gettext("In place")}</span>
                  </span>
                <% end %>
              </div>
            </div>

            <%!-- Advanced — EXPANDED by default, collapsible (server assign) --%>
            <div class={["pad-adv mt-6 border-t border-base-300 pt-2.5", !@advanced_open && "closed"]}>
              <div
                class="flex items-baseline gap-2 cursor-pointer select-none"
                phx-click="pad_toggle_advanced"
              >
                <span class="pad-arrow text-[10px] text-base-content/25">▾</span>
                <span class="text-xs text-base-content/40">{gettext("Advanced")}</span>
              </div>

              <div class="pad-adv-grid font-mono">
                <div
                  :if={@model_profiles != []}
                  class="flex items-baseline gap-1.5 whitespace-nowrap min-w-0"
                >
                  <span class="text-[11px] text-base-content/25">model</span>
                  <select
                    name="model_id"
                    phx-change="pad_model_change"
                    class="pad-select text-xs text-base-content/40"
                  >
                    <option
                      :for={profile <- @model_profiles}
                      value={profile.id}
                      selected={@selected_model_id == profile.id}
                    >
                      {model_label(profile)}
                    </option>
                  </select>
                </div>

                <%= if @mode_tab == "new" do %>
                  <div class="flex items-baseline gap-1.5 whitespace-nowrap min-w-0">
                    <span class="text-[11px] text-base-content/25">build</span>
                    <select
                      name="build_system"
                      phx-change="pad_tune_change"
                      class="pad-select text-xs text-base-content/40"
                    >
                      <option value="" selected={is_nil(@selected_build_system)}>
                        {gettext("Auto")}
                      </option>
                      <option
                        :for={bs <- @build_systems}
                        value={to_string(bs.id)}
                        selected={@selected_build_system == to_string(bs.id)}
                      >
                        {bs.name}
                      </option>
                    </select>
                  </div>
                <% else %>
                  <div class="flex items-baseline gap-1.5 whitespace-nowrap min-w-0">
                    <span class="text-[11px] text-base-content/25">node</span>
                    <input
                      type="text"
                      name="node_path"
                      value={@node_path}
                      phx-change="pad_tune_change"
                      phx-debounce="300"
                      placeholder="./"
                      spellcheck="false"
                      class="pad-path-input flex-1 min-w-0 font-mono text-xs text-base-content/40"
                    />
                  </div>
                  <div class="flex items-baseline gap-1.5 whitespace-nowrap min-w-0">
                    <span class="text-[11px] text-base-content/25">commit</span>
                    <input
                      type="text"
                      name="starting_commit"
                      value={@starting_commit}
                      phx-change="pad_tune_change"
                      phx-debounce="300"
                      placeholder="—"
                      spellcheck="false"
                      class="pad-path-input flex-1 min-w-0 font-mono text-xs text-base-content/40"
                    />
                  </div>
                  <div class="flex items-baseline gap-1.5 whitespace-nowrap min-w-0">
                    <span class="text-[11px] text-base-content/25">resume</span>
                    <input
                      type="text"
                      name="resume_from"
                      value={@resume_from}
                      phx-change="pad_tune_change"
                      phx-debounce="300"
                      placeholder="—"
                      spellcheck="false"
                      class="pad-path-input flex-1 min-w-0 font-mono text-xs text-base-content/40"
                    />
                  </div>
                <% end %>

                <label class="flex items-baseline gap-1.5 whitespace-nowrap min-w-0 cursor-pointer">
                  <span class="text-[11px] text-base-content/25">archive</span>
                  <input
                    type="checkbox"
                    name="archive"
                    value="true"
                    phx-change="pad_tune_change"
                    checked={@archive}
                    class="checkbox checkbox-xs"
                  />
                </label>
              </div>
            </div>

            <p :if={@submit_error} role="alert" class="mt-3 text-xs text-error">
              {@submit_error}
            </p>

            <div class="flex justify-end mt-5">
              <button type="submit" class="pad-start">{gettext("Start ↵")}</button>
            </div>
          </.form>
        </div>
      </main>

      <%!-- Rail: task squares, newest first --%>
      <aside id="pad-rail" class="pad-rail" aria-label={gettext("Tasks")}>
        <PadComponents.rail_square
          :for={task <- @rail_tasks}
          task={task}
          enter={Map.get(task, :id) in @rail_new_ids}
        />
      </aside>

      <Layouts.flash_group flash={@flash} />
    </div>
    """
  end
end
