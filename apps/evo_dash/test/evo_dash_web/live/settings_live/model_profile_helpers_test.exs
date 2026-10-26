defmodule EvoDashWeb.SettingsLive.ModelProfileHelpersTest do
  @moduledoc """
  Pure unit tests for EvoDashWeb.SettingsLive.ModelProfileHelpers.

  These are pure data-transformation functions operating on plain maps — no
  LiveView, Phoenix socket, or DB setup is required.
  """

  use ExUnit.Case, async: true

  alias EvoDashWeb.SettingsLive.ModelProfileHelpers

  # Baseline form params: a complete "provider:model" profile with no overrides.
  @base_params %{
    "provider" => "deepseek",
    "model_id" => "deepseek-v4-pro",
    "base_url" => "",
    "extra" => ""
  }

  defp parse_params(params),
    do: ModelProfileHelpers.parse_model_profile_params(params, "profile-1")

  defp with_base(patch), do: Map.merge(@base_params, patch)

  defp profile_for(patch) do
    {:ok, profile} = parse_params(with_base(patch))
    profile
  end

  defp error_for(patch) do
    {:error, reason} = parse_params(with_base(patch))
    reason
  end

  defp peak_hours(input), do: profile_for(%{"peak_hours" => input}).peak_hours

  defp models(result), do: get_in(result, [:llm, :models])

  describe "add_model_profile/2 completeness filter" do
    test "a non-nil model drops every incomplete draft and adds the complete profile" do
      # Draft shapes coming from the "Add Profile" button: a missing :model key,
      # and an empty-string :model.
      drafts = [
        %{id: "profile-1", concurrency: 3},
        %{id: "profile-2", concurrency: 3, model: ""}
      ]

      # Model values may be a compact string or a ReqLLM map spec — both are non-nil.
      for model <- ["anthropic:claude-sonnet-4", %{provider: :anthropic, id: "claude-sonnet-4"}] do
        models = models(ModelProfileHelpers.add_model_profile(%{llm: %{models: drafts}}, model))

        refute Enum.any?(models, &(Map.get(&1, :model) in [nil, ""])),
               "expected incomplete drafts dropped for #{inspect(model)}"

        assert [%{model: ^model}] = models
      end
    end

    test "complete profiles survive the filter unchanged" do
      complete = %{id: "profile-1", concurrency: 3, model: "openai:gpt-4o"}

      result =
        ModelProfileHelpers.add_model_profile(
          %{llm: %{models: [complete]}},
          "anthropic:claude-sonnet-4"
        )

      assert [kept, added] = models(result)
      assert kept == complete, "existing complete profile should not be dropped"
      assert added.model == "anthropic:claude-sonnet-4"
    end

    test "a nil/empty model keeps drafts and appends a new draft" do
      for {existing, model} <- [
            {%{id: "profile-1", concurrency: 3}, nil},
            {%{id: "profile-1", concurrency: 3, model: ""}, ""}
          ] do
        models =
          models(ModelProfileHelpers.add_model_profile(%{llm: %{models: [existing]}}, model))

        assert existing in models, "existing draft should be preserved when creating a new draft"

        assert length(Enum.filter(models, &(Map.get(&1, :model) in [nil, ""]))) == 2,
               "expected the existing draft plus the new draft for #{inspect(model)}"
      end
    end
  end

  describe "parse_model_profile_params/2 serialization format" do
    test "stores the compact provider:model string form when no overrides exist" do
      # The edit form pre-fills by splitting :model on the FIRST colon only, so a
      # model id containing colons must survive the round-trip verbatim.
      for model <- ["deepseek:deepseek-v4-pro", "gpt-4o", "openai:gpt-4o:extended"] do
        params =
          case String.split(model, ":", parts: 2) do
            [provider, model_id] -> %{"provider" => provider, "model_id" => model_id}
            [model_id] -> %{"provider" => "", "model_id" => model_id}
          end

        assert {:ok, profile} =
                 parse_params(Map.merge(params, %{"base_url" => "", "extra" => ""}))

        assert profile.model == model, "expected #{inspect(params)} to round-trip to #{model}"
      end
    end

    test "keeps the ReqLLM map spec when a base_url or extra override is present" do
      assert {:ok, %{model: %{provider: :deepseek, id: "deepseek-v4-pro", base_url: base_url}}} =
               parse_params(with_base(%{"base_url" => "https://custom.example.com/v1"}))

      assert base_url == "https://custom.example.com/v1"

      assert {:ok, %{model: %{provider: :deepseek, id: "deepseek-v4-pro", extra: extra}}} =
               parse_params(with_base(%{"extra" => ~s({"reasoning_effort": "high"})}))

      assert extra == %{"reasoning_effort" => "high"}
    end

    test "returns model_id_empty when model_id is blank" do
      assert {:error, "model_id_empty"} = parse_params(with_base(%{"model_id" => ""}))
    end
  end

  describe "parse_model_profile_params/2 — context_window field" do
    test "an absent, blank, or non-numeric value omits the key; an integer string round-trips" do
      for {raw, expected} <- [{:absent, :omit}, {"", :omit}, {"128k", :omit}, {"128000", 128_000}] do
        params = if raw == :absent, do: @base_params, else: with_base(%{"context_window" => raw})

        assert {:ok, profile} = parse_params(params)

        case expected do
          :omit ->
            refute Map.has_key?(profile, :context_window),
                   "context_window key must stay absent for #{inspect(raw)}"

          int ->
            assert profile.context_window == int
        end
      end
    end
  end

  describe "parse_model_profile_params/2 — peak/off-peak concurrency fields" do
    test "absent or fully-blank peak fields omit every key (no nil/[] leakage)" do
      for patch <- [
            %{},
            %{"peak_concurrency" => ""},
            %{
              "peak_hours" => %{
                "0" => %{"start" => "", "end" => ""},
                "1" => %{"start" => "", "end" => ""}
              }
            },
            %{"peak_concurrency" => "", "timezone" => "  ", "off_peak_days" => []}
          ] do
        profile = profile_for(patch)

        for key <- [:peak_concurrency, :peak_hours, :timezone, :off_peak_days] do
          refute Map.has_key?(profile, key), "#{key} must stay absent for #{inspect(patch)}"
        end
      end
    end

    test "peak_concurrency round-trips as a non-negative integer (0 = hard pause)" do
      for {raw, expected} <- [{"8", 8}, {"0", 0}] do
        profile = profile_for(%{"peak_concurrency" => raw})

        assert profile.peak_concurrency == expected
        refute Map.has_key?(profile, :peak_hours)
      end

      # parse_peak_fields/1 exposes the same acceptance directly.
      assert {:ok, %{peak_concurrency: 0}} =
               ModelProfileHelpers.parse_peak_fields(%{"peak_concurrency" => "0"})
    end

    test "peak_hours round-trips form order, list form, and numeric index sorting" do
      two_windows =
        profile_for(%{
          "peak_hours" => %{
            "0" => %{"start" => "09:00", "end" => "12:00"},
            "1" => %{"start" => "14:00", "end" => "18:00"}
          }
        })

      assert two_windows.peak_hours == [
               %{start: "09:00", end: "12:00"},
               %{start: "14:00", end: "18:00"}
             ]

      refute Map.has_key?(two_windows, :peak_concurrency)

      assert peak_hours([%{"start" => "09:00", "end" => "12:00"}]) == [
               %{start: "09:00", end: "12:00"}
             ]

      assert peak_hours(%{
               "10" => %{"start" => "20:00", "end" => "21:00"},
               "9" => %{"start" => "09:00", "end" => "10:00"}
             }) == [
               %{start: "09:00", end: "10:00"},
               %{start: "20:00", end: "21:00"}
             ]
    end

    test "peak_concurrency, peak_hours, timezone, and off_peak_days merge into one profile" do
      profile =
        profile_for(%{
          "peak_concurrency" => "12",
          "peak_hours" => %{"0" => %{"start" => "08:00", "end" => "10:00"}},
          "timezone" => "Asia/Shanghai"
        })

      assert profile.peak_concurrency == 12
      assert profile.peak_hours == [%{start: "08:00", end: "10:00"}]
      assert profile.timezone == "Asia/Shanghai"

      profile =
        profile_for(%{
          "off_peak_days" => ["sat", "sun"],
          "peak_concurrency" => "2",
          "peak_hours" => %{
            "0" => %{"start" => "09:00", "end" => "12:00", "days" => ["mon"]}
          }
        })

      assert profile.peak_concurrency == 2
      assert profile.peak_hours == [%{start: "09:00", end: "12:00", days: ["mon"]}]
      assert profile.off_peak_days == ["sat", "sun"]
    end

    test "a non-blank timezone is stored trimmed; blank/nil omit the key" do
      assert profile_for(%{"timezone" => "  Asia/Shanghai  "}).timezone == "Asia/Shanghai"

      for blank <- ["", "   ", nil] do
        refute Map.has_key?(profile_for(%{"timezone" => blank}), :timezone),
               "expected blank timezone #{inspect(blank)} to omit the key"
      end
    end

    test "invalid peak_concurrency values are rejected" do
      for bad <- ["-1", "abc"] do
        assert error_for(%{"peak_concurrency" => bad}) == "peak_concurrency_invalid",
               "expected #{inspect(bad)} to be rejected"

        # parse_peak_fields/1 exposes the same validation directly.
        assert {:error, "peak_concurrency_invalid"} =
                 ModelProfileHelpers.parse_peak_fields(%{"peak_concurrency" => bad})
      end
    end

    test "valid_clock_time?/1 accepts strict HH:MM and rejects malformed times" do
      for good <- ["00:00", "09:00", "12:30", "23:59"] do
        assert ModelProfileHelpers.valid_clock_time?(good),
               "expected #{inspect(good)} to be valid"
      end

      for bad <- ["9:00", "24:00", "12:60", "12:0", "abc", "12:00am", ""] do
        refute ModelProfileHelpers.valid_clock_time?(bad),
               "expected #{inspect(bad)} to be invalid"
      end

      refute ModelProfileHelpers.valid_clock_time?(nil)
      refute ModelProfileHelpers.valid_clock_time?(930)
    end

    test "malformed or half-filled window times are rejected" do
      for bad <- ["9:00", "24:00", "12:60", "12:0", "abc"] do
        assert error_for(%{"peak_hours" => %{"0" => %{"start" => bad, "end" => "12:00"}}}) ==
                 "peak_hours_invalid_time",
               "expected start #{inspect(bad)} to be rejected"
      end

      for {start, stop} <- [{"09:00", ""}, {"", "12:00"}] do
        assert error_for(%{"peak_hours" => %{"0" => %{"start" => start, "end" => stop}}}) ==
                 "peak_hours_invalid_time",
               "expected a half-filled window (#{inspect(start)}..#{inspect(stop)}) to be rejected"
      end
    end

    test "start == end and overlapping windows are rejected; touching windows are accepted" do
      assert error_for(%{"peak_hours" => %{"0" => %{"start" => "09:00", "end" => "09:00"}}}) ==
               "peak_hours_start_equals_end"

      assert error_for(%{
               "peak_hours" => %{
                 "0" => %{"start" => "09:00", "end" => "12:00"},
                 "1" => %{"start" => "11:00", "end" => "13:00"}
               }
             }) == "peak_hours_overlap"

      assert peak_hours(%{
               "0" => %{"start" => "09:00", "end" => "12:00"},
               "1" => %{"start" => "12:00", "end" => "15:00"}
             }) == [
               %{start: "09:00", end: "12:00"},
               %{start: "12:00", end: "15:00"}
             ]
    end

    test "spec and provider_options errors win over a peak error" do
      # model_id_empty is checked before any peak validation.
      assert error_for(%{"model_id" => "", "peak_concurrency" => "abc"}) == "model_id_empty"

      # Invalid extra JSON beats the peak error.
      assert error_for(%{"extra" => "not json", "peak_concurrency" => "abc"}) ==
               "invalid_extra_json"

      # Invalid provider_options JSON beats the peak error.
      assert error_for(%{
               "provider_options" => "not json",
               "peak_hours" => %{"0" => %{"start" => "09:00", "end" => "09:00"}}
             }) == "invalid_provider_options_json"
    end

    test "off_peak_days accepts the multi-checkbox list (with the \"\" seed), a single value, and a bare string" do
      assert profile_for(%{"off_peak_days" => ["mon", "", "fri", "weekends"]}).off_peak_days ==
               ["mon", "fri", "weekends"]

      assert profile_for(%{"off_peak_days" => ["sat"]}).off_peak_days == ["sat"]

      # Plug collapses a repeated form param to a plain string when exactly one
      # checkbox is submitted (`off_peak_days=weekends`) — it must be wrapped,
      # never silently dropped.
      assert profile_for(%{"off_peak_days" => "weekends"}).off_peak_days == ["weekends"]

      # parse_peak_fields/1 exposes the same normalization directly.
      assert {:ok, %{off_peak_days: ["mon", "fri", "weekends"]}} =
               ModelProfileHelpers.parse_peak_fields(%{
                 "off_peak_days" => ["mon", "", "fri", "weekends"]
               })

      assert {:ok, %{off_peak_days: ["mon"]}} =
               ModelProfileHelpers.parse_peak_fields(%{"off_peak_days" => "mon"})
    end

    test "normalize_days/1 is total across every input shape" do
      # Bare binary (single-checked-chip collapse) → one-element list.
      assert ModelProfileHelpers.normalize_days("weekends") == ["weekends"]
      assert ModelProfileHelpers.normalize_days(" mon ") == ["mon"]

      # List form: seed "" entries filtered, trim+downcase, vocabulary whitelist,
      # order-preserving uniq.
      assert ModelProfileHelpers.normalize_days(["", " mon ", "TUE", "garbage", "mon"]) == [
               "mon",
               "tue"
             ]

      # All-unchecked group (`[""]`) and absent/empty shapes → [].
      assert ModelProfileHelpers.normalize_days([""]) == []
      assert ModelProfileHelpers.normalize_days([]) == []
      assert ModelProfileHelpers.normalize_days(nil) == []

      # Odd non-list/non-binary shapes never raise.
      assert ModelProfileHelpers.normalize_days(930) == []
      assert ModelProfileHelpers.normalize_days(%{"days" => ["mon"]}) == []
      assert ModelProfileHelpers.normalize_days({:mon, :tue}) == []
    end

    test "off_peak_days entries are trimmed, downcased, whitelisted, and de-duplicated" do
      assert profile_for(%{"off_peak_days" => [" Mon ", "TUE", "  wed  "]}).off_peak_days ==
               ["mon", "tue", "wed"]

      # Invalid vocabulary entries are silently dropped — no dashboard-side error.
      assert profile_for(%{"off_peak_days" => ["tues", "monday", "garbage", "fri"]}).off_peak_days ==
               ["fri"]

      assert profile_for(%{"off_peak_days" => ["mon", "mon", "wed", "mon"]}).off_peak_days ==
               ["mon", "wed"]
    end

    test "empty/absent off_peak_days omits the key (no nil/[] leakage)" do
      for days <- [nil, [], [""], ["   "]] do
        params = if days == nil, do: @base_params, else: with_base(%{"off_peak_days" => days})

        assert {:ok, profile} = parse_params(params),
               "expected off_peak_days #{inspect(days)} to be accepted"

        refute Map.has_key?(profile, :off_peak_days),
               "off_peak_days key must stay absent for #{inspect(days)}"
      end
    end

    test "per-window days round-trip (map rows, atom-keyed rows, bare-string collapse)" do
      assert peak_hours(%{
               "0" => %{"start" => "09:00", "end" => "12:00", "days" => ["mon", "fri"]}
             }) == [%{start: "09:00", end: "12:00", days: ["mon", "fri"]}]

      # List-form peak_hours with atom-keyed rows (round-trip from a draft).
      assert peak_hours([%{start: "09:00", end: "12:00", days: ["mon", "fri"]}]) == [
               %{start: "09:00", end: "12:00", days: ["mon", "fri"]}
             ]

      assert peak_hours(%{
               "0" => %{"start" => "09:00", "end" => "12:00", "days" => "fri"}
             }) == [%{start: "09:00", end: "12:00", days: ["fri"]}]
    end

    test "a window without (valid) days stays EXACTLY %{start:, end:} (backward compatible)" do
      for days <- [:absent, [], [""], ["garbage"]] do
        row =
          case days do
            :absent -> %{"start" => "09:00", "end" => "12:00"}
            days -> %{"start" => "09:00", "end" => "12:00", "days" => days}
          end

        assert peak_hours(%{"0" => row}) == [%{start: "09:00", end: "12:00"}],
               "a window with days #{inspect(days)} must not carry a :days key"
      end
    end

    test "blank rows are dropped in the parse path (mixed blank/valid and days-only)" do
      # A blank row alongside a valid one is dropped; the valid one survives.
      assert peak_hours(%{
               "0" => %{"start" => "09:00", "end" => "12:00"},
               "1" => %{"start" => "", "end" => ""}
             }) == [%{start: "09:00", end: "12:00"}]

      assert peak_hours(%{
               "0" => %{"start" => "09:00", "end" => "12:00"},
               "1" => %{"days" => ["mon", "fri"]}
             }) == [%{start: "09:00", end: "12:00"}],
             "a days-only row with blank start/end must be dropped as blank"

      # A wholly days-only input → peak_hours key absent.
      refute Map.has_key?(
               profile_for(%{"peak_hours" => %{"0" => %{"days" => ["mon"]}}}),
               :peak_hours
             )
    end

    test "normalize_peak_hours_draft/1 normalizes nested-map, list, and absent input" do
      # Nested map (Phoenix phx-change shape) — sorted numerically.
      assert ModelProfileHelpers.normalize_peak_hours_draft(%{
               "10" => %{"start" => "20:00", "end" => "21:00"},
               "9" => %{"start" => "09:00", "end" => "10:00"}
             }) == [
               %{start: "09:00", end: "10:00"},
               %{start: "20:00", end: "21:00"}
             ]

      # Atom-keyed rows survive (round-trip from a prior draft).
      assert ModelProfileHelpers.normalize_peak_hours_draft([%{start: "09:00", end: "12:00"}]) ==
               [
                 %{start: "09:00", end: "12:00"}
               ]

      # Blank/partially-filled rows keep "" (no data loss).
      assert ModelProfileHelpers.normalize_peak_hours_draft(%{
               "0" => %{"start" => "", "end" => ""}
             }) == [%{start: "", end: ""}]

      # Total — odd/absent input never raises.
      assert ModelProfileHelpers.normalize_peak_hours_draft(nil) == []
      assert ModelProfileHelpers.normalize_peak_hours_draft("garbage") == []
      assert ModelProfileHelpers.normalize_peak_hours_draft(%{}) == []
    end

    test "normalize_peak_hours_draft/1 keeps :days on a row only when non-empty" do
      # Non-empty days are preserved on the draft row (map and atom-keyed forms).
      assert ModelProfileHelpers.normalize_peak_hours_draft(%{
               "0" => %{"start" => "09:00", "end" => "12:00", "days" => ["mon"]}
             }) == [%{start: "09:00", end: "12:00", days: ["mon"]}]

      assert ModelProfileHelpers.normalize_peak_hours_draft([
               %{start: "09:00", end: "12:00", days: ["fri"]}
             ]) == [%{start: "09:00", end: "12:00", days: ["fri"]}]

      # Empty/absent days stay WITHOUT a :days key (backward compatible).
      assert ModelProfileHelpers.normalize_peak_hours_draft(%{
               "0" => %{"start" => "09:00", "end" => "12:00"}
             }) == [%{start: "09:00", end: "12:00"}]

      assert ModelProfileHelpers.normalize_peak_hours_draft(%{
               "0" => %{"start" => "09:00", "end" => "12:00", "days" => []}
             }) == [%{start: "09:00", end: "12:00"}]

      # A days-only draft row still gets start/end as "" (draft rows always get
      # both keys) — with days kept when non-empty.
      assert ModelProfileHelpers.normalize_peak_hours_draft(%{"0" => %{"days" => ["mon"]}}) == [
               %{start: "", end: "", days: ["mon"]}
             ]
    end

    test "day values never produce dashboard-side errors" do
      # Invalid vocabulary entries are silently dropped — no error, no key.
      assert {:ok, %{peak_concurrency: 4}} =
               ModelProfileHelpers.parse_peak_fields(%{
                 "off_peak_days" => ["garbage"],
                 "peak_concurrency" => "4"
               })

      # A valid-days + valid-window combo round-trips cleanly.
      assert {:ok,
              %{
                off_peak_days: ["fri"],
                peak_hours: [%{start: "09:00", end: "12:00", days: ["mon"]}]
              }} =
               ModelProfileHelpers.parse_peak_fields(%{
                 "off_peak_days" => ["fri"],
                 "peak_hours" => %{
                   "0" => %{"start" => "09:00", "end" => "12:00", "days" => ["mon"]}
                 }
               })
    end
  end

  describe "profile id naming from model value" do
    test "derives the base id from a provider:model string, a plain model, a map spec, or a slugified value" do
      cases = [
        {"deepseek:deepseek-flash", "deepseek-flash"},
        {"gpt-4o", "gpt-4o"},
        {%{provider: :anthropic, id: "claude-sonnet-4"}, "claude-sonnet-4"},
        # downcase, non-alphanumeric runs become dashes
        {"DeepSeek V3.2", "deepseek-v3-2"}
      ]

      for {model, expected} <- cases do
        assert [%{id: ^expected}] =
                 models(ModelProfileHelpers.add_model_profile(%{llm: %{models: []}}, model)),
               "expected #{inspect(model)} to yield id #{expected}"
      end
    end
  end

  describe "profile id conflict suffixes" do
    test "appends -2 when the base id exists and skips to the next free suffix" do
      # Seeded profiles MUST carry a :model key — draft-cleaning would drop them.
      one = %{id: "deepseek-flash", concurrency: 3, model: "deepseek:deepseek-flash"}

      result =
        ModelProfileHelpers.add_model_profile(%{llm: %{models: [one]}}, "deepseek:deepseek-flash")

      assert Enum.map(models(result), & &1.id) == ["deepseek-flash", "deepseek-flash-2"]

      two = [
        one,
        %{id: "deepseek-flash-2", concurrency: 3, model: "deepseek:deepseek-flash-2"}
      ]

      result =
        ModelProfileHelpers.add_model_profile(%{llm: %{models: two}}, "deepseek:deepseek-flash")

      assert List.last(models(result)).id == "deepseek-flash-3"
    end
  end

  describe "profile id fallbacks" do
    test "the draft flow (nil model) and an unusable model value use the profile-N scheme" do
      for model <- [nil, "!!!"] do
        assert [%{id: "profile-1"}] =
                 models(ModelProfileHelpers.add_model_profile(%{llm: %{models: []}}, model)),
               "expected #{inspect(model)} to fall back to profile-1"
      end
    end
  end

  describe "generate_profile_id/2" do
    test "produces base, base-2, ... skipping existing ids; nil base and the one-arity wrapper use profile-N" do
      models = [
        %{id: "foo", concurrency: 3, model: "x:foo"},
        %{id: "foo-2", concurrency: 3, model: "x:foo-2"}
      ]

      assert ModelProfileHelpers.generate_profile_id(models, "foo") == "foo-3"

      drafts = [%{id: "profile-1", concurrency: 3}]
      assert ModelProfileHelpers.generate_profile_id(drafts, nil) == "profile-2"
      assert ModelProfileHelpers.generate_profile_id(drafts) == "profile-2"
    end
  end
end
