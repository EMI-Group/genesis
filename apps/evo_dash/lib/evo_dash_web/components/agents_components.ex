defmodule EvoDashWeb.AgentsComponents do
  use EvoDashWeb, :html

  attr :agents, :list, required: true
  attr :parent_id, :any, default: nil
  attr :depth, :integer, default: 0
  attr :selected_id, :any, default: nil

  def agent_tree(assigns) do
    ~H"""
    <%= for agent <- Enum.filter(@agents, &(&1.parent_id == @parent_id)) do %>
      <div class="relative">
        <!-- Tree connector lines -->
        <%= if @depth > 0 do %>
          <div class="absolute -left-4 top-0 bottom-0 w-px bg-base-300"></div>
          <div class="absolute -left-4 top-5 w-4 h-px bg-base-300"></div>
        <% end %>

        <!-- Agent row -->
        <div
          class={[
            "flex items-center gap-3 p-2 rounded-lg border-2 transition-all cursor-pointer hover:bg-base-200",
            agent_status_bg(agent.status),
            agent_status_border(agent.status),
            @selected_id == agent.id && "ring-2 ring-primary"
          ]}
          style={"padding-left: #{max(0, @depth * 24)}px"}
          phx-click="select_agent"
          phx-value-id={agent.id}
        >
          <!-- Expand/collapse icon if has children -->
          <div class="w-5 flex items-center justify-center">
            <%= if agent.has_children do %>
              <.icon name="hero-chevron-right" class="size-3" />
            <% else %>
              <.icon name="hero-minus" class="size-3 opacity-0" />
            <% end %>
          </div>

          <!-- Status icon -->
          <div class="w-6 h-6 rounded-full flex items-center justify-center">
            <.icon name={agent_status_icon(agent.status)} class={"size-4 #{agent_status_color(agent.status)}"} />
          </div>

          <!-- Agent info -->
          <div class="flex-1 min-w-0">
            <div class="flex items-center gap-2">
              <span class="font-semibold">#<%= agent.id %></span>
              <span class={["text-xs px-2 py-0.5 rounded", agent_status_color(agent.status), agent_status_bg(agent.status)]}>
                <%= String.upcase(to_string(agent.status)) %>
              </span>
              <%= if agent.retries > 0 do %>
                <span class="badge badge-warning badge-xs">Retry <%= agent.retries %></span>
              <% end %>
            </div>
            <div class="text-xs text-base-content/60 truncate mt-0.5">
              <%= format_module_name(agent.agent_module) %>
            </div>
          </div>

          <!-- Sub-agent count badge -->
          <%= if agent.has_children do %>
            <div class="badge badge-ghost badge-sm">
              <%= length(agent.children) %> child<%= if length(agent.children) != 1, do: "ren" %>
            </div>
          <% end %>
        </div>

        <!-- Recursively render children -->
        <EvoDashWeb.AgentsComponents.agent_tree
          agents={@agents}
          parent_id={agent.id}
          depth={@depth + 1}
          selected_id={@selected_id}
        />
      </div>
    <% end %>
    """
  end

  defp agent_status_color(:pending), do: "text-gray-500"
  defp agent_status_color(:running), do: "text-green-600"
  defp agent_status_color(:waiting), do: "text-yellow-600"
  defp agent_status_color(_), do: "text-gray-500"

  defp agent_status_bg(:pending), do: "bg-gray-50"
  defp agent_status_bg(:running), do: "bg-green-50"
  defp agent_status_bg(:waiting), do: "bg-yellow-50"
  defp agent_status_bg(_), do: "bg-gray-50"

  defp agent_status_border(:pending), do: "border-gray-300"
  defp agent_status_border(:running), do: "border-green-400"
  defp agent_status_border(:waiting), do: "border-yellow-400"
  defp agent_status_border(_), do: "border-gray-300"

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
