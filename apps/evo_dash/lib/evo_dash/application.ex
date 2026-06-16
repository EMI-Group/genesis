defmodule EvoDash.Application do
  # See https://hexdocs.pm/elixir/Application.html
  # for more information on OTP Applications
  @moduledoc false

  use Application
  use Gettext, backend: EvoDashWeb.Gettext

  @impl true
  def start(_type, _args) do
    desktop_children =
      if Application.get_env(:evo_dash, :desktop, false) do
        # Explicitly start the :desktop application (and its :wx dependency)
        # only when desktop mode is enabled. The dependency uses runtime: false
        # and :wx is not in extra_applications, so neither auto-starts.
        Application.ensure_all_started(:desktop)

        port = Application.get_env(:evo_dash, :desktop_port, 4100)

        [{Desktop.Window,
          [
            app: :evo_dash,
            id: :evo_dash_window,
            title: gettext("Genesis Dashboard"),
            url: "http://localhost:#{port}/?client=desktop",
            size: {1280, 800}
          ]}]
      else
        []
      end

    children = [
      EvoDashWeb.Telemetry,
      {Phoenix.PubSub, name: EvoDash.PubSub},
      {Task.Supervisor, name: EvoDash.TaskSupervisor},
      EvoDash.TaskRegistry
    ] ++ desktop_children ++ [
      EvoDashWeb.Endpoint
    ]

    # See https://hexdocs.pm/elixir/Supervisor.html
    # for other strategies and supported options
    opts = [strategy: :one_for_one, name: EvoDash.Supervisor]
    Supervisor.start_link(children, opts)
  end

  # Tell Phoenix to update the endpoint configuration
  # whenever the application is updated.
  @impl true
  def config_change(changed, _new, removed) do
    EvoDashWeb.Endpoint.config_change(changed, removed)
    :ok
  end
end
