defmodule EvoDashWeb.Router do
  use EvoDashWeb, :router
  import Phoenix.LiveDashboard.Router

  pipeline :browser do
    plug(:accepts, ["html"])
    plug(:fetch_session)
    plug(:detect_desktop_client)
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
    live("/tasks", TasksLive, :index)
    live("/agents", AgentsLive, :index)
    live("/settings", SettingsLive, :index)
    live("/help", HelpLive, :index)
    live("/review/:task_id", ReviewLive, :show)
    live_dashboard "/dashboard",
      additional_pages: [
        os_mon: Phoenix.LiveDashboard.OsMonPage
      ]
  end

  # Other scopes may use custom stacks.
  # scope "/api", EvoDashWeb do
  #   pipe_through :api
  # end

  defp detect_desktop_client(conn, _opts) do
    if conn.params["client"] == "desktop" do
      Plug.Conn.put_session(conn, :is_desktop, true)
    else
      conn
    end
  end
end
