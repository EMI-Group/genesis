defmodule EvoGit.Agent.UsageTest do
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
end
