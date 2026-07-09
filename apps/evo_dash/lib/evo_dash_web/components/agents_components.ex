defmodule EvoDashWeb.AgentsComponents do
  @moduledoc """
  LiveView components for rendering the recursive agent path tree with
  connector lines and per-node status coloring.
  """
  use EvoDashWeb, :html
  use Gettext, backend: EvoDashWeb.Gettext

  attr(:nodes, :list, required: true)
  attr(:depth, :integer, default: 0)
  attr(:selected_id, :any, default: nil)
  attr(:max_width, :integer, default: nil)
  attr(:new_agent_ids, :any, default: MapSet.new())
  attr(:changed_status_ids, :any, default: MapSet.new())

  def path_tree(assigns) do
    assigns =
      if assigns.depth == 0 and is_nil(assigns.max_width) do
        assign(assigns, :max_width, calculate_max_width(assigns.nodes))
      else
        assigns
      end

    ~H"""
    <%= for {node, index} <- Enum.with_index(@nodes) do %>
      <% is_last = index == length(@nodes) - 1 %>
      <div class="relative">
        <%= if @depth > 0 do %>
          <%!-- Vertical trunk line: full height for non-last, partial (to connector) for last child --%>
          <div
            class={[
              "absolute top-0 border-l-2 border-base-content/10 z-0",
              "left-2 sm:left-3 lg:left-4",
              is_last && "h-6",
              !is_last && "bottom-0"
            ]}
          >
          </div>
          <%!-- Horizontal connector from trunk to content --%>
          <div
            class={[
              "absolute top-6 border-t-2 border-base-content/10 z-0",
              "left-2 sm:left-3 lg:left-4 w-3 sm:w-5 lg:w-6"
            ]}
          >
          </div>
        <% end %>

        <!-- Content row — indented to clear connectors -->
        <div class={@depth > 0 && "pl-5 sm:pl-8 lg:pl-10"}>
          <!-- Path and Agents Row -->
          <div class="relative z-10 flex flex-col sm:flex-row sm:items-start gap-3 py-1">
            <!-- Path info -->
            <div class="flex items-center gap-2 mt-1 shrink-0" style={"width: #{@max_width}ch; max-width: 100%;"}>
              <.icon name="hero-folder" class="size-5 text-base-content/50 shrink-0" />
              <span class="font-semibold text-base-content truncate min-w-0" title={node.name}>{node.name}</span>
              <%= if length(node.agents) > 0 do %>
                <div class="grow border-b-2 border-dotted border-base-content/10 ml-1 mr-2"></div>
              <% end %>
            </div>

            <!-- Agents Row -->
            <%= if length(node.agents) > 0 do %>
              <div class="flex flex-wrap gap-2 flex-1 mt-1 sm:mt-0">
                <%= for agent <- node.agents do %>
                  <div
                    id={"agent-card-#{agent.id}"}
                    class={[
                      "flex flex-col gap-1 p-2 rounded-xl border shadow-sm transition-all cursor-pointer hover:bg-base-200/80 min-w-[120px] sm:min-w-[140px]",
                      agent_status_bg(agent.status),
                      agent_status_border(agent.status),
                      @selected_id == agent.id && "ring-2 ring-primary ring-offset-1",
                      agent.status == :running && "agent-card-running",
                      agent.status == :running && "animate-pulse-glow",
                      MapSet.member?(@new_agent_ids, agent.id) && "animate-agent-spawn",
                      MapSet.member?(@changed_status_ids, agent.id) && "animate-status-bounce"
                    ]}
                    phx-click="select_agent"
                    phx-value-id={agent.id}
                  >
                    <div class="flex items-center gap-2 justify-between">
                      <div class="flex items-center gap-1.5">
                        <.icon
                          name={agent_status_icon(agent.status)}
                          class={"size-4 #{agent_status_color(agent.status)}"}
                        />
                        <span class="font-bold text-sm">#<%= agent.task_local_id || agent.id %></span>
                      </div>
                      <span class={[
                        "text-[10px] px-1.5 py-0.5 rounded uppercase font-bold",
                        agent_status_color(agent.status),
                        agent_status_bg(agent.status)
                      ]}>
                        {agent.status}
                      </span>
                    </div>

                    <div class="flex items-center justify-between gap-2">
                      <div class="text-xs text-base-content/70 truncate">
                        {format_module_name(agent.agent_module)}
                      </div>
                      <div class="flex items-center gap-1">
                        <span class="text-[10px] text-base-content/40 font-mono" title={"Task ##{agent.task_number || agent.task_id}"}>T{agent.task_number || agent.task_id}</span>
                        <%= if agent.retries > 0 do %>
                          <span class="badge badge-warning badge-sm">Retry {agent.retries}</span>
                        <% end %>
                      </div>
                    </div>

                    <%= if agent.has_children do %>
                      <div class="text-[10px] text-base-content/50">
                        {dngettext("default", "%{count} child", "%{count} children", length(agent.children), count: length(agent.children))}
                      </div>
                    <% end %>
                  </div>
                <% end %>
              </div>
            <% end %>
          </div>
        </div>

        <!-- Children container (recursive) — no container-level trunk line -->
        <%= if length(node.children) > 0 do %>
          <div class="space-y-1 relative">
            <EvoDashWeb.AgentsComponents.path_tree
              nodes={node.children}
              depth={@depth + 1}
              selected_id={@selected_id}
              max_width={@max_width}
              new_agent_ids={@new_agent_ids}
              changed_status_ids={@changed_status_ids}
            />
          </div>
        <% end %>
      </div>
    <% end %>
    """
  end

  defp calculate_max_width([], _depth), do: 15

  defp calculate_max_width(nodes, depth) do
    nodes
    |> Enum.map(fn node ->
      my_width = depth * 4 + String.length(node.name) + 8
      child_width = calculate_max_width(node.children, depth + 1)
      max(my_width, child_width)
    end)
    |> Enum.max(fn -> 15 end)
  end

  defp calculate_max_width(nodes), do: calculate_max_width(nodes, 0)
end
