defmodule EvoDashWeb.TaskFormComponents do
  @moduledoc """
  Task form component for the dashboard — a minimalist three-zone
  "pageless editor" layout.

  Layout (top → bottom):
    * Zone 2 — the prompt textarea (fills all available vertical space).
    * Zone 3 — a floating bottom launcher panel (mode / launch / model).

  The top bar (Zone 1) and the collapsible Project Settings / Advanced Options
  panels live OUTSIDE this component in the dashboard layout.
  """

  # zh_CN: Evolution → "演进", Prompt → "提示词", Commit → "提交", Branch → "分支"

  use EvoDashWeb, :html

  defdelegate model_display(value), to: EvoDashWeb.SettingsComponents.SettingCard

  # ---------------------------------------------------------------------------
  # task_form/1 — Minimalist prompt editor (textarea + floating bottom launcher)
  #
  # The <.form id="task-form"> wraps BOTH the textarea (Zone 2) and the bottom
  # launcher panel (Zone 3). The top-bar controls (Build System select, Archive
  # checkbox, Advanced Options inputs) are rendered OUTSIDE this form element in
  # the dashboard, so they MUST carry form="task-form" to associate with it.
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
    <.form
      for={%{}}
      id="task-form"
      phx-submit="task_submit"
      class="w-full flex-1 flex flex-col min-h-0 gap-0"
    >
      <div class={[
        "relative flex-1 flex flex-col min-h-0 transition-opacity",
        @disabled && "opacity-40 pointer-events-none select-none"
      ]}>
        <!-- Zone 2 — the input box (fills all remaining vertical space) -->
        <textarea
          name="prompt"
          id="prompt"
          phx-update="ignore"
          class="w-full flex-1 min-h-[200px] p-6 text-base leading-relaxed bg-transparent border-0 border-b border-base-200 focus:outline-none resize-none placeholder:text-base-content/25 transition-colors focus:border-base-300"
          placeholder={
            cond do
              @mode == "genesis_existing" ->
                gettext("Optional — leave empty and click Launch to initialize an existing codebase")

              String.starts_with?(@mode, "evolve") ->
                gettext("Describe what you want to change or improve...")

              true ->
                gettext("Describe the codebase you want to create...")
            end
          }
        ><%= @prompt %></textarea>

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
      </div>

      <!-- Zone 3 — Floating bottom launcher panel (pinned bottom-center) -->
      <div class="shrink-0 flex justify-center pt-3">
        <div class="flex items-center gap-2 px-3 py-2 rounded-2xl bg-base-100/95 border border-base-200 shadow-lg backdrop-blur-sm">
          <!-- Mode switch -->
          <select
            name="mode"
            phx-change="task_change"
            class="select select-ghost select-sm bg-transparent font-medium focus:outline-none focus:ring-2 focus:ring-primary/20 min-w-[8.5rem]"
            title={mode_description(@mode)}
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

          <div class="w-px h-7 bg-base-200"></div>

          <!-- Launch Task button — the focal point -->
          <button type="submit" class="btn btn-primary gap-2 px-5" disabled={@disabled}>
            <.icon name="hero-rocket-launch" class="size-4" /> {gettext("Launch Task")}
          </button>

          <!-- Model switch -->
          <%= if @model_profiles != [] do %>
            <div class="w-px h-7 bg-base-200"></div>
            <select
              name="model_id"
              phx-change="select_model"
              class="select select-ghost select-sm bg-transparent font-medium focus:outline-none focus:ring-2 focus:ring-primary/20 min-w-[9rem]"
            >
              <%= for profile <- @model_profiles do %>
                <option value={profile.id} selected={@selected_model_id == profile.id}>
                  {profile.id <> " (" <> profile_model_label(profile) <> ")"}
                </option>
              <% end %>
            </select>
          <% end %>
        </div>
      </div>
    </.form>
    """
  end

  # ---------------------------------------------------------------------------
  # advanced_options/1 — Extracted Advanced Options panel (evolve modes)
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
      <div class={[
        "rounded-xl bg-base-100 border border-base-200 shadow-sm overflow-hidden transition-opacity",
        @disabled && "opacity-40 pointer-events-none select-none"
      ]}>
        <div class="p-3.5 flex items-center gap-2 border-b border-base-200">
          <.icon name="hero-adjustments-horizontal" class="size-4 text-base-content/60" />
          <span class="text-sm font-semibold flex-1">{gettext("Advanced Options")}</span>
        </div>
        <div class="p-4 space-y-4">
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
      </div>
    <% end %>
    """
  end

  # Renders a compact label for a profile's model spec. Handles both
  # string models (e.g., "gpt-5.6-sol") and map models
  # (e.g., %{provider: "openai", id: "gpt-4"}). Delegates to
  # model_display/1 (defined in SettingCard) for consistent rendering.
  defp profile_model_label(profile) when is_map(profile) do
    model = Map.get(profile, :model) || Map.get(profile, "model")
    model_display(model)
  end
end
