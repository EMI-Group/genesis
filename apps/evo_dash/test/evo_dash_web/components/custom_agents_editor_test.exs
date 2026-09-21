defmodule EvoDashWeb.SettingsComponents.CustomAgentsEditorTest do
  @moduledoc """
  Render-only component tests for
  `EvoDashWeb.SettingsComponents.CustomAgentsEditor.custom_agents_editor/1`,
  focused on the tools group and its ADDITIONAL "Custom tools" chip group.

  The custom chip group lists custom tool modules loaded from
  `<config_dir>/tools/` (`custom_tool_names`) next to the built-in tool chips,
  using the SAME `tools[]` checkbox markup so the save path is unchanged; names
  colliding with a built-in are dropped, and names matching neither a built-in
  nor a loaded custom tool produce an amber "unknown tool" diagnostic.

  Render-only by design: the form's events (`add_custom_agent`,
  `save_custom_agent`, ...) are handled by SettingsLive, not the component.
  """

  use ExUnit.Case, async: true

  import Phoenix.LiveViewTest

  alias EvoDashWeb.SettingsComponents.CustomAgentsEditor

  @agent_id "my-id"

  describe "custom_agents_editor/1 — custom tools group" do
    test "a loaded custom tool renders a checked tools[] chip inside the Custom tools group" do
      builtin = builtin_tools()
      builtin_name = hd(builtin)

      html =
        render_edit_form(
          %{
            id: @agent_id,
            name: "Reviewer",
            prompt: "You are a reviewer",
            tools: ["my_custom_tool"]
          },
          custom_tool_names: ["my_custom_tool"]
        )

      group = custom_tools_group(html)
      assert group, "expected a rendered \"Custom tools\" group"

      custom_chips = Floki.find(group, ~s(input[name="tools[]"][value="my_custom_tool"]))
      assert length(custom_chips) == 1
      assert attribute(hd(custom_chips), "type") == ["checkbox"]
      assert attribute(hd(custom_chips), "class") == ["checkbox checkbox-xs"]
      assert attribute(hd(custom_chips), "checked") != []

      # The built-in chips still render alongside the custom group (and the
      # custom chip is NOT one of them).
      builtin_chips = Floki.find(parse(html), ~s(input[name="tools[]"][value="#{builtin_name}"]))
      assert length(builtin_chips) == 1
      assert attribute(hd(builtin_chips), "checked") == []
      assert length(builtin) > 1
    end

    test "a custom tool name colliding with a built-in is dropped and rendered exactly once" do
      colliding = hd(builtin_tools())

      html = render_edit_form(%{id: @agent_id, tools: []}, custom_tool_names: [colliding])

      chips = Floki.find(parse(html), ~s(input[name="tools[]"][value="#{colliding}"]))
      assert length(chips) == 1

      # The built-in chip already covers the colliding name, so no custom group.
      refute html =~ "Custom tools"
    end

    test "no custom tool names renders no Custom tools group and no warning" do
      html = render_edit_form(%{id: @agent_id, tools: []}, custom_tool_names: [])

      refute html =~ "Custom tools"
      refute html =~ "Unknown tool names"
    end

    test "an unrecognized tool warns with the exact sentence, valid tools do not" do
      html =
        render_edit_form(
          %{id: @agent_id, tools: ["totally_unknown_tool"]},
          custom_tool_names: []
        )

      assert html =~
               "Unknown tool names: totally_unknown_tool. They are neither built-in tools nor loaded custom tools."

      # The warning renders in the amber (warning) styling.
      assert [warning] =
               html |> parse() |> Floki.find(~s(p[class*="text-warning"]))

      assert Floki.text(warning) =~ "totally_unknown_tool"

      # An agent whose tools are all built-ins OR all loaded customs renders no
      # warning at all.
      valid_builtins =
        render_edit_form(
          %{id: @agent_id, tools: [hd(builtin_tools())]},
          custom_tool_names: []
        )

      refute valid_builtins =~ "Unknown tool names"

      valid_custom =
        render_edit_form(
          %{id: @agent_id, tools: ["my_custom_tool"]},
          custom_tool_names: ["my_custom_tool"]
        )

      refute valid_custom =~ "Unknown tool names"
    end

    test "an agent with an empty tools list renders no warning" do
      html = render_edit_form(%{id: @agent_id, tools: []}, custom_tool_names: [])

      refute html =~ "Unknown tool names"
    end
  end

  # --- helpers ---

  # Renders the editor in edit mode: `editing_agent_id` must match the agent's
  # id string for the private `agent_edit_form/1` (and thus the tools group) to
  # render. `custom_tool_names` sets the loaded-custom-tool chip list.
  defp render_edit_form(agent, opts) do
    render_component(&CustomAgentsEditor.custom_agents_editor/1,
      agents: [agent],
      editing_agent_id: to_string(Map.get(agent, :id)),
      custom_tool_names: Keyword.get(opts, :custom_tool_names, [])
    )
  end

  # The ADDITIONAL custom-tools block: the sole `div.mt-3` wrapper whose text
  # carries the "Custom tools" label. Returns nil when the group is absent.
  defp custom_tools_group(html) do
    html
    |> parse()
    |> Floki.find("div.mt-3")
    |> Enum.find(fn el -> Floki.text(el) =~ "Custom tools" end)
  end

  # Real built-in tool names as offered by `tool_names/0` in the component.
  defp builtin_tools do
    EvoGit.Agent.Tools.schemas()
    |> Enum.map(&EvoGit.Agent.tool_name/1)
    |> Enum.reject(&is_nil/1)
  end

  defp attribute(el, name) do
    el |> Floki.attribute(name) |> Enum.map(&to_string/1)
  end

  # Floki's find/2 + attribute/2 require a parsed tree, not a raw binary.
  defp parse(html), do: Floki.parse_document!(html)
end
