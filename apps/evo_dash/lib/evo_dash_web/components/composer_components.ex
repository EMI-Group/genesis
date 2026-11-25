defmodule EvoDashWeb.ComposerComponents do
  @moduledoc """
  Shared workbench composer wrapper. Callers own the form, controls and layout.
  """

  use EvoDashWeb, :html

  attr(:kind, :string, required: true, values: ["assistant", "task"])
  attr(:class, :any, default: nil)
  attr(:rest, :global)
  slot(:inner_block, required: true)

  def composer(assigns) do
    ~H"""
    <div class={["workbench-composer", @class]} data-composer-kind={@kind} {@rest}>
      {render_slot(@inner_block)}
    </div>
    """
  end
end
