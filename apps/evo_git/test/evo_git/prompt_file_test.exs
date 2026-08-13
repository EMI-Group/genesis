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
    test "multi-page PDF returns page texts with conversion note and page markers" do
      path = write_tmp!("multi_page.pdf", pdf_binary(["Hello page one", "Hello page two"]))

      assert {:ok, text} = PromptFile.read(path)

      # Conversion note mentioning the file basename
      assert text =~ "converted from a PDF file"
      assert text =~ Path.basename(path)
      assert text =~ "PDF text extraction can be imperfect"

      # Page markers in order, page content present
      assert text =~ "## Page 1"
      assert text =~ "## Page 2"
      assert text =~ "Hello page one"
      assert text =~ "Hello page two"
      assert String.split(text, "## Page 1") |> length() == 2

      # Deterministic and trimmed
      assert text == String.trim(text)
      assert {:ok, ^text} = PromptFile.read(path)
    end

    test "single-page PDF content appears under the page 1 marker" do
      path = write_tmp!("single_page.pdf", pdf_binary(["Only page text"]))

      assert {:ok, text} = PromptFile.read(path)
      assert text =~ "## Page 1\n\nOnly page text"
    end

    test "PDF with no extractable text (scanned/image-only) returns {:error, {:empty, _}}" do
      path = write_tmp!("empty.pdf", pdf_binary([]))

      assert {:error, {:empty, reason}} = PromptFile.read(path)
      assert reason =~ "OCR"
    end

    test "file that is not a PDF returns {:error, {:invalid, :not_a_pdf}}" do
      path = write_tmp!("fake.pdf", "this is definitely not a PDF document")
      assert {:error, {:invalid, :not_a_pdf}} = PromptFile.read(path)
    end

    test "truncated PDF is recovered (recover: true) and yields no text" do
      # Missing xref/objects: the reader's recovery mode tolerates this and
      # yields an empty document rather than a fatal error.
      path = write_tmp!("truncated.pdf", "%PDF-1.7\n%%EOF\n")
      assert {:error, {:empty, _}} = PromptFile.read(path)
    end

    test "missing .pdf file returns :enoent" do
      path =
        Path.join(
          System.tmp_dir!(),
          "prompt_file_test_missing_#{System.unique_integer([:positive])}.pdf"
        )

      assert {:error, :enoent} = PromptFile.read(path)
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

    test "invalid docx" do
      assert PromptFile.describe_error({:invalid, "missing word/document.xml"}, "obj.docx") ==
               "Invalid .docx file: missing word/document.xml"
    end

    test "empty docx" do
      assert PromptFile.describe_error({:empty, "no text runs found"}, "obj.docx") ==
               "No text found in .docx file: no text runs found"
    end

    test "invalid pdf — not a pdf" do
      msg = PromptFile.describe_error({:invalid, :not_a_pdf}, "obj.pdf")
      assert msg == "Invalid .pdf file: not a valid PDF (file does not contain PDF data)"
    end

    test "invalid pdf — encrypted without password" do
      msg = PromptFile.describe_error({:invalid, :encrypted_password_required}, "obj.pdf")
      assert msg =~ "Invalid .pdf file:"
      assert msg =~ "password-protected"
    end

    test "empty pdf" do
      reason = "no extractable text found — scanned or image-only PDFs are not supported (no OCR)"
      msg = PromptFile.describe_error({:empty, reason}, "obj.pdf")
      assert msg == "No text found in .pdf file: #{reason}"
      assert msg =~ "OCR"
    end

    test "bare posix atom from pdf path" do
      assert PromptFile.describe_error(:enoent, "obj.pdf") == "File not found: obj.pdf"
    end
  end

  ## Helpers

  # Builds a real PDF binary with one page per text (pure-BEAM writer).
  # An empty list yields a single blank page (no text) — simulates an
  # image-only/scanned PDF.
  defp pdf_binary([]), do: Pdf.build([], & &1) |> Pdf.export()

  defp pdf_binary(page_texts) do
    pdf =
      Pdf.build([], fn pdf ->
        pdf
        |> Pdf.set_font("Helvetica", 12)
        |> Pdf.text_at({72, 700}, hd(page_texts))
      end)

    pdf =
      Enum.reduce(tl(page_texts), pdf, fn text, doc ->
        doc
        |> Pdf.add_page(:a4)
        |> Pdf.set_font("Helvetica", 12)
        |> Pdf.text_at({72, 700}, text)
      end)

    Pdf.export(pdf)
  end

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
