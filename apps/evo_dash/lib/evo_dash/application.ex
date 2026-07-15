defmodule EvoDash.Application do
  # See https://hexdocs.pm/elixir/Application.html
  # for more information on OTP Applications
  @moduledoc false

  use Application

  @impl true
  def start(_type, _args) do
    # Configure Floki to use html5ever (Rust NIF, precompiled — no build tools
    # needed) for robust HTML parsing of Lumis syntax-highlighter output.
    Application.put_env(:floki, :html_parser, Floki.HTMLParser.Html5ever)

    children = [
      EvoDashWeb.Telemetry,
      {Phoenix.PubSub, name: EvoDash.PubSub},
      {Task.Supervisor, name: EvoDash.TaskSupervisor},
      EvoDashWeb.Endpoint
    ]

    # See https://hexdocs.pm/elixir/Supervisor.html
    # for other strategies and supported options
    # Use :one_for_one with a generous max_restarts to tolerate transient
    # crashes without shutting down the whole application.
    opts = [
      strategy: :one_for_one,
      max_restarts: 10,
      max_seconds: 60,
      name: EvoDash.Supervisor
    ]

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
