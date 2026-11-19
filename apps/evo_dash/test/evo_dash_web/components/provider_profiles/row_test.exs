defmodule EvoDashWeb.SettingsComponents.ProviderProfiles.RowTest do
  @moduledoc """
  One account row of the `/settings` provider-account list: provider-derived
  identity, model chips, slot/schedule/auth summaries and the row actions.
  The pure `schedule_badge/1`, `model_chips/1`, `profile_id/1` and `slug/1`
  derivations are pinned here so a row can never present a MODEL as the account.
  """
  use ExUnit.Case, async: true
  import Phoenix.LiveViewTest
  alias EvoDashWeb.SettingsComponents.ProviderProfiles.Row

  describe "schedule_badge/1" do
    test "reports peak capacity plus the off-peak holiday calendar" do
      assert Row.schedule_badge(account()) == "Peak 2/4 · CN holidays"
    end

    test "reports peak capacity alone when no holiday calendar is configured" do
      assert Row.schedule_badge(account(%{"off_peak_holidays" => ""})) == "Peak 2/4"
      assert Row.schedule_badge(account(%{"off_peak_holidays" => nil})) == "Peak 2/4"
    end

    test "reports no schedule when no peak capacity is configured" do
      assert Row.schedule_badge(account(%{"peak_concurrency" => "", "off_peak_holidays" => "CN"})) ==
               "No schedule"

      assert Row.schedule_badge(%{}) == "No schedule"
    end

    test "falls back to the default slot count when concurrency is absent" do
      assert Row.schedule_badge(%{"peak_concurrency" => "2"}) == "Peak 2/3"
    end
  end

  describe "model_chips/1 and identity helpers" do
    test "puts the default model first and deduplicates the inventory" do
      chips =
        Row.model_chips(
          account(%{
            "default_model" => "deepseek-chat",
            "models" => [
              %{"model" => "deepseek-reasoner"},
              %{"model" => "deepseek-chat"}
            ]
          })
        )

      assert chips == [
               %{model: "deepseek-chat", default?: true},
               %{model: "deepseek-reasoner", default?: false}
             ]
    end

    test "handles atom-keyed and indexed model maps" do
      assert Row.model_chips(%{"default_model" => "m1", "models" => [%{"model" => "m2"}]}) == [
               %{model: "m1", default?: true},
               %{model: "m2", default?: false}
             ]

      assert Row.model_chips(%{}) == []
    end

    test "the account id is never one of its models, and slugs are URL-safe" do
      profile = account()
      assert Row.profile_id(profile) == "deepseek-main"
      refute Row.profile_id(profile) in Enum.map(Row.model_chips(profile), & &1.model)
      assert Row.profile_id(%{"id" => "   "}) == nil
      assert Row.profile_id(%{}) == nil
      assert Row.slug("DeepSeek Main") == "deepseek-main"
      assert Row.slug("  ") == "account"
      assert Row.slug(nil) == "account"
    end
  end

  describe "profile_row/1" do
    test "renders the provider-derived account identity, chips, slots and badges" do
      tree = render_row(account(), default?: true)

      row = one(tree, "#provider-profile-deepseek-main")
      assert attr(row, "data-expanded") == ["false"]

      # Two affordances expand the row: the row body itself and the Edit action.
      assert [trigger, edit] = Floki.find(tree, ~s(button[phx-click="edit_provider_profile"]))
      assert attr(trigger, "phx-value-profile_id") == ["deepseek-main"]
      assert attr(trigger, "aria-expanded") == ["false"]
      assert attr(edit, "phx-value-profile_id") == ["deepseek-main"]

      rendered = text(tree)
      assert rendered =~ "DeepSeek"
      assert rendered =~ "DeepSeek main"
      assert rendered =~ "deepseek-main"
      assert rendered =~ "deepseek-chat"
      assert rendered =~ "4 slots"
      assert rendered =~ "Peak 2/4 · CN holidays"
      assert rendered =~ "API key"
      assert rendered =~ "Default"
    end

    test "a model string in the inventory never becomes the account heading" do
      profile =
        account(%{
          "name" => "",
          "models" => [%{"model" => "deepseek-reasoner"}],
          "default_model" => "deepseek-reasoner"
        })

      tree = render_row(profile)

      refute first_heading(tree) =~ "deepseek-reasoner"
      # The model only ever appears inside a model chip.
      chips = Floki.find(tree, ".badge.font-mono") |> Enum.map(&text/1)
      assert Enum.any?(chips, &(&1 =~ "deepseek-reasoner"))
    end

    test "offers the row actions and never a default action for the default account" do
      tree = render_row(account(), default?: true)

      assert [_] = Floki.find(tree, ~s(button[phx-click="start_add_provider_model"]))
      assert [_, _] = Floki.find(tree, ~s(button[phx-click="edit_provider_profile"]))
      assert Floki.find(tree, ~s(button[phx-click="set_default_provider_profile"])) == []

      delete = one(tree, ~s(button[phx-click="delete_provider_profile"]))
      assert attr(delete, "phx-value-profile_id") == ["deepseek-main"]
      assert attr(delete, "data-confirm") != []
    end

    test "a non-default account offers Make default" do
      tree = render_row(account(), default?: false)

      button = one(tree, ~s(button[phx-click="set_default_provider_profile"]))
      assert attr(button, "phx-value-profile_id") == ["deepseek-main"]
    end

    test "marks an expanded row and renders the OAuth variant for subscription accounts" do
      oauth =
        account(%{"id" => "codex-main", "provider" => "openai_codex", "auth_mode" => "oauth"})

      tree = render_row(oauth, expanded?: true, auth_status: %{"state" => "ok"})

      assert attr(one(tree, "#provider-profile-codex-main"), "data-expanded") == ["true"]
      assert text(tree) =~ "Subscription (OAuth)"
      assert [_] = Floki.find(tree, ~s(button[phx-click="refresh_auth_status"]))
    end
  end

  defp render_row(profile, opts \\ []) do
    render_component(&Row.profile_row/1, Keyword.merge([profile: profile], opts))
    |> Floki.parse_document!()
  end

  defp first_heading(tree) do
    tree
    |> Floki.find("span.truncate")
    |> List.first()
    |> text()
  end

  defp account(overrides \\ %{}) do
    Map.merge(
      %{
        "id" => "deepseek-main",
        "name" => "DeepSeek main",
        "provider" => "deepseek",
        "auth_mode" => "api_key",
        "concurrency" => "4",
        "peak_concurrency" => "2",
        "off_peak_holidays" => "CN",
        "default_model" => "deepseek-chat",
        "models" => [%{"model" => "deepseek-chat"}]
      },
      overrides
    )
  end

  defp one(tree, selector) do
    assert [node] = Floki.find(tree, selector)
    node
  end

  defp attr(node, name), do: Floki.attribute(node, name)

  defp text(tree), do: tree |> Floki.text() |> String.replace(~r/\s+/, " ") |> String.trim()
end
