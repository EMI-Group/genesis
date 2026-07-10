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

    # Group lines into segments: pre-hunk lines (meta/header) and hunk blocks.
    # Each hunk block becomes a list of split-view pairs.
    segments = build_diff_segments(lines)

    assigns = %{
      file: file,
      file_path: file_path,
      context_level: context_level,
      segments: segments,
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
        <% show_bottom_expand = @context_level != :all %>
        <div class="diff-split-table">
          <%= if length(@segments) > 0 and @context_level != :all do %>
            <.diff_expand_bar path={@file_path} context_level={@context_level} />
          <% end %>
          <%= for segment <- @segments do %>
            <%= case segment do %>
              <% {:pre_hunk, pre_lines} -> %>
                <%= for line <- pre_lines do %>
                  <div class={["diff-split-pre-hunk", diff_line_class(line.type)]}>
                    <span class="diff-line-content" phx-no-format>{Map.get(@highlighted, line.line_number, line.content)}</span>
                  </div>
                <% end %>
              <% {:hunk, hunk_line, pairs} -> %>
                <div class="diff-split-hunk">
                  <span class="diff-line-content" phx-no-format>{hunk_line.content}</span>
                </div>
                <%= for pair <- pairs do %>
                  <.diff_split_row pair={pair} highlighted={@highlighted} />
                <% end %>
            <% end %>
          <% end %>
          <%= if show_bottom_expand do %>
            <.diff_expand_bar path={@file_path} context_level={@context_level} />
          <% end %>
        </div>
      <% end %>
    </div>
    """
  end

  # A single row in the split-view diff. Renders 4 grid cells: old gutter,
  # old content, new gutter, new content. Either side may be nil (blank).
  attr(:pair, :map, required: true)
  attr(:highlighted, :map, required: true)

  defp diff_split_row(assigns) do
    %{left: left, right: right, type: type} = assigns.pair

    row_class =
      case type do
        :addition -> "diff-split-row diff-split-row-addition"
        :deletion -> "diff-split-row diff-split-row-deletion"
        :context -> "diff-split-row diff-split-row-context"
        _ -> "diff-split-row"
      end

    left_num = if left, do: left.line_num, else: ""
    right_num = if right, do: right.line_num, else: ""

    left_content =
      if left,
        do: Map.get(assigns.highlighted, left.line.line_number, left.line.content),
        else: ""

    right_content =
      if right,
        do: Map.get(assigns.highlighted, right.line.line_number, right.line.content),
        else: ""

    assigns =
      assigns
      |> assign(:row_class, row_class)
      |> assign(:left_num, left_num)
      |> assign(:right_num, right_num)
      |> assign(:left_content, left_content)
      |> assign(:right_content, right_content)

    ~H"""
    <div class={@row_class}>
      <span class="diff-split-gutter diff-split-gutter-left">{@left_num}</span>
      <span class="diff-split-cell diff-split-cell-left" phx-no-format>{@left_content}</span>
      <span class="diff-split-gutter diff-split-gutter-right">{@right_num}</span>
      <span class="diff-split-cell diff-split-cell-right" phx-no-format>{@right_content}</span>
    </div>
    """
  end

  # Group parsed diff lines into segments for split-view rendering.
  # Returns a list of:
  #   {:pre_hunk, [lines]}  — meta/header lines before the first hunk
  #   {:hunk, hunk_line, [pairs]} — a hunk header + its split-view pairs
  #
  # Lines before the first @@ hunk header (diff/index/---/+++) are collected
  # as :pre_hunk. Each hunk is split into its header line and a body that
  # gets converted to split-view pairs via build_split_pairs/1.
  defp build_diff_segments(lines) do
    {pre, first_hunk_idx} =
      case Enum.find_index(lines, &(&1.type == :hunk)) do
        nil -> {lines, nil}
        idx -> {Enum.take(lines, idx), idx}
      end

    hunk_lines = if first_hunk_idx, do: Enum.drop(lines, first_hunk_idx), else: []

    pre_segment = if pre == [], do: [], else: [{:pre_hunk, pre}]

    hunk_segments =
      hunk_lines
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
      |> Enum.map(fn chunk ->
        [hdr | body] = chunk
        {old_start, new_start} = parse_hunk_header(hdr.content)
        pairs = build_split_pairs(body, old_start, new_start)
        {:hunk, hdr, pairs}
      end)

    pre_segment ++ hunk_segments
  end

  # Build split-view pairs from a hunk's body lines.
  #
  # Walks the hunk body, maintaining old_line_num and new_line_num counters
  # (initialized from the @@ header's old_start/new_start). Context lines
  # appear on both sides; deletions only on the left; additions only on the
  # right. Consecutive deletions and additions are zipped together (padding
  # the shorter side with blank placeholders).
  #
  # Returns a list of pairs:
  #   %{left: %{line: line, line_num: n} | nil, right: %{...} | nil, type: atom}
  @doc false
  def build_split_pairs(hunk_body, old_start \\ nil, new_start \\ nil)

  def build_split_pairs([], _old_start, _new_start), do: []

  def build_split_pairs(hunk_body, old_start, new_start) do
    {old_start, new_start} =
      case {old_start, new_start} do
        {nil, nil} ->
          case Enum.find(hunk_body, &(&1.type == :hunk)) do
            %{type: :hunk, content: content} -> parse_hunk_header(content)
            _ -> {1, 1}
          end

        _ ->
          {old_start || 1, new_start || 1}
      end

    state = {[], old_start, new_start, [], []}

    {pairs, old_num, new_num, old_buf, new_buf} =
      Enum.reduce(hunk_body, state, fn
        %{type: :context} = line, {acc, old_num, new_num, old_buf, new_buf} ->
          {flushed, o_num, n_num} = flush_buffers(old_buf, new_buf, old_num, new_num, acc)
          pair = %{
            left: %{line: line, line_num: o_num},
            right: %{line: line, line_num: n_num},
            type: :context
          }
          {flushed ++ [pair], o_num + 1, n_num + 1, [], []}

        %{type: :deletion} = line, {acc, old_num, new_num, old_buf, new_buf} ->
          {acc, old_num, new_num, [line | old_buf], new_buf}

        %{type: :addition} = line, {acc, old_num, new_num, old_buf, new_buf} ->
          {acc, old_num, new_num, old_buf, [line | new_buf]}

        %{type: :no_newline} = line, {acc, old_num, new_num, old_buf, new_buf} ->
          {flushed, o_num, n_num} = flush_buffers(old_buf, new_buf, old_num, new_num, acc)
          pair = %{
            left: %{line: line, line_num: nil},
            right: %{line: line, line_num: nil},
            type: :no_newline
          }
          {flushed ++ [pair], o_num, n_num, [], []}

        _line, acc ->
          acc
      end)

    {final, _, _} = flush_buffers(old_buf, new_buf, old_num, new_num, pairs)
    final
  end

  # Zip old_buf and new_buf into split-view pairs, padding the shorter side
  # with nil placeholders. old_buf and new_buf are in reverse order (built
  # with prepend), so we reverse them first. Returns {pairs ++ new_pairs,
  # advanced_old_num, advanced_new_num}.
  defp flush_buffers([], [], old_num, new_num, acc) do
    {acc, old_num, new_num}
  end

  defp flush_buffers(old_buf, new_buf, old_num, new_num, acc) do
    old_list = Enum.reverse(old_buf)
    new_list = Enum.reverse(new_buf)
    max_len = max(length(old_list), length(new_list))

    {pairs, o_num, n_num} =
      Enum.reduce(0..(max_len - 1), {[], old_num, new_num}, fn i, {p_acc, o, n} ->
        old_line = Enum.at(old_list, i)
        new_line = Enum.at(new_list, i)

        {left, o2} =
          if old_line do
            {%{line: old_line, line_num: o}, o + 1}
          else
            {nil, o}
          end

        {right, n2} =
          if new_line do
            {%{line: new_line, line_num: n}, n + 1}
          else
            {nil, n}
          end

        type =
          cond do
            old_line != nil and new_line != nil -> :mixed
            old_line != nil -> :deletion
            new_line != nil -> :addition
          end

        {p_acc ++ [%{left: left, right: right, type: type}], o2, n2}
      end)

    {acc ++ pairs, o_num, n_num}
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
  # and produces consistent highlighting. The Lumis HTML output is parsed into
  # a map %{line_number => inner_html} via data-line attributes. We walk the
  # diff hunk-by-hunk, using the @@ header line numbers to index into the
  # full-file highlight maps.
  #
  # FALLBACK (hunk-level): When full content is unavailable (added/deleted
  # files where content fetch failed, or binary/oversized files),
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

  # Text files larger than this byte size fall back to hunk-level highlighting
  # to avoid performance issues. 500KB covers the vast majority of real source
  # files; generated/minified files exceeding this are poor candidates for
  # Tree-sitter highlighting anyway.
  @max_full_file_bytes 500_000

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

  # Highlight the full file content if it is present, is not binary, and is
  # under the byte-size threshold. Returns nil (treat as unavailable) otherwise.
  defp maybe_highlight_full(nil, _language), do: nil

  defp maybe_highlight_full(content, language) do
    cond do
      binary_content?(content) -> nil
      byte_size(content) >= @max_full_file_bytes -> nil
      true -> highlight_code_block(content, language)
    end
  end

  # Detect binary content by checking for null bytes in the first 8KB —
  # mirrors git's own binary detection heuristic.
  defp binary_content?(content) do
    chunk = binary_part(content, 0, min(byte_size(content), 8192))
    :binary.match(chunk, <<0>>) != :nomatch
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
    #
    # IMPORTANT: use split_while (not split_with). split_with partitions ALL
    # non-hunk lines into the first list regardless of position — since each
    # chunk starts with the :hunk header, that would put the entire body into
    # `pre`, bypassing map_hunk_body and dropping all syntax highlighting.
    # split_while stops at the FIRST element that fails the predicate, giving
    # {pre_hunk_meta_lines, [hunk_header | body]}.
    case Enum.split_while(chunk, &(&1.type != :hunk)) do
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
        line_num = new_start + new_off
        hl = lookup_highlight(new_hl, line_num) || line.content
        map_hunk_body(rest, new_hl, old_hl, Map.put(acc, line.line_number, raw(hl)), old_start, new_start, old_off + 1, new_off + 1)

      :addition ->
        line_num = new_start + new_off
        hl = lookup_highlight(new_hl, line_num) || line.content
        map_hunk_body(rest, new_hl, old_hl, Map.put(acc, line.line_number, raw(hl)), old_start, new_start, old_off, new_off + 1)

      :deletion ->
        line_num = old_start + old_off
        hl = lookup_highlight(old_hl, line_num) || line.content
        map_hunk_body(rest, new_hl, old_hl, Map.put(acc, line.line_number, raw(hl)), old_start, new_start, old_off + 1, new_off)

      _ ->
        # no_newline / header / meta — plain text, don't advance code offsets.
        map_hunk_body(rest, new_hl, old_hl, Map.put(acc, line.line_number, line.content), old_start, new_start, old_off, new_off)
    end
  end

  # Index into the highlight map; returns nil for missing key or nil map.
  defp lookup_highlight(nil, _line_num), do: nil
  defp lookup_highlight(hl_map, line_num) when is_map(hl_map), do: Map.get(hl_map, line_num)
  defp lookup_highlight(_hl_map, _line_num), do: nil

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
    # highlight_code_block/2 now returns a map %{line_number => html}, and the
    # hunk code is built fresh so data-line numbers start at 1 within each hunk.
    {_old_i, _new_i, result} =
      Enum.reduce(hunk_lines, {0, 0, acc}, fn
        %{type: :hunk}, counters ->
          counters

        %{type: :context, line_number: ln}, {old_i, new_i, acc2} ->
          hl = Map.get(old_highlighted, old_i + 1) || Map.get(new_highlighted, new_i + 1) || ""
          {old_i + 1, new_i + 1, Map.put(acc2, ln, raw(hl))}

        %{type: :addition, line_number: ln}, {old_i, new_i, acc2} ->
          hl = Map.get(new_highlighted, new_i + 1) || ""
          {old_i, new_i + 1, Map.put(acc2, ln, raw(hl))}

        %{type: :deletion, line_number: ln}, {old_i, new_i, acc2} ->
          hl = Map.get(old_highlighted, old_i + 1) || ""
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

  # Call Lumis once for a whole code block, return per-line highlighted HTML as
  # a map %{line_number => inner_html}. Returns %{1 => plain, ...} for nil
  # language or empty code (1-based line numbers).
  defp highlight_code_block(code, language) do
    if code == "" or is_nil(language) do
      code
      |> String.split("\n")
      |> Enum.with_index(1)
      |> Enum.reduce(%{}, fn {content, line_num}, acc ->
        Map.put(acc, line_num, content)
      end)
    else
      try do
        Lumis.highlight!(code,
          formatter:
            {:html_multi_themes,
             language: language,
             themes: [light: "github_light", dark: "github_dark"],
             default_theme: "light-dark()"}
        )
        |> parse_lumis_lines()
      rescue
        _ ->
          code
          |> String.split("\n")
          |> Enum.with_index(1)
          |> Enum.reduce(%{}, fn {content, line_num}, acc ->
            Map.put(acc, line_num, content)
          end)
      end
    end
  end

  # Parse Lumis HTML output into a map of %{line_number => inner_html}.
  #
  # Lumis output format:
  #   <pre class="lumis" ...><code ...>
  #   <div class="l-line" data-line="1"><span>...</span></div>
  #   <div class="l-line" data-line="2"><span>...</span></div>
  #   </code></pre>
  #
  # Uses Floki (with the html5ever parser configured in Application.start/1)
  # for robust HTML parsing instead of fragile regex. Each .l-line div's
  # data-line attribute gives the 1-based line number; the children's raw HTML
  # gives the highlighted inner content (preserving <span> elements).
  @doc false
  def parse_lumis_lines(html) do
    case Floki.parse_document(html) do
      {:ok, document} ->
        document
        |> Floki.find(".l-line")
        |> Enum.reduce(%{}, fn line_div, acc ->
          line_num =
            line_div
            |> Floki.attribute("data-line")
            |> List.first()
            |> String.to_integer()

          inner_html = line_div |> Floki.children() |> Floki.raw_html()
          Map.put(acc, line_num, inner_html)
        end)

      {:error, _} ->
        %{}
    end
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
