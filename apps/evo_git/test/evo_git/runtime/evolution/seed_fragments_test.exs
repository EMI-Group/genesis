defmodule EvoGit.Runtime.Evolution.SeedFragmentsTest do
  use ExUnit.Case, async: true

  alias EvoGit.Runtime.Evolution.Fragment
  alias EvoGit.Runtime.Evolution.SeedFragments

  describe "all/0" do
    test "returns a non-empty list" do
      fragments = SeedFragments.all()
      assert is_list(fragments)
      refute Enum.empty?(fragments)
    end

    test "returns exactly 15 fragments" do
      assert length(SeedFragments.all()) == 15
    end

    test "every element is a Fragment struct" do
      for fragment <- SeedFragments.all() do
        assert match?(%Fragment{}, fragment)
      end
    end

    test "every fragment has a non-empty content string" do
      for fragment <- SeedFragments.all() do
        assert is_binary(fragment.content)
        assert String.length(fragment.content) > 0
      end
    end

    test "every fragment has language elixir" do
      for fragment <- SeedFragments.all() do
        assert fragment.language == "elixir"
      end
    end

    test "every fragment has a non-empty domain string" do
      for fragment <- SeedFragments.all() do
        assert is_binary(fragment.domain)
        assert String.length(fragment.domain) > 0
      end
    end

    test "every fragment has source :seed" do
      for fragment <- SeedFragments.all() do
        assert fragment.source == :seed
      end
    end

    test "every fragment has generation 0" do
      for fragment <- SeedFragments.all() do
        assert fragment.generation == 0
      end
    end

    test "covers all expected domains" do
      domains =
        SeedFragments.all()
        |> Enum.map(& &1.domain)
        |> Enum.sort()

      expected =
        [
          "physics",
          "game_loop",
          "data_pipeline",
          "http_handler",
          "graph_algorithm",
          "pattern_matching",
          "process_pool",
          "stream_processing",
          "sorting",
          "encoding",
          "middleware",
          "tree_traversal",
          "rate_limiter",
          "cache_ttl",
          "event_emitter"
        ]
        |> Enum.sort()

      assert domains == expected
    end

    test "all fragments have unique ids" do
      ids = Enum.map(SeedFragments.all(), & &1.id)
      assert length(Enum.uniq(ids)) == length(ids)
    end
  end

  describe "by_category/1" do
    test "by_category(:physics) returns a list of length 1" do
      fragments = SeedFragments.by_category(:physics)
      assert length(fragments) == 1
    end

    test "by_category(:physics) returns a fragment with domain physics" do
      for fragment <- SeedFragments.by_category(:physics) do
        assert fragment.domain == "physics"
      end
    end

    test "string form returns the same domains as atom form" do
      # Fragments have a random id and timestamp generated on each call, so we
      # compare by domain/content rather than full struct equality.
      atom_domains = SeedFragments.by_category(:physics) |> Enum.map(& &1.content)
      string_domains = SeedFragments.by_category("physics") |> Enum.map(& &1.content)
      assert string_domains == atom_domains
    end

    test "by_category(:nonexistent) returns an empty list" do
      assert SeedFragments.by_category(:nonexistent) == []
    end

    test "string form for nonexistent category also returns empty list" do
      assert SeedFragments.by_category("nonexistent") == []
    end

    test "by_category(:game_loop) returns a list of length 1" do
      assert length(SeedFragments.by_category(:game_loop)) == 1
    end

    test "by_category(:game_loop) returns a fragment with domain game_loop" do
      for fragment <- SeedFragments.by_category(:game_loop) do
        assert fragment.domain == "game_loop"
      end
    end

    test "returned fragments' domain matches the category string" do
      categories = [
        :physics,
        :game_loop,
        :data_pipeline,
        :http_handler,
        :graph_algorithm,
        :pattern_matching,
        :process_pool,
        :stream_processing,
        :sorting,
        :encoding,
        :middleware,
        :tree_traversal,
        :rate_limiter,
        :cache_ttl,
        :event_emitter
      ]

      for category <- categories do
        cat_str = Atom.to_string(category)
        fragments = SeedFragments.by_category(category)

        for fragment <- fragments do
          assert fragment.domain == cat_str
        end
      end
    end

    test "returns Fragment structs" do
      for fragment <- SeedFragments.by_category(:physics) do
        assert match?(%Fragment{}, fragment)
      end
    end
  end

  describe "random/1" do
    test "random(1) returns a list of exactly 1 fragment" do
      assert length(SeedFragments.random(1)) == 1
    end

    test "random(5) returns a list of exactly 5 fragments" do
      assert length(SeedFragments.random(5)) == 5
    end

    test "random(15) returns all 15 fragments" do
      assert length(SeedFragments.random(15)) == 15
    end

    test "random(100) returns at most 15 fragments and does not crash" do
      result = SeedFragments.random(100)
      assert length(result) <= 15
      assert is_list(result)
    end

    test "all returned elements are Fragment structs" do
      for fragment <- SeedFragments.random(5) do
        assert match?(%Fragment{}, fragment)
      end
    end

    test "all returned fragments are unique by id (no duplicates)" do
      fragments = SeedFragments.random(10)
      ids = Enum.map(fragments, & &1.id)
      assert length(Enum.uniq(ids)) == length(ids)
    end

    test "random(15) returns fragments with no duplicate ids" do
      fragments = SeedFragments.random(15)
      ids = Enum.map(fragments, & &1.id)
      assert length(Enum.uniq(ids)) == 15
    end
  end
end
