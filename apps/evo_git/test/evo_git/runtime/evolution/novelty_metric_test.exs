defmodule EvoGit.Runtime.Evolution.NoveltyMetricTest do
  use ExUnit.Case, async: true

  alias EvoGit.Runtime.Evolution.Fragment
  alias EvoGit.Runtime.Evolution.NoveltyMetric

  # ---------------------------------------------------------------------------
  # Helpers
  # ---------------------------------------------------------------------------

  # Build a fragment with a fully-populated, deterministic feature vector.
  defp build_fragment(content \\ "def foo, do: :ok", sf_overrides \\ []) do
    structural_features =
      %{
        nesting_depth: 1,
        function_count: 1,
        control_flow_count: 0,
        comment_density: 0.0,
        import_count: 0,
        avg_line_length: 20.0,
        string_literal_count: 0,
        numeric_literal_count: 0,
        line_count: 1,
        char_count: 20
      }
      |> Map.merge(Map.new(sf_overrides))

    behavioral_profile = %{complexity: 0.5, paradigm: :functional, abstraction: 0.3}

    %Fragment{
      Fragment.new(content, domain: "test")
      | structural_features: structural_features,
        behavioral_profile: behavioral_profile
    }
  end

  # A fragment with ONLY structural features (no behavioral profile).
  defp build_structural_only_fragment(content \\ "def bar, do: :ok", sf_overrides \\ []) do
    structural_features =
      %{
        nesting_depth: 1,
        function_count: 1,
        control_flow_count: 0,
        comment_density: 0.0,
        import_count: 0,
        avg_line_length: 20.0,
        string_literal_count: 0,
        numeric_literal_count: 0,
        line_count: 1,
        char_count: 20
      }
      |> Map.merge(Map.new(sf_overrides))

    %Fragment{
      Fragment.new(content, domain: "test")
      | structural_features: structural_features,
        behavioral_profile: %{}
    }
  end

  # ---------------------------------------------------------------------------
  # novelty_score/3
  # ---------------------------------------------------------------------------

  describe "novelty_score/3" do
    test "returns 1.0 for an empty reference set" do
      fragment = build_fragment()

      assert NoveltyMetric.novelty_score(fragment, []) == 1.0
    end

    test "returns 0.0 for a fragment identical to the single reference" do
      # Two fragments with the SAME structural_features and behavioral_profile
      # produce identical feature vectors → distance 0 → novelty 0.
      fragment = build_fragment()
      identical_reference = build_fragment()

      score = NoveltyMetric.novelty_score(fragment, [identical_reference])

      assert score == 0.0
    end

    test "with k: 1 uses only the single nearest neighbor" do
      # The nearest neighbor (identical) dominates with k: 1.
      fragment = build_fragment()
      identical = build_fragment()
      distant = build_fragment("def baz(x), do: x + 9999", nesting_depth: 10, function_count: 9)

      # With k: 1, the identical neighbor (distance 0) should be selected,
      # yielding a score of 0.0 even though a distant neighbor exists.
      score = NoveltyMetric.novelty_score(fragment, [identical, distant], k: 1)

      assert score == 0.0
    end

    test "with k larger than the reference set size, uses all available references" do
      fragment = build_fragment()
      identical = build_fragment()

      # k: 100 but only 1 reference — must not crash, averages over the 1 reference.
      score = NoveltyMetric.novelty_score(fragment, [identical], k: 100)

      assert score == 0.0
    end

    test "score is always a float >= 0.0" do
      fragment = build_fragment()
      reference = build_fragment("def baz(x), do: x + 9999", nesting_depth: 5, function_count: 4)

      score = NoveltyMetric.novelty_score(fragment, [reference], k: 2)

      assert is_float(score)
      assert score >= 0.0
    end

    test "returns a positive float for a fragment distinct from the reference" do
      fragment = build_fragment()
      distant = build_fragment("def baz(x), do: x + 9999", nesting_depth: 10, function_count: 9)

      score = NoveltyMetric.novelty_score(fragment, [distant])

      assert is_float(score)
      assert score > 0.0
    end

    test "defaults to k of 5 when no option is given" do
      fragment = build_fragment()
      identical = build_fragment()

      # A single identical reference → score is 0 regardless of default k.
      score = NoveltyMetric.novelty_score(fragment, [identical])

      assert score == 0.0
    end
  end

  # ---------------------------------------------------------------------------
  # distance/2
  # ---------------------------------------------------------------------------

  describe "distance/2" do
    test "returns 1.0 for two fragments with empty features (default %{})" do
      a = %Fragment{
        Fragment.new("x", domain: "t")
        | structural_features: %{},
          behavioral_profile: %{}
      }

      b = %Fragment{
        Fragment.new("y", domain: "t")
        | structural_features: %{},
          behavioral_profile: %{}
      }

      assert NoveltyMetric.distance(a, b) == 1.0
    end

    test "returns 0.0 for two fragments with identical populated features" do
      a = build_fragment()
      b = build_fragment()

      assert NoveltyMetric.distance(a, b) == 0.0
    end

    test "returns a positive float for two fragments with different features" do
      a = build_fragment()
      b = build_fragment("def baz(x), do: x + 9999", nesting_depth: 8, function_count: 7)

      dist = NoveltyMetric.distance(a, b)

      assert is_float(dist)
      assert dist > 0.0
    end

    test "handles mismatched vector lengths (structural-only vs structural + behavioral)" do
      # One fragment has structural features only; the other has both
      # structural + behavioral. The shorter vector is padded with zeros.
      a = build_structural_only_fragment()
      b = build_fragment()

      dist = NoveltyMetric.distance(a, b)

      assert is_float(dist)
      assert dist >= 0.0
    end

    test "distance is symmetric" do
      a = build_fragment()
      b = build_fragment("def baz(x), do: x + 9999", nesting_depth: 8, function_count: 7)

      assert NoveltyMetric.distance(a, b) == NoveltyMetric.distance(b, a)
    end
  end

  # ---------------------------------------------------------------------------
  # batch_novelty_scores/3
  # ---------------------------------------------------------------------------

  describe "batch_novelty_scores/3" do
    test "returns [] for an empty fragments list" do
      reference = build_fragment()

      assert NoveltyMetric.batch_novelty_scores([], [reference], k: 5) == []
    end

    test "results are sorted by score descending (most novel first)" do
      # A fragment identical to the reference → score 0 (least novel).
      # A distinct fragment → positive score (most novel).
      identical = build_fragment()
      distinct = build_fragment("def baz(x), do: x + 9999", nesting_depth: 10, function_count: 9)
      reference = build_fragment()

      results = NoveltyMetric.batch_novelty_scores([identical, distinct], [reference], k: 1)

      scores = Enum.map(results, fn {_fragment, score} -> score end)

      assert length(results) == 2
      assert scores == Enum.sort_by(scores, & &1, :desc)
      assert hd(scores) >= List.last(scores)
    end

    test "each element is a {Fragment, float} tuple" do
      a = build_fragment()
      b = build_fragment("def baz(x), do: x + 9999", nesting_depth: 10, function_count: 9)
      reference = build_fragment()

      results = NoveltyMetric.batch_novelty_scores([a, b], [reference], k: 1)

      for {fragment, score} <- results do
        assert %Fragment{} = fragment
        assert is_float(score)
      end
    end
  end

  # ---------------------------------------------------------------------------
  # structural_features/1
  # ---------------------------------------------------------------------------

  describe "structural_features/1" do
    test "returns a map with :line_count and :char_count keys" do
      features = NoveltyMetric.structural_features("def foo, do: :ok")

      assert is_map(features)
      assert Map.has_key?(features, :line_count)
      assert Map.has_key?(features, :char_count)
    end

    test "char_count equals String.length(content) for the given string" do
      content = "def foo, do: :ok"
      features = NoveltyMetric.structural_features(content)

      assert features[:char_count] == String.length(content)
    end

    test "delegates to Fragment.extract_structural_features and matches its output" do
      content = "defmodule Bar do\n  def baz, do: :ok\nend\n"
      features = NoveltyMetric.structural_features(content)

      direct = Fragment.extract_structural_features(Fragment.new(content, domain: "temp"))

      assert features == direct
    end

    test "handles multiline content" do
      content = """
      defmodule Foo do
        def bar(x) do
          x + 1
        end
      end
      """

      features = NoveltyMetric.structural_features(content)

      assert features[:char_count] == String.length(content)
      assert features[:line_count] == String.split(content, "\n", trim: true) |> length()
    end
  end

  # ---------------------------------------------------------------------------
  # most_redundant/1
  # ---------------------------------------------------------------------------

  describe "most_redundant/1" do
    test "returns nil for an empty list" do
      assert NoveltyMetric.most_redundant([]) == nil
    end

    test "returns the single fragment for a one-element list" do
      only = build_fragment()

      assert NoveltyMetric.most_redundant([only]) == only
    end

    test "returns the fragment most similar to the others (lowest novelty)" do
      # Two identical fragments and one clearly distinct fragment.
      # The identical fragments are redundant relative to each other.
      dup_a = build_fragment()
      dup_b = build_fragment()
      unique = build_fragment("def baz(x), do: x + 9999", nesting_depth: 10, function_count: 9)

      result = NoveltyMetric.most_redundant([dup_a, dup_b, unique])

      # The result must be one of the two duplicates, never the unique fragment.
      assert result in [dup_a, dup_b]
    end

    test "returns a Fragment struct for a non-empty list" do
      a = build_fragment()
      b = build_fragment("def baz(x), do: x + 9999", nesting_depth: 10, function_count: 9)

      result = NoveltyMetric.most_redundant([a, b])

      assert %Fragment{} = result
    end
  end
end
