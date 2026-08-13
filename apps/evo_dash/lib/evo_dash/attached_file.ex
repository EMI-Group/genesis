defmodule EvoDash.AttachedFile do
  @moduledoc """
  Reads attached objective files picked from the dashboard's objective editor
  (the attach-file '+' button) — it reads local files on the dashboard node.

  Supported formats:
    * `.txt`, `.md`, or any other plain-text file — read verbatim and trimmed
    * `.docx` — Word documents, extracted to plain text using OTP stdlib only
      (`:zip` + regexes; no third-party dependencies)
    * `.pdf` — PDF documents, extracted to Markdown via the pure-BEAM `ex_pdf`
      reader (`Pdf.Reader`). Each page becomes a `## Page N` heading; a note
      explaining the conversion is prepended so LLM agents can account for
      extraction artifacts.

  Known .docx limitations:
    * Only `word/document.xml` is read — headers, footers, footnotes and
      comments are ignored.
    * Field codes (`w:instrText`, e.g. PAGE fields) are stripped.
    * XML entities are unescaped; whitespace inside text runs is preserved
      (`xml:space="preserve"`).

  Known .pdf limitations:
    * Extraction quality varies with the generator: spacing/word breaks can be
      imperfect (columns, tables and layouts are flattened line-by-line).
    * Scanned / image-only PDFs contain no embedded text and are NOT supported
      (no OCR) — they return `{:empty, _}`.
    * Password-protected PDFs are not supported (no password option is
      exposed) — they return `{:invalid, {:encrypted_*, ...}}`.
    * Opened with `recover: true`, so recoverable xref/page-tree corruption is
      tolerated; unrecoverable corruption returns `{:invalid, reason}`.

  Error shapes from `read/1`:
    * bare POSIX atom (`:enoent`, `:eacces`, ...) — plain file/PDF read failed
      (propagated from `File.read/1`; a defensive `{:io_error, posix}` from
      `Pdf.Reader` is unwrapped to the bare posix atom)
    * `{:invalid, reason}` — malformed input: not a valid ZIP / no
      `word/document.xml` (.docx), or not a valid / corrupt / encrypted PDF
      (.pdf). `reason` is a string for .docx, an `ex_pdf` reason atom or tuple
      for .pdf (e.g. `:not_a_pdf`, `{:malformed, ...}`,
      `:encrypted_password_required`).
    * `{:empty, reason}` — valid file but no text found (empty .docx; scanned /
      image-only .pdf without OCR)
  """

  @doc """
  Reads an attached objective file.

  Returns `{:ok, text}` or `{:error, reason}`. `reason` is a bare POSIX atom
  (`:enoent`, `:eacces`, ...) for plain files (propagated from `File.read/1`),
  or one of the shapes documented in the moduledoc (`{:invalid, reason}` or
  `{:empty, reason}`).
  """
  def read(path) do
    case path |> Path.extname() |> String.downcase() do
      ".docx" -> read_docx(path)
      ".pdf" -> read_pdf(path)
      _ -> read_text(path)
    end
  end

  @doc "Builds a user-ready error message for a `read/1` error."
  def describe_error(error, path) do
    case error do
      :enoent ->
        "File not found: #{path}"

      :enotdir ->
        "File not found: #{path}"

      {:invalid, reason} when is_binary(reason) ->
        "Invalid .docx file: #{reason}"

      {:invalid, reason} ->
        "Invalid .pdf file: #{pdf_reason_msg(reason)}"

      {:empty, "no text runs found"} ->
        "No text found in .docx file: no text runs found"

      {:empty, reason} when is_binary(reason) ->
        "No text found in .pdf file: #{reason}"

      {:empty, reason} ->
        "No text found in file: #{reason_str(reason)}"

      reason when is_atom(reason) ->
        "Failed to read file: #{path} (#{inspect(reason)})"

      reason ->
        "Failed to read file: #{path} (#{inspect(reason)})"
    end
  end

  ## Plain text

  defp read_text(path) do
    case File.read(path) do
      {:ok, binary} -> {:ok, String.trim(binary)}
      {:error, reason} -> {:error, reason}
    end
  end

  ## .docx

  # Internal placeholders for converted w:tab/w:br markers — real document
  # text never contains these control chars, and `\s`-based cleanup of
  # inter-run segments must not strip the markers.
  @tab_marker "\u0001"
  @br_marker "\u0002"

  defp read_docx(path) do
    with {:ok, binary} <- File.read(path) do
      extract_docx(binary)
    end
  end

  defp extract_docx(binary) do
    case unzip(binary) do
      {:ok, entries} ->
        case find_document_xml(entries) do
          {:ok, xml} -> xml_to_text(xml)
          {:error, reason} -> {:error, {:invalid, reason}}
        end

      {:error, reason} ->
        {:error, {:invalid, reason}}
    end
  end

  defp unzip(binary) do
    # :zip.extract returns {:error, {:EXIT, ...}} for malformed archives; some
    # corrupt inputs raise instead. Normalize both to a clean tuple.
    try do
      :zip.extract(binary, [:memory])
    rescue
      e -> {:error, {:invalid, Exception.message(e)}}
    end
  end

  defp find_document_xml(entries) do
    case Enum.find(entries, fn entry -> entry_name(entry) == "word/document.xml" end) do
      nil -> {:error, "missing word/document.xml"}
      entry -> {:ok, entry_content(entry)}
    end
  end

  defp entry_name({name, _content}), do: to_string(name)
  defp entry_name({name, _info, _content}), do: to_string(name)

  defp entry_content({_name, content}), do: content
  defp entry_content({_name, _info, content}), do: content

  defp xml_to_text(xml) do
    text =
      xml
      |> strip_field_codes()
      |> String.replace(~r/<w:p\b[^>]*\/>/, "</w:p>")
      |> String.split("</w:p>")
      |> Enum.map(&paragraph_text/1)
      |> Enum.join("\n")
      |> unescape_entities()

    if String.trim(text) == "" do
      {:error, {:empty, "no text runs found"}}
    else
      {:ok, String.trim(text)}
    end
  end

  defp strip_field_codes(xml) do
    # /s so field codes spanning newlines are removed too.
    Regex.replace(~r/<w:instrText[^>]*>.*?<\/w:instrText>/s, xml, "")
  end

  defp paragraph_text(para) do
    para
    |> String.replace(~r/<w:tab[^>]*\/>/, @tab_marker)
    |> String.replace(~r/<w:br[^>]*\/>/, @br_marker)
    |> run_text()
    |> String.replace(@tab_marker, "\t")
    |> String.replace(@br_marker, "\n")
  end

  defp run_text(para) do
    # NOTE: do NOT use :re.find for run extraction — re:find SIGSEGVs on the
    # OTP 29 build used by this project (see root CONTEXT.md research notes).
    # Split on <w:t>...</w:t> runs (include_captures keeps each full run
    # match): run contents are kept verbatim after tag-stripping; segments
    # BETWEEN runs keep only non-whitespace leftovers, i.e. the tab/br marker
    # placeholders converted above (formatting whitespace is dropped).
    para
    |> String.split(~r/<w:t[^>]*>(.*?)<\/w:t>/, include_captures: true)
    |> Enum.map(&String.replace(&1, ~r/<[^>]*>/, ""))
    |> Enum.with_index()
    |> Enum.map_join(fn {seg, idx} ->
      if rem(idx, 2) == 0, do: String.replace(seg, ~r/\s+/, ""), else: seg
    end)
  end

  ## XML entity unescaping

  defp unescape_entities(text) do
    text
    |> unescape_numeric()
    |> unescape_named()
  end

  # Numeric entities FIRST so `&amp;#38;` (a literal "&#38;" in the source)
  # stays literal: the named pass turns `&amp;` into `&` only afterwards.
  defp unescape_numeric(text) do
    Regex.replace(~r/&#(x?)([0-9a-fA-F]+);/, text, fn match, prefix, digits ->
      base = if prefix == "x", do: 16, else: 10

      case Integer.parse(digits, base) do
        {cp, ""} when cp in 0..0x10FFFF and cp not in 0xD800..0xDFFF ->
          <<cp::utf8>>

        _ ->
          match
      end
    end)
  end

  defp unescape_named(text) do
    Regex.replace(~r/&(amp|lt|gt|quot|apos);/, text, fn
      _, "amp" -> "&"
      _, "lt" -> "<"
      _, "gt" -> ">"
      _, "quot" -> "\""
      _, "apos" -> "'"
    end)
  end

  ## .pdf

  # Visible note prepended to every PDF extraction so LLM agents understand
  # where the text came from and why spacing/word breaks may look odd.
  defp conversion_note(path) do
    "> **Note**: the content below was converted from a PDF file " <>
      "(`#{Path.basename(path)}`). PDF text extraction can be imperfect — " <>
      "words may be split, reordered or merged, and tables/columns/layout " <>
      "are flattened. Treat odd spacing or broken words as extraction " <>
      "artifacts, not as the source document's intended text."
  end

  defp read_pdf(path) do
    with {:ok, binary} <- File.read(path) do
      extract_pdf(binary, path)
    end
  end

  defp extract_pdf(binary, path) do
    # recover: true tolerates recoverable xref/page-tree corruption; fatal
    # errors (:not_a_pdf, :encrypted_*, {:io_error, _}) still surface.
    case Pdf.Reader.open(binary, recover: true) do
      {:ok, doc} ->
        case Pdf.Reader.read(doc, shape: :text) do
          {:ok, pages, _doc} -> format_pdf_pages(pages, path)
          {:error, reason} -> {:error, {:invalid, reason}}
        end

      {:error, reason} ->
        {:error, map_pdf_open_error(reason)}
    end
  end

  # We read the file ourselves, so Pdf.Reader should never open by path — but
  # be defensive: unwrap {:io_error, posix} to the bare posix atom so callers
  # get the same shape as a File.read/1 failure.
  defp map_pdf_open_error({:io_error, posix}), do: posix
  defp map_pdf_open_error(reason), do: {:invalid, reason}

  defp format_pdf_pages(pages, path) do
    text =
      pages
      |> Enum.with_index(1)
      |> Enum.map_join("\n\n", fn {page, n} ->
        "## Page #{n}\n\n#{String.trim(page)}"
      end)
      |> String.trim()

    if text == "" do
      {:error,
       {:empty,
        "no extractable text found — scanned or image-only PDFs are not supported (no OCR)"}}
    else
      {:ok, conversion_note(path) <> "\n\n" <> text}
    end
  end

  defp pdf_reason_msg(:not_a_pdf), do: "not a valid PDF (file does not contain PDF data)"
  defp pdf_reason_msg(:malformed), do: "corrupt or malformed PDF"
  defp pdf_reason_msg({:malformed, _tag, _info}), do: "corrupt or malformed PDF"

  defp pdf_reason_msg(:encrypted_password_required),
    do: "password-protected PDF (password-protected PDFs are not supported)"

  defp pdf_reason_msg(:encrypted_wrong_password),
    do: "password-protected PDF (password-protected PDFs are not supported)"

  defp pdf_reason_msg(:encrypted_unsupported_handler),
    do: "PDF uses an unsupported encryption scheme"

  defp pdf_reason_msg({:unsupported_filter, name}),
    do: "PDF uses an unsupported filter: #{inspect(name)}"

  defp pdf_reason_msg({:unresolved_ref, ref}),
    do: "PDF contains an unresolved reference: #{inspect(ref)}"

  defp pdf_reason_msg({:unsupported_pdf_version, version}),
    do: "unsupported PDF version: #{inspect(version)}"

  defp pdf_reason_msg(reason), do: reason_str(reason)

  defp reason_str(reason) when is_binary(reason), do: reason
  defp reason_str(reason), do: inspect(reason)
end
