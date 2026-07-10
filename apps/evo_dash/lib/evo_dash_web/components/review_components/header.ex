defmodule EvoDashWeb.ReviewComponents.Header do
  @moduledoc false

  # zh_CN: Token → "词元", Agent → "智能体"

  use EvoDashWeb, :html

  # ---------------------------------------------------------------------------
  # review_header/1 — Page header with PR title, badges, and metadata
  # ---------------------------------------------------------------------------

  attr(:title, :string, required: true)
  attr(:task_type, :atom, required: true)
  attr(:branch_name, :string, default: nil)
  attr(:commit_sha, :string, default: nil)
  attr(:status, :atom, default: :open)

  def review_header(assigns) do
    ~H"""
    <div class="border-y border-base-200 bg-base-100 ">
      <div class="p-4">
        <div class="flex items-start gap-3">
          <.icon name="hero-code-bracket-square" class="size-5 text-base-content/50 shrink-0 mt-0.5" />
          <div class="flex-1 min-w-0">
            <h1 class="text-lg font-bold leading-tight truncate">{@title}</h1>
            <div class="flex flex-wrap items-center gap-2 mt-2">
              <span class={["badge badge-sm px-2 py-1.5", review_status_badge(@status)]}>
                <.icon name={review_status_icon(@status)} class="size-3.5 mr-1.5" />
                {review_status_label(@status)}
              </span>
              <span class="badge badge-sm badge-ghost px-2 py-1.5 capitalize">{@task_type}</span>
              <%= if @branch_name do %>
                <span class="badge badge-sm badge-primary px-2 py-1.5 font-mono">
                  <.icon name="hero-code-bracket-square" class="size-3.5 mr-1.5" />
                  {@branch_name}
                </span>
              <% end %>
              <%= if @commit_sha do %>
                <span class="badge badge-sm badge-ghost px-2 py-1.5 font-mono">
                  <.icon name="hero-code-bracket" class="size-3.5 mr-1.5" />
                  {String.slice(@commit_sha, 0..7)}
                </span>
              <% end %>
            </div>
          </div>
        </div>
      </div>
    </div>
    """
  end

  # ---------------------------------------------------------------------------
  # task_summary/1 — Compact stats strip showing token/cost usage and agent count
  # ---------------------------------------------------------------------------

  attr(:usage, :map, default: nil)
  attr(:agent_count, :integer, default: nil)
  attr(:task_type, :atom, default: nil)
  attr(:status, :atom, default: nil)
  attr(:started_at, :any, default: nil)
  attr(:finished_at, :any, default: nil)

  def task_summary(assigns) do
    ~H"""
    <div class="border-b border-base-200 bg-base-100 p-3">
      <div class="grid grid-cols-2 sm:grid-cols-4 gap-3">
        <%= if @usage do %>
          <div class="flex flex-col">
            <span class="text-xs font-medium text-base-content/50 uppercase tracking-wide flex items-center gap-1">
              <.icon name="hero-cpu-chip" class="size-3.5" /> <%!-- zh_CN: Token → "词元" --%>{gettext("Total Tokens")}
            </span>
            <span class="text-sm font-semibold text-base-content mt-0.5">
              {format_number(Map.get(@usage, :total_tokens, 0))}
            </span>
          </div>
          <div class="flex flex-col">
            <span class="text-xs font-medium text-base-content/50 uppercase tracking-wide flex items-center gap-1">
              <.icon name="hero-currency-dollar" class="size-3.5" /> {gettext("Total Cost")}
            </span>
            <span class="text-sm font-semibold text-base-content mt-0.5">
              {format_cost(Map.get(@usage, :total_cost, 0))}
            </span>
          </div>
          <div class="flex flex-col">
            <span class="text-xs font-medium text-base-content/50 uppercase tracking-wide flex items-center gap-1">
              <.icon name="hero-bolt" class="size-3.5" /> {gettext("Cache Hit Rate")}
            </span>
            <span class="text-sm font-semibold text-base-content mt-0.5">
              {format_cache_hit_rate(@usage)}
            </span>
          </div>
        <% end %>
        <%= if @agent_count do %>
          <div class="flex flex-col">
            <span class="text-xs font-medium text-base-content/50 uppercase tracking-wide flex items-center gap-1">
              <.icon name="hero-user-group" class="size-3.5" /> <%!-- zh_CN: Agent → "智能体" --%>{gettext("Agents")}
            </span>
            <span class="text-sm font-semibold text-base-content mt-0.5">{@agent_count}</span>
          </div>
        <% end %>
        <%= if @status do %>
          <div class="flex flex-col">
            <span class="text-xs font-medium text-base-content/50 uppercase tracking-wide flex items-center gap-1">
              <.icon name="hero-signal" class="size-3.5" /> {gettext("Status")}
            </span>
            <span class="text-sm font-semibold text-base-content mt-0.5 capitalize">{@status}</span>
          </div>
        <% end %>
        <%= if @task_type do %>
          <div class="flex flex-col">
            <span class="text-xs font-medium text-base-content/50 uppercase tracking-wide flex items-center gap-1">
              <.icon name="hero-cube" class="size-3.5" /> {gettext("Task Type")}
            </span>
            <span class="text-sm font-semibold text-base-content mt-0.5 capitalize">{@task_type}</span>
          </div>
        <% end %>
      </div>
    </div>
    """
  end

  # ---------------------------------------------------------------------------
  # agent_summary/1 — Collapsible panel showing agent result
  # ---------------------------------------------------------------------------

  attr(:summary, :string, required: true)
  attr(:open, :boolean, default: true)

  def agent_summary(assigns) do
    ~H"""
    <div class="bg-base-100 border-b border-base-200 ">
      <div class="relative">
        <details open={@open}>
          <summary class="p-5 md:p-6 cursor-pointer hover:bg-base-200/30 transition-colors flex items-center gap-4 list-none">
            <div class="bg-success/15 text-success p-2.5">
              <.icon name="hero-chat-bubble-left-ellipsis" class="size-5" />
            </div>
            <span class="font-semibold text-base-content/80">{gettext("Agent Summary")}</span>
            <div class="flex-1"></div>
            <.icon name="hero-chevron-down" class="size-4 text-base-content/40" />
          </summary>
          <div class="px-5 md:px-6 pb-5 md:pb-6">
            <div class="md-content text-sm leading-relaxed">
              {raw(EvoDash.MarkdownRender.render(@summary))}
            </div>
          </div>
        </details>
        <button
          id="summary-copy-btn"
          class="btn btn-ghost btn-sm btn-square absolute top-4 right-4 z-10"
          phx-hook="ClipboardCopy"
          data-content={@summary}
          title={gettext("Copy agent summary")}
        >
          <.icon name="hero-clipboard" class="size-4" />
        </button>
      </div>
    </div>
    """
  end
end
