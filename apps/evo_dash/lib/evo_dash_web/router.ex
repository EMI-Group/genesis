defmodule EvoDashWeb.Router do
  use EvoDashWeb, :router
  import Phoenix.LiveDashboard.Router

  pipeline :browser do
    plug(:accepts, ["html"])
    plug(:fetch_session)
    plug(EvoDashWeb.Plugs.Locale)
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
    live("/welcome", WelcomeLive, :index)
    live("/agents", AgentsLive, :index)
    live("/settings", SettingsLive, :index)
    live("/review/:task_id", ReviewLive, :show)
    live("/review/:task_id/commit/:commit_sha", ReviewLive, :commit)
    get("/tasks/:task_id/export", TaskExportController, :export)
    get("/welcome/complete", WelcomeController, :complete)
    live_dashboard("/phoenix/dashboard")
  end

  # Other scopes may use custom stacks.
  # scope "/api", EvoDashWeb do
  #   pipe_through :api
  # end
end
