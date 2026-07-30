defmodule EvoGit.Agent.OutputSanitizerTest do
  use ExUnit.Case, async: true

  alias EvoGit.Agent.OutputSanitizer

  describe "strip_ansi/1" do
    test "string without ANSI codes is unchanged" do
      input = "plain text with no escape codes"
      assert OutputSanitizer.strip_ansi(input) == input
    end

    test "empty string passes through" do
      assert OutputSanitizer.strip_ansi("") == ""
    end

    test "non-binary input passes through unchanged" do
      assert OutputSanitizer.strip_ansi(nil) == nil
      assert OutputSanitizer.strip_ansi(42) == 42
    end

    test "removes green color codes" do
      input = "\e[32mgreen text\e[0m"
      assert OutputSanitizer.strip_ansi(input) == "green text"
    end

    test "removes red color codes" do
      input = "\e[31mred text\e[0m"
      assert OutputSanitizer.strip_ansi(input) == "red text"
    end

    test "removes cursor movement codes" do
      input = "\e[1;1H"
      assert OutputSanitizer.strip_ansi(input) == ""
    end

    test "removes bold/bright codes" do
      input = "\e[1mbold\e[0m"
      assert OutputSanitizer.strip_ansi(input) == "bold"
    end

    test "removes multiple ANSI codes in one string" do
      input = "\e[1m\e[32mBold Green\e[0m then \e[31mRed\e[0m"
      assert OutputSanitizer.strip_ansi(input) == "Bold Green then Red"
    end

    test "removes background color codes" do
      input = "\e[44mblue background\e[49m"
      assert OutputSanitizer.strip_ansi(input) == "blue background"
    end

    test "removes underlined text codes" do
      input = "\e[4munderlined\e[24m"
      assert OutputSanitizer.strip_ansi(input) == "underlined"
    end

    test "removes 256-color and RGB codes" do
      input = "\e[38;5;196m256-color\e[0m"
      assert OutputSanitizer.strip_ansi(input) == "256-color"
    end

    test "preserves text content between ANSI codes" do
      input = "before \e[32mmiddle\e[0m after"
      assert OutputSanitizer.strip_ansi(input) == "before middle after"
    end
  end

  describe "strip_progress_bars/1" do
    test "normal text lines are kept unchanged" do
      input = "line 1\nline 2\nline 3"
      assert OutputSanitizer.strip_progress_bars(input) == input
    end

    test "non-binary input passes through" do
      assert OutputSanitizer.strip_progress_bars(nil) == nil
      assert OutputSanitizer.strip_progress_bars(42) == 42
    end

    test "carriage return overwriting keeps last segment" do
      input = "progress 0%\rprogress 50%\rprogress 100%"
      assert OutputSanitizer.strip_progress_bars(input) == "progress 100%"
    end

    test "progress bar lines with brackets are filtered out" do
      input = "some output\n[=====>      ] 50%\nmore output"
      result = OutputSanitizer.strip_progress_bars(input)
      assert result =~ "some output"
      assert result =~ "more output"
      refute result =~ "[=====>"
    end

    test "progress bar with equals signs is filtered" do
      input = "[==========>                ] 42%"
      result = OutputSanitizer.strip_progress_bars(input)
      refute result =~ "[==========>"
    end

    test "progress bar with hash signs is filtered" do
      input = "[########                    ] 35%"
      result = OutputSanitizer.strip_progress_bars(input)
      refute result =~ "[########"
    end

    test "spinner characters on their own lines are filtered" do
      assert OutputSanitizer.strip_progress_bars("|") == ""
      assert OutputSanitizer.strip_progress_bars("/") == ""
      assert OutputSanitizer.strip_progress_bars("-") == ""
      assert OutputSanitizer.strip_progress_bars("\\") == ""
    end

    test "spinner with surrounding whitespace is filtered" do
      assert OutputSanitizer.strip_progress_bars("  |  ") == ""
      assert OutputSanitizer.strip_progress_bars("\t-\t") == ""
    end

    test "empty and whitespace-only lines are filtered out" do
      input = "real line\n\n   \n\t\nanother real line"
      result = OutputSanitizer.strip_progress_bars(input)
      assert result =~ "real line"
      assert result =~ "another real line"
    end

    test "mixed content: progress lines + real output keeps only real output" do
      input =
        "Compiling...\n[=====>      ] 50%\n[==========> ] 80%\nBuild complete!\n|\nDone."

      result = OutputSanitizer.strip_progress_bars(input)
      assert result =~ "Compiling..."
      assert result =~ "Build complete!"
      assert result =~ "Done."
      refute result =~ "[=====>"
      refute result =~ "[==========>"
    end

    test "multi-line output with progress bars interspersed" do
      input = """
      Starting build...
      [=>                             ] 10%
      Compiling module A
      [========>                      ] 30%
      Compiling module B
      [================>              ] 60%
      Linking...
      [========================>      ] 90%
      Build successful!
      """

      result = OutputSanitizer.strip_progress_bars(input)
      assert result =~ "Starting build..."
      assert result =~ "Compiling module A"
      assert result =~ "Compiling module B"
      assert result =~ "Linking..."
      assert result =~ "Build successful!"
      refute result =~ "[=>"
      refute result =~ "[========>"
      refute result =~ "[================>"
      refute result =~ "[========================>"
    end

    test "carriage returns within multi-line content" do
      input = "Downloading\rDownloading 50%\rDownloading 100%\nComplete"
      result = OutputSanitizer.strip_progress_bars(input)
      assert result =~ "Downloading 100%"
      assert result =~ "Complete"
    end

    test "single line with only carriage return segments" do
      # When a line is just carriage-return overwritten content and nothing else
      input = "\r\r\r"
      result = OutputSanitizer.strip_progress_bars(input)
      # After handling carriage returns, the line becomes empty, so it gets filtered
      assert result == ""
    end

    test "preserves lines that look like progress bars but aren't" do
      # Lines with brackets but also substantial content should be preserved
      # The regex requires the line to match the specific progress bar pattern
      input = "See [reference] for details"
      result = OutputSanitizer.strip_progress_bars(input)
      assert result =~ "See [reference] for details"
    end
  end

  describe "truncate/3" do
    test "output under threshold passes through unchanged with nil truncation_info" do
      small_output = "Hello, this is a small output"
      {result, truncation_info} = OutputSanitizer.truncate(small_output, "read_file", %{"path" => "test.txt"})
      assert result == small_output
      assert truncation_info == nil
    end

    test "non-binary passes through with nil truncation_info" do
      assert OutputSanitizer.truncate(nil, "read_file", %{}) == {nil, nil}
      assert OutputSanitizer.truncate(42, "some_tool", %{}) == {42, nil}
    end

    test "empty string passes through with nil truncation_info" do
      assert OutputSanitizer.truncate("", "tool", %{}) == {"", nil}
    end

    test "small multiline output passes through unchanged with nil truncation_info" do
      output = Enum.join(Enum.map(1..100, &"Line #{&1}"), "\n")
      {result, truncation_info} = OutputSanitizer.truncate(output, "read_file", %{})
      assert result == output
      assert truncation_info == nil
    end
  end

  describe "sanitize_and_truncate/3" do
    test "small clean string passes through all pipeline steps unchanged with nil truncation_info" do
      input = "Hello, world!"
      {result, truncation_info} = OutputSanitizer.sanitize_and_truncate(input, "echo", %{})
      assert result == input
      assert truncation_info == nil
    end

    test "non-binary value passes through with nil truncation_info" do
      assert OutputSanitizer.sanitize_and_truncate(nil, "tool", %{}) == {nil, nil}
      assert OutputSanitizer.sanitize_and_truncate(123, "tool", %{}) == {123, nil}
    end

    test "string with ANSI codes gets cleaned" do
      input = "\e[32mSuccess\e[0m: File written"
      {result, truncation_info} = OutputSanitizer.sanitize_and_truncate(input, "write_file", %{})
      assert result == "Success: File written"
      assert truncation_info == nil
    end

    test "string with progress bars gets cleaned" do
      input = "Build started\n[=====>  ] 50%\nBuild complete"
      {result, truncation_info} = OutputSanitizer.sanitize_and_truncate(input, "build", %{})
      assert result =~ "Build started"
      assert result =~ "Build complete"
      refute result =~ "[=====>"
      assert truncation_info == nil
    end

    test "string with ANSI codes, carriage returns, and progress bars gets fully cleaned" do
      input =
        "\e[1m\e[32mDownloading\e[0m\r\e[1m\e[33mDownloading 50%\e[0m\n" <>
          "[========>     ] 50%\n" <>
          "\e[32mDownload complete\e[0m"

      {result, truncation_info} = OutputSanitizer.sanitize_and_truncate(input, "curl", %{"url" => "http://example.com"})

      # Should have ANSI codes removed
      refute result =~ "\e["
      # Should keep the last carriage return segment
      assert result =~ "Downloading 50%"
      # Should filter out the progress bar
      refute result =~ "[========>"
      # Should keep meaningful output
      assert result =~ "Download complete"
      assert truncation_info == nil
    end

    test "invalid UTF-8 with ANSI codes gets repaired and cleaned with truncation_info" do
      # Invalid UTF-8 prefix with ANSI color codes
      invalid = "valid \e[32mcolored\e[0m" <> <<0xFF>>
      {result, truncation_info} = OutputSanitizer.sanitize_and_truncate(invalid, "tool", %{})

      assert is_binary(result)
      # Should have ANSI codes removed
      refute result =~ "\e["
      # Should contain the valid text
      assert result =~ "valid colored"
      # Should report invalid_utf8 truncation
      assert truncation_info.reason == :invalid_utf8
      assert truncation_info.original_size == byte_size(invalid)
    end

    test "full pipeline on realistic tool output" do
      # Simulate output from a build tool with ANSI, progress bars, carriage returns
      input =
        "Running tests...\n" <>
          "\e[32m.\e[0m\e[32m.\e[0m\e[32m.\e[0m\n" <>
          "Running integration tests\rRunning integration tests (3/5)\rRunning integration tests (5/5)\n" <>
          "[==========================>] 100%\n" <>
          "\e[32mAll tests passed!\e[0m\n" <>
          "|\n" <>
          "Coverage: 95%"

      {result, truncation_info} = OutputSanitizer.sanitize_and_truncate(input, "mix_test", %{})

      # No ANSI escape codes
      refute result =~ "\e["
      # Progress bar removed
      refute result =~ "[==========================>]"
      # Spinner removed
      # Carriage returns resolved to final value
      assert result =~ "Running integration tests (5/5)"
      # Real content preserved
      assert result =~ "Running tests..."
      assert result =~ "..."
      assert result =~ "All tests passed!"
      assert result =~ "Coverage: 95%"
      # No truncation occurred
      assert truncation_info == nil
    end
  end
end
