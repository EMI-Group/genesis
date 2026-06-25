defmodule EvoGit.Runtime.Evolution.EntropyPoolTest do
  use ExUnit.Case, async: false

  alias EvoGit.Runtime.Evolution.EntropyPool
  alias EvoGit.Runtime.Evolution.Fragment

  setup do
    try do
      EntropyPool.stop()
    catch
      _, _ -> :ok
    end

    {:ok, _pid} = EntropyPool.start_link()
    Process.sleep(10)
    EntropyPool.clear()
    Process.sleep(10)

    on_exit(fn ->
      try do
        EntropyPool.stop()
      catch
        _, _ -> :ok
      end
    end)

    :ok
  end

  # Helper to build a fragment with a controlled novelty score.
  defp build_fragment(content, opts) do
    novelty = Keyword.get(opts, :novelty, 0.5)
    %Fragment{Fragment.new(content, domain: "t") | novelty_score: novelty}
  end

  describe "insert/1" do
    test "inserts a fragment retrievable via get/1" do
      fragment = build_fragment("def foo, do: :ok", novelty: 0.5)

      EntropyPool.insert(fragment)
      Process.sleep(20)

      assert EntropyPool.get(fragment.id) == fragment
    end

    test "increments the pool size" do
      fragment = build_fragment("hello world", novelty: 0.1)

      EntropyPool.insert(fragment)
      Process.sleep(20)

      assert EntropyPool.size() == 1
    end

    test "returns :ok" do
      fragment = build_fragment("code", novelty: 0.2)
      assert EntropyPool.insert(fragment) == :ok
      Process.sleep(20)
    end
  end

  describe "get/1" do
    test "returns nil for a non-existent id" do
      assert EntropyPool.get("does-not-exist-1234") == nil
    end

    test "returns the fragment after insertion" do
      fragment = build_fragment("x = 1", novelty: 0.7)

      EntropyPool.insert(fragment)
      Process.sleep(20)

      assert EntropyPool.get(fragment.id) == fragment
    end
  end

  describe "insert_all/1" do
    test "inserts multiple fragments" do
      fragments = [
        build_fragment("one", novelty: 0.1),
        build_fragment("two", novelty: 0.2),
        build_fragment("three", novelty: 0.3)
      ]

      EntropyPool.insert_all(fragments)
      Process.sleep(20)

      Enum.each(fragments, fn fragment ->
        assert EntropyPool.get(fragment.id) == fragment
      end)

      assert EntropyPool.size() == 3
    end

    test "inserting an empty list keeps the pool empty" do
      EntropyPool.insert_all([])
      Process.sleep(20)

      assert EntropyPool.size() == 0
    end

    test "returns :ok" do
      assert EntropyPool.insert_all([build_fragment("a", novelty: 0.1)]) == :ok
      Process.sleep(20)
    end
  end

  describe "all/0" do
    test "returns an empty list for an empty pool" do
      assert EntropyPool.all() == []
    end

    test "returns all inserted fragments" do
      f1 = build_fragment("a", novelty: 0.1)
      f2 = build_fragment("b", novelty: 0.2)

      EntropyPool.insert_all([f1, f2])
      Process.sleep(20)

      result = EntropyPool.all()
      assert length(result) == 2
      assert f1 in result
      assert f2 in result

      Enum.each(result, fn fragment ->
        assert %Fragment{} = fragment
      end)
    end
  end

  describe "size/0" do
    test "returns 0 for an empty pool" do
      assert EntropyPool.size() == 0
    end

    test "reflects the number of inserted fragments" do
      EntropyPool.insert_all([
        build_fragment("a", novelty: 0.1),
        build_fragment("b", novelty: 0.2),
        build_fragment("c", novelty: 0.3)
      ])

      Process.sleep(20)

      assert EntropyPool.size() == 3
    end
  end

  describe "select_novel/1" do
    test "returns an empty list for an empty pool" do
      assert EntropyPool.select_novel(2) == []
    end

    test "returns the top n fragments by novelty_score descending" do
      low = build_fragment("low", novelty: 0.1)
      mid = build_fragment("mid", novelty: 0.5)
      high = build_fragment("high", novelty: 0.9)

      EntropyPool.insert_all([low, mid, high])
      Process.sleep(20)

      result = EntropyPool.select_novel(2)

      assert length(result) == 2
      assert hd(result) == high
      assert Enum.at(result, 1) == mid
    end

    test "returns fewer than n when pool is smaller than n" do
      EntropyPool.insert_all([
        build_fragment("a", novelty: 0.1),
        build_fragment("b", novelty: 0.2)
      ])

      Process.sleep(20)

      assert length(EntropyPool.select_novel(5)) == 2
    end
  end

  describe "select_random/1" do
    test "returns an empty list for an empty pool" do
      assert EntropyPool.select_random(2) == []
    end

    test "returns at most n fragments from the pool" do
      EntropyPool.insert_all([
        build_fragment("a", novelty: 0.1),
        build_fragment("b", novelty: 0.2),
        build_fragment("c", novelty: 0.3)
      ])

      Process.sleep(20)

      result = EntropyPool.select_random(2)
      assert length(result) == 2
    end

    test "returns all available fragments when n exceeds pool size" do
      EntropyPool.insert_all([
        build_fragment("a", novelty: 0.1),
        build_fragment("b", novelty: 0.2)
      ])

      Process.sleep(20)

      result = EntropyPool.select_random(10)
      assert length(result) == 2

      all = EntropyPool.all()

      Enum.each(result, fn fragment ->
        assert fragment in all
      end)
    end

    test "does not return duplicates (samples without replacement)" do
      EntropyPool.insert_all([
        build_fragment("a", novelty: 0.1),
        build_fragment("b", novelty: 0.2),
        build_fragment("c", novelty: 0.3)
      ])

      Process.sleep(20)

      result = EntropyPool.select_random(3)
      ids = Enum.map(result, & &1.id)
      assert length(ids) == length(Enum.uniq(ids))
    end
  end

  describe "evict_most_redundant/0" do
    test "returns nil for an empty pool" do
      assert EntropyPool.evict_most_redundant() == nil
    end

    test "removes and returns the lowest novelty fragment" do
      low = build_fragment("low", novelty: 0.1)
      mid = build_fragment("mid", novelty: 0.5)
      high = build_fragment("high", novelty: 0.9)

      EntropyPool.insert_all([low, mid, high])
      Process.sleep(20)

      assert EntropyPool.size() == 3

      evicted = EntropyPool.evict_most_redundant()
      assert evicted == low

      assert EntropyPool.size() == 2
      assert EntropyPool.get(low.id) == nil
      assert EntropyPool.get(mid.id) == mid
      assert EntropyPool.get(high.id) == high
    end

    test "evicts sequentially keeping the pool shrinking" do
      low = build_fragment("low", novelty: 0.1)
      mid = build_fragment("mid", novelty: 0.5)
      high = build_fragment("high", novelty: 0.9)

      EntropyPool.insert_all([low, mid, high])
      Process.sleep(20)

      assert EntropyPool.evict_most_redundant() == low
      assert EntropyPool.evict_most_redundant() == mid
      assert EntropyPool.evict_most_redundant() == high
      assert EntropyPool.evict_most_redundant() == nil
      assert EntropyPool.size() == 0
    end
  end

  describe "update_fragment/1" do
    test "updates an existing fragment matched by id" do
      fragment = build_fragment("original", novelty: 0.1)

      EntropyPool.insert(fragment)
      Process.sleep(20)

      updated = %Fragment{fragment | novelty_score: 0.9}
      EntropyPool.update_fragment(updated)
      Process.sleep(20)

      assert EntropyPool.get(fragment.id) == updated
      assert EntropyPool.get(fragment.id).novelty_score == 0.9
    end

    test "does not change the pool size when updating an existing fragment" do
      fragment = build_fragment("original", novelty: 0.1)

      EntropyPool.insert(fragment)
      Process.sleep(20)

      assert EntropyPool.size() == 1

      updated = %Fragment{fragment | novelty_score: 0.9}
      EntropyPool.update_fragment(updated)
      Process.sleep(20)

      assert EntropyPool.size() == 1
    end

    test "returns :ok" do
      fragment = build_fragment("original", novelty: 0.1)
      EntropyPool.insert(fragment)
      Process.sleep(20)

      assert EntropyPool.update_fragment(%Fragment{fragment | novelty_score: 0.9}) == :ok
      Process.sleep(20)
    end
  end

  describe "clear/0" do
    test "removes all fragments" do
      EntropyPool.insert_all([
        build_fragment("a", novelty: 0.1),
        build_fragment("b", novelty: 0.2),
        build_fragment("c", novelty: 0.3)
      ])

      Process.sleep(20)

      assert EntropyPool.size() == 3

      assert EntropyPool.clear() == :ok
      Process.sleep(20)

      assert EntropyPool.size() == 0
      assert EntropyPool.all() == []
    end
  end

  describe "auto-eviction on overflow" do
    test "evicts the lowest-novelty fragment when max_size is exceeded" do
      # Stop the default pool and restart with a small max_size.
      EntropyPool.stop()
      {:ok, _} = EntropyPool.start_link(max_size: 3)
      Process.sleep(10)

      lowest = build_fragment("lowest", novelty: 0.1)
      mid = build_fragment("mid", novelty: 0.5)
      high = build_fragment("high", novelty: 0.9)
      extra = build_fragment("extra", novelty: 0.3)

      EntropyPool.insert(lowest)
      EntropyPool.insert(mid)
      EntropyPool.insert(high)
      Process.sleep(20)

      assert EntropyPool.size() == 3

      # Inserting a 4th fragment should trigger auto-eviction of the lowest.
      EntropyPool.insert(extra)
      Process.sleep(20)

      assert EntropyPool.size() == 3
      assert EntropyPool.get(lowest.id) == nil
      assert EntropyPool.get(mid.id) == mid
      assert EntropyPool.get(high.id) == high
      assert EntropyPool.get(extra.id) == extra
    end

    test "evicts the correct fragment when inserting via insert_all overflow" do
      EntropyPool.stop()
      {:ok, _} = EntropyPool.start_link(max_size: 3)
      Process.sleep(10)

      lowest = build_fragment("lowest", novelty: 0.1)
      mid = build_fragment("mid", novelty: 0.5)
      high = build_fragment("high", novelty: 0.9)
      extra = build_fragment("extra", novelty: 0.2)

      EntropyPool.insert_all([lowest, mid, high, extra])
      Process.sleep(20)

      # With max_size 3 and 4 inserted, exactly 1 fragment is evicted:
      # the one with the lowest novelty_score (lowest = 0.1).
      assert EntropyPool.size() == 3
      assert EntropyPool.get(lowest.id) == nil
      assert EntropyPool.get(extra.id) == extra
      assert EntropyPool.get(mid.id) == mid
      assert EntropyPool.get(high.id) == high
    end
  end
end
