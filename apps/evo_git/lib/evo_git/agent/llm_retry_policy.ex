defmodule EvoGit.Agent.LlmRetryPolicy do
  @moduledoc """
  Pure retry-delay schedule for LLM **model-exhaustion** errors.

  ## What the schedule is

  Unlike a transient transport/rate-limit hiccup, a *model-exhaustion* error
  (e.g. DeepSeek HTTP 402 "insufficient balance", an exhausted quota, a
  permanently unavailable model) cannot be fixed by an agent retrying quickly —
  it requires a human to act (top up the account, swap the model, wait for the
  provider). The retry schedule is therefore deliberately long and slow:

  * a **base** delay of 60 s that **doubles** each retry,
  * **capped** at 8 h (28,800,000 ms),
  * **15 delays** in total (1-based attempt index 1..15),
  * the 8 doubling entries `60_000, 120_000, 240_000, 480_000, 960_000,
    1_920_000, 3_840_000, 7_680_000` followed by **7 entries held flat at the
    8 h cap**,
  * a **total of 216,900,000 ms** (~60.25 hours ≈ 2.5 days).

  ## Why ≥ 2 days

  A model-exhaustion error usually means the account is out of funds / quota.
  The agent cannot recover on its own; it must wait long enough for a human to
  notice and top the account up. The schedule's total is ≥ 2 days
  (172,800,000 ms) so the whole retry budget genuinely covers a human's
  response window — while each individual sleep stays bounded (max 8 h), never
  a multi-hour agent-side sleep that would block a worktree indefinitely.

  ## Timing seams

  The base and cap are read **at call time** from the application environment
  (never at compile time), so tests can shrink the whole schedule:

    * `:llm_model_exhaustion_backoff_base_ms` (default `60_000`)
    * `:llm_model_exhaustion_backoff_cap_ms` (default `28_800_000`)

  ## This module is pure

  No state, no processes, no I/O — every function is a plain computation over
  its inputs and the current app-env seam values.

  ## Examples

      iex> EvoGit.Agent.LlmRetryPolicy.model_exhaustion_total_ms()
      216_900_000

      iex> EvoGit.Agent.LlmRetryPolicy.model_exhaustion_total_ms() >= 172_800_000
      true

      iex> length(EvoGit.Agent.LlmRetryPolicy.model_exhaustion_delays())
      15

      iex> EvoGit.Agent.LlmRetryPolicy.model_exhaustion_delay(1)
      60_000
  """

  @schedule_length 15
  @default_base_ms 60_000
  @default_cap_ms 28_800_000

  @typedoc "A positive retry delay in milliseconds."
  @type delay_ms :: pos_integer()

  @doc """
  The full list of 15 retry delays (ms), one per retry.

  The schedule is built from the call-time seam values: `base` doubles for
  `trunc(log2(cap / base))` entries and the remaining entries are held flat at
  `cap`. With the default seams it returns exactly:

      [60_000, 120_000, 240_000, 480_000, 960_000, 1_920_000, 3_840_000,
       7_680_000, 28_800_000, 28_800_000, 28_800_000, 28_800_000, 28_800_000,
       28_800_000, 28_800_000]

  Always returns exactly `15` entries.
  """
  @spec model_exhaustion_delays() :: [delay_ms()]
  def model_exhaustion_delays do
    base = base_ms()
    cap = cap_ms()
    steps = doubling_steps(base, cap)

    doubling =
      for n <- 1..steps//1 do
        min(base * Integer.pow(2, n - 1), cap)
      end

    # Pad with `cap` then trim, so the result always has exactly
    # `@schedule_length` entries regardless of the seam values.
    (doubling ++ List.duplicate(cap, @schedule_length))
    |> Enum.take(@schedule_length)
  end

  @doc """
  The delay (ms) that elapses **before** attempt `attempt + 1`.

  `attempt` is 1-based, so `model_exhaustion_delay(1)` is the base delay
  (`60_000` with default seams). Attempt indices greater than the last schedule
  index (`> 15`) clamp to the last (capped) entry — so a "final report" uses the
  capped value. Integer input never raises; non-positive input clamps to the
  first entry.
  """
  @spec model_exhaustion_delay(integer()) :: delay_ms()
  def model_exhaustion_delay(attempt) when is_integer(attempt) do
    delays = model_exhaustion_delays()
    index = attempt |> max(1) |> min(length(delays))
    Enum.at(delays, index - 1)
  end

  @doc """
  The sum (ms) of `model_exhaustion_delays/0`.

  Computed from the schedule — never hardcoded. With the default seams it is
  `216_900_000` ms (~60.25 h), which is ≥ the required 2-day minimum
  (`172_800_000` ms).

      iex> EvoGit.Agent.LlmRetryPolicy.model_exhaustion_total_ms()
      216_900_000
  """
  @spec model_exhaustion_total_ms() :: delay_ms()
  def model_exhaustion_total_ms do
    model_exhaustion_delays() |> Enum.sum()
  end

  @doc """
  The default model-exhaustion backoff (ms) — the first entry of the schedule.

  Equal to `model_exhaustion_delay(1)` (`60_000` with default seams).
  """
  @spec default_model_exhaustion_backoff_ms() :: delay_ms()
  def default_model_exhaustion_backoff_ms do
    model_exhaustion_delay(1)
  end

  # --- Timing seams (read at call time) ---

  defp base_ms do
    case Application.get_env(:evo_git, :llm_model_exhaustion_backoff_base_ms, @default_base_ms) do
      n when is_integer(n) and n > 0 -> n
      _ -> @default_base_ms
    end
  end

  defp cap_ms do
    case Application.get_env(:evo_git, :llm_model_exhaustion_backoff_cap_ms, @default_cap_ms) do
      n when is_integer(n) and n > 0 -> n
      _ -> @default_cap_ms
    end
  end

  # Number of DOUBLING entries: trunc(log2(cap / base)); <= 0 means every entry
  # is the cap.
  defp doubling_steps(base, cap) do
    base
    |> then(&(cap / &1))
    |> :math.log2()
    |> trunc()
    |> max(0)
  end
end
