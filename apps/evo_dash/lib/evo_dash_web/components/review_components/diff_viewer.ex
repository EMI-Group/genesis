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
              <.icon name={file_status_icon(file.status)} class={"size-3.5 shrink-0 #{file_status_color(file.status)}"} />
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
                  class={["file-item file-item-indented", @selected_file == file.path && "file-selected"]}
                >
                  <.icon name={file_status_icon(file.status)} class={"size-3.5 shrink-0 #{file_status_color(file.status)}"} />
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
            <.icon name={file_status_icon(file.status)} class={"size-3.5 #{file_status_color(file.status)}"} />
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
    assigns = %{file: file, file_path: file_path, context_level: context_level}

    ~H"""
    <div class="text-xs font-mono">
      <%= if is_nil(@file.diff) do %>
        <div class="flex items-center justify-center py-8 gap-2 text-base-content/50">
          <span class="loading loading-spinner loading-sm"></span>
          <span><%= gettext("Loading diff...") %></span>
        </div>
      <% else %>
        <% lines = parse_diff_lines(@file) %>
        <% {hunk_starts, _} =
            Enum.reduce(lines, {[], 0}, fn line, {acc, idx} ->
              if line.type == :hunk, do: {[idx | acc], idx + 1}, else: {acc, idx + 1}
            end) %>
        <% hunk_indices = Enum.reverse(hunk_starts) %>
        <% show_top_expand = length(hunk_indices) > 0 %>
        <% show_bottom_expand = @context_level != :all %>
        <%= if show_top_expand do %>
          <.diff_expand_bar path={@file_path} context_level={@context_level} />
        <% end %>
        <%= for {line, i} <- Enum.with_index(lines) do %>
          <%= if i in hunk_indices and i > 0 do %>
            <.diff_expand_bar path={@file_path} context_level={@context_level} />
          <% end %>
          <div class={["diff-line", diff_line_class(line.type)]}>
            <span class="diff-line-gutter">{line.line_number}</span>
            <span class={["diff-line-prefix", diff_prefix_color(line.type)]}>{line.prefix}</span>
            <span class="diff-line-content" phx-no-format>{if line.type in [:addition, :deletion, :context], do: highlight_line_content(line.content, @file.language), else: line.content}</span>
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
  defp parse_diff_lines(file) do
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

        true ->
          content = if String.length(line) > 0, do: String.slice(line, 1..-1//1), else: ""
          %{line_number: idx, prefix: " ", content: content, type: :context}
      end
    end)
  end

  # Syntax highlighting using Lumis multi-themes for light/dark support.
  # Strips the <pre>/<code> wrappers since we render lines individually.
  #
  # This try/rescue is JUSTIFIED:
  #   - Lumis.highlight!/2 raises on invalid/unexpected input (malformed code,
  #     unsupported language, binary-encoded edge cases). The non-bang variant
  #     Lumis.highlight/2 also raises internally (it does NOT return {:error, _}
  #     despite what the docs suggest), so case/with cannot cleanly replace it.
  #   - This is called per-line in a diff viewer, so offloading to a separate
  #     process (Task/async) is impractical — it would spawn one task per line.
  #   - Falling back to the raw (un-highlighted) content is the correct graceful
  #     degradation: the line is still visible, just without syntax coloring.
  defp highlight_line_content(content, language) do
    if content && String.length(content) > 0 do
      try do
        Lumis.highlight!(content,
          formatter:
            {:html_multi_themes,
             language: language,
             themes: [light: "github_light", dark: "github_dark"],
             default_theme: "light-dark()"}
        )
        |> strip_lumis_wrappers()
        |> raw()
      rescue
        _ -> content
      end
    else
      ""
    end
  end

  # Strip <pre class="lumis" ...><code ...>...</code></pre> wrappers,
  # keeping only the inner <span> elements with syntax colors.
  defp strip_lumis_wrappers(html) do
    html
    |> String.replace(~r/^<pre[^>]*><code[^>]*>/, "")
    |> String.replace(~r/<\/code><\/pre>$/, "")
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
