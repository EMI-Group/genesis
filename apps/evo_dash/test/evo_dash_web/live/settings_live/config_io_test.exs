defmodule EvoDashWeb.SettingsLive.ConfigIOTest do
  @moduledoc """
  Pure unit tests for EvoDashWeb.SettingsLive.ConfigIO's `:list_of_strings`
  handling (e.g. `[sandbox] write_paths`) and for the data-driven `:boolean` /
  `:float` branches used by flat global `[llm]` cards (e.g.
  `tool_result_pruning`, `tool_result_pruning_target_fraction`).

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

  # Mirrors the real schema shape for a flat global [llm] boolean key, e.g. the
  # core's [:llm, :tool_result_pruning] (type :boolean, default true).
  defp boolean_schema do
    %{
      key_path: [:llm, :tool_result_pruning],
      type: :boolean,
      default: true,
      validation: [],
      category: :llm,
      sub_category: nil,
      description: "Whether tool results are pruned during context compression."
    }
  end

  # Mirrors the real schema shape for a flat global [llm] float key, e.g. the
  # core's [:llm, :tool_result_pruning_target_fraction] (type :float).
  defp float_schema do
    %{
      key_path: [:llm, :tool_result_pruning_target_fraction],
      type: :float,
      default: 0.5,
      validation: [min: 0.0, max: 1.0],
      category: :llm,
      sub_category: nil,
      description: "Target fraction of the compression threshold kept after pruning."
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
        ConfigIO.build_config_from_category_params(
          params,
          :sandbox,
          [write_paths_schema()],
          file_config
        )

      assert get_in(config, [:sandbox, :write_paths]) == ["/tmp/a", "/tmp/b"]
      assert get_in(config, [:sandbox, :mode]) == :auto
    end

    test "persists an explicit empty list (replaces existing entries)" do
      file_config = %{sandbox: %{mode: :auto, write_paths: ["/old"]}}
      params = %{"sandbox.write_paths" => []}

      config =
        ConfigIO.build_config_from_category_params(
          params,
          :sandbox,
          [write_paths_schema()],
          file_config
        )

      assert get_in(config, [:sandbox, :write_paths]) == []
    end

    test "persists a blank-only list as [] (replaces existing entries, not deleted)" do
      file_config = %{sandbox: %{mode: :auto, write_paths: ["/old"]}}
      params = %{"sandbox.write_paths" => ["", " "]}

      config =
        ConfigIO.build_config_from_category_params(
          params,
          :sandbox,
          [write_paths_schema()],
          file_config
        )

      assert get_in(config, [:sandbox, :write_paths]) == []
      assert get_in(config, [:sandbox, :mode]) == :auto
    end

    test "absent param deletes the key from the config" do
      file_config = %{sandbox: %{mode: :auto, write_paths: ["/old"]}}

      config =
        ConfigIO.build_config_from_category_params(
          %{},
          :sandbox,
          [write_paths_schema()],
          file_config
        )

      assert is_nil(get_in(config, [:sandbox, :write_paths]))
      assert get_in(config, [:sandbox, :mode]) == :auto
    end

    test "scalar (non-list) value deletes the key from the config" do
      file_config = %{sandbox: %{mode: :auto, write_paths: ["/old"]}}
      params = %{"sandbox.write_paths" => "/not-a-list"}

      config =
        ConfigIO.build_config_from_category_params(
          params,
          :sandbox,
          [write_paths_schema()],
          file_config
        )

      refute Map.has_key?(get_in(config, [:sandbox]) || %{}, :write_paths)
      assert get_in(config, [:sandbox, :mode]) == :auto
    end

    test "unrelated categories survive the merge" do
      file_config = %{scheduler: %{default_llm_max_concurrency: 4}, sandbox: %{mode: :auto}}
      params = %{"sandbox.write_paths" => ["/tmp/a"]}

      config =
        ConfigIO.build_config_from_category_params(
          params,
          :sandbox,
          [write_paths_schema()],
          file_config
        )

      assert get_in(config, [:scheduler, :default_llm_max_concurrency]) == 4
      assert get_in(config, [:sandbox, :write_paths]) == ["/tmp/a"]
    end
  end

  describe "params_to_category_config/3 with :boolean and :float schemas" do
    test ":boolean stores true for a \"true\" param" do
      params = %{"llm.tool_result_pruning" => "true"}

      assert {%{llm: %{tool_result_pruning: true}}, []} =
               ConfigIO.params_to_category_config(params, :llm, [boolean_schema()])
    end

    test ":boolean stores false for a \"false\" param" do
      params = %{"llm.tool_result_pruning" => "false"}

      assert {%{llm: %{tool_result_pruning: false}}, []} =
               ConfigIO.params_to_category_config(params, :llm, [boolean_schema()])
    end

    test ":boolean treats a missing param as false and does NOT queue it for deletion" do
      # Actual behavior: the :boolean branch runs BEFORE the nil/"" check, so an
      # absent param parses as `value == "true"` → false and the key is written.
      # That is the intended value for a rendered boolean card: the checkbox
      # renders a hidden `value="false"` companion input
      # (setting_card.ex:240-249), so an UNCHECKED checkbox submits "false" and
      # the absent-param case can only mean "false" too — never "delete/unset".
      assert {%{llm: %{tool_result_pruning: false}}, []} =
               ConfigIO.params_to_category_config(%{}, :llm, [boolean_schema()])
    end

    test ":boolean treats an empty-string param as false and does NOT queue it for deletion" do
      params = %{"llm.tool_result_pruning" => ""}

      assert {%{llm: %{tool_result_pruning: false}}, []} =
               ConfigIO.params_to_category_config(params, :llm, [boolean_schema()])
    end

    test ":boolean treats any non-\"true\" value as false" do
      params = %{"llm.tool_result_pruning" => "1"}

      assert {%{llm: %{tool_result_pruning: false}}, []} =
               ConfigIO.params_to_category_config(params, :llm, [boolean_schema()])
    end

    test ":float stores a parsed float for a numeric string" do
      params = %{"llm.tool_result_pruning_target_fraction" => "0.5"}

      assert {%{llm: %{tool_result_pruning_target_fraction: 0.5}}, []} =
               ConfigIO.params_to_category_config(params, :llm, [float_schema()])
    end

    test ":float stores a parsed float for a smaller numeric string" do
      params = %{"llm.tool_result_pruning_target_fraction" => "0.25"}

      config = ConfigIO.params_to_category_config(params, :llm, [float_schema()])

      assert {%{llm: %{tool_result_pruning_target_fraction: 0.25}}, []} = config
      assert is_float(get_in(elem(config, 0), [:llm, :tool_result_pruning_target_fraction]))
    end

    test ":float does NOT write a garbage value and does NOT queue it for deletion" do
      # SettingsUtils.parse_float/1 returns nil for an unparsable string; the
      # `is_nil(parsed)` branch then drops the key from BOTH accumulators.
      params = %{"llm.tool_result_pruning_target_fraction" => "abc"}

      assert {%{}, []} =
               ConfigIO.params_to_category_config(params, :llm, [float_schema()])
    end

    test ":float drops a non-binary param value (parse_float/1 → nil) without deletion" do
      # Plug collapses repeated same-name inputs into a list; parse_float/1 has
      # no list clause and returns nil → neither written nor queued for deletion.
      params = %{"llm.tool_result_pruning_target_fraction" => ["0.5"]}

      assert {%{}, []} =
               ConfigIO.params_to_category_config(params, :llm, [float_schema()])
    end

    test ":float treats an empty-string param as empty (queued for deletion)" do
      # Unlike :boolean, a :float card has NO hidden companion input, so an
      # emptied numeric field means "unset" and the key is deleted.
      params = %{"llm.tool_result_pruning_target_fraction" => ""}

      assert {%{}, [[:llm, :tool_result_pruning_target_fraction]]} =
               ConfigIO.params_to_category_config(params, :llm, [float_schema()])
    end

    test "boolean and float keys land in the same nested config map" do
      params = %{
        "llm.tool_result_pruning" => "true",
        "llm.tool_result_pruning_target_fraction" => "0.25"
      }

      assert {%{llm: %{tool_result_pruning: true, tool_result_pruning_target_fraction: 0.25}}, []} =
               ConfigIO.params_to_category_config(params, :llm, [
                 boolean_schema(),
                 float_schema()
               ])
    end

    test "a missing boolean and a present float still merge into one nested map" do
      params = %{"llm.tool_result_pruning_target_fraction" => "0.5"}

      assert {%{llm: %{tool_result_pruning: false, tool_result_pruning_target_fraction: 0.5}}, []} =
               ConfigIO.params_to_category_config(params, :llm, [
                 boolean_schema(),
                 float_schema()
               ])
    end
  end
end
