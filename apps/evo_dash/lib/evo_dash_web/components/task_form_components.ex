defmodule EvoDashWeb.TaskFormComponents do
  @moduledoc """
  Task form component for the dashboard — a single-card, two-layout
  "pageless editor".

  The shared composer surface is `.input-layout > .input-card`: its editor
  zone holds the textarea and its final toolbar zone is `.input-controls`.
  The layout is server-seeded via `layout_for/1` and client-driven by the
  AdaptiveInput JS hook, which adds a height-based trigger to the server
  thresholds. The hook
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
      max-height cap (~16 wrapped lines) — load-bearing for the AdaptiveInput
      hook's flip-to-expanded decision.
    * Layout B (`data-layout="expanded"`) — the card and its editor zone fill
      the available height. The textarea scrolls internally and the in-flow
      `.input-controls` toolbar stays at the bottom.

  Both layouts share the same toolbar: attach-kind dropdown (text / image /
  audio) and mode+speed capsule on the left; optional custom-agent select,
  model capsule and icon-only launch button on the right. CSS owns the
  surface styling and layout geometry.

  There is NO per-keystroke server round trip: the textarea sends no
  `phx-change` event. The AdaptiveInput JS hook autogrows the textarea AND
  switches `data-layout` between compact/expanded client-side, flipping to
  expanded when the content would exceed the compact max-height cap (~16
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

  The labelled Task Options section sits below the editor, with its fields
  associated with `task-form`. A page that places the section separately sets
  `show_options={false}` and renders `task_options_tab/1` once instead. Project
  settings belong to the page.

  Passing `provider_profiles`, `model_selections`, or a non-empty `model_spec`
  moves the shared `LLMSelectionComponents.llm_selection/1` capsule INSIDE the
  toolbar's right-aligned cluster (before the send button). Its event attrs
  (`provider_event`, `model_event`, `reasoning_event`) pass through unchanged.
  Reasoning is a discrete zero-based stop index; callers resolve it through
  `LLMSelectionComponents.resolve_reasoning_effort/3` before storing the spec.
  Mode, speed/quality and reasoning stay independent. When these new attrs are
  empty, the legacy `model_profiles` / `selected_model_id` toolbar select
  remains unchanged.
  """

  # zh_CN: Evolution → "演进", Prompt → "提示词", Commit → "提交", Branch → "分支"

  use EvoDashWeb, :html

  import EvoDashWeb.ComposerComponents, only: [composer: 1, composer_surface: 1]
  alias EvoDashWeb.TaskOptionsComponents

  @short_objective_threshold 1200

  @doc """
  Layout decision for the task form: `:compact` (Layout A — unified box) vs
  `:expanded` (Layout B — split). Threshold: objective length > 1200 graphemes
  OR > 32 explicit lines.

  This seeds the initial `data-layout` attribute at render time (SSR first
  paint + after restore/submit) — after that the client is authoritative.
  While typing, the AdaptiveInput JS hook switches the layout client-side —
  flipping to expanded when the content would exceed the compact max-height
  cap (~16 wrapped lines) OR on these thresholds, with hysteresis when
  flipping back — and it also re-asserts the computed layout
  whenever the server re-seeds the attribute from its possibly-stale
  `@task_prompt` (a MutationObserver on `.input-layout` catches any server
  re-render, e.g. toggling mode/model; it converges immediately since the
  hook only writes the attribute when the computed value differs, with zero
  network events) — there is no per-keystroke server event.
  """
  def layout_for(prompt) when is_binary(prompt) do
    if String.length(prompt) > @short_objective_threshold or line_count(prompt) > 32,
      do: :expanded,
      else: :compact
  end

  def layout_for(_), do: :compact

  defp line_count(prompt), do: prompt |> String.split("\n") |> length()

  # ---------------------------------------------------------------------------
  # task_form/1 — Single-card objective editor (textarea + in-flow bottom toolbar)
  #
  # The <.form id="task-form"> wraps the whole card: the textarea AND the
  # bottom toolbar (attach "+" | mode+speed capsule (LEFT), then (agent) |
  # model capsule | send button) as the card's last element. The
  # compact/expanded layout is server-seeded at render via layout_for/1
  # (data-layout) and client-driven by the AdaptiveInput hook (adds a
  # height-based trigger — flips to expanded when the content exceeds the
  # compact max-height cap ~16 wrapped lines or the char/line thresholds,
  # with hysteresis): it re-asserts the layout while typing AND whenever the
  # server re-seeds the attribute
  # from its possibly-stale @task_prompt (a MutationObserver on .input-layout
  # catches any server re-render, e.g. toggling mode/model, converging with
  # no loop and zero network events). Options stay outside the form element,
  # so submit-time inputs carry form="task-form" to associate with it.
  # ---------------------------------------------------------------------------

  attr(:prompt, :string, default: "")
  attr(:mode, :string, default: "genesis_new")
  attr(:node_path, :string, default: "")
  attr(:starting_commit, :string, default: "")
  attr(:resume_from, :string, default: "")
  attr(:disabled, :boolean, default: false)
  attr(:launch_disabled, :boolean, default: false)
  attr(:show_options, :boolean, default: true, doc: "Render built-in task options.")
  attr(:archive, :boolean, default: false)
  attr(:persist_agent_state?, :boolean, default: true)
  attr(:provider_profiles, :list, default: [])
  attr(:model_selections, :list, default: [])
  attr(:model_spec, :map, default: %{})
  attr(:provider_event, :string, default: "select_provider_profile")
  attr(:model_event, :string, default: "select_model")
  attr(:reasoning_event, :string, default: "select_reasoning_effort")
  attr(:model_profiles, :list, default: [])
  attr(:selected_model_id, :string, default: nil)
  attr(:custom_agents, :list, default: [])
  attr(:selected_agent_id, :string, default: nil)
  attr(:show_auto_model_option, :boolean, default: false)
  attr(:build_systems, :list, default: [])
  attr(:selected_build_system, :string, default: nil)
  attr(:staged_attachments, :list, default: [])
  attr(:quality_level, :string, default: "balanced")

  slot(:controls)

  def task_form(assigns) do
    ~H"""
    <.composer kind="task" class="w-full flex-1 flex flex-col min-h-0">
      {task_editor(assigns)}
      <.task_options_tab
        :if={@show_options && !@disabled}
        class="mx-auto mt-3 w-full max-w-3xl shrink-0 px-4"
        mode={@mode}
        node_path={@node_path}
        starting_commit={@starting_commit}
        resume_from={@resume_from}
        archive={@archive}
        persist_agent_state?={@persist_agent_state?}
        build_systems={@build_systems}
        selected_build_system={@selected_build_system}
      />
    </.composer>
    """
  end

  defp task_editor(assigns) do
    assigns =
      assign(
        assigns,
        :use_llm_selection?,
        assigns.provider_profiles != [] or assigns.model_selections != [] or
          assigns.model_spec not in [nil, %{}]
      )

    ~H"""
    <.form
      for={%{}}
      id="task-form"
      phx-submit="task_submit"
      class="w-full flex-1 flex flex-col min-h-0 gap-0"
    >
      <%!-- Hidden mode field — the form's ONLY carrier of the combined UI mode
           string ("genesis_new" | "genesis_existing" | "evolve_simple" |
           "custom_agent"). The old <select name="mode" phx-change="task_change">
           was replaced by the fused mode+speed capsule's Layer-2 buttons, which
           render OUTSIDE any input, so without this field the submit payload has
           no "mode" key and ProjectsLive's strict
           handle_event("task_submit", %{"prompt" => _, "mode" => _}) clause
           raises FunctionClauseError. The value always mirrors the server-side
           truth (@mode == @task_mode, moved only by the task_change handler).
           Quality level is NOT a form field — it comes from the
           :quality_level assign through LaunchOptions. --%>
      <input type="hidden" name="mode" value={@mode} />
      <div class={[
        "relative flex-1 flex flex-col min-h-0 transition-opacity",
        @disabled && "opacity-40 pointer-events-none select-none"
      ]}>
        <% layout = layout_for(@prompt) %>
        <% placeholder = task_placeholder(@disabled, @mode) %>
        <!-- Single-card, two-layout objective editor.
             data-layout is server-seeded at render time via layout_for/1
             (threshold: @short_objective_threshold chars or 32+ lines) and
             client-driven by the AdaptiveInput JS hook (flips to expanded
             when the content exceeds the compact max-height cap ~16 wrapped
             lines or the char/line thresholds, with hysteresis — no
             per-keystroke server event): the hook re-asserts the computed
             layout while typing AND whenever the server
             re-seeds the attribute from its stale @task_prompt (a
             MutationObserver on .input-layout catches any server re-render,
             e.g. toggling mode/model, converging with no loop):
               "compact"  → Layout A — unified box: the bottom toolbar is the
                            card's last line (attach dropdown | mode+speed capsule |
                            model capsule | send).
               "expanded" → Layout B — large objective area with an in-flow
                            bottom toolbar (attach dropdown | mode+speed capsule |
                            model capsule | send).
             Both layouts share the same bottom toolbar — the attach-kind
             dropdown (text / image / audio, bottom-left) and the fused
             mode+speed capsule sit on the left → (custom-agent select) →
             model capsule → circular icon-only send button (far right); only
             the textarea size differs.

             PLACEHOLDER CHANNEL — the textarea is phx-update="ignore" (the
             client owns the typed value), so LiveView only re-merges its
             data-* attributes (dom.ts mergeAttrs keeps an ignored element's
             data-* attributes) and updated() never fires for it. The
             SSR-computed placeholder attribute is therefore a first-paint
             value only — it is never refreshed (the page usually first
             renders with no active project, then the mode/project changes).
             data-placeholder={placeholder} is the LIVE channel: LiveView
             re-merges it through phx-update="ignore" and the AdaptiveInput
             hook mirrors it onto el.placeholder (an attributeFilter observer
             on data-placeholder, plus _apply()), so the hint follows the mode. -->
        <div
          class="input-layout mx-auto w-full max-w-3xl px-4 flex-1 flex flex-col min-h-0"
          data-layout={layout}
          id="input-layout"
        >
          <.composer_surface class="input-card" toolbar_class="input-controls flex-nowrap">
            <:editor>
              <textarea
                name="prompt"
                id="prompt"
                phx-update="ignore"
                phx-hook="AdaptiveInput"
                class="input-prompt text-base"
                placeholder={placeholder}
                data-placeholder={placeholder}
              ><%= @prompt %></textarea>
            </:editor>

            <:before_toolbar :if={!@disabled}>
              <p
                :if={@mode == "custom_agent"}
                class={[
                  "workbench-composer-hint flex items-center gap-1.5 text-xs",
                  if(@custom_agents == [], do: "text-warning", else: "text-base-content/70")
                ]}
              >
                <%= if @custom_agents == [] do %>
                  <.icon name="hero-exclamation-triangle" class="size-3.5 shrink-0" />
                  <%!-- zh_CN: Custom Agent → "自定义智能体"（用户自定义的根智能体） --%>
                  {gettext(
                    "No custom agents defined. Add one in Settings → Agents to use Custom Agent mode."
                  )}
                <% else %>
                  <.icon name="hero-user-circle" class="size-3.5 shrink-0" />
                  <%!-- zh_CN: Custom Agent → "自定义智能体", root agent → "根智能体" --%>
                  {gettext("Runs the selected custom agent as the root agent of an evolution task.")}
                <% end %>
              </p>

              <%!-- Staged media attachments — image/audio files picked via the
                   attach-kind dropdown above are staged server-side by
                   ProjectsLive into the @staged_attachments assign: a list of
                   STRING-keyed maps %{"type" => "image"|"audio", "name" =>
                   basename, "media_type" => IANA string, "data" => RAW binary}.
                   This chip row renders METADATA ONLY (kind + basename + remove
                   button) — the "data" key is a raw server-side binary and is
                   NEVER rendered nor encoded into any attribute/event. The row
                   is a normal (non-phx-update="ignore") re-render region so
                   staging appears immediately, and it is a sibling ABOVE
                   .input-controls — it never disturbs the toolbar's
                   first-child/DOM-order contract. Removal is
                   remove_staged_attachment by integer index (phx-value-index).
                   The assign is optional (the component renders without it) —
                   normalized via Map.get before reading. --%>
              <% staged_attachments = Map.get(assigns, :staged_attachments) || [] %>
              <%= if staged_attachments != [] do %>
                <%!-- The `:if` sits ON this node, so it is the node the patch
                     removes — which is exactly where LiveView runs `phx-remove`
                     (a descendant's attribute never fires). The entrance class
                     `motion-panel-open` (fill: both) keeps the row at its final
                     frame forever, and an animation value outranks a class
                     change, so it is removed first; otherwise the exit fade
                     below would have nothing to animate. --%>
                <div
                  id="staged-attachments"
                  class="motion-panel motion-panel-slide motion-panel-open flex flex-wrap items-center gap-1.5 px-4 pt-1 pb-0 shrink-0"
                  phx-remove={
                    JS.remove_class("motion-panel-open motion-panel-slide")
                    |> JS.hide(
                      transition: {"motion-exit-lift", "motion-exit-visible", "motion-exit-hidden"}
                    )
                  }
                >
                  <%= for {att, index} <- Enum.with_index(staged_attachments) do %>
                    <div
                      class="flex items-center gap-1.5 max-w-full rounded-lg border border-base-300 bg-base-200/70 py-0.5 pl-2 pr-0.5"
                      title={attachment_attr(att, :name)}
                    >
                      <span class="shrink-0 text-2xs font-semibold uppercase tracking-wide text-base-content/60">
                        {staged_kind_label(attachment_attr(att, :type))}
                      </span>
                      <span class="min-w-0 max-w-[12rem] truncate text-xs font-medium text-base-content/80">
                        {attachment_attr(att, :name)}
                      </span>
                      <%!-- zh_CN: 移除暂存的附件 → "移除附件" --%>
                      <button
                        type="button"
                        phx-click="remove_staged_attachment"
                        phx-value-index={index}
                        aria-label={gettext("Remove attachment")}
                        title={gettext("Remove attachment")}
                        class="btn btn-ghost btn-xs btn-square rounded-md shrink-0 hover:bg-error/10 hover:text-error"
                      >
                        <.icon name="hero-x-mark" class="size-3.5" />
                      </button>
                    </div>
                  <% end %>
                </div>
              <% end %>
            </:before_toolbar>

            <:toolbar :if={!@disabled}>
              <%!-- Attach-kind dropdown — bottom-LEFT of the toolbar. A
                     native <details class="dropdown"> whose <summary> is the
                     visual "+" trigger (id objective-file-button — stable
                     test/UI marker). The FilePicker JS hook owns the whole
                     control (phx-hook lives on the <details>; it click-delegates
                     on the [data-picker-kind] menu items — NO phx-click and NO
                     submit anywhere in the menu, every button is
                     type="button"): on pick it pushes a "file_pick" event with
                     the item's data-picker-id (text = objective_file — the
                     EXISTING text pipeline, unchanged: ProjectsLive runs the
                     native file dialog and appends the file's text to the
                     objective; image = objective_file_image; audio =
                     objective_file_audio — both staged server-side into
                     @staged_attachments) and closes the details. The <summary>
                     cannot be a <button> — it is the native details toggle
                     (type="button" is meaningless on a summary); the old
                     data-picker-id="objective_file" on the trigger is GONE
                     (the hook derives the per-kind ids from the menu items).
                     dropdown-top opens the menu UPWARD so .input-card's
                     overflow containment (expanded layout) never clips it. --%>
              <%!-- zh_CN: Attach file → "附加文件" --%>
              <details
                id="objective-file-attach"
                class="dropdown dropdown-top"
                phx-hook="FilePicker"
              >
                <summary
                  id="objective-file-button"
                  aria-label={gettext("Attach file")}
                  title={gettext("Attach file")}
                  class="btn btn-ghost btn-sm btn-square shrink-0"
                >
                  <.icon name="hero-plus" class="size-4" />
                </summary>
                <ul class="menu menu-sm dropdown-content z-50 mb-2 p-1 shadow-lg bg-base-100 rounded-lg w-44 border border-base-300">
                  <li>
                    <button
                      type="button"
                      data-picker-kind="text"
                      data-picker-id="objective_file"
                    >
                      <.icon name="hero-document-text" class="size-4" />
                      <%!-- zh_CN: Text / PDF → "文字/PDF 文档类附件" --%>
                      {gettext("Text / PDF")}
                    </button>
                  </li>
                  <li>
                    <button
                      type="button"
                      data-picker-kind="image"
                      data-picker-id="objective_file_image"
                    >
                      <.icon name="hero-photo" class="size-4" />
                      <%!-- zh_CN: Image → "图片"（图片类附件，服务端暂存） --%>
                      {gettext("Image")}
                    </button>
                  </li>
                  <li>
                    <button
                      type="button"
                      data-picker-kind="audio"
                      data-picker-id="objective_file_audio"
                    >
                      <.icon name="hero-musical-note" class="size-4" />
                      <%!-- zh_CN: Audio → "音频"（音频类附件，服务端暂存） --%>
                      {gettext("Audio")}
                    </button>
                  </li>
                </ul>
              </details>

              <%!-- Manual path fallback for the attach dropdown's TEXT kind —
                     rendered hidden; the FilePicker JS hook reveals it when the
                     native picker is unavailable (headless server, remote node,
                     picker disabled) and submits the typed path via the
                     "file_pick_manual" event. Anchored just above the toolbar's
                     left side, near the "+" trigger (position: absolute in
                     app.css — the exact pixel offset lives there, not in
                     markup).
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

              <%!-- Fused mode + speed/quality capsule — a ChatGPT-style
                     collapsed pill sitting at the toolbar's LEFT, right after
                     the attach "+" trigger (its `.file-manual` sibling is
                     position:absolute and takes no flex space). The pill shows
                     the SHORT mode label (mode_label/1 — "New project" /
                     "Init existing" / "Evolve" / "Custom") as the main value
                     and the current speed/quality label as the secondary
                     value; the LONG sentence (mode_description/1) is only the
                     trigger's `title` tooltip, because it overflowed the
                     one-line toolbar. The pill then expands UPWARD
                     (dropdown-top, so .input-card's overflow containment never
                     clips it) into a two-layer panel: Layer 1 is the
                     speed/quality hero (three discrete .capsule-stop buttons on
                     ONE non-wrapping line), and its .capsule-subrow entry
                     ("Mode · <short label>") opens Layer 2 (the four mode
                     choices). `phx-hook="CapsulePanel"` adds outside-click /
                     Escape close and the panel's open/close animation, while
                     the nested `.capsule-sub` keeps its native <details>
                     toggling (the hook never intercepts it) and only gains an
                     entrance animation. Every button is type="button" (NEVER
                     submit — the capsule lives inside <form id="task-form">) and
                     fires phx-click="select_quality_level" (phx-value-level
                     "fast"|"balanced"|"high_quality") or phx-click="task_change"
                     (phx-value-mode "<value>"). The quality value is threaded to
                     the task opt :quality_level (STRING); mode/quality and the
                     model capsule's reasoning stay independent. --%>
              <details
                id="mode-speed-capsule"
                phx-hook="CapsulePanel"
                class="capsule dropdown dropdown-top min-w-0 shrink-0"
              >
                <summary
                  class="capsule-trigger flex items-center gap-1.5 rounded-full border border-base-300 bg-base-100 px-3 py-1.5 text-sm cursor-pointer select-none list-none [&::-webkit-details-marker]:hidden"
                  title={mode_description(@mode)}
                >
                  <span class="capsule-main min-w-0 max-w-[9rem] truncate font-medium text-base-content">
                    {mode_label(@mode)}
                  </span>
                  <span class="capsule-secondary shrink-0 text-xs text-base-content/60">
                    {quality_label(@quality_level)}
                  </span>
                  <span class="capsule-chevron shrink-0 text-base-content/50" aria-hidden="true">
                    <.icon name="hero-chevron-down" class="size-3.5" />
                  </span>
                </summary>

                <div class="capsule-panel dropdown-content z-50 mb-2 w-max min-w-72 max-w-[92vw] rounded-2xl border border-base-300 bg-base-100 p-2 shadow-lg">
                  <%!-- Layer 1: speed ↔ quality hero (discrete stops) — ONE
                         line (flex-nowrap + whitespace-nowrap/flex-shrink-0 on
                         .capsule-stop in app.css): the three labels must never
                         wrap into a stack. --%>
                  <div
                    class="capsule-stops flex flex-nowrap gap-1"
                    role="group"
                    aria-label={gettext("Speed / quality trade-off")}
                  >
                    <%!-- zh_CN: 速度优先（信任上下文、少做校验） --%>
                    <button
                      type="button"
                      id="quality-level-fast"
                      phx-click="select_quality_level"
                      phx-value-level="fast"
                      aria-pressed={to_string(@quality_level == "fast")}
                      disabled={@disabled}
                      class={[
                        "capsule-stop rounded-lg px-2.5 py-1.5 text-sm font-medium",
                        @quality_level == "fast" && "capsule-stop-active"
                      ]}
                      title={gettext("Prioritise speed — trust the context, run fewer checks")}
                    >
                      <.icon name="hero-bolt" class="size-3.5" />
                      {gettext("Fast")}
                    </button>
                    <%!-- zh_CN: 均衡（默认，速度与正确性折中） --%>
                    <button
                      type="button"
                      id="quality-level-balanced"
                      phx-click="select_quality_level"
                      phx-value-level="balanced"
                      aria-pressed={to_string(@quality_level == "balanced")}
                      disabled={@disabled}
                      class={[
                        "capsule-stop rounded-lg px-2.5 py-1.5 text-sm font-medium",
                        @quality_level == "balanced" && "capsule-stop-active"
                      ]}
                      title={
                        gettext("Balanced — the default trade-off between speed and correctness")
                      }
                    >
                      <.icon name="hero-scale" class="size-3.5" />
                      {gettext("Balanced")}
                    </button>
                    <%!-- zh_CN: 高质量（正确性优先，多验证、跑测试/编译） --%>
                    <button
                      type="button"
                      id="quality-level-high_quality"
                      phx-click="select_quality_level"
                      phx-value-level="high_quality"
                      aria-pressed={to_string(@quality_level == "high_quality")}
                      disabled={@disabled}
                      class={[
                        "capsule-stop rounded-lg px-2.5 py-1.5 text-sm font-medium",
                        @quality_level == "high_quality" && "capsule-stop-active"
                      ]}
                      title={gettext("Prioritise correctness — verify more, run tests and compile")}
                    >
                      <.icon name="hero-check-badge" class="size-3.5" />
                      {gettext("High quality")}
                    </button>
                  </div>

                  <%!-- Layer-1 → Layer-2 entry: SHORT mode label + right arrow
                         (the long description sentence lives in the trigger's
                         title tooltip, never inline here). --%>
                  <details class="capsule-sub">
                    <summary class="capsule-subrow flex items-center gap-1.5 rounded-lg px-2 py-1.5 text-sm cursor-pointer select-none list-none hover:bg-base-200 [&::-webkit-details-marker]:hidden">
                      <span class="capsule-subrow-label min-w-0 flex-1 truncate text-base-content/80">
                        {gettext("Mode")} · {mode_label(@mode)}
                      </span>
                      <span
                        class="capsule-subrow-arrow shrink-0 text-base-content/50"
                        aria-hidden="true"
                      >
                        <.icon name="hero-chevron-right" class="size-4" />
                      </span>
                    </summary>

                    <div
                      class="capsule-list mt-1 space-y-0.5"
                      role="listbox"
                      aria-label={gettext("Mode")}
                    >
                      <button
                        type="button"
                        id="mode-option-genesis_existing"
                        phx-click="task_change"
                        phx-value-mode="genesis_existing"
                        disabled={@disabled}
                        class={[
                          "capsule-item flex w-full items-center gap-2 rounded-lg px-2 py-1.5 text-sm text-left",
                          @mode == "genesis_existing" && "capsule-item-active"
                        ]}
                      >
                        <span class="capsule-item-label min-w-0 flex-1 truncate">
                          <%!-- zh_CN: Initialize existing project → "初始化已有项目" --%>
                          {gettext("Initialize existing project")}
                        </span>
                        <span
                          :if={@mode == "genesis_existing"}
                          class="capsule-item-check shrink-0 text-primary-standalone"
                          aria-hidden="true"
                        >
                          <.icon name="hero-check" class="size-4" />
                        </span>
                      </button>
                      <button
                        type="button"
                        id="mode-option-genesis_new"
                        phx-click="task_change"
                        phx-value-mode="genesis_new"
                        disabled={@disabled}
                        class={[
                          "capsule-item flex w-full items-center gap-2 rounded-lg px-2 py-1.5 text-sm text-left",
                          @mode == "genesis_new" && "capsule-item-active"
                        ]}
                      >
                        <span class="capsule-item-label min-w-0 flex-1 truncate">
                          <%!-- zh_CN: Create new project → "新建空白项目" --%>
                          {gettext("Create new project")}
                        </span>
                        <span
                          :if={@mode == "genesis_new"}
                          class="capsule-item-check shrink-0 text-primary-standalone"
                          aria-hidden="true"
                        >
                          <.icon name="hero-check" class="size-4" />
                        </span>
                      </button>
                      <button
                        type="button"
                        id="mode-option-evolve_simple"
                        phx-click="task_change"
                        phx-value-mode="evolve_simple"
                        disabled={@disabled}
                        class={[
                          "capsule-item flex w-full items-center gap-2 rounded-lg px-2 py-1.5 text-sm text-left",
                          @mode == "evolve_simple" && "capsule-item-active"
                        ]}
                      >
                        <span class="capsule-item-label min-w-0 flex-1 truncate">
                          <%!-- zh_CN: Evolve existing project → "演进已有项目" --%>
                          {gettext("Evolve existing project")}
                        </span>
                        <span
                          :if={@mode == "evolve_simple"}
                          class="capsule-item-check shrink-0 text-primary-standalone"
                          aria-hidden="true"
                        >
                          <.icon name="hero-check" class="size-4" />
                        </span>
                      </button>
                      <button
                        type="button"
                        id="mode-option-custom_agent"
                        phx-click="task_change"
                        phx-value-mode="custom_agent"
                        disabled={@disabled}
                        class={[
                          "capsule-item flex w-full items-center gap-2 rounded-lg px-2 py-1.5 text-sm text-left",
                          @mode == "custom_agent" && "capsule-item-active"
                        ]}
                      >
                        <span class="capsule-item-label min-w-0 flex-1 truncate">
                          <%!-- zh_CN: Custom Agent → "自定义智能体"（用户自定义的根智能体） --%>
                          {gettext("Custom Agent")}
                        </span>
                        <span
                          :if={@mode == "custom_agent"}
                          class="capsule-item-check shrink-0 text-primary-standalone"
                          aria-hidden="true"
                        >
                          <.icon name="hero-check" class="size-4" />
                        </span>
                      </button>
                    </div>
                  </details>
                </div>
              </details>

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
                  class={[
                    "select select-ghost select-sm text-sm bg-transparent font-medium min-w-0 truncate max-w-[10rem]",
                    not @use_llm_selection? && "ml-auto"
                  ]}
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

              <%!-- Shared model capsule (fused model + reasoning picker) — the
                     RIGHT cluster's model control when @use_llm_selection? is
                     true. It sits AFTER the custom-agent select (if present)
                     and BEFORE the send button, and carries the row's ml-auto
                     (the first element of the right cluster owns the auto
                     margin). The own-row picker above the toolbar is gone.
                     Its provider-profile row is a ChatGPT-style drill-down
                     (the same panel switches between the model view and the
                     provider list) rather than a <select>, and it needs no
                     form owner: every control emits phx-click/phx-value
                     events, so no `form` association is threaded. --%>
              <EvoDashWeb.LLMSelectionComponents.llm_selection
                :if={@use_llm_selection?}
                id="task-llm-selection"
                provider_profiles={@provider_profiles}
                model_selections={@model_selections}
                model_spec={@model_spec}
                provider_event={@provider_event}
                model_event={@model_event}
                reasoning_event={@reasoning_event}
                show_auto_option={@show_auto_model_option}
                compact
                disabled={@disabled}
                class={
                  if right_cluster_ml_auto?(@use_llm_selection?),
                    do: "mx-1 ml-auto",
                    else: "mx-1"
                }
              />

              <!-- Legacy model switch -->
              <%= if not @use_llm_selection? and @model_profiles != [] do %>
                <select
                  name="model_id"
                  phx-change="select_model"
                  class={[
                    "select select-ghost select-sm text-sm bg-transparent font-medium min-w-0 truncate max-w-[11rem]",
                    @custom_agents == [] && "ml-auto"
                  ]}
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

              <div class={[
                "flex items-center gap-1 shrink-0",
                !@use_llm_selection? && @custom_agents == [] && @model_profiles == [] && "ml-auto"
              ]}>
                {render_slot(@controls)}
                <button
                  type="submit"
                  id="task-launch-button"
                  class="btn btn-primary btn-circle btn-sm shrink-0"
                  data-mode={@mode}
                  data-resume={String.trim(@resume_from) != ""}
                  disabled={@launch_disabled}
                  aria-label={gettext("Launch")}
                  title={gettext("Launch")}
                >
                  <.icon name="hero-arrow-up" class="size-4" />
                </button>
              </div>
            </:toolbar>
          </.composer_surface>

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

  # Defensive accessor for staged-attachment maps (STRING-keyed per the
  # @staged_attachments contract; atom keys tolerated for safety).
  defp attachment_attr(att, key) do
    Map.get(att, key) || Map.get(att, Atom.to_string(key))
  end

  # Kind label for a staged-attachment chip: "image"/"audio" map to gettext
  # labels (same msgids as the attach dropdown menu items); anything unknown
  # falls back to the raw type string — never a dynamic gettext call.
  defp staged_kind_label(type) when is_binary(type) do
    case type do
      "image" -> gettext("Image")
      "audio" -> gettext("Audio")
      _ -> type
    end
  end

  defp staged_kind_label(_), do: ""

  # Collapsed-pill secondary label for the fused mode+speed capsule: the three
  # speed/quality steps map to their short gettext labels; anything unknown
  # falls back to the default "Balanced" label.
  defp quality_label("fast"), do: gettext("Fast")
  defp quality_label("balanced"), do: gettext("Balanced")
  defp quality_label("high_quality"), do: gettext("High quality")
  defp quality_label(_), do: gettext("Balanced")

  # When the shared model capsule leads the right-aligned toolbar cluster, it
  # carries the row's ml-auto; the other cases put ml-auto on the custom-agent
  # or legacy model select instead (see the toolbar markup). Literal
  # passthrough keeps the call site readable:
  # right_cluster_ml_auto?(@use_llm_selection?).
  defp right_cluster_ml_auto?(use_llm_selection?), do: use_llm_selection?

  # Custom Agent mode is evolve-family: it runs an :evolve task (existing
  # repo, reviewable result) with the chosen custom agent as the root agent.
  # All evolve-gated UI (placeholder, advanced options) must include it.
  defp evolve_family_mode?(mode) do
    String.starts_with?(mode, "evolve") or mode == "custom_agent"
  end

  # The task-launch hint for the objective textarea, derived ONCE per render
  # and used for BOTH the SSR `placeholder` (first paint) and the live
  # `data-placeholder` channel the AdaptiveInput hook mirrors onto
  # el.placeholder — keeping one helper means the two can never drift.
  # @disabled (no project open) suppresses the hint entirely: the centered
  # welcome overlay is the only hint then.
  defp task_placeholder(true, _mode), do: ""

  defp task_placeholder(false, "genesis_existing") do
    gettext("Optional — leave empty and click Launch to initialize an existing codebase")
  end

  defp task_placeholder(false, mode) do
    if evolve_family_mode?(mode) do
      gettext("Describe what you want to change or improve...")
    else
      gettext("Describe the codebase you want to create...")
    end
  end

  # Options are a sibling of #task-form, with submit-time fields associated by
  # form="task-form". Only the persistence toggle updates an assign directly.

  attr(:mode, :string, default: "genesis_new")
  attr(:node_path, :string, default: "")
  attr(:starting_commit, :string, default: "")
  attr(:resume_from, :string, default: "")
  attr(:archive, :boolean, default: false)
  # Persist agent state (default ON) — server-assign-driven, see
  # persist_agent_state_toggle/1.
  attr(:persist_agent_state?, :boolean, default: true)
  attr(:build_systems, :list, default: [])
  attr(:selected_build_system, :string, default: nil)
  attr(:disabled, :boolean, default: false)
  attr(:class, :any, default: nil)

  def task_options_tab(assigns) do
    assigns
    |> assign(:advanced?, evolve_family_mode?(assigns.mode))
    |> TaskOptionsComponents.options()
  end

  attr(:persist_agent_state?, :boolean, default: true)

  # No name or form association: the launch path reads the server assign.
  def persist_agent_state_toggle(assigns),
    do: TaskOptionsComponents.persist_agent_state_toggle(assigns)
end
