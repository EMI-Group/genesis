defmodule EvoDashWeb.ModelProfilesEditorAuthTest do
  @moduledoc """
  Render-only component tests for the OAuth / subscription-auth UI of
  `EvoDashWeb.SettingsComponents.ModelProfilesEditor`: the edit form's auth-mode
  control, the summary row's auth badge, and the shared credential-status line.

  Render-only by design: the `refresh_auth_status` event is handled by
  SettingsLive, not the component, so these tests pin markup and the pure
  derivation helpers only (no LiveView, no sleeps → fully async).
  """

  use ExUnit.Case, async: true

  import Phoenix.LiveViewTest

  alias EvoDashWeb.SettingsComponents.ModelProfilesEditor

  # A fixed far-future ms epoch (2100-01-01T00:00:00Z) so the expiry branch is
  # deterministic; the formatted date string is deliberately NOT asserted (it is
  # locale/timezone dependent) — only the stable label prefix is.
  @future_expiry_ms 4_102_444_800_000

  describe "auth mode control visibility (edit form)" do
    # Pins: an OAuth-CAPABLE provider (anthropic) always gets the auth-mode
    # select, and with no saved auth_mode the effective mode is API key.
    test "an OAuth-capable provider without a saved auth_mode defaults the select to API key" do
      html = render_edit_form(%{id: "p1", model: "anthropic:claude-sonnet-5-5"})

      assert [select] = find(html, ~s(select[name="auth_mode"]))
      assert option_values(select) == ["api_key", "oauth"]
      assert selected_option_values(select) == ["api_key"]
      # API key mode means no subscription credential file is offered.
      assert find(html, ~s(input[name="oauth_file"])) == []
    end

    # Pins: a saved `auth_mode = "oauth"` pre-selects the OAuth option AND
    # reveals the credential-file input, whose placeholder is the managed file.
    test "a saved auth_mode of oauth selects the OAuth option and reveals the credential file" do
      html =
        render_edit_form(%{
          id: "p1",
          model: "anthropic:claude-sonnet-5-5",
          auth_mode: "oauth"
        })

      assert [select] = find(html, ~s(select[name="auth_mode"]))
      assert selected_option_values(select) == ["oauth"]

      assert [input] = find(html, ~s(input[name="oauth_file"]))
      assert attribute(input, "placeholder") == [EvoGit.Auth.default_oauth_file()]
      assert attribute(input, "value") == [""]
    end

    # Pins: an API-key-only provider (deepseek) gets NO auth UI whatsoever — no
    # select, no credential input, not even the "Authentication" section — so an
    # irrelevant API-key prompt can never be shown.
    test "an API-key-only provider renders no auth controls at all" do
      html = render_edit_form(%{id: "p1", model: "deepseek:deepseek-v4-pro"})

      assert find(html, ~s(select[name="auth_mode"])) == []
      assert find(html, ~s(input[name="oauth_file"])) == []
      refute text(html) =~ "Authentication"
    end

    # Pins: an OAuth-ONLY provider (openai_codex) degrades to a static badge
    # instead of the select, yet the credential-file input still renders because
    # OAuth is the effective mode.
    test "an OAuth-only provider renders a static subscription badge instead of the select" do
      html = render_edit_form(%{id: "p1", model: "openai_codex:gpt-5.6-terra"})

      assert find(html, ~s(select[name="auth_mode"])) == []

      body = text(html)
      assert body =~ "Subscription (OAuth)"
      assert body =~ "This provider only supports a subscription login."

      assert [input] = find(html, ~s(input[name="oauth_file"]))
      assert attribute(input, "placeholder") == [EvoGit.Auth.default_oauth_file()]
    end
  end

  describe "summary row auth badge" do
    # Pins: the collapsed row summarises the effective auth mode; an OAuth-capable
    # profile with no saved auth_mode reads "API key".
    test "an OAuth-capable profile without an auth_mode shows the API key badge" do
      html = render_summary_row(%{id: "p1", model: "anthropic:claude-sonnet-5-5"})

      body = text(html)
      assert body =~ "API key"
      refute body =~ "OAuth"
    end

    # Pins: `auth_mode = "oauth"` flips the summary badge to "OAuth" (and, being
    # OAuth-enabled, also renders the credential-status line at row level).
    test "a profile with auth_mode oauth shows the OAuth badge" do
      html =
        render_summary_row(%{
          id: "p1",
          model: "anthropic:claude-sonnet-5-5",
          auth_mode: "oauth"
        })

      body = text(html)
      assert body =~ "OAuth"
      refute body =~ "API key"
      # Row-level status line is verdict-free when no status was supplied.
      assert body =~ "Subscription login"
    end

    # Pins: an API-key-only provider carries no auth badge at all in the row.
    test "an API-key-only provider shows no auth badge at all" do
      html = render_summary_row(%{id: "p1", model: "deepseek:deepseek-v4-pro"})

      body = text(html)
      refute body =~ "API key"
      refute body =~ "OAuth"
    end

    # Pins: a missing `auth_statuses` entry is NORMAL (only OAuth-enabled
    # profiles are polled) and must render the neutral label — never a verdict.
    test "a missing auth_statuses entry renders neutral guidance, never a verdict" do
      html =
        render_summary_row(
          %{id: "p1", model: "anthropic:claude-sonnet-5-5", auth_mode: "oauth"},
          auth_statuses: %{}
        )

      body = text(html)
      assert body =~ "Subscription login"
      refute body =~ "Login detected"
      refute body =~ "No subscription login found"
    end
  end

  describe "auth status line" do
    # Pins: state :ok renders the positive verdict, the success icon, and the
    # resolved managed-credential path.
    test "a detected login shows the verdict, its success icon, and the managed file" do
      html =
        render_edit_form(
          %{id: "p1", model: "anthropic:claude-sonnet-5-5", auth_mode: "oauth"},
          auth_statuses: %{
            "p1" => %{
              state: :ok,
              expires: @future_expiry_ms,
              account_id: "acct",
              login_instructions: nil,
              oauth_file: "/tmp/genesis/auth.json"
            }
          }
        )

      body = text(html)
      assert body =~ ~r/Login detected/
      assert body =~ "Managed credential file: /tmp/genesis/auth.json"
      assert find(html, "span.hero-check-circle") != []
    end

    # Pins: state :missing renders the negative verdict, the status-supplied
    # login guidance, the managed file, and the "we import it next run" note.
    test "a missing login shows the verdict, the login guidance, and the next-run note" do
      html =
        render_edit_form(
          %{id: "p1", model: "anthropic:claude-sonnet-5-5", auth_mode: "oauth"},
          auth_statuses: %{
            "p1" => %{
              state: :missing,
              login_instructions: "Run `claude` and log in once",
              oauth_file: "/tmp/genesis/auth.json"
            }
          }
        )

      body = text(html)
      assert body =~ "No subscription login found"
      assert body =~ "Run `claude` and log in once"
      assert body =~ "Managed credential file: /tmp/genesis/auth.json"
      assert body =~ "Genesis imports the vendor login automatically on the next run."
      assert find(html, "span.hero-exclamation-triangle") != []
    end

    # Pins: an unknown/absent state is neutral — the generic label plus the
    # provider's fallback login guidance, and never a verdict.
    test "an unknown status shows neutral guidance with no verdict" do
      html =
        render_edit_form(
          %{id: "p1", model: "anthropic:claude-sonnet-5-5", auth_mode: "oauth"},
          auth_statuses: %{"p1" => %{state: :unknown}}
        )

      body = text(html)
      assert body =~ "Subscription login"
      refute body =~ "Login detected"
      refute body =~ "No subscription login found"
      # No status guidance → the provider's fallback instructions render.
      assert body =~ "claude setup-token"
    end

    # Pins: the status helpers are TOTAL over string-keyed maps (the live side
    # normalizes JSON-ish maps), so a string-keyed entry behaves identically —
    # including honoring the custom guidance rather than the provider fallback.
    test "a string-keyed status map normalizes identically to an atom-keyed one" do
      html =
        render_edit_form(
          %{id: "p1", model: "anthropic:claude-sonnet-5-5", auth_mode: "oauth"},
          auth_statuses: %{
            "p1" => %{
              "state" => "missing",
              "login_instructions" => "CUSTOM-STATUS-LOGIN-GUIDANCE",
              "oauth_file" => "/tmp/genesis/string-keyed.json"
            }
          }
        )

      body = text(html)
      assert body =~ "No subscription login found"
      assert body =~ "CUSTOM-STATUS-LOGIN-GUIDANCE"
      assert body =~ "Managed credential file: /tmp/genesis/string-keyed.json"
      assert find(html, "span.hero-exclamation-triangle") != []
    end

    # Pins: statuses are read by SAVED profile-id STRING, so another profile's
    # entry can never leak into this profile's line.
    test "a status entry for another profile id never leaks into this profile" do
      html =
        render_edit_form(
          %{id: "p1", model: "anthropic:claude-sonnet-5-5", auth_mode: "oauth"},
          auth_statuses: %{
            "other-profile" => %{state: :missing, oauth_file: "/tmp/genesis/other.json"}
          }
        )

      body = text(html)
      assert body =~ "Subscription login"
      refute body =~ "No subscription login found"
      refute body =~ "/tmp/genesis/other.json"
    end

    # Pins: a malformed (non-map) status entry must not crash the render — it
    # degrades to the neutral label, exactly like a missing entry.
    test "a non-map status entry degrades to neutral guidance" do
      html =
        render_edit_form(
          %{id: "p1", model: "anthropic:claude-sonnet-5-5", auth_mode: "oauth"},
          auth_statuses: %{"p1" => "bogus"}
        )

      body = text(html)
      assert body =~ "Subscription login"
      refute body =~ "Login detected"
      refute body =~ "No subscription login found"
    end

    # Pins: the recheck affordance lives INSIDE the status line and is a plain
    # form-less button (the event is handled by SettingsLive).
    test "the Recheck control is a plain button inside the status line" do
      html =
        render_edit_form(%{id: "p1", model: "anthropic:claude-sonnet-5-5", auth_mode: "oauth"})

      assert [status_line] = find(html, "div.mt-2.space-y-1")
      assert [button] = Floki.find(status_line, ~s(button[phx-click="refresh_auth_status"]))
      assert attribute(button, "type") == ["button"]
      assert attribute(button, "aria-label") == ["Recheck"]
      # The whole editor holds exactly one recheck button.
      assert length(find(html, ~s(button[phx-click="refresh_auth_status"]))) == 1
    end
  end

  # --- helpers ---

  # Renders the editor with a single profile in EDIT mode (editing_profile_id
  # must match the profile's id string for the edit form to render).
  defp render_edit_form(profile, opts \\ []) do
    render_editor(profile, to_string(Map.get(profile, :id)), opts)
  end

  # Renders the editor with a single profile in SUMMARY (read-only row) mode.
  defp render_summary_row(profile, opts \\ []) do
    render_editor(profile, nil, opts)
  end

  defp render_editor(profile, editing_profile_id, opts) do
    render_component(&ModelProfilesEditor.model_profiles_editor/1,
      profiles: [profile],
      editing_profile_id: editing_profile_id,
      profile_form_draft: nil,
      profile_advanced_open: nil,
      auth_statuses: Keyword.get(opts, :auth_statuses, %{})
    )
  end

  defp option_values(select) do
    select
    |> Floki.find("option")
    |> Enum.map(fn option -> option |> attribute("value") |> hd() end)
  end

  defp selected_option_values(select) do
    select
    |> Floki.find("option")
    |> Enum.filter(fn option -> attribute(option, "selected") != [] end)
    |> Enum.map(fn option -> option |> attribute("value") |> hd() end)
  end

  defp find(html, selector) do
    Floki.find(parse(html), selector)
  end

  defp text(html) do
    html |> parse() |> Floki.text()
  end

  defp attribute(el, name) do
    el |> Floki.attribute(name) |> Enum.map(&to_string/1)
  end

  # Floki's find/2 + attribute/2 require a parsed tree, not a raw binary.
  defp parse(html), do: Floki.parse_document!(html)
end
