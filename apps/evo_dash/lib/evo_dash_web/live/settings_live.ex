defmodule EvoDashWeb.SettingsLive do
  use EvoDashWeb, :live_view

  @impl true
  def render(assigns) do
    ~H"""
    <EvoDashWeb.Layouts.app flash={@flash} current_page={:settings} config_status={@config_status}>
      <div class="flex items-center gap-3 mb-2">
        <div class="bg-secondary/15 text-secondary p-3 rounded-xl">
          <.icon name="hero-cog-6-tooth" class="size-6" />
        </div>
        <div>
          <h1 class="text-xl font-bold">Scheduler Settings</h1>
          <p class="text-sm text-base-content/60">Runtime configuration for agent execution</p>
        </div>
      </div>

      <!-- Config Status Warning -->
      <%= if not @config_status.ok? do %>
        <div class="mt-4 bg-warning/10 border border-warning/20 rounded-xl p-4">
          <h3 class="font-semibold text-warning flex items-center gap-2 mb-2">
            <.icon name="hero-exclamation-triangle" class="size-5" /> Missing Configuration
          </h3>
          <ul class="space-y-1">
            <%= for warning <- @config_status.warnings do %>
              <li class="text-sm text-warning/80 flex items-start gap-2">
                <.icon name="hero-chevron-right" class="size-4 mt-0.5 shrink-0" />
                <span>{warning}</span>
              </li>
            <% end %>
          </ul>
          <p class="text-xs text-base-content/50 mt-2">
            Visit the <a href="/help" class="link link-primary">Help &amp; Config</a> page to set up your configuration.
          </p>
        </div>
      <% end %>

      <!-- Scheduler Settings Form -->
      <div class="mt-6">
        <EvoDashWeb.DashboardComponents.scheduler_settings config={@scheduler_config} />
      </div>

      <!-- Current Config Summary -->
      <div class="mt-6 bg-base-100 rounded-2xl shadow-lg border border-base-200 overflow-hidden">
        <div class="bg-gradient-to-br from-base-200/50 via-base-200/20 to-transparent p-6">
          <h2 class="text-lg font-semibold flex items-center gap-2">
            <.icon name="hero-information-circle" class="size-5 text-info" /> Current Runtime Values
          </h2>
        </div>
        <div class="p-6 pt-2">
          <div class="grid grid-cols-1 sm:grid-cols-2 lg:grid-cols-3 gap-4">
            <%= for {label, key, value} <- [
              {"LLM Concurrency", :max_concurrency, @scheduler_config[:max_concurrency]},
              {"Tool Concurrency", :max_tool_concurrency, @scheduler_config[:max_tool_concurrency]},
              {"Agent Max Retries", :agent_max_retries, @scheduler_config[:agent_max_retries]},
              {"Max Depth", :max_agent_depth, @scheduler_config[:max_agent_depth]},
              {"LLM Retries", :max_retries, @scheduler_config[:max_retries]},
              {"LLM Model", :llm_model, @scheduler_config[:llm_model]}
            ] do %>
              <div class="bg-base-200/40 rounded-lg p-3 border border-base-200">
                <p class="text-xs text-base-content/50 font-medium uppercase tracking-wide">{label}</p>
                <p class="text-sm font-mono mt-1">
                  <%= case value do %>
                    <% nil -> %><span class="text-base-content/30">Not set</span>
                    <% v -> %><span>{v}</span>
                  <% end %>
                </p>
              </div>
            <% end %>
          </div>
        </div>
      </div>
    </EvoDashWeb.Layouts.app>
    """
  end

  @impl true
  def mount(_params, _session, socket) do
    if connected?(socket) do
      :timer.send_interval(2000, self(), :refresh_config)
    end

    config_status =
      try do
        EvoGit.Config.config_status()
      rescue
        _ -> %{missing: [], warnings: [], ok?: true}
      catch
        _, _ -> %{missing: [], warnings: [], ok?: true}
      end

    socket =
      socket
      |> assign(:scheduler_config, load_scheduler_config())
      |> assign(:config_status, config_status)

    {:ok, socket}
  end

  @impl true
  def handle_info(:refresh_config, socket) do
    {:noreply, assign(socket, :scheduler_config, load_scheduler_config())}
  end

  @impl true
  def handle_event("scheduler_config_change", _params, socket) do
    {:noreply, socket}
  end

  @impl true
  def handle_event("update_scheduler_config", params, socket) do
    config_updates =
      []
      |> maybe_add_int(:max_concurrency, params["max_concurrency"])
      |> maybe_add_int(:max_tool_concurrency, params["max_tool_concurrency"])
      |> maybe_add_int(:agent_max_retries, params["agent_max_retries"])
      |> maybe_add_int(:max_depth, params["max_agent_depth"])
      |> maybe_add_int(:max_retries, params["max_retries"])
      |> maybe_add_string(:llm_model, params["llm_model"])

    case EvoGit.AgentScheduler.update_config(config_updates) do
      :ok ->
        {:noreply,
         socket
         |> assign(:scheduler_config, load_scheduler_config())
         |> put_flash(:info, "Scheduler settings updated successfully.")}

      {:error, :agents_running} ->
        {:noreply,
         socket
         |> put_flash(
           :error,
           "Cannot update concurrency while agents are running. Other settings applied."
         )}
    end
  end

  # Helpers

  defp load_scheduler_config do
    try do
      EvoGit.AgentScheduler.get_config()
    rescue
      _ -> %{}
    catch
      _, _ -> %{}
    end
  end

  defp maybe_add_int(list, key, value) when is_binary(value) do
    case Integer.parse(value) do
      {int, ""} -> Keyword.put(list, key, int)
      _ -> list
    end
  end

  defp maybe_add_int(list, _key, _value), do: list

  defp maybe_add_string(list, key, value) when is_binary(value) and value != "" do
    Keyword.put(list, key, value)
  end

  defp maybe_add_string(list, _key, _value), do: list
end
