defmodule EvoGit.Agent.UsageTest do
  @moduledoc """
  `async: true` — pure `EvoGit.Agent.Usage` struct arithmetic (`zero/0`,
  `from_response_usage/1`, `add/2`, `cache_hit_rate/1`, archive maps); no
  shared/global state is touched.
  """

  use ExUnit.Case, async: true

  alias EvoGit.Agent.Usage

  # ==========================================================================
  # zero/0
  # ==========================================================================
  describe "zero/0" do
    test "returns a struct with all fields defaulted to zero" do
      usage = Usage.zero()

      assert %Usage{} = usage
      assert usage.input_tokens == 0
      assert usage.output_tokens == 0
      assert usage.total_tokens == 0
      assert usage.input_cost == 0.0
      assert usage.output_cost == 0.0
      assert usage.total_cost == 0.0
      assert usage.cached_tokens == 0
      assert usage.cache_creation_tokens == 0
    end
  end

  # ==========================================================================
  # from_response_usage/1
  # ==========================================================================
  describe "from_response_usage/1" do
    test "with nil returns zero struct" do
      usage = Usage.from_response_usage(nil)

      assert %Usage{} = usage
      assert usage == Usage.zero()
    end

    test "extracts all fields including cached_tokens and cache_creation_tokens" do
      map = %{
        input_tokens: 1000,
        output_tokens: 500,
        total_tokens: 1500,
        input_cost: 0.01,
        output_cost: 0.02,
        total_cost: 0.03,
        cached_tokens: 400,
        cache_creation_tokens: 200
      }

      usage = Usage.from_response_usage(map)

      assert usage.input_tokens == 1000
      assert usage.output_tokens == 500
      assert usage.total_tokens == 1500
      assert usage.input_cost == 0.01
      assert usage.output_cost == 0.02
      assert usage.total_cost == 0.03
      assert usage.cached_tokens == 400
      assert usage.cache_creation_tokens == 200
    end

    test "handles missing cache fields gracefully (defaults to 0)" do
      map = %{
        input_tokens: 1000,
        output_tokens: 500,
        total_tokens: 1500,
        input_cost: 0.01,
        output_cost: 0.02,
        total_cost: 0.03
      }

      usage = Usage.from_response_usage(map)

      assert usage.cached_tokens == 0
      assert usage.cache_creation_tokens == 0
    end

    test "handles nil values in the map (the `|| 0` pattern)" do
      map = %{
        input_tokens: nil,
        output_tokens: nil,
        total_tokens: nil,
        input_cost: nil,
        output_cost: nil,
        total_cost: nil,
        cached_tokens: nil,
        cache_creation_tokens: nil
      }

      usage = Usage.from_response_usage(map)

      assert usage.input_tokens == 0
      assert usage.output_tokens == 0
      assert usage.total_tokens == 0
      assert usage.input_cost == 0.0
      assert usage.output_cost == 0.0
      assert usage.total_cost == 0.0
      assert usage.cached_tokens == 0
      assert usage.cache_creation_tokens == 0
    end
  end

  # ==========================================================================
  # add/2
  # ==========================================================================
  describe "add/2" do
    test "accumulates all fields including the two new cache fields" do
      a = %Usage{
        input_tokens: 1000,
        output_tokens: 500,
        total_tokens: 1500,
        input_cost: 0.01,
        output_cost: 0.02,
        total_cost: 0.03,
        cached_tokens: 400,
        cache_creation_tokens: 200
      }

      b = %Usage{
        input_tokens: 2000,
        output_tokens: 700,
        total_tokens: 2700,
        input_cost: 0.04,
        output_cost: 0.05,
        total_cost: 0.09,
        cached_tokens: 600,
        cache_creation_tokens: 300
      }

      result = Usage.add(a, b)

      assert result.input_tokens == 3000
      assert result.output_tokens == 1200
      assert result.total_tokens == 4200
      assert result.input_cost == 0.05
      assert result.output_cost == 0.07
      assert result.total_cost == 0.12
      assert result.cached_tokens == 1000
      assert result.cache_creation_tokens == 500
    end

    test "adding zero usage is a no-op" do
      usage = %Usage{
        input_tokens: 1000,
        output_tokens: 500,
        total_tokens: 1500,
        cached_tokens: 400,
        cache_creation_tokens: 200
      }

      result = Usage.add(usage, Usage.zero())

      assert result.input_tokens == 1000
      assert result.cached_tokens == 400
      assert result.cache_creation_tokens == 200
    end
  end

  # ==========================================================================
  # cache_hit_rate/1
  # ==========================================================================
  describe "cache_hit_rate/1" do
    test "returns 0.0 when input_tokens is 0" do
      usage = %Usage{input_tokens: 0, cached_tokens: 100}

      assert Usage.cache_hit_rate(usage) == 0.0
    end

    test "computes correct percentage when cached_tokens present" do
      # 500 of 1000 input tokens cached = 50%
      usage = %Usage{input_tokens: 1000, cached_tokens: 500}

      assert Usage.cache_hit_rate(usage) == 50.0
    end

    test "returns 0.0 when cached_tokens is 0 but input_tokens > 0" do
      usage = %Usage{input_tokens: 1000, cached_tokens: 0}

      assert Usage.cache_hit_rate(usage) == 0.0
    end

    test "returns 100.0 when all input tokens are cached" do
      usage = %Usage{input_tokens: 1000, cached_tokens: 1000}

      assert Usage.cache_hit_rate(usage) == 100.0
    end

    test "returns 0.0 for a fresh zero struct" do
      assert Usage.cache_hit_rate(Usage.zero()) == 0.0
    end
  end

  # ==========================================================================
  # archive_usage_keys/0
  # ==========================================================================
  describe "archive_usage_keys/0" do
    test "returns exactly the 9 canonical archive usage-map keys" do
      assert Usage.archive_usage_keys() == [
               :input_tokens,
               :output_tokens,
               :total_tokens,
               :input_cost,
               :output_cost,
               :total_cost,
               :cached_tokens,
               :cache_creation_tokens,
               :cache_hit_rate
             ]
    end
  end

  # ==========================================================================
  # from_archive_map/1
  # ==========================================================================
  describe "from_archive_map/1" do
    test "returns zero usage for nil" do
      assert Usage.from_archive_map(nil) == Usage.zero()
    end

    test "returns an existing %Usage{} unchanged" do
      usage = %Usage{input_tokens: 7, total_cost: 1.5}
      assert Usage.from_archive_map(usage) == usage
    end

    test "parses an atom-keyed archive usage map (live ETS shape)" do
      usage =
        Usage.from_archive_map(%{
          input_tokens: 100,
          output_tokens: 50,
          total_tokens: 150,
          input_cost: 0.005,
          output_cost: 0.01,
          total_cost: 0.015,
          cached_tokens: 40,
          cache_creation_tokens: 20,
          cache_hit_rate: 40.0
        })

      assert usage == %Usage{
               input_tokens: 100,
               output_tokens: 50,
               total_tokens: 150,
               input_cost: 0.005,
               output_cost: 0.01,
               total_cost: 0.015,
               cached_tokens: 40,
               cache_creation_tokens: 20
             }
    end

    test "parses a string-keyed archive usage map (post-JSON round-trip shape)" do
      usage =
        Usage.from_archive_map(%{
          "input_tokens" => 100,
          "output_tokens" => 50,
          "total_tokens" => 150,
          "input_cost" => 0.005,
          "output_cost" => 0.01,
          "total_cost" => 0.015,
          "cached_tokens" => 40,
          "cache_creation_tokens" => 20,
          "cache_hit_rate" => 40.0
        })

      assert usage == %Usage{
               input_tokens: 100,
               output_tokens: 50,
               total_tokens: 150,
               input_cost: 0.005,
               output_cost: 0.01,
               total_cost: 0.015,
               cached_tokens: 40,
               cache_creation_tokens: 20
             }
    end

    test "defaults missing keys and nil values to zero (legacy/partial records)" do
      usage = Usage.from_archive_map(%{"input_tokens" => 10, "output_cost" => nil})

      assert usage.input_tokens == 10
      assert usage.output_tokens == 0
      assert usage.output_cost == 0.0
      assert usage.total_cost == 0.0
      assert usage.cached_tokens == 0
    end

    test "ignores the derived cache_hit_rate key (recomputed via cache_hit_rate/1)" do
      usage =
        Usage.from_archive_map(%{
          input_tokens: 100,
          cached_tokens: 40,
          cache_hit_rate: 40.0
        })

      refute Map.has_key?(Map.from_struct(usage), :cache_hit_rate)
      assert Usage.cache_hit_rate(usage) == 40.0
    end
  end
end
