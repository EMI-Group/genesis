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
    * image attachments (`.png`, `.jpg`/`.jpeg`, `.gif`, `.webp`, `.bmp`) —
      read via `read_kind/2` as raw binary bytes, never transformed
    * audio attachments (`.mp3`, `.wav`, `.ogg`, `.m4a`, `.flac`) — read via
      `read_kind/2` as raw binary bytes, never transformed

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

  Image/audio attachments (`read_kind/2`) are capped at 15 MiB of raw bytes
  per file (the per-task cap of 4 attachments is enforced by the caller when
  staging). Raw bytes are returned to the caller only — this module never
  renders, logs, or sends them to the client.

  Error shapes from `read_kind/2`:
    * bare POSIX atom (`:enoent`, `:eacces`, ...) — file read failed
      (propagated from `File.read/1`)
    * `{:unsupported_extension, ext}` — extension not allowed for the kind
      (ext = the lowercase extension including the dot)
    * `{:file_too_large, byte_size}` — raw bytes exceed the 15 MiB cap
    * `{:unsupported_kind, kind}` — `kind` is not `"image"` or `"audio"`

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

  # Keep in sync with EvoGit.Attachments in :evo_git (the authoritative validation)
  @max_attachments 4
  @max_attachment_bytes 15 * 1024 * 1024

  @doc """
  Reads an attached objective file.

  Returns `{:ok, text}` or `{:error, reason}`. `reason` is a bare POSIX atom
  (`:enoent`, `:eacces`, ...) for plain files (propagated from `File.read/1`),
  or one of the shapes documented in the moduledoc (`{:invalid, reason}` or
  `{:empty, reason}`).
  The path is stat-ed BEFORE any read: a non-regular file is refused with
  `:not_a_regular_file` and a file — or extracted text — over
  `@max_attachment_bytes` with `{:file_too_large, byte_size}`, so a huge
  attachment is never pulled into memory.
  """
  def read(path) do
    # Size gate BEFORE any read: the picker paths below (plain text, .pdf,
    # .docx) have no caller-side cap, so an arbitrarily large log/PDF would
    # otherwise be pulled into memory (and, for .docx, unzipped) and could
    # OOM the VM. `File.stat/1` is cheap and reports the same POSIX errors
    # `File.read/1` would.
    with :ok <- ensure_readable_size(path) do
      case path |> Path.extname() |> String.downcase() do
        ".docx" -> read_docx(path)
        ".pdf" -> read_pdf(path)
        # TRAP: this catch-all treats ANY unknown extension as plain text, so
        # the UI must gate by dropdown kind — binary image/audio files must
        # never reach read/1 (they go through read_kind/2 instead).
        _ -> read_text(path)
      end
    end
    |> cap_extracted_text()
  end

  # Stat gate for the picker read paths: only a regular file at or under the
  # per-file cap may be read (`read_uploaded/2` performs its own equivalent
  # gate before dispatch).
  defp ensure_readable_size(path) do
    case File.stat(path) do
      {:ok, %{type: :regular, size: size}} when size <= @max_attachment_bytes ->
        :ok

      {:ok, %{type: :regular, size: size}} ->
        {:error, {:file_too_large, size}}

      {:ok, _stat} ->
        {:error, :not_a_regular_file}

      {:error, reason} ->
        {:error, reason}
    end
  end

  # Extracted text can balloon well past the source file (PDF/DOCX expansion),
  # so the same byte cap applies to the converted result — LLM-bound context
  # must stay bounded no matter what the container looked like.
  defp cap_extracted_text({:ok, text}) when is_binary(text) do
    if byte_size(text) > @max_attachment_bytes do
      {:error, {:file_too_large, byte_size(text)}}
    else
      {:ok, text}
    end
  end

  defp cap_extracted_text(other), do: other

  @text_extensions ~w(.txt .md .markdown .csv .tsv .json .jsonl .yaml .yml .toml .xml .log .ini .conf .ex .exs .js .jsx .ts .tsx .html .htm .css .scss .py .rb .sh .sql .go .rs .java .c .h .cpp .hpp .swift .kt .vue .svelte)

  @doc "Supported browser-upload extensions, including text documents and media."
  def upload_extensions,
    do: @text_extensions ++ [".pdf", ".docx"] ++ Map.keys(upload_media_types())

  @doc "Sanitizes an untrusted browser filename without using it as a server path."
  def upload_name(name) when is_binary(name) do
    if String.valid?(name) and not String.contains?(name, <<0>>) do
      name =
        name
        |> String.replace("\\", "/")
        |> Path.basename()
        |> String.replace(~r/[\r\n\t]/, "_")
        |> String.slice(0, 255)

      if name in ["", ".", ".."], do: {:error, :invalid_filename}, else: {:ok, name}
    else
      {:error, :invalid_filename}
    end
  end

  def upload_name(_), do: {:error, :invalid_filename}

  @doc "Reads a consumed upload using its original name, never its extensionless temporary path."
  def read_uploaded(path, client_name) do
    with {:ok, name} <- upload_name(client_name),
         ext = name |> Path.extname() |> String.downcase(),
         true <- ext in upload_extensions(),
         {:ok, stat} <- File.stat(path),
         true <- stat.type == :regular,
         :ok <- upload_size(stat.size) do
      case Map.get(upload_media_types(), ext) do
        {kind, media_type} ->
          read_kind_file(path, kind, media_type)

        nil ->
          result =
            case ext do
              ".pdf" -> read_pdf(path, name)
              ".docx" -> read_docx(path)
              _ -> read_text(path)
            end

          with {:ok, text} <- result,
               true <- String.valid?(text) and not String.contains?(text, <<0>>),
               :ok <- upload_size(byte_size(text)) do
            {:ok, %{type: "text", name: name, text: text}}
          else
            false -> {:error, :invalid_text}
            {:error, _} = error -> error
          end
      end
    else
      false -> {:error, {:unsupported_extension, Path.extname(to_string(client_name))}}
      {:error, _} = error -> error
    end
  end

  defp upload_size(size) when size <= @max_attachment_bytes, do: :ok
  defp upload_size(size), do: {:error, {:file_too_large, size}}

  @doc "Builds a user-ready error message for a `read/1`/`read_kind/2` error."
  def describe_error(error, path) do
    case error do
      :invalid_filename ->
        "Invalid attachment filename"

      :invalid_text ->
        "The file does not contain valid UTF-8 text"

      :enoent ->
        "File not found: #{path}"

      :not_a_regular_file ->
        "Not a regular file: #{path}"

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

      {:unsupported_extension, ext} ->
        "Unsupported file type for attachment: #{ext}"

      {:file_too_large, byte_size} ->
        "File is too large (max #{div(@max_attachment_bytes, 1024 * 1024)} MiB): " <>
          "#{Path.basename(path)} (#{byte_size} bytes)"

      {:unsupported_kind, kind} ->
        "Unsupported attachment kind: #{inspect(kind)}"

      reason when is_atom(reason) ->
        "Failed to read file: #{path} (#{inspect(reason)})"

      reason ->
        "Failed to read file: #{path} (#{inspect(reason)})"
    end
  end

  ## Image/audio attachments

  # Pinned image/audio extension → IANA media type allowlists (also kept in
  # sync with EvoGit.Attachments in :evo_git).
  @image_media_types %{
    ".png" => "image/png",
    ".jpg" => "image/jpeg",
    ".jpeg" => "image/jpeg",
    ".gif" => "image/gif",
    ".webp" => "image/webp",
    ".bmp" => "image/bmp"
  }

  @audio_media_types %{
    ".mp3" => "audio/mpeg",
    ".wav" => "audio/wav",
    ".ogg" => "audio/ogg",
    ".m4a" => "audio/mp4",
    ".flac" => "audio/flac"
  }

  @media_types Map.merge(@image_media_types, @audio_media_types)

  defp upload_media_types do
    Map.new(@image_media_types, fn {ext, mime} -> {ext, {"image", mime}} end)
    |> Map.merge(Map.new(@audio_media_types, fn {ext, mime} -> {ext, {"audio", mime}} end))
  end

  @doc """
  Maps a lowercase file extension (with or without the leading dot) to the
  pinned IANA media type; `nil` when unknown.
  """
  def media_type_for(ext) when is_binary(ext) do
    Map.get(@media_types, normalize_ext(ext))
  end

  def media_type_for(_ext), do: nil

  @doc """
  Reads an image or audio attachment file (binary kind `"image"`/`"audio"`)
  into a raw binary payload for server-side staging — the extension is checked
  against the kind's pinned allowlist and the file is read verbatim (raw bytes
  are never trimmed or otherwise transformed; callers must not render, log, or
  send them to the client).

  Returns `{:ok, %{type: kind, media_type: media_type, bytes: raw_binary}}`.
  Errors: bare POSIX atom from `File.read/1`; `{:unsupported_extension, ext}`
  (ext = the lowercase extension incl. dot); `{:file_too_large, byte_size}`
  (raw bytes over the 15 MiB per-file cap); `{:unsupported_kind, kind}`. The
  per-task cap of #{@max_attachments} attachments is caller-enforced.
  """
  def read_kind(path, kind) when kind in ["image", "audio"] do
    ext = path |> Path.extname() |> String.downcase()

    case Map.fetch(media_types_for(kind), ext) do
      {:ok, media_type} -> read_kind_file(path, kind, media_type)
      :error -> {:error, {:unsupported_extension, ext}}
    end
  end

  def read_kind(_path, kind), do: {:error, {:unsupported_kind, kind}}

  defp read_kind_file(path, kind, media_type) do
    case File.read(path) do
      {:ok, bytes} when byte_size(bytes) <= @max_attachment_bytes ->
        {:ok, %{type: kind, media_type: media_type, bytes: bytes}}

      {:ok, bytes} ->
        {:error, {:file_too_large, byte_size(bytes)}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp media_types_for("image"), do: @image_media_types
  defp media_types_for("audio"), do: @audio_media_types

  # Lowercases and guarantees the leading dot for allowlist lookups.
  defp normalize_ext("." <> rest), do: "." <> String.downcase(rest)
  defp normalize_ext(ext), do: "." <> String.downcase(ext)

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

  defp read_pdf(path, display_name \\ nil) do
    with {:ok, binary} <- File.read(path) do
      extract_pdf(binary, display_name || path)
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
