defmodule EvoDash.SettingsUtilsTest do
  use ExUnit.Case, async: true

  import EvoDash.SettingsUtils
  alias EvoDash.SettingsUtils

  doctest EvoDash.SettingsUtils

  describe "deep_put/3" do
    test "puts a value at a single key" do
      assert SettingsUtils.deep_put(%{}, [:a], 1) == %{a: 1}
    end

    test "creates nested path in an empty map" do
      assert SettingsUtils.deep_put(%{}, [:a, :b, :c], 1) == %{a: %{b: %{c: 1}}}
    end

    test "merges into an existing nested map without losing siblings" do
      assert SettingsUtils.deep_put(%{a: %{c: 2}}, [:a, :b], 1) == %{a: %{b: 1, c: 2}}
    end

    test "overwrites an existing scalar value at a single key" do
      assert SettingsUtils.deep_put(%{a: 1}, [:a], 2) == %{a: 2}
    end

    test "overwrites an existing nested map at a deeper key" do
      assert SettingsUtils.deep_put(%{a: %{b: 1}}, [:a, :b], 9) == %{a: %{b: 9}}
    end
  end

  describe "deep_merge/2" do
    test "merges non-overlapping maps" do
      assert SettingsUtils.deep_merge(%{a: 1}, %{b: 2}) == %{a: 1, b: 2}
    end

    test "right wins on conflicting scalar values" do
      assert SettingsUtils.deep_merge(%{a: 1}, %{a: 2}) == %{a: 2}
    end

    test "recursively merges nested maps" do
      left = %{a: %{x: 1, y: 2}}
      right = %{a: %{y: 9, z: 3}}

      assert SettingsUtils.deep_merge(left, right) == %{a: %{x: 1, y: 9, z: 3}}
    end

    test "right scalar overrides left map at the same key" do
      assert SettingsUtils.deep_merge(%{a: %{x: 1}}, %{a: 2}) == %{a: 2}
    end

    test "merging an empty map is a no-op on the left" do
      assert SettingsUtils.deep_merge(%{a: 1}, %{}) == %{a: 1}
    end

    test "merging into an empty map copies the right map" do
      assert SettingsUtils.deep_merge(%{}, %{a: 1}) == %{a: 1}
    end
  end

  describe "deep_delete/2" do
    test "deletes a leaf at a single-key path" do
      assert SettingsUtils.deep_delete(%{a: 1, b: 2}, [:a]) == %{b: 2}
    end

    test "deletes a nested leaf and cascades when the parent becomes empty" do
      assert SettingsUtils.deep_delete(%{a: %{b: 1}}, [:a, :b]) == %{}
    end

    test "deletes a nested leaf while the parent retains other keys" do
      assert SettingsUtils.deep_delete(%{a: %{b: 1, c: 2}}, [:a, :b]) == %{a: %{c: 2}}
    end

    test "cascades through multiple empty levels" do
      assert SettingsUtils.deep_delete(%{a: %{b: %{c: 1}}}, [:a, :b, :c]) == %{}
    end

    test "returns the map unchanged when the key path does not exist" do
      assert SettingsUtils.deep_delete(%{a: 1}, [:x, :y]) == %{a: 1}
    end

    test "returns the map unchanged when an intermediate value is not a map" do
      assert SettingsUtils.deep_delete(%{a: 1}, [:a, :b]) == %{a: 1}
    end

    test "deleting a missing single key leaves the map unchanged" do
      assert SettingsUtils.deep_delete(%{a: 1}, [:x]) == %{a: 1}
    end
  end

  describe "parse_int/1" do
    test "parses a valid integer string" do
      assert SettingsUtils.parse_int("42") == 42
    end

    test "parses a negative integer string" do
      assert SettingsUtils.parse_int("-7") == -7
    end

    test "returns nil for a non-numeric string" do
      assert SettingsUtils.parse_int("abc") == nil
    end

    test "returns nil for nil input" do
      assert SettingsUtils.parse_int(nil) == nil
    end

    test "returns nil for a float string (trailing characters remain)" do
      assert SettingsUtils.parse_int("3.14") == nil
    end

    test "returns nil for a string with trailing non-numeric characters" do
      assert SettingsUtils.parse_int("12abc") == nil
    end

    test "returns nil for an empty string" do
      assert SettingsUtils.parse_int("") == nil
    end
  end

  describe "parse_float/1" do
    test "parses a valid float string" do
      assert SettingsUtils.parse_float("3.14") == 3.14
    end

    test "parses an integer string into a float" do
      assert SettingsUtils.parse_float("5") == 5.0
    end

    test "returns nil for a non-numeric string" do
      assert SettingsUtils.parse_float("abc") == nil
    end

    test "returns nil for nil input" do
      assert SettingsUtils.parse_float(nil) == nil
    end

    test "returns nil for a string with trailing non-numeric characters" do
      assert SettingsUtils.parse_float("1.5abc") == nil
    end

    test "returns nil for an empty string" do
      assert SettingsUtils.parse_float("") == nil
    end
  end

  describe "parse_atom/2" do
    @schema %{validation: [in: [:enabled, :disabled]]}

    test "converts a string matching a whitelisted atom" do
      assert SettingsUtils.parse_atom("enabled", @schema) == :enabled
      assert SettingsUtils.parse_atom("disabled", @schema) == :disabled
    end

    test "returns nil for a string not in the whitelist" do
      assert SettingsUtils.parse_atom("unknown", @schema) == nil
    end

    test "returns nil for an empty string" do
      assert SettingsUtils.parse_atom("", @schema) == nil
    end

    test "returns nil for nil input" do
      assert SettingsUtils.parse_atom(nil, @schema) == nil
    end

    test "returns nil when the schema has no validation whitelist" do
      assert SettingsUtils.parse_atom("enabled", %{}) == nil
    end

    test "returns nil when the whitelist is explicitly empty" do
      assert SettingsUtils.parse_atom("enabled", %{validation: [in: []]}) == nil
    end
  end

  describe "maybe_add_kw/3" do
    test "adds a non-nil value to an empty list" do
      assert SettingsUtils.maybe_add_kw([], :foo, 1) == [foo: 1]
    end

    test "adds a non-nil value to an existing list" do
      assert SettingsUtils.maybe_add_kw([bar: 2], :foo, 1) == [foo: 1, bar: 2]
    end

    test "skips adding a nil value" do
      assert SettingsUtils.maybe_add_kw([], :foo, nil) == []
    end

    test "does not modify an existing list when value is nil" do
      assert SettingsUtils.maybe_add_kw([bar: 2], :foo, nil) == [bar: 2]
    end

    test "adds a falsey-but-present value (not nil)" do
      assert SettingsUtils.maybe_add_kw([], :flag, false) == [flag: false]
      assert SettingsUtils.maybe_add_kw([], :count, 0) == [count: 0]
    end
  end
end
