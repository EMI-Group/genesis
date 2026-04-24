defmodule EvoDashWeb.AgentsComponents do
  use EvoDashWeb, :html

  attr :agents, :list, required: true
  attr :parent_id, :any, default: nil
  attr :depth, :integer, default: 0
  attr :selected_id, :any, default: nil

  def agent_tree(assigns) do
    ~H"""
    <% filtered_agents = Enum.filter(@agents, &(&1.parent_id == @parent_id)) %>
    <% total_agents = length(filtered_agents) %>
    <%= for {agent, index} <- Enum.with_index(filtered_agents) do %>
      <% is_last = index == total_agents - 1 %>
      <div class={["relative", @depth > 0 && "ml-6"]}>
        <!-- Tree connector lines for nested items -->
        <%= if @depth > 0 do %>
          <!-- Vertical line -->
          <div class={["absolute -left-3 border-l-2 border-base-300 z-0", is_last && "top-0 h-8", !is_last && "top-0 bottom-0"]}></div>
          <!-- Horizontal line -->
          <div class="absolute -left-3 top-8 w-3 border-t-2 border-base-300 z-0"></div>
        <% end %>

        <!-- Agent row -->
        <div
          class={[
            "relative z-10 flex items-center gap-3 p-3 rounded-lg border-2 transition-all cursor-pointer hover:bg-base-200 my-1",
            agent_status_bg(agent.status),
            agent_status_border(agent.status),
            @selected_id == agent.id && "ring-2 ring-primary ring-offset-1"
          ]}
          phx-click="select_agent"
          phx-value-id={agent.id}
        >
          <!-- Expand/collapse icon if has children -->
          <div class="w-6 flex items-center justify-center shrink-0">
            <%= if agent.has_children do %>
              <.icon name="hero-chevron-right" class="size-4 text-base-content/50" />
            <% else %>
              <span class="w-4 h-4"></span>
            <% end %>
          </div>

          <!-- Status icon -->
          <div class="w-8 h-8 rounded-full flex items-center justify-center shrink-0 bg-base-200">
            <.icon name={agent_status_icon(agent.status)} class={"size-5 #{agent_status_color(agent.status)}"} />
          </div>

          <!-- Agent info -->
          <div class="flex-1 min-w-0">
            <div class="flex items-center gap-2 flex-wrap">
              <span class="font-semibold text-base">#<%= agent.id %></span>
              <span class={["text-xs px-2 py-0.5 rounded-full font-medium", agent_status_color(agent.status), agent_status_bg(agent.status)]}>
                <%= String.upcase(to_string(agent.status)) %>
              </span>
              <%= if agent.retries > 0 do %>
                <span class="badge badge-warning badge-xs">Retry <%= agent.retries %></span>
              <% end %>
            </div>
            <div class="text-sm text-base-content/70 truncate mt-1">
              <%= format_module_name(agent.agent_module) %>
            </div>
          </div>

          <!-- Subagent count badge -->
          <%= if agent.has_children do %>
            <div class="badge badge-ghost badge-sm shrink-0">
              <%= length(agent.children) %> child<%= if length(agent.children) != 1, do: "ren" %>
            </div>
          <% end %>
        </div>

        <!-- Children container with proper spacing -->
        <%= if agent.has_children do %>
          <div class="mt-1 space-y-1 relative">
            <EvoDashWeb.AgentsComponents.agent_tree
              agents={@agents}
              parent_id={agent.id}
              depth={@depth + 1}
              selected_id={@selected_id}
            />
          </div>
        <% end %>
      </div>
    <% end %>
    """
  end

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
