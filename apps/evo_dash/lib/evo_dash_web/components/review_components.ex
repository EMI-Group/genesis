defmodule EvoDashWeb.ReviewComponents do
  @moduledoc """
  Components for the code review page — diff viewer, file list, action buttons.
  """
  use EvoDashWeb, :html

  # ---------------------------------------------------------------------------
  # review_header/1 — Page header with PR title, badges, and metadata
  # ---------------------------------------------------------------------------

  attr :title, :string, required: true
  attr :task_type, :atom, required: true
  attr :branch_name, :string, default: nil
  attr :commit_sha, :string, default: nil
  attr :status, :atom, default: :open

  def review_header(assigns) do
    ~H"""
    <div class="bg-base-100 rounded-2xl shadow-sm border border-base-200 overflow-hidden">
      <div class="bg-gradient-to-br from-primary/10 via-primary/5 to-transparent p-6 md:p-8">
        <div class="flex items-start gap-4">
          <div class="bg-primary/15 text-primary p-3 rounded-xl shrink-0">
            <.icon name="hero-code-bracket-square" class="size-6" />
          </div>
          <div class="flex-1 min-w-0">
            <h1 class="text-xl md:text-2xl font-bold leading-tight truncate">{@title}</h1>
            <div class="flex flex-wrap items-center gap-2 mt-3">
              <span class={["badge badge-sm", review_status_badge(@status)]}>
                <.icon name={review_status_icon(@status)} class="size-3 mr-1" />
                {review_status_label(@status)}
              </span>
              <span class="badge badge-sm badge-ghost capitalize">{@task_type}</span>
              <%= if @branch_name do %>
                <span class="badge badge-sm badge-primary font-mono">
                  <.icon name="hero-code-bracket-square" class="size-3 mr-1" />
                  {@branch_name}
                </span>
              <% end %>
              <%= if @commit_sha do %>
                <span class="badge badge-sm badge-ghost font-mono">
                  <.icon name="hero-code-bracket" class="size-3 mr-1" />
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
  # agent_summary/1 — Collapsible panel showing agent result
  # ---------------------------------------------------------------------------

  attr :summary, :string, required: true
  attr :open, :boolean, default: true

  def agent_summary(assigns) do
    ~H"""
    <div class="bg-base-100 rounded-2xl shadow-sm border border-base-200 overflow-hidden">
      <details open={@open}>
        <summary class="p-4 md:p-6 cursor-pointer hover:bg-base-200/30 transition-colors flex items-center gap-3 list-none">
          <div class="bg-success/15 text-success p-2 rounded-lg">
            <.icon name="hero-chat-bubble-left-ellipsis" class="size-5" />
          </div>
          <span class="font-semibold text-base-content/80">{gettext("Agent Summary")}</span>
          <div class="flex-1"></div>
          <.icon name="hero-chevron-down" class="size-4 text-base-content/40" />
        </summary>
        <div class="px-4 md:px-6 pb-4 md:pb-6">
          <div class="bg-success/5 border border-success/10 rounded-xl p-4 max-h-[300px] overflow-y-auto">
            <pre class="text-sm whitespace-pre-wrap break-words">{@summary}</pre>
          </div>
        </div>
      </details>
    </div>
    """
  end

  # ---------------------------------------------------------------------------
  # diff_stats_bar/1 — Files changed count, insertions, deletions
  # ---------------------------------------------------------------------------

  attr :files_count, :integer, required: true
  attr :additions, :integer, required: true
  attr :deletions, :integer, required: true

  def diff_stats_bar(assigns) do
    ~H"""
    <div class="bg-base-100 rounded-2xl shadow-sm border border-base-200 p-4 md:p-6">
      <div class="flex items-center gap-3 flex-wrap">
        <div class="flex items-center gap-2">
          <.icon name="hero-document-text" class="size-5 text-base-content/60" />
          <span class="font-semibold text-sm">
            {gettext("%{count} files changed", count: @files_count)}
          </span>
        </div>
        <div class="flex items-center gap-3 text-sm">
          <span class="text-success font-medium flex items-center gap-1">
            <.icon name="hero-plus" class="size-3" /> {@additions}
          </span>
          <span class="text-error font-medium flex items-center gap-1">
            <.icon name="hero-minus" class="size-3" /> {@deletions}
          </span>
        </div>
      </div>
    </div>
    """
  end

  # ---------------------------------------------------------------------------
  # file_list/1 — Clickable list of changed files with stats
  # ---------------------------------------------------------------------------

  attr :files, :list, required: true
  attr :selected_file, :string, default: nil

  def file_list(assigns) do
    ~H"""
    <div class="bg-base-100 rounded-2xl shadow-sm border border-base-200 overflow-hidden">
      <div class="p-4 border-b border-base-200">
        <h3 class="font-semibold text-sm flex items-center gap-2">
          <.icon name="hero-folder-open" class="size-4 text-base-content/60" />
          {gettext("Changed Files")}
        </h3>
      </div>
      <div class="divide-y divide-base-200 max-h-[400px] overflow-y-auto">
        <%= for file <- @files do %>
          <button
            phx-click="select_file"
            phx-value-path={file.path}
            class={[
              "w-full text-left px-4 py-3 hover:bg-base-200/50 transition-colors flex items-center gap-3",
              @selected_file == file.path && "bg-primary/5 border-l-2 border-l-primary"
            ]}
          >
            <.icon name={file_status_icon(file.status)} class={["size-4 shrink-0", file_status_color(file.status)]} />
            <span class="text-sm font-mono truncate flex-1">{file.path}</span>
            <span class="text-xs text-success font-mono">+{file.additions}</span>
            <span class="text-xs text-error font-mono">-{file.deletions}</span>
          </button>
        <% end %>
      </div>
    </div>
    """
  end

  # ---------------------------------------------------------------------------
  # diff_viewer/1 — Full diff display with Lumis syntax highlighting
  # ---------------------------------------------------------------------------

  attr :files, :list, required: true
  attr :expanded_files, :map, default: %{}

  def diff_viewer(assigns) do
    ~H"""
    <div class="bg-base-100 rounded-2xl shadow-sm border border-base-200 overflow-hidden">
      <div class="p-4 border-b border-base-200">
        <h3 class="font-semibold text-sm flex items-center gap-2">
          <.icon name="hero-code-bracket" class="size-4 text-base-content/60" />
          {gettext("Changes")}
        </h3>
      </div>
      <div class="divide-y divide-base-200">
        <%= for file <- @files do %>
          <div>
            <button
              phx-click="toggle_file_expansion"
              phx-value-path={file.path}
              class="w-full text-left px-4 py-3 hover:bg-base-200/50 transition-colors flex items-center gap-3"
            >
              <.icon
                name="hero-chevron-right"
                class={["size-4 transition-transform", Map.get(@expanded_files, file.path, true) && "rotate-90"]}
              />
              <.icon name={file_status_icon(file.status)} class={["size-4", file_status_color(file.status)]} />
              <span class="text-sm font-mono">{file.path}</span>
              <span class="text-xs text-success font-mono ml-auto">+{file.additions}</span>
              <span class="text-xs text-error font-mono">-{file.deletions}</span>
            </button>
            <%= if Map.get(@expanded_files, file.path, true) do %>
              <div class="border-t border-base-200 bg-base-300/30 overflow-x-auto">
                {render_diff_content(file)}
              </div>
            <% end %>
          </div>
        <% end %>
      </div>
    </div>
    """
  end

  defp render_diff_content(file) do
    assigns = %{file: file}

    ~H"""
    <div class="text-xs font-mono leading-relaxed">
      <%= for line <- parse_diff_lines(@file) do %>
        <div class={["flex", line_bg(line.type)]}>
          <span class="w-10 shrink-0 text-right pr-3 text-base-content/30 select-none">{line.line_number}</span>
          <span class="w-5 shrink-0 text-base-content/30 select-none text-center">{line.prefix}</span>
          <span class={["whitespace-pre", line_text_color(line.type)]}>
            {highlight_line_content(line.content, @file.language)}
          </span>
        </div>
      <% end %>
    </div>
    """
  end

  # ---------------------------------------------------------------------------
  # action_buttons/1 — Merge, Reject, Continue, and optional Create PR
  # ---------------------------------------------------------------------------

  attr :branch_exists, :boolean, default: true
  attr :has_pr, :boolean, default: false
  attr :pr_url, :string, default: nil
  attr :loading, :boolean, default: false

  def action_buttons(assigns) do
    ~H"""
    <div class="bg-base-100 rounded-2xl shadow-sm border border-base-200 p-4 md:p-6">
      <div class="flex items-center gap-2 mb-4">
        <.icon name="hero-hand-raised" class="size-5 text-base-content/60" />
        <h3 class="font-semibold">{gettext("Actions")}</h3>
      </div>
      <div class="flex flex-wrap gap-3">
        <%= if @branch_exists do %>
          <button
            class="btn btn-success gap-2"
            phx-click="merge"
            phx-confirm={gettext("Merge these changes into the current branch?")}
            disabled={@loading}
          >
            <.icon name="hero-check" class="size-4" />
            {gettext("Merge Changes")}
          </button>
          <button
            class="btn btn-outline btn-error gap-2"
            phx-click="reject"
            phx-confirm={gettext("Reject and delete these changes? This cannot be undone.")}
            disabled={@loading}
          >
            <.icon name="hero-x-mark" class="size-4" />
            {gettext("Reject Changes")}
          </button>
          <button
            class="btn btn-outline btn-info gap-2"
            phx-click="continue"
            disabled={@loading}
          >
            <.icon name="hero-arrow-path" class="size-4" />
            {gettext("Continue from Here")}
          </button>
          <div class="divider divider-horizontal mx-1 hidden sm:block"></div>
        <% end %>
        <%= if @branch_exists and not @has_pr do %>
          <button
            class="btn btn-outline gap-2"
            phx-click="create_pr"
            disabled={@loading}
          >
            <.icon name="hero-arrow-top-right-on-square" class="size-4" />
            {gettext("Create GitHub PR")}
          </button>
        <% end %>
        <%= if @has_pr and @pr_url do %>
          <a href={@pr_url} target="_blank" class="btn btn-outline btn-success gap-2">
            <.icon name="hero-arrow-top-right-on-square" class="size-4" />
            {gettext("View GitHub PR")}
          </a>
        <% end %>
        <%= if not @branch_exists do %>
          <div class="bg-warning/10 border border-warning/20 rounded-lg p-4 w-full">
            <div class="flex items-center gap-2">
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
  # Private helpers
  # ---------------------------------------------------------------------------

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

  defp line_bg(:addition), do: "bg-success/10"
  defp line_bg(:deletion), do: "bg-error/10"
  defp line_bg(:hunk), do: "bg-info/5 text-info"
  defp line_bg(:context), do: ""
  defp line_bg(_), do: "bg-base-200/30"

  defp line_text_color(:addition), do: "text-success"
  defp line_text_color(:deletion), do: "text-error"
  defp line_text_color(:hunk), do: "text-info"
  defp line_text_color(_), do: "text-base-content/80"

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

  # Use Lumis for syntax highlighting of individual lines
  defp highlight_line_content(content, language) do
    if content && String.length(content) > 0 do
      try do
        Lumis.highlight!(content, formatter: {:html_inline, language: language, theme: "onedark"})
        |> raw()
      rescue
        _ -> content
      end
    else
      ""
    end
  end
end
