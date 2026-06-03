defmodule EvoDashWeb.ReviewComponents do
  @moduledoc """
  Shared function components for the Review LiveView page.
  """
  use EvoDashWeb, :html

  # ---------------------------------------------------------------------------
  # review_header/1 — Page header with task info, status badges, and prompt
  # ---------------------------------------------------------------------------

  attr :task, :map, required: true
  attr :review_status, :atom, required: true

  def review_header(assigns) do
    ~H"""
    <div class="bg-base-100 rounded-2xl shadow-lg border border-base-200 overflow-hidden">
      <!-- Hero Header -->
      <div class="bg-gradient-to-br from-primary/10 via-primary/5 to-transparent px-6 py-5 md:px-8 md:py-6">
        <div class="flex flex-col sm:flex-row sm:items-center sm:justify-between gap-4">
          <div class="flex items-center gap-3">
            <div class="bg-primary/15 text-primary p-2.5 rounded-xl">
              <.icon name="hero-code-bracket-square" class="size-5" />
            </div>
            <div>
              <h1 class="text-xl font-bold">{gettext("Review Changes")}</h1>
              <p class="text-xs text-base-content/60">
                <%= case @task.type do %>
                  <% :genesis -> %>
                    {gettext("Genesis task")}
                  <% :evolve -> %>
                    {gettext("Evolve task")}
                  <% _ -> %>
                    {gettext("Task")}
                <% end %>
                <%= if @task.opts[:mode] do %>
                  <span class="mx-1">·</span> {@task.opts[:mode]}
                <% end %>
              </p>
            </div>
          </div>
          <div class="flex items-center gap-2">
            {review_status_badge(%{review_status: @review_status})}
          </div>
        </div>
      </div>

      <!-- Badges Row -->
      <% result_data = result_from_task(@task) %>
      <div class="px-6 md:px-8 py-3 border-t border-base-200/50 bg-base-200/20">
        <div class="flex flex-wrap gap-2">
          <%= if result_data[:branch_name] do %>
            <span class="badge badge-primary font-mono text-sm gap-1">
              <.icon name="hero-code-bracket-square" class="size-3.5" />
              {result_data[:branch_name]}
            </span>
          <% end %>
          <%= if result_data[:commit_sha] do %>
            <span class="badge badge-ghost font-mono text-sm gap-1">
              <.icon name="hero-code-bracket" class="size-3.5" />
              {String.slice(result_data[:commit_sha], 0, 8)}
            </span>
          <% end %>
          <%= if result_data[:base_sha] do %>
            <span class="badge badge-ghost font-mono text-sm gap-1">
              <.icon name="hero-arrow-long-down" class="size-3.5" />
              {String.slice(result_data[:base_sha], 0, 8)}
            </span>
          <% end %>
        </div>
      </div>

      <!-- Prompt/Objective -->
      <% prompt_text = task_prompt(@task) %>
      <%= if prompt_text do %>
        <div class="px-6 md:px-8 py-3 border-t border-base-200/50">
          <p class="text-sm text-base-content/70">
            <span class="font-semibold text-base-content/90">{gettext("Objective")}:</span>
            {String.slice(prompt_text, 0, 500)}
          </p>
        </div>
      <% end %>
    </div>
    """
  end

  defp result_from_task(%{result: {:ok, data}}) when is_map(data), do: data
  defp result_from_task(_), do: %{}

  defp task_prompt(%{type: :genesis, opts: opts}) when is_list(opts), do: opts[:prompt]
  defp task_prompt(%{type: :evolve, opts: opts}) when is_list(opts), do: opts[:objective]
  defp task_prompt(_), do: nil

  # ---------------------------------------------------------------------------
  # review_status_badge/1 — Status badge for review state
  # ---------------------------------------------------------------------------

  attr :review_status, :atom, required: true

  def review_status_badge(assigns) do
    ~H"""
    <%= case @review_status do %>
      <% :pending_review -> %>
        <span class="badge badge-warning gap-1 text-sm">
          <.icon name="hero-clock" class="size-4" />
          {gettext("Pending Review")}
        </span>
      <% :merged -> %>
        <span class="badge badge-success gap-1 text-sm">
          <.icon name="hero-check-circle" class="size-4" />
          {gettext("Merged")}
        </span>
      <% :rejected -> %>
        <span class="badge badge-error gap-1 text-sm">
          <.icon name="hero-x-circle" class="size-4" />
          {gettext("Rejected")}
        </span>
      <% :continued -> %>
        <span class="badge badge-info gap-1 text-sm">
          <.icon name="hero-arrow-path" class="size-4" />
          {gettext("Continued")}
        </span>
      <% _ -> %>
        <span class="badge badge-ghost gap-1 text-sm">
          <.icon name="hero-ellipsis-horizontal" class="size-4" />
          {gettext("Review")}
        </span>
    <% end %>
    """
  end

  # ---------------------------------------------------------------------------
  # summary_section/1 — Agent result summary
  # ---------------------------------------------------------------------------

  attr :result, :string, required: true

  def summary_section(assigns) do
    ~H"""
    <div class="bg-base-100 rounded-2xl shadow-lg border border-base-200 overflow-hidden">
      <div class="px-6 py-3 border-b border-base-200/50 bg-base-200/20 flex items-center gap-2">
        <.icon name="hero-chat-bubble-left-ellipsis" class="size-4 text-primary" />
        <h2 class="text-sm font-bold uppercase tracking-wide">{gettext("Agent Summary")}</h2>
      </div>
      <div class="p-6 max-h-[50vh] overflow-y-auto">
        <pre class="text-sm whitespace-pre-wrap break-words leading-relaxed">{@result}</pre>
      </div>
    </div>
    """
  end

  # ---------------------------------------------------------------------------
  # file_list/1 — Diff stat summary with per-file breakdown
  # ---------------------------------------------------------------------------

  attr :files, :list, required: true
  attr :total_additions, :integer, default: 0
  attr :total_deletions, :integer, default: 0

  def file_list(assigns) do
    assigns =
      assign(assigns, :max_changes, max(assigns.total_additions + assigns.total_deletions, 1))

    ~H"""
    <div class="bg-base-100 rounded-2xl shadow-lg border border-base-200 overflow-hidden">
      <div class="px-6 py-3 border-b border-base-200/50 bg-base-200/20 flex items-center gap-2">
        <.icon name="hero-document-text" class="size-4 text-primary" />
        <h2 class="text-sm font-bold uppercase tracking-wide">{gettext("Files Changed")}</h2>
      </div>

      <!-- Summary bar -->
      <div class="px-6 py-2.5 border-b border-base-200/50 text-sm text-base-content/70">
        {gettext("%{count} files changed", count: length(@files))}
        <span class="text-success mx-1">+{@total_additions}</span>
        <span class="text-error">-{@total_deletions}</span>
      </div>

      <!-- File table -->
      <div class="divide-y divide-base-200/50">
        <%= for file <- @files do %>
          <div class="px-6 py-2.5 flex items-center gap-4 hover:bg-base-200/20 transition-colors">
            <span class="font-mono text-sm truncate flex-1 min-w-0" title={file.path}>
              {file.path}
            </span>
            <div class="flex items-center gap-3 shrink-0">
              <span class="text-success text-xs font-mono font-semibold">+{file.additions}</span>
              <span class="text-error text-xs font-mono font-semibold">-{file.deletions}</span>
              <!-- Visual bar -->
              <div class="w-20 h-2 bg-base-300/50 rounded-full overflow-hidden flex">
                <div
                  class="h-full bg-success/70"
                  style={"width: #{file.additions / @max_changes * 100}%"}
                >
                </div>
                <div
                  class="h-full bg-error/70"
                  style={"width: #{file.deletions / @max_changes * 100}%"}
                >
                </div>
              </div>
            </div>
          </div>
        <% end %>
      </div>
    </div>
    """
  end

  # ---------------------------------------------------------------------------
  # diff_viewer/1 — Full diff display
  # ---------------------------------------------------------------------------

  attr :diff, :string, required: true

  def diff_viewer(assigns) do
    ~H"""
    <div class="bg-base-100 rounded-2xl shadow-lg border border-base-200 overflow-hidden">
      <div class="px-6 py-3 border-b border-base-200/50 bg-base-200/20 flex items-center gap-2">
        <.icon name="hero-code-bracket" class="size-4 text-primary" />
        <h2 class="text-sm font-bold uppercase tracking-wide">{gettext("Changes")}</h2>
      </div>
      <div class="p-4 max-h-[60vh] overflow-y-auto bg-base-300/30">
        <pre class="text-xs font-mono whitespace-pre overflow-x-auto leading-relaxed">{@diff}</pre>
      </div>
    </div>
    """
  end

  # ---------------------------------------------------------------------------
  # action_buttons/1 — Merge / Reject / Continue / Create PR buttons
  # ---------------------------------------------------------------------------

  attr :review_status, :atom, required: true
  attr :task_id, :string, required: true
  attr :branch_exists, :boolean, default: true
  attr :pr_url, :string, default: nil
  attr :creating_pr, :boolean, default: false

  def action_buttons(assigns) do
    ~H"""
    <div class="space-y-4">
      <%= if @review_status in [:pending_review, nil] do %>
        <div class="flex flex-wrap items-center gap-3">
          <button
            class="btn btn-success gap-2"
            phx-click="merge"
            phx-disable-with={gettext("Merging...")}
            data-confirm={gettext("Are you sure you want to merge these changes?")}
          >
            <.icon name="hero-check" class="size-5" />
            {gettext("Merge")}
          </button>
          <button
            class="btn btn-error gap-2"
            phx-click="reject"
            phx-disable-with={gettext("Rejecting...")}
            data-confirm={gettext("Are you sure you want to reject these changes?")}
          >
            <.icon name="hero-x-mark" class="size-5" />
            {gettext("Reject")}
          </button>
          <button
            class="btn btn-primary gap-2"
            phx-click="continue"
            phx-disable-with={gettext("Continuing...")}
          >
            <.icon name="hero-arrow-path" class="size-5" />
            {gettext("Continue")}
          </button>

          <div class="divider divider-horizontal mx-1 h-8 hidden sm:block"></div>

          <%= if is_nil(@pr_url) do %>
            <button
              class="btn btn-outline gap-2"
              phx-click="create_pr"
              phx-disable-with={gettext("Creating PR...")}
              disabled={@creating_pr}
            >
              <%= if @creating_pr do %>
                <span class="loading loading-spinner loading-xs"></span>
                {gettext("Creating PR...")}
              <% else %>
                <.icon name="hero-arrow-top-right-on-square" class="size-5" />
                {gettext("Create GitHub PR")}
              <% end %>
            </button>
          <% else %>
            <a
              href={@pr_url}
              target="_blank"
              class="badge badge-success gap-1 text-sm hover:opacity-80 transition-opacity py-3 px-4"
            >
              <.icon name="hero-arrow-top-right-on-square" class="size-4" />
              {gettext("View PR on GitHub")}
            </a>
          <% end %>
        </div>
      <% else %>
        <!-- Final status alert -->
        <div class={[
          "alert shadow-sm",
          alert_class_for_status(@review_status)
        ]}>
          <.icon name={alert_icon_for_status(@review_status)} class="size-5" />
          <span>{alert_message_for_status(@review_status)}</span>
        </div>

        <%= if @pr_url do %>
          <a
            href={@pr_url}
            target="_blank"
            class="badge badge-success gap-1 text-sm hover:opacity-80 transition-opacity py-3 px-4"
          >
            <.icon name="hero-arrow-top-right-on-square" class="size-4" />
            {gettext("View PR on GitHub")}
          </a>
        <% end %>
      <% end %>
    </div>
    """
  end

  defp alert_class_for_status(:merged), do: "alert-success"
  defp alert_class_for_status(:rejected), do: "alert-error"
  defp alert_class_for_status(:continued), do: "alert-info"
  defp alert_class_for_status(_), do: "alert-ghost"

  defp alert_icon_for_status(:merged), do: "hero-check-circle"
  defp alert_icon_for_status(:rejected), do: "hero-x-circle"
  defp alert_icon_for_status(:continued), do: "hero-arrow-path"
  defp alert_icon_for_status(_), do: "hero-information-circle"

  defp alert_message_for_status(:merged), do: gettext("These changes have been merged.")
  defp alert_message_for_status(:rejected), do: gettext("These changes were rejected.")
  defp alert_message_for_status(:continued), do: gettext("These changes were continued.")
  defp alert_message_for_status(_), do: gettext("Review complete.")
end
