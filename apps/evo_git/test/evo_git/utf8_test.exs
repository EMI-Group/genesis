defmodule EvoGit.UTF8Test do
  use ExUnit.Case, async: true

  alias EvoGit.UTF8

  describe "safe_binary_part/3" do
    test "returns the full binary when start + len exceeds byte_size" do
      binary = "Hello"
      assert UTF8.safe_binary_part(binary, 0, 100) == "Hello"
    end

    test "extracts a substring that ends on a character boundary" do
      # 5 ASCII chars + em-dash (3 bytes) + 5 ASCII chars
      binary = "aaaaa—bbbbb"
      # byte_size = 5 + 3 + 5 = 13
      assert byte_size(binary) == 13

      # Take 6 bytes: "aaaaa" (5) + first byte of em-dash (0xE2).
      # safe_binary_part must back up to a valid boundary → "aaaaa" (5 bytes).
      result = UTF8.safe_binary_part(binary, 0, 6)
      assert String.valid?(result)
      assert result == "aaaaa"
    end

    test "never produces invalid UTF-8 even when cutting mid-codepoint" do
      # 100 em-dashes = 300 bytes
      binary = String.duplicate("—", 100)
      assert byte_size(binary) == 300

      # Cut at every byte position that could split a codepoint
      for cut <- 1..299 do
        result = UTF8.safe_binary_part(binary, 0, cut)
        assert String.valid?(result), "cut=#{cut} produced invalid UTF-8"
      end
    end

    test "handles pure ASCII unchanged" do
      binary = String.duplicate("A", 100)
      assert UTF8.safe_binary_part(binary, 0, 50) == String.duplicate("A", 50)
    end

    test "handles start offset mid-codepoint by still returning valid prefix" do
      # 'a' + em-dash + 'b'  → bytes: 0x61 E2 80 94 0x62
      binary = "a—b"
      # start=1 lands on 0xE2 (start of em-dash). len=2 covers 0xE2 0x80.
      result = UTF8.safe_binary_part(binary, 1, 2)
      assert String.valid?(result)
    end
  end

  describe "safe_binary_part_from_end/2" do
    test "returns last len bytes when on a clean boundary" do
      binary = "abcdefghij"
      assert UTF8.safe_binary_part_from_end(binary, 3) == "hij"
    end

    test "trims leading partial bytes to produce valid UTF-8" do
      # 5 ASCII + em-dash (3 bytes) + 5 ASCII = 13 bytes
      binary = "aaaaa—bbbbb"
      # Ask for last 7 bytes: starts at byte 6 → lands on 0x80 (middle of em-dash).
      # Must trim forward to 0x62 ('b') to be valid.
      result = UTF8.safe_binary_part_from_end(binary, 7)
      assert String.valid?(result)
      assert result == "bbbbb"
    end

    test "never produces invalid UTF-8 at any len from end" do
      binary = String.duplicate("—", 100)

      for len <- 1..299 do
        result = UTF8.safe_binary_part_from_end(binary, len)
        assert String.valid?(result), "len=#{len} produced invalid UTF-8"
      end
    end

    test "handles len larger than binary" do
      binary = "ab"
      assert UTF8.safe_binary_part_from_end(binary, 100) == "ab"
    end
  end

  describe "ensure_utf8/1" do
    test "valid UTF-8 string passes through unchanged with nil truncation_info" do
      input = "Hello, world! 日本語テスト 🎉"
      assert UTF8.ensure_utf8(input) == {input, nil}
    end

    test "empty string passes through with nil truncation_info" do
      assert UTF8.ensure_utf8("") == {"", nil}
    end

    test "non-binary nil passes through unchanged with nil truncation_info" do
      assert UTF8.ensure_utf8(nil) == {nil, nil}
    end

    test "non-binary integer passes through unchanged with nil truncation_info" do
      assert UTF8.ensure_utf8(123) == {123, nil}
    end

    test "non-binary list passes through unchanged with nil truncation_info" do
      assert UTF8.ensure_utf8([1, 2, 3]) == {[1, 2, 3], nil}
    end

    test "invalid UTF-8 binary gets repaired or truncated with warning and truncation_info" do
      invalid_binary = "valid prefix" <> <<0xFF, 0xFE>>
      {result, truncation_info} = UTF8.ensure_utf8(invalid_binary)

      assert is_binary(result)
      assert result =~ "valid prefix"
      assert result =~ "[WARNING: Output truncated due to invalid UTF-8 binary data]"

      assert truncation_info.reason == :invalid_utf8
      assert truncation_info.original_size == byte_size(invalid_binary)
      assert is_integer(truncation_info.truncated_size)
    end

    test "incomplete UTF-8 sequence gets truncated with warning and truncation_info" do
      incomplete = "hello" <> <<0xE2, 0x82>>
      {result, truncation_info} = UTF8.ensure_utf8(incomplete)

      assert is_binary(result)
      assert result =~ "hello"
      assert result =~ "[WARNING: Output truncated due to invalid UTF-8 binary data]"

      assert truncation_info.reason == :invalid_utf8
      assert truncation_info.original_size == byte_size(incomplete)
    end

    test "valid multi-byte UTF-8 characters pass through with nil truncation_info" do
      input = "日本語 中文 한국어 Ελληνικά العربية"
      assert UTF8.ensure_utf8(input) == {input, nil}
    end

    test "repaired output is always valid UTF-8" do
      # A string with various invalid byte sequences
      invalid = "good" <> <<0xC3, 0x28>> <> "more" <> <<0xE2, 0x80>>
      {result, _} = UTF8.ensure_utf8(invalid)

      assert String.valid?(result)
    end
  end

  describe "integration: em-dash truncation bug scenario" do
    # This is the exact scenario from the bug report: CONTEXT.md content with
    # em-dashes (—) that gets truncated by binary_part at a byte boundary,
    # splitting the 3-byte codepoint and crashing Jason.encode!.
    test "truncating em-dash content never yields invalid UTF-8" do
      # Simulate a CONTEXT.md with em-dashes
      content = "Architecture — design — overview\n" |> String.duplicate(1000)
      context_max = 500

      truncated = UTF8.safe_binary_part(content, 0, context_max)

      # The truncated result MUST be valid UTF-8 (this is what was crashing)
      assert String.valid?(truncated),
             "truncated content must be valid UTF-8, got invalid bytes"

      # And it should be encodable by Jason without crashing
      assert {:ok, _} = Jason.encode(%{"content" => truncated})
    end
  end
end
