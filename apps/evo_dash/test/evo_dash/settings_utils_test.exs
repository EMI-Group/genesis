defmodule EvoDash.SettingsUtilsTest do
  use ExUnit.Case, async: true

  import EvoDash.SettingsUtils
  alias EvoDash.SettingsUtils

  doctest EvoDash.SettingsUtils

  describe "deep_put/3" do
    test "puts at a single key, creating/merging nested maps and overwriting existing values" do
      cases = [
        {%{}, [:a], 1, %{a: 1}},
        {%{}, [:a, :b, :c], 1, %{a: %{b: %{c: 1}}}},
        {%{a: %{c: 2}}, [:a, :b], 1, %{a: %{b: 1, c: 2}}},
        {%{a: 1}, [:a], 2, %{a: 2}},
        {%{a: %{b: 1}}, [:a, :b], 9, %{a: %{b: 9}}}
      ]

      for {map, path, value, expected} <- cases do
        assert SettingsUtils.deep_put(map, path, value) == expected,
               "deep_put(#{inspect(map)}, #{inspect(path)}, #{inspect(value)})"
      end
    end
  end

  describe "deep_merge/2" do
    test "merges recursively with the right side winning, and handles empty maps" do
      cases = [
        {%{a: 1}, %{b: 2}, %{a: 1, b: 2}},
        {%{a: 1}, %{a: 2}, %{a: 2}},
        {%{a: %{x: 1, y: 2}}, %{a: %{y: 9, z: 3}}, %{a: %{x: 1, y: 9, z: 3}}},
        {%{a: %{x: 1}}, %{a: 2}, %{a: 2}},
        {%{a: 1}, %{}, %{a: 1}},
        {%{}, %{a: 1}, %{a: 1}}
      ]

      for {left, right, expected} <- cases do
        assert SettingsUtils.deep_merge(left, right) == expected,
               "deep_merge(#{inspect(left)}, #{inspect(right)})"
      end
    end
  end

  describe "deep_delete/2" do
    test "deletes leaves, cascades empty parents, and is a no-op on missing paths" do
      cases = [
        {%{a: 1, b: 2}, [:a], %{b: 2}},
        {%{a: %{b: 1}}, [:a, :b], %{}},
        {%{a: %{b: 1, c: 2}}, [:a, :b], %{a: %{c: 2}}},
        {%{a: %{b: %{c: 1}}}, [:a, :b, :c], %{}},
        {%{a: 1}, [:x, :y], %{a: 1}},
        # An intermediate value that is not a map is left untouched.
        {%{a: 1}, [:a, :b], %{a: 1}},
        {%{a: 1}, [:x], %{a: 1}}
      ]

      for {map, path, expected} <- cases do
        assert SettingsUtils.deep_delete(map, path) == expected,
               "deep_delete(#{inspect(map)}, #{inspect(path)})"
      end
    end
  end

  describe "parse_int/1" do
    test "parses whole integers and returns nil for anything else" do
      assert SettingsUtils.parse_int("42") == 42
      assert SettingsUtils.parse_int("-7") == -7

      for bad <- ["abc", nil, "3.14", "12abc", ""] do
        assert SettingsUtils.parse_int(bad) == nil, "expected #{inspect(bad)} to fail"
      end
    end
  end

  describe "parse_float/1" do
    test "parses floats and integer strings, returning nil for anything else" do
      assert SettingsUtils.parse_float("3.14") == 3.14
      assert SettingsUtils.parse_float("5") == 5.0

      for bad <- ["abc", nil, "1.5abc", ""] do
        assert SettingsUtils.parse_float(bad) == nil, "expected #{inspect(bad)} to fail"
      end
    end
  end

  describe "parse_atom/2" do
    @schema %{validation: [in: [:enabled, :disabled]]}

    test "maps a string onto a whitelisted atom only" do
      assert SettingsUtils.parse_atom("enabled", @schema) == :enabled
      assert SettingsUtils.parse_atom("disabled", @schema) == :disabled
    end

    test "returns nil for unknown strings, blank input and schemas without a whitelist" do
      assert SettingsUtils.parse_atom("unknown", @schema) == nil
      assert SettingsUtils.parse_atom("", @schema) == nil
      assert SettingsUtils.parse_atom(nil, @schema) == nil
      assert SettingsUtils.parse_atom("enabled", %{}) == nil
      assert SettingsUtils.parse_atom("enabled", %{validation: [in: []]}) == nil
    end
  end

  describe "maybe_add_kw/3" do
    test "prepends non-nil values and skips nil" do
      assert SettingsUtils.maybe_add_kw([], :foo, 1) == [foo: 1]
      assert SettingsUtils.maybe_add_kw([bar: 2], :foo, 1) == [foo: 1, bar: 2]
      assert SettingsUtils.maybe_add_kw([], :foo, nil) == []
      assert SettingsUtils.maybe_add_kw([bar: 2], :foo, nil) == [bar: 2]
      # Falsey-but-present values (only nil is skipped).
      assert SettingsUtils.maybe_add_kw([], :flag, false) == [flag: false]
      assert SettingsUtils.maybe_add_kw([], :count, 0) == [count: 0]
    end
  end
end
