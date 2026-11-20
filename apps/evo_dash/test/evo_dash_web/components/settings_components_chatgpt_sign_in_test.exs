defmodule EvoDashWeb.SettingsComponentsChatGPTSignInTest do
  @moduledoc """
  The `/settings` LLM category threads the page-owned Sign in with ChatGPT
  state from `category_section/1` down to the ONE expanded account's detail
  panel: the two new attrs are TOTAL (the page renders before, or entirely
  without, the live side's assigns) and a surface never renders another
  account's flow.
  """

  use ExUnit.Case, async: true

  import Phoenix.LiveViewTest

  alias EvoDashWeb.SettingsComponents

  describe "category_section/1 — ChatGPT sign-in threading" do
    test "renders without the two ChatGPT sign-in attrs and shows the idle button" do
      tree = category([codex_account()], editing: "codex-main")

      form = one(tree, "#provider-profile-detail-codex-main")
      button = one(form, "#provider-detail-codex-main-chatgpt-sign-in")

      assert attr(button, "type") == "button"
      assert attr(button, "phx-value-surface") == "detail"
      assert attr(button, "phx-value-profile_id") == "codex-main"

      assert Floki.find(tree, "#provider-detail-codex-main-chatgpt-waiting") == []
      assert Floki.find(tree, "#provider-detail-codex-main-chatgpt-manual-hint") == []
    end

    test "a page-level flow reaches the right account's detail panel only" do
      tree =
        category([codex_account(), alt_codex_account()],
          editing: "codex-main",
          chatgpt_sign_in: %{
            surface: {:detail, "codex-main"},
            flow_id: "f1",
            phase: :waiting,
            url: "https://example.test/authorize"
          }
        )

      detail = one(tree, "#provider-profile-detail-codex-main")
      link = one(detail, "#provider-detail-codex-main-chatgpt-sign-in-url")
      assert attr(link, "href") == "https://example.test/authorize"

      assert text(one(detail, "#provider-detail-codex-main-chatgpt-waiting p[role=\"status\"]")) ==
               "Waiting for authorization…"

      assert Floki.find(detail, "#provider-detail-codex-main-chatgpt-sign-in") == []

      # The sibling account never renders that flow: its collapsed row stays
      # compact (verdict + Recheck, no sign-in surface, no waiting block).
      assert Floki.find(tree, "#provider-status-codex-alt-chatgpt-sign-in") == []
      assert Floki.find(tree, "#provider-status-codex-alt-chatgpt-waiting") == []

      sibling_row = one(tree, "#provider-profile-codex-alt")

      assert length(Floki.find(sibling_row, ~s(button[phx-click="refresh_auth_status"]))) == 1

      assert Floki.find(tree, "#provider-detail-codex-main-chatgpt-sign-in-url") != []
      assert length(Floki.find(tree, "[id$='-chatgpt-waiting']")) == 1
    end

    test "the manual verdict reaches the expanded account's detail panel" do
      tree = category([codex_account()], editing: "codex-main", chatgpt_sign_in_manual: true)

      hint = one(tree, "#provider-detail-codex-main-chatgpt-manual-hint")
      assert text(hint) =~ "genesis chatgpt login"

      assert Floki.find(tree, "#provider-detail-codex-main-chatgpt-sign-in") == []
      assert Floki.find(tree, "#provider-detail-codex-main-chatgpt-waiting") == []
    end

    test "a non-ChatGPT account in the same category renders no ChatGPT surface" do
      tree = category([codex_account(), anthropic_account()], editing: "codex-main")

      assert Floki.find(tree, "#provider-profile-detail-codex-main") != []
      assert Floki.find(tree, "#provider-profile-subscription-a") != []
      assert Floki.find(tree, "#provider-status-subscription-a-chatgpt-sign-in") == []
      assert Floki.find(tree, "#provider-detail-subscription-a-chatgpt-sign-in") == []
    end
  end

  # ═══════════════════════════════════════════════════════════════════════════
  # helpers
  # ═══════════════════════════════════════════════════════════════════════════

  defp category(profiles, opts) do
    render_component(
      &SettingsComponents.category_section/1,
      [
        category: :llm,
        schemas: [],
        file_config: %{},
        provider_profiles: profiles,
        editing_profile_id: Keyword.fetch!(opts, :editing)
      ] ++ Keyword.delete(opts, :editing)
    )
    |> Floki.parse_document!()
  end

  defp codex_account(overrides \\ %{}) do
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
  end

  defp alt_codex_account do
    codex_account(%{
      "id" => "codex-alt",
      "siwc_account" => "home",
      "default_model" => "gpt-5",
      "models" => [%{"model" => "gpt-5"}]
    })
  end

  defp anthropic_account do
    %{
      "id" => "subscription-a",
      "provider" => "anthropic",
      "auth_mode" => "oauth",
      "default_model" => "claude-opus-4-5-20251101",
      "models" => [%{"model" => "claude-opus-4-5-20251101"}]
    }
  end

  defp one(tree, selector) do
    assert [node] = Floki.find(List.wrap(tree), selector)
    node
  end

  defp attr(node, name) do
    assert [value] = Floki.attribute(node, name)
    value
  end

  defp text(node), do: node |> Floki.text() |> String.replace(~r/\s+/, " ") |> String.trim()
end
