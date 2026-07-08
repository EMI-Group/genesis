defmodule EvoDashWeb.ArchiveComponents do
  @moduledoc """
  Archive components for the dashboard — per-agent archive records,
  nested agent hierarchy tree, and recursive node renderer.
  """

  # zh_CN: Agent → "智能体", Commit → "提交", Branch → "分支", Token → "词元"

  use EvoDashWeb, :html
  alias EvoDashWeb.ArchiveHelpers

  # ---------------------------------------------------------------------------
  # archive_details/1 — Per-agent archive records section (opt-in)
  # ---------------------------------------------------------------------------

  attr(:archive_metadata, :list, default: nil)
  attr(:task_id, :string, default: nil)

  def archive_details(assigns) do
    ~H"""
    <%= if @archive_metadata != nil and @archive_metadata != [] do %>
      <div class="bg-base-200/30 p-5 rounded-2xl border border-base-200/80 hover:border-base-300 transition-colors">
        <div class="flex items-center justify-between mb-4">
          <h4 class="text-sm font-bold flex items-center gap-2">
            <.icon name="hero-archive-box" class="size-4.5 text-primary" /> <%!-- zh_CN: Agent → "智能体" --%>{gettext(
              "Archived Agent Details"
            )}
          </h4>
          <%= if @task_id do %>
            <.link
              href={"/tasks/#{@task_id}/export"}
              class="btn btn-sm btn-outline btn-primary rounded-full"
              download
            >
              <.icon name="hero-arrow-down-tray" class="size-4 mr-1" /> {gettext("Export JSON")}
            </.link>
          <% end %>
        </div>
        <.archive_tree agents={@archive_metadata} />
      </div>
    <% end %>
    """
  end

  # ---------------------------------------------------------------------------
  # archive_tree/1 — Renders the nested parent-child agent hierarchy
  # ---------------------------------------------------------------------------

  attr(:agents, :list, required: true)

  def archive_tree(assigns) do
    roots = ArchiveHelpers.build_archive_tree(assigns.agents)
    assigns = assign(assigns, :roots, roots)

    ~H"""
    <div class="space-y-3">
      <%= for node <- @roots do %>
        <.archive_tree_node agent={node.agent} children={node.children} />
      <% end %>
    </div>
    """
  end

  # ---------------------------------------------------------------------------
  # archive_tree_node/1 — Recursive node renderer for a single archived agent
  # ---------------------------------------------------------------------------

  attr(:agent, :map, required: true)
  attr(:children, :list, default: [])

  def archive_tree_node(assigns) do
    ~H"""
    <div class="border border-base-200 rounded-xl bg-base-100/60 overflow-hidden">
      <div class="p-4 space-y-3">
        <!-- Agent ID + depth badge -->
        <div class="flex items-center gap-2 flex-wrap">
          <span class="font-bold font-mono text-sm text-base-content">{@agent[:agent_id]}</span>
          <%= if @agent[:depth] do %>
            <span class="badge badge-ghost badge-sm font-mono">{gettext("Depth")}: {@agent[:depth]}</span>
          <% end %>
        </div>

        <!-- Objective -->
        <%= if @agent[:objective] not in [nil, ""] do %>
          <div>
            <div class="text-xs text-base-content/50 mb-0.5">{gettext("Objective")}</div>
            <div class="text-sm text-base-content/90 whitespace-pre-wrap break-words">
              {@agent[:objective]}
            </div>
          </div>
        <% end %>

        <!-- Result -->
        <%= if @agent[:result] not in [nil, ""] do %>
          <div>
            <div class="text-xs text-base-content/50 mb-0.5">{gettext("Result")}</div>
            <div class="text-sm text-base-content/90 whitespace-pre-wrap break-words">
              {@agent[:result]}
            </div>
          </div>
        <% end %>

        <!-- Commits -->
        <div class="flex flex-wrap gap-x-6 gap-y-1">
          <%= if @agent[:base_commit] not in [nil, ""] do %>
            <div>
              <%!-- zh_CN: Commit → "提交" --%><span class="text-xs text-base-content/50">{gettext("Start Commit")}: </span>
              <span class="text-xs font-mono">{@agent[:base_commit]}</span>
            </div>
          <% end %>
          <%= if @agent[:final_commit] not in [nil, ""] do %>
            <div>
              <%!-- zh_CN: Commit → "提交" --%><span class="text-xs text-base-content/50">{gettext("End Commit")}: </span>
              <span class="text-xs font-mono">{@agent[:final_commit]}</span>
            </div>
          <% end %>
        </div>

        <!-- Archive refs -->
        <div class="flex flex-wrap gap-x-6 gap-y-1">
          <%= if @agent[:archive_ref_start] not in [nil, ""] do %>
            <div>
              <span class="text-xs text-base-content/50">{gettext("Archive Start Ref")}: </span>
              <span class="text-xs font-mono">{@agent[:archive_ref_start]}</span>
            </div>
          <% end %>
          <%= if @agent[:archive_ref_final] not in [nil, ""] do %>
            <div>
              <span class="text-xs text-base-content/50">{gettext("Archive Final Ref")}: </span>
              <span class="text-xs font-mono">{@agent[:archive_ref_final]}</span>
            </div>
          <% end %>
        </div>

        <%= if @agent[:branch_name] not in [nil, ""] do %>
          <div>
            <%!-- zh_CN: Branch → "分支" --%><span class="text-xs text-base-content/50">{gettext("Branch")}: </span>
            <span class="text-xs font-mono">{@agent[:branch_name]}</span>
          </div>
        <% end %>

        <!-- Token usage -->
        <%= if @agent[:usage] do %>
          <div class="grid grid-cols-2 sm:grid-cols-4 gap-2 pt-2 border-t border-base-200">
            <div>
              <%!-- zh_CN: Token → "词元" --%><div class="text-xs text-base-content/50">{gettext("Input Tokens")}</div>
              <div class="text-sm font-semibold">
                {format_number(@agent[:usage][:input_tokens] || 0)}
              </div>
            </div>
            <div>
              <%!-- zh_CN: Token → "词元" --%><div class="text-xs text-base-content/50">{gettext("Output Tokens")}</div>
              <div class="text-sm font-semibold">
                {format_number(@agent[:usage][:output_tokens] || 0)}
              </div>
            </div>
            <div>
              <%!-- zh_CN: Token → "词元" --%><div class="text-xs text-base-content/50">{gettext("Total Tokens")}</div>
              <div class="text-sm font-semibold">
                {format_number(@agent[:usage][:total_tokens] || 0)}
              </div>
            </div>
            <div>
              <div class="text-xs text-base-content/50">{gettext("Cost")}</div>
              <div class="text-sm font-semibold">${format_cost(@agent[:usage][:cost] || 0)}</div>
            </div>
          </div>
        <% end %>

        <!-- Timestamps -->
        <%= if @agent[:started_at] || @agent[:completed_at] do %>
          <div class="flex flex-wrap gap-x-6 gap-y-1 pt-2 border-t border-base-200">
            <%= if @agent[:started_at] do %>
              <div>
                <span class="text-xs text-base-content/50">{gettext("Started")}: </span>
                <span class="text-xs">{format_datetime(@agent[:started_at])}</span>
              </div>
            <% end %>
            <%= if @agent[:completed_at] do %>
              <div>
                <span class="text-xs text-base-content/50">{gettext("Completed")}: </span>
                <span class="text-xs">{format_datetime(@agent[:completed_at])}</span>
              </div>
            <% end %>
          </div>
        <% end %>
      </div>

      <%= if @children != [] do %>
        <div class="pl-5 border-l-2 border-base-200 ml-4 space-y-3 mb-3">
          <%= for child <- @children do %>
            <.archive_tree_node agent={child.agent} children={child.children} />
          <% end %>
        </div>
      <% end %>
    </div>
    """
  end
end
