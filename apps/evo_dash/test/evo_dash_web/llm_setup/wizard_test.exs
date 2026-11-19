defmodule EvoDashWeb.LLMSetup.WizardTest do
  @moduledoc """
  Pins the pure step model shared by `/welcome` and `/settings`: the ordered
  step list, the conditional auth step, clamped navigation, progress maths and
  every per-step gate.
  """

  use ExUnit.Case, async: true

  alias EvoDashWeb.LLMSetup.Wizard

  defp steps, do: Wizard.all_steps()
  defp steps_without_auth, do: Wizard.steps_for(%{auth_choice?: false})

  describe "all_steps/0 and steps_for/1" do
    test "all_steps/0 is the canonical six-step order" do
      assert Wizard.all_steps() == [
               :provider,
               :auth,
               :model,
               :reasoning_schedule,
               :test,
               :done
             ]
    end

    test "keeps every step when the provider has a real auth choice" do
      assert Wizard.steps_for(%{auth_choice?: true}) == steps()
      assert Wizard.steps_for(%{"auth_choice?" => true}) == steps()
      assert Wizard.steps_for(%{}) == steps()
    end

    test "drops :auth when auth_choice? is false, from atom- or string-keyed input" do
      expected = [:provider, :model, :reasoning_schedule, :test, :done]

      assert Wizard.steps_for(%{auth_choice?: false}) == expected
      assert Wizard.steps_for(%{"auth_choice?" => false}) == expected
    end

    test "non-map input keeps every step" do
      assert Wizard.steps_for(nil) == steps()
      assert Wizard.steps_for("capabilities") == steps()
    end
  end

  describe "first/1, step_at/2 and index/2" do
    test "first/1 is the first step of the run, nil for an empty run" do
      assert Wizard.first(steps()) == :provider
      assert Wizard.first(steps_without_auth()) == :provider
      assert Wizard.first([]) == nil
      assert Wizard.first(nil) == nil
    end

    test "step_at/2 is zero-based and nil out of range" do
      assert Wizard.step_at(steps(), 0) == :provider
      assert Wizard.step_at(steps(), 3) == :reasoning_schedule
      assert Wizard.step_at(steps(), 99) == nil
      assert Wizard.step_at(steps(), -1) == nil
      assert Wizard.step_at(steps(), :zero) == nil
      assert Wizard.step_at(nil, 0) == nil
    end

    test "index/2 answers the zero-based position or nil" do
      assert Wizard.index(steps(), :provider) == 0
      assert Wizard.index(steps(), :model) == 2
      assert Wizard.index(steps(), :done) == 5
      assert Wizard.index(steps_without_auth(), :model) == 1
      assert Wizard.index(steps(), :unknown) == nil
      assert Wizard.index(nil, :provider) == nil
    end
  end

  describe "next/2 and back/2" do
    test "next/2 walks the ordered run" do
      assert Wizard.next(steps(), :provider) == :auth
      assert Wizard.next(steps(), :auth) == :model
      assert Wizard.next(steps(), :reasoning_schedule) == :test
      assert Wizard.next(steps(), :test) == :done
      assert Wizard.next(steps_without_auth(), :provider) == :model
    end

    test "next/2 clamps at the last step" do
      assert Wizard.next(steps(), :done) == :done
      assert Wizard.next(steps_without_auth(), :done) == :done
    end

    test "back/2 walks backwards and clamps at the first step" do
      assert Wizard.back(steps(), :auth) == :provider
      assert Wizard.back(steps(), :done) == :test
      assert Wizard.back(steps(), :provider) == :provider
      assert Wizard.back(steps_without_auth(), :model) == :provider
    end

    test "both are nil for an absent step or a non-list run" do
      assert Wizard.next(steps(), :unknown) == nil
      assert Wizard.back(steps(), :unknown) == nil
      assert Wizard.next(nil, :provider) == nil
      assert Wizard.back(nil, :provider) == nil
      assert Wizard.next(steps(), nil) == nil
    end
  end

  describe "progress/2" do
    test "reports the 1-based position, the total and an integer percent" do
      assert Wizard.progress(steps(), :provider) == {1, 6, 17}
      assert Wizard.progress(steps(), :reasoning_schedule) == {4, 6, 67}
      assert Wizard.progress(steps(), :done) == {6, 6, 100}
      assert Wizard.progress(steps_without_auth(), :provider) == {1, 5, 20}
    end

    test "percent stays within 1..100 for every step of a run" do
      for step <- steps() do
        {current, total, percent} = Wizard.progress(steps(), step)

        assert current >= 1
        assert current <= total
        assert percent >= 1
        assert percent <= 100
      end
    end

    test "an unknown step answers {0, total, 0} and a non-list run {0, 0, 0}" do
      assert Wizard.progress(steps(), :unknown) == {0, 6, 0}
      assert Wizard.progress(nil, :provider) == {0, 0, 0}
      assert Wizard.progress([], :provider) == {0, 0, 0}
    end
  end

  describe "validate/2 — :provider" do
    test "accepts a non-blank provider, from atom- or string-keyed drafts" do
      assert Wizard.validate(:provider, %{"provider" => "deepseek"}) == :ok
      assert Wizard.validate(:provider, %{provider: :deepseek}) == :ok
      assert Wizard.validate(:provider, %{"provider" => "  zai "}) == :ok
    end

    test "blocks a missing or blank provider" do
      assert Wizard.validate(:provider, %{}) == {:error, :missing_provider}
      assert Wizard.validate(:provider, %{"provider" => ""}) == {:error, :missing_provider}
      assert Wizard.validate(:provider, %{"provider" => "   "}) == {:error, :missing_provider}
      assert Wizard.validate(:provider, %{"provider" => nil}) == {:error, :missing_provider}
      assert Wizard.validate(:provider, nil) == {:error, :missing_provider}
      assert Wizard.validate(:provider, "junk") == {:error, :missing_provider}
    end
  end

  describe "validate/2 — :auth" do
    test "accepts the two supported modes" do
      assert Wizard.validate(:auth, %{"auth_mode" => "api_key"}) == :ok
      assert Wizard.validate(:auth, %{"auth_mode" => "oauth"}) == :ok
      assert Wizard.validate(:auth, %{auth_mode: :oauth}) == :ok
    end

    test "normalizes case, whitespace and hyphens" do
      assert Wizard.validate(:auth, %{"auth_mode" => " API-Key "}) == :ok
      assert Wizard.validate(:auth, %{"auth_mode" => "OAuth"}) == :ok
    end

    test "blocks anything else" do
      assert Wizard.validate(:auth, %{}) == {:error, :invalid_auth_mode}
      assert Wizard.validate(:auth, %{"auth_mode" => "apikey"}) == {:error, :invalid_auth_mode}
      assert Wizard.validate(:auth, %{"auth_mode" => nil}) == {:error, :invalid_auth_mode}
      assert Wizard.validate(:auth, nil) == {:error, :invalid_auth_mode}
    end
  end

  describe "validate/2 — :model" do
    test "accepts a catalog pick" do
      assert Wizard.validate(:model, %{"model" => "deepseek-flash"}) == :ok
      assert Wizard.validate(:model, %{model: "gpt-6-sol"}) == :ok
    end

    test "accepts a free-text custom model name" do
      assert Wizard.validate(:model, %{"custom_model" => "my-local-model"}) == :ok
      assert Wizard.validate(:model, %{custom_model: "my-local-model"}) == :ok
    end

    test "blocks a blank pick with no custom fallback" do
      assert Wizard.validate(:model, %{}) == {:error, :missing_model}

      assert Wizard.validate(:model, %{"model" => "", "custom_model" => "   "}) ==
               {:error, :missing_model}

      assert Wizard.validate(:model, nil) == {:error, :missing_model}
      assert Wizard.validate(:model, 42) == {:error, :missing_model}
    end
  end

  describe "validate/2 — non-blocking steps" do
    test "never blocks the reasoning/schedule, test, done or unknown steps" do
      for step <- [:reasoning_schedule, :test, :done, :unknown_step, nil] do
        assert Wizard.validate(step, %{}) == :ok
        assert Wizard.validate(step, nil) == :ok
        assert Wizard.validate(step, "junk") == :ok
      end
    end
  end
end
