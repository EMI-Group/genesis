defmodule EvoDashWeb.SettingsLive.ConfigIOTest do
  @moduledoc """
  Pure unit tests for EvoDashWeb.SettingsLive.ConfigIO's `:list_of_strings`
  handling (e.g. `[sandbox] write_paths`).

  These are pure data-transformation functions operating on plain maps — no
  LiveView, Phoenix socket, or DB setup is required.
  """

  use ExUnit.Case, async: true

  alias EvoDashWeb.SettingsLive.ConfigIO

  # Mirrors the real schema definition for [:sandbox, :write_paths] from
  # EvoGit.Config.Schema.Definitions (type :list_of_strings, default nil).
  defp write_paths_schema do
    %{
      key_path: [:sandbox, :write_paths],
      type: :list_of_strings,
      default: nil,
      validation: [],
      category: :sandbox,
      sub_category: nil,
      description:
        "User-defined list of writable paths for sandboxed tool execution (e.g. cache directories). When set, this list REPLACES the built-in writable cache-dir list; an explicitly empty list disables those writable paths entirely. When unset (nil), the platform's default writable paths are used."
    }
  end

  describe "list_of_strings_value/1" do
    test "filters blank entries from a list value" do
      assert ConfigIO.list_of_strings_value(["/tmp/a", "", " ", "/tmp/b"]) == [
               "/tmp/a",
               "/tmp/b"
             ]
    end

    test "explicit empty list round-trips as []" do
      assert ConfigIO.list_of_strings_value([]) == []
    end

    test "blank-only list round-trips as []" do
      assert ConfigIO.list_of_strings_value(["", " "]) == []
    end

    test "non-binary entries are dropped" do
      assert ConfigIO.list_of_strings_value([1, "/tmp/a", nil]) == ["/tmp/a"]
    end

    test "kept entries are not trimmed" do
      assert ConfigIO.list_of_strings_value([" /tmp/a "]) == [" /tmp/a "]
    end

    test "nil is the delete signal (:explicitly_empty)" do
      assert ConfigIO.list_of_strings_value(nil) == :explicitly_empty
    end

    test "scalar (non-list) value is the delete signal" do
      assert ConfigIO.list_of_strings_value("/tmp/a") == :explicitly_empty
    end
  end

  describe "params_to_category_config/3 with a :list_of_strings schema" do
    test "stores list entries with blanks filtered" do
      params = %{"sandbox.write_paths" => ["/tmp/a", "", " ", "/tmp/b"]}

      assert {%{sandbox: %{write_paths: ["/tmp/a", "/tmp/b"]}}, []} =
               ConfigIO.params_to_category_config(params, :sandbox, [write_paths_schema()])
    end

    test "explicit empty list is stored as [] and NOT queued for deletion" do
      params = %{"sandbox.write_paths" => []}

      assert {%{sandbox: %{write_paths: []}}, []} =
               ConfigIO.params_to_category_config(params, :sandbox, [write_paths_schema()])
    end

    test "blank-only list is stored as [] and NOT queued for deletion" do
      params = %{"sandbox.write_paths" => ["", " "]}

      assert {%{sandbox: %{write_paths: []}}, []} =
               ConfigIO.params_to_category_config(params, :sandbox, [write_paths_schema()])
    end

    test "absent param queues the key for deletion" do
      assert {%{}, [[:sandbox, :write_paths]]} =
               ConfigIO.params_to_category_config(%{}, :sandbox, [write_paths_schema()])
    end

    test "empty-string param queues the key for deletion" do
      params = %{"sandbox.write_paths" => ""}

      assert {%{}, [[:sandbox, :write_paths]]} =
               ConfigIO.params_to_category_config(params, :sandbox, [write_paths_schema()])
    end

    test "scalar (non-list) value queues the key for deletion" do
      params = %{"sandbox.write_paths" => "/tmp/a"}

      assert {%{}, [[:sandbox, :write_paths]]} =
               ConfigIO.params_to_category_config(params, :sandbox, [write_paths_schema()])
    end
  end

  describe "build_config_from_category_params/4 with a :list_of_strings schema" do
    test "persists the list into the config (blanks filtered)" do
      file_config = %{sandbox: %{mode: :auto}}
      params = %{"sandbox.write_paths" => ["/tmp/a", "", "/tmp/b"]}

      config =
        ConfigIO.build_config_from_category_params(params, :sandbox, [write_paths_schema()], file_config)

      assert get_in(config, [:sandbox, :write_paths]) == ["/tmp/a", "/tmp/b"]
      assert get_in(config, [:sandbox, :mode]) == :auto
    end

    test "persists an explicit empty list (replaces existing entries)" do
      file_config = %{sandbox: %{mode: :auto, write_paths: ["/old"]}}
      params = %{"sandbox.write_paths" => []}

      config =
        ConfigIO.build_config_from_category_params(params, :sandbox, [write_paths_schema()], file_config)

      assert get_in(config, [:sandbox, :write_paths]) == []
    end

    test "persists a blank-only list as [] (replaces existing entries, not deleted)" do
      file_config = %{sandbox: %{mode: :auto, write_paths: ["/old"]}}
      params = %{"sandbox.write_paths" => ["", " "]}

      config =
        ConfigIO.build_config_from_category_params(params, :sandbox, [write_paths_schema()], file_config)

      assert get_in(config, [:sandbox, :write_paths]) == []
      assert get_in(config, [:sandbox, :mode]) == :auto
    end

    test "absent param deletes the key from the config" do
      file_config = %{sandbox: %{mode: :auto, write_paths: ["/old"]}}

      config =
        ConfigIO.build_config_from_category_params(%{}, :sandbox, [write_paths_schema()], file_config)

      assert is_nil(get_in(config, [:sandbox, :write_paths]))
      assert get_in(config, [:sandbox, :mode]) == :auto
    end

    test "scalar (non-list) value deletes the key from the config" do
      file_config = %{sandbox: %{mode: :auto, write_paths: ["/old"]}}
      params = %{"sandbox.write_paths" => "/not-a-list"}

      config =
        ConfigIO.build_config_from_category_params(params, :sandbox, [write_paths_schema()], file_config)

      refute Map.has_key?(get_in(config, [:sandbox]) || %{}, :write_paths)
      assert get_in(config, [:sandbox, :mode]) == :auto
    end

    test "unrelated categories survive the merge" do
      file_config = %{scheduler: %{max_concurrency: 4}, sandbox: %{mode: :auto}}
      params = %{"sandbox.write_paths" => ["/tmp/a"]}

      config =
        ConfigIO.build_config_from_category_params(params, :sandbox, [write_paths_schema()], file_config)

      assert get_in(config, [:scheduler, :max_concurrency]) == 4
      assert get_in(config, [:sandbox, :write_paths]) == ["/tmp/a"]
    end
  end
end
