defmodule EvoGit.Agent.ClockTest do
  @moduledoc """
  Pins the agent clock seam (`EvoGit.Agent.Clock`).

  The seam exists so a test comparing two exchanges' contexts (or a message
  `metadata[:timestamp]`) can pin the wall clock. These tests pin BOTH halves of
  that contract: an unpinned clock is the real clock, and a pin is process-local,
  restorable and validated.

  `async: true`: the pin lives in the PROCESS DICTIONARY only (there is no
  app-env global), so no concurrent module can observe it.
  """

  use ExUnit.Case, async: true

  alias EvoGit.Agent.Clock

  # 2023-11-14T22:13:20Z, the canonical Unix-second fixture.
  @pinned 1_700_000_000
  @pinned_datetime ~U[2023-11-14 22:13:20Z]
  @pinned_naive ~N[2023-11-14 22:13:20]

  describe "now_seconds/0 without a pin" do
    test "reads the real system clock" do
      before_seconds = System.system_time(:second)
      seconds = Clock.now_seconds()
      after_seconds = System.system_time(:second)

      assert is_integer(seconds)
      assert seconds >= before_seconds
      assert seconds <= after_seconds
    end
  end

  describe "with_now/2 pins" do
    test "an integer Unix second" do
      assert Clock.with_now(@pinned, fn -> Clock.now_seconds() end) == @pinned
    end

    test "a DateTime is converted to Unix seconds" do
      assert Clock.with_now(@pinned_datetime, fn -> Clock.now_seconds() end) == @pinned
    end

    test "a NaiveDateTime is interpreted as UTC" do
      assert Clock.with_now(@pinned_naive, fn -> Clock.now_seconds() end) == @pinned
    end

    test "a 0-arity function pin is called once per stamp" do
      Process.put(:clock_test_calls, 0)

      pin = fn ->
        calls = Process.get(:clock_test_calls)
        Process.put(:clock_test_calls, calls + 1)
        @pinned + calls
      end

      assert Clock.with_now(pin, fn ->
               {Clock.now_seconds(), Clock.now_seconds(), Clock.now_seconds()}
             end) == {@pinned, @pinned + 1, @pinned + 2}

      assert Process.get(:clock_test_calls) == 3
      Process.delete(:clock_test_calls)
    end
  end

  describe "with_opts/2" do
    test "pins from opts[:now]" do
      assert Clock.with_opts([now: @pinned], fn -> Clock.now_seconds() end) == @pinned
    end

    test "an absent or nil :now is the real clock" do
      before_seconds = System.system_time(:second)
      absent = Clock.with_opts([], fn -> Clock.now_seconds() end)
      explicit_nil = Clock.with_opts([now: nil], fn -> Clock.now_seconds() end)
      after_seconds = System.system_time(:second)

      for seconds <- [absent, explicit_nil] do
        assert is_integer(seconds)
        assert seconds >= before_seconds
        assert seconds <= after_seconds
      end
    end
  end

  describe "scoping" do
    test "the pin is restored once fun returns" do
      before_seconds = System.system_time(:second)

      Clock.with_now(@pinned, fn -> assert Clock.now_seconds() == @pinned end)

      seconds = Clock.now_seconds()
      after_seconds = System.system_time(:second)
      assert seconds >= before_seconds and seconds <= after_seconds
    end

    test "the pin is restored even when fun raises" do
      assert_raise RuntimeError, "boom", fn ->
        Clock.with_now(@pinned, fn -> raise "boom" end)
      end

      before_seconds = System.system_time(:second)
      seconds = Clock.now_seconds()
      after_seconds = System.system_time(:second)
      assert seconds >= before_seconds and seconds <= after_seconds
    end

    test "nesting restores the outer pin" do
      Clock.with_now(@pinned, fn ->
        assert Clock.now_seconds() == @pinned

        Clock.with_now(@pinned + 10, fn ->
          assert Clock.now_seconds() == @pinned + 10
        end)

        assert Clock.now_seconds() == @pinned
      end)
    end

    test "with_now(nil, fun) writes nothing, so an outer pin stays in effect" do
      Clock.with_now(@pinned, fn ->
        process_dictionary_before = Process.get()

        assert Clock.with_now(nil, fn -> Process.get() end) == process_dictionary_before
        assert Process.get() == process_dictionary_before
        assert Clock.now_seconds() == @pinned
      end)
    end

    test "the pin is per-process: a spawned Task does not see it" do
      Clock.with_now(@pinned, fn ->
        before_seconds = System.system_time(:second)
        in_task = Task.async(fn -> Clock.now_seconds() end) |> Task.await()
        after_seconds = System.system_time(:second)

        assert in_task >= before_seconds
        assert in_task <= after_seconds
        refute in_task == @pinned

        # ... while the pinning process still reads the pin.
        assert Clock.now_seconds() == @pinned
      end)
    end
  end

  describe "invalid pins" do
    test "a non-clock value raises a descriptive ArgumentError" do
      assert_raise ArgumentError, ~r/EvoGit\.Agent\.Clock expects/, fn ->
        with_invalid_pin(:not_a_clock)
      end

      assert_raise ArgumentError, ~r/got: "1700000000"/, fn ->
        with_invalid_pin("1700000000")
      end
    end

    test "a 0-arity pin returning a non-clock value raises when stamped" do
      assert_raise ArgumentError, ~r/EvoGit\.Agent\.Clock expects/, fn ->
        Clock.with_now(fn -> :not_a_clock end, fn -> Clock.now_seconds() end)
      end
    end

    test "a non-0-arity function raises ArgumentError" do
      assert_raise ArgumentError, ~r/EvoGit\.Agent\.Clock expects/, fn ->
        with_invalid_pin(fn _seconds -> @pinned end)
      end
    end
  end

  # Calls `with_now/2` with a DELIBERATELY invalid pin through `apply/3`: these
  # are runtime validation cases, and a literal call would make the compiler's
  # type checker flag this file against the documented `pin()` shapes.
  defp with_invalid_pin(pin), do: apply(Clock, :with_now, [pin, fn -> :ok end])
end
