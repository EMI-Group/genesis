defmodule EvoDashWeb.ReviewComponents.DiffViewer do
  @moduledoc false
  use EvoDashWeb, :html

  # ---------------------------------------------------------------------------
  # file_tree_sidebar/1 — Sidebar file list for the split-pane layout
  # ---------------------------------------------------------------------------

  attr(:files, :list, required: true)
  attr(:selected_file, :string, default: nil)

  def file_tree_sidebar(assigns) do
    ~H"""
    <div class="diff-file-sidebar">
      <div class="p-3 border-b border-base-200 bg-base-200/30 sticky top-0 z-10">
        <h3 class="font-semibold text-xs text-base-content/60 uppercase tracking-wider">
          {gettext("Changed Files")}
        </h3>
      </div>
      <%= for {group, files} <- group_files_by_dir(@files) do %>
        <%= if group == :root do %>
          <%= for file <- files do %>
            <button
              phx-click="select_file"
              phx-value-path={file.path}
              class={["file-item", @selected_file == file.path && "file-selected"]}
            >
              <.icon
                name={file_status_icon(file.status)}
                class={"size-3.5 shrink-0 #{file_status_color(file.status)}"}
              />
              <span class="font-mono truncate flex-1 text-xs" title={file.path}>
                {Path.basename(file.path)}
              </span>
              <span class="text-[10px] text-success font-mono leading-none">+{file.additions}</span>
              <span class="text-[10px] text-error font-mono leading-none">-{file.deletions}</span>
            </button>
          <% end %>
        <% else %>
          <details open class="dir-group">
            <summary class="dir-group-header">
              <span class="dir-icon">📁</span>
              <span class="dir-name font-mono text-xs truncate" title={group}>{group}/</span>
              <% {group_additions, group_deletions} = dir_stats(files) %>
              <span class="dir-stats">
                {ngettext("%{count} file", "%{count} files", length(files), count: length(files))}
                <span class="text-success">+{group_additions}</span>
                <span class="text-error">-{group_deletions}</span>
              </span>
            </summary>
            <div class="dir-files">
              <%= for file <- files do %>
                <button
                  phx-click="select_file"
                  phx-value-path={file.path}
                  class={[
                    "file-item file-item-indented",
                    @selected_file == file.path && "file-selected"
                  ]}
                >
                  <.icon
                    name={file_status_icon(file.status)}
                    class={"size-3.5 shrink-0 #{file_status_color(file.status)}"}
                  />
                  <span class="font-mono truncate flex-1 text-xs" title={file.path}>
                    {Path.basename(file.path)}
                  </span>
                  <span class="text-[10px] text-success font-mono leading-none">+{file.additions}</span>
                  <span class="text-[10px] text-error font-mono leading-none">-{file.deletions}</span>
                </button>
              <% end %>
            </div>
          </details>
        <% end %>
      <% end %>
    </div>
    """
  end

  # ---------------------------------------------------------------------------
  # diff_viewer/1 — GitHub-style diff viewer with proper syntax highlighting
  # ---------------------------------------------------------------------------

  attr(:files, :list, required: true)
  attr(:expanded_files, :map, default: %{})
  attr(:selected_file, :string, default: nil)
  attr(:file_context_levels, :map, default: %{})

  def diff_viewer(assigns) do
    ~H"""
    <div class="diff-main-content" id="diff-viewer" phx-hook="ScrollToFile">
      <%= for file <- @files do %>
        <div class="diff-file-section" id={"file-section-#{file_path_to_id(file.path)}"}>
          <button
            phx-click="toggle_file_expansion"
            phx-value-path={file.path}
            class="diff-file-header w-full text-left"
          >
            <.icon
              name="hero-chevron-right"
              class={"size-3.5 transition-transform shrink-0 #{if Map.get(@expanded_files, file.path, false), do: "rotate-90", else: ""}"}
            />
            <.icon
              name={file_status_icon(file.status)}
              class={"size-3.5 #{file_status_color(file.status)}"}
            />
            <span class="truncate flex-1">{file.path}</span>
            <span class="text-[10px] text-success font-mono">+{file.additions}</span>
            <span class="text-[10px] text-error font-mono">-{file.deletions}</span>
          </button>
          <%= if Map.get(@expanded_files, file.path, false) do %>
            <div class="overflow-x-auto">
              <% context_level = Map.get(@file_context_levels, file.path, 3) %>
              {render_diff_content(file, file.path, context_level)}
            </div>
          <% end %>
        </div>
      <% end %>
    </div>
    """
  end

  # ---------------------------------------------------------------------------
  # split_diff_layout/1 — Full split layout with sidebar + diff
  # ---------------------------------------------------------------------------

  attr(:files, :list, required: true)
  attr(:expanded_files, :map, default: %{})
  attr(:selected_file, :string, default: nil)
  attr(:file_context_levels, :map, default: %{})

  def split_diff_layout(assigns) do
    ~H"""
    <div class="diff-fullscreen-layout">
      <.file_tree_sidebar files={@files} selected_file={@selected_file} />
      <.diff_viewer
        files={@files}
        expanded_files={@expanded_files}
        selected_file={@selected_file}
        file_context_levels={@file_context_levels}
      />
    </div>
    """
  end

  # ---------------------------------------------------------------------------
  # commit_detail_header/1 — Header for a commit inspection view
  # ---------------------------------------------------------------------------

  attr(:commit, :map, required: true)

  def commit_detail_header(assigns) do
    ~H"""
    <div class="rounded-lg border border-base-200 bg-base-100 overflow-hidden">
      <div class="p-4">
        <div class="flex items-start gap-3">
          <.icon name="hero-code-bracket-square" class="size-5 text-base-content/50 shrink-0 mt-0.5" />
          <div class="flex-1 min-w-0">
            <h1 class="text-lg font-bold leading-tight">{@commit.message}</h1>
            <div class="flex flex-wrap items-center gap-2 mt-2">
              <span class="badge badge-sm badge-ghost rounded-md px-2 py-1.5 font-mono">
                <.icon name="hero-code-bracket" class="size-3.5 mr-1.5" />
                {String.slice(@commit.sha, 0..7)}
              </span>
              <span class="text-sm text-base-content/50">{@commit.author_name}</span>
              <span class="text-sm text-base-content/30">·</span>
              <span class="text-sm text-base-content/50">{relative_time(@commit.date)}</span>
            </div>
          </div>
        </div>
      </div>
    </div>
    """
  end

  # ---------------------------------------------------------------------------
  # commit_diff_layout/1 — Commit detail view with sidebar + diff viewer
  # ---------------------------------------------------------------------------

  attr(:files, :list, required: true)
  attr(:expanded_files, :map, default: %{})
  attr(:selected_file, :string, default: nil)
  attr(:file_context_levels, :map, default: %{})

  def commit_diff_layout(assigns) do
    ~H"""
    <div class="diff-fullscreen-layout">
      <.file_tree_sidebar files={@files} selected_file={@selected_file} />
      <.diff_viewer
        files={@files}
        expanded_files={@expanded_files}
        selected_file={@selected_file}
        file_context_levels={@file_context_levels}
      />
    </div>
    """
  end

  # ---------------------------------------------------------------------------
  # Private helpers
  # ---------------------------------------------------------------------------

  defp render_diff_content(file, file_path, context_level) do
    # Pre-compute highlighted content: prefer file-level highlighting (one Lumis
    # call for the entire file, then map diff lines back by line number) which
    # gives Tree-sitter full context; fall back to hunk-level highlighting when
    # full content is unavailable.
    lines = if file.diff, do: parse_diff_lines(file), else: []
    highlighted =
      if file.diff,
        do: precompute_highlights(lines, file.language, file.full_new_content, file.full_old_content),
        else: %{}

    assigns = %{
      file: file,
      file_path: file_path,
      context_level: context_level,
      lines: lines,
      highlighted: highlighted
    }

    ~H"""
    <div class="text-xs font-mono">
      <%= if is_nil(@file.diff) do %>
        <div class="flex items-center justify-center py-8 gap-2 text-base-content/50">
          <span class="loading loading-spinner loading-sm"></span>
          <span>{gettext("Loading diff...")}</span>
        </div>
      <% else %>
        <% {hunk_starts, _} =
          Enum.reduce(@lines, {[], 0}, fn line, {acc, idx} ->
            if line.type == :hunk, do: {[idx | acc], idx + 1}, else: {acc, idx + 1}
          end) %>
        <% hunk_indices = Enum.reverse(hunk_starts) %>
        <% show_top_expand = length(hunk_indices) > 0 %>
        <% show_bottom_expand = @context_level != :all %>
        <%= if show_top_expand do %>
          <.diff_expand_bar path={@file_path} context_level={@context_level} />
        <% end %>
        <%= for {line, i} <- Enum.with_index(@lines) do %>
          <%= if i in hunk_indices and i > 0 do %>
            <.diff_expand_bar path={@file_path} context_level={@context_level} />
          <% end %>
          <div class={["diff-line", diff_line_class(line.type)]}>
            <span class="diff-line-gutter">{line.line_number}</span>
            <span class={["diff-line-prefix", diff_prefix_color(line.type)]}>{line.prefix}</span>
            <span class="diff-line-content" phx-no-format>{Map.get(@highlighted, line.line_number, line.content)}</span>
          </div>
        <% end %>
        <%= if show_bottom_expand do %>
          <.diff_expand_bar path={@file_path} context_level={@context_level} />
        <% end %>
      <% end %>
    </div>
    """
  end

  # ---------------------------------------------------------------------------
  # diff_expand_bar/1 — Expandable context bar at hunk edges
  # ---------------------------------------------------------------------------

  attr(:path, :string, required: true)
  attr(:context_level, :any, default: nil)

  def diff_expand_bar(assigns) do
    ~H"""
    <%= if @context_level != :all do %>
      <div class="diff-expand-bar">
        <button
          class="diff-expand-btn"
          phx-click="expand_context"
          phx-value-path={@path}
        >
          <.icon name="hero-chevron-double-down" class="size-3.5" />
        </button>
      </div>
    <% end %>
    """
  end

  # Map line types to CSS classes
  defp diff_line_class(:addition), do: "diff-line-addition"
  defp diff_line_class(:deletion), do: "diff-line-deletion"
  defp diff_line_class(:hunk), do: "diff-line-hunk"
  defp diff_line_class(:context), do: "diff-line-context"
  defp diff_line_class(:header), do: "diff-line-meta"
  defp diff_line_class(:meta), do: "diff-line-meta"
  defp diff_line_class(_), do: ""

  defp diff_prefix_color(:addition), do: "text-success/70"
  defp diff_prefix_color(:deletion), do: "text-error/70"
  defp diff_prefix_color(_), do: ""

  # Parse diff lines into structured data
  @doc false
  def parse_diff_lines(file) do
    file.diff
    |> String.split("\n")
    |> Enum.with_index(1)
    |> Enum.map(fn {line, idx} ->
      cond do
        String.starts_with?(line, "+++") ->
          %{line_number: idx, prefix: " ", content: line, type: :header}

        String.starts_with?(line, "---") ->
          %{line_number: idx, prefix: " ", content: line, type: :header}

        String.starts_with?(line, "@@") ->
          %{line_number: idx, prefix: " ", content: line, type: :hunk}

        String.starts_with?(line, "+") ->
          content = String.slice(line, 1..-1//1) || ""
          %{line_number: idx, prefix: "+", content: content, type: :addition}

        String.starts_with?(line, "-") ->
          content = String.slice(line, 1..-1//1) || ""
          %{line_number: idx, prefix: "-", content: content, type: :deletion}

        String.starts_with?(line, "diff ") ->
          %{line_number: idx, prefix: " ", content: line, type: :meta}

        String.starts_with?(line, "index ") ->
          %{line_number: idx, prefix: " ", content: line, type: :meta}

        # "\ No newline at end of file" git marker — not code, skip highlighting
        String.starts_with?(line, "\\ ") ->
          %{line_number: idx, prefix: " ", content: line, type: :no_newline}

        true ->
          content = if String.length(line) > 0, do: String.slice(line, 1..-1//1), else: ""
          %{line_number: idx, prefix: " ", content: content, type: :context}
      end
    end)
  end

  # ---------------------------------------------------------------------------
  # Syntax highlighting: file-level (primary) with hunk-level fallback
  # ---------------------------------------------------------------------------
  #
  # PRIMARY (file-level): When the full file content at the new/old commit is
  # available, we highlight the ENTIRE file in a single Lumis call. Tree-sitter
  # then has full context (imports, function boundaries, multi-line constructs)
  # and produces consistent highlighting. We walk the diff hunk-by-hunk, using
  # the @@ header line numbers to index into the full-file highlight arrays.
  #
  # FALLBACK (hunk-level): When full content is unavailable (added/deleted
  # files where content fetch failed, or files exceeding the size threshold),
  # we fall back to the original approach: reconstruct clean old/new code
  # strings from each hunk and call Lumis once per hunk code block.
  #
  # This try/rescue in highlight_code_block/2 is JUSTIFIED:
  #   - Lumis.highlight!/2 raises on invalid/unexpected input (malformed code,
  #     unsupported language, binary-encoded edge cases). The non-bang variant
  #     Lumis.highlight/2 also raises internally (it does NOT return {:error, _}
  #     despite what the docs suggest), so case/with cannot cleanly replace it.
  #   - It is called at most twice per file (file-level) or a handful of times
  #     per hunk (fallback), so the cost is amortized. Falling back to raw
  #     un-highlighted code is the correct graceful degradation.

  # Full files larger than this many lines fall back to hunk-level highlighting.
  # 5000 lines keeps the single Lumis call fast (< ~200ms) while covering the
  # vast majority of real source files. Generated/minified files exceeding this
  # are poor candidates for Tree-sitter highlighting anyway.
  @max_full_file_lines 5000

  @doc false
  def precompute_highlights(lines, language, full_new_content, full_old_content) do
    new_hl = maybe_highlight_full(full_new_content, language)
    old_hl = maybe_highlight_full(full_old_content, language)

    if is_nil(new_hl) and is_nil(old_hl) do
      precompute_highlights_hunk_level(lines, language)
    else
      precompute_highlights_file_level(lines, new_hl, old_hl)
    end
  end

  # Highlight the full file content if it is present and under the size
  # threshold. Returns nil (treat as unavailable) otherwise.
  defp maybe_highlight_full(nil, _language), do: nil

  defp maybe_highlight_full(content, language) do
    if line_count(content) <= @max_full_file_lines do
      highlight_code_block(content, language)
    else
      nil
    end
  end

  defp line_count(content) do
    content |> String.split("\n") |> length()
  end

  # --- File-level mapping -------------------------------------------------
  #
  # Walks the parsed diff lines hunk-by-hunk. For each hunk, the @@ header
  # gives 1-indexed starting line numbers in the old file and new file. We
  # maintain per-hunk offsets (old_offset, new_offset) that advance as we
  # consume context/addition/deletion lines, and index into the full-file
  # highlight arrays (converted to 0-indexed). Out-of-bounds or nil lookups
  # fall back to the raw line content (not empty string).

  defp precompute_highlights_file_level(lines, new_hl, old_hl) do
    lines
    |> Enum.chunk_while(
      [],
      fn
        %{type: :hunk} = line, [] ->
          {:cont, [line]}

        %{type: :hunk} = line, acc ->
          {:cont, Enum.reverse(acc), [line]}

        line, acc ->
          {:cont, [line | acc]}
      end,
      fn
        [] -> {:cont, []}
        acc -> {:cont, Enum.reverse(acc), []}
      end
    )
    |> Enum.reduce(%{}, fn
      [], acc -> acc
      chunk, acc -> map_hunk_file_level(chunk, new_hl, old_hl, acc)
    end)
  end

  defp map_hunk_file_level(chunk, new_hl, old_hl, acc) do
    # Split the hunk header from the body. Header/meta lines before the first
    # hunk (diff/index/---/+++) are mapped as plain text.
    case Enum.split_with(chunk, &(&1.type != :hunk)) do
      {pre, [%{type: :hunk} = hdr | body]} ->
        pre_acc = Enum.reduce(pre, acc, fn l, a -> Map.put(a, l.line_number, l.content) end)
        header_acc = Map.put(pre_acc, hdr.line_number, hdr.content)
        {old_start, new_start} = parse_hunk_header(hdr.content)
        map_hunk_body(body, new_hl, old_hl, header_acc, old_start, new_start, 0, 0)

      _ ->
        # No hunk header in this chunk — plain text only.
        Enum.reduce(chunk, acc, fn l, a -> Map.put(a, l.line_number, l.content) end)
    end
  end

  defp map_hunk_body([], _new_hl, _old_hl, acc, _old_start, _new_start, _old_off, _new_off) do
    acc
  end

  defp map_hunk_body([line | rest], new_hl, old_hl, acc, old_start, new_start, old_off, new_off) do
    case line.type do
      :context ->
        # Context lines appear in both old and new files; prefer the NEW file's
        # highlighting (the "after" version) so surrounding code matches the
        # final result. Both offsets advance (the line exists in both sides).
        idx = new_start - 1 + new_off
        hl = lookup_highlight(new_hl, idx) || line.content
        map_hunk_body(rest, new_hl, old_hl, Map.put(acc, line.line_number, raw(hl)), old_start, new_start, old_off + 1, new_off + 1)

      :addition ->
        idx = new_start - 1 + new_off
        hl = lookup_highlight(new_hl, idx) || line.content
        map_hunk_body(rest, new_hl, old_hl, Map.put(acc, line.line_number, raw(hl)), old_start, new_start, old_off, new_off + 1)

      :deletion ->
        idx = old_start - 1 + old_off
        hl = lookup_highlight(old_hl, idx) || line.content
        map_hunk_body(rest, new_hl, old_hl, Map.put(acc, line.line_number, raw(hl)), old_start, new_start, old_off + 1, new_off)

      _ ->
        # no_newline / header / meta — plain text, don't advance code offsets.
        map_hunk_body(rest, new_hl, old_hl, Map.put(acc, line.line_number, line.content), old_start, new_start, old_off, new_off)
    end
  end

  # Index into the highlight array; returns nil for out-of-bounds or nil array.
  defp lookup_highlight(nil, _idx), do: nil
  defp lookup_highlight(hl_array, idx) when idx >= 0, do: Enum.at(hl_array, idx)
  defp lookup_highlight(_hl_array, _idx), do: nil

  # Parse the @@ header to extract old_start and new_start line numbers.
  # Format: "@@ -<old_start>[,<count>] +<new_start>[,<count>] @@ <context>"
  # Returns {old_start, new_start} as 1-indexed integers, defaulting to {0, 0}.
  @doc false
  def parse_hunk_header(content) do
    case Regex.run(~r/-\d+(?:,\d+)?\s+\+(\d+)(?:,\d+)?/, content) do
      [_, new_start_str] ->
        new_start = String.to_integer(new_start_str)
        old_start = parse_old_start(content)
        {old_start, new_start}

      _ ->
        {0, 0}
    end
  end

  defp parse_old_start(content) do
    case Regex.run(~r/-(\d+)(?:,\d+)?\s+\+\d+/, content) do
      [_, old_start_str] -> String.to_integer(old_start_str)
      _ -> 0
    end
  end

  # --- Hunk-level fallback (original approach) ----------------------------

  defp precompute_highlights_hunk_level(lines, language) do
    {result, _} = do_precompute(lines, language, %{})
    result
  end

  defp do_precompute([], _language, acc), do: {acc, []}

  # Start of a hunk: collect everything until the next hunk header or end.
  defp do_precompute([%{type: :hunk} = hdr | rest], language, acc) do
    {hunk_body, remaining} = Enum.split_while(rest, fn l -> l.type != :hunk end)
    hunk_lines = [hdr | hunk_body]
    new_acc = highlight_hunk(hunk_lines, language, acc)
    do_precompute(remaining, language, new_acc)
  end

  # Header/meta lines before the first hunk — no highlighting needed.
  defp do_precompute([line | rest], language, acc) do
    do_precompute(rest, language, Map.put(acc, line.line_number, line.content))
  end

  # Highlight a single hunk (including its @@ header line).
  defp highlight_hunk(hunk_lines, language, acc) do
    # Map the hunk header line (plain text)
    acc =
      case hunk_lines do
        [%{type: :hunk} = hdr | _] -> Map.put(acc, hdr.line_number, hdr.content)
        _ -> acc
      end

    old_code = build_hunk_code(hunk_lines, :old)
    new_code = build_hunk_code(hunk_lines, :new)

    old_highlighted = highlight_code_block(old_code, language)
    new_highlighted = highlight_code_block(new_code, language)

    # Walk the hunk lines and map each code line to its highlighted counterpart.
    {_old_i, _new_i, result} =
      Enum.reduce(hunk_lines, {0, 0, acc}, fn
        %{type: :hunk}, counters ->
          counters

        %{type: :context, line_number: ln}, {old_i, new_i, acc2} ->
          hl = Enum.at(old_highlighted, old_i) || Enum.at(new_highlighted, new_i) || ""
          {old_i + 1, new_i + 1, Map.put(acc2, ln, raw(hl))}

        %{type: :addition, line_number: ln}, {old_i, new_i, acc2} ->
          hl = Enum.at(new_highlighted, new_i) || ""
          {old_i, new_i + 1, Map.put(acc2, ln, raw(hl))}

        %{type: :deletion, line_number: ln}, {old_i, new_i, acc2} ->
          hl = Enum.at(old_highlighted, old_i) || ""
          {old_i + 1, new_i, Map.put(acc2, ln, raw(hl))}

        %{type: :no_newline, line_number: ln} = line, {old_i, new_i, acc2} ->
          {old_i, new_i, Map.put(acc2, ln, line.content)}

        _line, counters ->
          counters
      end)

    result
  end

  # Build a clean code string for a hunk, joining lines of the requested type.
  # :old → context + deletion lines (original file)
  # :new → context + addition lines (new file)
  defp build_hunk_code(hunk_lines, :old) do
    hunk_lines
    |> Enum.filter(&(&1.type in [:context, :deletion]))
    |> Enum.map_join("\n", & &1.content)
  end

  defp build_hunk_code(hunk_lines, :new) do
    hunk_lines
    |> Enum.filter(&(&1.type in [:context, :addition]))
    |> Enum.map_join("\n", & &1.content)
  end

  # Call Lumis once for a whole code block, return per-line highlighted HTML.
  defp highlight_code_block(code, language) do
    if code == "" or is_nil(language) do
      String.split(code, "\n")
    else
      try do
        Lumis.highlight!(code,
          formatter:
            {:html_multi_themes,
             language: language,
             themes: [light: "github_light", dark: "github_dark"],
             default_theme: "light-dark()"}
        )
        |> strip_lumis_wrappers()
        |> String.trim_trailing("\n")
        |> split_html_by_newline()
      rescue
        _ -> String.split(code, "\n")
      end
    end
  end

  # Split highlighted HTML by newlines while keeping <span> tags balanced per
  # line. Tree-sitter/Lumis produces multi-line spans (for multi-line strings,
  # block comments, etc.) whose \n falls *inside* a <span>. A naive
  # String.split("\n") would split those spans into orphaned fragments. Instead
  # we walk the HTML, tracking a stack of open spans: at each \n we close all
  # open spans (LIFO) on the current line, then reopen them (FIFO) on the next.
  @doc false
  def split_html_by_newline(html) do
    html
    |> String.to_charlist()
    |> do_split_html_by_newline([], [], [])
    |> Enum.reverse()
    |> Enum.map(&IO.iodata_to_binary/1)
  end

  # End of input: close any remaining open spans on the final line.
  defp do_split_html_by_newline([], current_line, open_tags, lines) do
    final = [current_line | close_span_tags(open_tags)]
    [final | lines]
  end

  # Start of an HTML tag — read the full tag (respecting quoted attributes).
  defp do_split_html_by_newline([?< | _] = chars, current_line, open_tags, lines) do
    {tag, rest} = take_tag(chars)
    tag_str = List.to_string(tag)

    cond do
      opening_span?(tag_str) ->
        do_split_html_by_newline(rest, [current_line, tag_str], [tag_str | open_tags], lines)

      tag_str == "</span>" ->
        do_split_html_by_newline(rest, [current_line, tag_str], drop_one(open_tags), lines)

      true ->
        do_split_html_by_newline(rest, [current_line, tag_str], open_tags, lines)
    end
  end

  # Newline — flush the current line (closing all open spans), reopen on next.
  defp do_split_html_by_newline([?\n | rest], current_line, open_tags, lines) do
    completed = [current_line | close_span_tags(open_tags)]
    reopened = reopen_span_tags(open_tags)
    do_split_html_by_newline(rest, reopened, open_tags, [completed | lines])
  end

  # Regular character.
  defp do_split_html_by_newline([char | rest], current_line, open_tags, lines) do
    do_split_html_by_newline(rest, [current_line, char], open_tags, lines)
  end

  # Extract a full HTML tag from a charlist starting with '<'. Reads until the
  # matching '>' while respecting single/double-quoted attribute values.
  defp take_tag([?< | rest]) do
    take_tag_rest(rest, [?<], nil)
  end

  # '>' outside quotes terminates the tag.
  defp take_tag_rest([?> | rest], acc, nil) do
    {Enum.reverse([?> | acc]), rest}
  end

  # Enter a quoted attribute string.
  defp take_tag_rest([q | rest], acc, nil) when q in [?", ?'] do
    take_tag_rest(rest, [q | acc], q)
  end

  # Exit a quoted attribute string (closing quote matches the opening one).
  defp take_tag_rest([q | rest], acc, q) when q in [?", ?'] do
    take_tag_rest(rest, [q | acc], nil)
  end

  # Any other character (including '>' inside quotes).
  defp take_tag_rest([char | rest], acc, quote_state) do
    take_tag_rest(rest, [char | acc], quote_state)
  end

  defp take_tag_rest([], acc, _quote_state) do
    {Enum.reverse(acc), []}
  end

  defp opening_span?(tag_str) do
    String.starts_with?(tag_str, "<span") and not String.ends_with?(tag_str, "/>")
  end

  # Emit </span> for each open tag, in stack (LIFO) order.
  defp close_span_tags(open_tags) do
    Enum.map(open_tags, fn _ -> "</span>" end)
  end

  # Reopen spans in original (FIFO) order — reverse of the stack.
  defp reopen_span_tags(open_tags) do
    Enum.reverse(open_tags)
  end

  defp drop_one([]), do: []
  defp drop_one([_ | rest]), do: rest

  # Strip <pre class="lumis" ...><code ...>...</code></pre> wrappers AND the
  # per-line <div class="l-line" data-line="N">...</div> wrappers that Lumis
  # emits around each highlighted line, keeping only the inner <span> elements
  # with syntax colors. The div wrappers are block-level elements that would
  # break the flex diff-line layout, so they must be removed before splitting.
  @doc false
  def strip_lumis_wrappers(html) do
    html
    |> String.replace(~r/^<pre[^>]*><code[^>]*>/, "")
    |> String.replace(~r/<\/code><\/pre>$/, "")
    |> String.replace(~r/<\/?div[^>]*>/, "")
  end

  # Convert a file path to a valid HTML id (replace / and . with -)
  defp file_path_to_id(path) do
    path
    |> String.replace(~r{[^a-zA-Z0-9_-]}, "-")
    |> String.trim("-")
  end

  defp file_status_icon("added"), do: "hero-plus-circle"
  defp file_status_icon("deleted"), do: "hero-minus-circle"
  defp file_status_icon("modified"), do: "hero-pencil-square"
  defp file_status_icon(_), do: "hero-document"

  defp file_status_color("added"), do: "text-success"
  defp file_status_color("deleted"), do: "text-error"
  defp file_status_color("modified"), do: "text-info"
  defp file_status_color(_), do: "text-base-content/50"

  # Group files by their parent directory. Returns a list of {group_key, files} tuples
  # sorted alphabetically, with :root first for files at the top level.
  defp group_files_by_dir(files) do
    files
    |> Enum.group_by(fn file ->
      case Path.dirname(file.path) do
        "." -> :root
        dir -> dir
      end
    end)
    |> Enum.sort_by(fn
      {:root, _} -> {0, ""}
      {dir, _} -> {1, dir}
    end)
  end

  # Calculate total additions and deletions for a group of files
  defp dir_stats(files) do
    additions = Enum.sum(Enum.map(files, & &1.additions))
    deletions = Enum.sum(Enum.map(files, & &1.deletions))
    {additions, deletions}
  end
end
