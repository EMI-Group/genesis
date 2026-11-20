defmodule EvoDashWeb.ProviderProfileFieldsTest do
  @moduledoc """
  Isolated canonical form-field contracts: browser list order, blank sentinels,
  schedule indexing, request parameter fidelity and node-supplied OAuth verdicts.
  """
  use ExUnit.Case, async: true

  import Phoenix.LiveViewTest

  alias EvoDashWeb.SettingsComponents.ProviderProfileFields, as: Fields

  # The dashboard's canonical reasoning LEVELS in core order. `max` is only a
  # provider wire alias of `xhigh`, never a dashboard level.
  @canonical ~w(none minimal low medium high xhigh)

  describe "exact catalog reasoning suggestions" do
    test "uses explicit effort metadata only for the exact provider and model identity" do
      assert Fields.reasoning_suggestions(%{
               "provider" => "anthropic",
               "default_model" => "claude-opus-4-5-20251101"
             }) == ["low", "medium", "high"]

      # The alias resolves to the dated entry, but is not that exact catalog id.
      for {provider, model} <- [
            {"anthropic", "claude-opus-4-5"},
            {"openai", "claude-opus-4-5-20251101"},
            {"openai_codex", "claude-opus-4-5-20251101"},
            {"private_gateway", "claude-opus-4-5-20251101"},
            {"anthropic", "unknown-model"},
            {"openai", "gpt-5"}
          ] do
        assert Fields.reasoning_suggestions(%{"provider" => provider, "default_model" => model}) ==
                 []
      end
    end

    test "shared suggestions intersect every default and nested model, while overrides use their own model" do
      profile = %{
        "provider" => "anthropic",
        "default_model" => "claude-opus-4-6",
        "models" => %{"4" => %{"model" => "claude-opus-4-5-20251101"}}
      }

      assert Fields.reasoning_suggestions(profile) == ["low", "medium", "high"]

      assert Fields.reasoning_suggestions(profile, "claude-opus-4-6") == [
               "low",
               "medium",
               "high",
               "max"
             ]

      unknown = Map.put(profile, "models", [%{"model" => "unknown-model"}])
      assert Fields.reasoning_suggestions(unknown) == []

      assert Fields.reasoning_suggestions(unknown, "claude-opus-4-6") == [
               "low",
               "medium",
               "high",
               "max"
             ]

      assert Fields.reasoning_suggestions(Map.put(profile, "default_model", "unknown-default")) ==
               []

      assert Fields.reasoning_suggestions(%{"provider" => "anthropic", "models" => []}) == []
    end

    test "custom endpoints never borrow the named provider model's catalog efforts" do
      profile = %{
        "provider" => "anthropic",
        "default_model" => "claude-opus-4-5-20251101",
        "base_url" => "https://private.example/v1"
      }

      assert Fields.reasoning_suggestions(profile) == []
      assert Fields.reasoning_suggestions(profile, "claude-opus-4-5-20251101") == []
    end
  end

  describe "reasoning checkbox serialization" do
    test "ONE canonical chip list: canonical order, then configured extras once at the END" do
      tree =
        render_component(&Fields.reasoning_fields/1,
          prefix: "",
          fields: %{
            "reasoning_efforts" => [" high ", "custom-level", "low", "high", "", nil, "max"]
          }
        )
        |> parse()

      # "max" is only a provider WIRE alias of "xhigh" and never a dashboard
      # level, so a persisted "max" renders as the xhigh chip exactly once.
      assert checkbox_values(tree, "reasoning_efforts[]") == @canonical ++ ["custom-level"]
      assert length(Floki.find(tree, ~s(input[type="checkbox"][value="xhigh"]))) == 1
      assert Floki.find(tree, ~s(input[value="max"])) == []

      # Checked state follows the draft inventory, in chip order — a persisted
      # "max" checks the canonical "xhigh" chip.
      assert checked_values(tree, "reasoning_efforts[]") == [
               "low",
               "high",
               "xhigh",
               "custom-level"
             ]

      # Every chip carries its own stable, prefix-scoped DOM id.
      assert chip_ids(tree, "reasoning_efforts[]") ==
               Enum.map(@canonical ++ ["custom-level"], &"reasoning-#{&1}")
    end

    test "the hidden blank seed stays the FIRST input so an explicit empty list submits" do
      tree =
        render_component(&Fields.reasoning_fields/1,
          prefix: "",
          fields: %{"reasoning_efforts" => ["high"]}
        )
        |> parse()

      [first | _rest] = Floki.find(tree, ~s(input[name="reasoning_efforts[]"]))
      assert attr(first, "type") == ["hidden"]
      assert attr(first, "value") == [""]
    end

    test "chip ids and order are byte-identical whether or not the draft selects a level" do
      # The morphdom stability pin: the previously clicked level keeps its node
      # identity across a phx-change repaint, so a flipped checkbox is never
      # rewritten to a different level by positional patching.
      empty =
        render_component(&Fields.reasoning_fields/1, prefix: "models[2]", fields: %{})
        |> parse()

      selected =
        render_component(&Fields.reasoning_fields/1,
          prefix: "models[2]",
          fields: %{"reasoning_efforts" => ["xhigh"]}
        )
        |> parse()

      name = "models[2][reasoning_efforts][]"

      assert chip_ids(empty, name) == chip_ids(selected, name)
      assert chip_ids(selected, name) == Enum.map(@canonical, &"reasoning-models-2-#{&1}")
      assert checked_values(empty, name) == []
      assert checked_values(selected, name) == ["xhigh"]
    end

    test "per-model rows keep distinct, unique chip ids" do
      htmls = [
        render_component(&Fields.reasoning_fields/1, prefix: "", fields: %{}),
        render_component(&Fields.reasoning_fields/1, prefix: "models[0]", fields: %{}),
        render_component(&Fields.reasoning_fields/1, prefix: "models[1]", fields: %{})
      ]

      ids =
        Enum.flat_map(htmls, fn html ->
          html
          |> parse()
          |> Floki.find(~s(input[type="checkbox"]))
          |> Floki.attribute("id")
        end)

      assert length(ids) == 18
      assert ids == Enum.uniq(ids)
      assert Enum.take(ids, 6) == Enum.map(@canonical, &"reasoning-#{&1}")
      assert Enum.slice(ids, 6, 6) == Enum.map(@canonical, &"reasoning-models-0-#{&1}")
      assert Enum.slice(ids, 12, 6) == Enum.map(@canonical, &"reasoning-models-1-#{&1}")
    end

    test "catalog suggestions are advisory: no membership, order or selection change" do
      tree =
        render_component(&Fields.reasoning_fields/1,
          prefix: "",
          fields: %{},
          suggestions: [" low ", "medium", "max", "low", "", nil]
        )
        |> parse()

      assert checkbox_values(tree, "reasoning_efforts[]") == @canonical
      assert checked_values(tree, "reasoning_efforts[]") == []
      assert Floki.find(tree, ~s(input[value="max"])) == []
      assert text(tree) =~ "Catalog suggestions are advisory"
      assert text(tree) =~ "Low, Medium, Extra high"
      assert Floki.find(tree, ~s(select[name="default_reasoning_effort"])) == []
    end

    test "a fully configured canonical vocabulary selects every canonical chip exactly once" do
      tree =
        render_component(&Fields.reasoning_fields/1,
          prefix: "",
          fields: %{"reasoning_efforts" => @canonical ++ ["max", "xhigh"]}
        )
        |> parse()

      assert checked_values(tree, "reasoning_efforts[]") == @canonical
      assert length(Floki.find(tree, ~s(input[type="checkbox"]))) == 6
      assert Floki.find(tree, "details") == []
    end

    test "nested empty overrides still submit a blank list sentinel, not a missing field" do
      tree =
        render_component(&Fields.reasoning_fields/1,
          prefix: "models[12]",
          fields: %{"reasoning_efforts" => []},
          model_override: true
        )
        |> parse()

      name = "models[12][reasoning_efforts][]"
      assert attr(one(tree, ~s(input[type="hidden"][name="#{name}"])), "value") == [""]
      assert checked_values(tree, name) == []
      assert length(Floki.find(tree, ~s(input[type="checkbox"][name="#{name}"]))) == 6
      assert text(tree) =~ "No levels selected explicitly disables reasoning for this model."

      # No configured inventory means no level to default to, so no select is
      # rendered at all rather than an empty one.
      assert Floki.find(tree, ~s(select[name="models[12][default_reasoning_effort]"])) == []
    end

    test "account inventory can hide its duplicate default control without hiding the sentinel" do
      tree =
        render_component(&Fields.reasoning_fields/1,
          prefix: "",
          fields: %{"reasoning_efforts" => "custom, high, low, custom"},
          show_default: false
        )
        |> parse()

      assert checked_values(tree, "reasoning_efforts[]") == ["low", "high", "custom"]
      assert length(Floki.find(tree, ~s(input[type="hidden"][name="reasoning_efforts[]"]))) == 1
      assert Floki.find(tree, "select") == []
      # A custom value is appended BELOW the complete canonical ladder.
      assert length(Floki.find(tree, ~s(input[type="checkbox"]))) == 7
    end

    test "the default select offers exactly the inventory levels plus one blank" do
      tree =
        render_component(&Fields.reasoning_fields/1,
          prefix: "models[1]",
          fields: %{
            "reasoning_efforts" => ["high", "custom-level", "max"],
            "default_reasoning_effort" => "high"
          }
        )
        |> parse()

      select = one(tree, ~s(select[name="models[1][default_reasoning_effort]"]))
      assert option_values(select) == ["", "high", "custom-level", "xhigh"]
      refute "max" in option_values(select)
      assert selected(select) == ["high"]

      assert Enum.map(Floki.find(select, "option"), &text/1) == [
               "Provider default",
               "High",
               "custom-level",
               "Extra high"
             ]
    end

    test "an empty inventory renders no default control and no blank default option" do
      tree = render_component(&Fields.reasoning_fields/1, prefix: "", fields: %{}) |> parse()

      assert Floki.find(tree, "select") == []
      assert text(tree) =~ "No verified catalog level list is available"
    end

    test "unsupported saved default is visible and invalid rather than silently replaced" do
      tree =
        render_component(&Fields.reasoning_default/1,
          prefix: "models[3]",
          fields: %{"default_reasoning_effort" => "retired"},
          efforts: ["high", "low"],
          inherit: true
        )
        |> parse()

      select = one(tree, ~s(select[name="models[3][default_reasoning_effort]"]))
      assert selected(select) == ["retired"]
      assert option_values(select) == ["", "retired", "high", "low"]
      assert attr(select, "aria-invalid") == ["true"]
      assert text(one(select, ~s(option[value="retired"]))) == "Unsupported level: retired"
      assert text(one(select, ~s(option[value=""]))) == "Inherit provider default"
      [help_id] = attr(select, "aria-describedby")
      assert text(one(tree, "##{help_id}")) =~ "separate from task speed and quality"
    end
  end

  describe "closed schedule fidelity" do
    test "zero peak concurrency, overnight bounds and indexed day selections are retained" do
      tree =
        schedule(%{
          "peak_concurrency" => 0,
          "timezone" => "Asia/Hong_Kong",
          "off_peak_days" => ["sat", "sun"],
          "peak_hours" => %{
            "10" => %{"start" => "23:00", "end" => "03:00", "days" => ["weekends"]},
            "2" => %{"start" => "09:30", "end" => "17:45", "days" => ["mon", "fri"]}
          }
        })

      details = one(tree, "#provider-peak-schedule")
      assert attr(details, "open") == []
      assert attr(one(tree, ~s(input[name="peak_concurrency"])), "value") == ["0"]
      assert attr(one(tree, ~s(input[name="timezone"])), "value") == ["Asia/Hong_Kong"]
      assert checked_values(tree, "off_peak_days[]") == ["sat", "sun"]
      assert checked_values(tree, "peak_hours[2][days][]") == ["mon", "fri"]
      assert checked_values(tree, "peak_hours[10][days][]") == ["weekends"]

      assert Enum.map(Floki.find(tree, ~s(input[type="time"])), &attr(&1, "name")) == [
               ["peak_hours[2][start]"],
               ["peak_hours[2][end]"],
               ["peak_hours[10][start]"],
               ["peak_hours[10][end]"]
             ]

      assert attr(one(tree, ~s(input[name="peak_hours[10][start]"])), "value") == ["23:00"]
      assert attr(one(tree, ~s(input[name="peak_hours[10][end]"])), "value") == ["03:00"]

      for name <- ["off_peak_days[]", "peak_hours[2][days][]", "peak_hours[10][days][]"] do
        assert attr(one(tree, ~s(input[type="hidden"][name="#{name}"])), "value") == [""]
        assert length(Floki.find(tree, ~s(input[type="checkbox"][name="#{name}"]))) == 9
      end

      assert Enum.map(
               Floki.find(tree, ~s(button[phx-click="remove_provider_peak_hours_row"])),
               &attr(&1, "phx-value-index")
             ) == [["2"], ["10"]]

      assert attr(one(tree, ~s(button[phx-click="add_provider_peak_hours_row"])), "type") == [
               "button"
             ]
    end

    test "empty schedule gives one blank window with explicit clear-day sentinels" do
      tree = schedule(%{"peak_hours" => [], "off_peak_days" => []})
      assert attr(one(tree, ~s(input[name="peak_hours[0][start]"])), "value") == [""]
      assert attr(one(tree, ~s(input[name="peak_hours[0][end]"])), "value") == [""]
      assert checked_values(tree, "off_peak_days[]") == []
      assert checked_values(tree, "peak_hours[0][days][]") == []

      assert attr(one(tree, ~s(input[type="hidden"][name="peak_hours[0][days][]"])), "value") == [
               ""
             ]

      assert text(tree) =~ "No days selected means every day."
    end
  end

  describe "generation field fidelity" do
    test "numeric control types and bounds remain intact inside either namespace" do
      for prefix <- ["generation", "models[4][generation]"] do
        tree =
          render_component(&Fields.generation_fields/1, prefix: prefix, fields: %{}) |> parse()

        for {key, step, min, max} <- [
              {"temperature", "0.01", "0", "2"},
              {"max_tokens", "1", "1", nil},
              {"top_p", "0.01", "0", "1"},
              {"top_k", "1", "1", nil},
              {"frequency_penalty", "0.01", "-2", "2"},
              {"presence_penalty", "0.01", "-2", "2"}
            ] do
          input = one(tree, ~s(input[name="#{prefix}[#{key}]"]))
          assert attr(input, "type") == ["number"]
          assert attr(input, "step") == [step]
          assert attr(input, "min") == [min]
          assert attr(input, "max") == if(max, do: [max], else: [])
          assert attr(input, "value") == [""]
        end
      end
    end

    test "invalid draft JSON remains editable verbatim instead of being erased or encoded twice" do
      draft = ~s({"custom": "<script>", broken)

      tree =
        render_component(&Fields.generation_fields/1,
          prefix: "models[4][generation]",
          fields: %{"provider_options" => draft, "extra" => ""}
        )
        |> parse()

      textarea = one(tree, ~s(textarea[name="models[4][generation][provider_options]"]))
      assert textarea_value(textarea) == draft
      assert Floki.text(one(tree, ~s(textarea[name="models[4][generation][extra]"]))) == ""
      assert Floki.find(tree, "script") == []
    end
  end

  describe "node-supplied OAuth credential status" do
    test "each verdict has distinct guidance and no guessed local managed path" do
      for {state, label} <- [
            {:ok, "Login detected"},
            {:missing, "No subscription login found"},
            {:unwritable, "Login found, managed credential file not writable"},
            {:unknown, "Subscription login"}
          ] do
        tree =
          auth(%{
            state: state,
            login_instructions: "NODE-LOGIN-MARKER",
            oauth_file: "/remote/managed.json"
          })

        assert text(tree) =~ label
        assert text(tree) =~ "Managed credential file: /remote/managed.json"
        button = one(tree, ~s(button[phx-click="refresh_auth_status"]))
        assert attr(button, "phx-value-profile_id") == ["subscription-a"]
        assert attr(button, "type") == ["button"]
        assert attr(button, "aria-label") == ["Recheck subscription login"]

        if state == :unwritable do
          assert text(tree) =~
                   "Set oauth_file on this profile to a writable location, then recheck."

          refute text(tree) =~ "NODE-LOGIN-MARKER"
          refute text(tree) =~ "Genesis imports the vendor login automatically"
        else
          assert text(tree) =~ "NODE-LOGIN-MARKER"
          refute text(tree) =~ "Set oauth_file on this profile"
        end

        assert text(tree) =~ "Genesis imports the vendor login automatically" ==
                 (state == :missing)

        assert Floki.find(tree, ".hero-check-circle") != [] == (state == :ok)
      end
    end

    test "string-keyed status and configured path fallback render without local credential lookup" do
      tree =
        auth(%{"state" => "unwritable"},
          profile: oauth_profile(%{"oauth_file" => "~/remote/login.json"})
        )

      assert text(tree) =~ "Login found, managed credential file not writable"
      assert text(tree) =~ "Managed credential file: ~/remote/login.json"
    end

    test "missing or malformed status is neutral, not a missing-login verdict" do
      for status <- [nil, :unavailable, %{}, %{"state" => "unexpected"}] do
        tree = auth(status)
        assert text(tree) =~ "Subscription login"
        assert text(tree) =~ "Run claude to sign in on the selected node"
        refute text(tree) =~ "No subscription login found"
        refute text(tree) =~ "Login detected"
        refute text(tree) =~ "Managed credential file:"
      end
    end

    test "summary status hides path and instructions while retaining verdict and refresh control" do
      tree =
        auth(
          %{
            state: :missing,
            login_instructions: "DETAIL-MARKER",
            oauth_file: "/remote/hidden.json"
          },
          details: false
        )

      assert text(tree) =~ "No subscription login found"
      assert length(Floki.find(tree, ~s(button[phx-click="refresh_auth_status"]))) == 1
      refute text(tree) =~ "DETAIL-MARKER"
      refute text(tree) =~ "/remote/hidden.json"
      refute text(tree) =~ "Genesis imports the vendor login automatically"
    end
  end

  describe "ChatGPT sign-in inside the auth status" do
    test "a non-connected ChatGPT account renders the shared panel instead of CLI prose" do
      tree =
        auth(%{state: :missing, login_instructions: "NODE-LOGIN-MARKER"},
          profile: chatgpt_profile()
        )

      button = one(tree, "#provider-status-codex-main-chatgpt-sign-in")
      assert attr(button, "type") == ["button"]
      assert attr(button, "phx-click") == ["chatgpt_sign_in"]
      assert attr(button, "phx-value-surface") == ["status"]
      assert attr(button, "phx-value-profile_id") == ["codex-main"]

      # The old primary CLI instruction paragraph is gone from this branch.
      refute text(tree) =~ "NODE-LOGIN-MARKER"
      refute text(tree) =~ "genesis chatgpt login"
      refute text(tree) =~ "Sign in with the provider's CLI on the selected node"

      # The verdict row itself is unchanged.
      assert text(tree) =~ "No subscription login found"

      assert length(Floki.find(tree, ~s(button[phx-click="refresh_auth_status"]))) == 1
    end

    test "the status surface renders its own flow and ignores another surface's" do
      waiting =
        auth(%{state: :missing},
          profile: chatgpt_profile(),
          chatgpt_sign_in: %{
            surface: {:status, "codex-main"},
            flow_id: "f1",
            phase: :waiting,
            url: "https://example.test/authorize"
          }
        )

      link = one(waiting, "#provider-status-codex-main-chatgpt-sign-in-url")
      assert attr(link, "href") == ["https://example.test/authorize"]
      assert attr(link, "target") == ["_blank"]
      assert attr(link, "rel") == ["noopener noreferrer"]

      assert text(one(waiting, "#provider-status-codex-main-chatgpt-waiting p[role=\"status\"]")) ==
               "Waiting for authorization…"

      assert attr(
               one(waiting, "#provider-status-codex-main-chatgpt-sign-in-cancel"),
               "phx-value-profile_id"
             ) == ["codex-main"]

      assert Floki.find(waiting, "#provider-status-codex-main-chatgpt-sign-in") == []

      for foreign <- [
            %{surface: {:detail, "codex-main"}, phase: :waiting, url: "https://example.test/a"},
            %{surface: {:status, "another-account"}, phase: :waiting},
            %{surface: :wizard, phase: :waiting, url: "https://example.test/a"}
          ] do
        idle = auth(%{state: :missing}, profile: chatgpt_profile(), chatgpt_sign_in: foreign)

        assert Floki.find(idle, "#provider-status-codex-main-chatgpt-sign-in") != []
        assert Floki.find(idle, "#provider-status-codex-main-chatgpt-waiting") == []
        assert Floki.find(idle, "a[href]") == []
      end
    end

    test "manual mode renders the account-specific CLI command and no button" do
      tree =
        auth(%{state: :missing},
          profile: chatgpt_profile(),
          chatgpt_sign_in_manual: true,
          chatgpt_sign_in: %{surface: {:status, "codex-main"}, phase: :waiting}
        )

      hint = one(tree, "#provider-status-codex-main-chatgpt-manual-hint")
      assert text(hint) =~ "genesis chatgpt login --account work"
      assert text(hint) =~ "same machine as the execution node"

      assert Floki.find(tree, "#provider-status-codex-main-chatgpt-sign-in") == []
      assert Floki.find(tree, "#provider-status-codex-main-chatgpt-waiting") == []

      # A profile without a usable account name shows the plain command.
      plain =
        auth(%{state: :missing},
          profile: chatgpt_profile(%{"siwc_account" => ""}),
          chatgpt_sign_in_manual: true
        )

      assert text(one(plain, "#provider-status-codex-main-chatgpt-manual-hint")) =~
               "genesis chatgpt login"
    end

    test "the collapsed summary row stays compact: no panel, Recheck retained" do
      tree =
        auth(%{state: :missing, login_instructions: "DETAIL-MARKER"},
          profile: chatgpt_profile(),
          details: false,
          chatgpt_sign_in: %{surface: {:status, "codex-main"}, phase: :waiting}
        )

      assert Floki.find(tree, "#provider-status-codex-main-chatgpt-sign-in") == []
      assert Floki.find(tree, "#provider-status-codex-main-chatgpt-waiting") == []
      assert Floki.find(tree, "#provider-status-codex-main-chatgpt-manual-hint") == []

      assert text(tree) =~ "No subscription login found"
      assert length(Floki.find(tree, ~s(button[phx-click="refresh_auth_status"]))) == 1
      refute text(tree) =~ "DETAIL-MARKER"
    end

    test "a connected ChatGPT account keeps its account id line and renders no panel" do
      tree =
        auth(%{state: :ok, account_id: "work@example.test"},
          profile: chatgpt_profile(),
          chatgpt_sign_in: %{surface: {:status, "codex-main"}, phase: :waiting}
        )

      assert text(tree) =~ "Login detected"
      assert text(tree) =~ "work@example.test"
      assert Floki.find(tree, "#provider-status-codex-main-chatgpt-sign-in") == []
      assert Floki.find(tree, "#provider-status-codex-main-chatgpt-waiting") == []
      refute text(tree) =~ "genesis chatgpt login"
    end

    test "non-ChatGPT providers keep the node-owned instructions" do
      tree =
        auth(%{state: :missing, login_instructions: "NODE-LOGIN-MARKER"},
          chatgpt_sign_in: %{surface: {:status, "subscription-a"}, phase: :waiting}
        )

      assert text(tree) =~ "NODE-LOGIN-MARKER"
      assert Floki.find(tree, "#provider-status-subscription-a-chatgpt-sign-in") == []
      assert Floki.find(tree, "#provider-status-subscription-a-chatgpt-waiting") == []
    end
  end

  defp schedule(fields),
    do: render_component(&Fields.provider_schedule/1, fields: fields) |> parse()

  defp oauth_profile(overrides \\ %{}),
    do:
      Map.merge(
        %{"id" => "subscription-a", "provider" => "anthropic", "auth_mode" => "oauth"},
        overrides
      )

  defp chatgpt_profile(overrides \\ %{}),
    do:
      Map.merge(
        %{
          "id" => "codex-main",
          "provider" => "openai_codex",
          "auth_mode" => "oauth",
          "siwc_account" => "work",
          "default_model" => "gpt-5-codex",
          "models" => [%{"model" => "gpt-5-codex"}]
        },
        overrides
      )

  defp auth(status, opts \\ []) do
    render_component(
      &Fields.provider_auth_status/1,
      Keyword.merge([profile: oauth_profile(), status: status], opts)
    )
    |> parse()
  end

  # Floki's mochiweb parser leaves textarea RCDATA entities encoded; parse that
  # escaped text once to recover the browser's value, without trimming drafts.
  defp textarea_value(node), do: node |> Floki.text() |> Floki.parse_fragment!() |> Floki.text()

  defp parse(html), do: Floki.parse_document!(html)
  defp attr(node, name), do: Floki.attribute(node, name)

  defp one(tree, selector) do
    assert [node] = Floki.find(tree, selector)
    node
  end

  defp text(tree), do: tree |> Floki.text() |> String.replace(~r/\s+/, " ") |> String.trim()
  defp option_values(select), do: select |> Floki.find("option") |> Floki.attribute("value")
  defp selected(select), do: select |> Floki.find("option[selected]") |> Floki.attribute("value")

  defp chip_ids(tree, name),
    do:
      tree
      |> Floki.find(~s(input[type="checkbox"][name="#{name}"]))
      |> Floki.attribute("id")

  defp checkbox_values(tree, name),
    do: tree |> Floki.find(~s(input[type="checkbox"][name="#{name}"])) |> Floki.attribute("value")

  defp checked_values(tree, name),
    do:
      tree
      |> Floki.find(~s(input[type="checkbox"][name="#{name}"][checked]))
      |> Floki.attribute("value")
end
