defmodule EvoDash.AttachedFileTest do
  use ExUnit.Case, async: true

  alias EvoDash.AttachedFile

  describe "read/1 — plain text" do
    test ".txt file returns trimmed content" do
      path = write_tmp!("prompt.txt", "  Implement the feature.\n\n  ")
      assert {:ok, "Implement the feature."} = AttachedFile.read(path)
    end

    test ".md file returns content" do
      path = write_tmp!("prompt.md", "# Objective\n\nMake it faster")
      assert {:ok, "# Objective\n\nMake it faster"} = AttachedFile.read(path)
    end

    test "missing file returns :enoent" do
      path =
        Path.join(
          System.tmp_dir!(),
          "prompt_file_test_missing_#{System.unique_integer([:positive])}.txt"
        )

      assert {:error, :enoent} = AttachedFile.read(path)
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

      assert {:ok, text} = AttachedFile.read(path)
      assert text == "Hello & welcome\nSecond & line\n\nTab:\tafter\nEscaped: &#38;"
    end

    test "file that is not a zip returns {:error, {:invalid, _}}" do
      path = write_tmp!("not_a_docx.docx", "this is definitely not a zip archive")
      assert {:error, {:invalid, _}} = AttachedFile.read(path)
    end

    test "zip without word/document.xml returns {:error, {:invalid, _}}" do
      zip = docx_zip("<w:other>no document here</w:other>", ~c"word/other.xml")
      path = write_tmp!("no_document.docx", zip)
      assert {:error, {:invalid, _}} = AttachedFile.read(path)
    end

    test "missing .docx file returns :enoent" do
      path =
        Path.join(
          System.tmp_dir!(),
          "prompt_file_test_missing_#{System.unique_integer([:positive])}.docx"
        )

      assert {:error, :enoent} = AttachedFile.read(path)
    end
  end

  describe "read/1 — .pdf" do
    test "multi-page PDF returns page texts with conversion note and page markers" do
      path = write_tmp!("multi_page.pdf", pdf_binary(["Hello page one", "Hello page two"]))

      assert {:ok, text} = AttachedFile.read(path)

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
      assert {:ok, ^text} = AttachedFile.read(path)
    end

    test "single-page PDF content appears under the page 1 marker" do
      path = write_tmp!("single_page.pdf", pdf_binary(["Only page text"]))

      assert {:ok, text} = AttachedFile.read(path)
      assert text =~ "## Page 1\n\nOnly page text"
    end

    test "PDF with no extractable text (scanned/image-only) returns {:error, {:empty, _}}" do
      path = write_tmp!("empty.pdf", pdf_binary([]))

      assert {:error, {:empty, reason}} = AttachedFile.read(path)
      assert reason =~ "OCR"
    end

    test "file that is not a PDF returns {:error, {:invalid, :not_a_pdf}}" do
      path = write_tmp!("fake.pdf", "this is definitely not a PDF document")
      assert {:error, {:invalid, :not_a_pdf}} = AttachedFile.read(path)
    end

    test "truncated PDF is recovered (recover: true) and yields no text" do
      # Missing xref/objects: the reader's recovery mode tolerates this and
      # yields an empty document rather than a fatal error.
      path = write_tmp!("truncated.pdf", "%PDF-1.7\n%%EOF\n")
      assert {:error, {:empty, _}} = AttachedFile.read(path)
    end

    test "missing .pdf file returns :enoent" do
      path =
        Path.join(
          System.tmp_dir!(),
          "prompt_file_test_missing_#{System.unique_integer([:positive])}.pdf"
        )

      assert {:error, :enoent} = AttachedFile.read(path)
    end
  end

  describe "read_kind/2 — image" do
    test ".png returns image/png with the exact raw bytes" do
      bytes = <<0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, 0x00, 0x01, 0x02, 0x03>>
      path = write_tmp!("pixel.png", bytes)

      assert {:ok, %{type: "image", media_type: "image/png", bytes: ^bytes}} =
               AttachedFile.read_kind(path, "image")
    end

    test ".jpg returns image/jpeg with the exact raw bytes" do
      bytes = <<0xFF, 0xD8, 0xFF, 0xE0, "JFIF", 0x00, 0x01>>
      path = write_tmp!("photo.jpg", bytes)

      assert {:ok, %{type: "image", media_type: "image/jpeg", bytes: ^bytes}} =
               AttachedFile.read_kind(path, "image")
    end

    test ".jpeg returns image/jpeg with the exact raw bytes" do
      bytes = <<0xFF, 0xD8, 0xFF, 0xE1, "EXIF", 0x00, 0x00>>
      path = write_tmp!("photo.jpeg", bytes)

      assert {:ok, %{type: "image", media_type: "image/jpeg", bytes: ^bytes}} =
               AttachedFile.read_kind(path, "image")
    end

    test ".gif returns image/gif with the exact raw bytes" do
      bytes = <<"GIF89a", 0x01, 0x00, 0x01, 0x00>>
      path = write_tmp!("anim.gif", bytes)

      assert {:ok, %{type: "image", media_type: "image/gif", bytes: ^bytes}} =
               AttachedFile.read_kind(path, "image")
    end

    test ".webp returns image/webp with the exact raw bytes" do
      bytes = <<"RIFF", 0x00, 0x00, 0x00, 0x00, "WEBP", 0x0F, 0x00>>
      path = write_tmp!("pic.webp", bytes)

      assert {:ok, %{type: "image", media_type: "image/webp", bytes: ^bytes}} =
               AttachedFile.read_kind(path, "image")
    end

    test ".bmp returns image/bmp with the exact raw bytes" do
      bytes = <<"BM", 0x0A, 0x00, 0x00, 0x00>>
      path = write_tmp!("pic.bmp", bytes)

      assert {:ok, %{type: "image", media_type: "image/bmp", bytes: ^bytes}} =
               AttachedFile.read_kind(path, "image")
    end
  end

  describe "read_kind/2 — audio" do
    test ".mp3 returns audio/mpeg with the exact raw bytes" do
      bytes = <<0x49, 0x44, 0x33, 0x03, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00>>
      path = write_tmp!("song.mp3", bytes)

      assert {:ok, %{type: "audio", media_type: "audio/mpeg", bytes: ^bytes}} =
               AttachedFile.read_kind(path, "audio")
    end

    test ".wav returns audio/wav with the exact raw bytes" do
      bytes = <<"RIFF", 0x24, 0x00, 0x00, 0x00, "WAVE">>
      path = write_tmp!("sound.wav", bytes)

      assert {:ok, %{type: "audio", media_type: "audio/wav", bytes: ^bytes}} =
               AttachedFile.read_kind(path, "audio")
    end

    test ".ogg returns audio/ogg with the exact raw bytes" do
      bytes = <<"OggS", 0x00, 0x02, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00>>
      path = write_tmp!("track.ogg", bytes)

      assert {:ok, %{type: "audio", media_type: "audio/ogg", bytes: ^bytes}} =
               AttachedFile.read_kind(path, "audio")
    end

    test ".m4a returns audio/mp4 with the exact raw bytes" do
      bytes = <<0x00, 0x00, 0x00, 0x20, "ftypM4A ", 0x00, 0x00, 0x00, 0x00>>
      path = write_tmp!("track.m4a", bytes)

      assert {:ok, %{type: "audio", media_type: "audio/mp4", bytes: ^bytes}} =
               AttachedFile.read_kind(path, "audio")
    end

    test ".flac returns audio/flac with the exact raw bytes" do
      bytes = <<"fLaC", 0x00, 0x00, 0x00, 0x22, 0x00>>
      path = write_tmp!("track.flac", bytes)

      assert {:ok, %{type: "audio", media_type: "audio/flac", bytes: ^bytes}} =
               AttachedFile.read_kind(path, "audio")
    end
  end

  describe "read_kind/2 — unknown kind" do
    test "video kind is rejected regardless of the file extension" do
      path = write_tmp!("sound.png", "not really an image")
      assert {:error, {:unsupported_kind, "video"}} = AttachedFile.read_kind(path, "video")

      path = write_tmp!("song.mp3", "not really audio")
      assert {:error, {:unsupported_kind, "video"}} = AttachedFile.read_kind(path, "video")
    end

    test "text kind is rejected regardless of the file extension" do
      path = write_tmp!("sound.png", "not really an image")
      assert {:error, {:unsupported_kind, "text"}} = AttachedFile.read_kind(path, "text")
    end

    test "non-binary kind argument hits the same unsupported_kind clause" do
      path = write_tmp!("sound.png", "not really an image")
      assert {:error, {:unsupported_kind, :image}} = AttachedFile.read_kind(path, :image)
    end
  end

  describe "read_kind/2 — unsupported extension" do
    test "image kind on a .txt file returns the lowercase ext incl. the dot" do
      path = write_tmp!("notes.txt", "plain text")
      assert {:error, {:unsupported_extension, ".txt"}} = AttachedFile.read_kind(path, "image")
    end

    test "audio kind on a .png file returns the lowercase ext incl. the dot" do
      path = write_tmp!("picture.png", "not really an image")
      assert {:error, {:unsupported_extension, ".png"}} = AttachedFile.read_kind(path, "audio")
    end
  end

  describe "read_kind/2 — missing file" do
    test "missing .png file with image kind returns :enoent" do
      path =
        Path.join(
          System.tmp_dir!(),
          "prompt_file_test_missing_#{System.unique_integer([:positive])}.png"
        )

      assert {:error, :enoent} = AttachedFile.read_kind(path, "image")
    end
  end

  describe "read_kind/2 — size cap" do
    test "a file of exactly 15 MiB passes the cap" do
      path = write_tmp!("big.png", :binary.copy(<<0>>, 15 * 1024 * 1024))

      assert {:ok, %{type: "image", media_type: "image/png", bytes: bytes}} =
               AttachedFile.read_kind(path, "image")

      assert byte_size(bytes) == 15 * 1024 * 1024
    end

    test "one byte over 15 MiB fails with file_too_large" do
      over_cap = 15 * 1024 * 1024 + 1
      path = write_tmp!("bigger.png", :binary.copy(<<0>>, over_cap))

      assert {:error, {:file_too_large, ^over_cap}} = AttachedFile.read_kind(path, "image")
    end
  end

  describe "media_type_for/1" do
    test "image family — extension with dot, without dot, and uppercase" do
      assert AttachedFile.media_type_for(".png") == "image/png"
      assert AttachedFile.media_type_for("png") == "image/png"
      assert AttachedFile.media_type_for(".PNG") == "image/png"
    end

    test "audio family — extension with dot, without dot, and uppercase" do
      assert AttachedFile.media_type_for(".mp3") == "audio/mpeg"
      assert AttachedFile.media_type_for("mp3") == "audio/mpeg"
      assert AttachedFile.media_type_for(".MP3") == "audio/mpeg"
    end

    test "unknown extension returns nil" do
      assert AttachedFile.media_type_for(".xyz") == nil
      assert AttachedFile.media_type_for("txt") == nil
    end

    test "non-binary input returns nil" do
      assert AttachedFile.media_type_for(:png) == nil
      assert AttachedFile.media_type_for(nil) == nil
    end
  end

  describe "read/1 vs read_kind/2" do
    test ".png via read/1 is treated as plain text (text pipeline catch-all)" do
      path = write_tmp!("trap.png", "\n  not a real image, just text content  \n")

      assert {:ok, "not a real image, just text content"} = AttachedFile.read(path)

      # The same file read through read_kind/2 returns raw bytes untouched.
      assert {:ok, %{type: "image", media_type: "image/png"}} =
               AttachedFile.read_kind(path, "image")
    end
  end

  describe "describe_error/2" do
    test "enoent" do
      assert AttachedFile.describe_error(:enoent, "obj.txt") == "File not found: obj.txt"
    end

    test "other POSIX atoms" do
      assert AttachedFile.describe_error(:eacces, "obj.txt") ==
               "Failed to read file: obj.txt (:eacces)"
    end

    test "invalid docx" do
      assert AttachedFile.describe_error({:invalid, "missing word/document.xml"}, "obj.docx") ==
               "Invalid .docx file: missing word/document.xml"
    end

    test "empty docx" do
      assert AttachedFile.describe_error({:empty, "no text runs found"}, "obj.docx") ==
               "No text found in .docx file: no text runs found"
    end

    test "invalid pdf — not a pdf" do
      msg = AttachedFile.describe_error({:invalid, :not_a_pdf}, "obj.pdf")
      assert msg == "Invalid .pdf file: not a valid PDF (file does not contain PDF data)"
    end

    test "invalid pdf — encrypted without password" do
      msg = AttachedFile.describe_error({:invalid, :encrypted_password_required}, "obj.pdf")
      assert msg =~ "Invalid .pdf file:"
      assert msg =~ "password-protected"
    end

    test "empty pdf" do
      reason = "no extractable text found — scanned or image-only PDFs are not supported (no OCR)"
      msg = AttachedFile.describe_error({:empty, reason}, "obj.pdf")
      assert msg == "No text found in .pdf file: #{reason}"
      assert msg =~ "OCR"
    end

    test "bare posix atom from pdf path" do
      assert AttachedFile.describe_error(:enoent, "obj.pdf") == "File not found: obj.pdf"
    end

    test "unsupported extension" do
      assert AttachedFile.describe_error({:unsupported_extension, ".txt"}, "obj.txt") ==
               "Unsupported file type for attachment: .txt"
    end

    test "file too large" do
      msg = AttachedFile.describe_error({:file_too_large, 15 * 1024 * 1024 + 1}, "photo.png")

      assert msg ==
               "File is too large (max 15 MiB): photo.png (#{15 * 1024 * 1024 + 1} bytes)"
    end

    test "unsupported kind" do
      assert AttachedFile.describe_error({:unsupported_kind, "video"}, "obj.txt") ==
               "Unsupported attachment kind: \"video\""
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
