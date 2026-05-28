defmodule EvoDashWeb.HelpLive do
  use EvoDashWeb, :live_view

  @impl true
  def render(assigns) do
    ~H"""
    <EvoDashWeb.Layouts.app flash={@flash} current_page={:help}>
      <div class="flex items-center gap-3 mb-2">
        <div class="bg-accent/15 text-accent p-3 rounded-xl">
          <.icon name="hero-question-mark-circle" class="size-6" />
        </div>
        <div>
          <h1 class="text-xl font-bold">Help & Configuration</h1>
          <p class="text-sm text-base-content/60">Manage your EvoGit configuration files</p>
        </div>
      </div>

      <!-- Config Status -->
      <div class="mt-4">
        <%= if @config_status.ok? do %>
          <div class="bg-success/10 border border-success/20 rounded-xl p-4 flex items-center gap-3">
            <.icon name="hero-check-circle" class="size-5 text-success shrink-0" />
            <div>
              <p class="font-semibold text-success">All configured</p>
              <p class="text-xs text-success/70">All critical configuration values are set</p>
            </div>
          </div>
        <% else %>
          <div class="bg-warning/10 border border-warning/20 rounded-xl p-4">
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
          </div>
        <% end %>
      </div>

      <!-- Config File Locations -->
      <div class="mt-6 bg-base-100 rounded-2xl shadow-lg border border-base-200 overflow-hidden">
        <div class="bg-gradient-to-br from-base-200/50 via-base-200/20 to-transparent p-6">
          <h2 class="text-lg font-semibold flex items-center gap-2">
            <.icon name="hero-folder" class="size-5 text-primary" /> Configuration Files
          </h2>
        </div>
        <div class="p-6 pt-2 space-y-3">
          <%= for {label, path, exists} <- [
            {"Config Directory", @config_dir, File.dir?(@config_dir)},
            {"Config File", @config_path, File.exists?(@config_path)},
            {"Credentials File", @credentials_path, File.exists?(@credentials_path)}
          ] do %>
            <div class="flex items-center gap-3 bg-base-200/40 rounded-lg p-3 border border-base-200">
              <%= if exists do %>
                <.icon name="hero-check-circle" class="size-5 text-success shrink-0" />
              <% else %>
                <.icon name="hero-x-circle" class="size-5 text-error shrink-0" />
              <% end %>
              <div class="flex-1 min-w-0">
                <p class="text-xs text-base-content/50 font-medium uppercase tracking-wide">{label}</p>
                <p class="text-sm font-mono truncate">{path}</p>
              </div>
              <span class={["badge badge-sm", exists && "badge-success", not exists && "badge-ghost"]}>
                <%= if exists, do: "Exists", else: "Missing" %>
              </span>
            </div>
          <% end %>
        </div>
      </div>

      <!-- User Config Editor -->
      <div class="mt-6 bg-base-100 rounded-2xl shadow-lg border border-base-200 overflow-hidden">
        <div class="bg-gradient-to-br from-primary/10 via-primary/5 to-transparent p-6">
          <div class="flex items-center justify-between">
            <h2 class="text-lg font-semibold flex items-center gap-2">
              <.icon name="hero-document-text" class="size-5 text-primary" /> User Configuration
            </h2>
            <div class="flex gap-2">
              <%= if @editing do %>
                <button class="btn btn-sm btn-ghost" phx-click="cancel_edit">
                  <.icon name="hero-x-mark" class="size-4" /> Cancel
                </button>
                <button class="btn btn-sm btn-primary" phx-click="save_config">
                  <.icon name="hero-check" class="size-4" /> Save
                </button>
              <% else %>
                <button class="btn btn-sm btn-primary" phx-click="edit_config">
                  <.icon name="hero-pencil" class="size-4" /> Edit Config
                </button>
              <% end %>
            </div>
          </div>
        </div>
        <div class="p-6 pt-2">
          <%= if @editing do %>
            <div class="form-control">
              <textarea
                name="config_text"
                class="textarea textarea-bordered w-full font-mono text-sm min-h-[300px] bg-base-200/30 focus:outline-none focus:ring-2 focus:ring-primary/30"
                phx-change="config_text_change"
                phx-debounce="300"
              ><%= @config_edit %></textarea>
              <label class="label">
                <span class="label-text-alt text-base-content/50">Editing: <%= @config_path %></span>
              </label>
            </div>
          <% else %>
            <div class="bg-base-200/30 rounded-lg p-4 border border-base-200">
              <%= if @config_toml_content != "" do %>
                <pre class="text-sm font-mono whitespace-pre-wrap break-words max-h-[400px] overflow-y-auto"><%= @config_toml_content %></pre>
              <% else %>
                <div class="text-center py-8 text-base-content/40">
                  <.icon name="hero-document-plus" class="size-10 mx-auto mb-2 opacity-50" />
                  <p class="text-sm">No config file found. Click "Edit Config" to create one.</p>
                </div>
              <% end %>
            </div>
          <% end %>
        </div>
      </div>

      <!-- Quick Reference -->
      <div class="mt-6 bg-base-100 rounded-2xl shadow-lg border border-base-200 overflow-hidden">
        <div class="bg-gradient-to-br from-info/10 via-info/5 to-transparent p-6">
          <h2 class="text-lg font-semibold flex items-center gap-2">
            <.icon name="hero-book-open" class="size-5 text-info" /> Configuration Reference
          </h2>
        </div>
        <div class="p-6 pt-2">
          <pre class="text-sm font-mono bg-base-200/30 rounded-lg p-4 border border-base-200 whitespace-pre-wrap break-words max-h-[500px] overflow-y-auto"><%= @config_reference %></pre>
        </div>
      </div>
    </EvoDashWeb.Layouts.app>
    """
  end

  @config_reference """
# EvoGit Configuration Reference
# Save this as: ~/.config/evogit/config.toml

[scheduler]
# Maximum concurrent LLM calls
max_concurrency = 3
# Maximum concurrent tool executions
max_tool_concurrency = 2
# Crash-retries per agent
agent_max_retries = 3
# Maximum subagent recursion depth
max_agent_depth = 8
# LLM API call retries
max_retries = 15

[llm]
# REQUIRED: LLM model identifier (format: "provider:model")
# Examples:
#   "anthropic:claude-sonnet-4-20250514"
#   "google:gemini-2.0-flash-exp"
#   "zai_coding_plan:glm-5.1"
model = "your-model-here"
# Token count threshold for context compression
compression_threshold_tokens = 100_000

[user]
# Your GitHub username (used for commit co-authoring)
github_username = "your-username"

[sandbox]
# Sandbox mode: "auto" | "enabled" | "disabled"
mode = "auto"
"""

  @impl true
  def mount(_params, _session, socket) do
    config_status = safe_config_status()
    config_dir = EvoGit.Config.config_dir()
    config_path = EvoGit.Config.config_path()
    credentials_path = EvoGit.Config.credentials_path()
    
    config_toml_content = 
      if File.exists?(config_path) do
        case File.read(config_path) do
          {:ok, content} -> content
          {:error, _} -> ""
        end
      else
        ""
      end

    socket =
      socket
      |> assign(:config_status, config_status)
      |> assign(:config_dir, config_dir)
      |> assign(:config_path, config_path)
      |> assign(:credentials_path, credentials_path)
      |> assign(:config_toml_content, config_toml_content)
      |> assign(:config_edit, config_toml_content)
      |> assign(:editing, false)
      |> assign(:config_reference, @config_reference)

    {:ok, socket}
  end

  @impl true
  def handle_event("edit_config", _params, socket) do
    # Re-read the file to get latest content
    config_path = socket.assigns.config_path
    content = 
      if File.exists?(config_path) do
        case File.read(config_path) do
          {:ok, content} -> content
          {:error, _} -> ""
        end
      else
        ""
      end

    {:noreply,
     socket
     |> assign(:config_edit, content)
     |> assign(:editing, true)}
  end

  @impl true
  def handle_event("cancel_edit", _params, socket) do
    {:noreply, assign(socket, :editing, false)}
  end

  @impl true
  def handle_event("config_text_change", %{"config_text" => text}, socket) do
    {:noreply, assign(socket, :config_edit, text)}
  end

  @impl true
  def handle_event("config_text_change", _params, socket) do
    {:noreply, socket}
  end

  @impl true
  def handle_event("save_config", _params, socket) do
    edited_text = socket.assigns.config_edit

    case TomlElixir.decode(edited_text) do
      {:ok, parsed} ->
        case EvoGit.Config.save_user_config(parsed) do
          :ok ->
            # Reload config
            config_path = socket.assigns.config_path
            config_toml_content = 
              if File.exists?(config_path) do
                case File.read(config_path) do
                  {:ok, content} -> content
                  {:error, _} -> ""
                end
              else
                ""
              end

            {:noreply,
             socket
             |> assign(:editing, false)
             |> assign(:config_toml_content, config_toml_content)
             |> assign(:config_status, safe_config_status())
             |> put_flash(:info, "Configuration saved successfully.")}

          {:error, reason} ->
            {:noreply,
             socket
             |> put_flash(:error, "Failed to save configuration: #{inspect(reason)}")}
        end

      {:error, reason} ->
        {:noreply,
         socket
         |> put_flash(:error, "Invalid TOML syntax: #{inspect(reason)}")}
    end
  end

  defp safe_config_status do
    try do
      EvoGit.Config.config_status()
    rescue
      _ -> %{missing: [], warnings: [], ok?: true}
    catch
      _, _ -> %{missing: [], warnings: [], ok?: true}
    end
  end
end
