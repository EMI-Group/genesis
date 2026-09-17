defmodule EvoGit.Agent.LlmRetryPolicyTest do
  @moduledoc """
  `async: false` — pins the PURE `EvoGit.Agent.LlmRetryPolicy` model-exhaustion
  retry schedule (the long, capped, ≥2-day budget that replaced the short
  transient-error schedule for HTTP 402 / "insufficient balance" failures).

  The backoff base/cap are read at call time from the app-env seams
  `:llm_model_exhaustion_backoff_base_ms` / `:llm_model_exhaustion_backoff_cap_ms`,
  so this module mutates that shared app env (restored via `on_exit`) — and
  `agent/tool_dispatch_retry_slot_test.exs` (also `async: false`) mutates the
  same keys, so this module must never run concurrently with it.
  """

  use ExUnit.Case, async: false

  alias EvoGit.Agent.LlmRetryPolicy

  doctest EvoGit.Agent.LlmRetryPolicy

  # The production schedule with the default seams (60 s base doubling to an
  # 8 h cap): 8 doubling entries then 7 entries held flat at the cap.
  @default_schedule [
    60_000,
    120_000,
    240_000,
    480_000,
    960_000,
    1_920_000,
    3_840_000,
    7_680_000,
    28_800_000,
    28_800_000,
    28_800_000,
    28_800_000,
    28_800_000,
    28_800_000,
    28_800_000
  ]

  # The documented total of the default schedule: 216_900_000 ms ≈ 60.25 h.
  @default_total_ms 216_900_000

  # The required MINIMUM total: 2 days.
  @two_days_ms 172_800_000

  describe "model_exhaustion_delays/0" do
    test "returns exactly 15 delays" do
      assert length(LlmRetryPolicy.model_exhaustion_delays()) == 15
    end

    test "returns the exact default schedule (60s base doubling, capped at 8h)" do
      assert LlmRetryPolicy.model_exhaustion_delays() == @default_schedule
    end
  end

  describe "model_exhaustion_total_ms/0" do
    test "covers at least 2 days over the 15 retries" do
      assert LlmRetryPolicy.model_exhaustion_total_ms() >= @two_days_ms
    end

    test "is the sum of the schedule (currently 216_900_000 ms ≈ 60.25 h)" do
      assert LlmRetryPolicy.model_exhaustion_total_ms() == @default_total_ms
      assert LlmRetryPolicy.model_exhaustion_total_ms() == Enum.sum(@default_schedule)
    end
  end

  describe "model_exhaustion_delay/1" do
    test "is 1-based: attempt 1 is the base delay" do
      assert LlmRetryPolicy.model_exhaustion_delay(1) == 60_000
      assert LlmRetryPolicy.model_exhaustion_delay(2) == 120_000
    end

    test "clamps non-positive attempts to the first entry" do
      assert LlmRetryPolicy.model_exhaustion_delay(0) == 60_000
      assert LlmRetryPolicy.model_exhaustion_delay(-5) == 60_000
    end

    test "clamps attempts beyond the schedule to the last (capped) entry" do
      assert LlmRetryPolicy.model_exhaustion_delay(16) == 28_800_000
      assert LlmRetryPolicy.model_exhaustion_delay(99) == 28_800_000
    end

    test "is monotonically non-decreasing across attempts 1..15" do
      delays = for attempt <- 1..15, do: LlmRetryPolicy.model_exhaustion_delay(attempt)

      assert delays == @default_schedule

      assert Enum.chunk_every(delays, 2, 1, :discard)
             |> Enum.all?(fn [a, b] -> a <= b end)
    end
  end

  describe "default_model_exhaustion_backoff_ms/0" do
    test "equals the first schedule entry" do
      assert LlmRetryPolicy.default_model_exhaustion_backoff_ms() ==
               LlmRetryPolicy.model_exhaustion_delay(1)
    end
  end

  describe "timing seams" do
    setup do
      original_base = Application.get_env(:evo_git, :llm_model_exhaustion_backoff_base_ms)
      original_cap = Application.get_env(:evo_git, :llm_model_exhaustion_backoff_cap_ms)

      on_exit(fn ->
        restore_seam(:llm_model_exhaustion_backoff_base_ms, original_base)
        restore_seam(:llm_model_exhaustion_backoff_cap_ms, original_cap)
      end)

      :ok
    end

    test "both seams shrink the schedule (still exactly 15 entries)" do
      Application.put_env(:evo_git, :llm_model_exhaustion_backoff_base_ms, 10)
      Application.put_env(:evo_git, :llm_model_exhaustion_backoff_cap_ms, 80)

      delays = LlmRetryPolicy.model_exhaustion_delays()

      assert length(delays) == 15
      assert hd(delays) == 10
      assert List.last(delays) == 80
      # 10 + 20 + 40 doubling entries, then 12 entries held at the 80 cap.
      assert delays == [10, 20, 40, 80, 80, 80, 80, 80, 80, 80, 80, 80, 80, 80, 80]
      assert LlmRetryPolicy.model_exhaustion_total_ms() == 1_030
    end

    test "shrinking the seams changes the delay lookup and the default backoff" do
      Application.put_env(:evo_git, :llm_model_exhaustion_backoff_base_ms, 10)
      Application.put_env(:evo_git, :llm_model_exhaustion_backoff_cap_ms, 80)

      assert LlmRetryPolicy.model_exhaustion_delay(1) == 10
      assert LlmRetryPolicy.model_exhaustion_delay(15) == 80
      assert LlmRetryPolicy.default_model_exhaustion_backoff_ms() == 10
    end

    test "a non-positive or non-integer seam falls back to the default" do
      for bad <- [0, -1, "10", nil, 1.5] do
        Application.put_env(:evo_git, :llm_model_exhaustion_backoff_base_ms, bad)
        Application.put_env(:evo_git, :llm_model_exhaustion_backoff_cap_ms, bad)

        assert LlmRetryPolicy.model_exhaustion_delays() == @default_schedule
        assert LlmRetryPolicy.default_model_exhaustion_backoff_ms() == 60_000
      end
    end
  end

  defp restore_seam(key, nil), do: Application.delete_env(:evo_git, key)
  defp restore_seam(key, value), do: Application.put_env(:evo_git, key, value)
end
