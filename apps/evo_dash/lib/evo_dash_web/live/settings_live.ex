defmodule EvoDashWeb.SettingsLive do
  use EvoDashWeb, :live_view

  @impl true
  def render(assigns) do
    ~H"""
    <EvoDashWeb.Layouts.app flash={@flash} current_page={:settings} config_status={@config_status}>
      <div class="flex items-center gap-3 mb-2 animate-fade-in-up">
        <div class="bg-secondary/15 text-secondary p-3 rounded-xl">
          <.icon name="hero-cog-6-tooth" class="size-6" />
        </div>
        <div>
          <h1 class="text-xl font-bold">{gettext("Scheduler Settings")}</h1>
          <p class="text-sm text-base-content/60">{gettext("Runtime configuration for agent execution")}</p>
        </div>
      </div>

      <!-- Scheduler Pause/Resume Control -->
      <div class="mt-4 bg-base-100 rounded-2xl shadow-lg border border-base-200 overflow-hidden animate-fade-in-up animation-delay-100">
        <div class="p-5 flex flex-col sm:flex-row sm:items-center sm:justify-between gap-3 sm:gap-4">
          <div class="flex items-center gap-3">
            <div class={[
              "p-3 rounded-xl",
              if(@scheduler_paused, do: "bg-warning/15 text-warning", else: "bg-success/15 text-success")
            ]}>
              <.icon name={if @scheduler_paused, do: "hero-pause-circle", else: "hero-play-circle"} class="size-6" />
            </div>
            <div>
              <h2 class="text-base font-bold">
                {if @scheduler_paused, do: gettext("Scheduler Paused"), else: gettext("Scheduler Active")}
              </h2>
              <p class="text-xs text-base-content/60">
                <%= if @scheduler_paused do %>
                  {gettext("Running agents continue. No new slots or agents will be granted until resumed.")}
                <% else %>
                  {gettext("Agents and slots are being granted normally.")}
                <% end %>
              </p>
            </div>
          </div>
          <button
            phx-click="toggle_pause"
            class={[
              "btn",
              if(@scheduler_paused, do: "btn-success", else: "btn-warning")
            ]}
          >
            <.icon name={if @scheduler_paused, do: "hero-play", else: "hero-pause"} class="size-4" />
            {if @scheduler_paused, do: gettext("Resume Scheduler"), else: gettext("Pause Scheduler")}
          </button>
        </div>
      </div>

      <!-- Config Status Warning -->
      <%= if not @config_status.ok? do %>
        <div class="mt-4 bg-warning/10 border border-warning/20 rounded-xl p-4">
          <h3 class="font-semibold text-warning flex items-center gap-2 mb-2">
            <.icon name="hero-exclamation-triangle" class="size-5" /> {gettext("Missing Configuration")}
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
            {gettext("Visit the")} <a href="/help" class="link link-primary">{gettext("Help & Config")}</a> {gettext("page to set up your configuration.")}
          </p>
        </div>
      <% end %>

      <!-- Scheduler Settings Form -->
      <div class="mt-6 animate-fade-in-up animation-delay-200">
        <EvoDashWeb.DashboardComponents.scheduler_settings config={@scheduler_config} />
      </div>

      <!-- Current Config Summary -->
      <div class="mt-6 bg-base-100 rounded-2xl shadow-lg border border-base-200 overflow-hidden animate-fade-in-up animation-delay-300">
        <div class="bg-gradient-to-br from-base-200/50 via-base-200/20 to-transparent p-4 sm:p-6">
          <h2 class="text-lg font-semibold flex items-center gap-2">
            <.icon name="hero-information-circle" class="size-5 text-info" /> {gettext("Current Runtime Values")}
          </h2>
        </div>
        <div class="p-4 sm:p-6 pt-2">
          <div class="grid grid-cols-1 sm:grid-cols-2 lg:grid-cols-3 gap-3 sm:gap-4">
            <%= for {label, key, value} <- [
              {gettext("Status"), :paused, @scheduler_paused},
              {gettext("LLM Concurrency"), :max_concurrency, @scheduler_config[:max_concurrency]},
              {gettext("Tool Concurrency"), :max_tool_concurrency, @scheduler_config[:max_tool_concurrency]},
              {gettext("Agent Max Retries"), :agent_max_retries, @scheduler_config[:agent_max_retries]},
              {gettext("Max Depth"), :max_agent_depth, @scheduler_config[:max_agent_depth]},
              {gettext("LLM Retries"), :max_retries, @scheduler_config[:max_retries]},
              {gettext("LLM Model"), :llm_model, @scheduler_config[:llm_model]}
            ] do %>
              <div class="bg-base-200/40 rounded-lg p-3 border border-base-200">
                <p class="text-xs text-base-content/50 font-medium uppercase tracking-wide">{label}</p>
                <p class="text-sm font-mono mt-1">
                  <%= case value do %>
                    <% true -> %><span class="text-warning font-bold">{gettext("Paused")}</span>
                    <% false -> %><span class="text-success font-bold">{gettext("Active")}</span>
                    <% nil -> %><span class="text-base-content/30">{gettext("Not set")}</span>
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
      |> assign(:scheduler_paused, load_paused_state())
      |> assign(:config_status, config_status)

    {:ok, socket}
  end

  @impl true
  def handle_info(:refresh_config, socket) do
    {:noreply,
     socket
     |> assign(:scheduler_config, load_scheduler_config())
     |> assign(:scheduler_paused, load_paused_state())}
  end

  @impl true
  def handle_event("scheduler_config_change", _params, socket) do
    {:noreply, socket}
  end

  @impl true
  def handle_event("toggle_pause", _params, socket) do
    if socket.assigns.scheduler_paused do
      EvoGit.AgentScheduler.resume()
      {:noreply,
       socket
       |> assign(:scheduler_paused, false)
       |> put_flash(:info, gettext("Scheduler resumed. New agents and slots are being granted."))}
    else
      EvoGit.AgentScheduler.pause()
      {:noreply,
       socket
       |> assign(:scheduler_paused, true)
       |> put_flash(:info, gettext("Scheduler paused. Running agents continue, but no new slots or agents will be granted."))}
    end
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
         |> put_flash(:info, gettext("Scheduler settings updated successfully."))}

      {:error, :agents_running} ->
        {:noreply,
         socket
         |> put_flash(
           :error,
           gettext("Cannot update concurrency while agents are running. Other settings applied.")
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

  defp load_paused_state do
    try do
      EvoGit.AgentScheduler.get_config()[:paused] || false
    rescue
      _ -> false
    catch
      _, _ -> false
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
