defmodule EvoDashWeb.ComposerComponents do
  @moduledoc """
  Shared workbench composer wrapper and surface. Callers own the form and controls.
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

  attr(:class, :any, default: nil)
  attr(:rest, :global)
  attr(:toolbar_id, :string, default: nil)
  attr(:toolbar_class, :any, default: nil)

  attr(:toolbar_attrs, :map,
    default: %{},
    doc: "Additional toolbar attributes; pass id and class through their dedicated props."
  )

  slot(:editor, required: true)

  slot(:before_toolbar,
    doc: "Existing sidecars between the editor and toolbar, without a wrapper."
  )

  slot(:toolbar, doc: "Toolbar controls; omit for an editor without controls.")

  def composer_surface(assigns) do
    ~H"""
    <div class={["workbench-composer-surface", @class]} {@rest}>
      <div class="workbench-composer-editor">{render_slot(@editor)}</div>
      {render_slot(@before_toolbar)}
      <div
        :if={@toolbar != []}
        id={@toolbar_id}
        class={["workbench-composer-toolbar", @toolbar_class]}
        {@toolbar_attrs}
      >
        {render_slot(@toolbar)}
      </div>
    </div>
    """
  end
end
