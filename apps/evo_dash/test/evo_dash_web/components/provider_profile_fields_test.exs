defmodule EvoDashWeb.ProviderProfileFieldsTest do
  @moduledoc """
  Isolated canonical form-field contracts: browser list order, blank sentinels,
  schedule indexing, request parameter fidelity and node-supplied OAuth verdicts.
  """
  use ExUnit.Case, async: true

  import Phoenix.LiveViewTest

  alias EvoDashWeb.SettingsComponents.ProviderProfileFields, as: Fields

  describe "reasoning checkbox serialization" do
    test "configured custom levels precede unchecked vocabulary in their original order" do
      tree =
        render_component(&Fields.reasoning_fields/1,
          prefix: "",
          fields: %{"reasoning_efforts" => [" high ", "vendor-custom", "low", "high", "", nil]}
        )
        |> parse()

      inputs = Floki.find(tree, ~s(input[name="reasoning_efforts[]"]))

      assert Enum.map(inputs, &attr(&1, "value")) ==
               Enum.map(
                 [
                   "",
                   "high",
                   "vendor-custom",
                   "low",
                   "none",
                   "minimal",
                   "medium",
                   "xhigh",
                   "max",
                   "default"
                 ],
                 &[&1]
               )

      assert checked_values(tree, "reasoning_efforts[]") == ["high", "vendor-custom", "low"]
      assert attr(hd(inputs), "type") == ["hidden"]
      assert selected(one(tree, ~s(select[name="default_reasoning_effort"]))) == [""]

      assert option_values(one(tree, ~s(select[name="default_reasoning_effort"]))) == [
               "",
               "high",
               "vendor-custom",
               "low"
             ]
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
      assert length(Floki.find(tree, ~s(input[type="checkbox"][name="#{name}"]))) == 8
      assert text(tree) =~ "No levels selected explicitly disables reasoning for this model."
      assert selected(one(tree, ~s(select[name="models[12][default_reasoning_effort]"]))) == [""]
    end

    test "account inventory can hide its duplicate default control without hiding the sentinel" do
      tree =
        render_component(&Fields.reasoning_fields/1,
          prefix: "",
          fields: %{"reasoning_efforts" => "custom, high, low, custom"},
          show_default: false
        )
        |> parse()

      assert checked_values(tree, "reasoning_efforts[]") == ["custom", "high", "low"]
      assert length(Floki.find(tree, ~s(input[type="hidden"][name="reasoning_efforts[]"]))) == 1
      assert Floki.find(tree, "select") == []
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

  defp schedule(fields),
    do: render_component(&Fields.provider_schedule/1, fields: fields) |> parse()

  defp oauth_profile(overrides \\ %{}),
    do:
      Map.merge(
        %{"id" => "subscription-a", "provider" => "anthropic", "auth_mode" => "oauth"},
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

  defp checked_values(tree, name),
    do:
      tree
      |> Floki.find(~s(input[type="checkbox"][name="#{name}"][checked]))
      |> Floki.attribute("value")
end
