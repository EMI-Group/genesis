defmodule EvoDashWeb.SystemLive.ChartsComponent do
  @moduledoc """
  Render boundary for the `/system` scheduler-status charts.

  The evo_git system sampler broadcasts `{:system_sample, node, seq, sample}`
  every 3 seconds, and the page appends each sample to its bounded ring buffer
  (`Charts.push/2`). Isolating the charts in a stateful LiveComponent keeps that
  once-per-tick diff scoped to the chart section: a sample update re-renders
  (and patches) only this component's chart cards, not the Software Update
  card, the System Self-Check grid, the Genesis Source card or the System
  Controls section.

  The component owns NO data: the page still owns the ring buffer
  (`samples`), the resolved provider-profile pool selection
  (`selected_llm_model`) and the scheduler paused flag (`paused`). Series
  derivation, pool options and the SVG path building stay where they already
  live — in `EvoDashWeb.SystemLive.Charts` / `Charts.charts_section/1`, which
  this component calls unchanged. The in-card `select_llm_model` change event
  carries no `phx-target`, so it still reaches the page's own handler, which
  re-assigns `selected_llm_model` and passes it back down.
  """

  use EvoDashWeb, :live_component

  alias EvoDashWeb.SystemLive.Charts

  @impl true
  def update(assigns, socket) do
    # Only the chart inputs cross this boundary — the component never receives
    # (and so can never re-render on) any other page assign.
    {:ok,
     assign(socket,
       samples: assigns.samples,
       paused: assigns.paused,
       selected_llm_model: assigns.selected_llm_model
     )}
  end

  attr(:samples, :list, required: true)
  attr(:paused, :boolean, default: false)
  attr(:selected_llm_model, :string, default: nil)

  @impl true
  def render(assigns) do
    # A stateful component needs ONE static root tag; the wrapper carries no
    # markup of its own, so the chart section's DOM is unchanged.
    ~H"""
    <div id="system-charts">
      <Charts.charts_section
        samples={@samples}
        paused={@paused}
        selected_llm_model={@selected_llm_model}
      />
    </div>
    """
  end
end
