defmodule EvoDashWeb.LiveHooks.GuidePureTest do
  # Pure unit tests split out of EvoDashWeb.LiveHooks.GuideTest:
  #
  # `normalize_guide/2` + `relevant?/2` need no LiveView, no Store/TaskRegistry,
  # no XDG_CONFIG_HOME and no global ETS hub — so they run `async: true`. The
  # LiveView integration tests (which terminate/restart the production
  # TaskRegistry/Store children) stay in the `async: false` GuideTest module.
  use ExUnit.Case, async: true

  alias EvoDashWeb.LiveHooks.Guide

  describe "normalize_guide/2" do
    test "atom-keyed payload → exact canonical map" do
      assert Guide.normalize_guide("g1", %{
               message: "hello",
               page: "/system",
               selector: "#el",
               dismissible: true
             }) == %{
               id: "g1",
               message: "hello",
               page: "/system",
               selector: "#el",
               dismissible: true
             }
    end

    test "string-keyed payload → same canonical map" do
      assert Guide.normalize_guide("g1", %{
               "message" => "hello",
               "page" => "/system",
               "selector" => "#el",
               "dismissible" => true
             }) == %{
               id: "g1",
               message: "hello",
               page: "/system",
               selector: "#el",
               dismissible: true
             }
    end

    test "partial payload → safe defaults (missing message → \"\", missing page/selector → nil)" do
      assert Guide.normalize_guide("g1", %{}) ==
               %{id: "g1", message: "", page: nil, selector: nil, dismissible: false}
    end

    test "non-boolean dismissible → false" do
      assert Guide.normalize_guide("g1", %{message: "m", dismissible: "yes"}) ==
               %{id: "g1", message: "m", page: nil, selector: nil, dismissible: false}
    end

    test "non-map payload (nil) → safe defaults" do
      assert Guide.normalize_guide("g1", nil) ==
               %{id: "g1", message: "", page: nil, selector: nil, dismissible: false}
    end
  end

  describe "relevant?/2" do
    test "matching node → true (explicit current_node and missing-assign fallback)" do
      assert Guide.relevant?(%{current_node: node()}, node())
      assert Guide.relevant?(%{}, node())
    end

    test "foreign node → false" do
      refute Guide.relevant?(%{current_node: node()}, :guide_other_node)
      refute Guide.relevant?(%{}, :guide_other_node)
    end
  end
end
