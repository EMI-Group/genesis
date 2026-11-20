defmodule EvoDashWeb.SettingsComponents.ProviderProfiles.DetailChatGPTSignInTest do
  @moduledoc """
  The expanded provider-account form for a ChatGPT (`:openai_codex`) account:
  the shared Sign in with ChatGPT panel renders INSIDE the detail `<form>`,
  filtered to the `{:detail, profile_id}` surface, and its rewritten
  `siwc_account` help routes the user to the in-form sign-in instead of the
  terminal CLI.
  """

  use ExUnit.Case, async: true

  import Phoenix.LiveViewTest

  alias EvoDashWeb.SettingsComponents.ProviderProfiles.Detail

  @new_help "The ChatGPT account this profile uses. Sign in below to connect it on this node."
  @old_help "Use the account name you signed in with"

  describe "profile_detail/1 — ChatGPT sign-in surface" do
    test "renders the shared panel inside the detail form, filtered to {:detail, id}" do
      tree = detail(chatgpt_sign_in: waiting_state(surface: {:detail, "codex-main"}))

      form = one(tree, "#provider-profile-detail-codex-main")

      link = one(form, "#provider-detail-codex-main-chatgpt-sign-in-url")
      assert attr(link, "href") == "https://example.test/authorize"
      assert attr(link, "target") == "_blank"
      assert attr(link, "rel") == "noopener noreferrer"

      assert text(one(form, "#provider-detail-codex-main-chatgpt-waiting p[role=\"status\"]")) ==
               "Waiting for authorization…"

      cancel = one(form, "#provider-detail-codex-main-chatgpt-sign-in-cancel")
      assert attr(cancel, "type") == "button"
      assert attr(cancel, "phx-value-surface") == "detail"
      assert attr(cancel, "phx-value-profile_id") == "codex-main"

      assert Floki.find(form, "#provider-detail-codex-main-chatgpt-sign-in") == []
    end

    test "the begin control is a non-submitting button carrying the surface and profile id" do
      tree = detail()

      form = one(tree, "#provider-profile-detail-codex-main")
      button = one(form, "#provider-detail-codex-main-chatgpt-sign-in")

      assert attr(button, "type") == "button"
      assert attr(button, "phx-click") == "chatgpt_sign_in"
      assert attr(button, "phx-value-surface") == "detail"
      assert attr(button, "phx-value-profile_id") == "codex-main"
      assert text(button) == "Sign in with ChatGPT"

      # A submit button here would post the whole account form.
      refute attr(button, "type") == "submit"
      assert Floki.find(tree, "#provider-detail-codex-main-chatgpt-waiting") == []
    end

    test "another surface's flow never renders in the detail editor" do
      for foreign <- [
            %{surface: {:status, "codex-main"}, phase: :waiting, url: "https://example.test/a"},
            %{surface: :wizard, phase: :waiting, url: "https://example.test/a"},
            %{surface: {:detail, "another-account"}, phase: :waiting}
          ] do
        tree = detail(chatgpt_sign_in: foreign)

        assert Floki.find(tree, "#provider-detail-codex-main-chatgpt-sign-in") != []
        assert Floki.find(tree, "#provider-detail-codex-main-chatgpt-waiting") == []
        assert Floki.find(tree, "#provider-detail-codex-main-chatgpt-sign-in-url") == []
      end
    end

    test "manual (remote) mode renders the CLI hint and no button" do
      tree =
        detail(
          chatgpt_sign_in_manual: true,
          chatgpt_sign_in: waiting_state(surface: {:detail, "codex-main"})
        )

      hint = one(tree, "#provider-detail-codex-main-chatgpt-manual-hint")
      assert text(hint) =~ "genesis chatgpt login"
      assert text(hint) =~ "same machine as the execution node"

      assert Floki.find(tree, "#provider-detail-codex-main-chatgpt-sign-in") == []
      assert Floki.find(tree, "#provider-detail-codex-main-chatgpt-waiting") == []
    end

    test "the siwc_account help points at the in-form sign-in, not the CLI" do
      tree = detail()

      rendered = text(tree)
      assert rendered =~ @new_help
      refute rendered =~ @old_help
      refute rendered =~ "passed to genesis chatgpt login"

      # The account field itself is unchanged.
      assert attr(one(tree, ~s(input[name="siwc_account"])), "value") == "work"
    end

    test "a non-ChatGPT account renders no ChatGPT sign-in surface" do
      tree = detail(profile: anthropic_profile())

      assert Floki.find(tree, "[id$='-chatgpt-sign-in']") == []
      assert Floki.find(tree, "[id$='-chatgpt-manual-hint']") == []
      assert Floki.find(tree, "[id$='-chatgpt-waiting']") == []
    end
  end

  # ═══════════════════════════════════════════════════════════════════════════
  # helpers
  # ═══════════════════════════════════════════════════════════════════════════

  defp detail(overrides \\ []) do
    overrides = Keyword.put_new(overrides, :profile, chatgpt_profile())

    render_component(&Detail.profile_detail/1, overrides)
    |> Floki.parse_document!()
  end

  defp waiting_state(overrides) do
    Map.merge(
      %{phase: :waiting, url: "https://example.test/authorize", flow_id: "f1"},
      Map.new(overrides)
    )
  end

  defp chatgpt_profile(overrides \\ %{}) do
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

  defp anthropic_profile do
    %{
      "id" => "subscription-a",
      "provider" => "anthropic",
      "auth_mode" => "oauth",
      "default_model" => "claude-opus-4-5-20251101",
      "models" => [%{"model" => "claude-opus-4-5-20251101"}]
    }
  end

  # A single element may be handed back in as the scope of the next query.
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
