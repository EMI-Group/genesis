defmodule EvoGit.Agent.Tools.FileReadTest do
  @moduledoc """
  `async: true` — each test reads/writes only its own per-test tmp dir
  (`System.tmp_dir!()` + a unique integer suffix); no BEAM-global state.

  Pins the trained `read` output conventions: the `File: <path>` header, the
  blank-line-separated footer (continuation hint vs end-of-file), the per-line
  2000-character clip, the offset-past-EOF failure, and the empty-file note.
  """

  use ExUnit.Case, async: true

  alias EvoGit.Agent.Tools.FileRead

  # The exact marker `file_read.ex` appends to a clipped line.
  @clip_marker "… (line truncated to 2000 chars)"
  @max_line_chars 2000

  setup do
    tmp_dir =
      Path.join(System.tmp_dir!(), "file_read_test_" <> to_string(System.unique_integer()))

    File.mkdir_p!(tmp_dir)
    on_exit(fn -> File.rm_rf!(tmp_dir) end)

    {:ok, %{tmp_dir: tmp_dir}}
  end

  # Writes `content` into the per-test tmp dir and returns the RELATIVE name (the
  # form the tool echoes back in its `File:` header).
  defp put_file!(tmp_dir, name, content) do
    File.write!(Path.join(tmp_dir, name), content)
    name
  end

  defp run(tmp_dir, args), do: FileRead.execute(args, tmp_dir, nil)

  # The body of a ONE-line read: the content line, with any `1\t` prefix removed.
  defp single_line_body(output) do
    output
    |> String.split("\n")
    |> Enum.at(1)
    |> String.replace_prefix("1\t", "")
  end

  describe "schema/0" do
    test "exposes the model-facing `read` name with only file_path required" do
      schema = FileRead.schema()

      assert schema.name == "read"
      assert schema.parameter_schema["required"] == ["file_path"]

      assert schema.parameter_schema["properties"] |> Map.keys() |> Enum.sort() ==
               ["file_path", "limit", "line_numbers", "max_bytes", "offset"]
    end

    test "keeps the terse parameter defaults the implementation relies on" do
      props = FileRead.schema().parameter_schema["properties"]

      assert props["offset"]["default"] == 1
      assert props["limit"]["default"] == 2000
      assert props["line_numbers"]["default"] == true

      for name <- ~w(file_path offset limit line_numbers max_bytes) do
        assert is_binary(props[name]["description"]) and props[name]["description"] != ""
      end
    end

    test "describes the read tool, the line clip and the offset footer" do
      description = FileRead.schema().description

      assert description =~ "Use the read tool"
      assert description =~ "2000 characters"
      assert description =~ "offset"
    end

    test "documents exactly the size cap it enforces", %{tmp_dir: tmp_dir} do
      description = FileRead.schema().description
      assert [_, cap_kb] = Regex.run(~r/capped at (\d+) KB/, description)
      cap_bytes = String.to_integer(cap_kb) * 1024

      at_cap = put_file!(tmp_dir, "at_cap.txt", String.duplicate("x", cap_bytes))
      assert run(tmp_dir, %{"file_path" => at_cap}) =~ "File: at_cap.txt"

      over_cap = put_file!(tmp_dir, "over_cap.txt", String.duplicate("x", cap_bytes + 1))

      assert run(tmp_dir, %{"file_path" => over_cap}) ==
               "Error: File over_cap.txt is too large (>#{cap_kb} KB). " <>
                 "Use offset and limit parameters to read specific ranges."

      # An explicit range bypasses the cap entirely.
      assert run(tmp_dir, %{"file_path" => over_cap, "offset" => 1, "limit" => 1}) =~
               "File: over_cap.txt"
    end
  end

  describe "execute/3 - output shape" do
    test "default read renders a File: header, numbered lines and an end-of-file footer", %{
      tmp_dir: tmp_dir
    } do
      path = put_file!(tmp_dir, "a.txt", "line one\nline two\nline three")

      assert run(tmp_dir, %{"file_path" => path}) ==
               "File: a.txt\n" <>
                 "1\tline one\n" <>
                 "2\tline two\n" <>
                 "3\tline three\n" <>
                 "\n" <>
                 "(End of file - total 3 lines)"
    end

    test "no `Lines: X-Y of N` header survives — the range lives in the footer", %{
      tmp_dir: tmp_dir
    } do
      path = put_file!(tmp_dir, "a.txt", "one\ntwo")

      output = run(tmp_dir, %{"file_path" => path})

      refute output =~ "Lines:"
      assert String.starts_with?(output, "File: a.txt\n")
    end

    test "line_numbers: false drops the prefixes but keeps the footer", %{tmp_dir: tmp_dir} do
      path = put_file!(tmp_dir, "a.txt", "line one\nline two")

      assert run(tmp_dir, %{"file_path" => path, "line_numbers" => false}) ==
               "File: a.txt\n" <> "line one\nline two\n" <> "\n(End of file - total 2 lines)"
    end

    test "a partial read ends with a continuation footer naming the next offset", %{
      tmp_dir: tmp_dir
    } do
      path = put_file!(tmp_dir, "b.txt", Enum.map_join(1..10, "\n", &"line #{&1}"))

      assert run(tmp_dir, %{"file_path" => path, "offset" => 3, "limit" => 4}) ==
               "File: b.txt\n" <>
                 "3\tline 3\n" <>
                 "4\tline 4\n" <>
                 "5\tline 5\n" <>
                 "6\tline 6\n" <>
                 "\n" <>
                 "(Showing lines 3-6 of 10. Use offset=7 to continue.)"
    end

    test "a limit that runs to EOF ends with the end-of-file footer", %{tmp_dir: tmp_dir} do
      path = put_file!(tmp_dir, "c.txt", "alpha\nbeta\ngamma")

      assert run(tmp_dir, %{"file_path" => path, "offset" => 2, "limit" => 100}) ==
               "File: c.txt\n2\tbeta\n3\tgamma\n\n(End of file - total 3 lines)"
    end

    test "the File: header echoes the raw argument, not the expanded path", %{
      tmp_dir: tmp_dir
    } do
      put_file!(tmp_dir, "nested.txt", "x")

      assert run(tmp_dir, %{"file_path" => "nested.txt"}) =~ "File: nested.txt\n"
    end
  end

  describe "execute/3 - per-line clip" do
    test "a line of exactly 2000 characters is not clipped", %{tmp_dir: tmp_dir} do
      path = put_file!(tmp_dir, "long.txt", String.duplicate("a", @max_line_chars))

      body = run(tmp_dir, %{"file_path" => path, "line_numbers" => false}) |> single_line_body()

      assert body == String.duplicate("a", @max_line_chars)
      refute body =~ "line truncated"
    end

    test "a line of 2001 characters is clipped to 2000 plus the visible marker", %{
      tmp_dir: tmp_dir
    } do
      path = put_file!(tmp_dir, "long.txt", String.duplicate("a", @max_line_chars + 1))

      body = run(tmp_dir, %{"file_path" => path, "line_numbers" => false}) |> single_line_body()

      assert body == String.duplicate("a", @max_line_chars) <> @clip_marker
    end

    test "a 2048-character line is clipped too", %{tmp_dir: tmp_dir} do
      path = put_file!(tmp_dir, "long.txt", String.duplicate("a", 2048))

      body = run(tmp_dir, %{"file_path" => path, "line_numbers" => false}) |> single_line_body()

      assert body == String.duplicate("a", @max_line_chars) <> @clip_marker
    end

    test "the clip applies to numbered output as well", %{tmp_dir: tmp_dir} do
      path = put_file!(tmp_dir, "long.txt", String.duplicate("a", 2048))

      assert [_, body] = Regex.run(~r/^1\t(.*)$/m, run(tmp_dir, %{"file_path" => path}))
      assert body == String.duplicate("a", @max_line_chars) <> @clip_marker
    end

    test "clipping never splits a codepoint (astral plane)", %{tmp_dir: tmp_dir} do
      path = put_file!(tmp_dir, "emoji.txt", String.duplicate("😀", 2500))

      output = run(tmp_dir, %{"file_path" => path, "line_numbers" => false})
      body = single_line_body(output)

      assert String.valid?(output)
      assert body == String.duplicate("😀", @max_line_chars) <> @clip_marker
      assert String.length(body) == @max_line_chars + String.length(@clip_marker)
    end

    test "clipping never splits a codepoint (multi-byte latin)", %{tmp_dir: tmp_dir} do
      path = put_file!(tmp_dir, "accent.txt", String.duplicate("é", 2500))

      output = run(tmp_dir, %{"file_path" => path, "line_numbers" => false})

      assert String.valid?(output)
      assert single_line_body(output) == String.duplicate("é", @max_line_chars) <> @clip_marker
    end
  end

  describe "execute/3 - offset past end of file" do
    test "a 1-line file names its line count in the singular", %{tmp_dir: tmp_dir} do
      path = put_file!(tmp_dir, "single.txt", "single line")

      assert run(tmp_dir, %{"file_path" => path, "offset" => 300}) ==
               "Error: offset 300 is beyond the end of single.txt, which has 1 line."
    end

    test "a 500-line file names its line count in the plural", %{tmp_dir: tmp_dir} do
      path = put_file!(tmp_dir, "lines500.txt", Enum.map_join(1..500, "\n", &"l#{&1}"))

      assert run(tmp_dir, %{"file_path" => path, "offset" => 900}) ==
               "Error: offset 900 is beyond the end of lines500.txt, which has 500 lines."
    end

    test "offset exactly one past the last line is an error, not an empty body", %{
      tmp_dir: tmp_dir
    } do
      path = put_file!(tmp_dir, "three.txt", "alpha\nbeta\ngamma")

      result = run(tmp_dir, %{"file_path" => path, "offset" => 4})

      assert result == "Error: offset 4 is beyond the end of three.txt, which has 3 lines."
      refute result =~ "alpha"
      refute result =~ "File:"
    end

    test "offset on the last line still reads it", %{tmp_dir: tmp_dir} do
      path = put_file!(tmp_dir, "lines500.txt", Enum.map_join(1..500, "\n", &"l#{&1}"))

      assert run(tmp_dir, %{"file_path" => path, "offset" => 500}) ==
               "File: lines500.txt\n500\tl500\n\n(End of file - total 500 lines)"
    end
  end

  describe "execute/3 - empty file" do
    test "renders the header then a blank-line-separated guidance note", %{tmp_dir: tmp_dir} do
      path = put_file!(tmp_dir, "empty.txt", "")

      output = run(tmp_dir, %{"file_path" => path})

      assert output == "File: empty.txt\n\nFile exists but has empty contents."
      refute output =~ "Warning:"
      refute output =~ "⚠️"
      refute output =~ "Error:"
      refute output =~ "End of file"
    end

    test "an offset beyond the zero line count still renders the empty note", %{
      tmp_dir: tmp_dir
    } do
      path = put_file!(tmp_dir, "empty.txt", "")

      assert run(tmp_dir, %{"file_path" => path, "offset" => 5}) ==
               "File: empty.txt\n\nFile exists but has empty contents."
    end

    test "a BOM-only file counts as empty", %{tmp_dir: tmp_dir} do
      path = put_file!(tmp_dir, "bom_only.txt", <<0xEF, 0xBB, 0xBF>>)

      assert run(tmp_dir, %{"file_path" => path}) ==
               "File: bom_only.txt\n\nFile exists but has empty contents."
    end
  end

  describe "execute/3 - text handling regressions" do
    test "strips a UTF-8 BOM", %{tmp_dir: tmp_dir} do
      path = put_file!(tmp_dir, "bom.txt", <<0xEF, 0xBB, 0xBF>> <> "bom content\nsecond")

      assert run(tmp_dir, %{"file_path" => path}) ==
               "File: bom.txt\n1\tbom content\n2\tsecond\n\n(End of file - total 2 lines)"
    end

    test "CRLF endings keep the trailing phantom line the fast path has always reported", %{
      tmp_dir: tmp_dir
    } do
      path = put_file!(tmp_dir, "crlf.txt", "one\r\ntwo\r\n")

      assert run(tmp_dir, %{"file_path" => path}) ==
               "File: crlf.txt\n1\tone\n2\ttwo\n3\t\n\n(End of file - total 3 lines)"
    end

    test "a missing file is a prefixed error, never a crash", %{tmp_dir: tmp_dir} do
      result = run(tmp_dir, %{"file_path" => "missing.txt"})

      assert String.starts_with?(result, "Error: ")
      assert result =~ "Error reading file"
      assert result =~ "no such file or directory"
    end
  end

  describe "execute/3 - argument validation" do
    setup %{tmp_dir: tmp_dir} do
      {:ok, %{path: put_file!(tmp_dir, "x.txt", "content")}}
    end

    test "missing file_path", %{tmp_dir: tmp_dir} do
      assert run(tmp_dir, %{}) ==
               "Error: Missing required argument 'file_path'. Please provide a valid value."
    end

    test "offset must be a positive integer", %{tmp_dir: tmp_dir, path: path} do
      assert run(tmp_dir, %{"file_path" => path, "offset" => 0}) ==
               "Error: Argument 'offset' must be a positive integer, got: 0"
    end

    test "limit must be a positive integer", %{tmp_dir: tmp_dir, path: path} do
      assert run(tmp_dir, %{"file_path" => path, "limit" => "ten"}) ==
               "Error: Argument 'limit' must be a positive integer, got: \"ten\""
    end

    test "line_numbers must be a boolean", %{tmp_dir: tmp_dir, path: path} do
      assert run(tmp_dir, %{"file_path" => path, "line_numbers" => "yes"}) ==
               "Error: Argument 'line_numbers' must be a boolean, got: \"yes\""
    end

    test "the first failing argument wins", %{tmp_dir: tmp_dir, path: path} do
      assert run(tmp_dir, %{"file_path" => path, "offset" => 0, "limit" => 0}) ==
               "Error: Argument 'offset' must be a positive integer, got: 0"
    end
  end
end
