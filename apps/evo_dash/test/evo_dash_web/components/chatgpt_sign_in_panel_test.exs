defmodule EvoDashWeb.SettingsComponents.ChatGPTSignInPanelTest do
  @moduledoc """
  The ONE shared Sign in with ChatGPT (SIWC) surface: button, waiting block,
  failure message and the manual CLI hint, plus the pure `surface_state/2`
  isolation rule the `/settings` page state relies on.

  Everything here is a pure function component rendered with assigns only — no
  LiveView, no flow module, no network and no clock: a test feeds the phase map
  it wants to see.
  """

  use ExUnit.Case, async: true

  import Phoenix.LiveViewTest

  alias EvoDashWeb.SettingsComponents.ChatGPTSignInPanel

  @idle %{flow_id: nil, url: nil, phase: :idle, reason: nil}

  describe "sign_in_panel/1 — idle" do
    test "an empty/nil/unknown-phase map renders ONE sign-in button and nothing else" do
      for sign_in <- [%{}, nil, %{phase: :idle}, %{phase: :nonsense}, %{phase: "ok?"}, "idle"] do
        tree = panel(sign_in: sign_in)

        button = one(tree, "#acct-sign-in")
        assert attr(button, "type") == "button"
        assert attr(button, "phx-click") == "chatgpt_sign_in"
        assert attr(button, "phx-value-surface") == "detail"
        assert text(button) == "Sign in with ChatGPT"

        assert nodes(tree, "#acct-waiting") == []
        assert nodes(tree, "#acct-sign-in-cancel") == []
        assert nodes(tree, "#acct-sign-in-error") == []
        assert nodes(tree, "#acct-manual-hint") == []
        assert nodes(tree, "a[href]") == []
      end
    end

    test "string-keyed state is read like the atom-keyed page state" do
      tree =
        panel(
          sign_in: %{
            "phase" => "waiting",
            "url" => "https://example.test/authorize?x=1",
            "flow_id" => "f1"
          }
        )

      assert attr(one(tree, "#acct-sign-in-url"), "href") == "https://example.test/authorize?x=1"
      assert nodes(tree, "#acct-sign-in") == []
    end

    test "an unset profile id renders no phx-value-profile_id attribute" do
      tree = panel(profile_id: nil)
      assert has_attr?(one(tree, "#acct-sign-in"), "phx-value-profile_id") == false
    end

    test "the surface and profile id are forwarded verbatim" do
      tree = panel(surface: "custom-surface", profile_id: "acct-42")

      button = one(tree, "#acct-sign-in")
      assert attr(button, "phx-value-surface") == "custom-surface"
      assert attr(button, "phx-value-profile_id") == "acct-42"
    end

    test "begin_event/cancel_event overrides reach the rendered phx-click" do
      assert attr(one(panel(begin_event: "go"), "#acct-sign-in"), "phx-click") == "go"

      waiting =
        panel(
          begin_event: "go",
          cancel_event: "stop",
          sign_in: %{phase: :waiting, url: "https://example.test/a"}
        )

      assert attr(one(waiting, "#acct-sign-in-cancel"), "phx-click") == "stop"
    end
  end

  describe "sign_in_panel/1 — waiting for authorization" do
    test "renders the link, the waiting line and the cancel control instead of the button" do
      tree =
        panel(
          profile_id: "acct-42",
          sign_in: %{
            flow_id: "f1",
            url: "https://example.test/authorize?a=1",
            phase: :waiting
          }
        )

      link = one(tree, "#acct-sign-in-url")
      assert attr(link, "href") == "https://example.test/authorize?a=1"
      assert attr(link, "target") == "_blank"
      assert attr(link, "rel") == "noopener noreferrer"
      assert text(link) == "Open the ChatGPT sign-in page"

      assert text(one(tree, "#acct-waiting p[role=\"status\"]")) == "Waiting for authorization…"

      cancel = one(tree, "#acct-sign-in-cancel")
      assert attr(cancel, "type") == "button"
      assert attr(cancel, "phx-value-surface") == "detail"
      assert attr(cancel, "phx-value-profile_id") == "acct-42"
      assert text(cancel) == "Cancel"

      # The primary action is replaced, never duplicated.
      assert nodes(tree, "#acct-sign-in") == []
      assert nodes(tree, "#acct-sign-in-error") == []
    end

    test "a blank or non-binary url renders no link at all" do
      for sign_in <- [
            %{phase: :waiting},
            %{phase: :waiting, url: nil},
            %{phase: :waiting, url: "   "},
            %{phase: :waiting, url: 42}
          ] do
        tree = panel(sign_in: sign_in)

        assert nodes(tree, "#acct-waiting") != []
        assert nodes(tree, "#acct-sign-in-url") == []
        assert nodes(tree, "a[href]") == []
        assert nodes(tree, "#acct-sign-in-cancel") != []
        assert nodes(tree, "#acct-sign-in") == []
      end
    end
  end

  describe "sign_in_panel/1 — failures" do
    test "a known reason renders the friendly localized text and never the raw atom" do
      tree = panel(sign_in: %{phase: :error, reason: :plan_not_authorized})

      error = one(tree, "#acct-sign-in-error")
      assert attr(error, "role") == "alert"
      assert text(error) == "Genesis was not granted permission to use this ChatGPT plan."
      refute html(tree) =~ "plan_not_authorized"

      # The user can immediately start again.
      assert nodes(tree, "#acct-sign-in") != []
      assert nodes(tree, "#acct-waiting") == []
    end

    test "an unknown reason falls back to the generic message" do
      tree = panel(sign_in: %{phase: :error, reason: :something_nobody_documented})

      error = text(one(tree, "#acct-sign-in-error"))
      assert error == "Sign-in could not be completed. Start again."
      refute error =~ "something_nobody_documented"
      refute html(tree) =~ "something_nobody_documented"
    end

    test "the message tone follows the outcome kind" do
      info = panel(sign_in: %{phase: :error, reason: :cancelled})
      assert text(one(info, "#acct-sign-in-error")) == "Sign-in cancelled."
      assert attr(one(info, "#acct-sign-in-error"), "class") =~ "text-base-content/70"

      denied = panel(sign_in: %{phase: :error, reason: :authorization_denied})
      assert attr(one(denied, "#acct-sign-in-error"), "class") =~ "text-error"
    end
  end

  describe "sign_in_panel/1 — manual (remote / unsupported) mode" do
    test "renders ONLY the CLI hint and the same-machine reason" do
      tree = panel(manual: true, sign_in: %{phase: :waiting, url: "https://example.test/a"})

      hint = one(tree, "#acct-manual-hint")
      assert text(hint) =~ "run this command on the execution node."
      assert text(hint) =~ "genesis chatgpt login"
      assert text(hint) =~ "same machine as the execution node"

      assert nodes(tree, "#acct-sign-in") == []
      assert nodes(tree, "#acct-waiting") == []
      assert nodes(tree, "#acct-sign-in-url") == []
      assert nodes(tree, "#acct-sign-in-cancel") == []
      assert nodes(tree, "#acct-sign-in-error") == []
      assert nodes(tree, "button") == []
    end

    test "an explicit command replaces the CLI line, a blank one falls back to the default" do
      overridden = panel(manual: true, command: "genesis chatgpt login --account work")

      assert text(one(overridden, "#acct-manual-hint code")) ==
               "genesis chatgpt login --account work"

      for command <- [nil, "", "   "] do
        tree = panel(manual: true, command: command)
        assert text(one(tree, "#acct-manual-hint code")) == "genesis chatgpt login"
      end
    end
  end

  describe "surface_state/2 — the ONE surface-isolation rule" do
    test "a surface that owns the state gets the normalized state back" do
      waiting = %{
        surface: :wizard,
        flow_id: "f1",
        url: "https://example.test/a",
        phase: :waiting,
        reason: nil
      }

      assert ChatGPTSignInPanel.surface_state(waiting, :wizard) == %{
               flow_id: "f1",
               url: "https://example.test/a",
               phase: :waiting,
               reason: nil
             }

      detail = %{surface: {:detail, "acct-1"}, phase: :error, reason: :cancelled}
      assert ChatGPTSignInPanel.surface_state(detail, {:detail, "acct-1"}).phase == :error
      assert ChatGPTSignInPanel.surface_state(detail, {:detail, "acct-1"}).reason == :cancelled

      status = %{surface: {:status, "acct-1"}, phase: :waiting}
      assert ChatGPTSignInPanel.surface_state(status, {:status, "acct-1"}).phase == :waiting
    end

    test "profile ids compare as strings, and the surface kind must match" do
      state = %{surface: {:detail, 42}, phase: :waiting}

      assert ChatGPTSignInPanel.surface_state(state, {:detail, "42"}).phase == :waiting

      assert %{phase: :waiting} =
               ChatGPTSignInPanel.surface_state(%{surface: {:status, "42"}, phase: :waiting}, {
                 :status,
                 42
               })

      assert ChatGPTSignInPanel.surface_state(state, {:status, "42"}) == %{}
      assert ChatGPTSignInPanel.surface_state(state, {:detail, "43"}) == %{}
      # A blank id never matches, even itself.
      assert ChatGPTSignInPanel.surface_state(%{surface: {:detail, ""}, phase: :waiting}, {
               :detail,
               ""
             }) == %{}
    end

    test "a nil/absent/unknown/different surface never leaks another surface's flow" do
      for {state, surface} <- [
            {%{surface: nil, phase: :waiting}, :wizard},
            {%{phase: :waiting}, :wizard},
            {%{surface: :nonsense, phase: :waiting}, :wizard},
            {%{surface: :wizard, phase: :waiting}, {:detail, "acct-1"}},
            {%{surface: {:detail, "acct-1"}, phase: :waiting}, :wizard},
            {%{surface: :wizard, phase: :waiting}, nil}
          ] do
        assert ChatGPTSignInPanel.surface_state(state, surface) == %{}
      end
    end

    test "a non-map state is idle-empty, not a crash" do
      for state <- [nil, :idle, "waiting", [phase: :waiting], 42] do
        assert ChatGPTSignInPanel.surface_state(state, :wizard) == %{}
      end
    end

    test "a matching surface at :idle answers the canonical idle map" do
      assert ChatGPTSignInPanel.surface_state(%{surface: :wizard}, :wizard) == @idle
      assert ChatGPTSignInPanel.surface_state(%{surface: {:detail, "a"}}, {:detail, "a"}) == @idle

      assert ChatGPTSignInPanel.surface_state(
               %{surface: :wizard, phase: :idle, flow_id: "stale", url: "stale"},
               :wizard
             ) == @idle
    end

    test "string-keyed page state is interpreted too" do
      state = %{"surface" => "wizard", "phase" => "waiting", "url" => "https://example.test/a"}

      assert ChatGPTSignInPanel.surface_state(state, :wizard) == %{
               flow_id: nil,
               url: "https://example.test/a",
               phase: :waiting,
               reason: nil
             }

      # A malformed stored surface is simply nobody's state.
      assert ChatGPTSignInPanel.surface_state(%{"surface" => %{}, "phase" => "waiting"}, :wizard) ==
               %{}
    end
  end

  # ═══════════════════════════════════════════════════════════════════════════
  # helpers
  # ═══════════════════════════════════════════════════════════════════════════

  defp panel(overrides) do
    render_component(
      &ChatGPTSignInPanel.sign_in_panel/1,
      Keyword.merge([id: "acct", surface: "detail"], overrides)
    )
    |> parse()
  end

  defp parse(html), do: Floki.parse_document!(html)

  defp html(tree), do: Floki.raw_html(tree)

  defp nodes(tree, selector), do: Floki.find(tree, selector)

  defp one(tree, selector) do
    assert [node] = Floki.find(tree, selector)
    node
  end

  defp attr(node, name) do
    assert [value] = Floki.attribute(node, name)
    value
  end

  defp has_attr?(node, name), do: Floki.attribute(node, name) != []

  defp text(node), do: node |> Floki.text() |> String.trim()
end
