defmodule EvoGit.BackgroundJobs.JobIdTest do
  # async: true — `EvoGit.BackgroundJobs.JobId` is a PURE module: no OS process,
  # no scratch directory, no port, no ETS, no app env and no shared registry.
  # Every case passes its own `taken` ids and its own `:candidate_source` /
  # `:attempts` test seams, so two cases (in any module) can never observe each
  # other.
  use ExUnit.Case, async: true

  alias EvoGit.BackgroundJobs.JobId

  describe "shape" do
    test "valid?/1 accepts 1..8 lowercase base36 payload characters" do
      for id <- ["bash-0", "bash-7f3k2", "bash-zzzzzzzz"] do
        assert JobId.valid?(id), "expected #{inspect(id)} to be a valid job id"
      end
    end

    test "valid?/1 rejects an empty, over-long or non-base36 payload and non-binaries" do
      for id <- [
            "bash-",
            "bash-abcdefgh0",
            "bash-ABC",
            "bash-1-2",
            "bashfoo",
            nil,
            123
          ] do
        refute JobId.valid?(id), "expected #{inspect(id)} NOT to be a valid job id"
      end
    end

    test "the declared attributes bound the shape" do
      assert JobId.prefix() == "bash-"
      assert JobId.payload_max() == 8
      assert JobId.space() == 36 ** 8
      # The widest encoding of the space is exactly `payload_max/0` characters —
      # the pattern and the encoder cannot drift apart.
      assert (JobId.space() - 1) |> Integer.to_string(36) |> String.length() ==
               JobId.payload_max()

      assert String.length(JobId.alphabet()) == 36
    end
  end

  describe "mint/2" do
    test "every minted id is valid and unique across many mints" do
      count = 2_000

      ids = MapSet.new(1..count, fn _ -> mint!() end)

      assert MapSet.size(ids) == count
      assert Enum.all?(ids, &JobId.valid?/1)
    end

    test "minted ids are random tokens, not a counter" do
      ints =
        1..50
        |> Enum.map(fn _ -> mint!() |> payload_integer() end)

      sorted = Enum.sort(ints)

      # A counter would be exactly 50 consecutive payload integers starting at the
      # smallest one. The comparison window is bounded to `length/1` on purpose:
      # the payloads are spread over 36^8 values, so materializing `min..max`
      # would allocate the whole space.
      counter_run = Enum.to_list(hd(sorted)..(hd(sorted) + length(sorted) - 1))

      refute sorted == counter_run,
             "expected the payload sequence #{inspect(sorted)} NOT to be a contiguous counter run"
    end

    test "an out-of-range candidate integer folds into the payload space" do
      assert mint!(candidate_source: fn -> JobId.space() end) == "bash-0"
      assert mint!(candidate_source: fn -> JobId.space() - 1 end) == "bash-zzzzzzzz"
      assert JobId.valid?(mint!(candidate_source: fn -> 10 ** 30 end))
    end

    test "the three `taken` shapes (map, MapSet, 1-arity fun) agree: a collision advances by one" do
      source = [candidate_source: fn -> 0 end]

      assert JobId.mint(%{"bash-0" => %{}}, source) == "bash-1"

      assert JobId.mint(MapSet.new(["bash-0", "bash-1", "bash-2"]), source) == "bash-3"

      assert JobId.mint(fn id -> id in ["bash-0", "bash-1"] end, source) == "bash-2"

      # …and the walk wraps around the end of the payload space.
      assert JobId.mint(MapSet.new(["bash-zzzzzzzz"]),
               candidate_source: fn -> JobId.space() - 1 end
             ) ==
               "bash-0"
    end

    test "a taken map only counts its KEYS as ids" do
      assert JobId.mint(%{"bash-0" => :not_an_id}, candidate_source: fn -> 0 end) == "bash-1"
    end

    test "an exhausted bounded walk answers {:error, :id_space_exhausted} instead of looping" do
      assert JobId.mint(fn _ -> true end, candidate_source: fn -> 0 end, attempts: 4) ==
               {:error, :id_space_exhausted}
    end

    test "the LAST slot of a bounded walk is still found (near miss)" do
      taken = MapSet.new(["bash-0", "bash-1", "bash-2"])

      assert JobId.mint(taken, candidate_source: fn -> 0 end, attempts: 4) == "bash-3"

      # One slot wider than the free tail is still exhausted.
      assert JobId.mint(taken, candidate_source: fn -> 0 end, attempts: 3) ==
               {:error, :id_space_exhausted}
    end

    test "a non-map/MapSet/fun `taken` raises ArgumentError" do
      assert_raise ArgumentError, ~r/expected the taken ids/, fn -> JobId.mint(["bash-0"]) end
      assert_raise ArgumentError, ~r/expected the taken ids/, fn -> JobId.mint(nil) end
    end

    test "an invalid :attempts or :candidate_source seam raises ArgumentError" do
      assert_raise ArgumentError, ~r/expected :attempts/, fn -> JobId.mint(%{}, attempts: 0) end
      assert_raise ArgumentError, ~r/expected :attempts/, fn -> JobId.mint(%{}, attempts: -3) end
      assert_raise ArgumentError, ~r/expected :attempts/, fn -> JobId.mint(%{}, attempts: "4") end

      assert_raise ArgumentError, ~r/expected :candidate_source/, fn ->
        JobId.mint(%{}, candidate_source: 1)
      end
    end
  end

  ## Helpers

  defp mint!(opts \\ []), do: JobId.mint(%{}, opts)

  defp payload_integer(id) do
    id
    |> String.replace_prefix(JobId.prefix(), "")
    |> String.to_integer(36)
  end
end
