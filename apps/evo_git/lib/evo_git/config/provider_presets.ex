defmodule EvoGit.Config.ProviderPresets do
  @moduledoc """
  Built-in, DATA-ONLY schedule presets for `[[llm.providers]]` accounts.

  A provider account may declare optional peak/off-peak scheduling
  (`concurrency`, `peak_concurrency`, `peak_hours`, `timezone`,
  `off_peak_days`, `off_peak_holidays`). Vendors publish those windows in
  prose, so a fresh account starts with no schedule data at all and the user
  has to hand-write it. This module is the machine-readable copy of the
  policies that are UNAMBIGUOUSLY published by the vendor, so a caller (the
  dashboard's provider-profile editor) can pre-fill the fields with one click.

  ## This module is data only

  Nothing here writes config, touches disk, starts a process, reads the
  clock or raises. `all/0`, `ids/0`, `get/1` and `for_provider/1` are pure
  and total. The CALLER decides whether/when to apply a preset, which
  provider account it belongs to, and whether the user then edits it.

  ## Shape

  The envelope is atom-keyed, the `:schedule` payload is STRING-keyed so it
  merges straight into a canonical provider account (which is string-keyed):

      %{
        id: "deepseek-standard",
        label: "DeepSeek standard (off-peak discount)",
        provider: :deepseek,
        schedule: %{
          "concurrency" => 4,
          "peak_concurrency" => 2,
          "peak_hours" => [
            %{
              "start" => "01:00",
              "end" => "04:00",
              "days" => ["weekdays"]
            },
            ...
          ],
          "timezone" => "UTC",
          ...
        },
        note: "One short human sentence on what the preset assumes."
      }

  Only the keys that actually apply to that provider's policy are present:
  `off_peak_holidays` appears ONLY where the vendor excludes public holidays
  from peak, and a provider with no published peak/off-peak policy gets no
  preset at all.

  Every preset is valid input for `EvoGit.PeakHours.validate_windows/1`
  (`"peak_hours"`) and `EvoGit.PeakHours.validate_days/1` (`"off_peak_days"`
  and each window's `"days"`), with non-negative integer concurrency values
  and an IANA `"timezone"` name.

  ## Off-peak-holiday awareness (data level only)

  A vendor that makes Chinese public holidays fully off-peak publishes one
  country, which the schedule key `"off_peak_holidays"` carries as an ISO
  3166-1 alpha-2 string (e.g. `"CN"`). This module only ships that string as
  DATA — the holiday calendar itself belongs to the schedule evaluator, and a
  caller that cannot handle the key simply drops it.

  ## Mapping a published policy onto Genesis slots

  No vendor publishes "Genesis LLM slots". A preset therefore maps a
  published price/quota ratio onto the slot fields the way a user would: a
  rate that doubles (or halves off-peak) becomes `"peak_concurrency"` = half
  of `"concurrency"`. These are conservative pre-fill defaults meant to be
  edited, never a claim about vendor capacity.

  ## Verified sources (accessed 2026-11-19)

    * DeepSeek — Models & Pricing, <https://api-docs.deepseek.com/quick_start/pricing>:
      "Off-peak rates are half of the peak rates. Peak hours are 01:00 - 04:00
      and 06:00 - 10:00 UTC, Monday through Friday, excluding Chinese public
      holidays. All other hours are off-peak, including weekends and Chinese
      public holidays in full."
    * Z.AI GLM Coding Plan — Overview, <https://docs.z.ai/devpack/overview>:
      "During off-peak hours, model usage is charged at 50% of the standard
      credit rate. Peak hours: Monday to Friday, 14:00-18:00 Singapore
      Standard Time (UTC+8)".
    * Z.AI GLM Coding Plan — Plan Update Announcement,
      <https://docs.z.ai/devpack/notice/usage-revision>: peak is Monday to
      Friday 14:00-18:00 Singapore Standard Time (UTC+8), and quota is
      consumed at 1x off-peak vs 3x peak for GLM-5.3 (0.4x/1.2x for
      GLM-5.3-Flash).

  ## Providers checked, deliberately WITHOUT a preset

    * `:anthropic`, `:openai`, `:openai_codex`, `:google`, `:xai`,
      `:openrouter` — no published time-of-day pricing at all.
    * `:zai` (pay-as-you-go API) — <https://docs.z.ai/guides/overview/pricing>
      lists flat per-token prices; only the Coding Plan subscription has
      peak/off-peak terms.
    * `:moonshotai` (Kimi) — <https://platform.kimi.ai/docs/pricing/chat>
      lists flat per-token prices (earlier off-peak campaigns are gone).
    * `:minimax` — only traffic/rate-limit thinning during peak hours, no
      time-of-day PRICING.
    * `:alibaba` (Model Studio) — publishes a night window (22:00-08:00,
      UTC+8) but applies it as MODEL-SPECIFIC, often expressly "limited-time"
      discounts (some Qwen models, plus the resold DeepSeek models), so it is
      not an unambiguous account-level schedule and is not shipped here.
  """

  @typedoc """
  A schedule preset: an atom-keyed envelope around a STRING-keyed `:schedule`
  payload that merges into a canonical provider account.
  """
  @type t :: %{
          id: String.t(),
          label: String.t(),
          provider: atom(),
          schedule: %{optional(String.t()) => term()},
          note: String.t()
        }

  @weekdays ["weekdays"]

  @presets [
    %{
      id: "deepseek-standard",
      label: "DeepSeek standard (off-peak discount)",
      provider: :deepseek,
      schedule: %{
        "concurrency" => 4,
        "peak_concurrency" => 2,
        "peak_hours" => [
          %{"start" => "01:00", "end" => "04:00", "days" => @weekdays},
          %{"start" => "06:00", "end" => "10:00", "days" => @weekdays}
        ],
        "timezone" => "UTC",
        "off_peak_days" => ["sat", "sun"],
        "off_peak_holidays" => "CN"
      },
      note:
        "DeepSeek anchors peak (01:00-04:00 and 06:00-10:00 UTC, Mon-Fri) to UTC and gives half price off-peak, with weekends and Chinese public holidays fully off-peak."
    },
    %{
      id: "zai-glm-coding-plan",
      label: "Z.AI GLM Coding Plan (peak-hours quota multiplier)",
      provider: :zai_coding_plan,
      schedule: %{
        "concurrency" => 4,
        "peak_concurrency" => 2,
        "peak_hours" => [
          %{"start" => "14:00", "end" => "18:00", "days" => @weekdays}
        ],
        "timezone" => "Asia/Singapore",
        "off_peak_days" => ["sat", "sun"]
      },
      note:
        "Z.AI's Coding Plan charges 50% of the standard credit rate off-peak, with peak limited to Mon-Fri 14:00-18:00 Singapore time (UTC+8) and no holiday exclusions."
    }
  ]

  @doc """
  All presets, in display order.
  """
  @spec all() :: [t()]
  def all, do: @presets

  @doc """
  The stable ids of every preset, in display order.
  """
  @spec ids() :: [String.t()]
  def ids, do: Enum.map(@presets, & &1.id)

  @doc """
  Fetches one preset by its stable `id`; `nil` when unknown or not a binary.
  """
  @spec get(term()) :: t() | nil
  def get(id) when is_binary(id), do: Enum.find(@presets, &(&1.id == id))
  def get(_id), do: nil

  @doc """
  Presets for one provider.

  Accepts the provider ATOM (`:deepseek`) or its STRING name
  (`"deepseek"`, `"zai_coding_plan"`, `"ZAI-Coding-Plan"`); `nil` and
  unknown providers yield `[]`.
  """
  @spec for_provider(term()) :: [t()]
  def for_provider(nil), do: []

  def for_provider(provider) when is_atom(provider) do
    Enum.filter(@presets, &(&1.provider == provider))
  end

  def for_provider(provider) when is_binary(provider) do
    wanted = normalize_provider(provider)
    Enum.filter(@presets, &(wanted != "" and Atom.to_string(&1.provider) == wanted))
  end

  def for_provider(_provider), do: []

  # Lowercase + hyphen-tolerant so "ZAI-Coding-Plan" and "zai_coding_plan"
  # both name the same provider atom.
  defp normalize_provider(provider) do
    provider
    |> String.trim()
    |> String.downcase()
    |> String.replace("-", "_")
  end
end
