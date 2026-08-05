defmodule EvoDashWeb.TaskFormComponents do
  @moduledoc """
  Task form component for the dashboard — a single-card, two-layout
  "pageless editor".

  One card contains the objective textarea AND the controls row (mode select,
  Launch button, model select) as its last element. The layout is
  server-driven via `layout_for/1`:

    * Layout A (`data-layout="compact"`) — unified objective box: the controls
      row is the card's last line, Launch button bottom-right
      (mode | model | Launch).
    * Layout B (`data-layout="expanded"`) — large objective area with an
      in-flow launch panel below (mode | Launch | model).

  The AdaptiveInput JS hook only autogrows the textarea; the compact/expanded
  decision lives in `layout_for/1` (@short_objective_threshold / line count).

  The top bar (Zone 1) and the collapsible Project Settings / Advanced Options
  panels live OUTSIDE this component in the dashboard layout.
  """

  # zh_CN: Evolution → "演进", Prompt → "提示词", Commit → "提交", Branch → "分支"

  use EvoDashWeb, :html

  defdelegate model_display(value), to: EvoDashWeb.SettingsComponents.SettingCard

  @short_objective_threshold 300

  @doc """
  Layout decision for the task form: `:compact` (Layout A — unified box) vs
  `:expanded` (Layout B — split). Threshold: objective length > 300 graphemes
  OR > 8 explicit lines.
  """
  def layout_for(prompt) when is_binary(prompt) do
    if String.length(prompt) > @short_objective_threshold or line_count(prompt) > 8,
      do: :expanded,
      else: :compact
  end

  def layout_for(_), do: :compact

  defp line_count(prompt), do: prompt |> String.split("\n") |> length()

  # ---------------------------------------------------------------------------
  # task_form/1 — Single-card objective editor (textarea + in-flow controls row)
  #
  # The <.form id="task-form"> wraps the whole card: the textarea AND the
  # controls row (mode / Launch / model) as the card's last element. The
  # compact/expanded layout is server-driven via layout_for/1 (data-layout).
  # The top-bar controls (Build System select, Archive checkbox, Advanced
  # Options inputs) are rendered OUTSIDE this form element in the dashboard,
  # so they MUST carry form="task-form" to associate with it.
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
        <% layout = layout_for(@prompt) %>
        <!-- Single-card, two-layout objective editor.
             data-layout is SERVER-DRIVED via layout_for/1 (threshold:
             @short_objective_threshold chars or 8+ lines):
               "compact"  → Layout A — unified box: controls row is the card's
                            last line (mode | model | Launch, launch centered).
               "expanded" → Layout B — large objective area with an in-flow
                            launch panel below (mode | model | Launch).
             Both layouts share the same visual order (mode | model | Launch,
             Launch centered via mx-auto); only the textarea size differs.
             The AdaptiveInput JS hook only autogrows the textarea now. -->
        <div
          class="input-layout mx-auto w-full max-w-3xl px-4 flex-1 flex flex-col min-h-0"
          data-layout={layout}
          id="input-layout"
        >
          <div class="input-card">
            <textarea
              name="prompt"
              id="prompt"
              phx-update="ignore"
              phx-hook="AdaptiveInput"
              phx-change="task_prompt_change"
              phx-debounce="200"
              class="input-prompt w-full min-h-[120px] p-4 text-base leading-relaxed bg-transparent border-0 focus:outline-none resize-none placeholder:text-base-content/25 transition-colors"
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

            <!-- Controls row — the card's LAST element, in normal document flow
                 (never position: fixed). DOM order AND visual order are
                 identical in both layouts: mode (order-1) | Launch (order-2,
                 centered via mx-auto) | model (order-3). The Launch button
                 carries mx-auto so it stays centered even when the model
                 select is absent (2-item row: space-between would otherwise
                 push it to the right edge). -->
            <div class="input-controls">
              <!-- Mode switch -->
              <select
                name="mode"
                phx-change="task_change"
                class="select select-ghost select-sm bg-transparent font-medium focus:outline-none focus:ring-2 focus:ring-primary/20 min-w-[8.5rem] order-1"
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

              <!-- Launch Task button — the focal point, centered in BOTH
                   layouts (order-2 + mx-auto; works with or without the
                   model select). -->
              <button
                type="submit"
                class={["btn btn-primary gap-2 px-5 order-2 mx-auto"]}
                disabled={@disabled}
              >
                <.icon name="hero-rocket-launch" class="size-4" /> {gettext("Launch Task")}
              </button>

              <!-- Model switch -->
              <%= if @model_profiles != [] do %>
                <select
                  name="model_id"
                  phx-change="select_model"
                  class="select select-ghost select-sm bg-transparent font-medium focus:outline-none focus:ring-2 focus:ring-primary/20 min-w-[9rem] order-3"
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
      </div>
    </.form>
    """
  end

  # ---------------------------------------------------------------------------
  # task_options_tab/1 — "Task Options" tab content for the config dropdown.
  #
  # Consolidates the former separate top-bar controls (Build System select,
  # Archive toggle) and the Advanced Options panel (Starting Node, Starting
  # Commit, Resume from) into a single tab. All form-associated inputs carry
  # form="task-form" since they live OUTSIDE the task_form's <.form> element.
  #
  # Mode-specific behaviour:
  #   * Build System + Archive — shown for all modes.
  #   * Starting Node / Starting Commit / Resume from — evolve modes only.
  # ---------------------------------------------------------------------------

  attr(:mode, :string, default: "genesis_new")
  attr(:node_path, :string, default: "")
  attr(:starting_commit, :string, default: "")
  attr(:resume_from, :string, default: "")
  attr(:archive, :boolean, default: false)
  attr(:build_systems, :list, default: [])
  attr(:selected_build_system, :string, default: nil)
  attr(:disabled, :boolean, default: false)

  def task_options_tab(assigns) do
    ~H"""
    <div class={[
      "space-y-4 transition-opacity",
      @disabled && "opacity-40 pointer-events-none select-none"
    ]}>
      <%!-- Build System (genesis modes only) --%>
      <%= if String.starts_with?(@mode, "genesis") do %>
        <div class="form-control">
          <label class="label pb-1">
            <span class="label-text font-medium text-sm">{gettext("Build System")}</span>
          </label>
          <select
            name="build_system"
            form="task-form"
            class="select select-bordered select-sm w-full focus:outline-none focus:ring-2 focus:ring-base-content/20"
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

      <%!-- Evolve-specific advanced options --%>
      <%= if String.starts_with?(@mode, "evolve") do %>
        <div class="grid grid-cols-1 sm:grid-cols-2 gap-3">
          <div class="form-control">
            <label class="label pb-1">
              <span class="label-text font-medium text-sm">{gettext("Starting Node")}
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
              <span class="label-text font-medium text-sm">{gettext("Starting Commit")}
              <.tip text={
                gettext("A Git commit SHA, branch name, or tag to use as the base. Defaults to HEAD.")
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
      <% end %>

      <%!-- Archive toggle (all modes) --%>
      <label
        class="flex items-center gap-3 cursor-pointer bg-base-200/40 rounded-lg p-2.5 border border-base-200"
        title={gettext("Archive agent details")}
      >
        <input
          type="checkbox"
          name="archive"
          value="true"
          form="task-form"
          class="toggle toggle-sm toggle-primary"
          checked={@archive}
        />
        <div class="flex-1">
          <span class="text-sm font-medium block">{gettext("Archive agent detail")}</span>
          <span class="text-xs text-base-content/50">
            {gettext("Collect per-agent metadata for review")}
          </span>
        </div>
      </label>
    </div>
    """
  end

  # ---------------------------------------------------------------------------
  # advanced_options/1 — (legacy) Extracted Advanced Options panel (evolve modes)
  #
  # Kept for backwards compatibility. The content now lives in task_options_tab/1.
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
                <span class="label-text font-medium text-sm">{gettext("Starting Node")}
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
