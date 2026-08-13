defmodule EvoGit.PromptFileTest do
  use ExUnit.Case, async: true

  alias EvoGit.PromptFile

  describe "read/1 — plain text" do
    test ".txt file returns trimmed content" do
      path = write_tmp!("prompt.txt", "  Implement the feature.\n\n  ")
      assert {:ok, "Implement the feature."} = PromptFile.read(path)
    end

    test ".md file returns content" do
      path = write_tmp!("prompt.md", "# Objective\n\nMake it faster")
      assert {:ok, "# Objective\n\nMake it faster"} = PromptFile.read(path)
    end

    test "missing file returns :enoent" do
      path =
        Path.join(
          System.tmp_dir!(),
          "prompt_file_test_missing_#{System.unique_integer([:positive])}.txt"
        )

      assert {:error, :enoent} = PromptFile.read(path)
    end
  end

  describe "read/1 — .docx" do
    test "extracts paragraphs, tabs and entities" do
      xml = """
      <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
      <w:document xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main">
        <w:body>
          <w:p>
            <w:r><w:t>Hello &amp; welcome</w:t></w:r>
            <w:r><w:instrText> PAGE </w:instrText></w:r>
          </w:p>
          <w:p><w:r><w:t>Second &#38; line</w:t></w:r></w:p>
          <w:p/>
          <w:p>
            <w:r><w:t>Tab:</w:t></w:r>
            <w:r><w:tab/><w:t>after</w:t></w:r>
          </w:p>
          <w:p><w:r><w:t>Escaped: &amp;#38;</w:t></w:r></w:p>
        </w:body>
      </w:document>
      """

      path = write_tmp!("prompt.docx", docx_zip(xml))

      assert {:ok, text} = PromptFile.read(path)
      assert text == "Hello & welcome\nSecond & line\n\nTab:\tafter\nEscaped: &#38;"
    end

    test "file that is not a zip returns {:error, {:invalid, _}}" do
      path = write_tmp!("not_a_docx.docx", "this is definitely not a zip archive")
      assert {:error, {:invalid, _}} = PromptFile.read(path)
    end

    test "zip without word/document.xml returns {:error, {:invalid, _}}" do
      zip = docx_zip("<w:other>no document here</w:other>", ~c"word/other.xml")
      path = write_tmp!("no_document.docx", zip)
      assert {:error, {:invalid, _}} = PromptFile.read(path)
    end

    test "missing .docx file returns :enoent" do
      path =
        Path.join(
          System.tmp_dir!(),
          "prompt_file_test_missing_#{System.unique_integer([:positive])}.docx"
        )

      assert {:error, :enoent} = PromptFile.read(path)
    end
  end

  describe "read/1 — .pdf" do
    test "returns {:error, {:unsupported, \"pdf\"}}" do
      path = write_tmp!("prompt.pdf", "%PDF-1.4 fake content")
      assert {:error, {:unsupported, "pdf"}} = PromptFile.read(path)
    end
  end

  describe "describe_error/2" do
    test "enoent" do
      assert PromptFile.describe_error(:enoent, "obj.txt") == "File not found: obj.txt"
    end

    test "other POSIX atoms" do
      assert PromptFile.describe_error(:eacces, "obj.txt") ==
               "Failed to read file: obj.txt (:eacces)"
    end

    test "unsupported pdf" do
      msg = PromptFile.describe_error({:unsupported, "pdf"}, "obj.pdf")
      assert msg =~ "not supported"
      assert msg =~ "pdftotext"
      assert msg =~ ".txt/.docx"
    end

    test "invalid docx" do
      assert PromptFile.describe_error({:invalid, "missing word/document.xml"}, "obj.docx") ==
               "Invalid .docx file: missing word/document.xml"
    end

    test "empty docx" do
      assert PromptFile.describe_error({:empty, "no text runs found"}, "obj.docx") ==
               "No text found in .docx file: no text runs found"
    end
  end

  ## Helpers

  defp docx_zip(xml, entry_name \\ ~c"word/document.xml") do
    {:ok, {_, zip}} = :zip.create(~c"docx.zip", [{entry_name, xml}], [:memory])
    zip
  end

  defp write_tmp!(name, binary) do
    path =
      Path.join(
        System.tmp_dir!(),
        "prompt_file_test_#{System.unique_integer([:positive])}_#{name}"
      )

    File.write!(path, binary)
    path
  end
end
