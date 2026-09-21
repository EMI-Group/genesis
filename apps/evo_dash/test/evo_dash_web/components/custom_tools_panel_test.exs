defmodule EvoDashWeb.Components.CustomToolsPanelTest do
  @moduledoc """
  Component-level tests for `EvoDashWeb.SettingsComponents.CustomToolsPanel`.

  Render-only by design: `custom_tools_panel/1` is a pure function component fed
  a `EvoGit.CustomTools.status/0` value (the readable summary map or an
  `{:error, term()}` tuple) — the `reload_custom_tools` event is handled by
  SettingsLive, not the component. The `custom_tool_names/1` helper is covered
  with pure unit tests.
  """

  use ExUnit.Case, async: true

  import Phoenix.LiveViewTest

  alias EvoDashWeb.SettingsComponents.CustomToolsPanel

  describe "custom_tools_panel/1" do
    test "a read-only ok entry renders name/module/file and the Read-only badge" do
      html =
        render_panel(%{
          ok: [
            %{
              name: "my_tool",
              module: MyTool,
              file: "/cfg/tools/my_tool.ex",
              read_only?: true
            }
          ],
          errors: []
        })

      assert html =~ "my_tool"
      assert html =~ "MyTool"
      assert html =~ "/cfg/tools/my_tool.ex"

      assert "Read-only" in badge_texts(html)
      refute "Write" in badge_texts(html)
    end

    test "a writable ok entry renders the Write badge and no Read-only badge" do
      html =
        render_panel(%{
          ok: [
            %{
              name: "my_tool",
              module: MyTool,
              file: "/cfg/tools/my_tool.ex",
              read_only?: false
            }
          ],
          errors: []
        })

      assert "Write" in badge_texts(html)
      refute "Read-only" in badge_texts(html)
    end

    test "an error entry renders its file and reason" do
      html =
        render_panel(%{
          ok: [],
          errors: [%{file: "/cfg/tools/bad_tool.ex", reason: "compile error: boom"}]
        })

      assert html =~ "/cfg/tools/bad_tool.ex"
      assert html =~ "compile error: boom"

      # The error row (error-tinted box) is present.
      assert error_rows(html) != []

      # The empty state is only for a genuinely empty status.
      refute html =~ "No custom tools loaded"
    end

    test "an error entry with a nil file falls back to the 'unknown file' label" do
      html = render_panel(%{ok: [], errors: [%{file: nil, reason: "bad"}]})

      assert html =~ "unknown file"
      assert html =~ "bad"
    end

    test "an empty status renders the empty state and no error banner" do
      html = render_panel(%{ok: [], errors: []})

      assert html =~ "No custom tools loaded"
      refute html =~ "Custom Tools Unavailable"
    end

    test "an {:error, reason} status renders the red banner with the inspected reason" do
      html = render_panel({:error, :boom})

      assert html =~ "Custom Tools Unavailable"
      assert html =~ inspect(:boom)

      [pre] = Floki.find(parse(html), "pre")
      assert pre |> Floki.text() |> String.trim() == ":boom"

      # Mutual exclusion: the empty state must NOT render for an unreadable
      # status (it would imply the tools dir is simply empty).
      refute html =~ "No custom tools loaded"

      # The Refresh action still renders so the user can retry.
      assert refresh_button(html) != []
    end

    test "loading: true disables the Refresh button" do
      html = render_panel(%{ok: [], errors: []}, loading: true)

      [button] = refresh_button(html)
      assert attr(button, "type") == ["button"]
      assert attr(button, "phx-click") == ["reload_custom_tools"]
      # HEEx emits a bare boolean attribute; Floki parses it as "disabled".
      assert attr(button, "disabled") == ["disabled"]
      assert button |> Floki.text() |> String.trim() == "Refresh"
    end

    test "loading: false leaves the Refresh button enabled" do
      html = render_panel(%{ok: [], errors: []}, loading: false)

      [button] = refresh_button(html)
      assert attr(button, "disabled") == []
    end

    test "a nil status renders the empty state without raising" do
      html = render_panel(nil)

      assert html =~ "No custom tools loaded"
      refute html =~ "Custom Tools Unavailable"
    end

    test "string-keyed status and entries render like the atom-keyed shape" do
      html =
        render_panel(%{
          "ok" => [%{"name" => "x", "file" => "/f", "read_only?" => true}],
          "errors" => []
        })

      assert html =~ "x"
      assert html =~ "/f"
      assert "Read-only" in badge_texts(html)
    end

    test "an ok value that is not a list degrades to the empty state" do
      html = render_panel(%{ok: "nonsense", errors: %{}})

      assert html =~ "No custom tools loaded"
      refute html =~ "Custom Tools Unavailable"
    end

    test "non-map ok entries are filtered out while real entries render" do
      html = render_panel(%{ok: [1, "s", nil, %{name: "real"}]})

      assert html =~ "real"
      refute html =~ "No custom tools loaded"
    end

    test "a missing errors key renders the tool with no error rows" do
      html = render_panel(%{ok: [%{name: "a"}]})

      assert html =~ "a"
      # No error-styled row is present.
      assert error_rows(html) == []
    end
  end

  describe "custom_tool_names/1" do
    test "extracts loaded tool names in order" do
      status = %{ok: [%{name: "alpha"}, %{name: "beta"}], errors: []}

      assert CustomToolsPanel.custom_tool_names(status) == ["alpha", "beta"]
    end

    test "an {:error, _} status yields []" do
      assert CustomToolsPanel.custom_tool_names({:error, :boom}) == []
    end

    test "nil yields []" do
      assert CustomToolsPanel.custom_tool_names(nil) == []
    end

    test "a bare list yields []" do
      assert CustomToolsPanel.custom_tool_names(["a", "b"]) == []
    end

    test "a string-keyed map yields the expected names" do
      status = %{"ok" => [%{"name" => "x"}, %{"name" => "y"}]}

      assert CustomToolsPanel.custom_tool_names(status) == ["x", "y"]
    end

    test "blank names are dropped" do
      status = %{ok: [%{name: ""}, %{name: "a"}, %{name: nil}]}

      assert CustomToolsPanel.custom_tool_names(status) == ["a"]
    end

    test "non-map and complex entries are dropped" do
      status = %{ok: [1, "s", nil, %{name: "real"}, %{name: %{nested: true}}]}

      assert CustomToolsPanel.custom_tool_names(status) == ["real"]
    end

    test "duplicates are deduped order-preservingly" do
      status = %{ok: [%{name: "a"}, %{name: "b"}, %{name: "a"}]}

      assert CustomToolsPanel.custom_tool_names(status) == ["a", "b"]
    end

    test "atoms, integers and floats are converted to strings" do
      status = %{ok: [%{name: :foo}, %{name: 1}, %{name: 2.5}]}

      assert CustomToolsPanel.custom_tool_names(status) == ["foo", "1", "2.5"]
    end
  end

  # --- helpers ---

  defp render_panel(status, opts \\ []) do
    render_component(&CustomToolsPanel.custom_tools_panel/1,
      status: status,
      loading: Keyword.get(opts, :loading, false)
    )
  end

  defp refresh_button(html) do
    Floki.find(parse(html), ~s(button[phx-click="reload_custom_tools"]))
  end

  # The per-error row box (error-tinted border).
  defp error_rows(html) do
    Floki.find(parse(html), ~s(div[class*="border-error/30"]))
  end

  defp badge_texts(html) do
    html
    |> parse()
    |> Floki.find("span.badge")
    |> Enum.map(fn badge -> badge |> Floki.text() |> String.trim() end)
  end

  defp attr(el, name) do
    el |> Floki.attribute(name) |> Enum.map(&to_string/1)
  end

  # Floki's find/2 + attribute/2 require a parsed tree, not a raw binary.
  defp parse(html), do: Floki.parse_document!(html)
end
