defmodule EvoDash.MCP.LinksTest do
  use ExUnit.Case, async: true

  test "uses the configured origin and encodes exact task IDs in list and detail links" do
    data = EvoDash.MCP.Links.enrich(%{id: "task/a", tasks: [%{id: "task/a"}]})
    assert data.links.task == EvoDashWeb.Endpoint.url() <> "/review/task%2Fa"
    assert hd(data.tasks).links.task == data.links.task
    refute data.links.agents =~ "task_id"
  end
end
