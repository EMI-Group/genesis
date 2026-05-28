defmodule EvoDashWeb.ConfigHelpLive do
  use EvoDashWeb, :live_view

  @default_template """
  [scheduler]
  max_concurrency = 3
  max_tool_concurrency = 2
  agent_max_retries = 3
  max_agent_depth = 8
  max_retries = 15

  [llm]
  model = ""

  [user]
  github_username = ""

  [sandbox]
  mode = "auto"
  """

  @impl true
  def mount(_params, _session, socket) do
    config_status = EvoGit.Config.config_status()
    config_content = load_config_content()

    socket =
      socket
      |> assign(:config_status, config_status)
      |> assign(:config_content, config_content)
      |> assign(:config_issues, config_status.issues)
      |> assign(:config_template, config_content == String.trim(@default_template))
      |> assign(:show_reference, false)

    {:ok, socket}
  end

  @impl true
  def handle_event("save_config", %{"config_content" => content}, socket) do
    case EvoGit.Config.write_user_config_toml(content) do
      :ok ->
        config_status = EvoGit.Config.config_status()

        {:noreply,
         socket
         |> assign(:config_status, config_status)
         |> assign(:config_issues, config_status.issues)
         |> assign(:config_content, content)
         |> put_flash(:info, "Configuration saved successfully!")}

      {:error, reason} ->
        {:noreply,
         socket
         |> assign(:config_content, content)
         |> put_flash(:error, "Failed to save: #{inspect(reason)}")}
    end
  end

  @impl true
  def handle_event("validate_config", _params, socket) do
    config_status = EvoGit.Config.config_status()

    {:noreply,
     socket
     |> assign(:config_status, config_status)
     |> assign(:config_issues, config_status.issues)}
  end

  @impl true
  def handle_event("toggle_reference", _params, socket) do
    {:noreply, assign(socket, :show_reference, !socket.assigns.show_reference)}
  end

  @impl true
  def handle_event("reset_template", _params, socket) do
    {:noreply, assign(socket, :config_content, String.trim(@default_template))}
  end

  defp load_config_content do
    case EvoGit.Config.read_user_config_toml() do
      {:ok, content} -> content
      {:error, :not_found} -> String.trim(@default_template)
      {:error, _reason} -> String.trim(@default_template)
    end
  end
end
