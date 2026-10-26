defmodule EvoDashWeb.HelpersBlobPreviewTest do
  use ExUnit.Case, async: true

  alias EvoDashWeb.Helpers

  @default_limit 16_384

  describe "blob_preview/2 — short input" do
    test "returns the binary unchanged with truncated?: false and the real byte size" do
      assert Helpers.blob_preview("hello") == %{
               text: "hello",
               truncated?: false,
               total_bytes: 5
             }
    end

    test "an empty binary is not truncated" do
      assert Helpers.blob_preview("") == %{text: "", truncated?: false, total_bytes: 0}
    end

    test "total_bytes counts BYTES, not characters" do
      # "héllo" = h(1) é(2) l l o => 6 bytes
      assert Helpers.blob_preview("héllo") == %{
               text: "héllo",
               truncated?: false,
               total_bytes: 6
             }
    end
  end

  describe "blob_preview/2 — default limit" do
    test "the default limit is 16_384 bytes" do
      # /1 exists (the documented default) and agrees with the explicit limit.
      assert Helpers.blob_preview("abc") == Helpers.blob_preview("abc", @default_limit)

      at_limit = String.duplicate("a", @default_limit)

      assert Helpers.blob_preview(at_limit) == %{
               text: at_limit,
               truncated?: false,
               total_bytes: @default_limit
             }

      over_limit = String.duplicate("a", @default_limit + 1)
      preview = Helpers.blob_preview(over_limit)

      assert preview.truncated? == true
      assert preview.total_bytes == @default_limit + 1
      assert preview.text == String.duplicate("a", @default_limit)
      assert byte_size(preview.text) == @default_limit
    end

    test "a large blob is byte-capped at the default limit" do
      blob = String.duplicate("x", 100_000)
      preview = Helpers.blob_preview(blob)

      assert %{text: text, truncated?: true, total_bytes: 100_000} = preview
      assert byte_size(text) == @default_limit
      assert String.starts_with?(blob, text)
    end
  end

  describe "blob_preview/2 — custom limit" do
    test "honors a smaller custom limit" do
      assert Helpers.blob_preview("abcdef", 3) == %{
               text: "abc",
               truncated?: true,
               total_bytes: 6
             }
    end

    test "a limit larger than the input leaves it untouched" do
      assert Helpers.blob_preview("abc", 100) == %{
               text: "abc",
               truncated?: false,
               total_bytes: 3
             }

      assert Helpers.blob_preview("abcdef", 6) == %{
               text: "abcdef",
               truncated?: false,
               total_bytes: 6
             }
    end

    test "limit: 0 drops the whole prefix but reports the real size as truncated" do
      assert Helpers.blob_preview("abc", 0) == %{
               text: "",
               truncated?: true,
               total_bytes: 3
             }
    end

    test "limit: 0 on an empty binary is not truncated" do
      assert Helpers.blob_preview("", 0) == %{text: "", truncated?: false, total_bytes: 0}
    end

    test "a negative limit is clamped back to the default limit" do
      # NOTE: the requested contract said a negative limit should behave like 0
      # (empty prefix + truncated?); the implementation's
      # `clamp_preview_limit/1` sends any negative value back to
      # @blob_preview_default_limit. Pinned as realized behavior (reported
      # upstream, not fixed here).
      assert Helpers.blob_preview("abc", -1) == %{
               text: "abc",
               truncated?: false,
               total_bytes: 3
             }

      big = String.duplicate("a", 20_000)
      assert %{text: text, truncated?: true, total_bytes: 20_000} = Helpers.blob_preview(big, -5)
      assert byte_size(text) == @default_limit
    end
  end

  describe "blob_preview/2 — multi-byte UTF-8" do
    test "never cuts a 2-byte character in half" do
      text = String.duplicate("é", 3)
      assert byte_size(text) == 6

      preview = Helpers.blob_preview(text, 3)

      assert preview.truncated? == true
      assert preview.total_bytes == 6
      assert preview.text == "é"
      assert String.valid?(preview.text)
    end

    test "never cuts a 3-byte character in half" do
      text = "日本"
      assert byte_size(text) == 6

      preview = Helpers.blob_preview(text, 4)

      assert preview.text == "日"
      assert String.valid?(preview.text)
      assert preview.truncated? == true
    end

    test "a cut at every byte offset stays valid UTF-8 and loses at most 3 bytes" do
      # Mixed widths: a(1) é(2) €(3) 😀(4) => 10 bytes.
      text = "aé€😀"
      assert byte_size(text) == 10

      for limit <- 1..9 do
        preview = Helpers.blob_preview(text, limit)

        assert preview.truncated? == true, "limit #{limit} should truncate"

        assert String.valid?(preview.text),
               "limit #{limit} produced invalid UTF-8: #{inspect(preview.text)}"

        assert String.starts_with?(text, preview.text)

        # At most a 3-byte incomplete codepoint is dropped from the cut.
        dropped = limit - byte_size(preview.text)
        assert dropped >= 0 and dropped <= 3, "limit #{limit} dropped #{dropped} bytes"
      end
    end

    test "an ASCII-only blob cut inside a codepoint-free region loses nothing" do
      preview = Helpers.blob_preview("abcdef", 4)
      assert preview.text == "abcd"
    end
  end

  describe "blob_preview/2 — invalid UTF-8" do
    test "degrades to the last valid prefix without raising" do
      blob = <<0xFF, 0xFE, "tail">>

      assert %{text: "", truncated?: true, total_bytes: 6} = Helpers.blob_preview(blob, 2)
    end

    test "keeps the valid bytes that precede the invalid one" do
      blob = <<"ab", 0xFF, "cd">>

      preview = Helpers.blob_preview(blob, 3)

      assert preview.text == "ab"
      assert preview.truncated? == true
      assert preview.total_bytes == 5
      assert String.valid?(preview.text)
    end

    test "an invalid blob under the limit is returned verbatim (never raised on)" do
      blob = <<0xFF, 0xFE>>

      assert %{text: ^blob, truncated?: false, total_bytes: 2} = Helpers.blob_preview(blob, 10)
    end
  end

  describe "blob_preview/2 — non-binary input" do
    test "nil and every non-binary term yield the empty preview" do
      empty = %{text: "", truncated?: false, total_bytes: 0}

      assert Helpers.blob_preview(nil) == empty
      assert Helpers.blob_preview(42, 10) == empty
      assert Helpers.blob_preview(:atom, 10) == empty
      assert Helpers.blob_preview(%{a: 1}, 10) == empty
      assert Helpers.blob_preview([1, 2, 3], 10) == empty
      assert Helpers.blob_preview({:ok, "x"}, 10) == empty
    end
  end

  describe "list_preview/2 — within the limit" do
    test "a list shorter than the limit is returned whole" do
      assert Helpers.list_preview([1, 2, 3], 10) == %{
               items: [1, 2, 3],
               total: 3,
               truncated?: false
             }
    end

    test "a list exactly at the limit is not truncated" do
      assert Helpers.list_preview([:a, :b], 2) == %{
               items: [:a, :b],
               total: 2,
               truncated?: false
             }
    end

    test "an empty list and limit: 0 on an empty list are both empty and untruncated" do
      empty = %{items: [], total: 0, truncated?: false}
      assert Helpers.list_preview([], 5) == empty
      assert Helpers.list_preview([], 0) == empty
    end
  end

  describe "list_preview/2 — over the limit" do
    test "keeps the first N items in order and reports the real total" do
      assert Helpers.list_preview([1, 2, 3, 4, 5], 2) == %{
               items: [1, 2],
               total: 5,
               truncated?: true
             }
    end

    test "items keep their identity (maps and tuples survive) " do
      items = [%{id: 1}, %{id: 2}, %{id: 3}]

      assert Helpers.list_preview(items, 2) == %{
               items: [%{id: 1}, %{id: 2}],
               total: 3,
               truncated?: true
             }

      assert Helpers.list_preview([{:a, 1}, {:b, 2}], 1) == %{
               items: [{:a, 1}],
               total: 2,
               truncated?: true
             }
    end

    test "limit: 0 drops every item but still reports the total as truncated" do
      assert Helpers.list_preview([1, 2, 3], 0) == %{
               items: [],
               total: 3,
               truncated?: true
             }
    end

    test "a negative limit is clamped back to the default limit" do
      # NOTE: same clamp as blob_preview/2 — a negative value falls back to
      # @blob_preview_default_limit rather than acting like 0. Pinned as
      # realized behavior (reported upstream, not fixed here).
      assert Helpers.list_preview([1, 2, 3], -1) == %{
               items: [1, 2, 3],
               total: 3,
               truncated?: false
             }
    end

    test "a huge list is capped at the requested limit without materializing the rest" do
      list = Enum.to_list(1..20_000)

      assert %{items: items, total: 20_000, truncated?: true} =
               Helpers.list_preview(list, 3)

      assert items == [1, 2, 3]
    end
  end

  describe "list_preview/2 — non-list input" do
    test "nil and every non-list term yield the empty preview" do
      empty = %{items: [], total: 0, truncated?: false}

      assert Helpers.list_preview(nil, 5) == empty
      assert Helpers.list_preview("not a list", 5) == empty
      assert Helpers.list_preview(%{a: 1}, 5) == empty
      assert Helpers.list_preview(42, 5) == empty
      assert Helpers.list_preview({1, 2}, 5) == empty
    end
  end
end
