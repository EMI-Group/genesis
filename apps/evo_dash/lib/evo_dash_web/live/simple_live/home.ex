defmodule EvoDashWeb.SimpleLive.Home do
  @moduledoc """
  Minimal home page (default `/`) — step 2 of the simple-mode flow:

      /welcome (API setup) → / (this page: task input) → /tree (agent tree)

  Google/Quark-style minimalism with two mode tabs centered above the input
  box (per product review):

  - **开发新软件** (default) — one "开发路径" field; a bare name auto-creates
    the project folder, an existing path opens it.
  - **重构已有软件** — two fields: "原软件路径" (must already exist) and
    "新软件路径" (optional). Empty new path → in-place evolution of the
    original; a given new path → genesis in the new directory with the
    original registered as a read-only foreign repo (port-style refactor).

  Launching navigates to the fullscreen agent tree (`/tree`). A small corner
  link (`Layouts.pro_corner`) enters the pro dashboard (`/dashboard`).
  """

  use EvoDashWeb, :live_view

  alias EvoGit.Core.ForeignRepo
  alias EvoGit.TaskRegistry
  alias EvoDashWeb.DashboardLive.Project

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.simple flash={@flash}>
      <%!-- Brand: top-left corner --%>
      <div class="absolute top-5 left-6 flex items-center gap-3 select-none">
        <img
          src={~p"/images/evox-logo.svg"}
          class="brand-logo-light h-7 w-auto"
          alt={gettext("Genesis")}
        />
        <img
          src={~p"/images/evox-logo-white.svg"}
          class="brand-logo-dark h-7 w-auto hidden"
          alt={gettext("Genesis")}
        />
        <div class="leading-tight border-l border-slate-200 pl-3">
          <p class="text-sm font-bold text-slate-900">天演·启元</p>
          <p class="text-[11px] text-slate-400">EvoX Genesis</p>
        </div>
      </div>

      <div class="flex-1 flex flex-col items-center justify-center px-4 pb-24">
        <div class="w-full max-w-2xl flex flex-col items-center">
          <%!-- No-model banner: warn before the user invests in writing a prompt --%>
          <%= if @no_model? do %>
            <div class="w-full mb-4 rounded-2xl border border-amber-200 bg-amber-50 px-4 py-3 flex items-center gap-3">
              <.icon name="hero-exclamation-triangle" class="size-5 text-amber-600 shrink-0" />
              <p class="text-sm text-amber-800">
                {gettext("No LLM configured yet.")}
                <.link navigate={~p"/welcome"} class="underline font-medium">
                  {gettext("Set up your model first")}
                </.link>
              </p>
            </div>
          <% end %>

          <%!-- Mode tabs (centered above the input box) --%>
          <div
            id="mode-tabs"
            class="flex items-center rounded-full border border-slate-200 bg-slate-50 p-1 mb-4"
            role="tablist"
          >
            <button
              :for={
                {mode, label} <- [
                  {"new", gettext("Develop new software")},
                  {"refactor", gettext("Refactor existing software")}
                ]
              }
              type="button"
              id={"mode-tab-#{mode}"}
              phx-click="switch_mode"
              phx-value-mode={mode}
              role="tab"
              aria-selected={to_string(@mode == mode)}
              class={[
                "rounded-full px-5 py-1.5 text-sm transition-colors",
                @mode == mode && "bg-slate-900 text-white font-medium shadow-sm",
                @mode != mode && "text-slate-500 hover:text-slate-800"
              ]}
            >
              {label}
            </button>
          </div>

          <%!-- Box 1: the requirement input stands alone --%>
          <.form
            for={@form}
            id="simple-task-form"
            phx-submit="launch"
            phx-change="update_prompt"
            class="w-full"
          >
            <div class="simple-search-box w-full px-5 py-3">
              <textarea
                id="simple-prompt"
                name="prompt"
                rows="3"
                phx-hook="AutoGrowTextarea"
                placeholder={gettext("Enter your development requirements, e.g. build a web calendar with month view")}
              >{@prompt}</textarea>
            </div>

            <%!-- Row 2: path field(s) + standalone start button on the right --%>
            <div class="w-full flex items-start justify-between gap-3 mt-3">
              <div class="flex-1 min-w-0 flex flex-col gap-2">
                <div class="relative">
                  <input
                    type="text"
                    id="simple-path-input"
                    name="path"
                    value={@path_input}
                    phx-change="suggest_path"
                    phx-debounce="150"
                    autocomplete="off"
                    placeholder={
                      if @mode == "new",
                        do: gettext("Development path, e.g. web-calendar (auto-created)"),
                        else:
                          gettext("Original software path, e.g. C:\\projects\\old-app (must exist)")
                    }
                    class="w-full rounded-xl border border-slate-200 bg-white px-3.5 py-2 text-sm text-slate-900 placeholder:text-slate-400 focus:outline-none focus:border-slate-400"
                  />
                  <p class="text-[11px] text-slate-400 mt-1 px-0.5">
                    {if @mode == "new",
                      do:
                        gettext(
                          "Enter an existing directory to open it, or a new name — the folder is created under ~/GenesisProjects automatically."
                        ),
                      else:
                        gettext(
                          "The original directory must already exist. It will only be modified if you leave the new path empty."
                        )}
                  </p>
                  <%= if @path_suggestions != [] do %>
                    <div class="absolute left-0 right-0 top-full mt-1 z-10 rounded-xl border border-slate-200 bg-white shadow-lg max-h-48 overflow-y-auto">
                      <button
                        :for={suggestion <- @path_suggestions}
                        type="button"
                        phx-click="fill_path"
                        phx-value-path={suggestion}
                        class="block w-full px-3 py-2 text-left text-sm text-slate-600 hover:bg-slate-50 truncate"
                      >
                        {suggestion}
                      </button>
                    </div>
                  <% end %>
                </div>

                <%= if @mode == "refactor" do %>
                  <div class="relative">
                    <input
                      type="text"
                      id="simple-new-path-input"
                      name="new_path"
                      value={@new_path_input}
                      phx-change="suggest_new_path"
                      phx-debounce="150"
                      autocomplete="off"
                      placeholder={
                        gettext(
                          "New software path, e.g. old-app-v2 (optional; empty = refactor in place)"
                        )
                      }
                      class="w-full rounded-xl border border-slate-200 bg-white px-3.5 py-2 text-sm text-slate-900 placeholder:text-slate-400 focus:outline-none focus:border-slate-400"
                    />
                    <p class="text-[11px] text-slate-400 mt-1 px-0.5">
                      {gettext(
                        "Leave empty: refactor in place (modifies the original directory). Fill in: generate into a new directory (original stays read-only)."
                      )}
                    </p>
                    <%= if @new_path_suggestions != [] do %>
                      <div class="absolute left-0 right-0 top-full mt-1 z-10 rounded-xl border border-slate-200 bg-white shadow-lg max-h-48 overflow-y-auto">
                        <button
                          :for={suggestion <- @new_path_suggestions}
                          type="button"
                          phx-click="fill_new_path"
                          phx-value-path={suggestion}
                          class="block w-full px-3 py-2 text-left text-sm text-slate-600 hover:bg-slate-50 truncate"
                        >
                          {suggestion}
                        </button>
                      </div>
                    <% end %>
                  </div>
                <% end %>

                <%!-- Recent projects: one-click fill + standalone review entry --%>
                <%= if @recent_projects != [] do %>
                  <div class="flex items-center gap-1.5 flex-wrap px-0.5">
                    <span class="text-[11px] text-slate-400">{gettext("Recent:")}</span>
                    <button
                      :for={project <- Enum.take(@recent_projects, 4)}
                      type="button"
                      phx-click="fill_path"
                      phx-value-path={project.path}
                      class="text-[11px] text-slate-500 hover:text-slate-800 underline decoration-slate-300 hover:decoration-slate-500 transition-colors"
                    >
                      {project.name || Path.basename(project.path)}
                    </button>
                    <button
                      type="button"
                      id="simple-review-btn"
                      phx-click="open_review"
                      class="ml-auto text-[11px] font-medium text-slate-500 hover:text-slate-800 transition-colors"
                    >
                      {ngettext("Review %{count} result →", "Review %{count} results →", @pending_review_count,
                        count: @pending_review_count)}
                    </button>
                  </div>
                <% end %>
              </div>

              <button
                type="submit"
                id="simple-launch"
                disabled={@prompt == ""}
                class={[
                  "shrink-0 rounded-full px-5 py-2.5 text-sm font-medium transition-colors",
                  @prompt == "" && "bg-slate-100 text-slate-300 cursor-not-allowed",
                  @prompt != "" && "bg-slate-900 text-white hover:bg-slate-700"
                ]}
                aria-label={gettext("Start task")}
              >
                {gettext("Start")}
              </button>
            </div>
          </.form>
        </div>
      </div>

      <Layouts.simple_corner />
    </Layouts.simple>
    """
  end

  @impl true
  def mount(_params, _session, socket) do
    # Same first-run detection as DashboardLive: dead render only, backed by
    # VersionState.onboarding_needed?/0. After the user completes (or skips)
    # /welcome once, this stops redirecting — no redirect loop.
    onboarding_needed =
      !connected?(socket) and
        if Code.ensure_loaded?(EvoGit.Config.VersionState) do
          EvoGit.Config.VersionState.onboarding_needed?()
        else
          false
        end

    if onboarding_needed do
      # First open: collect the LLM API info before anything else.
      {:ok, push_navigate(socket, to: "/welcome")}
    else
      {profiles, selected_model_id} = Project.load_model_profiles()
      recent_projects = TaskRegistry.list_recent_projects()

      socket =
        assign(socket,
          selected_model_id: selected_model_id,
          no_model?: profiles == [],
          pending_review_count: length(pending_reviews()),
          recent_projects: recent_projects,
          mode: "new",
          prompt: "",
          form: to_form(%{"prompt" => ""}),
          path_input: "",
          new_path_input: "",
          path_suggestions: [],
          new_path_suggestions: [],
          resume_from: nil,
          starting_commit: nil
        )

      {:ok, socket}
    end
  end

  @impl true
  def handle_params(params, _url, socket) do
    socket =
      case params["project"] do
        path when is_binary(path) ->
          if File.dir?(path), do: assign(socket, :path_input, Path.expand(path)), else: socket

        _ ->
          socket
      end

    # "从此处继续"（简洁审阅页）带来的续跑上下文：切到重构模式并记住
    # starting_commit / resume_from，启动原地重构时透传给任务。
    socket =
      case params["resume_from"] do
        branch when is_binary(branch) and branch != "" ->
          assign(socket,
            mode: "refactor",
            resume_from: branch,
            starting_commit: params["starting_commit"]
          )

        _ ->
          socket
      end

    {:noreply, socket}
  end

  @impl true
  def handle_event("update_prompt", %{"prompt" => prompt}, socket) do
    {:noreply, assign(socket, prompt: prompt || "", form: to_form(%{"prompt" => prompt || ""}))}
  end

  def handle_event("switch_mode", %{"mode" => mode}, socket) when mode in ["new", "refactor"] do
    {:noreply,
     assign(socket,
       mode: mode,
       path_suggestions: [],
       new_path_suggestions: []
     )}
  end

  def handle_event("suggest_path", %{"path" => value}, socket) do
    value = value || ""
    # Bare names are auto-created, not opened — path completion would mislead.
    suggestions = if bare_name?(value) and value != "", do: [], else: Project.path_suggestions(value)
    {:noreply, assign(socket, path_input: value, path_suggestions: suggestions)}
  end

  def handle_event("suggest_new_path", %{"new_path" => value}, socket) do
    {:noreply,
     assign(socket,
       new_path_input: value || "",
       new_path_suggestions: Project.path_suggestions(value || "")
     )}
  end

  def handle_event("fill_path", %{"path" => path}, socket) do
    {:noreply, assign(socket, path_input: path, path_suggestions: [])}
  end

  def handle_event("fill_new_path", %{"path" => path}, socket) do
    {:noreply, assign(socket, new_path_input: path, new_path_suggestions: [])}
  end

  # Standalone review entry: opens the list of all pending reviews so the
  # user can pick any of them (not just the most recent one).
  def handle_event("open_review", _params, socket) do
    if pending_reviews() == [] do
      {:noreply, put_flash(socket, :error, gettext("No completed task to review for this project."))}
    else
      {:noreply, push_navigate(socket, to: ~p"/tree/review")}
    end
  end

  def handle_event("launch", %{"prompt" => prompt} = params, socket) do
    prompt = String.trim(prompt || "")
    path_input = String.trim(params["path"] || socket.assigns.path_input)
    new_path_input = String.trim(params["new_path"] || socket.assigns.new_path_input)

    socket = assign(socket, path_input: path_input, new_path_input: new_path_input)

    cond do
      socket.assigns.no_model? ->
        {:noreply,
         put_flash(
           socket,
           :error,
           gettext("No LLM configured yet. Please set up your model first.")
         )}

      prompt == "" ->
        {:noreply, put_flash(socket, :error, gettext("Please describe what you want to do."))}

      socket.assigns.mode == "new" ->
        launch_new(socket, path_input, prompt)

      true ->
        launch_refactor(socket, path_input, new_path_input, prompt)
    end
  end

  # ── Private: launch flows ────────────────────────────────────────────────

  # 开发新软件: open an existing path, or auto-create a bare name.
  defp launch_new(socket, path_input, prompt) do
    if path_input == "" do
      {:noreply, put_flash(socket, :error, gettext("Please enter a development path."))}
    else
      case resolve_project(socket, path_input, allow_create: true) do
        {:ok, path} ->
          start_and_redirect(socket, path, prompt,
            genesis_opts: genesis_opts(socket, path, prompt)
          )

        {:error, message} ->
          {:noreply, put_flash(socket, :error, message)}
      end
    end
  end

  # 重构已有软件: original must exist; optional new path switches between
  # in-place evolution and port-style genesis with the original as reference.
  defp launch_refactor(socket, orig_input, new_input, prompt) do
    cond do
      orig_input == "" ->
        {:noreply, put_flash(socket, :error, gettext("Please enter a development path."))}

      true ->
        case resolve_project(socket, orig_input, allow_create: false) do
          {:error, message} ->
            {:noreply, put_flash(socket, :error, message)}

          {:ok, orig_path} ->
            if String.trim(new_input) == "" do
              opts = [path: orig_path, mode: "simple", objective: prompt]

              opts =
                case {socket.assigns.resume_from, socket.assigns.starting_commit} do
                  {nil, nil} ->
                    opts

                  {branch, commit} ->
                    opts
                    |> Keyword.put(:starting_commit, commit)
                    |> Keyword.put(:resume_from, branch)
                end

              opts = with_model(opts, socket)
              start_and_redirect(socket, orig_path, prompt, evolve: opts)
            else
              case resolve_project(socket, new_input, allow_create: true) do
                {:error, message} ->
                  {:noreply, put_flash(socket, :error, message)}

                {:ok, new_path} ->
                  foreign = [
                    ForeignRepo.new("legacy", orig_path,
                      description: gettext("Original software (refactor reference)")
                    )
                  ]

                  opts =
                    socket
                    |> genesis_opts(new_path, prompt)
                    |> Keyword.put(:foreign_repos, foreign)

                  start_and_redirect(socket, new_path, prompt, genesis_opts: opts)
              end
            end
        end
    end
  end

  defp start_and_redirect(socket, path, _prompt, opts) do
    {task_type, opts} =
      case opts do
        [evolve: o] -> {:evolve, o}
        [genesis_opts: o] -> {:genesis, o}
      end

    case TaskRegistry.start_task(task_type, opts) do
      {:ok, _task} ->
        TaskRegistry.add_recent_project(path, Path.basename(path))
        {:noreply, push_navigate(socket, to: ~p"/tree")}

      {:error, reason} ->
        {:noreply,
         put_flash(
           socket,
           :error,
           gettext("Failed to start task: %{reason}", reason: inspect(reason))
         )}
    end
  end

  defp genesis_opts(socket, path, prompt) do
    mode =
      case Project.detect_mode(path) do
        "genesis_new" -> "new"
        _ -> "existing"
      end

    [path: path, mode: mode, prompt: prompt] |> with_model(socket)
  end

  defp with_model(opts, socket) do
    case socket.assigns.selected_model_id do
      id when is_binary(id) and id != "" -> Keyword.put(opts, :model_id, id)
      _ -> opts
    end
  end

  # Completed, branch-backed tasks still awaiting review.
  defp pending_reviews, do: EvoDashWeb.SimpleLive.Reviews.pending()

  # ── Private: path resolution ─────────────────────────────────────────────

  # Opens an existing directory; when allow_create is set, a bare project
  # name (no separators) is created under the default base. Returns
  # {:ok, expanded_path} or {:error, localized_message}.
  defp resolve_project(_socket, value, allow_create: allow_create) do
    # Strip surrounding quotes — Windows Explorer copies paths as "C:\...".
    value = value |> to_string() |> String.trim() |> String.trim("\"")
    expanded = Path.expand(value)

    cond do
      value == "" ->
        {:error, gettext("Please enter a development path.")}

      File.dir?(expanded) ->
        {:ok, expanded}

      allow_create and bare_name?(value) ->
        case Project.validate_project_name(value) do
          {:error, :invalid_name} ->
            {:error, gettext("Invalid project name")}

          {:ok, sanitized} ->
            full_path = Path.join(default_projects_base(), sanitized)
            File.mkdir_p!(full_path)
            {:ok, full_path}
        end

      true ->
        {:error, gettext("Directory not found: %{path}", path: expanded)}
    end
  end

  # True for a bare project name like "calculator" — no path separators and
  # no drive colon (Windows).
  defp bare_name?(value) do
    value != "" and not String.contains?(value, ["/", "\\", ":"])
  end

  # Default base directory for auto-created projects. Overridable via
  # `config :evo_dash, :simple_projects_base` (used by tests to stay in tmp).
  defp default_projects_base do
    Application.get_env(:evo_dash, :simple_projects_base) ||
      Path.join(System.user_home!(), "GenesisProjects")
  end
end
