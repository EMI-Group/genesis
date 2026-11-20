defmodule EvoDashWeb.Components.Skeleton do
  @moduledoc """
  ONE shared loading placeholder for lazily-fetched content — the successor of
  the per-site `loading loading-spinner` line.

  A skeleton keeps the shape of the thing that is about to arrive, so the page
  does not reflow when the data lands: callers reserve the block's height through
  `:class` (e.g. `min-h-16`) and the bars simply fill it. The bars are decorative
  (`aria-hidden`), which is why a site that also renders a live status line keeps
  its own caption for assistive tech.

  Styling comes from the existing `.skeleton` utility in `assets/css/app.css`
  (shimmer, theme-token gradient) — no motion code lives here, and the global
  reduced-motion backstop in `assets/css/motion.css` stills the shimmer.
  """

  use EvoDashWeb, :html

  # Descending widths so a stack of bars reads as prose, not as a table.
  @bar_widths ["w-full", "w-5/6", "w-2/3", "w-1/2"]

  attr(:count, :integer, default: 3, doc: "how many bars to draw (minimum 1)")
  attr(:class, :string, default: nil, doc: "wrapper classes — reserve the block's height here")
  attr(:bar_class, :string, default: nil, doc: "extra classes for every bar")

  @doc """
  A stack of `:count` shimmering bars (default 3), widest first.
  """
  def row(assigns) do
    count = if is_integer(assigns.count) and assigns.count > 0, do: assigns.count, else: 3

    widths =
      Enum.map(1..count, fn index ->
        Enum.at(@bar_widths, rem(index - 1, length(@bar_widths)))
      end)

    assigns = assign(assigns, :widths, widths)

    ~H"""
    <div class={["space-y-2", @class]} aria-hidden="true" data-skeleton>
      <div :for={width <- @widths} class={["skeleton h-3 rounded-md", width, @bar_class]}></div>
    </div>
    """
  end
end
