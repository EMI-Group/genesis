defmodule EvoDashWeb.Router do
  use EvoDashWeb, :router
  import Phoenix.LiveDashboard.Router

  pipeline :browser do
    plug(:accepts, ["html"])
    plug(:fetch_session)
    plug(:fetch_live_flash)
    plug(:put_root_layout, html: {EvoDashWeb.Layouts, :root})
    plug(:protect_from_forgery)
    plug(:put_secure_browser_headers)
  end

  pipeline :api do
    plug(:accepts, ["json"])
  end

  scope "/", EvoDashWeb do
    pipe_through(:browser)

    live("/", DashboardLive, :index)
    live("/agents", AgentsLive, :index)
    live("/settings", SettingsLive, :index)
    live("/help", HelpLive, :index)
    live_dashboard("/dashboard")
  end

  # Other scopes may use custom stacks.
  # scope "/api", EvoDashWeb do
  #   pipe_through :api
  # end
end
