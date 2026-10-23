defmodule EvoGit.Agent.Tools.HtmlToMarkdown do
  @moduledoc """
  Pure HTML → Markdown conversion used by the `web_fetch` tool.

  No I/O, no dependencies beyond the standard library — the module is a
  best-effort, LLM-facing readability converter rather than a spec-perfect
  GFM serializer. The goal is text a model reads well: headings, paragraphs,
  lists, links, emphasis, code, quotes, images and tables, with all the
  noise (scripts, styles, comments, `<head>`, inline event handlers) gone.

  ## Pipeline

  1. **Strip hidden blocks** — `<!-- comments -->`, `<!DOCTYPE …>`,
     `<?xml …?>`, and any `<script>` / `<style>` / `<head>` / `<noscript>` /
     `<svg>` / `<template>` / `<iframe>` / `<object>` / `<embed>` / `<canvas>`
     / `<math>` element together with its contents. An UNCLOSED `<script>` /
     `<style>` swallows the remainder of the document (the only sane reading
     of malformed input). Inline event-handler attributes (`onclick="…"`) are
     stripped too — doubly so, because raw HTML tags are never re-emitted.
  2. **Tokenize** with a tolerant tag scanner: text runs plus
     `{:open, name, attrs}` / `{:close, name, attrs}` tokens. Unclosed and
     stray tags are ignored, never raised on.
  3. **Emit Markdown** through a small state machine (current line buffer +
     finished lines, a list stack, a blockquote depth, a link stack, a
     `<pre>` accumulator).

  ## Element mapping

  | HTML | Markdown |
  |---|---|
  | `<h1>`–`<h6>` | `#` … `######` |
  | `<p>`, `<div>`, `<section>`, … | blank-line separated blocks |
  | `<br>` | single line break |
  | `<hr>` | `---` |
  | `<ul>`/`<li>` | `- item`, nested lists indented two spaces per level |
  | `<ol>`/`<li>` | `1. item`, `2. item`, … (per-list counters) |
  | `<a href>` | `[text](href)` — relative hrefs resolved against `:base_url` when given, absolute/unknown schemes left as-is |
  | `<strong>`/`<b>` | `**text**` |
  | `<em>`/`<i>` | `*text*` |
  | `<code>`/`<tt>`/`<kbd>`/`<samp>` | `` `text` `` (skipped inside `<pre>`) |
  | `<pre>` | fenced code block (``` ``` ```) with whitespace preserved |
  | `<blockquote>` | `> ` prefix per depth |
  | `<img>` | `![alt](src)` |
  | `<del>`/`<s>` | `~~text~~` |
  | `<table>`/`<tr>`/`<td>`/`<th>` | **minimal flattening** — one line per row, cells joined with a pipe character (no GFM table syntax) |

  Entities are decoded for `&amp; &lt; &gt; &quot; &#39; &nbsp; &mdash; &ndash;
  &hellip;` plus a handful of typographic/punctuation names, and for numeric
  references (`&#NN;` and `&#xNN;`); unknown names are left verbatim.
  `&nbsp;` decodes to a plain space (an LLM reads it better than U+00A0).

  Whitespace outside `<pre>` is collapsed to single spaces and trailing spaces
  are trimmed per line; runs of three or more newlines collapse to one blank
  line.
  """

  @tag_re ~r/<\s*(\/?)\s*([A-Za-z][A-Za-z0-9:_-]*)((?:[^>"']|"[^"]*"|'[^']*')*)>/u

  @hidden_block_tags ~w(script style head noscript svg template iframe object embed canvas math)

  @hidden_re Regex.compile!(
               "<\\s*(?:" <>
                 Enum.join(@hidden_block_tags, "|") <>
                 ")\\b[^>]*>.*?<\\s*/\\s*(?:" <>
                 Enum.join(@hidden_block_tags, "|") <> ")\\s*>",
               "is"
             )

  # An UNCLOSED <script>/<style> at the end of the document swallows the tail.
  @unclosed_hidden_re Regex.compile!("<\\s*(?:script|style)\\b[^>]*>.*\\z", "is")

  @headings ~w(h1 h2 h3 h4 h5 h6)

  @block_tags ~w(p div section article header footer main aside nav figure figcaption
                 dl dt dd table thead tbody tfoot form fieldset address details summary center)

  @entity_re ~r/&(#[0-9]+|#[xX][0-9a-fA-F]+|[a-zA-Z][a-zA-Z0-9]{1,30});/

  @entities %{
    "amp" => "&",
    "lt" => "<",
    "gt" => ">",
    "quot" => "\"",
    "apos" => "'",
    "nbsp" => " ",
    "mdash" => "—",
    "ndash" => "–",
    "hellip" => "…",
    "lsquo" => "‘",
    "rsquo" => "’",
    "ldquo" => "“",
    "rdquo" => "”",
    "copy" => "©",
    "reg" => "®",
    "trade" => "™",
    "times" => "×",
    "laquo" => "«",
    "raquo" => "»",
    "middot" => "·",
    "bull" => "•",
    "deg" => "°",
    "plusmn" => "±",
    "frac12" => "½",
    "euro" => "€",
    "pound" => "£",
    "yen" => "¥",
    "sect" => "§",
    "para" => "¶",
    "dagger" => "†",
    "permil" => "‰",
    "shy" => ""
  }

  @doc """
  Converts `html` to Markdown.

  ## Options

    * `:base_url` — absolute URL the document was fetched from; relative
      `href`/`src` values are resolved against it. Without it, relative
      references are left exactly as written in the HTML.
  """
  @spec convert(binary(), keyword()) :: String.t()
  def convert(html, opts \\ [])

  def convert(html, opts) when is_binary(html) do
    base_url = Keyword.get(opts, :base_url)

    html
    |> strip_hidden()
    |> tokenize([])
    |> Enum.reduce(new_state(base_url), &apply_token/2)
    |> finalize()
  end

  def convert(other, _opts), do: other |> to_string() |> convert()

  @doc """
  Heuristic HTML sniff for responses with a missing or generic content type:
  a doctype, an `<html>`/`<body>`/`<head>` shell, or a handful of very common
  structural tags within the first 2 KiB (case-insensitive).
  """
  @spec html?(binary()) :: boolean()
  def html?(body) when is_binary(body) do
    head = binary_part(body, 0, min(byte_size(body), 2048)) |> String.downcase()

    Regex.match?(
      ~r/<!doctype\s+html|<html[\s>]|<body[\s>]|<div[\s>]|<p[\s>]|<h[1-6][\s>]|<(?:ul|ol|li|table|br)[\s>\/]/,
      head
    )
  end

  def html?(_), do: false

  ## ------------------------------------------------------------------
  ## Pre-pass: strip hidden blocks + event handlers
  ## ------------------------------------------------------------------

  defp strip_hidden(html) do
    html
    |> then(&Regex.replace(~r/<!--.*?-->/s, &1, ""))
    |> then(&Regex.replace(~r/<![^>]*>|<\?[^>]*\?>/s, &1, ""))
    |> then(&Regex.replace(@hidden_re, &1, ""))
    |> then(&Regex.replace(@unclosed_hidden_re, &1, ""))
    |> then(&Regex.replace(~r/\son[a-z]+\s*=\s*(?:"[^"]*"|'[^']*'|[^\s>]+)/i, &1, ""))
  end

  ## ------------------------------------------------------------------
  ## Tokenizer
  ## ------------------------------------------------------------------

  defp tokenize(bin, acc) do
    case Regex.run(@tag_re, bin, return: :index) do
      nil ->
        acc = if bin == "", do: acc, else: [{:text, decode_entities(bin)} | acc]
        Enum.reverse(acc)

      [{start, len} | groups] ->
        before = binary_part(bin, 0, start)
        tag_len_end = start + len
        rest = binary_part(bin, tag_len_end, byte_size(bin) - tag_len_end)

        [g1, g2, g3] =
          case groups do
            [a, b, c] -> [a, b, c]
            _ -> [{-1, 0}, {-1, 0}, {-1, 0}]
          end

        closing? = String.trim(slice(bin, g1)) == "/"
        name = bin |> slice(g2) |> String.downcase()
        attrs = slice(bin, g3)

        acc = if before == "", do: acc, else: [{:text, decode_entities(before)} | acc]
        token = if closing?, do: {:close, name, attrs}, else: {:open, name, attrs}
        tokenize(rest, [token | acc])
    end
  end

  defp slice(_bin, {-1, _len}), do: ""
  defp slice(bin, {off, len}), do: binary_part(bin, off, len)

  ## ------------------------------------------------------------------
  ## Token handling
  ## ------------------------------------------------------------------

  # Text inside <pre> is accumulated verbatim (entities already decoded).
  defp apply_token({:text, text}, %{pre: pre} = state) when is_list(pre),
    do: %{state | pre: [text | pre]}

  defp apply_token({:text, text}, state) do
    case collapse(text) do
      "" -> state
      collapsed -> append_text(state, collapsed)
    end
  end

  defp apply_token({:open, "pre", _attrs}, state), do: %{block(state) | pre: []}

  defp apply_token({:close, "pre", _attrs}, %{pre: pre} = state) when is_list(pre) do
    content = pre |> Enum.reverse() |> IO.iodata_to_binary()
    emit_fence(%{state | pre: nil}, content)
  end

  defp apply_token({:open, name, _attrs}, state) when name in @headings do
    level = String.to_integer(String.replace_prefix(name, "h", ""))
    state |> block() |> append_text(String.duplicate("#", level) <> " ")
  end

  defp apply_token({:close, name, _attrs}, state) when name in @headings, do: block(state)

  defp apply_token({:open, "hr", _attrs}, state) do
    state |> block() |> append_text("---") |> block()
  end

  # Lists. A nested list starts right under its parent item (flush, no blank
  # line); a list at the top level gets a blank-line separator.
  defp apply_token({:open, "ul", _attrs}, state),
    do: %{separate(state) | lists: [{:ul} | state.lists]}

  defp apply_token({:open, "ol", _attrs}, state),
    do: %{separate(state) | lists: [{:ol, 0} | state.lists]}

  defp apply_token({:close, tag, _attrs}, state) when tag in ["ul", "ol"] do
    lists =
      case state.lists do
        [] -> []
        [_ | rest] -> rest
      end

    %{flush_line(state) | lists: lists}
  end

  defp apply_token({:open, "li", _attrs}, state) do
    state = flush_line(state)

    case state.lists do
      [{:ol, n} | rest] ->
        %{state | lists: [{:ol, n + 1} | rest]} |> append_text("#{n + 1}. ")

      _ ->
        append_text(state, "- ")
    end
  end

  defp apply_token({:close, "li", _attrs}, state), do: flush_line(state)

  defp apply_token({:open, "blockquote", _attrs}, state),
    do: %{block(state) | blockquote: state.blockquote + 1}

  defp apply_token({:close, "blockquote", _attrs}, state) do
    state = block(state)
    %{state | blockquote: max(state.blockquote - 1, 0)}
  end

  defp apply_token({:open, "a", attrs}, state) do
    href = attr(attrs, "href")

    state =
      case href do
        nil -> state
        _ -> append_text(state, "[")
      end

    %{state | links: [href | state.links]}
  end

  defp apply_token({:close, "a", _attrs}, state) do
    case state.links do
      [] ->
        state

      [nil | rest] ->
        %{state | links: rest}

      [href | rest] ->
        %{state | links: rest} |> append_text("](#{resolve_url(state.base_url, href)})")
    end
  end

  defp apply_token({:open, tag, _attrs}, state) when tag in ["strong", "b"],
    do: append_text(state, "**")

  defp apply_token({:close, tag, _attrs}, state) when tag in ["strong", "b"],
    do: append_text(state, "**")

  defp apply_token({:open, tag, _attrs}, state) when tag in ["em", "i"],
    do: append_text(state, "*")

  defp apply_token({:close, tag, _attrs}, state) when tag in ["em", "i"],
    do: append_text(state, "*")

  defp apply_token({:open, tag, _attrs}, state) when tag in ["del", "s"],
    do: append_text(state, "~~")

  defp apply_token({:close, tag, _attrs}, state) when tag in ["del", "s"],
    do: append_text(state, "~~")

  # Inline code is skipped inside <pre> (handled by the pre text clause above,
  # which never reaches here for its content).
  defp apply_token({:open, tag, _attrs}, %{pre: pre} = state)
       when tag in ["code", "tt", "kbd", "samp"] and not is_list(pre),
       do: append_text(state, "`")

  defp apply_token({:close, tag, _attrs}, %{pre: pre} = state)
       when tag in ["code", "tt", "kbd", "samp"] and not is_list(pre),
       do: append_text(state, "`")

  defp apply_token({:open, "img", attrs}, state) do
    alt = attr(attrs, "alt") || ""
    src = attr(attrs, "src")

    if is_nil(src),
      do: state,
      else: append_text(state, "![#{alt}](#{resolve_url(state.base_url, src)})")
  end

  defp apply_token({:open, "br", _attrs}, state), do: flush_line(state)

  # Tables flatten to one line per row, cells joined with " | ".
  defp apply_token({:open, "tr", _attrs}, state), do: flush_line(state)

  defp apply_token({:close, "tr", _attrs}, state), do: flush_line(state)

  defp apply_token({:open, tag, _attrs}, state) when tag in ["td", "th"] do
    case String.trim(state.current) do
      "" -> state
      _ -> append_text(state, " | ")
    end
  end

  defp apply_token({:open, tag, _attrs}, state) when tag in @block_tags, do: block(state)

  defp apply_token({:close, tag, _attrs}, state) when tag in @block_tags, do: block(state)

  defp apply_token(_token, state), do: state

  ## ------------------------------------------------------------------
  ## Emission state machine
  ## ------------------------------------------------------------------

  defp new_state(base_url) do
    %{
      base_url: base_url,
      lines: [],
      current: "",
      blockquote: 0,
      lists: [],
      links: [],
      pre: nil
    }
  end

  # Appends collapsed text to the current line. Whitespace at the start of a
  # line is meaningless in Markdown (indentation comes from the prefix), so it
  # is dropped.
  defp append_text(%{current: ""} = state, text),
    do: %{state | current: String.trim_leading(text)}

  defp append_text(state, text), do: %{state | current: state.current <> text}

  # Line break: finish the current line without a blank separator.
  defp flush_line(state) do
    line = String.trim_trailing(state.current)

    if line == "" do
      %{state | current: ""}
    else
      %{state | lines: [line_prefix(state) <> line | state.lines], current: ""}
    end
  end

  # Block separator: finish the line and leave exactly one blank line behind.
  defp block(state) do
    state = flush_line(state)

    case state.lines do
      [] -> state
      ["" | _] -> state
      _ -> %{state | lines: ["" | state.lines]}
    end
  end

  # Separator for a construct that may sit immediately under a parent item
  # (nested lists, table rows): flush if there is text, else a blank line.
  defp separate(state) do
    if String.trim(state.current) == "" do
      block(state)
    else
      flush_line(state)
    end
  end

  defp line_prefix(state) do
    String.duplicate("> ", state.blockquote) <>
      String.duplicate("  ", max(length(state.lists) - 1, 0))
  end

  defp blockquote_prefix(state), do: String.duplicate("> ", state.blockquote)

  defp emit_fence(state, content) do
    prefix = blockquote_prefix(state)

    content =
      content
      |> String.replace("\r\n", "\n")
      |> String.replace("\r", "\n")
      |> String.trim("\n")

    body =
      content
      |> String.split("\n")
      |> Enum.map(fn line -> prefix <> String.trim_trailing(line) end)

    fence = prefix <> "```"
    emitted = [fence] ++ body ++ [fence, ""]

    %{state | lines: Enum.reverse(emitted) ++ state.lines}
  end

  defp finalize(state) do
    state =
      case state.pre do
        pre when is_list(pre) ->
          emit_fence(%{state | pre: nil}, pre |> Enum.reverse() |> IO.iodata_to_binary())

        _ ->
          state
      end

    state
    |> flush_line()
    |> Map.get(:lines)
    |> Enum.reverse()
    |> Enum.join("\n")
    |> then(&Regex.replace(~r/\n{3,}/, &1, "\n\n"))
    |> String.trim()
  end

  ## ------------------------------------------------------------------
  ## Text helpers
  ## ------------------------------------------------------------------

  defp collapse(text), do: Regex.replace(~r/[ \t\r\n\f\v\x{00A0}]+/u, text, " ")

  defp resolve_url(nil, url), do: url

  defp resolve_url(base, url) do
    trimmed = String.trim(url)

    cond do
      trimmed == "" -> ""
      String.starts_with?(trimmed, "#") -> trimmed
      absolute_url?(trimmed) -> trimmed
      not is_binary(base) -> trimmed
      true -> merge_url(base, trimmed)
    end
  end

  defp absolute_url?(url), do: Regex.match?(~r/^[a-zA-Z][a-zA-Z0-9+.\-]*:/, url)

  defp merge_url(base, url) do
    URI.merge(base, url) |> URI.to_string()
  rescue
    # A base URL the URI parser rejects is a caller problem, not a conversion
    # failure: keep the reference exactly as the document wrote it.
    _ -> url
  end

  ## ------------------------------------------------------------------
  ## Attributes + entities
  ## ------------------------------------------------------------------

  defp attr(attrs, name) when is_binary(attrs) and attrs != "" do
    re = ~r/(?:^|[\s"'])#{Regex.escape(name)}\s*=\s*(?:"([^"]*)"|'([^']*)'|([^\s"'>]+))/i

    case Regex.run(re, attrs) do
      nil ->
        nil

      [_all | values] ->
        values
        |> Enum.find("", &(&1 != ""))
        |> case do
          "" -> nil
          # Attribute values carry entities too (`href="/a?x=1&amp;y=2"`).
          value -> decode_entities(value)
        end
    end
  end

  defp attr(_attrs, _name), do: nil

  @doc """
  Decodes HTML entities: the common named set plus numeric (`&#NN;`,
  `&#xNN;`) references. Unknown names are left untouched.
  """
  @spec decode_entities(binary()) :: binary()
  def decode_entities(text) when is_binary(text) do
    if String.contains?(text, "&") do
      Regex.replace(@entity_re, text, fn full, code -> decode_entity(code, full) end)
    else
      text
    end
  end

  defp decode_entity("#x" <> hex, full), do: codepoint(hex, 16, full)
  defp decode_entity("#X" <> hex, full), do: codepoint(hex, 16, full)
  defp decode_entity("#" <> dec, full), do: codepoint(dec, 10, full)

  defp decode_entity(name, full),
    do: Map.get(@entities, String.downcase(name), full)

  defp codepoint(digits, base, full) do
    case Integer.parse(digits, base) do
      {cp, ""} when cp > 0 and cp <= 0x10FFFF and cp not in 0xD800..0xDFFF ->
        <<cp::utf8>>

      _ ->
        full
    end
  end
end
