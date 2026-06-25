defmodule EvoGit.Runtime.Evolution.MapElitesTest do
  use ExUnit.Case, async: false

  alias EvoGit.Runtime.Evolution.Fragment
  alias EvoGit.Runtime.Evolution.MapElites

  # MAP-Elites uses a global singleton ETS table and a hardcoded via_name().
  # Only one instance can exist per VM, so every test must start/stop it carefully.

  setup do
    # Stop if already running, ignore errors
    try do
      MapElites.stop()
    catch
      _, _ -> :ok
    end

    # Brief pause to ensure ETS table from prior process is fully cleaned up
    Process.sleep(10)

    {:ok, _pid} = MapElites.start_link()
    # start_link is synchronous, but allow a tick for the runtime to settle
    Process.sleep(10)

    on_exit(fn ->
      try do
        MapElites.stop()
      catch
        _, _ -> :ok
      end
    end)

    :ok
  end

  # Helper: build a fragment with a given behavioral profile and novelty score.
  defp build_fragment(content, bp, novelty_score) do
    %Fragment{
      Fragment.new(content, domain: "test")
      | behavioral_profile: bp,
        novelty_score: novelty_score
    }
  end

  # ---------------------------------------------------------------------------
  # descriptor_for/1 — pure function (no GenServer required, but setup runs it)
  # ---------------------------------------------------------------------------

  describe "descriptor_for/1" do
    test "returns {5, 1} for a default (empty) behavioral profile" do
      frag = Fragment.new("code", domain: "test")
      assert MapElites.descriptor_for(frag) == {5, 1}
    end

    test "bins complexity 0.0 into bin 0" do
      frag = %Fragment{
        Fragment.new("c", domain: "t")
        | behavioral_profile: %{complexity: 0.0, paradigm: :functional}
      }

      assert MapElites.descriptor_for(frag) == {0, 0}
    end

    test "bins complexity 0.04 into bin 0 (floor)" do
      frag = %Fragment{
        Fragment.new("c", domain: "t")
        | behavioral_profile: %{complexity: 0.04, paradigm: :functional}
      }

      assert MapElites.descriptor_for(frag) == {0, 0}
    end

    test "bins complexity 0.15 into bin 1 (floor)" do
      frag = %Fragment{
        Fragment.new("c", domain: "t")
        | behavioral_profile: %{complexity: 0.15, paradigm: :functional}
      }

      assert MapElites.descriptor_for(frag) == {1, 0}
    end

    test "bins complexity 0.3 into bin 3" do
      frag = %Fragment{
        Fragment.new("c", domain: "t")
        | behavioral_profile: %{complexity: 0.3, paradigm: :functional}
      }

      assert MapElites.descriptor_for(frag) == {3, 0}
    end

    test "bins complexity 0.5 into bin 5" do
      frag = %Fragment{
        Fragment.new("c", domain: "t")
        | behavioral_profile: %{complexity: 0.5, paradigm: :mixed}
      }

      assert MapElites.descriptor_for(frag) == {5, 1}
    end

    test "bins complexity 0.95 into bin 9" do
      frag = %Fragment{
        Fragment.new("c", domain: "t")
        | behavioral_profile: %{complexity: 0.95, paradigm: :mixed}
      }

      assert MapElites.descriptor_for(frag) == {9, 1}
    end

    test "bins complexity 1.0 into bin 9 (clamped from 10)" do
      frag = %Fragment{
        Fragment.new("c", domain: "t")
        | behavioral_profile: %{complexity: 1.0, paradigm: :mixed}
      }

      assert MapElites.descriptor_for(frag) == {9, 1}
    end

    test "clamps negative complexity to bin 0" do
      frag = %Fragment{
        Fragment.new("c", domain: "t")
        | behavioral_profile: %{complexity: -0.5, paradigm: :functional}
      }

      assert MapElites.descriptor_for(frag) == {0, 0}
    end

    test "clamps complexity above 1.0 to bin 9" do
      frag = %Fragment{
        Fragment.new("c", domain: "t")
        | behavioral_profile: %{complexity: 2.0, paradigm: :mixed}
      }

      assert MapElites.descriptor_for(frag) == {9, 1}
    end

    test "maps paradigm :functional to index 0" do
      frag = %Fragment{
        Fragment.new("c", domain: "t")
        | behavioral_profile: %{complexity: 0.5, paradigm: :functional}
      }

      assert MapElites.descriptor_for(frag) == {5, 0}
    end

    test "maps paradigm :mixed to index 1" do
      frag = %Fragment{
        Fragment.new("c", domain: "t")
        | behavioral_profile: %{complexity: 0.5, paradigm: :mixed}
      }

      assert MapElites.descriptor_for(frag) == {5, 1}
    end

    test "maps paradigm :declarative to index 2" do
      frag = %Fragment{
        Fragment.new("c", domain: "t")
        | behavioral_profile: %{complexity: 0.5, paradigm: :declarative}
      }

      assert MapElites.descriptor_for(frag) == {5, 2}
    end

    test "maps paradigm :imperative to index 3" do
      frag = %Fragment{
        Fragment.new("c", domain: "t")
        | behavioral_profile: %{complexity: 0.5, paradigm: :imperative}
      }

      assert MapElites.descriptor_for(frag) == {5, 3}
    end

    test "defaults unknown paradigm to index 1" do
      frag = %Fragment{
        Fragment.new("c", domain: "t")
        | behavioral_profile: %{complexity: 0.5, paradigm: :totally_unknown}
      }

      assert MapElites.descriptor_for(frag) == {5, 1}
    end

    test "defaults non-numeric complexity to bin 5" do
      frag = %Fragment{
        Fragment.new("c", domain: "t")
        | behavioral_profile: %{complexity: "high", paradigm: :functional}
      }

      assert MapElites.descriptor_for(frag) == {5, 0}
    end

    test "works when only complexity is set (paradigm defaults to :mixed)" do
      frag = %Fragment{
        Fragment.new("c", domain: "t")
        | behavioral_profile: %{complexity: 0.2}
      }

      assert MapElites.descriptor_for(frag) == {2, 1}
    end

    test "works when only paradigm is set (complexity defaults to 0.5)" do
      frag = %Fragment{
        Fragment.new("c", domain: "t")
        | behavioral_profile: %{paradigm: :declarative}
      }

      assert MapElites.descriptor_for(frag) == {5, 2}
    end
  end

  # ---------------------------------------------------------------------------
  # insert/1
  # ---------------------------------------------------------------------------

  describe "insert/1" do
    test "inserts a fragment into an empty cell and returns :ok" do
      frag = build_fragment("code1", %{complexity: 0.1, paradigm: :functional}, 0.5)

      assert MapElites.insert(frag) == :ok
      assert MapElites.size() == 1
    end

    test "inserts a second fragment into a different cell" do
      frag1 = build_fragment("code1", %{complexity: 0.1, paradigm: :functional}, 0.5)
      frag2 = build_fragment("code2", %{complexity: 0.9, paradigm: :declarative}, 0.7)

      assert MapElites.insert(frag1) == :ok
      assert MapElites.insert(frag2) == :ok
      assert MapElites.size() == 2
    end

    test "replaces the elite when the new fragment has a higher novelty_score" do
      old_frag = build_fragment("old", %{complexity: 0.2, paradigm: :mixed}, 0.3)
      new_frag = build_fragment("new", %{complexity: 0.2, paradigm: :mixed}, 0.8)

      assert MapElites.insert(old_frag) == :ok

      result = MapElites.insert(new_frag)
      assert {:replaced, returned} = result
      assert returned.id == old_frag.id
      assert returned.content == "old"

      # Cell still occupied by exactly one fragment
      assert MapElites.size() == 1
      # The elite is now the new fragment
      elite = MapElites.get_elite({2, 1})
      assert elite.id == new_frag.id
      assert elite.content == "new"
    end

    test "does not replace when the new fragment has a lower novelty_score" do
      high_frag = build_fragment("winner", %{complexity: 0.3, paradigm: :mixed}, 0.9)
      low_frag = build_fragment("loser", %{complexity: 0.3, paradigm: :mixed}, 0.2)

      assert MapElites.insert(high_frag) == :ok
      assert MapElites.insert(low_frag) == :ok

      # Still one cell, and the original high-novelty fragment is retained
      assert MapElites.size() == 1
      assert MapElites.get_elite({3, 1}).id == high_frag.id
    end

    test "does not replace when novelty scores are equal (strict >)" do
      frag_a = build_fragment("alpha", %{complexity: 0.4, paradigm: :functional}, 0.5)
      frag_b = build_fragment("beta", %{complexity: 0.4, paradigm: :functional}, 0.5)

      assert MapElites.insert(frag_a) == :ok
      assert MapElites.insert(frag_b) == :ok

      assert MapElites.size() == 1
      assert MapElites.get_elite({4, 0}).id == frag_a.id
    end

    test "filling multiple distinct cells grows the archive" do
      cells = [
        {%{complexity: 0.0, paradigm: :functional}, 0.1},
        {%{complexity: 0.5, paradigm: :mixed}, 0.2},
        {%{complexity: 1.0, paradigm: :declarative}, 0.3},
        {%{complexity: 0.3, paradigm: :imperative}, 0.4}
      ]

      for {{bp, novelty}, i} <- Enum.with_index(cells) do
        assert MapElites.insert(build_fragment("frag#{i}", bp, novelty)) == :ok
      end

      assert MapElites.size() == 4
      assert length(MapElites.get_elites()) == 4
    end
  end

  # ---------------------------------------------------------------------------
  # get_elite/1
  # ---------------------------------------------------------------------------

  describe "get_elite/1" do
    test "returns nil for an empty cell" do
      assert MapElites.get_elite({0, 0}) == nil
    end

    test "returns the fragment after insertion" do
      frag = build_fragment("hello", %{complexity: 0.7, paradigm: :imperative}, 0.6)
      assert MapElites.insert(frag) == :ok

      elite = MapElites.get_elite({7, 3})
      assert elite != nil
      assert elite.id == frag.id
      assert elite.content == "hello"
    end

    test "returns nil for a descriptor that maps to an unoccupied cell" do
      frag = build_fragment("hello", %{complexity: 0.7, paradigm: :imperative}, 0.6)
      MapElites.insert(frag)

      # {7, 3} is occupied but {0, 0} is not
      assert MapElites.get_elite({0, 0}) == nil
    end
  end

  # ---------------------------------------------------------------------------
  # get_elites/0
  # ---------------------------------------------------------------------------

  describe "get_elites/0" do
    test "returns an empty list when the archive is empty" do
      assert MapElites.get_elites() == []
    end

    test "returns all {descriptor, fragment} pairs after inserts" do
      frag1 = build_fragment("a", %{complexity: 0.1, paradigm: :functional}, 0.5)
      frag2 = build_fragment("b", %{complexity: 0.9, paradigm: :declarative}, 0.7)

      MapElites.insert(frag1)
      MapElites.insert(frag2)

      elites = MapElites.get_elites()
      assert length(elites) == 2

      descriptors =
        elites
        |> Enum.map(fn {descriptor, _fragment} -> descriptor end)
        |> Enum.sort()

      assert descriptors == [{1, 0}, {9, 2}]

      for {_descriptor, fragment} <- elites do
        assert %Fragment{} = fragment
      end
    end
  end

  # ---------------------------------------------------------------------------
  # all_fragments/0
  # ---------------------------------------------------------------------------

  describe "all_fragments/0" do
    test "returns an empty list when the archive is empty" do
      assert MapElites.all_fragments() == []
    end

    test "returns all fragments after inserts" do
      frag1 = build_fragment("a", %{complexity: 0.2, paradigm: :functional}, 0.5)
      frag2 = build_fragment("b", %{complexity: 0.8, paradigm: :mixed}, 0.7)

      MapElites.insert(frag1)
      MapElites.insert(frag2)

      fragments = MapElites.all_fragments()
      assert length(fragments) == 2
      assert Enum.all?(fragments, &match?(%Fragment{}, &1))

      ids = Enum.map(fragments, & &1.id) |> MapSet.new()
      assert MapSet.new([frag1.id, frag2.id]) == ids
    end
  end

  # ---------------------------------------------------------------------------
  # size/0
  # ---------------------------------------------------------------------------

  describe "size/0" do
    test "returns 0 for an empty archive" do
      assert MapElites.size() == 0
    end

    test "returns the number of occupied cells as fragments are inserted" do
      MapElites.insert(build_fragment("a", %{complexity: 0.1, paradigm: :functional}, 0.5))
      assert MapElites.size() == 1

      MapElites.insert(build_fragment("b", %{complexity: 0.9, paradigm: :declarative}, 0.7))
      assert MapElites.size() == 2
    end

    test "does not increase when replacing an existing cell" do
      MapElites.insert(build_fragment("a", %{complexity: 0.5, paradigm: :mixed}, 0.3))
      assert MapElites.size() == 1

      MapElites.insert(build_fragment("b", %{complexity: 0.5, paradigm: :mixed}, 0.9))
      assert MapElites.size() == 1
    end
  end

  # ---------------------------------------------------------------------------
  # clear/0
  # ---------------------------------------------------------------------------

  describe "clear/0" do
    test "returns :ok" do
      assert MapElites.clear() == :ok
    end

    test "removes all elites from the archive" do
      MapElites.insert(build_fragment("a", %{complexity: 0.1, paradigm: :functional}, 0.5))
      MapElites.insert(build_fragment("b", %{complexity: 0.9, paradigm: :declarative}, 0.7))
      assert MapElites.size() == 2

      MapElites.clear()
      # clear is a cast (async); wait for it to be processed before asserting
      Process.sleep(30)

      assert MapElites.size() == 0
      assert MapElites.all_fragments() == []
      assert MapElites.get_elites() == []
    end

    test "allows re-insertion after clear" do
      MapElites.insert(build_fragment("a", %{complexity: 0.5, paradigm: :mixed}, 0.5))
      assert MapElites.size() == 1

      MapElites.clear()
      Process.sleep(30)
      assert MapElites.size() == 0

      frag = build_fragment("b", %{complexity: 0.5, paradigm: :mixed}, 0.9)
      assert MapElites.insert(frag) == :ok
      assert MapElites.size() == 1
      assert MapElites.get_elite({5, 1}) != nil
    end
  end
end
