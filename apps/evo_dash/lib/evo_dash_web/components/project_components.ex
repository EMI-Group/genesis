defmodule EvoDashWeb.ProjectComponents do
  @moduledoc """
  Project selection and settings components for the dashboard.

  `project_omnibox/1` renders a **Command Palette** (like VS Code Cmd+K,
  Spotlight, Raycast): a clickable trigger showing the active project that
  opens a centered modal overlay with a search-filtered list of the VCT
  project registry (`%EvoGit.VCT.Mount{}` entries), an "Open by Path" action,
  and a "Create New Project" action.
  Keyboard-first: search auto-focuses, arrow keys navigate, Enter activates,
  Escape closes.

  `project_settings_panel/1`, `project_settings_tab/1`, and the private
  `project_settings_body/1p` (genesis.toml status, worktree script, dev
  commands, foreign repos) are the project SETTINGS components used by
  the Configure dropdown.
  """
  use EvoDashWeb, :html
  alias EvoGit.Core.ForeignRepo

  # ---------------------------------------------------------------------------
  # filter_projects/2 — Public helper used by both the component (rendering
  # the filtered list) and ProjectsLive (keyboard navigation index math).
  # ---------------------------------------------------------------------------

  @doc """
  Filters `projects` by a search query, matching against the mount's display
  `name`, its OS `path` AND its VCT `point` (case-insensitive substring
  match). The VCT point is optional (`nil` for an unmapped entry).
  Returns the full list when the query is empty.
  """
  def filter_projects(projects, search) do
    query =
      search
      |> to_string()
      |> String.trim()
      |> String.downcase()

    if query == "" do
      projects
    else
      Enum.filter(projects, fn project ->
        name = (Map.get(project, :name) || "") |> String.downcase()
        path = (Map.get(project, :path) || "") |> String.downcase()
        point = (Map.get(project, :point) || "") |> String.downcase()

        String.contains?(name, query) or String.contains?(path, query) or
          String.contains?(point, query)
      end)
    end
  end

  # The user-visible project identity: the mount's friendly display name,
  # falling back to the VCT point and then the OS path when name is nil/blank.
  defp display_name(project) do
    name = Map.get(project, :name)
    point = Map.get(project, :point)

    cond do
      is_binary(name) and String.trim(name) != "" -> name
      is_binary(point) and String.trim(point) != "" -> point
      true -> Map.get(project, :path)
    end
  end

  # ---------------------------------------------------------------------------
  # project_omnibox/1 — Command Palette trigger + overlay
  # ---------------------------------------------------------------------------

  attr(:active_project, :map, default: nil)
  attr(:projects, :list, default: [])
  attr(:palette_open, :boolean, default: false)
  attr(:palette_search, :string, default: "")

  attr(:palette_mode, :atom,
    values: [:menu, :open_path, :new_project, :new_workspace],
    default: :menu
  )

  attr(:palette_selected_index, :integer, default: 0)
  attr(:path_suggestions, :list, default: [])
  attr(:tauri_detected, :boolean, default: false)
  attr(:platform, :string, default: "linux")
  attr(:remote, :boolean, default: false)
  # VCT WORKSPACE view maps (`%{workspace: mount, resolved: [mount], missing:
  # [ref], nested: [ref]}`), the currently expanded workspace points, and the
  # ordered member refs already chosen in the New Workspace form.
  attr(:workspaces, :list, default: [])
  attr(:expanded_workspaces, :list, default: [])
  attr(:new_workspace_members, :list, default: [])

  def project_omnibox(assigns) do
    ~H"""
    <div id="project-omnibox">
      <!-- Trigger button (collapsed state, always visible) -->
      <button
        type="button"
        phx-click="open_project_palette"
        class="project-palette-trigger flex items-center gap-2 w-full min-w-0 bg-base-200/50 hover:bg-base-200 rounded-lg px-4 py-2 cursor-pointer transition-colors text-left"
      >
        <%= if @active_project do %>
          <.icon name="hero-folder" class="size-4 text-primary-standalone shrink-0" />
          <span class="text-base font-bold text-base-content truncate leading-tight">
            {display_name(@active_project)}
          </span>
          <span
            class="text-sm text-base-content/80 font-mono truncate hidden md:inline"
            title={@active_project.path}
          >
            {@active_project.path}
          </span>
        <% else %>
          <.icon name="hero-folder-open" class="size-4 text-base-content/60 shrink-0" />
          <span class="text-base text-base-content/80 truncate">
            {gettext("Open a project...")}
          </span>
        <% end %>
        <.icon name="hero-chevron-down" class="size-3.5 text-base-content/60 shrink-0 ml-auto" />
      </button>

      <%= if @palette_open do %>
        <!-- Backdrop (click-outside to close) -->
        <div class="project-palette-backdrop" phx-click="close_project_palette"></div>

        <!-- Palette overlay -->
        <div
          class="project-palette-overlay"
          phx-keydown="palette_keydown"
          phx-click-away="close_project_palette"
        >
          <%= case @palette_mode do %>
            <% :menu -> %>
              <.palette_menu
                projects={@projects}
                palette_search={@palette_search}
                palette_selected_index={@palette_selected_index}
                remote={@remote}
                workspaces={@workspaces}
                expanded_workspaces={@expanded_workspaces}
              />
            <% :open_path -> %>
              <.palette_open_path
                path_suggestions={@path_suggestions}
                tauri_detected={@tauri_detected}
                remote={@remote}
              />
            <% :new_project -> %>
              <.palette_new_project
                path_suggestions={@path_suggestions}
                tauri_detected={@tauri_detected}
                remote={@remote}
              />
            <% :new_workspace -> %>
              <.palette_new_workspace
                projects={@projects}
                new_workspace_members={@new_workspace_members}
              />
          <% end %>
        </div>
      <% end %>
    </div>
    """
  end

  # ---------------------------------------------------------------------------
  # palette_menu/1 — Search input + filtered projects + actions + workspaces
  # ---------------------------------------------------------------------------

  attr(:projects, :list, default: [])
  attr(:palette_search, :string, default: "")
  attr(:palette_selected_index, :integer, default: 0)
  attr(:remote, :boolean, default: false)
  attr(:workspaces, :list, default: [])
  attr(:expanded_workspaces, :list, default: [])

  defp palette_menu(assigns) do
    ~H"""
    <% filtered = filter_projects(@projects, @palette_search) %>
    <% action_base = length(filtered) %>
    <%!-- The workspace action sits AFTER the existing actions, so the keyboard
         index math stays `action_base` + a fixed offset: locally Open by Path,
         Create New Project, New Workspace (indices +0/+1/+2); on a remote node
         Create New Project is hidden, so New Workspace is +1. --%>
    <% new_workspace_index = action_base + if @remote, do: 1, else: 2 %>
    <!-- Search input -->
    <div class="p-3 border-b border-base-200">
      <div class="relative">
        <.icon
          name="hero-magnifying-glass"
          class="size-4 text-base-content/60 absolute left-3 top-1/2 -translate-y-1/2 pointer-events-none"
        />
        <input
          type="text"
          id="palette-search-input"
          name="palette_search"
          phx-hook="FocusInput"
          phx-keydown="palette_keydown"
          phx-change="palette_search"
          phx-debounce="100"
          value={@palette_search}
          placeholder={gettext("Search projects...")}
          class="input input-bordered w-full pl-9 text-sm"
        />
      </div>
    </div>

    <!-- Scrollable list -->
    <div
      id="palette-project-list"
      class="project-palette-list overflow-y-auto flex-1 p-2"
      phx-hook="PaletteList"
    >
      <%= if filtered != [] do %>
        <p class="text-xs font-semibold uppercase tracking-wide text-base-content/60 px-2 py-1">
          {gettext("Projects")}
        </p>
        <%= for {project, i} <- Enum.with_index(filtered) do %>
          <div class="relative group">
            <button
              type="button"
              phx-click="select_project"
              phx-value-path={project.path}
              data-selected={@palette_selected_index == i}
              class="project-palette-item w-full flex items-center gap-3 px-3 py-2 rounded-lg text-left transition-colors"
            >
              <.icon name="hero-folder" class="size-4 shrink-0" />
              <div class="min-w-0 flex-1">
                <div class="text-sm font-medium font-mono truncate">
                  {display_name(project)}
                </div>
                <div class="text-xs text-base-content/70 font-mono truncate" title={project.path}>
                  {project.path}
                </div>
              </div>
            </button>
            <%!-- Forget button: a sibling of the row button (not nested) so
                 clicking it never triggers the row's select_project action;
                 phx-stop-propagation is defense in depth. Barely visible by
                 default (opacity-0), appears on row hover, turns red on its
                 own hover. Available on LOCAL and REMOTE nodes alike.
                 zh_CN: Forget project → 从项目列表中移除该项目 --%>
            <button
              type="button"
              phx-click="forget_project"
              phx-value-point={Map.get(project, :point)}
              phx-stop-propagation
              aria-label={gettext("Forget %{name}", name: project.name)}
              title={gettext("Forget project")}
              class="absolute right-1.5 top-1/2 -translate-y-1/2 p-1.5 rounded-md opacity-0 group-hover:opacity-100 pointer-events-none group-hover:pointer-events-auto text-base-content/60 hover:text-error hover:bg-error/10 transition-opacity"
            >
              <.icon name="hero-trash" class="size-4" />
            </button>
          </div>
        <% end %>
      <% end %>

      <%= if filtered != [] do %>
        <div class="border-t border-base-200 my-1"></div>
      <% end %>

      <!-- Actions -->
      <button
        type="button"
        phx-click="palette_mode"
        phx-value-mode="open_path"
        data-selected={@palette_selected_index == action_base}
        class="project-palette-item w-full flex items-center gap-3 px-3 py-2 rounded-lg text-left transition-colors"
      >
        <.icon name="hero-folder-open" class="size-4 shrink-0" />
        <span class="text-sm">{gettext("Open Project by Path")}</span>
      </button>

      <%= unless @remote do %>
        <button
          type="button"
          phx-click="palette_mode"
          phx-value-mode="new_project"
          data-selected={@palette_selected_index == action_base + 1}
          class="project-palette-item w-full flex items-center gap-3 px-3 py-2 rounded-lg text-left transition-colors"
        >
          <.icon name="hero-plus-circle" class="size-4 shrink-0" />
          <span class="text-sm">{gettext("Create New Project")}</span>
        </button>
      <% end %>

      <%!-- New Workspace — available on LOCAL and REMOTE nodes alike: a
           workspace is pure VCT metadata (no OS path, no filesystem touch). --%>
      <button
        type="button"
        phx-click="palette_mode"
        phx-value-mode="new_workspace"
        data-selected={@palette_selected_index == new_workspace_index}
        class="project-palette-item w-full flex items-center gap-3 px-3 py-2 rounded-lg text-left transition-colors"
      >
        <.icon name="hero-rectangle-stack" class="size-4 shrink-0" />
        <span class="text-sm">{gettext("New Workspace")}</span>
      </button>

      <%= if filtered == [] and @palette_search != "" do %>
        <p class="text-xs text-base-content/60 px-3 py-2 text-center">
          {gettext("No matching projects")}
        </p>
      <% end %>

      <%!-- Workspaces — a pure GROUPING surface, rendered after the project
           rows AND the action buttons so the existing keyboard index math
           above is untouched. A workspace has `path: nil` and is NEVER
           activatable: it is not a runnable project. --%>
      <%= if @workspaces != [] do %>
        <div class="border-t border-base-200 my-1"></div>
        <p class="text-xs font-semibold uppercase tracking-wide text-base-content/60 px-2 py-1">
          {gettext("Workspaces")}
        </p>
        <p class="text-[11px] text-base-content/60 px-2 pb-1">
          <%!-- zh_CN: 工作区只是把项目分组，本身不是可运行的项目，不能作为任务执行路径 --%>
          {gettext("A workspace groups projects; it is not a runnable project.")}
        </p>
        <%= for ws <- @workspaces do %>
          <% point = workspace_point(ws) %>
          <% expanded? = is_binary(point) and point in @expanded_workspaces %>
          <div
            id={"workspace-row-#{workspace_slug(point)}"}
            data-workspace-point={point}
            class="px-2 py-1"
          >
            <div class="flex items-start gap-2">
              <div class="min-w-0 flex-1">
                <div class="text-sm font-medium truncate">{workspace_name(ws)}</div>
                <%= if is_binary(point) do %>
                  <div class="text-xs text-base-content/70 font-mono truncate" title={point}>
                    {point}
                  </div>
                <% end %>
                <%= if is_binary(workspace_description(ws)) do %>
                  <div class="text-xs text-base-content/60 truncate">
                    {workspace_description(ws)}
                  </div>
                <% end %>
              </div>
              <%!-- Toggle only: never opens/activates anything. --%>
              <button
                type="button"
                phx-click="toggle_workspace"
                phx-value-point={point}
                aria-expanded={to_string(expanded?)}
                class="btn btn-ghost btn-xs gap-1 shrink-0"
              >
                <span class="text-[11px] font-normal">
                  {gettext("%{count} members", count: workspace_member_count(ws))}
                </span>
                <.icon
                  name={if expanded?, do: "hero-chevron-up", else: "hero-chevron-down"}
                  class="size-3"
                />
              </button>
            </div>

            <%= if expanded? do %>
              <%= if workspace_entries(ws) == [] do %>
                <p class="text-[11px] text-base-content/60 pl-2 mt-1">
                  {gettext("No members yet.")}
                </p>
              <% else %>
                <ul class="mt-1.5 space-y-1 border-l border-base-200 pl-2">
                  <%= for member <- workspace_resolved(ws) do %>
                    <% ref_key = member_ref_key(member) %>
                    <li
                      data-workspace-member={ref_key}
                      title={ref_key}
                      class="flex items-center gap-2 min-w-0"
                    >
                      <.icon name="hero-folder" class="size-3 shrink-0" />
                      <span class="min-w-0 flex-1">
                        <span class="block text-xs font-medium truncate">
                          {display_name(member)}
                        </span>
                        <%= if is_binary(ref_key) do %>
                          <span class="block text-[11px] text-base-content/60 font-mono truncate">
                            {ref_key}
                          </span>
                        <% end %>
                      </span>
                    </li>
                  <% end %>
                  <%= for ref <- workspace_missing(ws) do %>
                    <% ref_key = ref_string(ref) %>
                    <li
                      data-workspace-missing={ref_key}
                      title={ref_key}
                      class="flex items-center gap-2 min-w-0"
                    >
                      <.icon name="hero-question-mark-circle" class="size-3 shrink-0 text-warning" />
                      <span class="min-w-0 flex-1 text-[11px] text-base-content/70 font-mono truncate">
                        {ref_key}
                      </span>
                      <span class="badge badge-warning badge-xs shrink-0">{gettext("Missing")}</span>
                    </li>
                  <% end %>
                  <%= for ref <- workspace_nested(ws) do %>
                    <% ref_key = ref_string(ref) %>
                    <li
                      data-workspace-nested={ref_key}
                      title={ref_key}
                      class="flex items-center gap-2 min-w-0"
                    >
                      <.icon name="hero-rectangle-stack" class="size-3 shrink-0" />
                      <span class="min-w-0 flex-1 text-[11px] text-base-content/70 font-mono truncate">
                        {ref_key}
                      </span>
                      <span class="badge badge-ghost badge-xs shrink-0">{gettext("Workspace")}</span>
                    </li>
                  <% end %>
                </ul>
              <% end %>
            <% end %>
          </div>
        <% end %>
      <% end %>
    </div>

    <!-- Footer keyboard hints -->
    <div class="project-palette-footer px-3 py-2 border-t border-base-200 flex items-center gap-3 text-xs text-base-content/60">
      <span><kbd>↑↓</kbd> {gettext("Navigate")}</span>
      <span><kbd>↵</kbd> {gettext("Select")}</span>
      <span><kbd>Esc</kbd> {gettext("Close")}</span>
    </div>
    """
  end

  # ---------------------------------------------------------------------------
  # palette_open_path/1 — Path input with autocomplete (Open by Path mode)
  # ---------------------------------------------------------------------------

  attr(:path_suggestions, :list, default: [])
  attr(:tauri_detected, :boolean, default: false)
  attr(:remote, :boolean, default: false)

  defp palette_open_path(assigns) do
    ~H"""
    <!-- Header with back button -->
    <div class="flex items-center gap-2 p-3 border-b border-base-200">
      <button
        type="button"
        phx-click="palette_mode"
        phx-value-mode="menu"
        class="btn btn-ghost btn-sm btn-circle shrink-0"
      >
        <.icon name="hero-arrow-left" class="size-4" />
      </button>
      <span class="text-sm font-semibold">{gettext("Open Project by Path")}</span>
    </div>

    <!-- Path form -->
    <div class="p-3">
      <.form for={%{}} phx-submit="open_project" class="flex flex-col gap-2">
        <div class="flex items-center gap-2">
          <%= if @tauri_detected and !@remote do %>
            <button
              type="button"
              id="project-path-browse-button"
              class="btn btn-sm btn-ghost gap-1 shrink-0 transition hover:ring-2 hover:ring-(--project-ring-accent)/50"
              phx-hook="DirectoryPicker"
              data-picker-id="project"
            >
              <.icon name="hero-folder-open" class="size-4" /> {gettext("Browse")}
            </button>
          <% end %>
          <div class="picker-container flex-1">
            <input
              type="text"
              name="path"
              class="input input-bordered input-sm w-full pr-8 font-mono text-sm"
              placeholder={gettext("Project path")}
              autofocus
              phx-hook="PathAutocomplete"
              phx-change="path_input"
              phx-debounce="150"
              phx-keydown="palette_keydown"
              phx-key="Escape"
              id="project-path-input"
              list="path-suggestions"
            />
            <datalist id="path-suggestions">
              <%= for suggestion <- @path_suggestions do %>
                <option value={suggestion}></option>
              <% end %>
            </datalist>
          </div>
        </div>

        <button type="submit" class="btn btn-primary btn-sm gap-1 self-end">
          <.icon name="hero-check" class="size-4" /> {gettext("Open")}
        </button>
      </.form>
    </div>
    """
  end

  # ---------------------------------------------------------------------------
  # palette_new_project/1 — New project creation form (Create New mode)
  # ---------------------------------------------------------------------------

  attr(:path_suggestions, :list, default: [])
  attr(:tauri_detected, :boolean, default: false)
  attr(:remote, :boolean, default: false)

  defp palette_new_project(assigns) do
    ~H"""
    <!-- Header with back button -->
    <div class="flex items-center gap-2 p-3 border-b border-base-200">
      <button
        type="button"
        phx-click="palette_mode"
        phx-value-mode="menu"
        class="btn btn-ghost btn-sm btn-circle shrink-0"
      >
        <.icon name="hero-arrow-left" class="size-4" />
      </button>
      <span class="text-sm font-semibold">{gettext("Create New Project")}</span>
    </div>

    <!-- New project form -->
    <div class="p-3">
      <.form for={%{}} phx-submit="create_project" class="flex flex-col gap-2">
        <!-- Project path -->
        <div>
          <label class="label py-1">
            <span class="label-text text-xs font-medium">{gettext("Project path")}</span>
          </label>
          <div class="flex items-center gap-2">
            <%= if @tauri_detected and !@remote do %>
              <button
                type="button"
                id="new-project-location-browse-button"
                class="btn btn-sm btn-ghost gap-1 shrink-0 transition hover:ring-2 hover:ring-(--project-ring-accent)/50"
                phx-hook="DirectoryPicker"
                data-picker-id="new-project"
              >
                <.icon name="hero-folder-open" class="size-4" /> {gettext("Browse")}
              </button>
            <% end %>
            <div class="picker-container flex-1">
              <input
                type="text"
                name="path"
                class="input input-bordered input-sm w-full font-mono text-sm"
                placeholder={gettext("Project path")}
                id="new-project-path-input"
                phx-hook="PathAutocomplete"
                phx-change="new_project_path_input"
                phx-debounce="150"
                list="new-project-path-suggestions"
              />
              <datalist id="new-project-path-suggestions">
                <%= for suggestion <- @path_suggestions do %>
                  <option value={suggestion}></option>
                <% end %>
              </datalist>
            </div>
          </div>
        </div>

        <div class="flex gap-2">
          <button type="submit" class="btn btn-primary btn-sm flex-1 gap-1">
            <.icon name="hero-check" class="size-4" /> {gettext("Create")}
          </button>
        </div>
      </.form>
    </div>
    """
  end

  # ---------------------------------------------------------------------------
  # palette_new_workspace/1 — New workspace form (group existing projects)
  #
  # A workspace is a pure VCT GROUPING point: it carries a name, an optional
  # description and an ORDERED member list, and it is never a runnable project.
  # The member order is the click order — the server owns it in
  # `new_workspace_members` (so the chips above the picker show position
  # numbers) and submits it verbatim.
  # ---------------------------------------------------------------------------

  attr(:projects, :list, default: [])
  attr(:new_workspace_members, :list, default: [])

  defp palette_new_workspace(assigns) do
    ~H"""
    <!-- Header with back button -->
    <div class="flex items-center gap-2 p-3 border-b border-base-200">
      <button
        type="button"
        phx-click="palette_mode"
        phx-value-mode="menu"
        class="btn btn-ghost btn-sm btn-circle shrink-0"
      >
        <.icon name="hero-arrow-left" class="size-4" />
      </button>
      <span class="text-sm font-semibold">{gettext("New Workspace")}</span>
    </div>

    <div class="p-3">
      <.form
        for={%{}}
        id="new-workspace-form"
        phx-submit="create_workspace"
        class="flex flex-col gap-2"
      >
        <div>
          <label class="label py-1">
            <span class="label-text text-xs font-medium">{gettext("Name")}</span>
          </label>
          <input
            type="text"
            id="new-workspace-name-input"
            name="name"
            required
            placeholder={gettext("Workspace name")}
            class="input input-bordered input-sm w-full"
          />
        </div>

        <div>
          <label class="label py-1">
            <span class="label-text text-xs font-medium">{gettext("Description (optional)")}</span>
          </label>
          <input
            type="text"
            id="new-workspace-description-input"
            name="description"
            placeholder={gettext("Short description of what this group is for")}
            class="input input-bordered input-sm w-full"
          />
        </div>

        <%!-- Selected members, in click order (the order is submitted verbatim). --%>
        <%= if @new_workspace_members != [] do %>
          <div class="flex flex-wrap gap-1">
            <%= for {point, index} <- Enum.with_index(@new_workspace_members) do %>
              <span
                data-workspace-selected={point}
                class="badge badge-primary badge-sm gap-1 max-w-full"
                title={point}
              >
                <span class="font-mono text-[11px] shrink-0">{index + 1}.</span>
                <span class="font-mono text-[11px] truncate">{point}</span>
              </span>
            <% end %>
          </div>
        <% end %>

        <%!-- Member picker — one clickable row per project mount on this node. --%>
        <div class="max-h-48 overflow-y-auto rounded-lg border border-base-200">
          <%= if @projects == [] do %>
            <p class="text-xs text-base-content/60 px-2 py-3 text-center">
              {gettext("No projects to add yet. Open a project first.")}
            </p>
          <% else %>
            <%= for project <- @projects do %>
              <% project_point = Map.get(project, :point) %>
              <% selected? = is_binary(project_point) and project_point in @new_workspace_members %>
              <button
                type="button"
                data-workspace-pick={project_point}
                data-selected={selected?}
                phx-click="toggle_workspace_member"
                phx-value-point={project_point}
                phx-value-path={Map.get(project, :path)}
                class="w-full flex items-center gap-2 px-2 py-1.5 text-left transition-colors hover:bg-base-200/60"
              >
                <.icon
                  name={if selected?, do: "hero-check-circle", else: "hero-plus-circle"}
                  class={
                    if selected?,
                      do: "size-3.5 shrink-0 text-primary-standalone",
                      else: "size-3.5 shrink-0"
                  }
                />
                <span class="min-w-0 flex-1">
                  <span class="block text-xs font-medium truncate">{display_name(project)}</span>
                  <span class="block text-[11px] text-base-content/60 font-mono truncate">
                    {project_point || Map.get(project, :path)}
                  </span>
                </span>
              </button>
            <% end %>
          <% end %>
        </div>

        <button type="submit" class="btn btn-primary btn-sm gap-1">
          <.icon name="hero-check" class="size-4" /> {gettext("Create or update")}
        </button>
        <p class="text-[11px] text-base-content/60">
          <%!-- zh_CN: 同名工作区会被整体替换（名称、成员与描述一起覆盖），不会新增第二个 --%>
          {gettext("An existing workspace with the same name is replaced, not duplicated.")}
        </p>
      </.form>
    </div>
    """
  end

  # ---------------------------------------------------------------------------
  # Workspace view helpers — TOTAL over any shape.
  #
  # A workspace entry reaching the palette is the view map built by
  # `EvoDashWeb.ProjectsLive.AsyncLoad.load_workspaces/3`
  # (`%{workspace: mount, resolved: [mount], missing: [ref], nested: [ref]}`),
  # but a bare `%EvoGit.VCT.Mount{}` (or a partially-built map) renders too.
  # Every field is treated as possibly nil.
  # ---------------------------------------------------------------------------

  defp workspace_mount(%{workspace: %{} = mount}), do: mount
  defp workspace_mount(%{} = entry), do: entry
  defp workspace_mount(_entry), do: %{}

  defp workspace_point(entry) do
    case Map.get(workspace_mount(entry), :point) do
      point when is_binary(point) -> point
      _ -> nil
    end
  end

  # Primary line: display name → point → point slug.
  defp workspace_name(entry) do
    mount = workspace_mount(entry)
    name = Map.get(mount, :name)

    cond do
      is_binary(name) and String.trim(name) != "" -> name
      is_binary(workspace_point(entry)) -> workspace_point(entry)
      true -> workspace_slug(workspace_point(entry))
    end
  end

  defp workspace_description(entry) do
    case Map.get(workspace_mount(entry), :description) do
      description when is_binary(description) ->
        if String.trim(description) == "", do: nil, else: description

      _ ->
        nil
    end
  end

  defp workspace_member_count(entry) do
    length(workspace_resolved(entry)) + length(workspace_missing(entry)) +
      length(workspace_nested(entry))
  end

  defp workspace_resolved(entry), do: Map.get(entry, :resolved) |> list_or_empty()
  defp workspace_missing(entry), do: Map.get(entry, :missing) |> list_or_empty()
  defp workspace_nested(entry), do: Map.get(entry, :nested) |> list_or_empty()

  defp workspace_entries(entry) do
    workspace_resolved(entry) ++ workspace_missing(entry) ++ workspace_nested(entry)
  end

  defp list_or_empty(list) when is_list(list), do: list
  defp list_or_empty(_other), do: []

  # A resolved member's DOM/ref key: its point, else its OS path.
  defp member_ref_key(member) do
    point = Map.get(member, :point)
    path = Map.get(member, :path)

    cond do
      is_binary(point) and point != "" -> point
      is_binary(path) and path != "" -> path
      true -> nil
    end
  end

  # A stored member ref (`%{"point" => … | nil, "path" => … | nil}`, atom keys
  # tolerated) as ONE displayable string: the non-nil point, else the path.
  defp ref_string(ref) when is_binary(ref), do: ref

  defp ref_string(ref) when is_map(ref) do
    point = Map.get(ref, "point") || Map.get(ref, :point)
    path = Map.get(ref, "path") || Map.get(ref, :path)

    cond do
      is_binary(point) and point != "" -> point
      is_binary(path) and path != "" -> path
      true -> ""
    end
  end

  defp ref_string(ref) when is_list(ref),
    do: ref |> List.wrap() |> Enum.map(&ref_string/1) |> Enum.join(" ")

  defp ref_string(_ref), do: ""

  # A stable, DOM-safe id fragment for a workspace point
  # (`vct:///workspaces/my-group` → `my-group`).
  defp workspace_slug(point) when is_binary(point) do
    slug =
      point
      |> String.replace_prefix("vct:///workspaces/", "")
      |> String.replace(~r/[^A-Za-z0-9_-]+/, "-")
      |> String.trim("-")

    if slug == "", do: "unknown", else: slug
  end

  defp workspace_slug(_point), do: "unknown"

  # ---------------------------------------------------------------------------
  # project_settings_panel/1 — Collapsible settings accordion
  #
  # Uses a native <details> element with open={@show} for the toggle.
  # Styled identically to the Advanced Options accordion in
  # TaskFormComponents for visual consistency. Works at any width within
  # the centered hero column layout.
  # ---------------------------------------------------------------------------

  attr(:active_project, :string, required: true)
  attr(:show, :boolean, default: false)
  attr(:project_config, :map, default: nil)
  attr(:worktree_script, :string, default: nil)
  attr(:commands, :map, default: %{})
  attr(:foreign_repos, :list, default: [])
  attr(:foreign_repo_path_suggestions, :list, default: [])
  attr(:show_add_foreign_repo, :boolean, default: false)
  attr(:new_repo_id, :string, default: "")
  attr(:new_repo_path, :string, default: "")
  attr(:new_repo_description, :string, default: "")
  attr(:tauri_detected, :boolean, default: false)
  attr(:platform, :string, default: "linux")
  attr(:remote, :boolean, default: false)
  attr(:new_repo_base_sha, :string, default: "")
  attr(:editing_foreign_repo_id, :string, default: nil)
  attr(:foreign_repo_edit_form, :map, default: nil)

  def project_settings_panel(assigns) do
    ~H"""
    <%= if @show do %>
      <div class="rounded-xl bg-base-100 border border-base-200 shadow-sm overflow-hidden">
        <div
          class="p-3.5 cursor-pointer hover:bg-base-200/30 transition-colors flex items-center gap-2"
          phx-click="toggle_project_settings"
          phx-value-project={@active_project}
        >
          <.icon name="hero-cog-6-tooth" class="size-4 text-base-content/60" />
          <span class="text-sm font-semibold flex-1">{gettext("Project Settings")}</span>
          <!-- Config status indicator -->
          <%= if @project_config do %>
            <span class="badge badge-success badge-xs gap-0.5">
              <.icon name="hero-check-circle" class="size-3" /> {gettext("genesis.toml")}
            </span>
          <% else %>
            <span class="badge badge-ghost badge-xs gap-0.5">
              <.icon name="hero-document-text" class="size-3" /> {gettext("Defaults")}
            </span>
          <% end %>
          <.icon name="hero-chevron-up" class="size-4 text-base-content/40" />
        </div>

        <div class="p-4 pt-2 space-y-4 border-t border-base-200">
          <.project_settings_body {assigns} />
        </div>
      </div>
    <% end %>
    """
  end

  # ---------------------------------------------------------------------------
  # project_settings_tab/1 — "Project Settings" tab content for the config
  # dropdown. Renders the same body as project_settings_panel/1 but WITHOUT the
  # collapsible accordion header (the dropdown tab provides the framing).
  # ---------------------------------------------------------------------------

  attr(:active_project, :string, required: true)
  attr(:project_config, :map, default: nil)
  attr(:worktree_script, :string, default: nil)
  attr(:commands, :map, default: %{})
  attr(:foreign_repos, :list, default: [])
  attr(:foreign_repo_path_suggestions, :list, default: [])
  attr(:show_add_foreign_repo, :boolean, default: false)
  attr(:new_repo_id, :string, default: "")
  attr(:new_repo_path, :string, default: "")
  attr(:new_repo_description, :string, default: "")
  attr(:tauri_detected, :boolean, default: false)
  attr(:platform, :string, default: "linux")
  attr(:remote, :boolean, default: false)
  attr(:new_repo_base_sha, :string, default: "")
  attr(:editing_foreign_repo_id, :string, default: nil)
  attr(:foreign_repo_edit_form, :map, default: nil)

  def project_settings_tab(assigns) do
    ~H"""
    <div class="space-y-4">
      <.project_settings_body {assigns} />
    </div>
    """
  end

  # Shared body content for both the legacy panel and the dropdown tab.
  attr(:remote, :boolean, default: false)

  defp project_settings_body(assigns) do
    ~H"""
    <!-- Config status -->
    <p class="text-sm">
      <%= if @project_config do %>
        <span class="text-success flex items-center gap-1">
          <.icon name="hero-check-circle" class="size-4" /> {gettext(
            "genesis.toml found — using project settings"
          )}
        </span>
      <% else %>
        <span class="text-base-content/70 flex items-center gap-1">
          <.icon name="hero-information-circle" class="size-4" /> {gettext(
            "No genesis.toml — using global defaults"
          )}
        </span>
      <% end %>
    </p>

    <!-- Project Root -->
    <div class="bg-base-200/40 rounded-lg p-2.5 border border-base-200">
      <p class="text-xs text-base-content/70 font-medium uppercase tracking-wide">
        {gettext("Project Root")}
      </p>
      <p class="text-xs font-mono mt-0.5 truncate">{@active_project}</p>
    </div>

    <%= if @worktree_script do %>
      <div class="bg-base-200/40 rounded-lg p-2.5 border border-base-200">
        <p class="text-xs text-base-content/70 font-medium uppercase tracking-wide">
          {gettext("Worktree Init Script")}
        </p>
        <p class="text-xs font-mono mt-0.5">{@worktree_script}</p>
      </div>
    <% end %>

    <!-- Dev Commands -->
    <%= if @commands != %{} do %>
      <div class="border-t border-base-200 pt-3">
        <h3 class="text-sm font-semibold flex items-center gap-2 mb-2">
          <.icon name="hero-terminal" class="size-4 text-secondary" /> {gettext("Dev Commands")}
          <.tip text={
            gettext("Quick shortcuts for common development commands. Click Run to execute.")
          } />
        </h3>
        <div class="space-y-1.5">
          <%= for {name, cmd} <- Enum.sort(@commands) do %>
            <div class="flex items-center gap-2 bg-base-200/40 rounded-lg p-2 border border-base-200 border-l-2 border-l-accent/40">
              <span class="badge badge-accent badge-sm font-mono">{name}</span>
              <span class="text-xs font-mono flex-1 truncate">{cmd}</span>
              <button class="btn btn-ghost btn-xs" phx-click="run_command" phx-value-command={name}>
                <.icon name="hero-play" class="size-3" /> {gettext("Run")}
              </button>
            </div>
          <% end %>
        </div>
      </div>
    <% end %>

    <!-- Foreign Repos -->
    <div class="border-t border-base-200 pt-3">
      <h3 class="text-sm font-semibold flex items-center gap-2 mb-2">
        <.icon name="hero-server-stack" class="size-4 text-secondary" /> {gettext(
          "Foreign Repositories"
        )}
        <.tip text={
          gettext(
            "Foreign repos are additional codebases accessible to agents during task execution. Useful for referencing original code or related projects."
          )
        } />
      </h3>

      <%= if @foreign_repos == [] do %>
        <div class="border-2 border-dashed border-base-300 rounded-lg p-4 text-center text-base-content/60">
          <.icon name="hero-server-stack" class="size-6 mx-auto mb-1 opacity-30" />
          <p class="text-xs font-medium">{gettext("No foreign repositories registered")}</p>
        </div>
      <% else %>
        <div class="space-y-2">
          <%= for repo <- @foreign_repos do %>
            <% accent_class =
              if ForeignRepo.primary?(repo.id), do: "bg-primary", else: "bg-secondary/60" %>
            <% badge_class =
              if ForeignRepo.primary?(repo.id), do: "badge-primary", else: "badge-ghost" %>
            <% edit_form = Map.get(assigns, :foreign_repo_edit_form) || %{} %>
            <div class="bg-base-100 rounded-lg p-2.5 border border-base-200 relative group flex flex-col gap-1 hover:border-secondary/30 transition-colors">
              <div class={"absolute left-0 top-0 bottom-0 w-1 rounded-l-lg #{accent_class}"}></div>
              <div class="flex items-center justify-between ml-2 gap-2">
                <span class="flex items-center gap-1.5 min-w-0">
                  <span class={"badge #{badge_class} badge-sm font-mono shrink-0"}>
                    {repo.id}
                  </span>
                  <%= if repo.writable do %>
                    <span class="badge badge-warning badge-sm shrink-0"><%!-- zh_CN: Writable → 可写：可写的外来仓库会获得独立工作树和 evogit-agent-* 分支，参与任务但不会被任务合并 --%>{gettext(
                      "Writable"
                    )}</span>
                  <% end %>
                  <%= if repo.base_sha do %>
                    <code
                      class="text-xs font-mono text-base-content/70 truncate"
                      title={repo.base_sha}
                    >
                      {repo.base_sha}
                    </code>
                  <% end %>
                </span>
                <%= unless ForeignRepo.primary?(repo.id) do %>
                  <span class="flex items-center gap-0.5 opacity-0 group-hover:opacity-100 transition-opacity shrink-0">
                    <button
                      class="btn btn-ghost btn-xs"
                      phx-click="edit_foreign_repo"
                      phx-value-repo_id={repo.id}
                    >
                      <.icon name="hero-pencil" class="size-3" />
                    </button>
                    <button
                      class="btn btn-ghost btn-xs text-error"
                      phx-click="remove_foreign_repo"
                      phx-value-repo_id={repo.id}
                    >
                      <.icon name="hero-trash" class="size-3" />
                    </button>
                  </span>
                <% end %>
              </div>
              <%= if Map.get(assigns, :editing_foreign_repo_id) == repo.id do %>
                <div class="ml-2 mt-1 border-t border-base-200 pt-2">
                  <.form for={%{}} phx-submit="save_foreign_repo" class="space-y-2">
                    <div>
                      <label class="label py-1">
                        <span class="label-text text-xs font-medium">{gettext("Repo ID")}</span>
                      </label>
                      <input
                        type="text"
                        name="repo_id"
                        value={Map.get(edit_form, :repo_id, repo.id)}
                        readonly
                        class="input input-bordered input-sm w-full font-mono opacity-60"
                      />
                    </div>
                    <div>
                      <label class="label py-1">
                        <span class="label-text text-xs font-medium">{gettext("Path")}</span>
                      </label>
                      <input
                        type="text"
                        name="path"
                        value={Map.get(edit_form, :path, repo.root)}
                        class="input input-bordered input-sm w-full font-mono"
                      />
                    </div>
                    <div>
                      <label class="label py-1">
                        <span class="label-text text-xs font-medium">{gettext(
                          "Description (optional)"
                        )}</span>
                      </label>
                      <input
                        type="text"
                        name="description"
                        value={Map.get(edit_form, :description, repo.description)}
                        placeholder={gettext("Short description of what this repo does")}
                        class="input input-bordered input-sm w-full"
                      />
                    </div>
                    <label class="flex items-center gap-2 cursor-pointer">
                      <input
                        type="checkbox"
                        name="writable"
                        value="true"
                        class="checkbox checkbox-sm checkbox-warning"
                        checked={Map.get(edit_form, :writable, repo.writable) in [true, "true"]}
                      />
                      <span class="label-text text-xs font-medium"><%!-- zh_CN: Writable → 可写：可写的外来仓库会获得独立工作树和 evogit-agent-* 分支，参与任务但不会被任务合并 --%>{gettext(
                        "Writable"
                      )}</span>
                    </label>
                    <div>
                      <label class="label py-1">
                        <span class="label-text text-xs font-medium">{gettext("Starting Commit")}</span>
                      </label>
                      <input
                        type="text"
                        name="base_sha"
                        value={Map.get(edit_form, :base_sha, repo.base_sha)}
                        placeholder={gettext("branch or SHA, blank = HEAD")}
                        class="input input-bordered input-sm w-full font-mono"
                      />
                    </div>
                    <div class="flex gap-2">
                      <button type="submit" class="btn btn-primary btn-xs flex-1 gap-1">
                        <.icon name="hero-check" class="size-3" /> {gettext("Save")}
                      </button>
                      <button
                        type="button"
                        class="btn btn-ghost btn-xs"
                        phx-click="cancel_edit_foreign_repo"
                      >
                        {gettext("Cancel")}
                      </button>
                    </div>
                  </.form>
                </div>
              <% else %>
                <div class="ml-2 mt-1">
                  <span class="text-xs font-mono block truncate" title={repo.root}>{repo.root}</span>
                  <%= if repo.description do %>
                    <span class="text-xs text-base-content/70 block mt-0.5">{repo.description}</span>
                  <% end %>
                </div>
              <% end %>
            </div>
          <% end %>
        </div>
      <% end %>

      <!-- Add Foreign Repo -->
      <%= if @show_add_foreign_repo do %>
        <div class="mt-2 border border-base-200 rounded-lg p-3 bg-base-200/20 animate-slide-down">
          <.form for={%{}} phx-submit="add_foreign_repo" class="space-y-2">
            <div>
              <label class="label py-1">
                <span class="label-text text-xs font-medium">{gettext("Repo ID")}
                <.tip text={
                  gettext("A unique identifier for this repository (e.g., 'original', 'upstream')")
                } /></span>
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
              <label class="label py-1">
                <span class="label-text text-xs font-medium">{gettext("Path")}
                <.tip text={gettext("Absolute path to the repository root on this machine")} /></span>
              </label>
              <div class="flex items-center gap-2">
                <div class="picker-container relative flex-1">
                  <input
                    type="text"
                    name="path"
                    value={@new_repo_path}
                    placeholder={platform_placeholder(@platform)}
                    class="input input-bordered input-sm w-full font-mono pr-8"
                    required
                    id="foreign-repo-path-input"
                    phx-hook="PathAutocomplete"
                    phx-change="foreign_repo_path_input"
                    phx-debounce="150"
                    list="foreign-repo-path-suggestions"
                  />
                  <datalist id="foreign-repo-path-suggestions">
                    <%= for suggestion <- @foreign_repo_path_suggestions do %>
                      <option value={suggestion}></option>
                    <% end %>
                  </datalist>
                </div>
                <%= if @tauri_detected and !@remote do %>
                  <button
                    type="button"
                    id="foreign-repo-path-browse-button"
                    class="btn btn-sm btn-ghost gap-1 shrink-0 transition hover:ring-2 hover:ring-(--project-ring-accent)/50"
                    phx-hook="DirectoryPicker"
                    data-picker-id="foreign-repo"
                  >
                    <.icon name="hero-folder-open" class="size-4" /> {gettext("Browse")}
                  </button>
                <% end %>
              </div>
            </div>
            <div>
              <label class="label py-1">
                <span class="label-text text-xs font-medium">{gettext("Description (optional)")}</span>
              </label>
              <input
                type="text"
                name="description"
                value={@new_repo_description}
                placeholder={gettext("Short description of what this repo does")}
                class="input input-bordered input-sm w-full"
              />
            </div>
            <label class="flex items-center gap-2 cursor-pointer">
              <input
                type="checkbox"
                name="writable"
                value="true"
                class="checkbox checkbox-sm checkbox-warning"
              />
              <span class="label-text text-xs font-medium"><%!-- zh_CN: Writable → 可写：可写的外来仓库会获得独立工作树和 evogit-agent-* 分支，参与任务但不会被任务合并 --%>{gettext(
                "Writable"
              )}
              <.tip text={
                gettext(
                  "Writable foreign repos get their own worktree and evogit-agent-* branch, are tracked in the task report, but are never merged by the task."
                )
              } /></span>
            </label>
            <div>
              <label class="label py-1">
                <span class="label-text text-xs font-medium">{gettext("Starting Commit")}
                <%!-- zh_CN: 起始提交：分支名或提交哈希，留空表示 HEAD --%>
                <.tip text={gettext("Branch name or commit SHA, blank = HEAD")} /></span>
              </label>
              <input
                type="text"
                name="base_sha"
                value={Map.get(assigns, :new_repo_base_sha, "")}
                placeholder={gettext("branch or SHA, blank = HEAD")}
                class="input input-bordered input-sm w-full font-mono"
              />
            </div>
            <div class="flex gap-2">
              <button type="submit" class="btn btn-primary btn-sm flex-1 gap-1">
                <.icon name="hero-plus" class="size-3" /> {gettext("Add")}
              </button>
              <button
                type="button"
                class="btn btn-ghost btn-sm"
                phx-click="toggle_add_foreign_repo_form"
              >
                {gettext("Cancel")}
              </button>
            </div>
          </.form>
        </div>
      <% else %>
        <button
          class="btn btn-sm btn-outline btn-secondary w-full gap-1 mt-2"
          phx-click="toggle_add_foreign_repo_form"
        >
          <.icon name="hero-plus-circle" class="size-4" /> {gettext("Add Foreign Repo")}
        </button>
      <% end %>
    </div>
    """
  end

  defp platform_placeholder(_platform), do: gettext("Project path")
end
