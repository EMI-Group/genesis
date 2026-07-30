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
  # objective_section/1 — Prominent card showing the original objective/prompt
  # ---------------------------------------------------------------------------

  attr(:objective, :string, default: nil)

  def objective_section(assigns) do
    ~H"""
    <%= if @objective do %>
      <div class="bg-base-100 border border-base-200 rounded-lg p-4">
        <div class="flex items-start gap-3">
          <div class="bg-primary/15 text-primary p-2 shrink-0">
            <.icon name="hero-bullseye" class="size-5" />
          </div>
          <div class="flex-1 min-w-0">
            <h3 class="text-xs font-bold text-base-content/50 uppercase tracking-wide mb-1">
              {gettext("Objective")}
            </h3>
            <p class="text-sm text-base-content/90 leading-relaxed whitespace-pre-wrap break-words">
              {@objective}
            </p>
          </div>
        </div>
      </div>
    <% end %>
    """
  end

  # ---------------------------------------------------------------------------
  # task_summary/1 — Compact stats strip + collapsible full usage breakdown
  # ---------------------------------------------------------------------------

  attr(:usage, :map, default: nil)
  attr(:agent_count, :integer, default: nil)
  attr(:task_type, :atom, default: nil)
  attr(:status, :atom, default: nil)
  attr(:model_id, :string, default: nil)
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
        <%= if @started_at do %>
          <div class="flex flex-col">
            <span class="text-xs font-medium text-base-content/50 uppercase tracking-wide flex items-center gap-1">
              <.icon name="hero-play" class="size-3.5" /> {gettext("Started")}
            </span>
            <span class="text-sm font-semibold text-base-content mt-0.5">{relative_time(@started_at)}</span>
          </div>
        <% end %>
        <%= if @finished_at do %>
          <div class="flex flex-col">
            <span class="text-xs font-medium text-base-content/50 uppercase tracking-wide flex items-center gap-1">
              <.icon name="hero-stop" class="size-3.5" /> {gettext("Finished")}
            </span>
            <span class="text-sm font-semibold text-base-content mt-0.5">{relative_time(@finished_at)}</span>
          </div>
        <% end %>
      </div>

      <%= if @usage do %>
        <!-- Collapsible full Token & Cost Usage breakdown (hidden by default) -->
        <details class="mt-3">
          <summary class="cursor-pointer text-xs font-medium text-base-content/60 hover:text-base-content flex items-center gap-1.5 select-none outline-none py-1 w-fit">
            <.icon name="hero-currency-dollar" class="size-3.5 text-primary" />
            {gettext("Token & Cost Usage")}
            <.icon name="hero-chevron-down" class="size-3.5 text-base-content/40" />
          </summary>
          <div class="mt-3 bg-base-200/30 p-4 rounded-lg border border-base-200/80 hover:border-base-300 transition-colors">
            <div class="grid grid-cols-3 gap-3">
              <div>
                <div class="text-xs text-base-content/50 mb-1">
                  <%!-- zh_CN: Token → "词元" --%>{gettext("Input Tokens")}
                </div>
                <div class="text-sm font-semibold">
                  {format_number(Map.get(@usage, :input_tokens, 0))}
                </div>
              </div>
              <div>
                <div class="text-xs text-base-content/50 mb-1">
                  <%!-- zh_CN: Token → "词元" --%>{gettext("Output Tokens")}
                </div>
                <div class="text-sm font-semibold">
                  {format_number(Map.get(@usage, :output_tokens, 0))}
                </div>
              </div>
              <div>
                <div class="text-xs text-base-content/50 mb-1">
                  <%!-- zh_CN: Token → "词元" --%>{gettext("Total Tokens")}
                </div>
                <div class="text-sm font-semibold">
                  {format_number(Map.get(@usage, :total_tokens, 0))}
                </div>
              </div>
            </div>

            <%= if Map.get(@usage, :cached_tokens, 0) > 0 or Map.get(@usage, :cache_creation_tokens, 0) > 0 do %>
              <div class="mt-4 pt-4 border-t border-base-200">
                <div class="grid grid-cols-3 gap-3">
                  <div>
                    <div class="text-xs text-base-content/50 mb-1">
                      <%!-- zh_CN: Token → "词元" --%>{gettext("Cached Tokens")}
                    </div>
                    <div class="text-sm font-semibold">
                      {format_number(Map.get(@usage, :cached_tokens, 0))}
                    </div>
                  </div>
                  <div>
                    <div class="text-xs text-base-content/50 mb-1">
                      {gettext("Cache Creation")}
                    </div>
                    <div class="text-sm font-semibold">
                      {format_number(Map.get(@usage, :cache_creation_tokens, 0))}
                    </div>
                  </div>
                  <div>
                    <div class="text-xs text-base-content/50 mb-1">
                      {gettext("Cache Hit Rate")}
                    </div>
                    <div class="text-sm font-semibold text-success">
                      {format_cache_hit_rate(@usage)}
                    </div>
                    <progress
                      class="progress progress-success w-full mt-1"
                      value={
                        input_tokens = Map.get(@usage, :input_tokens, 0)
                        cached = Map.get(@usage, :cached_tokens, 0)
                        if input_tokens > 0,
                          do: min(round(cached / input_tokens * 100), 100),
                          else: 0
                      }
                      max="100"
                    ></progress>
                  </div>
                </div>
              </div>
            <% end %>

            <div class="mt-4 pt-4 border-t border-base-200">
              <div class="grid grid-cols-3 gap-3">
                <div>
                  <div class="text-xs text-base-content/50 mb-1">{gettext("Input Cost")}</div>
                  <div class="text-sm font-semibold">
                    ${format_cost(Map.get(@usage, :input_cost, 0))}
                  </div>
                </div>
                <div>
                  <div class="text-xs text-base-content/50 mb-1">{gettext("Output Cost")}</div>
                  <div class="text-sm font-semibold">
                    ${format_cost(Map.get(@usage, :output_cost, 0))}
                  </div>
                </div>
                <div>
                  <div class="text-xs text-base-content/50 mb-1">{gettext("Total Cost")}</div>
                  <div class="text-sm font-semibold text-primary">
                    ${format_cost(Map.get(@usage, :total_cost, 0))}
                  </div>
                </div>
              </div>
            </div>

            <%= if @agent_count do %>
              <div class="mt-4 pt-4 border-t border-base-200 flex items-center justify-between gap-2">
                <div class="flex items-center gap-2">
                  <span class="text-xs text-base-content/50 flex items-center gap-1">
                    <.icon name="hero-user-group" class="size-3.5" /> <%!-- zh_CN: Agent → "智能体" --%>{gettext(
                      "Agents Spawned"
                    )}
                  </span>
                  <span class="text-sm font-bold text-primary">{format_number(@agent_count)}</span>
                </div>
                <%= if @model_id do %>
                  <span class="text-xs font-medium text-base-content/50">
                    {gettext("Model")}: <span class="font-mono">{@model_id}</span>
                  </span>
                <% end %>
              </div>
            <% end %>
          </div>
        </details>
      <% end %>
    </div>
    """
  end

  # ---------------------------------------------------------------------------
  # agent_summary/1 — Static panel showing agent result (markdown/raw toggle)
  # ---------------------------------------------------------------------------

  attr(:summary, :string, required: true)
  attr(:summary_raw, :boolean, default: false)

  def agent_summary(assigns) do
    ~H"""
    <div class="bg-base-100 border-b border-base-200 ">
      <div class="relative">
        <!-- static header -->
        <div class="p-5 md:p-6 pr-44 flex items-center gap-4">
          <div class="bg-success/15 text-success p-2.5">
            <.icon name="hero-chat-bubble-left-ellipsis" class="size-5" />
          </div>
          <span class="font-semibold text-base-content/80">{gettext("Agent Summary")}</span>
        </div>
        <!-- content -->
        <div class="px-5 md:px-6 pb-5 md:pb-6">
          <%= if @summary_raw do %>
            <pre class="text-sm whitespace-pre-wrap break-words font-mono bg-base-200/30 p-4 rounded-lg border border-base-200">{@summary}</pre>
          <% else %>
            <div class="md-content text-sm leading-relaxed">
              {raw(EvoDash.MarkdownRender.render(@summary))}
            </div>
          <% end %>
        </div>
        <!-- Markdown / Raw toggle + copy button -->
        <div class="absolute top-3 right-3 z-10 flex items-center gap-1">
          <div class="flex gap-0">
            <button
              class={["btn btn-xs rounded-r-none border-base-300", !@summary_raw && "btn-active btn-primary"]}
              phx-click="toggle_summary_view"
              phx-value-mode="markdown"
              title={gettext("Rendered Markdown")}
            >
              <.icon name="hero-document-text" class="size-3.5" />
              {gettext("Markdown")}
            </button>
            <button
              class={["btn btn-xs rounded-l-none border-base-300", @summary_raw && "btn-active btn-primary"]}
              phx-click="toggle_summary_view"
              phx-value-mode="raw"
              title={gettext("Raw Text")}
            >
              <.icon name="hero-code-bracket" class="size-3.5" />
              {gettext("Raw")}
            </button>
          </div>
          <button
            id="summary-copy-btn"
            class="btn btn-ghost btn-sm btn-square"
            phx-hook="ClipboardCopy"
            data-content={@summary}
            title={gettext("Copy agent summary")}
          >
            <.icon name="hero-clipboard" class="size-4" />
          </button>
        </div>
      </div>
    </div>
    """
  end
end
