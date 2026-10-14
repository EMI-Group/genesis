defmodule EvoDashWeb.ContentTextTest do
  use ExUnit.Case, async: true

  alias EvoDashWeb.ContentText

  # Unit tests for the shared response-text classification. This is the single
  # source of truth for "which content parts make up the response text",
  # mirroring ReqLLM.Response.text/1 (`&(&1.type == :text)`) so reasoning
  # (:thinking) never leaks into the rendered response. Every function is TOTAL
  # — atom/string keys, bare maps, malformed and non-map parts never raise.

  describe "text_part?/1" do
    test "atom- and string-typed :text parts are text" do
      assert ContentText.text_part?(%{type: :text, text: "a"})
      assert ContentText.text_part?(%{"type" => "text", "text" => "a"})
    end

    test "a bare map without a type counts as text; nil/empty type too" do
      assert ContentText.text_part?(%{text: "x"})
      assert ContentText.text_part?(%{type: nil, text: "x"})
      assert ContentText.text_part?(%{type: "", text: "x"})
    end

    test "explicit non-text types are excluded" do
      for type <- [
            :thinking,
            "thinking",
            :image,
            :image_url,
            :file,
            :video_url,
            :audio,
            :mystery,
            "mystery"
          ] do
        refute ContentText.text_part?(%{type: type, text: "x"})
      end
    end

    test "real ReqLLM ContentPart structs classify by type" do
      assert ContentText.text_part?(%ReqLLM.Message.ContentPart{type: :text, text: "a"})
      refute ContentText.text_part?(%ReqLLM.Message.ContentPart{type: :thinking, text: "R"})
      refute ContentText.text_part?(%ReqLLM.Message.ContentPart{type: :image, data: <<1, 2, 3>>})
    end

    test "non-map parts are false" do
      for part <- [nil, "text", 42, :junk, [%{text: "x"}]] do
        refute ContentText.text_part?(part)
      end
    end
  end

  describe "text_of/1" do
    test "returns the binary :text of a text part" do
      assert ContentText.text_of(%{type: :text, text: "hello"}) == "hello"
      assert ContentText.text_of(%{text: "bare"}) == "bare"
      # The type is matched atom-or-string, but the :text VALUE is read with the
      # ATOM key (mirrors the historical `Map.get(part, :text)` in the callers),
      # so a string-keyed part carries no response text.
      assert ContentText.text_of(%{"type" => "text", "text" => "hello"}) == nil
    end

    test "returns nil for a non-text type even when it carries :text" do
      assert ContentText.text_of(%{type: :thinking, text: "R"}) == nil
      assert ContentText.text_of(%ReqLLM.Message.ContentPart{type: :thinking, text: "R"}) == nil
    end

    test "returns nil when a text part's :text is not a binary" do
      assert ContentText.text_of(%{type: :text}) == nil
      assert ContentText.text_of(%{type: :text, text: nil}) == nil
      assert ContentText.text_of(%{type: :text, text: 42}) == nil
      assert ContentText.text_of(%{}) == nil
    end

    test "returns nil for non-map parts" do
      for part <- [nil, "text", 42, :junk, [%{text: "x"}]] do
        assert ContentText.text_of(part) == nil
      end
    end
  end
end
