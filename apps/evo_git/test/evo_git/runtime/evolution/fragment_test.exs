defmodule EvoGit.Runtime.Evolution.FragmentTest do
  use ExUnit.Case, async: true

  alias EvoGit.Runtime.Evolution.Fragment

  describe "new/2" do
    test "creates a fragment with default values" do
      fragment = Fragment.new("x = 1", domain: "math")

      assert %Fragment{} = fragment
      assert fragment.content == "x = 1"
      assert fragment.domain == "math"
      assert fragment.language == "elixir"
      assert fragment.source == :seed
      assert fragment.generation == 0
      assert fragment.parents == []
    end

    test "sets inserted_at to a DateTime" do
      fragment = Fragment.new("x = 1", domain: "math")

      assert %DateTime{} = fragment.inserted_at
    end

    test "generates a 16-char lowercase hex id" do
      fragment = Fragment.new("x = 1", domain: "math")

      assert fragment.id =~ ~r/^[0-9a-f]{16}$/
    end

    test "accepts custom opts" do
      fragment =
        Fragment.new("code",
          domain: "test",
          language: "python",
          source: :generated,
          generation: 5,
          parents: ["p1", "p2"]
        )

      assert fragment.content == "code"
      assert fragment.domain == "test"
      assert fragment.language == "python"
      assert fragment.source == :generated
      assert fragment.generation == 5
      assert fragment.parents == ["p1", "p2"]
    end

    test "raises KeyError when :domain is missing" do
      assert_raise KeyError, fn -> Fragment.new("x = 1") end
    end

    test "two calls produce different ids" do
      f1 = Fragment.new("x = 1", domain: "math")
      f2 = Fragment.new("x = 1", domain: "math")

      assert f1.id != f2.id
    end
  end

  describe "extract_structural_features/1" do
    @feature_keys [
      :nesting_depth,
      :function_count,
      :control_flow_count,
      :comment_density,
      :import_count,
      :avg_line_length,
      :string_literal_count,
      :numeric_literal_count,
      :line_count,
      :char_count
    ]

    test "returns a map with all 10 keys" do
      fragment = Fragment.new("x = 1", domain: "math")
      features = Fragment.extract_structural_features(fragment)

      assert is_map(features)

      for key <- @feature_keys do
        assert Map.has_key?(features, key), "missing key: #{inspect(key)}"
      end
    end

    test "line_count for a known snippet" do
      content = "defmodule Foo do\n  def bar, do: :ok\nend\n"
      fragment = Fragment.new(content, domain: "elixir")
      features = Fragment.extract_structural_features(fragment)

      assert features.line_count == 3
    end

    test "function_count matches def" do
      content = "defmodule Foo do\n  def bar, do: :ok\nend\n"
      fragment = Fragment.new(content, domain: "elixir")
      features = Fragment.extract_structural_features(fragment)

      assert features.function_count >= 1
    end

    test "char_count equals String.length of content" do
      content = "defmodule Foo do\n  def bar, do: :ok\nend\n"
      fragment = Fragment.new(content, domain: "elixir")
      features = Fragment.extract_structural_features(fragment)

      assert features.char_count == String.length(content)
    end

    test "comment_density for content with comments" do
      content = "# comment\ncode = 1\n"
      fragment = Fragment.new(content, domain: "elixir")
      features = Fragment.extract_structural_features(fragment)

      assert features.comment_density == 50.0
    end

    test "empty content has zero line_count, comment_density, and avg_line_length" do
      fragment = Fragment.new("", domain: "math")
      features = Fragment.extract_structural_features(fragment)

      assert features.line_count == 0
      assert features.comment_density == 0.0
      assert features.avg_line_length == 0.0
    end

    test "string_literal_count counts string literals" do
      content = ~s(x = "hello")
      fragment = Fragment.new(content, domain: "elixir")
      features = Fragment.extract_structural_features(fragment)

      assert features.string_literal_count >= 1
    end

    test "numeric_literal_count counts numeric literals" do
      content = "x = 42"
      fragment = Fragment.new(content, domain: "elixir")
      features = Fragment.extract_structural_features(fragment)

      assert features.numeric_literal_count >= 1
    end

    test "nesting_depth is at least 1 for indented lines" do
      content = "defmodule Foo do\n  def bar, do: :ok\nend\n"
      fragment = Fragment.new(content, domain: "elixir")
      features = Fragment.extract_structural_features(fragment)

      assert features.nesting_depth >= 1
    end
  end

  describe "to_feature_vector/1" do
    test "returns empty list for empty features and profile" do
      fragment = Fragment.new("x = 1", domain: "math")

      assert Fragment.to_feature_vector(fragment) == []
    end

    test "returns a list of 10 floats when structural_features are populated" do
      base = Fragment.new("x = 1", domain: "math")
      features = Fragment.extract_structural_features(base)
      fragment = %{base | structural_features: features}

      vector = Fragment.to_feature_vector(fragment)

      assert length(vector) == 10

      for value <- vector do
        assert is_float(value)
        assert value >= 0.0
        assert value <= 1.0
      end
    end

    test "returns 6-element behavior vector for functional paradigm" do
      base = Fragment.new("x = 1", domain: "math")

      fragment = %{
        base
        | behavioral_profile: %{complexity: 0.5, paradigm: :functional, abstraction: 0.3}
      }

      vector = Fragment.to_feature_vector(fragment)

      assert length(vector) == 6
      # complexity, abstraction, then 4 one-hot paradigm positions
      assert Enum.at(vector, 0) == 0.5
      assert Enum.at(vector, 1) == 0.3
      # first position of one-hot encoding
      assert Enum.at(vector, 2) == 1.0
      assert Enum.at(vector, 3) == 0.0
      assert Enum.at(vector, 4) == 0.0
      assert Enum.at(vector, 5) == 0.0
    end

    test "returns 16 elements when both structural_features and behavioral_profile are populated" do
      base = Fragment.new("x = 1", domain: "math")
      features = Fragment.extract_structural_features(base)

      fragment = %{
        base
        | structural_features: features,
          behavioral_profile: %{paradigm: :functional, complexity: 0.5, abstraction: 0.3}
      }

      vector = Fragment.to_feature_vector(fragment)

      assert length(vector) == 16
    end

    test "imperative paradigm sets last one-hot position to 1.0" do
      base = Fragment.new("x = 1", domain: "math")

      fragment = %{
        base
        | behavioral_profile: %{complexity: 0.5, paradigm: :imperative, abstraction: 0.3}
      }

      vector = Fragment.to_feature_vector(fragment)

      # one-hot is last 4 positions; imperative = last (index 5)
      assert Enum.at(vector, 2) == 0.0
      assert Enum.at(vector, 3) == 0.0
      assert Enum.at(vector, 4) == 0.0
      assert Enum.at(vector, 5) == 1.0
    end

    test "unknown paradigm sets all one-hot positions to 0.0" do
      base = Fragment.new("x = 1", domain: "math")

      fragment = %{
        base
        | behavioral_profile: %{complexity: 0.5, paradigm: :unknown, abstraction: 0.3}
      }

      vector = Fragment.to_feature_vector(fragment)

      assert Enum.at(vector, 2) == 0.0
      assert Enum.at(vector, 3) == 0.0
      assert Enum.at(vector, 4) == 0.0
      assert Enum.at(vector, 5) == 0.0
    end
  end

  describe "summarize/1" do
    test "returns the full content for short content (<=200 chars)" do
      fragment = Fragment.new("def foo, do: :ok", domain: "elixir")
      summary = Fragment.summarize(fragment)

      assert String.contains?(summary, "def foo, do: :ok")
    end

    test "truncates long content (>200 chars) with ellipsis" do
      long_content = String.duplicate("a", 250)
      fragment = Fragment.new(long_content, domain: "elixir")
      summary = Fragment.summarize(fragment)

      assert String.contains?(summary, "...")
      refute String.contains?(summary, String.duplicate("a", 250))
    end

    test "contains the domain in brackets" do
      fragment = Fragment.new("x = 1", domain: "math")
      summary = Fragment.summarize(fragment)

      assert String.contains?(summary, "[math]")
    end

    test "contains the generation for gen 0 fragment" do
      fragment = Fragment.new("x = 1", domain: "math")
      summary = Fragment.summarize(fragment)

      assert String.contains?(summary, "gen 0")
    end

    test "contains novelty: 0.0 for default novelty_score" do
      fragment = Fragment.new("x = 1", domain: "math")
      summary = Fragment.summarize(fragment)

      assert String.contains?(summary, "novelty: 0.0")
    end
  end
end
