defmodule EvoDashWeb.TaskFormComponents do
  @moduledoc """
  Task form component for the dashboard — a single-card, two-layout
  "pageless editor".

  One card contains the objective textarea AND the controls row (agent + mode
  selects, Launch button, model select) as its last element. The layout is
  server-seeded at render time via `layout_for/1` and client-driven by the
  AdaptiveInput JS hook (which adds a height-based trigger on top of the
  server thresholds): the hook
  re-asserts the client-computed layout (a) while typing, on mount/updates,
  and (b) whenever the server re-seeds `data-layout` from its possibly-stale
  `@task_prompt` — a MutationObserver on `.input-layout` (attributeFilter:
  ['data-layout']) re-runs the computation on any server re-render (e.g.
  toggling mode/model), so the layout can never snap back to compact while a
  long prompt remains in the box. The observer converges immediately (the
  hook only writes the attribute when the computed value differs) with zero
  network events:

    * Layout A (`data-layout="compact"`) — unified objective box: the controls
      row is the card's last line. The compact textarea keeps its own
      max-height cap (~8 wrapped lines) — load-bearing for the AdaptiveInput
      hook's flip-to-expanded decision.
    * Layout B (`data-layout="expanded"`) — the input card fills the available
      page height (flex column): `.input-card` is `flex: 1; min-height: 0;
      overflow: hidden`, the textarea is `flex: 1` with internal scrolling
      (`overflow-y: auto`) and NO max-height cap, and the in-flow
      `.input-controls` launch panel is pinned at the bottom of the card by
      flexbox — the card's overflow containment bounds the textarea on any
      viewport height.

  Both layouts share the same control order — agent + mode (order-1) | Launch
  (order-2, centered via mx-auto) | model (order-3); only the textarea size
  differs. The accent decorations (accent border-color, layered box-shadow
  glow, top-edge gradient) are defined on the base `.input-card` CSS rule
  and are shared by both layouts.

  There is NO per-keystroke server round trip: the textarea sends no
  `phx-change` event. The AdaptiveInput JS hook autogrows the textarea AND
  switches `data-layout` between compact/expanded client-side, flipping to
  expanded when the content would exceed the compact max-height cap (~8
  wrapped lines) OR on `layout_for/1`'s thresholds (@short_objective_threshold
  / line count), with hysteresis when flipping back to compact. It
  re-asserts the layout not only while typing but also whenever the server
  re-seeds the `data-layout` attribute from its stale `@task_prompt` (a
  MutationObserver on `.input-layout` re-runs the computation after any
  server re-render, e.g. toggling mode/model; it converges in one step with
  no loop and zero network events). `layout_for/1` only seeds the initial
  `data-layout` attribute at render time (SSR first paint + after
  restore/submit) — the client is authoritative afterwards. Prompt draft
  persistence is purely client-side (the StatePersistence input watcher in
  app.js).

  The top bar (Zone 1) and the collapsible Project Settings / Advanced Options
  panels live OUTSIDE this component in the dashboard layout.
  """

  # zh_CN: Evolution → "演进", Prompt → "提示词", Commit → "提交", Branch → "分支"

  use EvoDashWeb, :html

  @short_objective_threshold 600

  @doc """
  Layout decision for the task form: `:compact` (Layout A — unified box) vs
  `:expanded` (Layout B — split). Threshold: objective length > 600 graphemes
  OR > 16 explicit lines.

  This seeds the initial `data-layout` attribute at render time (SSR first
  paint + after restore/submit) — after that the client is authoritative.
  While typing, the AdaptiveInput JS hook switches the layout client-side —
  flipping to expanded when the content would exceed the compact max-height
  cap (~8 wrapped lines) OR on these thresholds, with hysteresis when
  flipping back — and it also re-asserts the computed layout
  whenever the server re-seeds the attribute from its possibly-stale
  `@task_prompt` (a MutationObserver on `.input-layout` catches any server
  re-render, e.g. toggling mode/model; it converges immediately since the
  hook only writes the attribute when the computed value differs, with zero
  network events) — there is no per-keystroke server event.
  """
  def layout_for(prompt) when is_binary(prompt) do
    if String.length(prompt) > @short_objective_threshold or line_count(prompt) > 16,
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
  # compact/expanded layout is server-seeded at render via layout_for/1
  # (data-layout) and client-driven by the AdaptiveInput hook (adds a
  # height-based trigger — flips to expanded when the content exceeds the
  # compact max-height cap ~8 wrapped lines or the char/line thresholds,
  # with hysteresis): it re-asserts the layout while typing AND whenever the
  # server re-seeds the attribute
  # from its possibly-stale @task_prompt (a MutationObserver on .input-layout
  # catches any server re-render, e.g. toggling mode/model, converging with
  # no loop and zero network events). The top-bar controls (Build System
  # select, Archive checkbox, Advanced Options inputs) are rendered OUTSIDE
  # this form element in the dashboard, so they MUST carry form="task-form"
  # to associate with it.
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
  attr(:custom_agents, :list, default: [])
  attr(:selected_agent_id, :string, default: nil)
  attr(:show_auto_model_option, :boolean, default: false)
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
             data-layout is server-seeded at render time via layout_for/1
             (threshold: @short_objective_threshold chars or 16+ lines) and
             client-driven by the AdaptiveInput JS hook (flips to expanded
             when the content exceeds the compact max-height cap ~8 wrapped
             lines or the char/line thresholds, with hysteresis — no
             per-keystroke server event): the hook re-asserts the computed
             layout while typing AND whenever the server
             re-seeds the attribute from its stale @task_prompt (a
             MutationObserver on .input-layout catches any server re-render,
             e.g. toggling mode/model, converging with no loop):
               "compact"  → Layout A — unified box: controls row is the card's
                            last line (agent+mode | Launch | model, launch centered).
               "expanded" → Layout B — large objective area with an in-flow
                            launch panel below (agent+mode | Launch | model).
             Both layouts share the same visual order — agent + mode (order-1) |
             Launch (order-2, centered via mx-auto) | model (order-3); only
             the textarea size differs. -->
        <div
          class="input-layout mx-auto w-full max-w-3xl px-4 flex-1 flex flex-col min-h-0"
          data-layout={layout}
          id="input-layout"
        >
          <div class="input-card relative">
            <textarea
              name="prompt"
              id="prompt"
              phx-update="ignore"
              phx-hook="AdaptiveInput"
              class="input-prompt w-full p-4 text-base bg-transparent border-0 focus:outline-none resize-none placeholder:text-base-content/45 transition-colors"
              placeholder={
                cond do
                  @mode == "genesis_existing" ->
                    gettext(
                      "Optional — leave empty and click Launch to initialize an existing codebase"
                    )

                  evolve_family_mode?(@mode) ->
                    gettext("Describe what you want to change or improve...")

                  true ->
                    gettext("Describe the codebase you want to create...")
                end
              }
            ><%= @prompt %></textarea>

            <%!-- Attach-file button — floats at the card's top-right corner
                 (absolute, requires `relative` on .input-card). Rendered only
                 when a project is open (@disabled == false), same gate as the
                 controls row. The FilePicker JS hook owns the click: it pushes
                 a "file_pick" event to the server (ProjectsLive runs the
                 native file dialog and appends the picked file's text to the
                 objective) and writes the returned prompt back into the
                 textarea — the server cannot do it, because the textarea is
                 phx-update="ignore" (the DOM is authoritative). type="button"
                 is CRITICAL: inside the task form, a button without it would
                 submit. --%>
            <%= unless @disabled do %>
              <%!-- Manual path fallback for the attach-file "+" button —
                   rendered hidden; the FilePicker JS hook reveals it when the
                   native picker is unavailable (headless server, remote node,
                   picker disabled) and submits the typed path via the
                   "file_pick_manual" event. Positioned to the LEFT of the "+"
                   button (absolute top-right, .file-manual in app.css).
                   phx-update="ignore" is CRITICAL (same contract as the
                   textarea): visibility / typed value / inline error are
                   client-owned, so a server re-render (e.g. task broadcasts,
                   mode toggles) must never reset the open input. All
                   user-facing strings are gettext-wrapped here (the JS hook
                   only toggles visibility and reads payload.reason). --%>
              <div
                id="objective-file-manual"
                class="file-manual"
                phx-update="ignore"
                hidden
              >
                <div class="file-manual-input-wrap">
                  <%!-- zh_CN: 手动输入完整文件路径的占位提示 → "输入完整文件路径…" --%>
                  <input
                    type="text"
                    class="file-manual-input"
                    placeholder={gettext("Type a full file path…")}
                    aria-label={gettext("File path to attach")}
                    autocomplete="off"
                    spellcheck="false"
                  />
                  <%!-- zh_CN: 确认输入的文件路径 → "确认附加文件路径" --%>
                  <button
                    type="button"
                    class="file-manual-confirm"
                    aria-label={gettext("Confirm attach file path")}
                    title={gettext("Confirm attach file path")}
                  >
                    <svg
                      xmlns="http://www.w3.org/2000/svg"
                      viewBox="0 0 24 24"
                      fill="none"
                      stroke="currentColor"
                      stroke-width="2"
                      stroke-linecap="round"
                      stroke-linejoin="round"
                    >
                      <path d="M5 13l4 4L19 7" />
                    </svg>
                  </button>
                  <%!-- zh_CN: 取消手动附加文件 → "取消附加文件路径" --%>
                  <button
                    type="button"
                    class="file-manual-cancel"
                    aria-label={gettext("Cancel attach file path")}
                    title={gettext("Cancel attach file path")}
                  >
                    <svg
                      xmlns="http://www.w3.org/2000/svg"
                      viewBox="0 0 24 24"
                      fill="none"
                      stroke="currentColor"
                      stroke-width="2"
                      stroke-linecap="round"
                      stroke-linejoin="round"
                    >
                      <path d="M6 18L18 6M6 6l12 12" />
                    </svg>
                  </button>
                </div>
                <span class="file-manual-error" role="alert" hidden></span>
              </div>

              <%!-- zh_CN: Attach file → "附加文件" --%>
              <button
                type="button"
                id="objective-file-button"
                phx-hook="FilePicker"
                data-picker-id="objective_file"
                aria-label={gettext("Attach file")}
                title={gettext("Attach file")}
                class="btn btn-ghost btn-sm btn-square absolute top-2 right-2 bg-base-100/80 z-10"
              >
                <.icon name="hero-paper-clip" class="size-4" />
              </button>
            <% end %>

            <%!-- Controls row — the card's LAST element, in normal document flow
                 (never position: fixed). DOM order AND visual order are
                 identical in both layouts: agent + mode (order-1) | Launch
                 (order-2, centered via mx-auto) | model (order-3). The Launch
                 button carries mx-auto so it stays centered even when the
                 agent/model selects are absent (2-item row: space-between
                 would otherwise push it to the right edge). The row is
                 guaranteed ONE LINE (flex-nowrap — never wraps): the selects
                 use min-w-0 + truncate, so long labels (agent names, mode
                 names, model profile ids) are clipped with an ellipsis
                 instead of forcing the row wider than its container. --%>

            <%!-- The launch panel renders ONLY when a project is open
                 (@disabled == false). When no project is active the row is
                 hidden entirely — the empty state shows just the faded
                 textarea (wrapper opacity) + the centered hint overlay. --%>
            <%= unless @disabled do %>
            <div class="input-controls flex-nowrap">
              <!-- Mode switch -->
              <select
                name="mode"
                phx-change="task_change"
                class="select select-ghost select-md text-base bg-transparent font-medium focus:outline-none focus:ring-2 focus:ring-primary/20 min-w-0 truncate order-1"
                title={mode_description(@mode)}
              >
                <option value="genesis_existing" selected={@mode == "genesis_existing"}>
                  <%!-- zh_CN: Initialize existing project → "初始化已有项目" --%>
                  {gettext("Initialize existing project")}
                </option>
                <option value="genesis_new" selected={@mode == "genesis_new"}>
                  <%!-- zh_CN: Create new project → "新建空白项目" --%>
                  {gettext("Create new project")}
                </option>
                <option value="evolve_simple" selected={@mode == "evolve_simple"}>
                  <%!-- zh_CN: Evolve existing project → "演进已有项目" --%>
                  {gettext("Evolve existing project")}
                </option>
                <option value="custom_agent" selected={@mode == "custom_agent"}>
                  <%!-- zh_CN: Custom Agent → "自定义智能体"（用户自定义的根智能体） --%>
                  {gettext("Custom Agent")}
                </option>
              </select>

              <%!-- Custom agent select — rendered only when custom agents
                   exist in agents.toml. "Auto (recommended)" (empty value)
                   lets the runtime spawn its default root agent; a custom
                   agent id is threaded as the task's :agent opt. In Custom
                   Agent mode the Auto option is hidden (an agent MUST be
                   chosen — the server auto-selects the first one on mode
                   switch and re-validates on submit). --%>
              <%= if @custom_agents != [] do %>
                <select
                  name="agent"
                  phx-change="select_agent"
                  class="select select-ghost select-md text-base bg-transparent font-medium focus:outline-none focus:ring-2 focus:ring-primary/20 min-w-0 truncate order-1"
                >
                  <%= if @mode != "custom_agent" do %>
                    <%!-- zh_CN: Auto → "自动"（推荐：由运行时选择默认智能体） --%>
                    <option value="" selected={@selected_agent_id in [nil, ""]}>
                      {gettext("Auto (recommended)")}
                    </option>
                  <% end %>
                  <%= for agent <- @custom_agents do %>
                    <option
                      value={agent_attr(agent, :id)}
                      selected={@selected_agent_id == agent_attr(agent, :id)}
                    >
                      {agent_attr(agent, :name)}
                    </option>
                  <% end %>
                </select>
              <% end %>

              <!-- Launch button — the focal point, centered in BOTH
                   layouts (order-2 + mx-auto; works with or without the
                   model select). data-mode drives the per-mode hover ring
                   color; data-resume drives the resume-ring variant (lighter
                   green when a resume task id is set — evolve only). Both
                   keyed in CSS in assets/css/app.css. -->
              <button
                type="submit"
                class={["btn btn-primary gap-2 px-5 order-2 mx-auto"]}
                data-mode={@mode}
                data-resume={String.trim(@resume_from) != ""}
                disabled={@disabled}
              >
                <.icon name="hero-rocket-launch" class="size-4" /> {gettext("Launch")}
              </button>

              <!-- Model switch -->
              <%= if @model_profiles != [] do %>
                <select
                  name="model_id"
                  phx-change="select_model"
                  class="select select-ghost select-md text-base bg-transparent font-medium focus:outline-none focus:ring-2 focus:ring-primary/20 min-w-0 truncate order-3"
                >
                  <%!-- "Auto (by rules)" is offered when a model-selection
                       script is configured (show_auto_model_option) — and
                       ALWAYS when the current selection is nil/"" so the
                       select is never visually empty. Choosing it sets
                       neither :model_id nor :model_id_locked, leaving the
                       runtime script (or default model) to decide. --%>
                  <%= if @show_auto_model_option or @selected_model_id in [nil, ""] do %>
                    <%!-- zh_CN: Auto → "自动"（按模型选择规则/脚本自动选择模型） --%>
                    <option value="" selected={@selected_model_id in [nil, ""]}>
                      {gettext("Auto (by rules)")}
                    </option>
                  <% end %>
                  <%= for profile <- @model_profiles do %>
                    <option value={profile.id} selected={@selected_model_id == profile.id}>
                      {profile.id}
                    </option>
                  <% end %>
                </select>
              <% end %>
            </div>

            <%!-- Custom Agent mode hint — a single-line explanation under the
                 controls row (the row stays the card's last element only for
                 the OTHER modes; in custom mode the hint appends below it,
                 still inside .input-card normal flow). Two variants: with
                 agents defined it explains the mode; with none it points to
                 the Settings → Agents editor. The server also guards submit
                 (task_submit) so a missing agent can never launch a task. --%>
            <%= if @mode == "custom_agent" do %>
              <%= if @custom_agents == [] do %>
                <p class="px-4 pb-3 text-xs text-warning/80 flex items-center gap-1.5">
                  <.icon name="hero-exclamation-triangle" class="size-3.5 shrink-0" />
                  <%!-- zh_CN: Custom Agent → "自定义智能体"（用户自定义的根智能体） --%>
                  {gettext(
                    "No custom agents defined. Add one in Settings → Agents to use Custom Agent mode."
                  )}
                </p>
              <% else %>
                <p class="px-4 pb-3 text-xs text-base-content/70 flex items-center gap-1.5">
                  <.icon name="hero-user-circle" class="size-3.5 shrink-0" />
                  <%!-- zh_CN: Custom Agent → "自定义智能体", root agent → "根智能体" --%>
                  {gettext("Runs the selected custom agent as the root agent of an evolution task.")}
                </p>
              <% end %>
            <% end %>
            <% end %>
          </div>

          <!-- Welcome hint overlay when disabled (no project active) -->
          <%= if @disabled do %>
            <div class="absolute inset-0 flex items-center justify-center pointer-events-none z-10">
              <div class="text-center">
                <div class="animate-float">
                  <.icon name="hero-sparkles" class="size-6 mx-auto mb-1 text-base-content/40" />
                </div>
                <p class="text-sm font-medium text-base-content/70">
                  {gettext("Open a project to get started")}
                </p>
                <p class="text-xs text-base-content/60">
                  {gettext("Use the project picker in the top bar to open or create one.")}
                </p>
              </div>
            </div>
          <% end %>
        </div>
      </div>
    </.form>
    """
  end

  # Defensive accessor for custom-agent definition maps: they come from
  # agents.toml (atom-keyed via EvoGit.CustomAgents.list/0) but callers may
  # pass string-keyed maps too, so both key forms are accepted.
  defp agent_attr(agent, key) do
    Map.get(agent, key) || Map.get(agent, Atom.to_string(key))
  end

  # Custom Agent mode is evolve-family: it runs an :evolve task (existing
  # repo, reviewable result) with the chosen custom agent as the root agent.
  # All evolve-gated UI (placeholder, advanced options) must include it.
  defp evolve_family_mode?(mode) do
    String.starts_with?(mode, "evolve") or mode == "custom_agent"
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
  #   * Starting Node / Starting Commit / Resume from — evolve-family modes
  #     only (evolve + custom agent).
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

      <%!-- Evolve-family specific advanced options (evolve + custom agent) --%>
      <%= if evolve_family_mode?(@mode) do %>
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
          <span class="text-xs text-base-content/70">
            {gettext("Collect per-agent metadata for review")}
          </span>
        </div>
      </label>
    </div>
    """
  end

  # ---------------------------------------------------------------------------
  # advanced_options/1 — (legacy) Extracted Advanced Options panel
  # (evolve-family modes: evolve + custom agent)
  #
  # Kept for backwards compatibility. The content now lives in task_options_tab/1.
  # Rendered OUTSIDE the task_form's <.form> element in projects_live.ex,
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
    <%= if evolve_family_mode?(@mode) do %>
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
end
