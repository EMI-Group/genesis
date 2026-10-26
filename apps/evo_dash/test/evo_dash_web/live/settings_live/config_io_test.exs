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
  # EvoGit.Config.Schema.Definitions (type :list_of_strings, default nil): when
  # set, the list REPLACES the built-in writable cache dirs; an explicitly
  # empty list disables them entirely.
  defp write_paths_schema do
    %{
      key_path: [:sandbox, :write_paths],
      type: :list_of_strings,
      default: nil,
      validation: [],
      category: :sandbox,
      sub_category: nil,
      description: "User-defined list of writable paths for sandboxed tool execution."
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

  defp llm_params(value), do: %{"llm.tool_result_pruning_target_fraction" => value}

  describe "list_of_strings_value/1" do
    test "filters blanks and non-binaries; kept entries stay untrimmed" do
      cases = [
        {["/tmp/a", "", " ", "/tmp/b"], ["/tmp/a", "/tmp/b"]},
        {[], []},
        {["", " "], []},
        {[1, "/tmp/a", nil], ["/tmp/a"]},
        {[" /tmp/a "], [" /tmp/a "]}
      ]

      for {input, expected} <- cases do
        assert ConfigIO.list_of_strings_value(input) == expected,
               "expected #{inspect(input)} to normalize to #{inspect(expected)}"
      end
    end

    test "nil and scalar values are the delete signal (:explicitly_empty)" do
      for input <- [nil, "/tmp/a"] do
        assert ConfigIO.list_of_strings_value(input) == :explicitly_empty,
               "expected #{inspect(input)} to be the delete signal"
      end
    end
  end

  describe "params_to_category_config/3 with a :list_of_strings schema" do
    test "stores filtered entries; explicit-empty and blank-only lists round-trip as [] (never a delete)" do
      cases = [
        {["/tmp/a", "", " ", "/tmp/b"], ["/tmp/a", "/tmp/b"]},
        {[], []},
        {["", " "], []}
      ]

      for {input, expected} <- cases do
        params = %{"sandbox.write_paths" => input}

        assert {%{sandbox: %{write_paths: ^expected}}, []} =
                 ConfigIO.params_to_category_config(params, :sandbox, [write_paths_schema()]),
               "expected #{inspect(input)} to be stored as #{inspect(expected)}"
      end
    end

    test "an absent, empty-string, or scalar param queues the key for deletion" do
      for {label, params} <- [
            {":absent", %{}},
            {":empty_string", %{"sandbox.write_paths" => ""}},
            {":scalar", %{"sandbox.write_paths" => "/tmp/a"}}
          ] do
        assert {%{}, [[:sandbox, :write_paths]]} =
                 ConfigIO.params_to_category_config(params, :sandbox, [write_paths_schema()]),
               "expected #{label} to queue the key for deletion"
      end
    end
  end

  describe "build_config_from_category_params/4 with a :list_of_strings schema" do
    test "list values persist (blanks filtered); explicit-empty and blank-only replace prior entries" do
      cases = [
        {["/tmp/a", "", "/tmp/b"], ["/tmp/a", "/tmp/b"]},
        {[], []},
        {["", " "], []}
      ]

      for {input, expected} <- cases do
        file_config = %{
          scheduler: %{default_llm_max_concurrency: 4},
          sandbox: %{mode: :auto, write_paths: ["/old"]}
        }

        config =
          ConfigIO.build_config_from_category_params(
            %{"sandbox.write_paths" => input},
            :sandbox,
            [write_paths_schema()],
            file_config
          )

        assert get_in(config, [:sandbox, :write_paths]) == expected
        assert get_in(config, [:sandbox, :mode]) == :auto

        # Unrelated categories (and unrelated sandbox keys) survive the merge.
        assert get_in(config, [:scheduler, :default_llm_max_concurrency]) == 4
      end
    end

    test "absent or scalar params delete the key while the rest of the config survives" do
      for params <- [%{}, %{"sandbox.write_paths" => "/not-a-list"}] do
        file_config = %{
          scheduler: %{default_llm_max_concurrency: 4},
          sandbox: %{mode: :auto, write_paths: ["/old"]}
        }

        config =
          ConfigIO.build_config_from_category_params(
            params,
            :sandbox,
            [write_paths_schema()],
            file_config
          )

        refute Map.has_key?(get_in(config, [:sandbox]) || %{}, :write_paths)
        assert get_in(config, [:sandbox, :mode]) == :auto
        assert get_in(config, [:scheduler, :default_llm_max_concurrency]) == 4
      end
    end
  end

  describe "params_to_category_config/3 with :boolean and :float schemas" do
    test ":boolean writes true only for \"true\"; absent/blank/other values write false and never delete" do
      # The :boolean branch runs BEFORE the nil/"" check, so an absent param
      # parses as `value == "true"` → false and the key is written. That is the
      # intended value for a rendered boolean card: the checkbox renders a
      # hidden `value="false"` companion input (setting_card.ex), so an
      # UNCHECKED checkbox submits "false" and the absent-param case can only
      # mean "false" too — never "delete/unset".
      cases = [
        {%{"llm.tool_result_pruning" => "true"}, true},
        {%{"llm.tool_result_pruning" => "false"}, false},
        {%{}, false},
        {%{"llm.tool_result_pruning" => ""}, false},
        {%{"llm.tool_result_pruning" => "1"}, false}
      ]

      for {params, expected} <- cases do
        assert {%{llm: %{tool_result_pruning: ^expected}}, []} =
                 ConfigIO.params_to_category_config(params, :llm, [boolean_schema()]),
               "expected #{inspect(params)} to store #{expected} without deletion"
      end
    end

    test ":float stores a parsed float and silently drops garbage or non-binary values (no delete)" do
      assert {%{llm: %{tool_result_pruning_target_fraction: 0.5}}, []} =
               ConfigIO.params_to_category_config(
                 llm_params("0.5"),
                 :llm,
                 [float_schema()]
               )

      {config, deleted} =
        ConfigIO.params_to_category_config(llm_params("0.25"), :llm, [float_schema()])

      value = get_in(config, [:llm, :tool_result_pruning_target_fraction])
      assert {value, deleted} == {0.25, []}
      assert is_float(value)

      # SettingsUtils.parse_float/1 returns nil for an unparsable string and has
      # no list clause (Plug collapses repeated same-name inputs into a list):
      # the nil branch drops the key from BOTH accumulators.
      for {label, value} <- [{"garbage", "abc"}, {"non-binary", ["0.5"]}] do
        assert {%{}, []} =
                 ConfigIO.params_to_category_config(llm_params(value), :llm, [float_schema()]),
               "expected #{label} to be dropped without deletion"
      end
    end

    test ":float treats an empty-string param as empty (queued for deletion)" do
      # Unlike :boolean, a :float card has NO hidden companion input, so an
      # emptied numeric field means "unset" and the key is deleted.
      assert {%{}, [[:llm, :tool_result_pruning_target_fraction]]} =
               ConfigIO.params_to_category_config(llm_params(""), :llm, [float_schema()])
    end

    test "boolean and float keys land in the same nested config map (a missing boolean still writes false)" do
      schemas = [boolean_schema(), float_schema()]

      assert {%{llm: %{tool_result_pruning: true, tool_result_pruning_target_fraction: 0.25}}, []} =
               ConfigIO.params_to_category_config(
                 %{
                   "llm.tool_result_pruning" => "true",
                   "llm.tool_result_pruning_target_fraction" => "0.25"
                 },
                 :llm,
                 schemas
               )

      assert {%{llm: %{tool_result_pruning: false, tool_result_pruning_target_fraction: 0.5}}, []} =
               ConfigIO.params_to_category_config(llm_params("0.5"), :llm, schemas)
    end
  end
end
