defmodule EvoDashWeb.AgentsComponents do
  use EvoDashWeb, :html

  attr :nodes, :list, required: true
  attr :depth, :integer, default: 0
  attr :selected_id, :any, default: nil
  attr :max_width, :integer, default: nil

  def path_tree(assigns) do
    assigns =
      if assigns.depth == 0 and is_nil(assigns.max_width) do
        assign(assigns, :max_width, calculate_max_width(assigns.nodes))
      else
        assigns
      end

    ~H"""
    <% total_nodes = length(@nodes) %>
    <%= for {node, index} <- Enum.with_index(@nodes) do %>
      <% is_last = index == total_nodes - 1 %>
      <div class={["relative", @depth > 0 && "ml-6"]}>
        <!-- Tree connector lines for nested items -->
        <%= if @depth > 0 do %>
          <!-- Vertical line -->
          <div class={[
            "absolute -left-3 border-l-2 border-base-300 z-0",
            is_last && "top-0 h-6",
            !is_last && "top-0 bottom-0"
          ]}>
          </div>
          <!-- Horizontal line -->
          <div class="absolute -left-3 top-6 w-3 border-t-2 border-base-300 z-0"></div>
        <% end %>
        
    <!-- Path and Agents Row -->
        <div class="relative z-10 flex flex-col sm:flex-row sm:items-start gap-4 py-2">
          <!-- Path info -->
          <div class="flex items-center gap-2 mt-2 shrink-0" style={"width: #{@max_width}ch; max-width: 100%;"}>
            <.icon name="hero-folder" class="size-5 text-base-content/50 shrink-0" />
            <span class="font-semibold text-base-content truncate min-w-0" title={node.name}>{node.name}</span>
            <%= if length(node.agents) > 0 do %>
              <div class="grow border-b-2 border-dotted border-base-300 opacity-50 ml-1 mr-2"></div>
            <% end %>
          </div>
          
    <!-- Agents Row -->
          <%= if length(node.agents) > 0 do %>
            <div class="flex flex-wrap gap-2 flex-1 mt-1 sm:mt-0">
              <%= for agent <- node.agents do %>
                <div
                  class={[
                    "flex flex-col gap-1 p-2 rounded-lg border-2 shadow-sm transition-all cursor-pointer hover:bg-base-200 min-w-[140px]",
                    agent_status_bg(agent.status),
                    agent_status_border(agent.status),
                    @selected_id == agent.id && "ring-2 ring-primary ring-offset-1"
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
                      <span class="font-bold text-sm">#{agent.id}</span>
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
                    <%= if agent.retries > 0 do %>
                      <span class="badge badge-warning badge-xs">Retry {agent.retries}</span>
                    <% end %>
                  </div>

                  <%= if agent.has_children do %>
                    <div class="text-[10px] text-base-content/50">
                      {length(agent.children)} child{if length(agent.children) != 1, do: "ren"}
                    </div>
                  <% end %>
                </div>
              <% end %>
            </div>
          <% end %>
        </div>
        
    <!-- Children container with proper spacing -->
        <%= if length(node.children) > 0 do %>
          <div class="mt-1 space-y-1 relative">
            <EvoDashWeb.AgentsComponents.path_tree
              nodes={node.children}
              depth={@depth + 1}
              selected_id={@selected_id}
              max_width={@max_width}
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
      my_width = (depth * 4) + String.length(node.name) + 8
      child_width = calculate_max_width(node.children, depth + 1)
      max(my_width, child_width)
    end)
    |> Enum.max(fn -> 15 end)
  end

  defp calculate_max_width(nodes), do: calculate_max_width(nodes, 0)

  defp agent_status_color(:pending), do: "text-base-content/70"
  defp agent_status_color(:running), do: "text-success"
  defp agent_status_color(:waiting), do: "text-warning"
  defp agent_status_color(_), do: "text-base-content/70"

  defp agent_status_bg(:pending), do: "bg-base-100"
  defp agent_status_bg(:running), do: "bg-success/10"
  defp agent_status_bg(:waiting), do: "bg-warning/10"
  defp agent_status_bg(_), do: "bg-base-100"

  defp agent_status_border(:pending), do: "border-base-300"
  defp agent_status_border(:running), do: "border-success/30"
  defp agent_status_border(:waiting), do: "border-warning/30"
  defp agent_status_border(_), do: "border-base-300"

  defp agent_status_icon(:pending), do: "hero-clock"
  defp agent_status_icon(:running), do: "hero-play-circle"
  defp agent_status_icon(:waiting), do: "hero-pause-circle"
  defp agent_status_icon(_), do: "hero-question-mark-circle"

  defp format_module_name(module) when is_atom(module) do
    module
    |> Atom.to_string()
    |> String.split(".")
    |> List.last()
  end

  defp format_module_name(_), do: "Unknown"
end
