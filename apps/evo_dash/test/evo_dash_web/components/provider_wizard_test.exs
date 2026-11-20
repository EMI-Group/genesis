defmodule EvoDashWeb.ProviderWizardTest do
  @moduledoc """
  Render contracts for the shared LLM-setup step components.

  These are pure function components, so every test renders one component with
  assigns only — no LiveView, no config, no catalog and no network. The
  assertions are structural (ids, attributes, counts, option order) rather than
  full-markup comparisons, and no CSS is asserted here: the `wizard-progress`
  and `wizard-step-enter` class names are emitted for the page stylesheet to
  own.
  """

  use ExUnit.Case, async: true

  import Phoenix.LiveViewTest

  alias EvoDashWeb.SettingsComponents.ProviderWizard
  alias EvoDashWeb.SettingsComponents.ProviderWizard.ChatGPTAuth

  @steps [:provider, :auth, :model, :reasoning_schedule, :test, :done]

  # One TEXT marker unique to each step's own content.
  @step_markers %{
    provider: "Custom / OpenAI-compatible endpoint",
    auth: "Subscription",
    model: "Use a custom model name",
    reasoning_schedule: "Reasoning efforts this model accepts",
    test: "Skip for now",
    done: "Your provider account is ready"
  }

  defp html(fun, assigns), do: render_component(fun, assigns)

  defp render_tree(fun, assigns \\ []), do: fun |> html(assigns) |> Floki.parse_fragment!()

  defp nodes(tree, selector), do: Floki.find(tree, selector)

  defp one(tree, selector) do
    assert [node] = Floki.find(tree, selector)
    node
  end

  defp text(node), do: node |> Floki.text() |> String.trim()

  defp attr(node, name) do
    assert [value] = Floki.attribute(node, name)
    value
  end

  defp attrs(nodes, name), do: Enum.map(nodes, &attr(&1, name))

  defp option_values(tree, select_selector) do
    tree |> nodes(select_selector <> " option") |> attrs("value")
  end

  defp option_labels(tree, select_selector) do
    tree |> nodes(select_selector <> " option") |> Enum.map(&text/1)
  end

  defp selected_option_values(tree, select_selector) do
    tree |> nodes(select_selector <> " option[selected]") |> attrs("value")
  end

  defp step_fun(:provider), do: &ProviderWizard.step_provider/1
  defp step_fun(:auth), do: &ProviderWizard.step_auth/1
  defp step_fun(:model), do: &ProviderWizard.step_model/1
  defp step_fun(:reasoning_schedule), do: &ProviderWizard.step_reasoning_schedule/1
  defp step_fun(:test), do: &ProviderWizard.step_test/1
  defp step_fun(:done), do: &ProviderWizard.step_done/1

  defp rows(tree, selector) do
    tree
    |> nodes(selector)
    |> Enum.map(fn row -> {text(one(row, "dt")), text(one(row, "dd"))} end)
  end

  describe "wizard_shell/1 — heading and progress rail" do
    test "renders the heading, subtitle and step count" do
      tree =
        render_tree(&ProviderWizard.wizard_shell/1,
          step: :model,
          steps: @steps,
          title: "Set up an LLM provider",
          subtitle: "One account per provider"
        )

      assert text(one(tree, "h2")) == "Set up an LLM provider"
      assert text(tree) =~ "One account per provider"
      assert text(tree) =~ "Step 3 of 6"
    end

    test "renders the rail with one label per step in wizard order" do
      tree =
        render_tree(&ProviderWizard.wizard_shell/1, step: :model, steps: @steps, title: "Setup")

      rail = one(tree, "ol.wizard-progress")
      assert attr(rail, "aria-label") == "Setup progress"

      assert rail |> nodes("li") |> Enum.map(&text/1) == [
               "Provider",
               "Authentication",
               "Model",
               "Reasoning & schedule",
               "Test",
               "Done"
             ]
    end

    test "marks exactly the current rail row with aria-current=\"step\"" do
      tree =
        render_tree(&ProviderWizard.wizard_shell/1, step: :model, steps: @steps, title: "Setup")

      current = one(tree, "ol.wizard-progress [aria-current=\"step\"]")
      assert text(current) == "Model"
      assert length(nodes(tree, "ol.wizard-progress [aria-current]")) == 1
    end

    test "marks no rail row current for an unknown step" do
      tree =
        render_tree(&ProviderWizard.wizard_shell/1, step: :bogus, steps: @steps, title: "Setup")

      assert nodes(tree, "ol.wizard-progress [aria-current=\"step\"]") == []
    end

    test "wraps the body in the step-keyed enter container" do
      tree =
        render_tree(&ProviderWizard.wizard_shell/1, step: :model, steps: @steps, title: "Setup")

      body = one(tree, "#wizard-step-model")
      assert attr(body, "class") =~ "wizard-step-enter"
      assert nodes(tree, "#wizard-step-provider") == []
    end

    test "honours a caller-supplied progress tuple" do
      tree =
        render_tree(&ProviderWizard.wizard_shell/1,
          step: :model,
          steps: @steps,
          title: "Setup",
          progress: {2, 3, 67}
        )

      assert text(tree) =~ "Step 2 of 3"
      assert text(tree) =~ "Model"
    end

    test "honours caller step labels" do
      tree =
        render_tree(&ProviderWizard.wizard_shell/1,
          step: :provider,
          steps: @steps,
          title: "Setup",
          step_labels: %{provider: "Vendor"}
        )

      assert text(one(tree, "ol.wizard-progress")) =~ "Vendor"
    end
  end

  describe "wizard_shell/1 — footer and error strip" do
    test "Back is disabled on the first step and enabled elsewhere" do
      first =
        render_tree(&ProviderWizard.wizard_shell/1, step: :provider, steps: @steps, title: "S")

      back_first = one(first, "button[phx-click=\"wizard_back\"]")
      assert Floki.attribute(back_first, "disabled") == ["disabled"]
      assert text(back_first) == "Back"

      later = render_tree(&ProviderWizard.wizard_shell/1, step: :auth, steps: @steps, title: "S")
      assert Floki.attribute(one(later, "button[phx-click=\"wizard_back\"]"), "disabled") == []
    end

    test "Next carries the default label and follows next_disabled" do
      tree = render_tree(&ProviderWizard.wizard_shell/1, step: :auth, steps: @steps, title: "S")

      next = one(tree, "button[phx-click=\"wizard_next\"]")
      assert text(next) == "Continue"
      assert Floki.attribute(next, "disabled") == []

      blocked =
        render_tree(&ProviderWizard.wizard_shell/1,
          step: :auth,
          steps: @steps,
          title: "S",
          next_disabled: true
        )

      assert Floki.attribute(one(blocked, "button[phx-click=\"wizard_next\"]"), "disabled") ==
               ["disabled"]
    end

    test "honours custom event names and labels" do
      tree =
        render_tree(&ProviderWizard.wizard_shell/1,
          step: :auth,
          steps: @steps,
          title: "S",
          back_event: "go_back",
          next_event: "go_next",
          next_label: "Finish setup",
          cancel_event: "abort_setup",
          cancel_label: "Abort"
        )

      assert text(one(tree, "button[phx-click=\"go_back\"]")) == "Back"
      assert text(one(tree, "button[phx-click=\"go_next\"]")) == "Finish setup"
      assert text(one(tree, "button[phx-click=\"abort_setup\"]")) == "Abort"
      assert nodes(tree, "button[phx-click=\"wizard_next\"]") == []
    end

    test "renders no Cancel button without a cancel_event" do
      tree = render_tree(&ProviderWizard.wizard_shell/1, step: :auth, steps: @steps, title: "S")

      refute text(one(tree, "footer")) =~ "Cancel"
    end

    test "formats an error tuple into the strip" do
      tree =
        render_tree(&ProviderWizard.wizard_shell/1,
          step: :provider,
          steps: @steps,
          title: "S",
          error: {:error, :missing_provider}
        )

      strip = one(tree, "p[class*=\"bg-error/10\"]")
      assert text(strip) =~ "missing provider"
    end

    test "formats a binary and an atom error, and renders no strip without one" do
      binary =
        render_tree(&ProviderWizard.wizard_shell/1,
          step: :provider,
          steps: @steps,
          title: "S",
          error: "Could not reach the provider"
        )

      assert text(one(binary, "p[class*=\"bg-error/10\"]")) =~ "Could not reach the provider"

      atom =
        render_tree(&ProviderWizard.wizard_shell/1,
          step: :provider,
          steps: @steps,
          title: "S",
          error: :invalid_auth_mode
        )

      assert text(one(atom, "p[class*=\"bg-error/10\"]")) =~ "invalid auth mode"

      clean =
        render_tree(&ProviderWizard.wizard_shell/1, step: :provider, steps: @steps, title: "S")

      assert nodes(clean, "p[class*=\"bg-error/10\"]") == []
    end
  end

  describe "step_provider/1" do
    test "renders one card per provider plus the always-present custom row" do
      tree =
        render_tree(&ProviderWizard.step_provider/1,
          providers: [
            %{"id" => "deepseek", "label" => "DeepSeek", "note" => "Vendor note"},
            %{"id" => "zai"},
            %{"id" => "", "label" => "dropped"}
          ]
        )

      assert length(nodes(tree, "button[phx-click=\"select_provider\"]")) == 3

      deepseek = one(tree, "button[phx-value-provider=\"deepseek\"]")
      assert text(deepseek) =~ "DeepSeek"
      assert text(deepseek) =~ "Vendor note"

      custom = one(tree, "button[phx-value-provider=\"custom\"]")
      assert text(custom) =~ "Custom / OpenAI-compatible endpoint"
    end

    test "marks the selected card with aria-pressed and aria-current" do
      tree =
        render_tree(&ProviderWizard.step_provider/1,
          providers: [%{"id" => "deepseek"}, %{"id" => "zai"}],
          selected: "zai"
        )

      selected = one(tree, "button[phx-value-provider=\"zai\"]")
      assert attr(selected, "aria-pressed") == "true"
      assert attr(selected, "aria-current") == "true"
      assert attr(selected, "class") =~ "border-primary"

      other = one(tree, "button[phx-value-provider=\"deepseek\"]")
      assert attr(other, "aria-pressed") == "false"
      assert Floki.attribute(other, "aria-current") == []
    end

    test "marks the custom row selected when the draft selects a custom endpoint" do
      tree = render_tree(&ProviderWizard.step_provider/1, selected: "custom")

      assert attr(one(tree, "button[phx-value-provider=\"custom\"]"), "aria-current") == "true"
    end

    test "always renders the base_url input" do
      tree = render_tree(&ProviderWizard.step_provider/1, base_url: "https://api.example.com/v1")

      input = one(tree, "input[name=\"base_url\"]")
      assert attr(input, "type") == "url"
      assert attr(input, "id") == "base_url-input"
      assert attr(input, "value") == "https://api.example.com/v1"

      # Still present with no providers and no value.
      bare = one(render_tree(&ProviderWizard.step_provider/1), "input[name=\"base_url\"]")
      assert Floki.attribute(bare, "value") == []
    end

    test "honours custom event, value, name and labels" do
      tree =
        render_tree(&ProviderWizard.step_provider/1,
          providers: [%{"id" => "deepseek"}],
          provider_event: "choose_provider",
          custom_value: "endpoint",
          base_url_name: "endpoint_url",
          base_url_label: "Endpoint",
          base_url_placeholder: "https://my.proxy/v1"
        )

      assert nodes(tree, "button[phx-click=\"choose_provider\"]") != []
      assert nodes(tree, "button[phx-value-provider=\"endpoint\"]") != []

      input = one(tree, "input[name=\"endpoint_url\"]")
      assert attr(input, "id") == "endpoint_url-input"
      assert attr(input, "placeholder") == "https://my.proxy/v1"
      assert text(tree) =~ "Endpoint"
    end
  end

  describe "step_auth/1" do
    test "renders both supported modes and marks the selection" do
      tree = render_tree(&ProviderWizard.step_auth/1, selected: "oauth")

      assert length(nodes(tree, "button[phx-click=\"select_auth\"]")) == 2

      api_key = one(tree, "button[phx-value-mode=\"api_key\"]")
      assert text(api_key) =~ "API key"
      assert attr(api_key, "aria-pressed") == "false"

      oauth = one(tree, "button[phx-value-mode=\"oauth\"]")
      assert text(oauth) =~ "Subscription"
      assert attr(oauth, "aria-pressed") == "true"
      assert attr(oauth, "aria-current") == "true"
    end

    test "renders only the supported modes" do
      api_key_only = render_tree(&ProviderWizard.step_auth/1, modes: [:api_key])
      assert length(nodes(api_key_only, "button[phx-value-mode=\"api_key\"]")) == 1
      assert nodes(api_key_only, "button[phx-value-mode=\"oauth\"]") == []

      oauth_only = render_tree(&ProviderWizard.step_auth/1, modes: ["oauth"])
      assert length(nodes(oauth_only, "button[phx-value-mode=\"oauth\"]")) == 1
      assert nodes(oauth_only, "button[phx-value-mode=\"api_key\"]") == []
    end

    test "falls back to the API-key card for an empty or unknown mode list" do
      for modes <- [[], ["nonsense"]] do
        tree = render_tree(&ProviderWizard.step_auth/1, modes: modes)
        assert length(nodes(tree, "button[phx-value-mode=\"api_key\"]")) == 1
        assert nodes(tree, "button[phx-value-mode=\"oauth\"]") == []
      end
    end

    test "oauth_only keeps only the subscription card and explains the short circuit" do
      tree = render_tree(&ProviderWizard.step_auth/1, oauth_only: true)

      assert length(nodes(tree, "button[phx-value-mode=\"oauth\"]")) == 1
      assert nodes(tree, "button[phx-value-mode=\"api_key\"]") == []
      assert text(tree) =~ "only accepts a subscription login"
    end

    test "renders no secret field — the caller owns credentials" do
      tree = render_tree(&ProviderWizard.step_auth/1, oauth_only: false)

      assert nodes(tree, "input") == []
      assert nodes(tree, "input[type=\"password\"]") == []
    end
  end

  describe "step_model/1 — search form" do
    test "renders the search form with the default event and query name" do
      tree = render_tree(&ProviderWizard.step_model/1, query: "flash")

      form = one(tree, "#wizard-model-search")
      assert attr(form, "phx-change") == "search_models"
      assert attr(form, "phx-submit") == "search_models"

      input = one(tree, "input[name=\"query\"]")
      assert attr(input, "type") == "search"
      assert attr(input, "value") == "flash"
    end

    test "honours a custom search event and input name" do
      tree =
        render_tree(&ProviderWizard.step_model/1,
          model_search_event: "filter_models",
          search_name: "q"
        )

      assert attr(one(tree, "#wizard-model-search"), "phx-change") == "filter_models"
      assert nodes(tree, "input[name=\"q\"]") != []
    end
  end

  describe "step_model/1 — catalog list" do
    test "renders the catalog rows and marks the pick with aria-current" do
      tree =
        render_tree(&ProviderWizard.step_model/1,
          models: [
            %{"id" => "deepseek-flash", "label" => "DeepSeek V4.1 Flash", "variant" => "Fast"},
            "bare-model"
          ],
          selected: "deepseek-flash"
        )

      buttons = nodes(tree, "ul[role=\"list\"] button[phx-click=\"select_model\"]")
      assert length(buttons) == 2

      picked = one(tree, "button[phx-value-model=\"deepseek-flash\"]")
      assert attr(picked, "aria-current") == "true"
      assert text(picked) =~ "DeepSeek V4.1 Flash"
      assert text(picked) =~ "Fast"

      bare = one(tree, "button[phx-value-model=\"bare-model\"]")
      assert Floki.attribute(bare, "aria-current") == []
      assert text(bare) == "bare-model"
    end

    test "an empty catalog shows the empty-search note and no list" do
      tree = render_tree(&ProviderWizard.step_model/1, models: [], query: "nothing")

      assert nodes(tree, "ul[role=\"list\"]") == []
      assert text(tree) =~ "No catalog model matches this search"
    end
  end

  describe "step_model/1 — always-present custom model input" do
    test "renders the free-text custom model input by default" do
      tree = render_tree(&ProviderWizard.step_model/1, models: [%{"id" => "deepseek-flash"}])

      input = one(tree, "input[name=\"custom_model\"]")
      assert attr(input, "type") == "text"
      assert attr(input, "id") == "custom_model-input"
      assert text(tree) =~ "Use a custom model name"
      assert nodes(tree, "#wizard-custom-model-form") == []
    end

    test "renders it even with no catalog models and carries a value" do
      tree = render_tree(&ProviderWizard.step_model/1, models: [], custom_model: "my-local-model")

      assert attr(one(tree, "input[name=\"custom_model\"]"), "value") == "my-local-model"
    end

    test "wraps the input in an event form when custom_model_event is set" do
      tree =
        render_tree(&ProviderWizard.step_model/1,
          custom_model_event: "update_custom_model",
          custom_model_name: "endpoint_model"
        )

      assert attr(one(tree, "#wizard-custom-model-form"), "phx-change") == "update_custom_model"
      assert nodes(tree, "input[name=\"endpoint_model\"]") != []
    end
  end

  describe "step_reasoning_schedule/1 — reasoning chips" do
    test "renders the canonical ladder in core order, never \"max\"" do
      tree = render_tree(&ProviderWizard.step_reasoning_schedule/1, inventory: ["low", "high"])

      chips = nodes(tree, "input[type=\"checkbox\"][name=\"reasoning_efforts[]\"]")
      assert attrs(chips, "value") == ["none", "minimal", "low", "medium", "high", "xhigh"]

      assert length(nodes(tree, "input[value=\"xhigh\"]")) == 1
      assert nodes(tree, "input[value=\"max\"]") == []
    end

    test "renders exactly one hidden blank seed beside the six chips" do
      tree = render_tree(&ProviderWizard.step_reasoning_schedule/1, inventory: ["low"])

      assert length(nodes(tree, "input[name=\"reasoning_efforts[]\"]")) == 7

      seed = one(tree, "input[type=\"hidden\"][name=\"reasoning_efforts[]\"]")
      assert attr(seed, "value") == ""
    end

    test "checks exactly the inventory members" do
      tree =
        render_tree(&ProviderWizard.step_reasoning_schedule/1, inventory: ["low", "max", "ultra"])

      assert tree |> nodes("input[type=\"checkbox\"][checked]") |> attrs("value") ==
               ["low", "xhigh", "ultra"]
    end

    test "appends an unknown configured value once, after the canonical ladder" do
      tree = render_tree(&ProviderWizard.step_reasoning_schedule/1, inventory: ["ultra", "Ultra"])

      assert attrs(nodes(tree, "input[type=\"checkbox\"]"), "value") == [
               "none",
               "minimal",
               "low",
               "medium",
               "high",
               "xhigh",
               "ultra"
             ]

      assert attr(one(tree, "input[value=\"ultra\"]"), "checked") == "checked"
    end

    test "honours a custom inventory input name" do
      tree =
        render_tree(&ProviderWizard.step_reasoning_schedule/1,
          inventory: ["low"],
          inventory_name: "efforts[]"
        )

      assert length(nodes(tree, "input[name=\"efforts[]\"]")) == 7
      assert nodes(tree, "input[name=\"reasoning_efforts[]\"]") == []
    end
  end

  describe "step_reasoning_schedule/1 — default effort select" do
    test "offers the provider default plus exactly the inventory, in inventory order" do
      tree =
        render_tree(&ProviderWizard.step_reasoning_schedule/1,
          inventory: ["low", "high", "xhigh"],
          default_effort: "high"
        )

      select = one(tree, "#default-reasoning-effort")
      assert attr(select, "name") == "default_reasoning_effort"
      assert option_values(tree, "#default-reasoning-effort") == ["", "low", "high", "xhigh"]
      assert selected_option_values(tree, "#default-reasoning-effort") == ["high"]

      assert option_labels(tree, "#default-reasoning-effort") == [
               "Provider default",
               "Low",
               "High",
               "Extra high"
             ]
    end

    test "a stale default points at the provider-default option" do
      tree =
        render_tree(&ProviderWizard.step_reasoning_schedule/1,
          inventory: ["low", "high"],
          default_effort: "max"
        )

      assert selected_option_values(tree, "#default-reasoning-effort") == [""]
    end

    test "renders no default select for an empty inventory" do
      tree = render_tree(&ProviderWizard.step_reasoning_schedule/1, inventory: [])

      assert nodes(tree, "#default-reasoning-effort") == []
      refute text(tree) =~ "Default reasoning effort"

      # The chips themselves are still offered.
      assert length(nodes(tree, "input[type=\"checkbox\"]")) == 6
    end

    test "honours a custom default input name" do
      tree =
        render_tree(&ProviderWizard.step_reasoning_schedule/1,
          inventory: ["low"],
          default_name: "effort"
        )

      assert attr(one(tree, "#default-reasoning-effort"), "name") == "effort"
    end
  end

  describe "step_reasoning_schedule/1 — schedule and holidays" do
    test "renders the holiday select with the real calendars and the blank option" do
      tree = render_tree(&ProviderWizard.step_reasoning_schedule/1)

      select = one(tree, "#off-peak-holidays")
      assert attr(select, "name") == "off_peak_holidays"
      assert option_values(tree, "#off-peak-holidays") == ["", "CN"]

      assert option_labels(tree, "#off-peak-holidays") == [
               "No public-holiday calendar",
               "China (CN)"
             ]

      assert text(tree) =~ "off-peak"
    end

    test "marks the configured holiday calendar and honours caller options/help" do
      tree =
        render_tree(&ProviderWizard.step_reasoning_schedule/1,
          off_peak_holidays: "CN",
          holiday_options: [{"CN", "China (CN)"}, {"US", "United States (US)"}],
          holiday_help: "Statutory holidays count as off-peak."
        )

      assert selected_option_values(tree, "#off-peak-holidays") == ["CN"]
      assert option_values(tree, "#off-peak-holidays") == ["", "CN", "US"]
      assert text(tree) =~ "Statutory holidays count as off-peak."
    end

    test "renders the applied preset strip with apply/undo (and optional dismiss) events" do
      tree =
        render_tree(&ProviderWizard.step_reasoning_schedule/1,
          presets: [%{"id" => "deepseek-standard", "label" => "DeepSeek standard"}],
          preset_applied: "deepseek-standard",
          preset_dismiss_event: "dismiss_schedule_preset"
        )

      assert text(tree) =~ "Recommended schedule applied"
      assert text(tree) =~ "DeepSeek standard"
      assert text(tree) =~ "Published schedule presets"

      # The applied strip's re-apply button plus the chooser button.
      assert length(nodes(tree, "button[phx-value-preset_id=\"deepseek-standard\"]")) == 2
      assert length(nodes(tree, "button[phx-click=\"apply_schedule_preset\"]")) == 2
      assert length(nodes(tree, "button[phx-click=\"undo_schedule_preset\"]")) == 1
      assert length(nodes(tree, "button[phx-click=\"dismiss_schedule_preset\"]")) == 1
    end

    test "renders only the preset chooser when no preset is applied" do
      tree =
        render_tree(&ProviderWizard.step_reasoning_schedule/1,
          presets: [%{"id" => "deepseek-standard", "label" => "DeepSeek standard"}]
        )

      assert text(tree) =~ "Published schedule presets"
      refute text(tree) =~ "Recommended schedule applied"
      assert nodes(tree, "button[phx-click=\"undo_schedule_preset\"]") == []
      assert nodes(tree, "button[phx-click=\"dismiss_schedule_preset\"]") == []
    end

    test "renders no schedule block without presets or an applied preset" do
      tree = render_tree(&ProviderWizard.step_reasoning_schedule/1)

      refute text(tree) =~ "Published schedule presets"
      refute text(tree) =~ "Recommended schedule applied"
    end

    test "renders the schedule summary rows" do
      tree =
        render_tree(&ProviderWizard.step_reasoning_schedule/1,
          schedule_rows: [{"Concurrency", "4"}, {"Peak hours", "01:00–04:00"}]
        )

      assert rows(tree, "dl > div") == [{"Concurrency", "4"}, {"Peak hours", "01:00–04:00"}]
    end

    test "accepts map summary rows and renders no list for none" do
      tree =
        render_tree(&ProviderWizard.step_reasoning_schedule/1,
          schedule_rows: [%{"label" => "Timezone", "value" => "UTC"}]
        )

      assert rows(tree, "dl > div") == [{"Timezone", "UTC"}]
      assert nodes(render_tree(&ProviderWizard.step_reasoning_schedule/1), "dl") == []
    end
  end

  describe "step_test/1" do
    test "idle renders the test and skip buttons without a result notice" do
      tree = render_tree(&ProviderWizard.step_test/1)

      test_button = one(tree, "button[phx-click=\"test_connection\"]")
      assert text(test_button) == "Test connection"
      assert Floki.attribute(test_button, "disabled") == []

      assert text(one(tree, "button[phx-click=\"skip_test\"]")) == "Skip for now"
      refute text(tree) =~ "Testing the connection"
      refute text(tree) =~ "Connection succeeded."
      refute text(tree) =~ "Connection failed."
    end

    test "testing disables the button and shows the spinner copy" do
      tree = render_tree(&ProviderWizard.step_test/1, test_state: :testing)

      assert Floki.attribute(one(tree, "button[phx-click=\"test_connection\"]"), "disabled") ==
               ["disabled"]

      assert text(tree) =~ "Testing the connection"
      assert text(tree) =~ "Skip for now"
    end

    test "renders the success notice with and without a detail" do
      detailed = render_tree(&ProviderWizard.step_test/1, test_state: {:ok, "2 models available"})
      assert text(detailed) =~ "Connection succeeded."
      assert text(detailed) =~ "2 models available"

      plain = render_tree(&ProviderWizard.step_test/1, test_state: :ok)
      assert text(plain) =~ "Connection succeeded."
      refute text(plain) =~ "models available"
    end

    test "renders the error notice through the total formatter" do
      atom_error =
        render_tree(&ProviderWizard.step_test/1, test_state: {:error, :invalid_api_key})

      assert text(atom_error) =~ "Connection failed."
      assert text(atom_error) =~ "invalid api key"

      string_error = render_tree(&ProviderWizard.step_test/1, test_state: {:error, "bad key"})
      assert text(string_error) =~ "Connection failed."
      assert text(string_error) =~ "bad key"
    end

    test "honours custom events and labels" do
      tree =
        render_tree(&ProviderWizard.step_test/1,
          test_event: "probe_connection",
          skip_event: "skip_probe",
          test_label: "Probe",
          skip_label: "Later"
        )

      assert text(one(tree, "button[phx-click=\"probe_connection\"]")) == "Probe"
      assert text(one(tree, "button[phx-click=\"skip_probe\"]")) == "Later"
    end
  end

  describe "step_done/1" do
    test "renders the summary rows, dropping blank ones" do
      tree =
        render_tree(&ProviderWizard.step_done/1,
          summary: [{"Provider", "DeepSeek"}, {"Model", "deepseek-flash"}, {"Blank", ""}]
        )

      assert rows(tree, "dl > div") == [
               {"Provider", "DeepSeek"},
               {"Model", "deepseek-flash"}
             ]
    end

    test "accepts map rows and renders no list for an empty summary" do
      tree =
        render_tree(&ProviderWizard.step_done/1,
          summary: [%{"label" => "Provider", "value" => "DeepSeek"}]
        )

      assert rows(tree, "dl > div") == [{"Provider", "DeepSeek"}]
      assert nodes(render_tree(&ProviderWizard.step_done/1), "dl") == []
    end

    test "links into the dashboard, honouring the path and label" do
      tree = render_tree(&ProviderWizard.step_done/1)

      assert text(one(tree, "a[href=\"/projects\"]")) == "Go to the dashboard"

      custom =
        render_tree(&ProviderWizard.step_done/1,
          dashboard_path: "/settings",
          dashboard_label: "Review settings"
        )

      assert text(one(custom, "a[href=\"/settings\"]")) == "Review settings"
    end
  end

  describe "each step renders only its own content" do
    test "the shell contributes no step content of its own" do
      tree =
        render_tree(&ProviderWizard.wizard_shell/1,
          step: :provider,
          steps: @steps,
          title: "Setup"
        )

      for {_step, marker} <- @step_markers do
        refute text(tree) =~ marker
      end
    end

    test "every step renders its own marker and none of the other steps'" do
      for {step, marker} <- @step_markers do
        rendered = text(render_tree(step_fun(step)))

        assert rendered =~ marker, "#{step} should render #{inspect(marker)}"

        for {other_step, other_marker} <- @step_markers, other_step != step do
          refute rendered =~ other_marker,
                 "#{step} must not render #{other_step}'s content (#{inspect(other_marker)})"
        end
      end
    end
  end

  describe "styling and secret boundaries" do
    test "emits only the CSS-owned class names, no stylesheet and no motion policy" do
      markup =
        html(&ProviderWizard.wizard_shell/1, step: :model, steps: @steps, title: "Setup")

      refute markup =~ "<style"
      refute markup =~ "prefers-reduced-motion"
      assert markup =~ "wizard-progress"
      assert markup =~ "wizard-step-enter"
    end

    test "no component renders a secret input" do
      components = [
        {&ProviderWizard.wizard_shell/1,
         [step: :provider, steps: @steps, title: "Setup", error: {:error, :missing_provider}]},
        {&ProviderWizard.step_provider/1, []},
        {&ProviderWizard.step_auth/1, []},
        {&ProviderWizard.step_model/1, []},
        {&ProviderWizard.step_reasoning_schedule/1, []},
        {&ProviderWizard.step_test/1, []},
        {&ProviderWizard.step_done/1, []}
      ]

      for {fun, assigns} <- components do
        markup = html(fun, assigns)

        refute markup =~ "type=\"password\""
        refute markup =~ "<style"
      end
    end
  end

  describe "label fallbacks — an unlabeled row is never blank" do
    test "a labeled provider row keeps its label byte-for-byte" do
      tree =
        render_tree(&ProviderWizard.step_provider/1,
          providers: [%{"id" => "deepseek", "label" => "DeepSeek (Vendor)"}]
        )

      assert text(one(tree, "button[phx-value-provider=\"deepseek\"]")) == "DeepSeek (Vendor)"
    end

    test "a provider label is read label → display_name → name" do
      tree =
        render_tree(&ProviderWizard.step_provider/1,
          providers: [
            %{"id" => "zai", "display_name" => "Zed AI", "name" => "Ignored"},
            %{"id" => "deepseek", "name" => "DeepSeek Ltd"}
          ]
        )

      assert text(one(tree, "button[phx-value-provider=\"zai\"]")) == "Zed AI"
      assert text(one(tree, "button[phx-value-provider=\"deepseek\"]")) == "DeepSeek Ltd"
    end

    test "a nil / blank / absent provider label falls back to the provider display name" do
      variants = [
        [%{"id" => "zai"}],
        [%{"id" => "zai", "label" => nil}],
        [%{"id" => "zai", "label" => "   "}],
        [%{"id" => "zai", "name" => ""}],
        [%{id: :zai}]
      ]

      for providers <- variants do
        tree = render_tree(&ProviderWizard.step_provider/1, providers: providers)

        assert text(one(tree, "button[phx-value-provider=\"zai\"]")) == "Z.ai (Zhipu AI)",
               "expected the provider display name for #{inspect(providers)}"
      end
    end

    test "an unlabeled model row renders the model id and no duplicate id line" do
      tree = render_tree(&ProviderWizard.step_model/1, models: [%{"id" => "bare-model-x"}])
      row = one(tree, "button[phx-value-model=\"bare-model-x\"]")

      assert text(row) == "bare-model-x"
      # The label IS the id, so the second (mono) id line is suppressed.
      assert row |> nodes("span.block") |> Enum.map(&text/1) == ["bare-model-x"]
    end

    test "a labeled model row keeps its label and still shows the id" do
      tree =
        render_tree(&ProviderWizard.step_model/1,
          models: [%{"id" => "deepseek-flash", "label" => "DeepSeek V4.1 Flash"}]
        )

      row = one(tree, "button[phx-value-model=\"deepseek-flash\"]")

      assert row |> nodes("span.block") |> Enum.map(&text/1) == [
               "DeepSeek V4.1 Flash",
               "deepseek-flash"
             ]
    end

    test "an id-less provider row is dropped, leaving only the custom endpoint row" do
      tree =
        render_tree(&ProviderWizard.step_provider/1,
          providers: [
            %{"label" => "No id"},
            %{"id" => ""},
            %{"id" => "   "},
            %{"id" => 42},
            nil,
            "  "
          ]
        )

      assert [custom] = nodes(tree, "button[phx-click=\"select_provider\"]")
      assert attr(custom, "phx-value-provider") == "custom"
      assert text(custom) =~ "Custom / OpenAI-compatible endpoint"
    end

    test "an id-less model row is dropped, leaving the empty-catalog note" do
      tree =
        render_tree(&ProviderWizard.step_model/1,
          models: [%{"label" => "No id"}, %{"id" => ""}, %{"model" => "   "}, 42, nil]
        )

      assert nodes(tree, "ul[role=\"list\"]") == []
      assert text(tree) =~ "No catalog model matches this search"
    end
  end

  # ═══════════════════════════════════════════════════════════════════════════
  # ChatGPTAuth.chatgpt_auth/1 — in-browser sign-in vs. the CLI fallback
  # ═══════════════════════════════════════════════════════════════════════════

  describe "chatgpt_auth/1 — local sign-in" do
    test "renders the sign-in button, no CLI hint, and keeps the refresh action" do
      tree =
        render_tree(&ChatGPTAuth.chatgpt_auth/1,
          id: "wizard",
          change_event: "change",
          refresh_event: "refresh"
        )

      assert [button] = nodes(tree, "#wizard-sign-in")
      assert attr(button, "type") == "button"
      assert attr(button, "phx-click") == "chatgpt_sign_in"
      assert text(button) == "Sign in with ChatGPT"

      refute text(tree) =~ "genesis chatgpt login"
      assert nodes(tree, "#wizard-manual-hint") == []

      assert [refresh] = nodes(tree, "#wizard-refresh")
      assert attr(refresh, "phx-value-refresh_chatgpt") == "true"
    end

    test "honours the caller's event names" do
      tree =
        render_tree(&ChatGPTAuth.chatgpt_auth/1,
          id: "wizard",
          change_event: "change",
          refresh_event: "refresh",
          sign_in_event: "go",
          cancel_event: "stop"
        )

      assert attr(one(tree, "#wizard-sign-in"), "phx-click") == "go"

      waiting =
        render_tree(&ChatGPTAuth.chatgpt_auth/1,
          id: "wizard",
          change_event: "change",
          refresh_event: "refresh",
          sign_in_event: "go",
          cancel_event: "stop",
          sign_in: %{phase: :waiting, url: "https://example.test/a"}
        )

      assert attr(one(waiting, "#wizard-sign-in-cancel"), "phx-click") == "stop"
    end

    test "the account picker and the connected line still render" do
      tree =
        render_tree(&ChatGPTAuth.chatgpt_auth/1,
          id: "wizard",
          account: "work",
          accounts: %{"work" => %{account_id: "work@example.test"}},
          change_event: "change",
          refresh_event: "refresh"
        )

      assert attr(one(tree, "#wizard-form"), "phx-change") == "change"
      assert option_values(tree, "#wizard-account") == ["", "work"]

      assert option_labels(tree, "#wizard-account") == [
               "Choose a connected account",
               "work · work@example.test"
             ]

      status = one(tree, "p[role=\"status\"]")
      assert text(status) == "ChatGPT connected"
    end

    test "an account map without options renders no form" do
      tree =
        render_tree(&ChatGPTAuth.chatgpt_auth/1,
          id: "wizard",
          accounts: %{},
          change_event: "change",
          refresh_event: "refresh"
        )

      assert nodes(tree, "#wizard-form") == []
      assert nodes(tree, "p[role=\"status\"]") == []
    end
  end

  describe "chatgpt_auth/1 — waiting for authorization" do
    test "renders a real link, the waiting line and a cancel button" do
      tree =
        render_tree(&ChatGPTAuth.chatgpt_auth/1,
          id: "wizard",
          change_event: "change",
          refresh_event: "refresh",
          sign_in: %{flow_id: "f1", url: "https://example.test/authorize?a=1", phase: :waiting}
        )

      link = one(tree, "#wizard-sign-in-url")
      assert attr(link, "href") == "https://example.test/authorize?a=1"
      assert attr(link, "target") == "_blank"
      assert attr(link, "rel") == "noopener noreferrer"
      assert text(link) == "Open the ChatGPT sign-in page"

      assert text(one(tree, "#wizard-waiting p[role=\"status\"]")) == "Waiting for authorization…"
      assert text(one(tree, "#wizard-sign-in-cancel")) == "Cancel"

      # The primary action is replaced by the waiting block, not duplicated.
      assert nodes(tree, "#wizard-sign-in") == []
      assert nodes(tree, "#wizard-sign-in-error") == []
      assert nodes(tree, "#wizard-refresh") != []
    end

    test "a nil url renders no link at all instead of a broken one" do
      for sign_in <- [
            %{phase: :waiting},
            %{phase: :waiting, url: nil},
            %{phase: :waiting, url: "   "}
          ] do
        tree =
          render_tree(&ChatGPTAuth.chatgpt_auth/1,
            id: "wizard",
            change_event: "change",
            refresh_event: "refresh",
            sign_in: sign_in
          )

        assert nodes(tree, "#wizard-waiting") != []
        assert nodes(tree, "#wizard-sign-in-url") == []
        assert nodes(tree, "a[href]") == []
        assert text(one(tree, "#wizard-sign-in-cancel")) == "Cancel"
      end
    end
  end

  describe "chatgpt_auth/1 — failures" do
    test "renders the friendly message with role=\"alert\" and never a raw atom" do
      tree =
        render_tree(&ChatGPTAuth.chatgpt_auth/1,
          id: "wizard",
          change_event: "change",
          refresh_event: "refresh",
          sign_in: %{phase: :error, reason: :plan_not_authorized}
        )

      error = one(tree, "#wizard-sign-in-error")
      assert attr(error, "role") == "alert"
      assert text(error) == "Genesis was not granted permission to use this ChatGPT plan."
      refute text(tree) =~ "plan_not_authorized"

      # The user can immediately start again.
      assert nodes(tree, "#wizard-sign-in") != []
      assert nodes(tree, "#wizard-waiting") == []
    end

    test "an unknown reason falls back to generic text" do
      tree =
        render_tree(&ChatGPTAuth.chatgpt_auth/1,
          id: "wizard",
          change_event: "change",
          refresh_event: "refresh",
          sign_in: %{phase: :error, reason: :something_nobody_documented}
        )

      error_text = text(one(tree, "#wizard-sign-in-error"))
      assert error_text == "Sign-in could not be completed. Start again."
      refute error_text =~ "something_nobody_documented"
      refute error_text =~ "%"
    end

    test "an informational outcome uses the muted tone" do
      tree =
        render_tree(&ChatGPTAuth.chatgpt_auth/1,
          id: "wizard",
          change_event: "change",
          refresh_event: "refresh",
          sign_in: %{phase: :error, reason: :cancelled}
        )

      error = one(tree, "#wizard-sign-in-error")
      assert text(error) == "Sign-in cancelled."
      assert attr(error, "class") =~ "text-base-content/70"
      refute attr(error, "class") =~ "text-error"
    end

    test "an :error outcome uses the error tone" do
      tree =
        render_tree(&ChatGPTAuth.chatgpt_auth/1,
          id: "wizard",
          change_event: "change",
          refresh_event: "refresh",
          sign_in: %{phase: :error, reason: :authorization_denied}
        )

      assert attr(one(tree, "#wizard-sign-in-error"), "class") =~ "text-error"
    end

    test "an unset / unknown phase is idle — no waiting block, no error block" do
      for sign_in <- [%{}, %{phase: :nonsense}, %{phase: "ok?"}, nil] do
        tree =
          render_tree(&ChatGPTAuth.chatgpt_auth/1,
            id: "wizard",
            change_event: "change",
            refresh_event: "refresh",
            sign_in: sign_in
          )

        assert nodes(tree, "#wizard-waiting") == []
        assert nodes(tree, "#wizard-sign-in-error") == []
        assert nodes(tree, "#wizard-sign-in") != []
      end
    end
  end

  describe "chatgpt_auth/1 — remote / unsupported (manual) mode" do
    test "renders the CLI hint and the reason instead of a sign-in button" do
      tree =
        render_tree(&ChatGPTAuth.chatgpt_auth/1,
          id: "wizard",
          change_event: "change",
          refresh_event: "refresh",
          manual: true,
          sign_in: %{phase: :waiting, url: "https://example.test/a"}
        )

      hint = one(tree, "#wizard-manual-hint")
      assert text(hint) =~ "run this command on the execution node."
      assert text(hint) =~ "genesis chatgpt login"
      assert text(hint) =~ "same machine as the execution node"

      assert nodes(tree, "#wizard-sign-in") == []
      assert nodes(tree, "#wizard-waiting") == []
      assert nodes(tree, "#wizard-sign-in-error") == []
      assert nodes(tree, "#wizard-refresh") != []
    end
  end
end
