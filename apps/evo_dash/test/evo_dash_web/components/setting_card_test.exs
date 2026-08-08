defmodule EvoDashWeb.SettingCardTest do
  use ExUnit.Case, async: true

  import Phoenix.LiveViewTest

  alias EvoDashWeb.SettingsComponents.SettingCard

  # Component-level tests for `setting_card/1`'s `:list_of_strings` branch
  # (e.g. `[sandbox] write_paths`, added in 0ff33d39). The list editor renders
  # repeated text inputs all named `sandbox.write_paths` (they submit as a list
  # under one key), per-entry remove controls + one add control (both carrying
  # the key_path in `phx-value-key_path`), and a hidden sentinel that keeps a
  # SET list (even `[]`) distinct from an UNSET (nil) list on submit.
  #
  # The schema fixture mirrors the real `EvoGit.Config.Schema` definition for
  # `[:sandbox, :write_paths]` (type `:list_of_strings`, default nil).

  @key_path "sandbox.write_paths"

  describe "setting_card/1 — :list_of_strings list editor" do
    test "renders each entry as a text input named sandbox.write_paths" do
      html =
        render_component(&SettingCard.setting_card/1,
          schema: write_paths_schema(),
          value: ["/tmp/a", "/tmp/b"]
        )

      inputs = text_inputs(html)
      assert length(inputs) == 2

      # Exact `name=` attribute: every entry submits under the same key so the
      # server collects them into one list.
      assert attr(inputs, 0, "name") == [@key_path]
      assert attr(inputs, 0, "value") == ["/tmp/a"]
      assert attr(inputs, 0, "placeholder") == ["e.g. ~/.cache/genesis"]
      assert attr(inputs, 0, "class") == [
               "input input-bordered input-sm rounded-md w-full font-mono text-base"
             ]

      assert attr(inputs, 1, "name") == [@key_path]
      assert attr(inputs, 1, "value") == ["/tmp/b"]
      assert attr(inputs, 1, "placeholder") == ["e.g. ~/.cache/genesis"]
    end

    test "renders the hidden sentinel for a set list value" do
      html =
        render_component(&SettingCard.setting_card/1,
          schema: write_paths_schema(),
          value: ["/tmp/a", "/tmp/b"]
        )

      assert length(hidden_sentinels(html)) == 1
      assert hidden_sentinels(html) |> attr(0, "name") == [@key_path]
      assert hidden_sentinels(html) |> attr(0, "value") == [""]
    end

    test "add and remove controls carry the list events with key_path payloads" do
      html =
        render_component(&SettingCard.setting_card/1,
          schema: write_paths_schema(),
          value: ["/tmp/a", "/tmp/b"]
        )

      [add] = add_buttons(html)
      assert attr(add, "type") == ["button"]
      assert attr(add, "phx-click") == ["add_list_entry"]
      assert attr(add, "phx-value-key_path") == [@key_path]
      assert add |> Floki.text() |> String.trim() == "Add path"

      removes = remove_buttons(html)
      assert length(removes) == 2

      Enum.each(removes, fn btn ->
        assert attr(btn, "type") == ["button"]
        assert attr(btn, "phx-click") == ["remove_list_entry"]
        assert attr(btn, "phx-value-key_path") == [@key_path]
        assert attr(btn, "title") == ["Remove entry"]
      end)

      # Per-entry remove controls carry the entry index.
      assert attr(Enum.at(removes, 0), "phx-value-index") == ["0"]
      assert attr(Enum.at(removes, 1), "phx-value-index") == ["1"]
    end

    test "nil value renders the Not set hint with no text inputs" do
      html = render_component(&SettingCard.setting_card/1, schema: write_paths_schema(), value: nil)

      assert html =~ "Not set — platform default writable paths are used."
      assert text_inputs(html) == []
      assert hidden_sentinels(html) == []
      assert length(add_buttons(html)) == 1
    end

    test "empty list renders the hidden sentinel with no text inputs" do
      html = render_component(&SettingCard.setting_card/1, schema: write_paths_schema(), value: [])

      assert length(hidden_sentinels(html)) == 1
      assert hidden_sentinels(html) |> attr(0, "value") == [""]
      assert text_inputs(html) == []
      assert remove_buttons(html) == []
      assert length(add_buttons(html)) == 1
      refute html =~ "Not set"
    end

    test "non-list scalar normalizes to a single editable entry" do
      html =
        render_component(&SettingCard.setting_card/1,
          schema: write_paths_schema(),
          value: "/tmp/only"
        )

      assert length(text_inputs(html)) == 1
      assert text_inputs(html) |> attr(0, "value") == ["/tmp/only"]
      assert length(hidden_sentinels(html)) == 1
      assert length(remove_buttons(html)) == 1
      assert remove_buttons(html) |> attr(0, "phx-value-index") == ["0"]
    end

    test "non-list map normalizes to a single inspect entry" do
      html =
        render_component(&SettingCard.setting_card/1,
          schema: write_paths_schema(),
          value: %{a: 1}
        )

      assert length(text_inputs(html)) == 1
      assert text_inputs(html) |> attr(0, "value") == ["%{a: 1}"]
    end

    test "renders the key path and description" do
      html = render_component(&SettingCard.setting_card/1, schema: write_paths_schema(), value: nil)

      assert html =~ "sandbox.write_paths"
      assert html =~ "User-defined list of writable paths"
    end
  end

  describe "default_label/1 — rendered on the Default line" do
    test "nil default renders 'empty'" do
      html = render_component(&SettingCard.setting_card/1, schema: write_paths_schema(), value: nil)

      assert default_label_text(html) == "empty"
    end

    test "empty list default renders '(none)'" do
      html =
        render_component(&SettingCard.setting_card/1,
          schema: write_paths_schema(default: []),
          value: []
        )

      assert default_label_text(html) == "(none)"
    end

    test "list default renders entries joined with ', '" do
      html =
        render_component(&SettingCard.setting_card/1,
          schema: write_paths_schema(default: ["/tmp/a", "/tmp/b"]),
          value: ["/tmp/a"]
        )

      assert default_label_text(html) == "/tmp/a, /tmp/b"
    end
  end

  # --- helpers ---

  defp write_paths_schema(overrides \\ []) do
    Map.merge(
      %{
        key_path: [:sandbox, :write_paths],
        type: :list_of_strings,
        default: nil,
        validation: [],
        category: :sandbox,
        sub_category: nil,
        description:
          "User-defined list of writable paths for sandboxed tool execution (e.g. cache directories)."
      },
      Map.new(overrides)
    )
  end

  defp text_inputs(html) do
    Floki.find(parse(html), ~s(input[type="text"][name="sandbox.write_paths"]))
  end

  defp hidden_sentinels(html) do
    Floki.find(parse(html), ~s(input[type="hidden"][name="sandbox.write_paths"]))
  end

  defp add_buttons(html) do
    Floki.find(parse(html), ~s(button[phx-click="add_list_entry"]))
  end

  defp remove_buttons(html) do
    Floki.find(parse(html), ~s(button[phx-click="remove_list_entry"]))
  end

  defp attr(els, index, name) do
    els |> Enum.at(index) |> Floki.attribute(name) |> Enum.map(&to_string/1)
  end

  defp attr(el, name) do
    el |> Floki.attribute(name) |> Enum.map(&to_string/1)
  end

  defp default_label_text(html) do
    [span] = Floki.find(parse(html), "span.font-mono")
    span |> Floki.text() |> String.trim()
  end

  # Floki's find/2 + attribute/2 require a parsed tree, not a raw binary.
  defp parse(html), do: Floki.parse_document!(html)
end
