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

  alias EvoDashWeb.LLMSetup.Identity
  alias EvoDashWeb.LLMSetup.Reasoning
  alias EvoDashWeb.LLMSetup.Schedule
  alias EvoDashWeb.LLMSetup.Wizard

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

  defp format_reason(reason) when is_binary(reason), do: reason

  defp format_reason(reason) when is_atom(reason) and reason not in [nil, true, false],
    do: reason |> Atom.to_string() |> String.replace("_", " ")

  defp format_reason({tag, reason}) when tag in [:error, :ok], do: format_reason(reason)

  defp format_reason(reason), do: inspect(reason)

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

  def step_provider(assigns) do
    assigns =
      assigns
      |> assign(:rows, provider_rows(assigns.providers))
      |> assign(:selected_id, clean_string(assigns.selected))
      |> assign(:custom_selected?, clean_string(assigns.selected) == assigns.custom_value)
      |> assign(:base_url_label, assigns.base_url_label || gettext("Endpoint URL"))
      |> assign(
        :base_url_placeholder,
        assigns.base_url_placeholder || "https://api.example.com/v1"
      )

    ~H"""
    <div class="space-y-5">
      <ul class="grid gap-2 sm:grid-cols-2" role="list">
        <li :for={row <- @rows}>
          <button
            type="button"
            phx-click={@provider_event}
            phx-value-provider={row.id}
            aria-pressed={to_string(row.id == @selected_id)}
            aria-current={if row.id == @selected_id, do: "true"}
            class={provider_card_class(row.id == @selected_id)}
          >
            <span class="block text-sm font-semibold text-base-content">{row.label}</span>
            <span :if={row.note} class="mt-1 block text-xs text-base-content/60">{row.note}</span>
          </button>
        </li>
        <li>
          <button
            type="button"
            phx-click={@provider_event}
            phx-value-provider={@custom_value}
            aria-pressed={to_string(@custom_selected?)}
            aria-current={if @custom_selected?, do: "true"}
            class={provider_card_class(@custom_selected?)}
          >
            <span class="block text-sm font-semibold text-base-content">
              {gettext("Custom / OpenAI-compatible endpoint")}
            </span>
            <span class="mt-1 block text-xs text-base-content/60">
              {gettext("Any endpoint that speaks the OpenAI chat-completions API.")}
            </span>
          </button>
        </li>
      </ul>

      <div>
        <label
          for={@base_url_name <> "-input"}
          class="mb-1 block text-xs font-medium text-base-content/70"
        >
          {@base_url_label}
        </label>
        <input
          id={@base_url_name <> "-input"}
          type="url"
          name={@base_url_name}
          value={@base_url}
          placeholder={@base_url_placeholder}
          autocomplete="off"
          spellcheck="false"
          class="input input-bordered input-sm w-full rounded-md font-mono text-sm"
        />
        <p class="mt-1 text-xs text-base-content/60">
          {gettext("Required for a custom endpoint; it is pre-filled for catalog providers.")}
        </p>
      </div>
    </div>
    """
  end

  defp provider_rows(providers) when is_list(providers) do
    providers
    |> Enum.map(&provider_row/1)
    |> Enum.reject(&is_nil/1)
  end

  defp provider_rows(_providers), do: []

  defp provider_row(%{} = provider) do
    id = value_of(provider, ["id", "value", "provider"])

    case clean_string(id) do
      "" ->
        nil

      id ->
        %{
          id: id,
          label: provider_label(provider, id),
          note: clean_string(value_of(provider, ["note", "description", "subtitle"]))
        }
    end
  end

  defp provider_row(provider) when is_atom(provider) or is_binary(provider) do
    provider_row(%{"id" => provider})
  end

  defp provider_row(_provider), do: nil

  defp provider_label(provider, id) do
    case clean_string(value_of(provider, ["label", "display_name", "name"])) do
      "" -> Identity.provider_display_name(id)
      label -> label
    end
  end

  defp provider_card_class(true) do
    "w-full rounded-lg border border-primary bg-primary/5 px-4 py-3 text-left transition hover:border-primary focus-visible:outline-none focus-visible:ring-2 focus-visible:ring-primary/40"
  end

  defp provider_card_class(_selected?) do
    "w-full rounded-lg border border-base-300 bg-base-100 px-4 py-3 text-left transition hover:border-base-content/30 focus-visible:outline-none focus-visible:ring-2 focus-visible:ring-primary/40"
  end

  # ═══════════════════════════════════════════════════════════════════════════
  # step_auth/1 — API key vs subscription (no secret input)
  # ═══════════════════════════════════════════════════════════════════════════

  attr(:selected, :any, default: nil)
  attr(:auth_event, :string, default: "select_auth")
  attr(:modes, :list, default: [:api_key, :oauth])
  attr(:oauth_only, :boolean, default: false)
  slot(:auth_detail)

  def step_auth(assigns) do
    assigns =
      assigns
      |> assign(:selected_mode, normalize_auth_mode(assigns.selected))
      |> assign(:available_modes, available_auth_modes(assigns))

    ~H"""
    <div class="space-y-4">
      <p
        :if={@oauth_only}
        class="rounded-lg border border-base-300 bg-base-200/50 px-3 py-2 text-sm text-base-content/80"
      >
        {gettext(
          "This provider only accepts a subscription login, so API-key authentication is not offered."
        )}
      </p>

      <ul class="grid gap-2 sm:grid-cols-2" role="list">
        <li :if={"api_key" in @available_modes}>
          <button
            type="button"
            phx-click={@auth_event}
            phx-value-mode="api_key"
            aria-pressed={to_string(@selected_mode == "api_key")}
            aria-current={if @selected_mode == "api_key", do: "true"}
            class={provider_card_class(@selected_mode == "api_key")}
          >
            <span class="block text-sm font-semibold text-base-content">{gettext("API key")}</span>
            <span class="mt-1 block text-xs text-base-content/60">
              {gettext("Bill the provider directly with a key stored in your credentials file.")}
            </span>
          </button>
        </li>
        <li :if={"oauth" in @available_modes}>
          <button
            type="button"
            phx-click={@auth_event}
            phx-value-mode="oauth"
            aria-pressed={to_string(@selected_mode == "oauth")}
            aria-current={if @selected_mode == "oauth", do: "true"}
            class={provider_card_class(@selected_mode == "oauth")}
          >
            <span class="block text-sm font-semibold text-base-content">
              {gettext("Subscription")}
            </span>
            <span class="mt-1 block text-xs text-base-content/60">
              {gettext(
                "Reuse a vendor CLI login (Codex / Claude) instead of an API key. Genesis never runs the OAuth flow itself."
              )}
            </span>
          </button>
        </li>
      </ul>

      {render_slot(@auth_detail)}
    </div>
    """
  end

  defp available_auth_modes(assigns) do
    modes =
      assigns.modes
      |> List.wrap()
      |> Enum.map(&normalize_auth_mode/1)
      |> Enum.filter(&(&1 in ["api_key", "oauth"]))

    modes =
      case modes do
        [] -> ["api_key"]
        modes -> Enum.uniq(modes)
      end

    if assigns.oauth_only do
      Enum.uniq(["oauth" | Enum.reject(modes, &(&1 == "api_key"))])
    else
      modes
    end
  end

  defp normalize_auth_mode(value) when is_binary(value) do
    value |> String.trim() |> String.downcase() |> String.replace("-", "_")
  end

  defp normalize_auth_mode(value) when is_atom(value) and value not in [nil, true, false],
    do: value |> Atom.to_string() |> normalize_auth_mode()

  defp normalize_auth_mode(_value), do: ""

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

  def step_model(assigns) do
    assigns =
      assigns
      |> assign(:rows, model_rows(assigns.models))
      |> assign(:selected_id, clean_string(assigns.selected))
      |> assign(:query_value, clean_string(assigns.query))
      |> assign(
        :custom_model_value,
        assigns.custom_model_value || gettext("Use a custom model name")
      )

    ~H"""
    <div class="space-y-4">
      <form
        id="wizard-model-search"
        phx-change={@model_search_event}
        phx-submit={@model_search_event}
        class="relative"
      >
        <label for="wizard-model-search-input" class="sr-only">{gettext("Search models")}</label>
        <input
          id="wizard-model-search-input"
          type="search"
          name={@search_name}
          value={@query}
          placeholder={gettext("Search models")}
          autocomplete="off"
          class="input input-bordered input-sm w-full rounded-md pl-9"
        />
        <.icon
          name="hero-magnifying-glass"
          class="pointer-events-none absolute left-3 top-1/2 size-4 -translate-y-1/2 text-base-content/40"
        />
      </form>

      <ul
        :if={@rows != []}
        class="max-h-72 space-y-1 overflow-y-auto rounded-lg border border-base-300 bg-base-100 p-2"
        role="list"
      >
        <li :for={row <- @rows}>
          <button
            type="button"
            phx-click={@model_event}
            phx-value-model={row.id}
            aria-current={if row.id == @selected_id, do: "true"}
            class={model_row_class(row.id == @selected_id)}
          >
            <span class="min-w-0">
              <span class="block truncate text-sm font-medium text-base-content">{row.label}</span>
              <span
                :if={row.label != row.id}
                class="block truncate font-mono text-xs text-base-content/50"
              >
                {row.id}
              </span>
            </span>
            <span :if={row.variant} class="badge badge-ghost badge-sm shrink-0">{row.variant}</span>
          </button>
        </li>
      </ul>

      <p
        :if={@rows == []}
        class="rounded-lg border border-dashed border-base-300 px-3 py-6 text-center text-sm text-base-content/60"
      >
        {gettext("No catalog model matches this search. Enter the model name below.")}
      </p>

      <.custom_model_field
        event={@custom_model_event}
        name={@custom_model_name}
        value={@custom_model}
        label={@custom_model_value}
      />
    </div>
    """
  end

  attr(:event, :string, default: nil)
  attr(:name, :string, required: true)
  attr(:value, :any, default: nil)
  attr(:label, :string, required: true)

  defp custom_model_field(%{event: nil} = assigns) do
    ~H"""
    <.custom_model_input name={@name} value={@value} label={@label} />
    """
  end

  defp custom_model_field(assigns) do
    ~H"""
    <form id="wizard-custom-model-form" phx-change={@event} phx-submit={@event}>
      <.custom_model_input name={@name} value={@value} label={@label} />
    </form>
    """
  end

  attr(:name, :string, required: true)
  attr(:value, :any, default: nil)
  attr(:label, :string, required: true)

  defp custom_model_input(assigns) do
    ~H"""
    <div>
      <label for={@name <> "-input"} class="mb-1 block text-xs font-medium text-base-content/70">
        {@label}
      </label>
      <input
        id={@name <> "-input"}
        type="text"
        name={@name}
        value={@value}
        autocomplete="off"
        spellcheck="false"
        placeholder={gettext("model-name-as-the-api-expects-it")}
        class="input input-bordered input-sm w-full rounded-md font-mono text-sm"
      />
      <p class="mt-1 text-xs text-base-content/60">
        {gettext("For an unreleased or self-hosted model that is not in the catalog.")}
      </p>
    </div>
    """
  end

  defp model_rows(models) when is_list(models) do
    models
    |> Enum.map(&model_row/1)
    |> Enum.reject(&is_nil/1)
  end

  defp model_rows(_models), do: []

  defp model_row(%{} = model) do
    id = clean_string(value_of(model, ["id", "model", "value"]))

    case id do
      "" ->
        nil

      id ->
        %{
          id: id,
          label: label_or_id(value_of(model, ["label", "display_name", "name"]), id),
          variant: clean_string(value_of(model, ["variant", "variant_label", "variant_id"]))
        }
    end
  end

  defp model_row(model) when is_binary(model), do: %{id: model, label: model, variant: nil}
  defp model_row(_model), do: nil

  defp model_row_class(true) do
    "flex w-full items-center justify-between gap-2 rounded-md border border-primary bg-primary/5 px-3 py-2 text-left transition hover:border-primary focus-visible:outline-none focus-visible:ring-2 focus-visible:ring-primary/40"
  end

  defp model_row_class(_selected?) do
    "flex w-full items-center justify-between gap-2 rounded-md border border-transparent px-3 py-2 text-left transition hover:border-base-300 hover:bg-base-200/50 focus-visible:outline-none focus-visible:ring-2 focus-visible:ring-primary/40"
  end

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

  def step_reasoning_schedule(assigns) do
    assigns =
      assigns
      |> assign(:inventory_values, Reasoning.normalize_inventory(assigns.inventory))
      |> assign(:inventory_name, assigns.inventory_name || Reasoning.inventory_input_name())
      |> assign(:default_name, assigns.default_name || Reasoning.default_input_name())
      |> assign(:default_value, default_select_value(assigns))
      |> assign(:chips, reasoning_chips(assigns.inventory))
      |> assign(:preset_rows, preset_rows(assigns.presets))
      |> assign(:applied_label, applied_preset_label(assigns.preset_applied))
      |> assign(:holiday_choices, holiday_choices(assigns))
      |> assign(:holiday_value, clean_string(assigns.off_peak_holidays))
      |> assign(:holiday_help_text, assigns.holiday_help || Schedule.holiday_help())
      |> assign(:rows, schedule_summary_rows(assigns.schedule_rows))

    ~H"""
    <div class="space-y-6">
      <fieldset>
        <legend class="mb-1 text-sm font-medium text-base-content">
          {gettext("Reasoning efforts this model accepts")}
        </legend>
        <p class="mb-3 text-xs text-base-content/60">
          {gettext(
            "Pick every effort level you want offered for this model, in the provider's own vocabulary."
          )}
        </p>
        <input type="hidden" name={@inventory_name} value="" />
        <div class="flex flex-wrap gap-2">
          <label :for={chip <- @chips} class={reasoning_chip_class(chip.checked)}>
            <input
              type="checkbox"
              name={@inventory_name}
              value={chip.value}
              checked={chip.checked}
              class="checkbox checkbox-sm"
            />
            <span class="text-sm">{chip.label}</span>
          </label>
        </div>
      </fieldset>

      <div :if={@inventory_values != []}>
        <label for="default-reasoning-effort" class="mb-1 block text-sm font-medium text-base-content">
          {gettext("Default reasoning effort")}
        </label>
        <select
          id="default-reasoning-effort"
          name={@default_name}
          class="select select-bordered select-sm w-full rounded-md sm:w-72"
        >
          <option value="" selected={@default_value == ""}>{gettext("Provider default")}</option>
          <option
            :for={effort <- @inventory_values}
            value={effort}
            selected={effort == @default_value}
          >
            {Reasoning.label(effort)}
          </option>
        </select>
      </div>

      <div
        :if={@applied_label || @preset_rows != []}
        class="rounded-lg border border-base-300 bg-base-200/40 p-4"
      >
        <div :if={@applied_label} class="flex flex-wrap items-center justify-between gap-3">
          <p class="flex items-center gap-2 text-sm font-medium text-base-content">
            <.icon name="hero-check-circle" class="size-4 text-primary" />
            {gettext("Recommended schedule applied")}
            <span class="font-normal text-base-content/60">· {@applied_label}</span>
          </p>
          <div class="flex items-center gap-2">
            <button
              :for={preset <- @preset_rows}
              type="button"
              phx-click={@preset_apply_event}
              phx-value-preset_id={preset.id}
              class="btn btn-ghost btn-xs"
            >
              {gettext("Re-apply")}
            </button>
            <button type="button" phx-click={@preset_undo_event} class="btn btn-ghost btn-xs">
              {gettext("Undo")}
            </button>
            <button
              :if={@preset_dismiss_event}
              type="button"
              phx-click={@preset_dismiss_event}
              class="btn btn-ghost btn-xs btn-square"
              aria-label={gettext("Dismiss")}
            >
              <.icon name="hero-x-mark" class="size-4" />
            </button>
          </div>
        </div>

        <div :if={@preset_rows != []} class={if(@applied_label, do: "mt-3", else: "")}>
          <p class="mb-2 text-xs font-medium text-base-content/70">
            {gettext("Published schedule presets")}
          </p>
          <div class="flex flex-wrap gap-2">
            <button
              :for={preset <- @preset_rows}
              type="button"
              phx-click={@preset_apply_event}
              phx-value-preset_id={preset.id}
              class="btn btn-outline btn-xs"
              title={preset.note}
            >
              {preset.label}
            </button>
          </div>
        </div>
      </div>

      <div>
        <label for="off-peak-holidays" class="mb-1 block text-sm font-medium text-base-content">
          {gettext("Off-peak public-holiday calendar")}
        </label>
        <select
          id="off-peak-holidays"
          name="off_peak_holidays"
          class="select select-bordered select-sm w-full rounded-md sm:w-72"
        >
          <option value="" selected={@holiday_value == ""}>
            {Schedule.holiday_label(nil)}
          </option>
          <option
            :for={{value, label} <- @holiday_choices}
            value={value}
            selected={value == @holiday_value}
          >
            {label}
          </option>
        </select>
        <p class="mt-1 text-xs text-base-content/60">{@holiday_help_text}</p>
      </div>

      <div :if={@rows != []}>
        <p class="mb-2 text-xs font-medium text-base-content/70">{gettext("Schedule")}</p>
        <dl class="divide-y divide-base-300 rounded-lg border border-base-300">
          <div :for={{label, value} <- @rows} class="flex items-start justify-between gap-4 px-3 py-2">
            <dt class="text-xs text-base-content/60">{label}</dt>
            <dd class="text-right text-xs font-medium text-base-content">{value}</dd>
          </div>
        </dl>
      </div>
    </div>
    """
  end

  defp reasoning_chips(inventory) do
    normalized = Reasoning.normalize_inventory(inventory)
    seen = MapSet.new(normalized)

    canonical =
      Enum.map(Reasoning.efforts(), fn effort ->
        %{value: effort, label: Reasoning.label(effort), checked: MapSet.member?(seen, effort)}
      end)

    extras =
      normalized
      |> Enum.reject(&Reasoning.level?/1)
      |> Enum.map(fn value -> %{value: value, label: Reasoning.label(value), checked: true} end)

    canonical ++ extras
  end

  defp default_select_value(assigns) do
    value = Reasoning.canonical(assigns.default_effort)

    if value != nil and value in Reasoning.normalize_inventory(assigns.inventory) do
      value
    else
      ""
    end
  end

  defp reasoning_chip_class(true) do
    "flex cursor-pointer items-center gap-2 rounded-lg border border-primary bg-primary/5 px-3 py-1.5"
  end

  defp reasoning_chip_class(_checked?) do
    "flex cursor-pointer items-center gap-2 rounded-lg border border-base-300 bg-base-100 px-3 py-1.5"
  end

  defp preset_rows(presets) when is_list(presets) do
    presets
    |> Enum.map(fn
      %{} = preset ->
        id = clean_string(value_of(preset, ["id"]))
        label = label_or_id(value_of(preset, ["label", "name"]), id)
        note = clean_string(value_of(preset, ["note"]))
        if id == "", do: nil, else: %{id: id, label: label, note: note}

      _preset ->
        nil
    end)
    |> Enum.reject(&is_nil/1)
  end

  defp preset_rows(_presets), do: []

  defp applied_preset_label(nil), do: nil
  defp applied_preset_label(""), do: nil
  defp applied_preset_label(true), do: nil

  defp applied_preset_label(%{} = preset) do
    id = clean_string(value_of(preset, ["id"]))
    label_or_id(value_of(preset, ["label", "name"]), id)
  end

  defp applied_preset_label(value), do: clean_string(value)

  defp holiday_choices(assigns) do
    options =
      case assigns.holiday_options do
        options when is_list(options) and options != [] -> options
        _ -> Schedule.holiday_options()
      end

    Enum.map(options, fn
      {value, label} ->
        {clean_string(value), to_string(label)}

      %{} = option ->
        {clean_string(value_of(option, ["value"])), to_string(value_of(option, ["label"]))}

      value ->
        {clean_string(value), clean_string(value)}
    end)
  end

  defp schedule_summary_rows(rows) when is_list(rows) do
    rows
    |> Enum.map(fn
      {label, value} -> {to_string(label), to_string(value)}
      %{} = row -> {to_string(value_of(row, ["label"])), to_string(value_of(row, ["value"]))}
      _row -> nil
    end)
    |> Enum.reject(&is_nil/1)
  end

  defp schedule_summary_rows(_rows), do: []

  # ═══════════════════════════════════════════════════════════════════════════
  # step_test/1 — connection test states
  # ═══════════════════════════════════════════════════════════════════════════

  attr(:test_state, :any, default: :idle)
  attr(:test_event, :string, default: "test_connection")
  attr(:skip_event, :string, default: "skip_test")
  attr(:test_label, :string, default: nil)
  attr(:skip_label, :string, default: nil)

  def step_test(assigns) do
    assigns =
      assigns
      |> assign(:test_label, assigns.test_label || gettext("Test connection"))
      |> assign(:skip_label, assigns.skip_label || gettext("Skip for now"))
      |> assign(:testing?, assigns.test_state == :testing)
      |> assign(:ok_detail, test_ok_detail(assigns.test_state))
      |> assign(:error_detail, test_error_detail(assigns.test_state))

    ~H"""
    <div class="space-y-4">
      <p class="text-sm text-base-content/70">
        {gettext(
          "Check that Genesis can reach the provider with the credentials you just entered. Skipping is fine — a wrong key surfaces on the first task instead."
        )}
      </p>

      <div class="flex flex-wrap items-center gap-2">
        <button
          type="button"
          phx-click={@test_event}
          class="btn btn-primary btn-sm"
          disabled={@testing?}
        >
          <.icon name="hero-bolt" class={if(@testing?, do: "size-4 animate-spin", else: "size-4")} />
          {@test_label}
        </button>
        <button type="button" phx-click={@skip_event} class="btn btn-ghost btn-sm">{@skip_label}</button>
      </div>

      <p
        :if={@testing?}
        class="flex items-center gap-2 rounded-lg border border-base-300 bg-base-200/50 px-3 py-2 text-sm text-base-content/70"
      >
        <.icon name="hero-arrow-path" class="size-4 animate-spin" />
        {gettext("Testing the connection…")}
      </p>

      <p
        :if={@ok_detail}
        class="flex items-start gap-2 rounded-lg border border-success/30 bg-success/10 px-3 py-2 text-sm text-success"
      >
        <.icon name="hero-check-circle" class="mt-0.5 size-4 shrink-0" />
        <span class="min-w-0">
          {gettext("Connection succeeded.")}
          <span :if={@ok_detail != ""} class="block text-xs text-success/80">{@ok_detail}</span>
        </span>
      </p>

      <p
        :if={@error_detail}
        class="flex items-start gap-2 rounded-lg border border-error/30 bg-error/10 px-3 py-2 text-sm text-error"
      >
        <.icon name="hero-exclamation-triangle" class="mt-0.5 size-4 shrink-0" />
        <span class="min-w-0">
          {gettext("Connection failed.")}
          <span class="block text-xs text-error/80">{@error_detail}</span>
        </span>
      </p>
    </div>
    """
  end

  defp test_ok_detail({:ok, detail}), do: clean_string(detail)
  defp test_ok_detail(:ok), do: ""

  defp test_ok_detail(%{status: status} = result) when status in [:ok, "ok"],
    do: clean_string(Map.get(result, :detail) || Map.get(result, "detail"))

  defp test_ok_detail(_state), do: nil

  defp test_error_detail({:error, reason}), do: format_reason(reason)
  defp test_error_detail(_state), do: nil

  # ═══════════════════════════════════════════════════════════════════════════
  # step_done/1 — summary + primary action
  # ═══════════════════════════════════════════════════════════════════════════

  attr(:summary, :any, default: [])
  attr(:dashboard_path, :string, default: "/projects")
  attr(:dashboard_label, :string, default: nil)
  slot(:secondary)

  def step_done(assigns) do
    assigns =
      assigns
      |> assign(:rows, done_rows(assigns.summary))
      |> assign(:dashboard_label, assigns.dashboard_label || gettext("Go to the dashboard"))

    ~H"""
    <div class="space-y-5">
      <p class="text-sm text-base-content/70">
        {gettext(
          "Your provider account is ready. Genesis can start tasks with this configuration now."
        )}
      </p>

      <dl :if={@rows != []} class="divide-y divide-base-300 rounded-lg border border-base-300">
        <div :for={{label, value} <- @rows} class="flex items-start justify-between gap-4 px-3 py-2">
          <dt class="text-xs text-base-content/60">{label}</dt>
          <dd class="text-right text-sm font-medium text-base-content">{value}</dd>
        </div>
      </dl>

      <div class="flex flex-wrap items-center gap-2">
        <a href={@dashboard_path} class="btn btn-primary btn-sm">{@dashboard_label}</a>
        {render_slot(@secondary)}
      </div>
    </div>
    """
  end

  defp done_rows(summary) when is_list(summary) do
    summary
    |> Enum.map(fn
      {label, value} -> done_row(label, value)
      %{} = row -> done_row(value_of(row, ["label"]), value_of(row, ["value"]))
      _row -> nil
    end)
    |> Enum.reject(&is_nil/1)
  end

  defp done_rows(_summary), do: []

  defp done_row(label, value) do
    case {clean_string(label), clean_string(value)} do
      {"", _value} -> nil
      {_label, ""} -> nil
      {label, value} -> {label, value}
    end
  end

  # ═══════════════════════════════════════════════════════════════════════════
  # shared private helpers
  # ═══════════════════════════════════════════════════════════════════════════

  defp value_of(%{} = map, keys) when is_list(keys) do
    Enum.find_value(keys, fn key ->
      case Map.fetch(map, key) do
        {:ok, value} -> value
        :error -> Map.get(map, static_key_atom(key))
      end
    end)
  end

  defp value_of(_value, _keys), do: nil

  # Static key → atom table: caller input never interns an atom.
  defp static_key_atom("id"), do: :id
  defp static_key_atom("value"), do: :value
  defp static_key_atom("provider"), do: :provider
  defp static_key_atom("label"), do: :label
  defp static_key_atom("name"), do: :name
  defp static_key_atom("note"), do: :note
  defp static_key_atom("description"), do: :description
  defp static_key_atom("subtitle"), do: :subtitle
  defp static_key_atom("display_name"), do: :display_name
  defp static_key_atom("model"), do: :model
  defp static_key_atom("variant"), do: :variant
  defp static_key_atom("variant_label"), do: :variant_label
  defp static_key_atom("variant_id"), do: :variant_id
  defp static_key_atom(_key), do: nil

  defp label_or_id(value, id) do
    case clean_string(value) do
      "" -> id
      label -> label
    end
  end

  defp clean_string(nil), do: nil
  defp clean_string(value) when is_binary(value), do: String.trim(value)

  defp clean_string(value) when is_atom(value) and value not in [true, false],
    do: Atom.to_string(value)

  defp clean_string(_value), do: nil
end
