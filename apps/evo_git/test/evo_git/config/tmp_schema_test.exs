defmodule EvoGit.Config.TmpSchemaTest do
  @moduledoc """
  Pins the `[tmp]` section of the config schema — the two schemas backing
  per-task temporary-directory selection (`[:tmp, :mode]` and `[:tmp, :path]`)
  plus the string→atom normalization of the mode enum.

  `async: true` is safe: everything under test is pure data transformation
  (`EvoGit.Config.Schema` and the pure `EvoGit.Config.__atomize_enum_values__/1`
  pipeline step). No test here mutates app env, `:persistent_term`, ETS, or any
  application singleton, and none subscribes to a shared PubSub topic.
  """

  use ExUnit.Case, async: true

  alias EvoGit.Config
  alias EvoGit.Config.Schema

  describe "[:tmp] schemas" do
    test "[:tmp, :mode] is present with the expected type/default/validation/category" do
      schema = find_schema([:tmp, :mode])

      assert schema.type == :atom
      assert schema.default == :system
      assert schema.validation == [in: [:system, :custom, :per_repo]]
      assert schema.category == :data
    end

    test "[:tmp, :path] is present with the expected type/default/validation/category" do
      schema = find_schema([:tmp, :path])

      assert schema.type == :string
      assert schema.default == nil
      assert schema.validation == []
      assert schema.category == :data
    end

    test "defaults/0 exposes both tmp keys" do
      defaults = Schema.defaults()
      assert defaults.tmp.mode == :system
      assert defaults.tmp.path == nil
    end
  end

  describe "[:tmp, :mode] validation" do
    test "validates the known mode atoms" do
      for mode <- [:system, :custom, :per_repo] do
        config = put_in(Schema.defaults(), [:tmp, :mode], mode)
        assert {:ok, _} = Schema.validate(config)
      end
    end

    test "rejects an unknown mode value without crashing" do
      config = put_in(Schema.defaults(), [:tmp, :mode], :bogus)
      assert {:error, errors} = Schema.validate(config)
      assert is_list(errors)
      assert length(errors) > 0

      error = List.first(errors)
      assert error.key_path == [:tmp, :mode]
      assert error.value == :bogus
      assert error.rule == {:in, [:system, :custom, :per_repo]}
    end
  end

  describe "[:tmp, :path] validation" do
    test "defaults to nil and accepts a string path" do
      defaults = Schema.defaults()
      assert defaults.tmp.path == nil
      assert {:ok, _} = Schema.validate(put_in(defaults, [:tmp, :path], "/tmp/x"))
    end
  end

  describe "[:tmp, :mode] atomization" do
    test "atomizes string mode values" do
      for {string, atom} <- [{"system", :system}, {"custom", :custom}, {"per_repo", :per_repo}] do
        config =
          Schema.defaults()
          |> put_in([:tmp, :mode], string)
          |> Config.__atomize_enum_values__()

        assert config.tmp.mode == atom
      end
    end
  end

  defp find_schema(key_path) do
    Enum.find(Schema.all_schemas(), &(&1.key_path == key_path)) ||
      flunk("no schema found for #{inspect(key_path)}")
  end
end
