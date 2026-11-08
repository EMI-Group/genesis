defmodule EvoDashWeb.ProviderProfilesEditorTest do
  @moduledoc """
  Canonical account editor render contracts, independent of SettingsLive and disk config.
  Closed disclosures must retain successful form controls, not discard saved overrides.
  """
  use ExUnit.Case, async: true

  import Phoenix.LiveViewTest

  alias EvoDashWeb.SettingsComponents.ProviderProfilesEditor

  describe "simple account form" do
    test "uses one required catalog provider select, not the old quick-setup flow" do
      tree = edit()
      select = one(tree, ~s(select[name="provider"]))
      assert attr(select, "id") == ["provider-field-provider"]
      assert attr(select, "required") == ["required"]
      assert selected(select) == ["anthropic"]
      values = option_values(select)
      assert hd(values) == ""
      assert Enum.count(values, &(&1 == "openai")) == 1
      assert "openai_codex" in values
      assert "alibaba_cn" in values
      assert "zai_coding_plan" in values
      assert text(one(select, ~s(option[value="alibaba_cn"]))) =~ "CN"
      assert Floki.find(tree, ~s(input[name="provider"])) == []
      refute text(tree) =~ "Quick Setup"

      assert Floki.find(one(tree, "#provider-profile-advanced"), ~s(select[name="provider"])) ==
               []
    end

    test "a noncatalog saved provider remains selectable instead of silently changing" do
      tree = edit(profile(%{"provider" => "private_gateway"}))
      select = one(tree, ~s(select[name="provider"]))
      assert selected(select) == ["private_gateway"]

      assert text(one(select, ~s(option[value="private_gateway"]))) ==
               "Configured provider: private_gateway"
    end

    test "new accounts start with blank provider and model choices and closed disclosures" do
      tree = render_editor(editing_profile_id: :new, profile_form_draft: %{})
      assert selected(one(tree, ~s(select[name="provider"]))) == [""]
      assert option_values(one(tree, ~s(select[name="default_model"]))) == [""]
      helper = one(tree, ~s(input[name="default_model_name"]))
      assert attr(helper, "value") == [""]
      assert attr(helper, "required") == ["required"]
      assert text(tree) =~ "Add model rows only when you need per-model overrides."
      assert_closed(tree, "#provider-profile-advanced")
      assert_closed(tree, "#provider-generation-defaults")
      assert_closed(tree, "#provider-peak-schedule")
      assert attr(one(tree, ~s(input[name="concurrency"])), "value") == ["3"]
    end

    test "compact model rows keep names and removal buttons outside closed model details" do
      tree = edit()

      for {index, name} <- [{0, "model-a"}, {1, "model-b"}] do
        input = one(tree, ~s(input[name="models[#{index}][model]"]))
        assert attr(input, "value") == [name]
        assert attr(input, "required") == ["required"]
        details = assert_closed(tree, "#provider-model-details-#{index}")
        assert text(one(tree, "#provider-model-details-#{index} > summary")) == "Model details"
        assert Floki.find(details, ~s(input[name="models[#{index}][model]"])) == []
        assert Floki.find(details, ~s(button[phx-click="remove_provider_model"])) == []

        button =
          one(tree, ~s(button[phx-click="remove_provider_model"][phx-value-index="#{index}"]))

        assert attr(button, "type") == ["button"]
        assert attr(button, "aria-label") == ["Remove model #{index + 1}"]
        assert_closed(tree, "#provider-model-generation-#{index}")
      end

      assert attr(one(tree, ~s(button[phx-click="add_provider_model"])), "type") == ["button"]
    end

    test "actual default model and reasoning selects remain outside Advanced" do
      tree = edit()
      models = one(tree, ~s(select[name="default_model"]))
      assert option_values(models) == ["", "model-b", "model-a"]
      assert selected(models) == ["model-b"]
      assert attr(models, "required") == ["required"]
      reasoning = one(tree, ~s(select[name="default_reasoning_effort"]))
      assert option_values(reasoning) == ["", "high", "custom-fast", "low"]
      assert selected(reasoning) == ["low"]
      advanced = one(tree, "#provider-profile-advanced")
      assert Floki.find(advanced, ~s(select[name="default_model"])) == []
      assert Floki.find(advanced, ~s(select[name="default_reasoning_effort"])) == []
      assert attr(models, "aria-describedby") == ["provider-default-model-help"]

      assert text(one(tree, "#provider-default-model-help")) ==
               "Choose the default model. This does not create a model override."

      assert Floki.find(tree, ~s(input[name="default_model"])) == []
      assert Floki.find(tree, ~s(input[name="default_model_name"])) == []
    end

    test "default-only accounts expose a required helper without inventing nested rows" do
      tree = edit(profile(%{"default_model" => "legacy-default", "models" => []}))
      helper = one(tree, ~s(input[name="default_model_name"]))
      assert attr(helper, "type") == ["text"]
      assert attr(helper, "value") == ["legacy-default"]
      assert attr(helper, "required") == ["required"]
      assert attr(helper, "disabled") == []
      assert text(one(tree, ~s(label[for="provider-field-default_model_name"]))) == "Model name"
      assert attr(helper, "aria-describedby") == ["provider-field-default_model_name-help"]

      assert text(one(tree, "#provider-field-default_model_name-help")) =~
               "Edit the default model name."

      select = one(tree, ~s(select[name="default_model"]))
      assert option_values(select) == ["", "legacy-default"]
      assert selected(select) == ["legacy-default"]
      assert attr(select, "required") == ["required"]
      assert Floki.find(tree, ~s(input[name="default_model"])) == []
      assert Floki.find(tree, ~s(input[name$="[model]"])) == []
      assert Floki.find(tree, "[id^=provider-model-details-]") == []

      assert Floki.find(
               one(tree, "#provider-profile-advanced"),
               ~s(input[name="default_model_name"])
             ) == []
    end

    test "default-only helper uses the effective draft value and offers it in the real select" do
      account = profile(%{"default_model" => "saved-model", "models" => []})

      for {draft, helper, options, selected_default} <- [
            {%{}, "saved-model", ["", "saved-model"], "saved-model"},
            {%{"default_model" => "draft-default"}, "draft-default", ["", "draft-default"],
             "draft-default"},
            {%{"default_model_name" => "helper-model"}, "helper-model",
             ["", "saved-model", "helper-model"], "saved-model"},
            {%{"default_model" => "helper-model", "default_model_name" => "helper-model"},
             "helper-model", ["", "helper-model"], "helper-model"},
            {%{"default_model" => "", "default_model_name" => " helper-model "}, " helper-model ",
             ["", "helper-model"], ""},
            {%{"default_model_name" => ""}, "", ["", "saved-model"], "saved-model"},
            {%{"default_model_name" => nil}, "saved-model", ["", "saved-model"], "saved-model"}
          ] do
        tree = edit(account, draft)
        assert attr(one(tree, ~s(input[name="default_model_name"])), "value") == [helper]
        select = one(tree, ~s(select[name="default_model"]))
        assert option_values(select) == options
        assert selected(select) == [selected_default]
        assert Floki.find(tree, ~s(input[name$="[model]"])) == []
      end
    end

    test "live draft names populate defaults once while an explicit blank stays blank" do
      tree =
        edit(profile(), %{
          "default_model" => "",
          "default_reasoning_effort" => "",
          "models" => %{
            "10" => %{"model" => " renamed "},
            "2" => %{"model" => "renamed"},
            "3" => %{"model" => "new-model"}
          }
        })

      assert option_values(one(tree, ~s(select[name="default_model"]))) ==
               ["", "renamed", "new-model"]

      assert selected(one(tree, ~s(select[name="default_model"]))) == [""]
      assert selected(one(tree, ~s(select[name="default_reasoning_effort"]))) == [""]

      assert Enum.map(Floki.find(tree, ~s(input[name$="[model]"])), &attr(&1, "name")) ==
               [["models[2][model]"], ["models[3][model]"], ["models[10][model]"]]
    end
  end

  describe "closed advanced controls retain account and nested values" do
    test "saved identity, endpoint, zero concurrency and context remain successful controls" do
      tree =
        edit(
          profile(%{
            "base_url" => "https://gateway.example/v1",
            "concurrency" => 0,
            "context_window" => 262_144
          })
        )

      advanced = assert_closed(tree, "#provider-profile-advanced")

      for {name, value} <- [
            {"profile_id_new", "account-a"},
            {"name", "Research account"},
            {"base_url", "https://gateway.example/v1"},
            {"concurrency", "0"},
            {"context_window", "262144"}
          ] do
        input = one(advanced, ~s(input[name="#{name}"]))
        assert attr(input, "value") == [value]
        assert attr(input, "disabled") == []
      end

      assert attr(one(tree, ~s(input[name="profile_id"])), "value") == ["account-a"]
      assert attr(one(advanced, ~s(input[name="base_url"])), "type") == ["url"]
    end

    test "draft blanks and zero replace saved values even when Advanced stays closed" do
      tree =
        edit(profile(%{"concurrency" => 9, "context_window" => 200_000}), %{
          "profile_id_new" => "renamed-account",
          "name" => "",
          "base_url" => "",
          "concurrency" => 0,
          "context_window" => "",
          "models" => []
        })

      advanced = assert_closed(tree, "#provider-profile-advanced")
      assert attr(one(advanced, ~s(input[name="profile_id_new"])), "value") == ["renamed-account"]
      assert attr(one(advanced, ~s(input[name="concurrency"])), "value") == ["0"]

      for name <- ["name", "base_url", "context_window"] do
        assert attr(one(advanced, ~s(input[name="#{name}"])), "value") == [""]
      end

      assert Floki.find(tree, "[id^=provider-model-details-]") == []
    end

    test "account effort checkboxes keep custom order and a leading blank sentinel" do
      tree = edit()
      advanced = assert_closed(tree, "#provider-profile-advanced")
      assert_efforts(advanced, "reasoning_efforts[]", ["high", "custom-fast", "low"])
      assert Floki.find(tree, ~s(input[type="text"][name="reasoning_efforts"])) == []
    end

    test "exact catalog suggestions stay unchecked beside saved levels in closed account and model details" do
      account =
        profile(%{
          "provider" => "anthropic",
          "default_model" => "claude-opus-4-5-20251101",
          "reasoning_efforts" => ["vendor-custom", "high"],
          "default_reasoning_effort" => "vendor-custom",
          "models" => [
            %{
              "model" => "claude-opus-4-5-20251101",
              "reasoning_efforts" => ["model-custom", "low"],
              "default_reasoning_effort" => "model-custom"
            }
          ]
        })

      tree = edit(account)

      for {scope, name, saved, visible} <- [
            {assert_closed(tree, "#provider-profile-advanced"), "reasoning_efforts[]",
             ["vendor-custom", "high"], ["vendor-custom", "high", "low", "medium"]},
            {assert_closed(tree, "#provider-model-details-0"), "models[0][reasoning_efforts][]",
             ["model-custom", "low"], ["model-custom", "low", "medium", "high"]}
          ] do
        assert_efforts(scope, name, saved)
        advanced = reasoning_advanced(scope)
        assert attr(advanced, "open") == []
        assert checkbox_values(advanced, name) == ["none", "minimal", "xhigh", "max", "default"]
        assert checkbox_values(Floki.filter_out(elem(scope, 2), "details"), name) == visible
        assert text(scope) =~ "Catalog suggestions are shown alongside configured levels."
      end
    end

    test "generic and custom endpoints keep saved overrides while unverified vocabulary stays closed" do
      for overrides <- [
            %{"provider" => "private_gateway"},
            %{"provider" => "anthropic", "base_url" => "https://private.example/v1"}
          ] do
        account =
          profile(
            Map.merge(
              %{
                "default_model" => "claude-opus-4-5-20251101",
                "reasoning_efforts" => ["account-custom", "high"],
                "models" => [
                  %{
                    "model" => "claude-opus-4-5-20251101",
                    "reasoning_efforts" => ["model-custom", "low"]
                  }
                ]
              },
              overrides
            )
          )

        tree = edit(account)

        for {scope, name, saved, vocabulary} <- [
              {assert_closed(tree, "#provider-profile-advanced"), "reasoning_efforts[]",
               ["account-custom", "high"], ~w(none minimal low medium xhigh max default)},
              {assert_closed(tree, "#provider-model-details-0"), "models[0][reasoning_efforts][]",
               ["model-custom", "low"], ~w(none minimal medium high xhigh max default)}
            ] do
          assert_efforts(scope, name, saved)
          advanced = reasoning_advanced(scope)
          assert attr(advanced, "open") == []
          assert checkbox_values(advanced, name) == vocabulary
          assert checkbox_values(Floki.filter_out(elem(scope, 2), "details"), name) == saved
          assert text(scope) =~ "No verified catalog level list is available"
          assert text(advanced) =~ "not verified support for this model or endpoint"
        end
      end
    end

    test "an explicitly cleared account inventory keeps its sentinel and blank default" do
      tree = edit(profile(), %{"reasoning_efforts" => [], "default_reasoning_effort" => ""})
      assert_efforts(tree, "reasoning_efforts[]", [])
      select = one(tree, ~s(select[name="default_reasoning_effort"]))
      assert option_values(select) == [""]
      assert selected(select) == [""]
      assert attr(select, "aria-invalid") == []
    end

    test "closed account scheduling renders the authoritative draft rather than saved windows" do
      tree =
        edit(
          profile(%{
            "peak_concurrency" => 5,
            "timezone" => "UTC",
            "off_peak_days" => ["mon"],
            "peak_hours" => [%{"start" => "09:00", "end" => "18:00"}]
          }),
          %{
            "peak_concurrency" => 0,
            "timezone" => "Asia/Hong_Kong",
            "off_peak_days" => [],
            "peak_hours" => %{
              "3" => %{"start" => "22:30", "end" => "04:15", "days" => ["weekdays"]}
            }
          }
        )

      advanced = assert_closed(tree, "#provider-profile-advanced")
      schedule = assert_closed(advanced, "#provider-peak-schedule")
      assert attr(one(schedule, ~s(input[name="peak_concurrency"])), "value") == ["0"]
      assert attr(one(schedule, ~s(input[name="timezone"])), "value") == ["Asia/Hong_Kong"]
      assert attr(one(schedule, ~s(input[name="peak_hours[3][start]"])), "value") == ["22:30"]
      assert attr(one(schedule, ~s(input[name="peak_hours[3][end]"])), "value") == ["04:15"]
      assert Floki.find(schedule, ~s(input[name="peak_hours[0][start]"])) == []
      assert Floki.find(schedule, ~s(input[name="off_peak_days[]"][checked])) == []

      assert attr(one(schedule, ~s(input[type="hidden"][name="off_peak_days[]"])), "value") == [
               ""
             ]

      assert attr(one(schedule, ~s(input[name="peak_hours[3][days][]"][checked])), "value") == [
               "weekdays"
             ]
    end

    test "nested override inventory and actual default use model-indexed names" do
      model = %{
        "model" => "special-model",
        "context_window" => 131_072,
        "reasoning_efforts" => ["custom-deep", "low", "high"],
        "default_reasoning_effort" => "low"
      }

      tree = edit(profile(), %{"models" => %{"7" => model}})
      details = assert_closed(tree, "#provider-model-details-7")

      assert attr(one(details, ~s(input[name="models[7][context_window]"])), "value") == [
               "131072"
             ]

      assert_efforts(details, "models[7][reasoning_efforts][]", ["custom-deep", "low", "high"])
      select = one(details, ~s(select[name="models[7][default_reasoning_effort]"]))
      assert option_values(select) == ["", "custom-deep", "low", "high"]
      assert selected(select) == ["low"]

      assert attr(
               one(details, ~s(input[type="hidden"][name="models[7][override_reasoning]"])),
               "value"
             ) == ["false"]

      assert attr(
               one(details, ~s(input[type="checkbox"][name="models[7][override_reasoning]"])),
               "checked"
             ) == ["checked"]
    end

    test "inherited reasoning omits its inventory but allows a model-specific default" do
      tree = edit()
      details = one(tree, "#provider-model-details-0")
      assert Floki.find(details, ~s(input[name="models[0][reasoning_efforts][]"])) == []

      assert attr(
               one(details, ~s(input[type="checkbox"][name="models[0][override_reasoning]"])),
               "checked"
             ) == []

      select = one(details, ~s(select[name="models[0][default_reasoning_effort]"]))
      assert option_values(select) == ["", "high", "custom-fast", "low"]
      assert selected(select) == ["custom-fast"]
      assert text(one(select, ~s(option[value=""]))) == "Inherit provider default"
    end

    test "explicit empty model reasoning advertises no levels rather than inheriting" do
      tree =
        edit(profile(), %{"models" => [%{"model" => "no-reasoning", "reasoning_efforts" => []}]})

      details = one(tree, "#provider-model-details-0")
      assert_efforts(details, "models[0][reasoning_efforts][]", [])

      assert attr(
               one(details, ~s(input[type="checkbox"][name="models[0][override_reasoning]"])),
               "checked"
             ) == ["checked"]

      assert option_values(one(details, ~s(select[name="models[0][default_reasoning_effort]"]))) ==
               [""]

      assert text(details) =~ "No levels selected explicitly disables reasoning for this model."
    end

    test "explicit false override suppresses a retained draft inventory" do
      tree =
        edit(profile(), %{
          "models" => [
            %{
              "model" => "inherited",
              "override_reasoning" => "false",
              "reasoning_efforts" => ["private"]
            }
          ]
        })

      details = one(tree, "#provider-model-details-0")
      assert Floki.find(details, ~s(input[name="models[0][reasoning_efforts][]"])) == []

      assert option_values(one(details, ~s(select[name="models[0][default_reasoning_effort]"]))) ==
               ["", "high", "custom-fast", "low"]
    end

    test "shared and model generation values survive closed nested disclosures" do
      generation = %{
        "temperature" => 0,
        "max_tokens" => 8192,
        "top_p" => 0.7,
        "top_k" => 12,
        "frequency_penalty" => -0.5,
        "presence_penalty" => 0,
        "extra" => %{"flag" => false},
        "provider_options" => %{"custom" => "<keep>"}
      }

      tree =
        edit(
          profile(%{
            "generation" => generation,
            "models" => [%{"model" => "model-b", "generation" => generation}]
          })
        )

      for {selector, prefix} <- [
            {"#provider-generation-defaults", "generation"},
            {"#provider-model-generation-0", "models[0][generation]"}
          ] do
        details = assert_closed(tree, selector)

        for {key, value} <- Map.drop(generation, ["extra", "provider_options"]) do
          input = one(details, ~s(input[name="#{prefix}[#{key}]"]))
          assert attr(input, "value") == [to_string(value)]
          assert attr(input, "disabled") == []
        end

        for key <- ["extra", "provider_options"] do
          textarea = one(details, ~s(textarea[name="#{prefix}[#{key}]"]))
          assert Jason.decode!(textarea_value(textarea)) == generation[key]
          assert attr(textarea, "disabled") == []
        end
      end
    end
  end

  describe "authentication and retained form identity" do
    test "API-key credentials are guidance only, never copied into the profile form" do
      tree = edit(profile(%{"provider" => "deepseek", "api_key" => "SECRET-MARKER"}))
      assert text(tree) =~ "credentials file or environment"
      assert attr(one(tree, ~s(input[name="auth_mode"])), "value") == ["api_key"]
      assert Floki.find(tree, ~s(select[name="auth_mode"])) == []
      assert Floki.find(tree, ~s(input[name="api_key"])) == []
      assert Floki.find(tree, ~s(input[name="oauth_file"])) == []
      refute Floki.raw_html(tree) =~ "SECRET-MARKER"
    end

    test "API-key environment override is editable, clearable and retained when omitted from a draft" do
      account = profile(%{"api_key_env_var" => "ACCOUNT_A_API_KEY", "api_key" => "SECRET-MARKER"})

      for {draft, expected} <- [
            {nil, "ACCOUNT_A_API_KEY"},
            {%{"name" => "Changed name"}, "ACCOUNT_A_API_KEY"},
            {%{"api_key_env_var" => "ACCOUNT_B_API_KEY"}, "ACCOUNT_B_API_KEY"},
            {%{"api_key_env_var" => ""}, ""}
          ] do
        tree = edit(account, draft)
        advanced = assert_closed(tree, "#provider-profile-advanced")
        input = one(advanced, ~s(input[name="api_key_env_var"]))
        assert attr(input, "type") == ["text"]
        assert attr(input, "value") == [expected]
        assert attr(input, "disabled") == []
        assert attr(input, "required") == []
        assert attr(input, "aria-describedby") == ["provider-field-api_key_env_var-help"]
        help = text(one(advanced, "#provider-field-api_key_env_var-help"))
        assert help =~ "Enter the variable name, not the key."
        assert help =~ "this exact variable is used on the selected node"
        assert help =~ "no fallback to another account's key"
        assert help =~ "Clear it to use the provider's default credential source."
        assert length(Floki.find(tree, ~s(input[name="api_key_env_var"]))) == 1
        refute Floki.raw_html(tree) =~ "SECRET-MARKER"
      end
    end

    test "OAuth mode omits the saved environment override instead of submitting a blank clear" do
      for account <- [
            profile(%{"auth_mode" => "oauth", "api_key_env_var" => "ACCOUNT_A_API_KEY"}),
            profile(%{"provider" => "openai_codex", "api_key_env_var" => "ACCOUNT_A_API_KEY"})
          ] do
        tree = edit(account)
        assert_closed(tree, "#provider-profile-advanced")
        assert Floki.find(tree, ~s([name="api_key_env_var"])) == []
        refute Floki.raw_html(tree) =~ "ACCOUNT_A_API_KEY"
      end
    end

    test "OAuth-capable accounts expose the real auth select and selected-node credential path" do
      tree = edit(profile(%{"auth_mode" => "oauth", "oauth_file" => "~/remote/account.json"}))
      select = one(tree, ~s(select[name="auth_mode"]))
      assert option_values(select) == ["api_key", "oauth"]
      assert selected(select) == ["oauth"]
      assert attr(one(tree, ~s(input[name="oauth_file"])), "value") == ["~/remote/account.json"]
      assert text(tree) =~ "Blank uses the managed credential file on the selected node."

      assert Floki.find(one(tree, "#provider-profile-advanced"), ~s(input[name="oauth_file"])) ==
               []
    end

    test "OAuth-only accounts submit the mode even without a select" do
      tree = edit(profile(%{"provider" => "openai_codex", "auth_mode" => "api_key"}))
      assert Floki.find(tree, ~s(select[name="auth_mode"])) == []
      assert attr(one(tree, ~s(input[name="auth_mode"])), "value") == ["oauth"]
      assert text(tree) =~ "Subscription (OAuth)"
      assert text(tree) =~ "Run codex login on the selected node"
      assert Floki.find(tree, ~s(input[name="oauth_file"])) != []
      refute text(tree) =~ "credentials file or environment"
    end

    test "credential verdicts are keyed by account, not another account with the same provider" do
      account = profile(%{"auth_mode" => "oauth"})

      tree =
        edit(account, nil,
          auth_statuses: %{
            "other-account" => %{state: :missing, login_instructions: "OTHER-MARKER"}
          }
        )

      refute text(tree) =~ "No subscription login found"
      refute text(tree) =~ "OTHER-MARKER"
      assert text(tree) =~ "Subscription login"
    end

    test "provider, path or auth-mode draft changes cannot reuse an old credential verdict" do
      account = profile(%{"auth_mode" => "oauth", "oauth_file" => "/remote/original.json"})
      statuses = %{"account-a" => %{state: :ok, oauth_file: "/remote/status-marker.json"}}
      assert text(edit(account, nil, auth_statuses: statuses)) =~ "Login detected"

      for draft <- [
            %{"provider" => "openai_codex"},
            %{"oauth_file" => "/remote/changed.json"},
            %{"auth_mode" => "api_key"}
          ] do
        tree = edit(account, draft, auth_statuses: statuses)
        refute text(tree) =~ "Login detected"
        refute text(tree) =~ "/remote/status-marker.json"
      end
    end

    test "validation errors retain the editable draft and original identity" do
      tree =
        edit(profile(), %{"profile_id_new" => "renamed", "models" => []},
          errors: %{"models" => "Add at least one model"}
        )

      form = one(tree, "#provider-profile-edit-form")
      assert attr(form, "phx-submit") == ["save_provider_profile"]
      assert attr(form, "phx-change") == ["provider_profile_form_change"]
      assert attr(form, "aria-describedby") == ["provider-profile-errors"]
      assert attr(one(tree, "#provider-profile-errors"), "role") == ["alert"]
      assert text(tree) =~ "Add at least one model"
      assert attr(one(tree, ~s(input[name="profile_id"])), "value") == ["account-a"]
      assert attr(one(tree, ~s(input[name="profile_id_new"])), "value") == ["renamed"]
      assert Floki.find(tree, "[id^=provider-model-details-]") == []
    end

    test "creation uses the :new sentinel without opening a saved account named new" do
      tree =
        render_editor(
          provider_profiles: [profile(%{"id" => "new"})],
          editing_profile_id: :new,
          profile_form_draft: %{}
        )

      assert length(Floki.find(tree, "#provider-profile-edit-form")) == 1
      assert length(Floki.find(tree, "article")) == 1

      assert attr(
               one(tree, ~s(button[phx-click="edit_provider_profile"])),
               "phx-value-profile_id"
             ) == ["new"]
    end
  end

  defp profile(overrides \\ %{}) do
    Map.merge(
      %{
        "id" => "account-a",
        "name" => "Research account",
        "provider" => "anthropic",
        "default_model" => "model-b",
        "reasoning_efforts" => ["high", "custom-fast", "low"],
        "default_reasoning_effort" => "low",
        "models" => [
          %{"model" => "model-a", "default_reasoning_effort" => "custom-fast"},
          %{"model" => "model-b"}
        ]
      },
      overrides
    )
  end

  defp edit(account \\ profile(), draft \\ nil, opts \\ []) do
    render_editor(
      Keyword.merge(
        [
          provider_profiles: [account],
          editing_profile_id: account["id"],
          profile_form_draft: draft
        ],
        opts
      )
    )
  end

  defp render_editor(opts) do
    render_component(&ProviderProfilesEditor.provider_profiles_editor/1, opts)
    |> Floki.parse_document!()
  end

  defp one(tree, selector) do
    assert [node] = Floki.find(tree, selector)
    node
  end

  # Floki's mochiweb parser leaves textarea RCDATA entities encoded; parse that
  # escaped text once to recover the browser's value, without trimming JSON.
  defp textarea_value(node), do: node |> Floki.text() |> Floki.parse_fragment!() |> Floki.text()

  defp attr(node, name), do: Floki.attribute(node, name)
  defp text(tree), do: tree |> Floki.text() |> String.replace(~r/\s+/, " ") |> String.trim()
  defp option_values(select), do: select |> Floki.find("option") |> Floki.attribute("value")
  defp selected(select), do: select |> Floki.find("option[selected]") |> Floki.attribute("value")

  defp assert_closed(tree, selector) do
    details = one(tree, selector)
    assert elem(details, 0) == "details"
    assert attr(details, "open") == []
    details
  end

  defp checkbox_values(tree, name),
    do: tree |> Floki.find(~s(input[type="checkbox"][name="#{name}"])) |> Floki.attribute("value")

  defp reasoning_advanced(tree) do
    assert [details] =
             tree
             |> Floki.find("details")
             |> Enum.filter(fn details ->
               text(hd(Floki.find(details, "summary"))) == "Advanced reasoning choices"
             end)

    details
  end

  defp assert_efforts(tree, name, expected) do
    inputs = Floki.find(tree, ~s(input[name="#{name}"]))
    assert [sentinel | choices] = inputs
    assert attr(sentinel, "type") == ["hidden"]
    assert attr(sentinel, "value") == [""]
    assert Enum.all?(choices, &(attr(&1, "type") == ["checkbox"]))
    assert inputs |> Floki.filter_out(":not([checked])") |> Floki.attribute("value") == expected
    assert Floki.find(tree, ~s(input[type="hidden"][name="#{name}"])) == [sentinel]
    assert Enum.all?(inputs, &(attr(&1, "disabled") == []))
  end
end
