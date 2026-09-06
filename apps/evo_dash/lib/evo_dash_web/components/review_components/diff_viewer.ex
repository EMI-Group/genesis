defmodule EvoDashWeb.ReviewComponents.DiffViewer do
  @moduledoc false
  use EvoDashWeb, :html

  # ---------------------------------------------------------------------------
  # file_tree_sidebar/1 — Sidebar file tree for the split-pane layout.
  #
  # The tree state is server-driven (no <details> elements): directory
  # expansion comes from the LiveView via `expanded_dirs` (dir path => boolean,
  # directories collapsed by default) and the flat filter mode via
  # `file_filter` (non-blank => flat case-insensitive full-path match, no
  # directory nodes).
  # ---------------------------------------------------------------------------

  attr(:files, :list, required: true)
  attr(:selected_file, :string, default: nil)
  attr(:expanded_dirs, :map, default: %{})
  attr(:file_filter, :string, default: "")

  def file_tree_sidebar(assigns) do
    ~H"""
    <div class="w-full lg:w-72 shrink-0 lg:sticky lg:top-0 lg:max-h-[100dvh] overflow-y-auto rounded-xl border border-base-300 bg-base-100">
      <div class="p-3 border-b border-base-300 bg-base-200/40 sticky top-0 z-10">
        <div class="flex items-center gap-2">
          <%!-- zh_CN: "Files changed" → 变更文件（评审文件树侧栏标题） --%>
          <h3 class="flex-1 min-w-0 truncate font-semibold text-xs text-base-content/60 uppercase tracking-wider">
            {gettext("Files changed")}
          </h3>
          <span class="font-mono text-xs text-base-content/60 shrink-0">{length(@files)}</span>
        </div>
        <div class="relative mt-2">
          <.icon
            name="hero-magnifying-glass"
            class="size-3.5 absolute left-2.5 top-1/2 -translate-y-1/2 text-base-content/40 pointer-events-none"
          />
          <%!-- zh_CN: "Filter files…" → 按路径筛选文件…（文件过滤框占位符） --%>
          <input
            type="text"
            name="filter"
            phx-change="filter_files"
            phx-debounce="200"
            value={@file_filter}
            placeholder={gettext("Filter files…")}
            class="input input-sm input-bordered rounded-lg w-full pl-8"
          />
        </div>
        <div class="flex items-center gap-2 mt-2">
          <%!-- zh_CN: "Collapse all" → 全部折叠（收起所有目录） --%>
          <button
            type="button"
            phx-click="collapse_all_dirs"
            class="btn btn-ghost btn-xs rounded-md gap-1"
          >
            <.icon name="hero-chevron-up-down" class="size-3" />
            {gettext("Collapse all")}
          </button>
          <%!-- zh_CN: "Expand all" → 全部展开（展开所有目录） --%>
          <button type="button" phx-click="expand_all_dirs" class="btn btn-ghost btn-xs rounded-md">
            {gettext("Expand all")}
          </button>
        </div>
      </div>
      <div class="p-1.5">
        <%= if String.trim(@file_filter) != "" do %>
          <% filter = String.downcase(String.trim(@file_filter)) %>
          <% matches = Enum.filter(@files, &String.contains?(String.downcase(&1.path), filter)) %>
          <%= if matches == [] do %>
            <%!-- zh_CN: "No matching files" → 没有匹配的文件（筛选无结果时的空状态） --%>
            <p class="px-2 py-3 text-xs text-base-content/50">{gettext("No matching files")}</p>
          <% else %>
            <%= for file <- matches do %>
              <.file_row
                path={file.path}
                name={Path.basename(file.path)}
                status={file.status}
                additions={file.additions}
                deletions={file.deletions}
                depth={0}
                selected_file={@selected_file}
              />
            <% end %>
          <% end %>
        <% else %>
          <%= for node <- build_file_tree(@files) do %>
            <.tree_node
              node={node}
              depth={0}
              selected_file={@selected_file}
              expanded_dirs={@expanded_dirs}
            />
          <% end %>
        <% end %>
      </div>
    </div>
    """
  end

  # ---------------------------------------------------------------------------
  # tree_node/1 — Recursive tree renderer.
  #
  # Directory nodes are plain buttons firing `toggle_dir` with the FULL dir
  # path; children render only while the dir is open (server-driven state).
  # File nodes delegate to the shared file_row/1 renderer.
  # ---------------------------------------------------------------------------

  attr(:node, :map, required: true)
  attr(:depth, :integer, required: true)
  attr(:selected_file, :string, default: nil)
  attr(:expanded_dirs, :map, default: %{})

  def tree_node(%{node: %{type: :dir}} = assigns) do
    assigns =
      assign(assigns, :open, Map.get(assigns.expanded_dirs, assigns.node.path, false))

    ~H"""
    <div>
      <button
        type="button"
        phx-click="toggle_dir"
        phx-value-dir={@node.path}
        aria-expanded={if @open, do: "true", else: "false"}
        class="w-full flex items-center gap-1.5 px-2 py-1.5 rounded-md hover:bg-base-200/60 text-xs transition-colors"
        style={"padding-left: #{0.75 + @depth * 0.75}rem"}
      >
        <.icon
          name="hero-chevron-right"
          class={"size-3 shrink-0 text-base-content/50 transition-transform #{if @open, do: "rotate-90", else: ""}"}
        />
        <.icon
          name={if @open, do: "hero-folder-open", else: "hero-folder"}
          class="size-3.5 shrink-0 text-base-content/50"
        />
        <span class="font-mono truncate flex-1 min-w-0 text-left" title={@node.path}>
          {@node.name}
        </span>
        <span class="shrink-0 flex items-center gap-1 font-mono text-[10px] leading-none text-base-content/60">
          {ngettext("%{count} file", "%{count} files", @node.file_count, count: @node.file_count)}
          <span class="text-success">+{@node.additions}</span>
          <span class="text-error">-{@node.deletions}</span>
        </span>
      </button>
      <%= if @open do %>
        <%= for child <- @node.children do %>
          <.tree_node
            node={child}
            depth={@depth + 1}
            selected_file={@selected_file}
            expanded_dirs={@expanded_dirs}
          />
        <% end %>
      <% end %>
    </div>
    """
  end

  def tree_node(%{node: %{type: :file}} = assigns) do
    ~H"""
    <.file_row
      path={@node.path}
      name={@node.name}
      status={@node.status}
      additions={@node.additions}
      deletions={@node.deletions}
      depth={@depth}
      selected_file={@selected_file}
    />
    """
  end

  # Shared file-row renderer — used both by the tree (file nodes at any depth)
  # and by the flat filtered list (depth 0).
  attr(:path, :string, required: true)
  attr(:name, :string, required: true)
  attr(:status, :string, default: nil)
  attr(:additions, :integer, default: 0)
  attr(:deletions, :integer, default: 0)
  attr(:depth, :integer, default: 0)
  attr(:selected_file, :string, default: nil)

  defp file_row(assigns) do
    ~H"""
    <button
      type="button"
      phx-click="select_file"
      phx-value-path={@path}
      class={[
        "w-full flex items-center gap-1.5 px-2 py-1.5 rounded-md text-xs transition-colors",
        (@selected_file == @path && "bg-primary/10 text-primary") || "hover:bg-base-200/60"
      ]}
      style={"padding-left: #{0.75 + @depth * 0.75}rem"}
    >
      <.icon
        name={file_status_icon(@status)}
        class={"size-3.5 shrink-0 #{file_status_color(@status)}"}
      />
      <span class="font-mono truncate flex-1 min-w-0 text-left" title={@path}>
        {@name}
      </span>
      <span class="shrink-0 font-mono text-[10px] leading-none text-success">+{@additions}</span>
      <span class="shrink-0 font-mono text-[10px] leading-none text-error">-{@deletions}</span>
    </button>
    """
  end

  # ---------------------------------------------------------------------------
  # diff_viewer/1 — GitHub-style diff viewer (syntax highlighting is applied
  # client-side by the DiffViewer JS hook).
  #
  # DOM/hook contract (do not break): #diff-viewer carries the single
  # `DiffViewer` hook; each file renders a .diff-file-section with
  # id="file-section-<sanitized path>" and an optional data-language; diff
  # content is ESCAPED plain text only (highlighting is 100% client-side).
  # ---------------------------------------------------------------------------

  attr(:files, :list, required: true)
  attr(:expanded_files, :map, default: %{})
  attr(:selected_file, :string, default: nil)
  attr(:file_context_levels, :map, default: %{})

  def diff_viewer(assigns) do
    ~H"""
    <div class="diff-main-content space-y-3" id="diff-viewer" phx-hook="DiffViewer">
      <%= for file <- @files do %>
        <div
          class="diff-file-section rounded-xl border border-base-300 overflow-hidden bg-base-100"
          id={"file-section-#{file_path_to_id(file.path)}"}
          data-language={file.language}
        >
          <button
            phx-click="toggle_file_expansion"
            phx-value-path={file.path}
            class="diff-file-header w-full text-left flex items-center gap-2 px-4 py-2.5 bg-base-200/70 backdrop-blur-sm text-sm"
          >
            <.icon
              name="hero-chevron-right"
              class={"size-3.5 transition-transform shrink-0 #{if Map.get(@expanded_files, file.path, false), do: "rotate-90", else: ""}"}
            />
            <.icon
              name={file_status_icon(file.status)}
              class={"size-3.5 shrink-0 #{file_status_color(file.status)}"}
            />
            <span class="truncate flex-1 font-mono">{file.path}</span>
            <span class="shrink-0 text-xs font-mono text-success">+{file.additions}</span>
            <span class="shrink-0 text-xs font-mono text-error">-{file.deletions}</span>
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
  # split_diff_layout/1 — Full-width split layout: optional multi-repo
  # toolbar + file-tree sidebar + diff column.
  # ---------------------------------------------------------------------------

  attr(:files, :list, required: true)
  attr(:expanded_files, :map, default: %{})
  attr(:selected_file, :string, default: nil)
  attr(:file_context_levels, :map, default: %{})
  attr(:expanded_dirs, :map, default: %{})
  attr(:file_filter, :string, default: "")
  attr(:repos, :list, default: [])
  attr(:active_repo_id, :string, default: "primary")

  def split_diff_layout(assigns) do
    assigns =
      assigns
      |> assign(:total_additions, sum_files(assigns.files, :additions))
      |> assign(:total_deletions, sum_files(assigns.files, :deletions))

    ~H"""
    <div>
      <%= if length(@repos) > 1 do %>
        <div class="flex items-center gap-3 px-4 py-2.5 rounded-xl border border-base-300 bg-base-100 mb-3">
          <%!-- heroicons has no folder-stack glyph; rectangle-stack is the closest stacked-repositories icon --%>
          <.icon name="hero-rectangle-stack" class="size-4 shrink-0 text-base-content/50" />
          <%!-- zh_CN: "Repository" → 仓库（切换评审仓库的标签，多仓库评审时选择当前查看的仓库） --%>
          <label class="flex items-center gap-2 min-w-0">
            <span class="text-sm text-base-content/60 whitespace-nowrap">{gettext("Repository")}</span>
            <select
              name="repo_id"
              phx-change="switch_repo"
              aria-label={gettext("Repository")}
              class="select select-sm rounded-lg border-base-300 max-w-56"
            >
              <option
                :for={repo <- @repos}
                value={repo[:repo_id]}
                selected={repo[:repo_id] == @active_repo_id}
              >
                {repo_option_label(repo)}
              </option>
            </select>
          </label>
          <div class="ml-auto shrink-0 flex items-center gap-2 font-mono text-xs">
            <span class="text-success">+{@total_additions}</span>
            <span class="text-error">-{@total_deletions}</span>
          </div>
        </div>
      <% end %>
      <div class="flex flex-col lg:flex-row gap-3 items-start">
        <.file_tree_sidebar
          files={@files}
          selected_file={@selected_file}
          expanded_dirs={@expanded_dirs}
          file_filter={@file_filter}
        />
        <div class="flex-1 min-w-0 w-full space-y-3">
          <.diff_viewer
            files={@files}
            expanded_files={@expanded_files}
            selected_file={@selected_file}
            file_context_levels={@file_context_levels}
          />
        </div>
      </div>
    </div>
    """
  end

  # ---------------------------------------------------------------------------
  # commit_detail_header/1 — Header for a commit inspection view
  # ---------------------------------------------------------------------------

  attr(:commit, :map, required: true)
  attr(:back_url, :string, required: true)
  attr(:task_title, :string, default: nil)

  def commit_detail_header(assigns) do
    ~H"""
    <div class="rounded-xl border border-base-300 bg-base-100 p-4 mb-3">
      <div class="flex items-center gap-2">
        <%!-- zh_CN: "Back to review" → 返回评审页（提交详情页左上角的返回按钮） --%>
        <a
          href={@back_url}
          title={gettext("Back to review")}
          aria-label={gettext("Back to review")}
          class="btn btn-ghost btn-sm btn-square rounded-lg shrink-0"
        >
          <.icon name="hero-arrow-left" class="size-4" />
        </a>
        <h1 class="text-base font-semibold truncate flex-1 min-w-0" title={@commit.message}>
          {@commit.message}
        </h1>
      </div>
      <div class="mt-2 flex flex-wrap items-center gap-x-3 gap-y-1 text-sm min-w-0">
        <span class="badge badge-sm badge-ghost font-mono shrink-0">
          {String.slice(@commit.sha, 0..7)}
        </span>
        <span class="text-base-content/70 truncate min-w-0">{@commit.author_name}</span>
        <span class="text-base-content/60 shrink-0">{relative_time(@commit.date)}</span>
        <%= if @task_title do %>
          <span class="text-base-content/60 truncate min-w-0" title={@task_title}>
            {@task_title}
          </span>
        <% end %>
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
  attr(:expanded_dirs, :map, default: %{})
  attr(:file_filter, :string, default: "")

  def commit_diff_layout(assigns) do
    ~H"""
    <div class="flex flex-col lg:flex-row gap-3 items-start">
      <.file_tree_sidebar
        files={@files}
        selected_file={@selected_file}
        expanded_dirs={@expanded_dirs}
        file_filter={@file_filter}
      />
      <div class="flex-1 min-w-0 w-full space-y-3">
        <.diff_viewer
          files={@files}
          expanded_files={@expanded_files}
          selected_file={@selected_file}
          file_context_levels={@file_context_levels}
        />
      </div>
    </div>
    """
  end

  # ---------------------------------------------------------------------------
  # Private helpers
  # ---------------------------------------------------------------------------

  # Sum one integer stat (:additions / :deletions) across the file list.
  defp sum_files(files, key) do
    Enum.reduce(files, 0, fn file, acc -> acc + (Map.get(file, key) || 0) end)
  end

  # Repo select option label: "<repo_id> — <truncated path>"; the path part is
  # dropped entirely when the repo map carries no usable path.
  defp repo_option_label(repo) do
    path = repo |> Map.get(:repo_path) |> truncate_string(30)

    if path == "" do
      "#{repo[:repo_id]}"
    else
      "#{repo[:repo_id]} — #{path}"
    end
  end

  defp render_diff_content(file, file_path, context_level) do
    lines = if file.diff, do: parse_diff_lines(file), else: []

    # Group lines into segments: pre-hunk lines (meta/header) and hunk blocks.
    # Each hunk block becomes a list of split-view pairs.
    segments = build_diff_segments(lines)

    assigns = %{
      file: file,
      file_path: file_path,
      context_level: context_level,
      segments: segments
    }

    ~H"""
    <div class="text-xs font-mono">
      <%= if is_nil(@file.diff) do %>
        <div class="flex items-center justify-center py-8 gap-2 text-base-content/60">
          <span class="loading loading-spinner loading-sm"></span>
          <span>{gettext("Loading diff...")}</span>
        </div>
      <% else %>
        <% show_bottom_expand = @context_level != :all %>
        <div class="diff-split-table">
          <%= if length(@segments) > 0 and @context_level != :all do %>
            <.diff_expand_bar path={@file_path} context_level={@context_level} direction={:above} />
          <% end %>
          <%= for segment <- @segments do %>
            <%= case segment do %>
              <% {:pre_hunk, pre_lines} -> %>
                <%= for line <- pre_lines do %>
                  <div class={["diff-split-pre-hunk", diff_line_class(line.type)]}>
                    <span class="diff-line-content" phx-no-format>{line.content}</span>
                  </div>
                <% end %>
              <% {:hunk, hunk_line, pairs} -> %>
                <div class="diff-split-hunk">
                  <span class="diff-line-content" phx-no-format>{hunk_line.content}</span>
                </div>
                <%= for pair <- pairs do %>
                  <.diff_split_row pair={pair} />
                <% end %>
            <% end %>
          <% end %>
          <%= if show_bottom_expand do %>
            <.diff_expand_bar path={@file_path} context_level={@context_level} direction={:below} />
          <% end %>
        </div>
      <% end %>
    </div>
    """
  end

  # A single row in the split-view diff. Renders 4 grid cells: old gutter,
  # old content, new gutter, new content. Either side may be nil (blank).
  attr(:pair, :map, required: true)

  defp diff_split_row(assigns) do
    %{left: left, right: right, type: type} = assigns.pair

    row_class =
      case type do
        :addition -> "diff-split-row diff-split-row-addition"
        :deletion -> "diff-split-row diff-split-row-deletion"
        :context -> "diff-split-row diff-split-row-context"
        :mixed -> "diff-split-row diff-split-row-mixed"
        _ -> "diff-split-row"
      end

    left_num = if left, do: left.line_num, else: ""
    right_num = if right, do: right.line_num, else: ""

    left_content = if left, do: left.line.content, else: ""
    right_content = if right, do: right.line.content, else: ""

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
  attr(:direction, :atom, default: :below)

  def diff_expand_bar(assigns) do
    ~H"""
    <%= if @context_level != :all do %>
      <div class="diff-expand-bar">
        <button
          class="diff-expand-btn"
          phx-click="expand_context"
          phx-value-path={@path}
        >
          <.icon
            name={
              if @direction == :above, do: "hero-chevron-double-up", else: "hero-chevron-double-down"
            }
            class="size-3.5"
          />
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

        # "\ No newline at end of file" git marker — not code
        String.starts_with?(line, "\\ ") ->
          %{line_number: idx, prefix: " ", content: line, type: :no_newline}

        true ->
          content = if String.length(line) > 0, do: String.slice(line, 1..-1//1), else: ""
          %{line_number: idx, prefix: " ", content: content, type: :context}
      end
    end)
  end

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
  defp file_status_color(_), do: "text-base-content/60"

  # Build a recursive nested tree from file paths. Each node is either a
  # directory node (%{type: :dir, ...}) or a file node (%{type: :file, ...}).
  # Directory nodes carry the FULL accumulated path (joined with "/", root
  # dirs = the single segment — used as the `toggle_dir` phx-value) plus
  # aggregate additions/deletions/file_count for the entire subtree.
  # Children are sorted: directories first (alphabetically,
  # case-insensitive), then files (alphabetically, case-insensitive).
  defp build_file_tree(files) do
    files
    |> Enum.reduce(%{}, fn file, tree ->
      segments = String.split(file.path, "/")
      insert_into_tree(tree, segments, "", file)
    end)
    |> children_to_sorted_list()
  end

  defp insert_into_tree(tree, [segment], _parent_path, file) do
    file_node = %{
      type: :file,
      path: file.path,
      name: segment,
      status: file.status,
      additions: file.additions,
      deletions: file.deletions,
      file_count: 1
    }

    Map.put(tree, segment, file_node)
  end

  defp insert_into_tree(tree, [segment | rest], parent_path, file) do
    path = if parent_path == "", do: segment, else: parent_path <> "/" <> segment

    raw_children =
      case Map.get(tree, segment) do
        %{children: children} -> children
        nil -> %{}
      end

    updated_children = insert_into_tree(raw_children, rest, path, file)
    Map.put(tree, segment, %{type: :dir, path: path, children: updated_children})
  end

  # Convert a raw tree map (%{name => node}) into a sorted list of finalized
  # nodes with computed aggregate stats for directories.
  defp children_to_sorted_list(tree) do
    tree
    |> Enum.map(fn {name, node} -> finalize_node(name, node) end)
    |> sort_nodes()
  end

  defp finalize_node(_name, %{type: :file} = node), do: node

  defp finalize_node(name, %{type: :dir, path: path, children: raw_children}) do
    children = children_to_sorted_list(raw_children)

    {additions, deletions, file_count} =
      Enum.reduce(children, {0, 0, 0}, fn child, {a, d, c} ->
        {a + child.additions, d + child.deletions, c + child.file_count}
      end)

    %{
      type: :dir,
      name: name,
      path: path,
      children: children,
      additions: additions,
      deletions: deletions,
      file_count: file_count
    }
  end

  # Sort directories first (alphabetically by name, case-insensitive), then
  # files (alphabetically, case-insensitive)
  defp sort_nodes(nodes) do
    Enum.sort_by(nodes, fn node ->
      case node.type do
        :dir -> {0, String.downcase(node.name)}
        :file -> {1, String.downcase(node.name)}
      end
    end)
  end
end
