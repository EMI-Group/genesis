defmodule EvoDashWeb.TaskFormComponents do
  @moduledoc """
  Task form component for the dashboard — a single-card, two-layout
  "pageless editor".

  One card contains the objective textarea AND a bottom toolbar
  (`.input-controls` — attach-kind dropdown | mode+speed fused capsule (LEFT),
  then a right-aligned cluster of (custom-agent select)? | model capsule |
  circular icon-only send button) as its last
  element. The
  layout is server-seeded at render time via `layout_for/1` and client-driven
  by the
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
      max-height cap (~16 wrapped lines) — load-bearing for the AdaptiveInput
      hook's flip-to-expanded decision.
    * Layout B (`data-layout="expanded"`) — the input card fills the available
      page height (flex column): `.input-card` is `flex: 1; min-height: 0;
      overflow: hidden`, the textarea is `flex: 1` with internal scrolling
      (`overflow-y: auto`) and NO max-height cap, and the in-flow
      `.input-controls` launch panel is pinned at the bottom of the card by
      flexbox — the card's overflow containment bounds the textarea on any
      viewport height.

  Both layouts share the same bottom toolbar (`.input-controls`) — the card's
  last element, ChatGPT/Gemini input-box style: the attach-kind dropdown
  (text / image / audio, bottom-left) and the fused mode+speed capsule sit on
  the LEFT, then the right-aligned cluster of (custom-agent select) → model
  capsule → circular icon-only send button (far right). Only the textarea size
  differs. The accent
  decorations (accent border-color, layered box-shadow glow, top-edge
  gradient) are defined on the base `.input-card` CSS rule and are shared by
  both layouts.

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

  The top bar (Zone 1) and the collapsible Project Settings / Advanced Options
  panels live OUTSIDE this component in the dashboard layout.

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

  def task_form(assigns) do
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
          <div class="input-card relative">
            <textarea
              name="prompt"
              id="prompt"
              phx-update="ignore"
              phx-hook="AdaptiveInput"
              class="input-prompt w-full text-base bg-transparent border-0 focus:outline-none resize-none placeholder:text-base-content/45 transition-colors"
              placeholder={placeholder}
              data-placeholder={placeholder}
            ><%= @prompt %></textarea>

            <%!-- Bottom toolbar (.input-controls) — the card's LAST element, in
                 normal document flow (never position: fixed). ChatGPT/Gemini
                 input-box style: ALL controls live in ONE toolbar row pinned to
                 the card's bottom — the ATTACH-KIND DROPDOWN (text / image /
                 audio; bottom-LEFT; a <details class="dropdown"> whose <summary>
                 is the visual "+" trigger — see below) and the fused
                 mode+speed capsule (#mode-speed-capsule, also bottom-LEFT,
                 right after "+"), then free space, then a RIGHT-ALIGNED
                 cluster: (custom-agent select) → model capsule → circular
                 icon-only send button (the cluster's LAST element = the row's
                 far right, no auto margin of its own). The row's auto-margin
                 lives on the FIRST element of the right cluster — the model
                 capsule's ml-auto when @use_llm_selection?, else the
                 custom-agent select's ml-auto, else the legacy model select's
                 ml-auto — absorbing the free space and packing the cluster at
                 the right edge with the uniform flex gap between members. DOM
                 order == visual order (no order-* overrides). The attach
                 dropdown, the mode+speed capsule and the hidden manual-fallback
                 panel are DIRECT children of the toolbar; .file-manual is
                 positioned absolutely just above the toolbar's left side, near
                 the "+" trigger (see app.css), so it never takes part in the
                 flex row. Both fused-capsule panels open UPWARD (daisyUI
                 dropdown-top) so .input-card's overflow containment (expanded
                 layout) never clips them below the card. The row is guaranteed
                 ONE LINE (flex-nowrap — never wraps): selects and capsules use
                 min-w-0 + truncate + max-w so long labels (agent names, mode
                 descriptions, model ids) are clipped with an ellipsis instead
                 of forcing the row wider than its container. Staged media
                 attachments (@staged_attachments) render as a chip row directly
                 ABOVE this toolbar, inside the card. --%>

            <%!-- The launch panel renders ONLY when a project is open
                 (@disabled == false). When no project is active the row is
                 hidden entirely — the textarea's task-launch hint is
                 suppressed too (task_placeholder/2 returns "" for @disabled,
                 so BOTH the SSR placeholder and the live data-placeholder are
                 empty), so the empty state shows just the faded textarea
                 (wrapper opacity) + the centered "Open a project to get
                 started" hint overlay. --%>
            <%= unless @disabled do %>
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
                <div
                  id="staged-attachments"
                  class="flex flex-wrap items-center gap-1.5 px-4 pt-1 pb-0 shrink-0"
                >
                  <%= for {att, index} <- Enum.with_index(staged_attachments) do %>
                    <div
                      class="flex items-center gap-1.5 max-w-full rounded-lg border border-base-300 bg-base-200/70 py-0.5 pl-2 pr-0.5"
                      title={attachment_attr(att, :name)}
                    >
                      <span class="shrink-0 text-xs font-semibold uppercase tracking-wide text-base-content/60">
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

              <div class="input-controls flex-nowrap">
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

                <!-- Launch button — circular icon-only send (ChatGPT/Gemini
                   style): the LAST element of the toolbar's right-aligned
                   cluster = the row's far right. It carries NO auto margin of
                   its own — the cluster is packed right by the FIRST element
                   of the right cluster's ml-auto (model capsule when
                   @use_llm_selection?, else custom-agent select, else legacy
                   model select). data-mode drives the per-mode hover ring
                   color; data-resume drives the resume-ring variant (lighter
                   green when a resume task id is set — evolve only). Both
                   keyed in CSS in assets/css/app.css.
                   id="task-launch-button" is a stable test/UI marker that
                   survives icon swaps. -->
                <button
                  type="submit"
                  id="task-launch-button"
                  class="btn btn-primary btn-circle btn-sm shrink-0"
                  data-mode={@mode}
                  data-resume={String.trim(@resume_from) != ""}
                  disabled={@disabled}
                  aria-label={gettext("Launch")}
                  title={gettext("Launch")}
                >
                  <.icon name="hero-arrow-up" class="size-4" />
                </button>
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
            class="select select-bordered select-sm w-full"
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
              class="input input-bordered input-sm w-full font-mono"
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
              class="input input-bordered input-sm w-full font-mono"
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
            class="input input-bordered input-sm w-full font-mono"
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
                class="input input-bordered input-sm w-full font-mono"
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
                class="input input-bordered input-sm w-full font-mono"
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
              class="input input-bordered input-sm w-full font-mono"
              placeholder="a1b2c3d4"
            />
          </div>
        </div>
      </div>
    <% end %>
    """
  end
end
