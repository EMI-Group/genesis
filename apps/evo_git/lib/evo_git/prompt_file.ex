defmodule EvoGit.PromptFile do
  @moduledoc """
  Reads prompt/objective files for the CLI `-f`/`--file` option.

  Supported formats:
    * `.txt`, `.md`, or any other plain-text file — read verbatim and trimmed
    * `.docx` — Word documents, extracted to plain text using OTP stdlib only
      (`:zip` + regexes; no third-party dependencies)

  `.pdf` is intentionally NOT supported (returns `{:error, {:unsupported, "pdf"}}`).
  See the root CONTEXT.md → "Research Notes: PDF/DOCX → Plain Text Extraction"
  for extraction options (e.g. `pdftotext -layout`).

  Known .docx limitations:
    * Only `word/document.xml` is read — headers, footers, footnotes and
      comments are ignored.
    * Field codes (`w:instrText`, e.g. PAGE fields) are stripped.
    * XML entities are unescaped; whitespace inside text runs is preserved
      (`xml:space="preserve"`).
  """

  @doc """
  Reads a prompt file.

  Returns `{:ok, text}` or `{:error, reason}`. `reason` is a bare POSIX atom
  (`:enoent`, `:eacces`, ...) for plain files (propagated from `File.read/1`),
  or one of:
    * `{:invalid, reason}` — not a valid ZIP or `word/document.xml` missing
    * `{:empty, reason}` — valid .docx but no text found
    * `{:unsupported, "pdf"}` — .pdf is not implemented
  """
  def read(path) do
    case path |> Path.extname() |> String.downcase() do
      ".docx" -> read_docx(path)
      ".pdf" -> {:error, {:unsupported, "pdf"}}
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

      {:unsupported, "pdf"} ->
        ".pdf files are not supported yet. Convert the PDF to plain text " <>
          "(e.g. `pdftotext -layout file.pdf`) or use a .txt/.docx file instead."

      {:invalid, reason} ->
        "Invalid .docx file: #{reason_str(reason)}"

      {:empty, reason} ->
        "No text found in .docx file: #{reason_str(reason)}"

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

  defp reason_str(reason) when is_binary(reason), do: reason
  defp reason_str(reason), do: inspect(reason)
end
