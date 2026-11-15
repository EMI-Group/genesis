defmodule EvoDashWeb.HomeLive.UserMessageTest do
  use ExUnit.Case, async: true
  import Phoenix.LiveViewTest
  alias EvoDashWeb.HomeLive.{ChatMessages, Transcript, UserMessage}

  defp bubble_text(text) do
    render_component(&UserMessage.user_message/1, entry: Transcript.entry(:user, text))
    |> LazyHTML.from_fragment()
    |> LazyHTML.query("div")
    |> LazyHTML.text()
  end

  test "typed messages render their exact text without template whitespace" do
    assert bubble_text("你好，Genesis <test> & friends") == "你好，Genesis <test> & friends"
  end

  test "suggestion messages render their exact button payload without template whitespace" do
    [suggestion | _] =
      render_component(&ChatMessages.quick_actions/1, %{})
      |> Floki.parse_fragment!()
      |> Floki.find("button[phx-click=send_message]")
      |> Floki.attribute("phx-value-message")

    assert bubble_text(suggestion) == suggestion
  end

  test "intentional multiline text and indentation remain unchanged" do
    text = "\n  第一段\n\n    第二段\n"
    assert bubble_text(text) == text
  end
end
