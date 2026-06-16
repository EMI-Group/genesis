defmodule EvoDashWeb.ReviewComponents do
  @moduledoc """
  Components for the code review page — GitHub PR-style tab layout with split diff viewer.
  """
  use EvoDashWeb, :html

  # ---------------------------------------------------------------------------
  # review_header/1 — Page header with PR title, badges, and metadata
  # ---------------------------------------------------------------------------

  attr(:title, :string, required: true)
  attr(:task_type, :atom, required: true)
  attr(:branch_name, :string, default: nil)
  attr(:commit_sha, :string, default: nil)
  attr(:status, :atom, default: :open)

  def review_header(assigns) do
    ~H"""
    <div class="bg-base-100 rounded-3xl shadow-sm border border-base-200/60 overflow-hidden">
      <div class="bg-gradient-to-br from-primary/10 via-primary/5 to-transparent p-5 sm:p-6">
        <div class="flex items-start gap-4">
          <div class="bg-primary/15 text-primary p-3.5 rounded-2xl shrink-0">
            <.icon name="hero-code-bracket-square" class="size-6" />
          </div>
          <div class="flex-1 min-w-0">
            <h1 class="text-xl md:text-2xl font-bold leading-tight truncate">{@title}</h1>
            <div class="flex flex-wrap items-center gap-2 mt-3.5">
              <span class={["badge badge-sm rounded-full px-2.5 py-3", review_status_badge(@status)]}>
                <.icon name={review_status_icon(@status)} class="size-3.5 mr-1.5" />
                {review_status_label(@status)}
              </span>
              <span class="badge badge-sm badge-ghost rounded-full px-2.5 py-3 capitalize">{@task_type}</span>
              <%= if @branch_name do %>
                <span class="badge badge-sm badge-primary rounded-full px-2.5 py-3 font-mono">
                  <.icon name="hero-code-bracket-square" class="size-3.5 mr-1.5" />
                  {@branch_name}
                </span>
              <% end %>
              <%= if @commit_sha do %>
                <span class="badge badge-sm badge-ghost rounded-full px-2.5 py-3 font-mono">
                  <.icon name="hero-code-bracket" class="size-3.5 mr-1.5" />
                  {String.slice(@commit_sha, 0..7)}
                </span>
              <% end %>
            </div>
          </div>
        </div>
      </div>
    </div>
    """
  end

  # ---------------------------------------------------------------------------
  # review_tabs/1 — Tab bar for switching between Conversation and Files Changed
  # ---------------------------------------------------------------------------

  attr(:active_tab, :atom, required: true)
  attr(:files_count, :integer, default: 0)
  attr(:commits_count, :integer, default: 0)

  def review_tabs(assigns) do
    ~H"""
    <div class="review-tab-bar flex gap-1 sm:gap-2 py-2 sm:py-3 overflow-x-auto scrollbar-none -mx-4 px-4 sm:mx-0 sm:px-0">
      <button
        phx-click="switch_tab"
        phx-value-tab="conversation"
        class={["review-tab rounded-full px-3 py-2 sm:px-5 sm:py-2.5 text-sm font-medium transition-all duration-200 whitespace-nowrap", @active_tab == :conversation && "bg-base-200 text-base-content shadow-sm ring-1 ring-base-content/5" || "text-base-content/60 hover:bg-base-200/50 hover:text-base-content"]}
      >
        <.icon name="hero-chat-bubble-left-right" class="size-4 mr-2" />
        {gettext("Conversation")}
      </button>
      <button
        phx-click="switch_tab"
        phx-value-tab="commits"
        class={["review-tab rounded-full px-3 py-2 sm:px-5 sm:py-2.5 text-sm font-medium transition-all duration-200 whitespace-nowrap", @active_tab == :commits && "bg-base-200 text-base-content shadow-sm ring-1 ring-base-content/5" || "text-base-content/60 hover:bg-base-200/50 hover:text-base-content"]}
      >
        <.icon name="hero-clock" class="size-4 mr-2" />
        {gettext("Commits")}
        <span class="badge badge-sm badge-ghost rounded-full ml-2">{@commits_count}</span>
      </button>
      <button
        phx-click="switch_tab"
        phx-value-tab="files_changed"
        class={["review-tab rounded-full px-3 py-2 sm:px-5 sm:py-2.5 text-sm font-medium transition-all duration-200 whitespace-nowrap", @active_tab == :files_changed && "bg-base-200 text-base-content shadow-sm ring-1 ring-base-content/5" || "text-base-content/60 hover:bg-base-200/50 hover:text-base-content"]}
      >
        <.icon name="hero-code-bracket" class="size-4 mr-2" />
        {gettext("Files Changed")}
        <span class="badge badge-sm badge-ghost rounded-full ml-2">{@files_count}</span>
      </button>
    </div>
    """
  end

  # ---------------------------------------------------------------------------
  # agent_summary/1 — Collapsible panel showing agent result
  # ---------------------------------------------------------------------------

  attr(:summary, :string, required: true)
  attr(:open, :boolean, default: true)

  def agent_summary(assigns) do
    ~H"""
    <div class="bg-base-100 rounded-3xl shadow-sm border border-base-200/60 overflow-hidden">
      <div class="relative">
        <details open={@open}>
          <summary class="p-5 md:p-6 cursor-pointer hover:bg-base-200/30 transition-colors flex items-center gap-4 list-none">
            <div class="bg-success/15 text-success p-2.5 rounded-xl">
              <.icon name="hero-chat-bubble-left-ellipsis" class="size-5" />
            </div>
            <span class="font-semibold text-base-content/80">{gettext("Agent Summary")}</span>
            <div class="flex-1"></div>
            <.icon name="hero-chevron-down" class="size-4 text-base-content/40" />
          </summary>
          <div class="px-5 md:px-6 pb-5 md:pb-6">
            <div class="md-content text-sm leading-relaxed">
              {raw(EvoDash.MarkdownRender.render(@summary))}
            </div>
          </div>
        </details>
        <button
          id="summary-copy-btn"
          class="btn btn-ghost btn-sm rounded-full btn-square absolute top-4 right-4 z-10"
          phx-hook="ClipboardCopy"
          data-content={@summary}
          title={gettext("Copy agent summary")}
        >
          <.icon name="hero-clipboard" class="size-4" />
        </button>
      </div>
    </div>
    """
  end

  # ---------------------------------------------------------------------------
  # diff_stats_bar/1 — Files changed, insertions, deletions, and commits count
  # ---------------------------------------------------------------------------

  attr(:files_count, :integer, required: true)
  attr(:additions, :integer, required: true)
  attr(:deletions, :integer, required: true)
  attr(:commits_count, :integer, default: 0)

  def diff_stats_bar(assigns) do
    ~H"""
    <div class="bg-base-100 rounded-3xl shadow-sm border border-base-200/60 px-5 py-4 md:px-6 md:py-4">
      <div class="flex items-center gap-4 flex-wrap text-sm">
        <div class="flex items-center gap-2.5">
          <.icon name="hero-document-text" class="size-4.5 text-base-content/50" />
          <span class="font-medium text-base-content/80">
            {gettext("%{count} files changed", count: @files_count)}
          </span>
        </div>
        <div class="flex items-center gap-3 bg-base-200/50 rounded-full px-3 py-1">
          <span class="text-success font-semibold flex items-center gap-1.5">
            <.icon name="hero-plus" class="size-3.5" /> {@additions}
          </span>
          <span class="text-error font-semibold flex items-center gap-1.5">
            <.icon name="hero-minus" class="size-3.5" /> {@deletions}
          </span>
        </div>
        <span class="text-base-content/30 hidden sm:inline">·</span>
        <div class="flex items-center gap-2.5">
          <.icon name="hero-clock" class="size-4.5 text-base-content/50" />
          <span class="font-medium text-base-content/80">
            {ngettext("%{count} commit", "%{count} commits", @commits_count, count: @commits_count)}
          </span>
        </div>
      </div>
    </div>
    """
  end

  # ---------------------------------------------------------------------------
  # commits_list/1 — GitHub-style commit list
  # ---------------------------------------------------------------------------

  attr(:commits, :list, required: true)

  def commits_list(assigns) do
    ~H"""
    <div>
      <div class="p-5 md:p-6 border-b border-base-200/50 bg-base-200/20">
        <div class="flex items-center gap-3">
          <.icon name="hero-clock" class="size-5 text-base-content/60" />
          <span class="font-semibold text-base">
            {ngettext("%{count} commit", "%{count} commits", length(@commits), count: length(@commits))}
          </span>
        </div>
      </div>
      <div class="divide-y divide-base-200/50">
        <%= for {commit, _i} <- Enum.with_index(@commits) do %>
          <div class="flex items-center gap-4 px-5 md:px-6 py-4 hover:bg-base-200/30 transition-colors">
            <span class="badge badge-sm badge-ghost rounded-full font-mono text-xs px-2.5 py-3 shrink-0">
              {commit.short_sha}
            </span>
            <span class="text-sm font-medium flex-1 truncate" title={commit.message}>
              {commit.message}
            </span>
            <span class="text-sm text-base-content/50 shrink-0 hidden sm:inline">
              {commit.author_name}
            </span>
            <span class="text-sm text-base-content/50 shrink-0">
              {relative_time(commit.date)}
            </span>
          </div>
        <% end %>
      </div>
    </div>
    """
  end

  # ---------------------------------------------------------------------------
  # action_buttons/1 — Merge, Reject, Continue, Create PR, and Extract Skills
  # ---------------------------------------------------------------------------

  attr(:branch_exists, :boolean, default: true)
  attr(:has_pr, :boolean, default: false)
  attr(:pr_url, :string, default: nil)
  attr(:loading, :boolean, default: false)

  def action_buttons(assigns) do
    ~H"""
    <div class="bg-base-100 rounded-3xl shadow-sm border border-base-200/60 p-5 md:p-6">
      <div class="flex items-center gap-3 mb-5">
        <.icon name="hero-hand-raised" class="size-5 text-base-content/60" />
        <h3 class="font-semibold text-base">{gettext("Actions")}</h3>
      </div>
      <div class="flex flex-wrap gap-3">
        <%= if @branch_exists do %>
          <button
            class="btn btn-success rounded-full px-6 gap-2 shadow-sm"
            phx-click="merge"
            phx-confirm={gettext("Merge these changes into the current branch?")}
            disabled={@loading}
          >
            <.icon name="hero-check" class="size-4.5" />
            {gettext("Merge Changes")}
          </button>
          <button
            class="btn btn-outline btn-error rounded-full px-6 gap-2"
            phx-click="reject"
            phx-confirm={gettext("Reject and delete these changes? This cannot be undone.")}
            disabled={@loading}
          >
            <.icon name="hero-x-mark" class="size-4.5" />
            {gettext("Reject Changes")}
          </button>
          <button
            class="btn btn-outline btn-info rounded-full px-6 gap-2"
            phx-click="continue"
            disabled={@loading}
          >
            <.icon name="hero-arrow-path" class="size-4.5" />
            {gettext("Continue from Here")}
          </button>
          <div class="divider divider-horizontal mx-2 hidden lg:block before:bg-base-200/50 after:bg-base-200/50"></div>
        <% end %>
        <%= if @branch_exists and not @has_pr do %>
          <button
            class="btn btn-outline rounded-full px-6 gap-2"
            phx-click="create_pr"
            disabled={@loading}
          >
            <.icon name="hero-arrow-top-right-on-square" class="size-4.5" />
            {gettext("Create GitHub PR")}
          </button>
        <% end %>
        <%= if @has_pr and @pr_url do %>
          <a href={@pr_url} target="_blank" class="btn btn-outline btn-success rounded-full px-6 gap-2">
            <.icon name="hero-arrow-top-right-on-square" class="size-4.5" />
            {gettext("View GitHub PR")}
          </a>
        <% end %>
        <%= if @branch_exists do %>
          <div class="divider divider-horizontal mx-2 hidden lg:block before:bg-base-200/50 after:bg-base-200/50"></div>
          <button
            class="btn btn-outline btn-secondary rounded-full px-6 gap-2"
            phx-click="extract_skills"
            disabled={@loading}
          >
            <.icon name="hero-academic-cap" class="size-4.5" />
            {gettext("Extract Skills")}
          </button>
        <% end %>
        <%= if not @branch_exists do %>
          <div class="bg-warning/10 border border-warning/20 rounded-2xl p-5 w-full">
            <div class="flex items-center gap-3">
              <.icon name="hero-exclamation-triangle" class="size-5 text-warning" />
              <span class="text-sm text-warning font-medium">{gettext("This branch no longer exists. No actions available.")}</span>
            </div>
          </div>
        <% end %>
      </div>
    </div>
    """
  end

  # ---------------------------------------------------------------------------
  # extract_skills_modal/1 — Modal for extracting skills from a PR
  # ---------------------------------------------------------------------------

  attr(:show, :boolean, default: false)

  def extract_skills_modal(assigns) do
    ~H"""
    <%= if @show do %>
      <div class="fixed inset-0 z-50 flex items-center justify-center p-4">
        <div class="fixed inset-0 bg-black/50 backdrop-blur-sm" phx-click="cancel_extract_skills"></div>
        <div class="relative bg-base-100 rounded-3xl shadow-2xl border border-base-200 max-w-lg w-full p-6 md:p-8">
          <div class="flex items-center gap-3 mb-4">
            <div class="flex items-center justify-center size-10 rounded-2xl bg-secondary/10">
              <.icon name="hero-academic-cap" class="size-5 text-secondary" />
            </div>
            <h3 class="text-lg font-bold">{gettext("Extract Skills")}</h3>
          </div>

          <p class="text-sm text-base-content/70 mb-5">
            {gettext("Analyze the changes in this PR and distill reusable knowledge into EvoGit skills. The agent will examine the diff, identify valuable patterns, and create skill files in .agents/skills/.")}
          </p>

          <.form for={%{}} phx-submit="confirm_extract_skills" class="space-y-4">
            <div class="form-control">
              <label class="label">
                <span class="label-text text-sm font-medium">
                  {gettext("Optional: Note for the skill extraction agent")}
                </span>
              </label>
              <textarea
                class="textarea textarea-bordered h-24 rounded-2xl text-sm"
                name="user_note"
                placeholder={gettext("e.g., Focus on the deployment workflow and database migration patterns discovered in this PR.")}
              ></textarea>
              <p class="text-xs text-base-content/50 mt-1">
                {gettext("Provide specific instructions on what knowledge should be captured as skills.")}
              </p>
            </div>

            <div class="flex justify-end gap-3 pt-2">
              <button type="button" class="btn btn-ghost rounded-full px-6" phx-click="cancel_extract_skills">
                {gettext("Cancel")}
              </button>
              <button type="submit" class="btn btn-secondary rounded-full px-6 gap-2">
                <.icon name="hero-academic-cap" class="size-4.5" />
                {gettext("Extract Skills")}
              </button>
            </div>
          </.form>
        </div>
      </div>
    <% end %>
    """
  end

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
              {render_diff_content(file)}
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

  def split_diff_layout(assigns) do
    ~H"""
    <div class="diff-fullscreen-layout">
      <.file_tree_sidebar files={@files} selected_file={@selected_file} />
      <.diff_viewer
        files={@files}
        expanded_files={@expanded_files}
        selected_file={@selected_file}
      />
    </div>
    """
  end

  # ---------------------------------------------------------------------------
  # Private helpers
  # ---------------------------------------------------------------------------

  defp render_diff_content(file) do
    assigns = %{file: file}

    ~H"""
    <div class="text-xs font-mono">
      <%= if is_nil(@file.diff) do %>
        <div class="flex items-center justify-center py-8 gap-2 text-base-content/50">
          <span class="loading loading-spinner loading-sm"></span>
          <span><%= gettext("Loading diff...") %></span>
        </div>
      <% else %>
        <%= for line <- parse_diff_lines(@file) do %>
          <div class={["diff-line", diff_line_class(line.type)]}>
            <span class="diff-line-gutter">{line.line_number}</span>
            <span class={["diff-line-prefix", diff_prefix_color(line.type)]}>{line.prefix}</span>
            <span class="diff-line-content" phx-no-format>{if line.type in [:addition, :deletion, :context], do: highlight_line_content(line.content, @file.language), else: line.content}</span>
          </div>
        <% end %>
      <% end %>
    </div>
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

  defp review_status_badge(:open), do: "badge-warning"
  defp review_status_badge(:merged), do: "badge-success"
  defp review_status_badge(:rejected), do: "badge-error"
  defp review_status_badge(:no_changes), do: "badge-ghost"
  defp review_status_badge(_), do: "badge-ghost"

  defp review_status_icon(:open), do: "hero-clock"
  defp review_status_icon(:merged), do: "hero-check-circle"
  defp review_status_icon(:rejected), do: "hero-x-circle"
  defp review_status_icon(:no_changes), do: "hero-information-circle"
  defp review_status_icon(_), do: "hero-question-mark-circle"

  defp review_status_label(:open), do: gettext("Open")
  defp review_status_label(:merged), do: gettext("Merged")
  defp review_status_label(:rejected), do: gettext("Rejected")
  defp review_status_label(:no_changes), do: gettext("No Changes")
  defp review_status_label(_), do: gettext("Unknown")

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
