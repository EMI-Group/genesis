defmodule EvoDash.AttachedFileTest do
  use ExUnit.Case, async: true

  alias EvoDash.AttachedFile

  # The pinned image/audio allowlist: {file name, exact raw bytes, media type}.
  # Each case asserts the FULL round-trip (type + media_type + untouched bytes),
  # so the family is data-driven instead of one test per extension.
  @image_cases [
    {"pixel.png", <<0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, 0x00, 0x01, 0x02, 0x03>>,
     "image/png"},
    {"photo.jpg", <<0xFF, 0xD8, 0xFF, 0xE0, "JFIF", 0x00, 0x01>>, "image/jpeg"},
    {"photo.jpeg", <<0xFF, 0xD8, 0xFF, 0xE1, "EXIF", 0x00, 0x00>>, "image/jpeg"},
    {"anim.gif", <<"GIF89a", 0x01, 0x00, 0x01, 0x00>>, "image/gif"},
    {"pic.webp", <<"RIFF", 0x00, 0x00, 0x00, 0x00, "WEBP", 0x0F, 0x00>>, "image/webp"},
    {"pic.bmp", <<"BM", 0x0A, 0x00, 0x00, 0x00>>, "image/bmp"}
  ]

  @audio_cases [
    {"song.mp3", <<0x49, 0x44, 0x33, 0x03, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00>>, "audio/mpeg"},
    {"sound.wav", <<"RIFF", 0x24, 0x00, 0x00, 0x00, "WAVE">>, "audio/wav"},
    {"track.ogg", <<"OggS", 0x00, 0x02, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00>>, "audio/ogg"},
    {"track.m4a", <<0x00, 0x00, 0x00, 0x20, "ftypM4A ", 0x00, 0x00, 0x00, 0x00>>, "audio/mp4"},
    {"track.flac", <<"fLaC", 0x00, 0x00, 0x00, 0x22, 0x00>>, "audio/flac"}
  ]

  @fifteen_mib 15 * 1024 * 1024

  describe "read/1 — plain text" do
    test ".txt is trimmed, .md is returned as-is" do
      assert {:ok, "Implement the feature."} =
               AttachedFile.read(write_tmp!("prompt.txt", "  Implement the feature.\n\n  "))

      assert {:ok, "# Objective\n\nMake it faster"} =
               AttachedFile.read(write_tmp!("prompt.md", "# Objective\n\nMake it faster"))
    end

    test "missing file returns :enoent" do
      assert {:error, :enoent} = AttachedFile.read(missing_path("txt"))
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

    test "not-a-zip and zip-without-word/document.xml are {:invalid, _}; missing file is :enoent" do
      not_zip = write_tmp!("not_a_docx.docx", "this is definitely not a zip archive")
      assert {:error, {:invalid, _}} = AttachedFile.read(not_zip)

      no_document =
        write_tmp!(
          "no_document.docx",
          docx_zip("<w:other>no document here</w:other>", ~c"word/other.xml")
        )

      assert {:error, {:invalid, _}} = AttachedFile.read(no_document)
      assert {:error, :enoent} = AttachedFile.read(missing_path("docx"))
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

      # A single-page PDF puts its text under the page 1 marker.
      single = write_tmp!("single_page.pdf", pdf_binary(["Only page text"]))
      assert {:ok, single_text} = AttachedFile.read(single)
      assert single_text =~ "## Page 1\n\nOnly page text"
    end

    test "no extractable text (scanned / truncated) is {:empty, _} mentioning OCR" do
      for {name, binary} <- [
            {"empty.pdf", pdf_binary([])},
            # Missing xref/objects: the reader's recovery mode tolerates this and
            # yields an empty document rather than a fatal error.
            {"truncated.pdf", "%PDF-1.7\n%%EOF\n"}
          ] do
        assert {:error, {:empty, reason}} = AttachedFile.read(write_tmp!(name, binary))
        assert reason =~ "OCR"
      end
    end

    test "a non-PDF is {:invalid, :not_a_pdf}; a missing file is :enoent" do
      fake = write_tmp!("fake.pdf", "this is definitely not a PDF document")
      assert {:error, {:invalid, :not_a_pdf}} = AttachedFile.read(fake)
      assert {:error, :enoent} = AttachedFile.read(missing_path("pdf"))
    end
  end

  describe "read_kind/2 — pinned extension → media type allowlist" do
    test "image kinds return image/<subtype> with the exact raw bytes" do
      for {name, bytes, media_type} <- @image_cases do
        path = write_tmp!(name, bytes)

        assert {:ok, %{type: "image", media_type: ^media_type, bytes: ^bytes}} =
                 AttachedFile.read_kind(path, "image"),
               "expected #{name} → #{media_type}"
      end
    end

    test "audio kinds return audio/<subtype> with the exact raw bytes" do
      for {name, bytes, media_type} <- @audio_cases do
        path = write_tmp!(name, bytes)

        assert {:ok, %{type: "audio", media_type: ^media_type, bytes: ^bytes}} =
                 AttachedFile.read_kind(path, "audio"),
               "expected #{name} → #{media_type}"
      end
    end
  end

  describe "read_kind/2 — rejections" do
    test "a kind other than image/audio is rejected regardless of the file extension" do
      path = write_tmp!("sound.png", "not really an image")

      assert {:error, {:unsupported_kind, "video"}} = AttachedFile.read_kind(path, "video")
      assert {:error, {:unsupported_kind, "text"}} = AttachedFile.read_kind(path, "text")
      # Non-binary kind hits the same clause (no String.to_atom guessing).
      assert {:error, {:unsupported_kind, :image}} = AttachedFile.read_kind(path, :image)
    end

    test "an extension outside the kind's allowlist reports the lowercase ext incl. the dot" do
      txt = write_tmp!("notes.txt", "plain text")
      assert {:error, {:unsupported_extension, ".txt"}} = AttachedFile.read_kind(txt, "image")

      png = write_tmp!("picture.png", "not really an image")
      assert {:error, {:unsupported_extension, ".png"}} = AttachedFile.read_kind(png, "audio")
    end

    test "missing file with an allowed extension returns :enoent" do
      assert {:error, :enoent} = AttachedFile.read_kind(missing_path("png"), "image")
    end
  end

  describe "read_kind/2 — 15 MiB size cap" do
    test "exactly 15 MiB passes the cap; one byte over fails with file_too_large" do
      # Sparse files: the SIZE is what the cap reads, so the test never has to
      # materialize a 15 MiB binary in the test process.
      at_cap = sparse_file!("big.png", @fifteen_mib)

      assert {:ok, %{type: "image", media_type: "image/png", bytes: bytes}} =
               AttachedFile.read_kind(at_cap, "image")

      assert byte_size(bytes) == @fifteen_mib

      over_cap = @fifteen_mib + 1
      over = sparse_file!("bigger.png", over_cap)

      assert {:error, {:file_too_large, ^over_cap}} = AttachedFile.read_kind(over, "image")
    end
  end

  describe "media_type_for/1" do
    test "accepts the extension with or without the dot, in any case" do
      for ext <- [".png", "png", ".PNG"] do
        assert AttachedFile.media_type_for(ext) == "image/png", "expected #{inspect(ext)}"
      end

      for ext <- [".mp3", "mp3", ".MP3"] do
        assert AttachedFile.media_type_for(ext) == "audio/mpeg", "expected #{inspect(ext)}"
      end
    end

    test "unknown extensions and non-binary input return nil" do
      assert AttachedFile.media_type_for(".xyz") == nil
      assert AttachedFile.media_type_for("txt") == nil
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
    test "POSIX atoms, .docx outcomes and the generic fallback" do
      assert AttachedFile.describe_error(:enoent, "obj.txt") == "File not found: obj.txt"
      assert AttachedFile.describe_error(:enoent, "obj.pdf") == "File not found: obj.pdf"

      assert AttachedFile.describe_error(:eacces, "obj.txt") ==
               "Failed to read file: obj.txt (:eacces)"

      assert AttachedFile.describe_error({:invalid, "missing word/document.xml"}, "obj.docx") ==
               "Invalid .docx file: missing word/document.xml"

      assert AttachedFile.describe_error({:empty, "no text runs found"}, "obj.docx") ==
               "No text found in .docx file: no text runs found"
    end

    test ".pdf outcomes" do
      assert AttachedFile.describe_error({:invalid, :not_a_pdf}, "obj.pdf") ==
               "Invalid .pdf file: not a valid PDF (file does not contain PDF data)"

      encrypted = AttachedFile.describe_error({:invalid, :encrypted_password_required}, "obj.pdf")
      assert encrypted =~ "Invalid .pdf file:"
      assert encrypted =~ "password-protected"

      reason = "no extractable text found — scanned or image-only PDFs are not supported (no OCR)"
      msg = AttachedFile.describe_error({:empty, reason}, "obj.pdf")
      assert msg == "No text found in .pdf file: #{reason}"
      assert msg =~ "OCR"
    end

    test "attachment-pipeline outcomes" do
      assert AttachedFile.describe_error({:unsupported_extension, ".txt"}, "obj.txt") ==
               "Unsupported file type for attachment: .txt"

      assert AttachedFile.describe_error({:file_too_large, @fifteen_mib + 1}, "photo.png") ==
               "File is too large (max 15 MiB): photo.png (#{@fifteen_mib + 1} bytes)"

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

  defp missing_path(ext) do
    Path.join(
      System.tmp_dir!(),
      "prompt_file_test_missing_#{System.unique_integer([:positive])}.#{ext}"
    )
  end

  defp write_tmp!(name, binary) do
    path = tmp_path(name)
    File.write!(path, binary)
    path
  end

  # A file of exactly `size` bytes with no real data blocks (seek past the end,
  # one byte written). Only the SIZE matters to the cap, so this avoids
  # allocating a 15 MiB binary just to write it.
  defp sparse_file!(name, size) do
    path = tmp_path(name)
    {:ok, fd} = :file.open(path, [:write, :raw, :binary])
    {:ok, _} = :file.position(fd, size - 1)
    :ok = :file.write(fd, <<0>>)
    :ok = :file.close(fd)
    path
  end

  defp tmp_path(name) do
    Path.join(
      System.tmp_dir!(),
      "prompt_file_test_#{System.unique_integer([:positive])}_#{name}"
    )
  end
end
