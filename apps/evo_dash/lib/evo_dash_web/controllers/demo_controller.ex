defmodule EvoDashWeb.DemoController do
  @moduledoc """
  Dev-only helper: seeds a complete demo flow (see `EvoDash.DemoSeed`) and
  returns the URLs to view it. Registered only when `Mix.env() == :dev`.
  """

  use EvoDashWeb, :controller

  def seed(conn, _params) do
    [task_1, task_2] = EvoDash.DemoSeed.seed!()
    task_3 = EvoDash.DemoSeedRich.seed!()

    json(conn, %{
      ok: true,
      tree: "/tree?demo=1",
      review: ["/tree/review/#{task_1}", "/tree/review/#{task_2}", "/tree/review/#{task_3}"]
    })
  end
end
