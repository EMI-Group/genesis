defmodule EvoDashWeb.CategoryMetadataTest do
  @moduledoc """
  Pure unit tests for `EvoDashWeb.SettingsComponents.CategoryMetadata`.

  The settings sidebar, search results, and section header render every
  category present in `schemas_by_category` through these helpers, and the
  display-name/icon/description functions have NO catch-all clause — so every
  new config category (e.g. the core's `[data] dir` → `:data`) needs a clause
  here or the Settings page raises FunctionClauseError. These tests pin the
  `:data` category metadata and its `sort_categories/1` position without
  needing the evo_git schema (the sibling core change may not be merged).
  """

  use ExUnit.Case, async: true

  alias EvoDashWeb.SettingsComponents.CategoryMetadata

  describe ":data category metadata" do
    test "category_display_name(:data) resolves" do
      assert CategoryMetadata.category_display_name(:data) == "Data"
    end

    test "category_icon(:data) resolves to a hero icon" do
      assert CategoryMetadata.category_icon(:data) == "hero-circle-stack"
    end

    test "category_description(:data) resolves to a one-sentence description" do
      description = CategoryMetadata.category_description(:data)
      assert is_binary(description)
      assert description =~ "runtime data"
      assert description =~ "logs"
    end
  end

  describe "sort_categories/1" do
    test "places :data between :task_history and :server" do
      categories = [
        {:data, []},
        {:server, []},
        {:task_history, []},
        {:node, []}
      ]

      sorted = CategoryMetadata.sort_categories(categories) |> Enum.map(&elem(&1, 0))
      assert sorted == [:task_history, :data, :server, :node]
    end
  end
end
