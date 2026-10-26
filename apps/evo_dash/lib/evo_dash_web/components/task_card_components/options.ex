defmodule EvoDashWeb.TaskCardComponents.Options do
  @moduledoc """
  Task-option rendering for the task card: `objective_text/1`,
  `render_options/1,2` (the capped in-card Objective body) and
  `render_options_full/1` (the uncapped Full Objective modal body).
  """

  use EvoDashWeb, :html

  alias EvoDashWeb.TaskCardComponents

  # ---------------------------------------------------------------------------
  # Public helpers — render_options/2
  # ---------------------------------------------------------------------------

  @doc """
  Returns the objective text for a task's opts (the `:prompt`, falling back to
  `:objective`), trimmed of surrounding whitespace. Shared by the collapsed-card
  preview, the expanded Objective card (including its copy button), and
  `render_options/2`.

  Deliberately returns the COMPLETE text — the card's Copy button bounds it at
  render time (`copy_payload/1`, 1 MiB cap on the HTML-materialized
  `data-content`), while the in-card RENDERING path (`render_options/2` with
  `truncate: true`) caps it to a preview.
  """
  def objective_text(opts) do
    (opts[:prompt] || opts[:objective] || "") |> String.trim()
  end

  def render_options(opts, render_opts \\ []) do
    # `truncate: true` = the expanded-card body (scrollable, CAPPED preview);
    # `truncate: false` = the zoomed Full Objective modal (own container
    # scrolls, full text).
    truncate = Keyword.get(render_opts, :truncate, true)
    primary_text = objective_text(opts)
    mode = opts[:mode] || ""
    path = opts[:path] || ""

    assigns = %{
      primary_text: TaskCardComponents.text_preview(primary_text, truncate),
      mode: mode,
      path: path,
      truncate: truncate
    }

    ~H"""
    <div class="space-y-3">
      <div class="bg-base-100 p-3 rounded-lg border border-base-200 shadow-inner">
        <div class={[
          "text-sm whitespace-pre-wrap break-words",
          if(@truncate, do: "max-h-48 overflow-y-auto", else: "")
        ]}>
          {@primary_text.text}
        </div>
        <EvoDashWeb.TaskCardComponents.preview_limit_note preview={@primary_text} />
      </div>
      <div class="flex flex-wrap gap-2 text-xs">
        <%= if @mode != "" do %>
          <span class="badge badge-primary font-mono">
            <.icon name="hero-cog-6-tooth" class="size-3 mr-1" />
            {@mode}
          </span>
        <% end %>
        <%= if @path != "" do %>
          <span class="badge badge-ghost font-mono">
            <.icon name="hero-folder" class="size-3 mr-1" />
            {@path}
          </span>
        <% end %>
      </div>
    </div>
    """
  end

  # ---------------------------------------------------------------------------
  # Public API — render_options_full/1 renders task options without truncation
  # ---------------------------------------------------------------------------

  # `truncate: false` = the Full Objective MODAL body: the complete, uncapped
  # objective text — reached only by an explicit user action
  # (`view_full_options`) and scrolled by the modal's own container.
  def render_options_full(opts) do
    render_options(opts, truncate: false)
  end
end
