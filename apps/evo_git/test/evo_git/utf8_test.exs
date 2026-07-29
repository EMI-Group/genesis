defmodule EvoGit.UTF8Test do
  use ExUnit.Case, async: true

  alias EvoGit.UTF8

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

      truncated = String.byte_slice(content, 0, context_max)

      # The truncated result MUST be valid UTF-8 (this is what was crashing)
      assert String.valid?(truncated),
             "truncated content must be valid UTF-8, got invalid bytes"

      # And it should be encodable by Jason without crashing
      assert {:ok, _} = Jason.encode(%{"content" => truncated})
    end
  end
end
