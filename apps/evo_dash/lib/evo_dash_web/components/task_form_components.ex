defmodule EvoDashWeb.TaskFormComponents do
  @moduledoc """
  Task form component for the dashboard — an immersive, ChatGPT/Gemini-style
  prompt composer with slim inline controls and a prominent prompt hero.

  Layout: the prompt textarea (the visual hero) sits at the top, followed by
  a single unified toolbar row (mode / model / build system / archive toggle
  / execute button) below it. Advanced options are extracted into a separate
  `advanced_options/1` component (rendered outside this form in the dashboard
  layout, alongside Project Settings).
  """

  # zh_CN: Evolution → "演进", Prompt → "提示词", Commit → "提交", Branch → "分支"

  use EvoDashWeb, :html

  # ---------------------------------------------------------------------------
  # task_form/1 — Immersive prompt composer (hero textarea + unified toolbar)
  # ---------------------------------------------------------------------------

  attr(:prompt, :string, default: "")
  attr(:mode, :string, default: "genesis_new")
  attr(:mode_info, :string, default: "")
  attr(:node_path, :string, default: "")
  attr(:starting_commit, :string, default: "")
  attr(:resume_from, :string, default: "")
  attr(:show_advanced, :boolean, default: false)
  attr(:disabled, :boolean, default: false)
  attr(:archive, :boolean, default: false)
  attr(:model_profiles, :list, default: [])
  attr(:selected_model_id, :string, default: nil)
  attr(:build_systems, :list, default: [])
  attr(:selected_build_system, :string, default: nil)

  def task_form(assigns) do
    ~H"""
    <.form for={%{}} id="task-form" phx-submit="task_submit" class="w-full">
      <div class={["transition-opacity", @disabled && "opacity-40 pointer-events-none select-none"]}>
        <!-- Prompt hero — the centerpiece (full width at top) -->
        <div class="relative">
          <!-- Welcome hint overlay when disabled (no project active) -->
          <%= if @disabled do %>
            <div class="absolute inset-0 flex items-center justify-center pointer-events-none z-10">
              <div class="text-center">
                <div class="animate-float">
                  <.icon name="hero-sparkles" class="size-12 mx-auto mb-2 text-base-content/40" />
                </div>
                <p class="text-base font-medium text-base-content/50">
                  {gettext("Open a project to get started")}
                </p>
                <p class="text-sm text-base-content/35 mt-0.5">
                  {gettext("Select or create a project to get started")}
                </p>
              </div>
            </div>
          <% end %>

          <textarea
            name="prompt"
            id="prompt"
            phx-update="ignore"
            class="w-full min-h-[360px] p-5 text-base leading-relaxed rounded-2xl border border-base-300 bg-base-100 shadow-sm focus:outline-none focus:ring-2 focus:ring-primary/30 focus:border-primary/40 resize-y placeholder:text-base-content/30 transition-all"
            placeholder={
              cond do
                @mode == "genesis_existing" ->
                  gettext("Optional — leave empty and click Execute to initialize an existing codebase")
                String.starts_with?(@mode, "evolve") ->
                  gettext("Describe what you want to change or improve...")
                true ->
                  gettext("Describe the codebase you want to create...")
              end
            }
          ><%= @prompt %></textarea>
        </div>

        <!-- Prompt label (below textarea, subtle) -->
        <div class="px-1 mt-2">
          <%= if String.starts_with?(@mode, "evolve") do %>
            <span class="text-xs text-base-content/40">
              <%!-- zh_CN: evolution → "演进" --%>
              {gettext("Objective — describe the changes you want")}
            </span>
          <% else %>
            <span class="text-xs text-base-content/40">
              <%!-- zh_CN: Prompt → "提示词" --%>
              {gettext("Prompt — describe what to build")}
            </span>
          <% end %>
        </div>

        <!-- Unified toolbar row: Mode | Model | Build System | Archive | (spacer) | mode_info | Execute -->
        <div class="flex flex-wrap items-end gap-x-5 gap-y-2.5 mt-4">
          <!-- Task Mode -->
          <div class="flex flex-col gap-1">
            <label class="text-[11px] font-semibold uppercase tracking-wide text-base-content/40 leading-none">
              {gettext("Mode")}
            </label>
            <div class="flex items-center gap-1.5">
              <select
                name="mode"
                phx-change="task_change"
                class="select select-bordered select-sm bg-base-100 shadow-sm font-medium focus:outline-none focus:ring-2 focus:ring-primary/20 min-w-[9rem]"
              >
                <option value="genesis_existing" selected={@mode == "genesis_existing"}>
                  {gettext("Initialize Existing")}
                </option>
                <option value="genesis_new" selected={@mode == "genesis_new"}>
                  {gettext("Create New")}
                </option>
                <option value="evolve_simple" selected={@mode == "evolve_simple"}>
                  <%!-- zh_CN: Evolution → "演进" --%>{gettext("Evolution")}
                </option>
              </select>
              <.tip text={mode_description(@mode)} />
            </div>
          </div>

          <!-- Model -->
          <%= if @model_profiles != [] do %>
            <div class="flex flex-col gap-1">
              <label class="text-[11px] font-semibold uppercase tracking-wide text-base-content/40 leading-none">
                {gettext("Model")}
              </label>
              <div class="flex items-center gap-1.5">
                <select
                  name="model_id"
                  phx-change="select_model"
                  class="select select-bordered select-sm bg-base-100 shadow-sm font-medium focus:outline-none focus:ring-2 focus:ring-primary/20 min-w-[10rem]"
                >
                  <%= for profile <- @model_profiles do %>
                    <option value={profile.id} selected={@selected_model_id == profile.id}>
                      {profile.id <> " (" <> profile_model_label(profile) <> ")"}
                    </option>
                  <% end %>
                </select>
                <.tip text={gettext("Select which model profile to use for this task")} />
              </div>
            </div>
          <% end %>

          <!-- Build System (genesis modes only) -->
          <%= if String.starts_with?(@mode, "genesis") do %>
            <div class="flex flex-col gap-1">
              <label class="text-[11px] font-semibold uppercase tracking-wide text-base-content/40 leading-none">
                {gettext("Build System")}
              </label>
              <select
                name="build_system"
                class="select select-bordered select-sm bg-base-100 shadow-sm font-medium focus:outline-none focus:ring-2 focus:ring-primary/20"
              >
                <option value="">{gettext("No build system")}</option>
                <%= for bs <- @build_systems do %>
                  <option value={to_string(bs.id)} selected={@selected_build_system == to_string(bs.id)}>
                    {bs.name}
                  </option>
                <% end %>
              </select>
            </div>
          <% end %>

          <!-- Archive toggle -->
          <div class="flex flex-col gap-1">
            <label class="text-[11px] font-semibold uppercase tracking-wide text-base-content/40 leading-none">
              {gettext("Archive")}
            </label>
            <label class="label cursor-pointer flex items-center gap-2 py-0">
              <input type="checkbox" name="archive" value="true" class="toggle toggle-sm toggle-primary" />
              <span class="text-sm text-base-content/60">{gettext("Archive agent details")}</span>
            </label>
          </div>

          <!-- Right-aligned: mode_info + Execute button -->
          <div class="ml-auto flex items-center gap-4">
            <%!-- Mode info message (subtle hint, inline) --%>
            <%= if @mode_info && @mode_info != "" do %>
              <span class="text-xs text-base-content/40 italic self-end pb-1.5">
                {@mode_info}
              </span>
            <% end %>
            <button type="submit" class="btn btn-primary gap-2 px-6" disabled={@disabled}>
              <.icon name="hero-rocket-launch" class="size-4" /> {gettext("Execute Task")}
            </button>
          </div>
        </div>
      </div>
    </.form>
    """
  end

  # ---------------------------------------------------------------------------
  # advanced_options/1 — Extracted Advanced Options accordion (evolve modes)
  #
  # Rendered OUTSIDE the task_form's <.form> element in dashboard_live.ex,
  # so each input MUST carry form="task-form" to associate with the form.
  # ---------------------------------------------------------------------------

  attr(:show_advanced, :boolean, default: false)
  attr(:node_path, :string, default: "")
  attr(:starting_commit, :string, default: "")
  attr(:resume_from, :string, default: "")
  attr(:mode, :string, default: "evolve_simple")
  attr(:disabled, :boolean, default: false)

  def advanced_options(assigns) do
    ~H"""
    <%= if String.starts_with?(@mode, "evolve") do %>
      <div class={["transition-opacity", @disabled && "opacity-40 pointer-events-none select-none"]}>
        <details class="group rounded-xl bg-base-100 border border-base-200 shadow-sm overflow-hidden" open={@show_advanced}>
          <summary
            class="p-3.5 cursor-pointer hover:bg-base-200/30 transition-colors flex items-center gap-2 list-none [&::-webkit-details-marker]:hidden"
            phx-click="toggle_advanced"
          >
            <.icon name="hero-adjustments-horizontal" class="size-4 text-base-content/60" />
            <span class="text-sm font-semibold flex-1">{gettext("Advanced Options")}</span>
            <.icon
              name="hero-chevron-down"
              class="size-4 text-base-content/40 group-open:rotate-180 transition-transform"
            />
          </summary>
          <div class="p-4 pt-2 space-y-4 border-t border-base-200">
            <div class="grid grid-cols-1 sm:grid-cols-2 gap-4">
              <div class="form-control">
                <label class="label pb-1">
                  <span class="label-text font-medium text-sm">{gettext(
                    "Starting Node"
                  )}
                  <%!-- zh_CN: evolution → "演进" --%>
                  <.tip text={
                    gettext(
                      "The subdirectory within the project to start evolution from. Use './' for root."
                    )
                  } /></span>
                </label>
                <input
                  type="text"
                  name="node_path"
                  form="task-form"
                  value={@node_path}
                  class="input input-bordered input-sm w-full font-mono focus:outline-none focus:ring-2 focus:ring-base-content/20"
                  placeholder={gettext("e.g., ./src/components")}
                />
              </div>
              <div class="form-control">
                <label class="label pb-1">
                  <span class="label-text font-medium text-sm"><%!-- zh_CN: Commit → "提交" --%>{gettext(
                    "Starting Commit"
                  )}
                  <%!-- zh_CN: commit → "提交", branch → "分支" --%>
                  <.tip text={
                    gettext(
                      "A Git commit SHA, branch name, or tag to use as the base. Defaults to HEAD."
                    )
                  } /></span>
                </label>
                <input
                  type="text"
                  name="starting_commit"
                  form="task-form"
                  value={@starting_commit}
                  class="input input-bordered input-sm w-full font-mono focus:outline-none focus:ring-2 focus:ring-base-content/20"
                  placeholder={gettext("e.g., abc1234 or HEAD")}
                />
              </div>
            </div>
            <div class="form-control">
              <label class="label pb-1">
                <span class="label-text font-medium text-sm">{gettext("Resume from")}
                <.tip text={
                  gettext(
                    "The ID of a previous task to continue from. Injects the previous task's context (commits, objective, and result) into this task's objective."
                  )
                } /></span>
              </label>
              <input
                type="text"
                name="resume_from"
                form="task-form"
                value={@resume_from}
                class="input input-bordered input-sm w-full font-mono focus:outline-none focus:ring-2 focus:ring-base-content/20"
                placeholder="a1b2c3d4"
              />
            </div>
          </div>
        </details>
      </div>
    <% end %>
    """
  end

  # Renders a compact label for a profile's model spec, handling both the new
  # map format (%{provider: atom, id: string, base_url: ...}) or tuple format
  # ({:provider, [id: "id", base_url: "..."]) and the legacy
  # "provider:id" string format. The `<>` binary operator crashes on maps, so we
  # normalize to a string here.
  defp profile_model_label(%{model: model} = _profile) when is_map(model) do
    provider = model[:provider] || model["provider"]
    id = model[:id] || model["id"]

    cond do
      provider != nil and id != nil -> "#{provider}:#{id}"
      id != nil -> to_string(id)
      true -> ""
    end
  end

  defp profile_model_label(%{model: {provider, opts}}) when is_atom(provider) and is_list(opts) do
    id = Keyword.get(opts, :id)
    if id && id != "", do: "#{provider}:#{id}"
  end

  defp profile_model_label(%{model: model}) when is_binary(model), do: model
  defp profile_model_label(_profile), do: ""
end
