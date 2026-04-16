defmodule EvoDashWeb.PageController do
  use EvoDashWeb, :controller

  def home(conn, _params) do
    render(conn, :home)
  end
end
