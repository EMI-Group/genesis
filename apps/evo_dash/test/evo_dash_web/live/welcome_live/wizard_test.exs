defmodule EvoDashWeb.WelcomeLive.WizardTest do
  @moduledoc """
  Pins the PURE draft model behind `/welcome`: the string-keyed draft, the
  provider-driven step run, the per-step gates, the whitelisted `put/3`, the
  multi-model toggles and the schedule-preset apply/undo cycle.

  Every test here is a unit test over the module alone — no LiveView, no
  config, no process and no clock — so the whole file is `async: true`.
  """

  use ExUnit.Case, async: true

  alias EvoDashWeb.LLMSetup.Reasoning
  alias EvoDashWeb.WelcomeLive.Wizard

  @all_steps [:provider, :auth, :model, :reasoning_schedule, :test, :done]
  @without_auth [:provider, :model, :reasoning_schedule, :test, :done]
  @draft_keys ~w(
    provider variant auth_mode base_url api_key models custom_model default_model
    model_reasoning reasoning_efforts default_reasoning_effort schedule
    schedule_snapshot preset_id
  )
  @anthropic_model "anthropic:claude-haiku-5-5"
  @deepseek_preset %{
    "concurrency" => 4,
    "peak_concurrency" => 2,
    "peak_hours" => [
      %{"start" => "01:00", "end" => "04:00", "days" => ["weekdays"]},
      %{"start" => "06:00", "end" => "10:00", "days" => ["weekdays"]}
    ],
    "timezone" => "UTC",
    "off_peak_days" => ["sat", "sun"],
    "off_peak_holidays" => "CN"
  }

  defp draft(provider), do: Wizard.put(Wizard.new(), "provider", provider)

  # ── new/0 ──────────────────────────────────────────────────────────────────
  describe "new/0" do
    test "returns the string-keyed empty draft" do
      draft = Wizard.new()

      assert Map.keys(draft) |> Enum.sort() == Enum.sort(@draft_keys)
      assert Enum.all?(Map.keys(draft), &is_binary/1)

      assert draft["provider"] == nil
      assert draft["variant"] == nil
      assert draft["auth_mode"] == "api_key"
      assert draft["base_url"] == ""
      assert draft["api_key"] == ""
      assert draft["models"] == []
      assert draft["custom_model"] == ""
      assert draft["default_model"] == nil
      assert draft["model_reasoning"] == %{}
      assert draft["reasoning_efforts"] == []
      assert draft["default_reasoning_effort"] == ""
      assert draft["schedule"] == %{}
      assert draft["schedule_snapshot"] == nil
      assert draft["preset_id"] == nil
    end

    test "seeds a provider from a string or an atom, ignoring blank input" do
      assert Wizard.new("deepseek")["provider"] == "deepseek"
      assert Wizard.new(:deepseek)["provider"] == "deepseek"
      assert Wizard.new("  ")["provider"] == nil
      assert Wizard.new(nil)["provider"] == nil
      assert Wizard.new(42)["provider"] == nil
    end
  end

  # ── steps/1 ────────────────────────────────────────────────────────────────
  describe "steps/1" do
    test "an unpicked provider still shows the whole plan" do
      assert Wizard.steps(Wizard.new()) == @all_steps
    end

    test "a provider with a real auth choice keeps the auth step" do
      # Anthropic is the one catalog provider that supports both an API key and
      # a subscription login.
      assert Wizard.steps(draft("anthropic")) == @all_steps
    end

    test "a single-mode or endpoint provider drops the auth step" do
      for provider <- ["deepseek", "zai", "custom", "openai_codex"] do
        assert Wizard.steps(draft(provider)) == @without_auth,
               "#{provider} should not ask an auth question"
      end
    end

    test "a capabilities map is honoured directly and junk keeps every step" do
      assert Wizard.steps(%{auth_choice?: false}) == @without_auth
      assert Wizard.steps(%{"auth_choice?" => false}) == @without_auth
      assert Wizard.steps(%{auth_choice?: true}) == @all_steps
      assert Wizard.steps(nil) == @all_steps
      assert Wizard.steps("nonsense") == @all_steps
    end
  end

  # ── capabilities/1 ─────────────────────────────────────────────────────────
  describe "capabilities/1" do
    test "a custom endpoint needs a base URL and offers no auth choice" do
      assert Wizard.capabilities(draft("custom")) == %{
               auth_choice?: false,
               auth_modes: ["api_key"],
               oauth_only?: false,
               requires_base_url?: true
             }
    end

    test "an unpicked provider shows the open capabilities" do
      assert Wizard.capabilities(Wizard.new()) == %{
               auth_choice?: true,
               auth_modes: ["api_key", "oauth"],
               oauth_only?: false,
               requires_base_url?: false
             }
    end

    test "Anthropic offers both modes" do
      capabilities = Wizard.capabilities(draft("anthropic"))

      assert capabilities.auth_choice? == true
      assert capabilities.auth_modes == ["api_key", "oauth"]
      assert capabilities.oauth_only? == false
      assert capabilities.requires_base_url? == false
    end

    test "ChatGPT Codex is OAuth-only" do
      capabilities = Wizard.capabilities(draft("openai_codex"))

      assert capabilities.oauth_only? == true
      assert capabilities.auth_modes == ["oauth"]
      assert capabilities.auth_choice? == false
    end

    test "Z.ai declares no auth modes, so it defaults to API key only" do
      capabilities = Wizard.capabilities(draft("zai"))

      assert capabilities.auth_modes == ["api_key"]
      assert capabilities.auth_choice? == false
      assert capabilities.oauth_only? == false
    end

    test "a ready-made partial capabilities map is filled to the four keys" do
      # A map carrying capability keys but NOT a draft's `"provider"` key is a
      # READY-MADE entry: it is filled to exactly the four keys, never echoed.
      assert Wizard.capabilities(%{auth_modes: ["oauth"]}) == %{
               auth_choice?: true,
               auth_modes: ["oauth"],
               oauth_only?: true,
               requires_base_url?: false
             }

      assert Wizard.capabilities(%{auth_choice?: false, auth_modes: ["oauth"], oauth_only?: true}) ==
               %{
                 auth_choice?: false,
                 auth_modes: ["oauth"],
                 oauth_only?: true,
                 requires_base_url?: false
               }
    end

    test "a DRAFT carrying capability keys still answers exactly the four keys" do
      # A DRAFT is identified by its string `"provider"` key, so it resolves from
      # that provider even when it also carries capability keys of its own; the
      # answer is the four-key shape, never a mixed draft/capability map.
      shaped =
        draft("anthropic")
        |> Map.put(:auth_modes, ["oauth"])
        |> Map.put(:oauth_only?, true)
        |> Map.put("api_key", "sk-transient")

      capabilities = Wizard.capabilities(shaped)

      assert capabilities == %{
               auth_choice?: true,
               auth_modes: ["api_key", "oauth"],
               oauth_only?: false,
               requires_base_url?: false
             }

      assert Map.keys(capabilities) |> Enum.sort() ==
               [:auth_choice?, :auth_modes, :oauth_only?, :requires_base_url?]

      refute Map.has_key?(capabilities, "provider")
      refute Map.has_key?(capabilities, "api_key")
    end

    test "is total over unusable input" do
      assert Wizard.capabilities(nil) == %{
               auth_choice?: false,
               auth_modes: ["api_key"],
               oauth_only?: false,
               requires_base_url?: true
             }

      assert Wizard.capabilities(42).auth_modes == ["api_key"]
    end
  end

  # ── navigation ─────────────────────────────────────────────────────────────
  describe "progress/2" do
    test "counts the whole run for an unpicked provider" do
      assert Wizard.progress(Wizard.new(), :provider) == {1, 6, 17}
      assert Wizard.progress(Wizard.new(), :done) == {6, 6, 100}
      assert Wizard.progress(Wizard.new(), :auth) == {2, 6, 33}
    end

    test "counts the shortened run for a single-mode provider" do
      # provider → model → reasoning_schedule → test → done
      assert Wizard.progress(draft("deepseek"), :test) == {4, 5, 80}
      assert Wizard.progress(draft("deepseek"), :provider) == {1, 5, 20}
    end

    test "an unknown step reports no position" do
      assert Wizard.progress(Wizard.new(), :nope) == {0, 6, 0}
    end
  end

  describe "next_step/2 and prev_step/2" do
    test "walk the run in order" do
      steps = @all_steps

      for [from, to] <- Enum.zip(steps, tl(steps)) do
        assert Wizard.next_step(Wizard.new(), from) == to
      end
    end

    test "clamp at both ends" do
      assert Wizard.prev_step(Wizard.new(), :provider) == :provider
      assert Wizard.next_step(Wizard.new(), :done) == :done
    end

    test "follow the shortened run" do
      draft = draft("deepseek")

      assert Wizard.next_step(draft, :provider) == :model
      assert Wizard.prev_step(draft, :model) == :provider
    end

    test "stay total over junk" do
      assert Wizard.next_step(Wizard.new(), :nope) == nil
      assert Wizard.prev_step(Wizard.new(), nil) == nil

      # A non-draft degrades to the whole, unpicked plan rather than raising.
      assert Wizard.next_step(nil, :provider) == :auth
      assert Wizard.prev_step(nil, :provider) == :provider
      assert Wizard.progress(nil, :provider) == {1, 6, 17}
    end
  end

  # ── validate/2 gates ───────────────────────────────────────────────────────
  describe "validate/2" do
    test ":provider needs a non-blank provider" do
      assert Wizard.validate(:provider, Wizard.new()) == {:error, :missing_provider}
      assert Wizard.validate(:provider, %{"provider" => "  "}) == {:error, :missing_provider}
      assert Wizard.validate(:provider, draft("deepseek")) == :ok
    end

    test ":provider requires an endpoint URL for the custom provider" do
      custom = draft("custom")

      assert Wizard.validate(:provider, custom) == {:error, :missing_base_url}

      assert Wizard.validate(:provider, Wizard.put(custom, "base_url", "https://x.test/v1")) ==
               :ok

      # The catalog's own `requires_base_url` provider behaves the same.
      assert Wizard.validate(:provider, draft("openai_compatible")) == {:error, :missing_base_url}
    end

    test ":auth needs a supported mode" do
      assert Wizard.validate(:auth, %{"auth_mode" => "api_key"}) == :ok
      assert Wizard.validate(:auth, %{"auth_mode" => "oauth"}) == :ok
      assert Wizard.validate(:auth, %{"auth_mode" => "none"}) == {:error, :invalid_auth_mode}
      assert Wizard.validate(:auth, Wizard.new()) == :ok
    end

    test ":model needs a catalog pick or a custom name" do
      assert Wizard.validate(:model, Wizard.new()) == {:error, :missing_model}

      assert Wizard.validate(:model, Wizard.put(Wizard.new(), "default_model", @anthropic_model)) ==
               :ok

      assert Wizard.validate(:model, Wizard.put(Wizard.new(), "custom_model", "my-model-x")) ==
               :ok

      assert Wizard.validate(:model, Wizard.put(Wizard.new(), "default_model", "my-model-x")) ==
               :ok
    end

    test "the remaining steps never block" do
      for step <- [:reasoning_schedule, :test, :done, :unknown] do
        assert Wizard.validate(step, Wizard.new()) == :ok
      end
    end

    test "walks the run end to end" do
      draft =
        Wizard.new()
        |> Wizard.put("provider", "anthropic")
        |> Wizard.put("auth_mode", "oauth")
        |> Wizard.put("default_model", @anthropic_model)

      for step <- Wizard.steps(draft) do
        assert Wizard.validate(step, draft) == :ok
        assert Wizard.valid?(step, draft, Wizard.capabilities(draft))
      end
    end

    test "is total over every step and unusable draft" do
      # `validate/2,3` never raises: a `nil`/non-map draft is read as the empty
      # draft, so every step answers a validation VALUE (the empty draft has no
      # provider, no auth mode and no model).
      expected = %{
        provider: {:error, :missing_provider},
        auth: {:error, :invalid_auth_mode},
        model: {:error, :missing_model},
        reasoning_schedule: :ok,
        test: :ok,
        done: :ok
      }

      for step <- [:provider, :auth, :model, :reasoning_schedule, :test, :done],
          draft <- [nil, :junk, "string", [], %{}] do
        assert Wizard.validate(step, draft) == Map.fetch!(expected, step)
        assert Wizard.valid?(step, draft) == (Map.fetch!(expected, step) == :ok)
      end

      # An unknown step never blocks, whatever the draft.
      for draft <- [nil, :junk, "string", [], %{}] do
        assert Wizard.validate(:unknown, draft) == :ok
        assert Wizard.valid?(:unknown, draft) == true
      end

      # The capabilities-aware arity behaves the same way.
      assert Wizard.validate(:auth, nil, Wizard.capabilities(nil)) ==
               {:error, :invalid_auth_mode}

      assert Wizard.validate(:done, :junk, Wizard.capabilities(:junk)) == :ok
    end
  end

  # ── put/3 ──────────────────────────────────────────────────────────────────
  describe "put/3" do
    test "accepts a whitelisted string or atom key" do
      draft = Wizard.new()

      assert Wizard.put(draft, "provider", "deepseek")["provider"] == "deepseek"
      assert Wizard.put(draft, :provider, "deepseek") == Wizard.put(draft, "provider", "deepseek")
    end

    test "keeps the transient api_key out of every other key" do
      draft = Wizard.put(Wizard.new(), "api_key", "sk-test")

      assert draft["api_key"] == "sk-test"
      assert draft["base_url"] == ""
      assert draft["schedule"] == %{}
    end

    test "ignores unknown, secret-bearing and wrongly-typed keys" do
      draft = Wizard.new()

      for key <- ["nope", "password", "credential", "token", "secret", nil, 42, {:a, :b}] do
        assert Wizard.put(draft, key, "value") == draft
      end
    end

    test "is total over junk drafts" do
      assert Wizard.put(nil, "provider", "deepseek") == %{"provider" => "deepseek"}
      assert Wizard.put(:junk, "nope", 1) == %{}
    end
  end

  # ── models ─────────────────────────────────────────────────────────────────
  describe "toggle_model/2 and set_custom_model/2" do
    test "toggling the same model twice restores an empty selection" do
      draft =
        Wizard.new()
        |> Wizard.toggle_model(@anthropic_model)

      assert draft["models"] == [@anthropic_model]
      assert draft["default_model"] == @anthropic_model

      draft = Wizard.toggle_model(draft, @anthropic_model)

      assert draft["models"] == []
      assert draft["default_model"] == nil
    end

    test "removing the default promotes the first survivor" do
      first = "anthropic:claude-haiku-5-5"
      second = "anthropic:claude-sonnet-5-5"

      draft =
        Wizard.new()
        |> Wizard.toggle_model(first)
        |> Wizard.toggle_model(second)

      assert draft["models"] == [first, second]
      assert draft["default_model"] == first

      draft = Wizard.toggle_model(draft, first)

      assert draft["models"] == [second]
      assert draft["default_model"] == second
    end

    test "a blank model string changes nothing" do
      draft = Wizard.new()

      assert Wizard.toggle_model(draft, "") == draft
      assert Wizard.toggle_model(draft, nil) == draft
      assert Wizard.toggle_model(draft, "   ") == draft
    end

    test "prunes reasoning for models that are no longer selected" do
      draft =
        Wizard.new()
        |> Wizard.toggle_model(@anthropic_model)
        |> Wizard.put("model_reasoning", %{@anthropic_model => "high"})

      assert Wizard.toggle_model(draft, @anthropic_model)["model_reasoning"] == %{}
    end

    test "a custom model name becomes the default and outlives a catalog pick" do
      draft = Wizard.set_custom_model(Wizard.new(), "  my-model-x  ")

      assert draft["custom_model"] == "my-model-x"
      assert draft["default_model"] == "my-model-x"

      # A catalog pick joins the selection but the custom name stays the default
      # (it is still a selected model, so `keep_default_valid/1` keeps it).
      draft = Wizard.toggle_model(draft, @anthropic_model)

      assert draft["models"] == [@anthropic_model]
      assert draft["default_model"] == "my-model-x"

      # Clearing the custom name falls back to the remaining catalog pick.
      assert Wizard.set_custom_model(draft, "")["default_model"] == @anthropic_model
    end
  end

  # ── presets ────────────────────────────────────────────────────────────────
  describe "schedule presets" do
    test "apply_preset/2 returns the draft and the pre-apply snapshot" do
      draft = Wizard.new()

      assert {applied, snapshot} = Wizard.apply_preset(draft, "deepseek-standard")
      assert snapshot == %{}

      assert applied["preset_id"] == "deepseek-standard"
      assert applied["schedule_snapshot"] == %{}
      assert applied["schedule"] == @deepseek_preset

      # Nothing outside the schedule keys is touched.
      assert applied["provider"] == draft["provider"]
      assert applied["api_key"] == draft["api_key"]
    end

    test "an unknown preset id leaves the draft and the snapshot alone" do
      draft = Wizard.new()

      assert {unchanged, snapshot} = Wizard.apply_preset(draft, "nope")
      assert unchanged == draft
      assert snapshot == %{}
    end

    test "a pre-existing schedule is snapshotted and restored" do
      draft = Wizard.put(Wizard.new(), "schedule", %{"concurrency" => 9, "timezone" => "UTC"})

      {applied, snapshot} = Wizard.apply_preset(draft, "deepseek-standard")

      assert snapshot == %{"concurrency" => 9, "timezone" => "UTC"}
      assert applied["schedule"]["concurrency"] == 4

      restored = Wizard.undo_preset(applied)

      assert restored["schedule"] == %{"concurrency" => 9, "timezone" => "UTC"}
      assert restored["schedule_snapshot"] == nil
      assert restored["preset_id"] == nil
    end

    test "undo_preset/1 empties a schedule the preset introduced" do
      {applied, _snapshot} = Wizard.apply_preset(Wizard.new(), "deepseek-standard")

      restored = Wizard.undo_preset(applied)

      assert restored["schedule"] == %{}
      assert restored["preset_id"] == nil
    end

    test "undo_preset/1 is idempotent when nothing was applied" do
      draft = Wizard.new()

      assert Wizard.undo_preset(draft) == draft
    end

    test "preset_state/1 reports the applied preset" do
      {applied, _snapshot} = Wizard.apply_preset(Wizard.new(), "deepseek-standard")

      assert %{applied?: true, changed?: false, preset: preset} = Wizard.preset_state(applied)
      assert preset.id == "deepseek-standard"
      assert preset.label == "DeepSeek standard (off-peak discount)"
      assert preset.provider == :deepseek
      assert preset.schedule == @deepseek_preset
    end

    test "preset_state/1 reports nothing before an apply and after an undo" do
      assert Wizard.preset_state(Wizard.new()) == %{
               applied?: false,
               preset: nil,
               changed?: false
             }

      {applied, _snapshot} = Wizard.apply_preset(Wizard.new(), "deepseek-standard")

      assert Wizard.preset_state(Wizard.undo_preset(applied)).applied? == false
    end

    test "preset_state/1 reports a manual edit as changed" do
      {applied, _snapshot} = Wizard.apply_preset(Wizard.new(), "deepseek-standard")

      edited =
        Wizard.put(applied, "schedule", Map.put(applied["schedule"], "concurrency", 7))

      assert Wizard.preset_state(edited).changed? == true
    end

    test "apply/undo/preset_state are total over junk" do
      assert {draft, %{}} = Wizard.apply_preset(nil, nil)
      assert is_map(draft)
      assert Wizard.preset_state(nil).applied? == false
      assert is_map(Wizard.undo_preset(nil))
    end
  end

  # ── vocabularies ───────────────────────────────────────────────────────────
  describe "reasoning_choices/0,1 and schedule_keys/0" do
    test "reasoning_choices/0 is the canonical ladder, never \"max\"" do
      assert Wizard.reasoning_choices() == ["none", "minimal", "low", "medium", "high", "xhigh"]
      assert Wizard.reasoning_choices() == Reasoning.efforts()
      refute "max" in Wizard.reasoning_choices()
    end

    test "reasoning_choices/1 displays an unrestricted empty inventory as the ladder" do
      assert Wizard.reasoning_choices([]) == Reasoning.efforts()
      assert Wizard.reasoning_choices(nil) == Reasoning.efforts()
      assert Wizard.reasoning_choices(["low", "medium"]) == ["low", "medium"]
      # A configured inventory keeps its order; an unknown level survives and
      # "max" is read as "xhigh".
      assert Wizard.reasoning_choices(["ultra", "max"]) == ["ultra", "xhigh"]
    end

    test "schedule_keys/0 is the preset vocabulary in display order" do
      assert Wizard.schedule_keys() == [
               "concurrency",
               "peak_concurrency",
               "peak_hours",
               "timezone",
               "off_peak_days",
               "off_peak_holidays"
             ]
    end
  end

  # ── per-model reasoning default (the ONE unwrap) ───────────────────────────
  describe "model_default_effort/1,2" do
    test "reads both recorded entry shapes and nothing when unrecorded" do
      assert Wizard.model_default_effort(%{"efforts" => ["low", "high"], "default" => "high"}) ==
               "high"

      assert Wizard.model_default_effort("medium") == "medium"
      assert Wizard.model_default_effort(nil) == ""
      assert Wizard.model_default_effort(%{}) == ""
    end

    test "a catalog pick answers its entry, never the custom model's flat field" do
      draft =
        Wizard.new()
        |> Wizard.put("default_model", "deepseek:deepseek-v4-flash")
        |> Wizard.put("model_reasoning", %{
          "deepseek:deepseek-v4-flash" => %{"efforts" => ["high"], "default" => "high"}
        })
        |> Wizard.put("custom_model", "my-model-x")
        |> Wizard.put("default_reasoning_effort", "low")

      assert Wizard.model_default_effort(draft, "deepseek:deepseek-v4-flash") == "high"
      assert Wizard.model_default_effort(draft, "not-picked") == ""

      # The FREE-TEXT name has no entry of its own: its level lives in the flat
      # draft field, which is what the save path persists for it.
      assert Wizard.model_default_effort(draft, "my-model-x") == "low"
    end

    test "is total over junk drafts and models" do
      assert Wizard.model_default_effort(nil, "deepseek:deepseek-v4-flash") == ""
      assert Wizard.model_default_effort(%{}, nil) == ""
      assert Wizard.model_default_effort(%{"model_reasoning" => "junk"}, "a:b") == ""
    end
  end

  # ── summaries ──────────────────────────────────────────────────────────────
  describe "summary_rows/1 and holiday_value/1" do
    test "names the provider, its model and its reasoning default" do
      draft =
        Wizard.new()
        |> Wizard.put("provider", "deepseek")
        |> Wizard.put("default_model", "deepseek:deepseek-v4-flash")
        |> Wizard.put("model_reasoning", %{"deepseek:deepseek-v4-flash" => "high"})

      assert Wizard.summary_rows(draft) == [
               {"Provider", "DeepSeek"},
               {"Model", "DeepSeek V4 Flash"},
               {"Reasoning", "High"}
             ]
    end

    test "appends the schedule rows after the identity rows" do
      draft = draft("deepseek") |> Wizard.put("default_model", "deepseek:deepseek-v4-flash")
      {applied, _snapshot} = Wizard.apply_preset(draft, "deepseek-standard")

      labels =
        applied
        |> Wizard.summary_rows()
        |> Enum.map(&elem(&1, 0))

      assert labels == [
               "Provider",
               "Model",
               "Concurrency",
               "Peak concurrency",
               "Peak hours",
               "Timezone",
               "Off-peak days",
               "Off-peak public holidays"
             ]

      # A row is emitted only when the draft carries that value: an empty draft
      # invents no "Custom endpoint" the user never chose.
      assert Wizard.summary_rows(Wizard.new()) == []

      # A provider with no model picked yet keeps the Provider row and nothing
      # else — no blank Model/Reasoning row is fabricated.
      picked = Wizard.summary_rows(draft("deepseek"))
      assert picked == [{"Provider", "DeepSeek"}]
      refute "Model" in Enum.map(picked, &elem(&1, 0))
      refute "Reasoning" in Enum.map(picked, &elem(&1, 0))
    end

    test "holiday_value/1 reads the applied calendar" do
      {applied, _snapshot} = Wizard.apply_preset(Wizard.new(), "deepseek-standard")

      assert Wizard.holiday_value(applied) == "CN"
      assert Wizard.holiday_value(Wizard.new()) == nil
      assert Wizard.holiday_value(nil) == nil
    end
  end
end
