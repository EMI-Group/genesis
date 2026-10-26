defmodule EvoDashWeb.LiveHooks.GuidePureTest do
  # Pure unit tests split out of EvoDashWeb.LiveHooks.GuideTest:
  #
  # `normalize_guide/2` + `relevant?/2` need no LiveView, no Store/TaskRegistry,
  # no XDG_CONFIG_HOME and no global ETS hub — so they run `async: true`. The
  # LiveView integration tests (which terminate/restart the production
  # TaskRegistry/Store children) stay in the `async: false` GuideTest module.
  use ExUnit.Case, async: true

  alias EvoDashWeb.LiveHooks.Guide

  test "normalize_guide/2 canonicalizes atom/string keys and defaults missing fields" do
    canonical = %{id: "g1", message: "hello", page: "/system", selector: "#el", dismissible: true}

    assert Guide.normalize_guide(
             "g1",
             %{message: "hello", page: "/system", selector: "#el", dismissible: true}
           ) == canonical

    assert Guide.normalize_guide(
             "g1",
             %{
               "message" => "hello",
               "page" => "/system",
               "selector" => "#el",
               "dismissible" => true
             }
           ) == canonical

    empty = %{id: "g1", message: "", page: nil, selector: nil, dismissible: false}

    # Partial and non-map payloads take the safe defaults; a non-boolean
    # dismissible is coerced to false.
    for payload <- [%{}, nil] do
      assert Guide.normalize_guide("g1", payload) == empty, inspect(payload)
    end

    assert Guide.normalize_guide("g1", %{message: "m", dismissible: "yes"}) ==
             %{empty | message: "m"}
  end

  test "relevant?/2 matches the current node (missing assign falls back to the local node)" do
    assert Guide.relevant?(%{current_node: node()}, node())
    assert Guide.relevant?(%{}, node())

    refute Guide.relevant?(%{current_node: node()}, :guide_other_node)
    refute Guide.relevant?(%{}, :guide_other_node)
  end
end
