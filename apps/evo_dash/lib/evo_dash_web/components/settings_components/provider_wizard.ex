defmodule EvoDashWeb.SettingsComponents.ProviderWizard do
  @moduledoc """
  Reusable step components for the LLM provider setup wizard — shared by
  `/welcome` onboarding and `/settings`.

  Every function here is a PURE function component: it receives assigns and
  returns HEEx. It owns NO `phx-*` event of its own in the sense that matters
  — each event name is an ATTR with a default (`back_event`, `next_event`,
  `provider_event`, `auth_event`, `model_event`, …), so a caller can keep its
  own vocabulary and both pages render the same visual language. Nothing here
  reads config, the catalog or the clock: the step order, the reasoning
  vocabulary, the holidays and the schedule summary all arrive as assigns
  (built by `EvoDashWeb.LLMSetup.Wizard`, `.Reasoning` and `.Schedule`).

  ## Pieces

    * `wizard_shell/1` — heading + segmented progress rail + step body +
      Back / Next / optional Cancel footer;
    * `step_provider/1` — provider cards, the custom-endpoint row and its URL
      input;
    * `step_auth/1` — API key vs subscription cards (no secret field — the
      caller owns credentials via the `:auth_detail` slot);
    * `step_model/1` — searchable catalog list PLUS an always-present
      free-text "custom model name" input;
    * `step_reasoning_schedule/1` — reasoning inventory chips, the
      per-model default select, the optional recommended-schedule strip and
      the off-peak holiday calendar;
    * `step_test/1` — connection-test states + "Skip for now";
    * `step_done/1` — summary rows + the primary link into the dashboard.

  ## File layout

  This module owns the PUBLIC API: every `attr`/`slot` declaration and the
  thin `step_*` wrappers live here, so call-site validation and docs are
  unchanged. The markup of each step lives in one module under
  `provider_wizard/` — `provider_step.ex`, `auth_step.ex`, `model_step.ex`,
  `reasoning_step.ex`, `test_step.ex`, `done_step.ex` — and the helpers more
  than one step needs (`value_of/2`, `clean_string/1`, `label_or_id/2`,
  `format_reason/1`, `card_class/1`) live in `provider_wizard/helpers.ex`.
  `wizard_shell/1` and its private progress-rail helpers stay in this file.

  ## Classes the page-level CSS supplies

  Two class names are emitted here and styled in `assets/css/app.css` (added
  separately): `wizard-progress` on the progress rail and `wizard-step-enter`
  on the step body wrapper (`id={"wizard-step-" <> step}`), which animates on
  each step change and must degrade to no animation under
  `prefers-reduced-motion: reduce`. This module writes NO CSS.

  ## Styling rules

  Tailwind 4 + DaisyUI tokens only (`bg-base-*`, `text-base-content`,
  `border-base-300`, `btn btn-primary`), corners ≤ `rounded-xl`, and
  `text-*-content` only on solid fills.
  """

  use EvoDashWeb, :html

  alias EvoDashWeb.LLMSetup.Wizard

  alias EvoDashWeb.SettingsComponents.ProviderWizard.{
    AuthStep,
    DoneStep,
    Helpers,
    ModelStep,
    ProviderStep,
    ReasoningStep,
    TestStep
  }

  # The shared total reason formatter lives in `provider_wizard/helpers.ex`
  # (the test step needs it too).
  import Helpers, only: [format_reason: 1]

  # ═══════════════════════════════════════════════════════════════════════════
  # wizard_shell/1 — heading + progress rail + step body + footer
  # ═══════════════════════════════════════════════════════════════════════════

  attr(:step, :atom, required: true)
  attr(:steps, :list, required: true)
  attr(:title, :string, required: true)
  attr(:subtitle, :string, default: nil)
  attr(:progress, :any, default: nil)
  attr(:step_labels, :map, default: %{})
  attr(:back_event, :string, default: "wizard_back")
  attr(:back_label, :string, default: nil)
  attr(:next_event, :string, default: "wizard_next")
  attr(:next_label, :string, default: nil)
  attr(:next_disabled, :boolean, default: false)
  attr(:cancel_event, :string, default: nil)
  attr(:cancel_label, :string, default: nil)
  attr(:error, :any, default: nil)
  slot(:inner_block)

  def wizard_shell(assigns) do
    assigns =
      assigns
      |> assign(:progress_values, progress_values(assigns))
      |> assign(:step_rows, step_rows(assigns))
      |> assign(:back_label, assigns.back_label || gettext("Back"))
      |> assign(:next_label, assigns.next_label || gettext("Continue"))
      |> assign(:cancel_label, assigns.cancel_label || gettext("Cancel"))
      |> assign(:error_text, error_text(assigns.error))
      |> assign(:first_step?, assigns.step == List.first(wizard_steps(assigns.steps)))

    ~H"""
    <section class="overflow-hidden rounded-xl border border-base-300 bg-base-100">
      <header class="border-b border-base-300 px-6 py-5">
        <div class="flex items-start justify-between gap-4">
          <div class="min-w-0">
            <h2 class="text-lg font-semibold tracking-tight text-base-content">{@title}</h2>
            <p :if={@subtitle} class="mt-1 text-sm text-base-content/70">{@subtitle}</p>
          </div>
          <p class="shrink-0 text-xs font-medium tabular-nums text-base-content/60">
            {step_count_text(@progress_values)}
          </p>
        </div>
        <ol
          class="wizard-progress mt-4 flex flex-wrap items-center gap-x-3 gap-y-2"
          aria-label={gettext("Setup progress")}
        >
          <li :for={row <- @step_rows} class="flex items-center gap-2">
            <span class={progress_dot_class(row.state)} aria-hidden="true"></span>
            <span
              class={progress_label_class(row.state)}
              aria-current={if row.state == :current, do: "step"}
            >
              {row.label}
            </span>
          </li>
        </ol>
      </header>
      <div class="px-6 py-6">
        <div class="wizard-step-enter" id={"wizard-step-" <> to_string(@step)}>
          {render_slot(@inner_block)}
        </div>
        <p
          :if={@error_text}
          class="mt-4 flex items-start gap-2 rounded-lg border border-error/30 bg-error/10 px-3 py-2 text-sm text-error"
        >
          <.icon name="hero-exclamation-triangle" class="mt-0.5 size-4 shrink-0" />
          <span class="min-w-0">{@error_text}</span>
        </p>
      </div>
      <footer class="flex items-center justify-between gap-3 border-t border-base-300 px-6 py-4">
        <div class="flex items-center gap-2">
          <button
            type="button"
            phx-click={@back_event}
            class="btn btn-ghost btn-sm"
            disabled={@first_step?}
          >
            {@back_label}
          </button>
          <button
            :if={@cancel_event}
            type="button"
            phx-click={@cancel_event}
            class="btn btn-ghost btn-sm text-base-content/70"
          >
            {@cancel_label}
          </button>
        </div>
        <button
          type="button"
          phx-click={@next_event}
          class="btn btn-primary btn-sm"
          disabled={@next_disabled}
        >
          {@next_label}
        </button>
      </footer>
    </section>
    """
  end

  defp wizard_steps(steps) when is_list(steps), do: steps
  defp wizard_steps(_steps), do: []

  defp progress_values(%{progress: {_current, _total, _percent} = progress}), do: progress
  defp progress_values(assigns), do: Wizard.progress(wizard_steps(assigns.steps), assigns.step)

  defp step_count_text({current, total, _percent}) when total > 0 do
    gettext("Step %{current} of %{total}", current: to_string(current), total: to_string(total))
  end

  defp step_count_text(_progress), do: ""

  defp step_rows(assigns) do
    steps = wizard_steps(assigns.steps)
    current_index = Wizard.index(steps, assigns.step)
    labels = if is_map(assigns.step_labels), do: assigns.step_labels, else: %{}

    steps
    |> Enum.with_index()
    |> Enum.map(fn {step, index} ->
      %{
        step: step,
        label: step_label(step, labels),
        state: step_state(index, current_index)
      }
    end)
  end

  defp step_state(_index, nil), do: :upcoming
  defp step_state(index, current) when index < current, do: :done
  defp step_state(index, current) when index == current, do: :current
  defp step_state(_index, _current), do: :upcoming

  defp step_label(step, labels) do
    case Map.get(labels, step) do
      # A caller-supplied label is already user-facing text (possibly already
      # translated); it is looked up at runtime because the msgid is dynamic.
      label when is_binary(label) -> Gettext.gettext(EvoDashWeb.Gettext, label)
      _ -> default_step_label(step)
    end
  end

  defp default_step_label(:provider), do: gettext("Provider")
  defp default_step_label(:auth), do: gettext("Authentication")
  defp default_step_label(:model), do: gettext("Model")
  defp default_step_label(:reasoning_schedule), do: gettext("Reasoning & schedule")
  defp default_step_label(:test), do: gettext("Test")
  defp default_step_label(:done), do: gettext("Done")

  defp default_step_label(step) do
    step |> to_string() |> String.replace("_", " ")
  end

  defp progress_dot_class(:done),
    do: "size-2.5 rounded-full bg-primary"

  defp progress_dot_class(:current),
    do:
      "size-2.5 rounded-full bg-primary ring-2 ring-primary/30 ring-offset-1 ring-offset-base-100"

  defp progress_dot_class(_state),
    do: "size-2.5 rounded-full bg-base-300"

  defp progress_label_class(:current), do: "text-xs font-semibold text-base-content"
  defp progress_label_class(:done), do: "text-xs font-medium text-base-content/80"
  defp progress_label_class(_state), do: "text-xs font-medium text-base-content/50"

  defp error_text(nil), do: nil
  defp error_text(""), do: nil

  defp error_text(%{} = error) do
    Map.get(error, :message) || Map.get(error, "message") || format_reason(error)
  end

  defp error_text(error), do: format_reason(error)

  # ═══════════════════════════════════════════════════════════════════════════
  # step_provider/1 — provider cards + custom endpoint
  # ═══════════════════════════════════════════════════════════════════════════

  attr(:providers, :list, default: [])
  attr(:selected, :any, default: nil)
  attr(:provider_event, :string, default: "select_provider")
  attr(:custom_value, :string, default: "custom")
  attr(:base_url, :any, default: nil)
  attr(:base_url_name, :string, default: "base_url")
  attr(:base_url_label, :string, default: nil)
  attr(:base_url_placeholder, :string, default: nil)

  def step_provider(assigns), do: ProviderStep.step_provider(assigns)

  # ═══════════════════════════════════════════════════════════════════════════
  # step_auth/1 — API key vs subscription (no secret input)
  # ═══════════════════════════════════════════════════════════════════════════

  attr(:selected, :any, default: nil)
  attr(:auth_event, :string, default: "select_auth")
  attr(:modes, :list, default: [:api_key, :oauth])
  attr(:oauth_only, :boolean, default: false)
  attr(:chatgpt, :boolean, default: false)
  slot(:auth_detail)

  def step_auth(assigns), do: AuthStep.step_auth(assigns)

  # ═══════════════════════════════════════════════════════════════════════════
  # step_model/1 — searchable catalog list + free-text custom model
  # ═══════════════════════════════════════════════════════════════════════════

  attr(:models, :list, default: [])
  attr(:selected, :any, default: nil)
  attr(:query, :any, default: nil)
  attr(:model_event, :string, default: "select_model")
  attr(:model_search_event, :string, default: "search_models")
  attr(:search_name, :string, default: "query")
  attr(:custom_model, :any, default: nil)
  attr(:custom_model_event, :string, default: nil)
  attr(:custom_model_name, :string, default: "custom_model")
  attr(:custom_model_value, :string, default: nil)
  attr(:allow_custom_model, :boolean, default: true)

  def step_model(assigns), do: ModelStep.step_model(assigns)

  # ═══════════════════════════════════════════════════════════════════════════
  # step_reasoning_schedule/1 — reasoning inventory + default + schedule
  # ═══════════════════════════════════════════════════════════════════════════

  attr(:inventory, :list, default: [])
  attr(:default_effort, :any, default: nil)
  attr(:presets, :list, default: [])
  attr(:preset_applied, :any, default: nil)
  attr(:preset_apply_event, :string, default: "apply_schedule_preset")
  attr(:preset_undo_event, :string, default: "undo_schedule_preset")
  attr(:preset_dismiss_event, :string, default: nil)
  attr(:off_peak_holidays, :any, default: nil)
  attr(:holiday_options, :list, default: nil)
  attr(:holiday_help, :string, default: nil)
  attr(:schedule_rows, :list, default: [])
  attr(:inventory_name, :string, default: nil)
  attr(:default_name, :string, default: nil)

  def step_reasoning_schedule(assigns), do: ReasoningStep.step_reasoning_schedule(assigns)

  # ═══════════════════════════════════════════════════════════════════════════
  # step_test/1 — connection test states
  # ═══════════════════════════════════════════════════════════════════════════

  attr(:test_state, :any, default: :idle)
  attr(:test_event, :string, default: "test_connection")
  attr(:skip_event, :string, default: "skip_test")
  attr(:test_label, :string, default: nil)
  attr(:skip_label, :string, default: nil)

  def step_test(assigns), do: TestStep.step_test(assigns)

  # ═══════════════════════════════════════════════════════════════════════════
  # step_done/1 — summary + primary action
  # ═══════════════════════════════════════════════════════════════════════════

  attr(:summary, :any, default: [])
  attr(:dashboard_path, :string, default: "/projects")
  attr(:dashboard_label, :string, default: nil)
  slot(:secondary)

  def step_done(assigns), do: DoneStep.step_done(assigns)
end
