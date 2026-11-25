defmodule EvoDashWeb.ReviewComponents.Header do
  @moduledoc false

  # zh_CN: Token → "词元", Agent → "智能体"

  use EvoDashWeb, :html

  # ---------------------------------------------------------------------------
  # page_header/1 — Compact page header: back link, one-line title, status
  # badges, a wrapping meta line, and a GitHub-style diff-stat row (deliberately
  # NOT a stat-card grid).
  # ---------------------------------------------------------------------------

  attr(:back_url, :string, required: true)
  attr(:title, :string, required: true)
  attr(:status, :atom, default: :open)
  attr(:task_status, :atom, default: nil)
  attr(:task_type, :atom, default: nil)
  attr(:task_id, :string, default: nil)
  attr(:repo_path, :string, default: nil)
  attr(:branch_name, :string, default: nil)
  attr(:merge_target, :string, default: nil)
  attr(:commit_sha, :string, default: nil)
  attr(:model_id, :string, default: nil)
  attr(:agent_count, :integer, default: nil)
  attr(:started_at, :any, default: nil)
  attr(:finished_at, :any, default: nil)
  attr(:stats, :map, default: nil)
  # The viewed node's display name — rendered as the page's SCOPE chip beside
  # the project slot (project + node + task id + status is the whole identity
  # line).
  attr(:node_name, :string, default: nil)
  # Whether the REVIEW-status badge (open / merged / rejected …) is meaningful:
  # a failed task is a diagnostics record, not a review state, so its owner
  # passes false.
  attr(:show_review_status, :boolean, default: true)

  def page_header(assigns) do
    ~H"""
    <header class="rounded-xl border border-base-300 bg-base-100 p-4 sm:p-5 space-y-3">
      <div class="flex items-start gap-2 min-w-0">
        <.link
          navigate={@back_url}
          class="btn btn-ghost btn-sm btn-square shrink-0"
          title={gettext("Back to projects")}
          aria-label={gettext("Back to projects")}
        >
          <.icon name="hero-arrow-left" class="size-4" />
        </.link>
        <div class="flex-1 min-w-0 pt-1">
          <h1
            class="line-clamp-3 text-xl font-semibold leading-snug [overflow-wrap:anywhere]"
            title={@title}
          >
            {short_title(@title)}
          </h1>
          <div :if={@show_review_status or @task_status != nil} class="mt-2 flex flex-wrap gap-2">
            <span
              :if={@show_review_status}
              class={["badge badge-sm gap-1 shrink-0 font-medium", review_status_badge(@status)]}
            >
              <.icon name={review_status_icon(@status)} class="size-3.5" />
              {review_status_label(@status)}
            </span>
            <span
              :if={@task_status}
              class={[
                "badge badge-sm shrink-0 font-medium border-0 px-2 py-1 rounded-md",
                task_status_badge(@task_status)
              ]}
            >
              {task_status_label(@task_status)}
            </span>
          </div>
        </div>
      </div>

      <%!-- Row 2: meta line (repo path, branch → merge target, task facts).
           Vertical rhythm: every text span shares `leading-none` so the boxed
           chips (symmetric py-0.5) and the bare mono/sans spans all center on
           the same optical line. Machine-ish values are `font-mono`; only the
           human words (task type label, relative times) stay sans. --%>
      <div class="flex flex-wrap items-center gap-x-3 gap-y-1.5 text-sm text-base-content/70">
        <%!-- The SCOPE line always renders its project slot: a repo-less task
             (assistant/reflect) has no path at all, and that absence is stated
             instead of silently dropping the slot. --%>
        <%= if @repo_path do %>
          <span class="flex items-center gap-1.5 min-w-0" title={@repo_path}>
            <.icon name="hero-folder" class="size-4 shrink-0" />
            <span class="font-mono text-xs truncate leading-none">{@repo_path}</span>
          </span>
        <% else %>
          <span class="flex items-center gap-1.5 min-w-0">
            <.icon name="hero-folder" class="size-4 shrink-0 text-base-content/50" />
            <span class="text-xs leading-none">
              <%!-- zh_CN: 没有项目路径（无仓库任务） --%>
              {gettext("No project path")}
            </span>
          </span>
        <% end %>
        <%= if @node_name do %>
          <span class="flex items-center gap-1.5 min-w-0">
            <.icon name="hero-server-stack" class="size-4 shrink-0" />
            <span class="text-xs leading-none truncate max-w-[12rem]" title={@node_name}>
              {@node_name}
            </span>
          </span>
        <% end %>
        <%= if @branch_name do %>
          <span class="flex items-center gap-1.5 min-w-0">
            <.icon name="hero-code-bracket-square" class="size-4 shrink-0" />
            <span
              class="font-mono text-xs bg-base-200 rounded-md px-1.5 py-0.5 leading-none truncate max-w-[16rem]"
              title={@branch_name}
            >
              {@branch_name}
            </span>
          </span>
        <% end %>
        <%= if @branch_name && @merge_target do %>
          <span class="flex items-center gap-1.5 min-w-0">
            <.icon name="hero-arrow-right" class="size-3.5 shrink-0 text-base-content/50" />
            <span
              class="font-mono text-xs bg-base-200 rounded-md px-1.5 py-0.5 leading-none truncate max-w-[16rem]"
              title={@merge_target}
            >
              {@merge_target}
            </span>
          </span>
        <% end %>
        <%= if @commit_sha do %>
          <span class="flex items-center gap-1.5 min-w-0" title={@commit_sha}>
            <.icon name="hero-code-bracket" class="size-4 shrink-0" />
            <span class="font-mono text-xs bg-base-200 rounded-md px-1.5 py-0.5 leading-none">{String.slice(
              @commit_sha,
              0,
              7
            )}</span>
          </span>
        <% end %>
        <%= if @task_type do %>
          <%!-- zh_CN: 任务类型（genesis/evolve） --%>
          <span class="leading-none">{String.capitalize(to_string(@task_type))}</span>
        <% end %>
        <%= if @task_id do %>
          <span class="min-w-0 max-w-full truncate font-mono text-xs leading-none" title={@task_id}>{@task_id}</span>
        <% end %>
        <%= if @model_id do %>
          <%!-- zh_CN: LLM 模型配置 id --%>
          <span
            class="min-w-0 max-w-[min(100%,16rem)] truncate font-mono text-xs leading-none"
            title={@model_id}
          >{@model_id}</span>
        <% end %>
        <%= if @agent_count do %>
          <span class="flex items-center gap-1.5 leading-none">
            <.icon name="hero-user-group" class="size-4 shrink-0" />
            <%!-- zh_CN: 智能体数量 --%>
            {format_number(@agent_count)}
          </span>
        <% end %>
        <%= if @started_at do %>
          <span class="leading-none">{relative_time(@started_at)}</span>
        <% end %>
        <%= if @started_at && @finished_at do %>
          <.icon name="hero-arrow-right" class="size-3.5 shrink-0 text-base-content/50" />
        <% end %>
        <%= if @finished_at do %>
          <span class="leading-none">{relative_time(@finished_at)}</span>
        <% end %>
      </div>

      <%!-- Row 3 (only when stats present): GitHub-style compact diff-stat row --%>
      <%= if @stats do %>
        <% commits_count = Map.get(@stats, :commits_count, Map.get(@stats, "commits_count", 0)) %>
        <% files_count = Map.get(@stats, :files_count, Map.get(@stats, "files_count", 0)) %>
        <% additions = Map.get(@stats, :additions, Map.get(@stats, "additions", 0)) %>
        <% deletions = Map.get(@stats, :deletions, Map.get(@stats, "deletions", 0)) %>
        <div class="flex flex-wrap items-center gap-x-3 gap-y-1 text-sm">
          <span class="flex items-center gap-1.5 text-xs text-base-content/80">
            <.icon name="hero-clock" class="size-4" />
            <%!-- zh_CN: commit → "提交" --%>
            {ngettext("%{count} commit", "%{count} commits", commits_count, count: commits_count)}
          </span>
          <span class="flex items-center gap-1.5 text-xs text-base-content/80">
            <.icon name="hero-document-text" class="size-4" />
            {gettext("%{count} files changed", count: files_count)}
          </span>
          <span class="text-success font-bold flex items-center gap-1">
            <%!-- zh_CN: +新增行数 --%>
            <.icon name="hero-arrow-up" class="size-3.5" />
            {additions}
          </span>
          <span class="text-error font-bold flex items-center gap-1">
            <%!-- zh_CN: −删除行数 --%>
            <.icon name="hero-arrow-down" class="size-3.5" />
            {deletions}
          </span>
        </div>
      <% end %>
    </header>
    """
  end

  # ---------------------------------------------------------------------------
  # task_outcome_banner/1 — the page's OUTCOME statement, rendered directly
  # under the header so it is visible on every tab. It tells the truth for
  # every terminal outcome, not only for a successful mergeable one:
  #
  #   * `:failed`    — error tint; merge/reject are unavailable, the failure
  #                    record and (when one exists) the agent report ARE the
  #                    record of the run.
  #   * `:cancelled` — warning tint; preserved changes stay reviewable, and a
  #                    cancellation that produced nothing says so.
  #   * otherwise    — info tint: a completed task without a report (or an
  #                    unexpected status) is stated, never implied.
  #
  # A completed task WITH a report renders nothing (the agent summary below is
  # the report), and a nil outcome means "not loaded yet" — also nothing.
  # ---------------------------------------------------------------------------

  attr(:outcome, :atom, default: nil)
  attr(:task_status, :atom, default: nil)
  attr(:task_error, :any, default: nil)
  attr(:has_report, :boolean, default: true)
  attr(:has_changes, :boolean, default: false)
  attr(:diagnostics_url, :string, default: nil)

  def task_outcome_banner(assigns) do
    assigns =
      assign(assigns,
        tone: banner_tone(assigns.outcome),
        headline: banner_headline(assigns.outcome),
        body: banner_body(assigns.outcome, assigns.has_changes, assigns.task_status),
        error_message: error_message(assigns.task_error),
        error_kind: error_field(assigns.task_error, :kind),
        error_source: error_field(assigns.task_error, :source)
      )

    ~H"""
    <div
      :if={show_outcome_banner?(@outcome, @has_report)}
      id="review-task-outcome"
      data-outcome={to_string(@outcome)}
      class={["rounded-xl border p-4 space-y-2", banner_tone_class(@tone)]}
    >
      <div class="flex items-start gap-2.5">
        <.icon
          name={banner_icon(@tone)}
          class={"size-5 shrink-0 mt-0.5 " <> banner_text_class(@tone)}
        />
        <div class="min-w-0 flex-1 space-y-1.5">
          <p class={["text-sm font-semibold", banner_text_class(@tone)]}>
            {@headline}
          </p>
          <p class="text-sm text-base-content/80">
            {@body}
          </p>

          <%= if @error_message do %>
            <p class="text-xs font-mono whitespace-pre-wrap break-words text-base-content/80">
              {@error_message}
            </p>
          <% end %>

          <%= if @error_kind || @error_source do %>
            <p class="flex flex-wrap items-center gap-x-3 gap-y-1 text-xs text-base-content/60">
              <span :if={@error_kind}>
                <%!-- zh_CN: 失败类型（如 :crash / :timeout） --%>
                {gettext("Kind: %{kind}", kind: @error_kind)}
              </span>
              <span :if={@error_source}>
                <%!-- zh_CN: 失败来源（如 :agent / :llm） --%>
                {gettext("Source: %{source}", source: @error_source)}
              </span>
            </p>
          <% end %>

          <%= if @outcome in [:failed, :cancelled] and not @has_report do %>
            <p class="text-xs text-base-content/70">
              {gettext("No agent report was recorded for this run.")}
            </p>
          <% end %>

          <%= if is_binary(@diagnostics_url) and String.trim(@diagnostics_url) != "" do %>
            <.link
              navigate={@diagnostics_url}
              id="review-task-diagnostics"
              class="btn btn-sm btn-outline rounded-lg gap-1.5"
            >
              <.icon name="hero-lifebuoy" class="size-4" />
              <%!-- zh_CN: 打开任务诊断（任务详情与运行记录） --%>
              {gettext("Open task diagnostics")}
            </.link>
          <% end %>
        </div>
      </div>
    </div>
    """
  end

  # Nothing to say for "not loaded yet", and nothing for a COMPLETED task that
  # recorded a report (that report is rendered as the agent summary).
  defp show_outcome_banner?(nil, _has_report), do: false
  defp show_outcome_banner?(:completed, true), do: false
  defp show_outcome_banner?(_outcome, _has_report), do: true

  defp banner_tone(:failed), do: :error
  defp banner_tone(:cancelled), do: :warning
  defp banner_tone(_outcome), do: :info

  defp banner_tone_class(:error), do: "border-error/30 bg-error/10"
  defp banner_tone_class(:warning), do: "border-warning/30 bg-warning/10"
  defp banner_tone_class(_tone), do: "border-info/30 bg-info/10"

  defp banner_text_class(:error), do: "text-error"
  defp banner_text_class(:warning), do: "text-warning"
  defp banner_text_class(_tone), do: "text-info"

  defp banner_icon(:error), do: "hero-x-circle"
  defp banner_icon(:warning), do: "hero-exclamation-triangle"
  defp banner_icon(_tone), do: "hero-information-circle"

  defp banner_headline(:failed), do: gettext("This task failed")
  defp banner_headline(:cancelled), do: gettext("This task was cancelled")
  defp banner_headline(_outcome), do: gettext("No agent report recorded")

  defp banner_body(:failed, _has_changes, _task_status) do
    gettext(
      "Its work cannot be merged or rejected. The failure details and the agent report (when one was recorded) are the record of this run."
    )
  end

  defp banner_body(:cancelled, true, _task_status) do
    gettext("Its preserved changes can still be reviewed and merged below.")
  end

  defp banner_body(:cancelled, _has_changes, _task_status) do
    gettext(
      "It was cancelled before producing reviewable changes. The agent report and archive (when collected) are the record of this run."
    )
  end

  defp banner_body(_outcome, _has_changes, task_status) do
    gettext(
      "This task ended as %{status} without an agent report. Check the task diagnostics for the transcript.",
      status: current_status_label(task_status)
    )
  end

  # The status label for the "no report" line: the LOCKED helper for a real
  # status atom, and a lowercase "unknown" for nil/unusable input.
  defp current_status_label(status) when is_atom(status) and not is_nil(status) do
    EvoDashWeb.Helpers.task_status_label(status)
  end

  defp current_status_label(status) when is_binary(status) do
    EvoDashWeb.Helpers.task_status_label(status)
  end

  defp current_status_label(_status), do: gettext("unknown")

  # The failure record is untrusted decoded JSON: read one field totally (atom
  # key first, then the string-keyed variant) and render scalars only.
  defp error_field(task_error, key) when is_map(task_error) do
    case Map.get(task_error, key) || Map.get(task_error, Atom.to_string(key)) do
      nil -> nil
      value when is_binary(value) -> blank_to_nil(value)
      value when is_atom(value) -> Atom.to_string(value)
      value when is_integer(value) -> Integer.to_string(value)
      value when is_float(value) -> to_string(value)
      _other -> nil
    end
  end

  defp error_field(_task_error, _key), do: nil

  defp error_message(task_error) when is_map(task_error), do: error_field(task_error, :message)
  defp error_message(task_error) when is_binary(task_error), do: blank_to_nil(task_error)
  defp error_message(_task_error), do: nil

  defp blank_to_nil(value) when is_binary(value) do
    if String.trim(value) == "", do: nil, else: value
  end

  @doc """
  One-line display title for a task objective: the first line, trimmed, and
  truncated to ~100 chars with an ellipsis when longer. Empty input is returned
  unchanged.
  """
  @spec short_title(nil | String.t()) :: nil | String.t()
  def short_title(nil), do: nil

  def short_title(title) when is_binary(title) do
    first_line =
      title
      |> String.split("\n")
      |> List.first()
      |> String.trim()

    if String.length(first_line) > 100 do
      String.slice(first_line, 0, 100) <> "…"
    else
      first_line
    end
  end

  # ---------------------------------------------------------------------------
  # agent_summary/1 — The agent's final message as a comment-style card with a
  # Markdown/Raw toggle and a copy button.
  # ---------------------------------------------------------------------------

  # Byte cap for the rendered previews (agent summary + objective). Anything
  # larger is truncated for DISPLAY; the copy payloads are capped separately
  # (see @copy_byte_limit / copy_payload/1).
  @preview_byte_limit 16_384

  # Byte cap for the clipboard payload embedded in `data-content`. That
  # attribute is materialized in the rendered HTML, so an uncapped payload puts
  # the whole multi-MB blob in the DOM even though Markdown rendering is
  # bounded. 1 MiB keeps essentially every real task result/copy verbatim while
  # bounding the pathological case; the untruncated text stays reachable through
  # the explicit Full Result modal / JSON export.
  @copy_byte_limit 1_048_576

  # Caps a copy payload at @copy_byte_limit. Total: a non-binary value yields an
  # empty preview rather than raising.
  defp copy_payload(text), do: blob_preview(text, @copy_byte_limit)

  # Appends a hint to a copy button's `title` when the payload was truncated, so
  # the truncation is never silent.
  defp copy_button_title(base_title, truncated?) do
    if truncated? do
      # zh_CN: 复制内容被截断到前 1 MB 时附加的提示（"Full view" 指完整结果弹窗/JSON 导出）
      base_title <>
        " — " <>
        gettext("Copy is limited to the first 1 MB — open the Full view for the complete text")
    else
      base_title
    end
  end

  attr(:summary, :string, required: true)
  attr(:summary_raw, :boolean, default: false)
  attr(:model_id, :string, default: nil)
  attr(:finished_at, :any, default: nil)

  def agent_summary(assigns) do
    # The summary IS the task's final agent message and can be enormous
    # (measured: 108 MB) — Markdown-rendering the whole blob on every rerender
    # freezes the page. Build ONE capped preview per render and feed it to both
    # the markdown and raw branches (never the whole blob). The copy payload is
    # capped separately at @copy_byte_limit.
    preview = blob_preview(assigns.summary, @preview_byte_limit)
    copy = copy_payload(assigns.summary)

    assigns =
      assign(assigns,
        summary_preview: preview.text,
        summary_truncated?: preview.truncated?,
        summary_shown_bytes: byte_size(preview.text),
        summary_total_bytes: preview.total_bytes,
        summary_copy_text: copy.text,
        summary_copy_truncated?: copy.truncated?
      )

    ~H"""
    <div class="rounded-xl border border-base-300 bg-base-100 overflow-hidden">
      <%!-- header strip --%>
      <div class="flex flex-wrap items-center gap-2 px-3 py-2.5 sm:px-4 border-b border-base-300 bg-base-200/40 min-w-0">
        <div class="size-7 rounded-lg bg-primary/10 text-primary-standalone flex items-center justify-center shrink-0">
          <.icon name="hero-sparkles" class="size-4" />
        </div>
        <span class="text-base font-semibold text-base-content/85 shrink-0">
          <%!-- zh_CN: 智能体报告 — the agent's final message --%>
          {gettext("Agent Report")}
        </span>
        <div :if={@summary_preview != ""} class="ml-auto flex items-center gap-2 min-w-0">
          <%= if @model_id || @finished_at do %>
            <%!-- Meta strip: model id and relative time share font-mono +
                 leading-none so they sit on one optical line (no baseline
                 drift between mono metrics and sans text). --%>
            <div class="hidden lg:flex max-w-40 items-center gap-2 text-xs text-base-content/60 min-w-0">
              <%= if @model_id do %>
                <span class="font-mono truncate leading-none" title={@model_id}>{@model_id}</span>
              <% end %>
              <%= if @finished_at do %>
                <span class="shrink-0 font-mono leading-none">{relative_time(@finished_at)}</span>
              <% end %>
            </div>
          <% end %>
          <div class="flex items-center gap-1 shrink-0">
            <div class="join">
              <button
                class={["join-item btn btn-sm", !@summary_raw && "btn-active btn-primary"]}
                type="button"
                phx-click="toggle_summary_view"
                phx-value-mode="markdown"
                aria-pressed={to_string(!@summary_raw)}
                title={gettext("Rendered Markdown")}
              >
                <.icon name="hero-document-text" class="size-3.5" />
                {gettext("Markdown")}
              </button>
              <button
                class={["join-item btn btn-sm", @summary_raw && "btn-active btn-primary"]}
                type="button"
                phx-click="toggle_summary_view"
                phx-value-mode="raw"
                aria-pressed={to_string(@summary_raw)}
                title={gettext("Raw Text")}
              >
                <.icon name="hero-code-bracket" class="size-3.5" />
                {gettext("Raw")}
              </button>
            </div>
            <button
              id="summary-copy-btn"
              type="button"
              class="btn btn-ghost btn-sm btn-square"
              phx-hook="ClipboardCopy"
              data-content={@summary_copy_text}
              title={copy_button_title(gettext("Copy agent summary"), @summary_copy_truncated?)}
              aria-label={copy_button_title(gettext("Copy agent summary"), @summary_copy_truncated?)}
            >
              <.icon name="hero-clipboard" class="size-3.5" />
            </button>
          </div>
        </div>
      </div>
      <%!-- body: the CAPPED preview only (@summary_preview); the copy button
           above carries its own capped payload (@summary_copy_text, 1 MiB). --%>
      <div class="px-4 py-4 sm:px-5">
        <%= cond do %>
          <% @summary_preview == "" -> %>
            <p class="text-sm text-base-content/70">{gettext("No agent report recorded.")}</p>
          <% @summary_raw -> %>
            <%!-- The <pre> must stay single-line: whitespace-pre-wrap renders any
               leading indentation from a formatter-wrapped line as visible text. --%>
            <pre class="text-sm whitespace-pre-wrap break-words font-mono bg-base-200/30 p-4 rounded-lg border border-base-200">{@summary_preview}</pre>
          <% true -> %>
            <div class="md-content text-base leading-relaxed">
              {raw(EvoDash.MarkdownRender.render(@summary_preview))}
            </div>
        <% end %>
        <%= if @summary_truncated? do %>
          <p class="mt-2 text-xs text-base-content/60">
            <%!-- zh_CN: 内容过大，仅渲染前若干字节 — 预览截断提示（复制按钮上限 1 MiB） --%>
            {gettext("Showing %{shown} of %{total} bytes",
              shown: format_number(@summary_shown_bytes),
              total: format_number(@summary_total_bytes)
            )}
          </p>
        <% end %>
      </div>
    </div>
    """
  end

  # ---------------------------------------------------------------------------
  # objective_section/1 — The task's original objective as a dedicated card
  # (rendered on its own "Objective" tab). Same header contract as
  # agent_summary: Markdown/Raw join toggle + ClipboardCopy button.
  # ---------------------------------------------------------------------------

  attr(:objective, :string, default: nil)
  attr(:objective_raw, :boolean, default: false)

  def objective_section(assigns) do
    # Same treatment as agent_summary/1: the objective is user/agent-authored and
    # unbounded, so only a capped preview ever reaches MarkdownRender or the
    # template. The copy payload is capped separately at @copy_byte_limit.
    preview = blob_preview(assigns.objective, @preview_byte_limit)
    copy = copy_payload(assigns.objective)

    assigns =
      assign(assigns,
        objective_preview: preview.text,
        objective_truncated?: preview.truncated?,
        objective_shown_bytes: byte_size(preview.text),
        objective_total_bytes: preview.total_bytes,
        objective_copy_text: copy.text,
        objective_copy_truncated?: copy.truncated?
      )

    ~H"""
    <div class="rounded-xl border border-base-300 bg-base-100 overflow-hidden">
      <%!-- header strip --%>
      <div class="flex flex-wrap items-center gap-2 px-3 py-2.5 sm:px-4 border-b border-base-300 bg-base-200/40 min-w-0">
        <div class="size-7 rounded-lg bg-base-content/5 text-base-content/60 flex items-center justify-center shrink-0">
          <.icon name="hero-chat-bubble-bottom-center-text" class="size-4" />
        </div>
        <span class="text-base font-semibold text-base-content/85 shrink-0">
          <%!-- zh_CN: 目标 — 提交给智能体的任务目标 --%>
          {gettext("Objective")}
        </span>
        <div class="ml-auto flex items-center gap-1 shrink-0">
          <%!-- Controls render only when there is something to show/copy. --%>
          <%= if @objective not in [nil, ""] do %>
            <div class="join">
              <button
                class={["join-item btn btn-sm", !@objective_raw && "btn-active btn-primary"]}
                type="button"
                phx-click="toggle_objective_view"
                phx-value-mode="markdown"
                aria-pressed={to_string(!@objective_raw)}
                title={gettext("Rendered Markdown")}
              >
                <.icon name="hero-document-text" class="size-3.5" />
                {gettext("Markdown")}
              </button>
              <button
                class={["join-item btn btn-sm", @objective_raw && "btn-active btn-primary"]}
                type="button"
                phx-click="toggle_objective_view"
                phx-value-mode="raw"
                aria-pressed={to_string(@objective_raw)}
                title={gettext("Raw Text")}
              >
                <.icon name="hero-code-bracket" class="size-3.5" />
                {gettext("Raw")}
              </button>
            </div>
            <%!-- zh_CN: 复制目标文本 — 复制按钮携带的文本上限为 1 MiB（见 copy_payload/1） --%>
            <button
              id="objective-copy-btn"
              type="button"
              class="btn btn-ghost btn-sm btn-square"
              phx-hook="ClipboardCopy"
              data-content={@objective_copy_text}
              title={copy_button_title(gettext("Copy objective"), @objective_copy_truncated?)}
              aria-label={copy_button_title(gettext("Copy objective"), @objective_copy_truncated?)}
            >
              <.icon name="hero-clipboard" class="size-3.5" />
            </button>
          <% end %>
        </div>
      </div>
      <%!-- body (capped preview only — the copy button carries its own 1 MiB cap) --%>
      <div class="px-4 py-4 sm:px-5">
        <%!-- LoadData normalizes a missing objective to "" (never nil) — the
             empty state covers both. --%>
        <%= if @objective in [nil, ""] do %>
          <.icon
            name="hero-chat-bubble-bottom-center-text"
            class="size-10 text-base-content/50 mx-auto mb-3"
          />
          <p class="text-sm text-base-content/70 text-center">
            <%!-- zh_CN: 该任务没有记录目标文本 --%>
            {gettext("No objective recorded for this task.")}
          </p>
        <% else %>
          <%= if @objective_raw do %>
            <%!-- The <pre> must stay single-line: whitespace-pre-wrap renders any
                 leading indentation from a formatter-wrapped line as visible text. --%>
            <pre class="text-sm whitespace-pre-wrap break-words font-mono bg-base-200/30 p-4 rounded-lg border border-base-200">{@objective_preview}</pre>
          <% else %>
            <div class="max-h-[32rem] overflow-y-auto">
              <div class="md-content text-base leading-relaxed">
                {raw(EvoDash.MarkdownRender.render(@objective_preview))}
              </div>
            </div>
          <% end %>
          <%= if @objective_truncated? do %>
            <p class="mt-2 text-xs text-base-content/60">
              <%!-- zh_CN: 内容过大，仅渲染前若干字节 — 预览截断提示（复制按钮上限 1 MiB） --%>
              {gettext("Showing %{shown} of %{total} bytes",
                shown: format_number(@objective_shown_bytes),
                total: format_number(@objective_total_bytes)
              )}
            </p>
          <% end %>
        <% end %>
      </div>
    </div>
    """
  end

  # ---------------------------------------------------------------------------
  # task_summary/1 — Collapsible disclosure with a compact definition-style
  # detail list and the full Token & Cost usage breakdown (no nested details).
  # ---------------------------------------------------------------------------

  attr(:usage, :map, default: nil)
  attr(:agent_count, :integer, default: nil)
  attr(:task_type, :atom, default: nil)
  attr(:status, :atom, default: nil)
  attr(:model_id, :string, default: nil)
  attr(:started_at, :any, default: nil)
  attr(:finished_at, :any, default: nil)

  def task_summary(assigns) do
    ~H"""
    <details class="group rounded-xl border border-base-300 bg-base-100">
      <summary class="flex cursor-pointer select-none items-center gap-2 px-4 py-3 text-sm font-medium text-base-content/80 hover:text-base-content hover:bg-base-200/50 transition-colors list-none [&::-webkit-details-marker]:hidden">
        <.icon name="hero-information-circle" class="size-4 shrink-0 text-base-content/60" />
        <%!-- zh_CN: 任务详情 — 展开查看状态/模型/用量 --%>
        {gettext("Task Details")}
        <.icon
          name="hero-chevron-down"
          class="size-4 shrink-0 text-base-content/60 transition-transform group-open:rotate-180 ml-auto"
        />
      </summary>

      <div class="border-t border-base-300 px-4 py-4 sm:px-5 space-y-4">
        <dl class="space-y-2">
          <%= if @status do %>
            <div class="flex items-center gap-3">
              <dt class="text-xs text-base-content/60 w-28 shrink-0">
                <%!-- zh_CN: 任务运行状态（completed/failed 等） --%>
                {gettext("Status")}
              </dt>
              <dd>
                <span class={[
                  "badge badge-sm font-medium border-0 px-2 py-1 rounded-md",
                  task_status_badge(@status)
                ]}>
                  {String.capitalize(to_string(@status))}
                </span>
              </dd>
            </div>
          <% end %>
          <%= if @task_type do %>
            <div class="flex items-center gap-3">
              <dt class="text-xs text-base-content/60 w-28 shrink-0">
                <%!-- zh_CN: 任务类型（genesis/evolve） --%>
                {gettext("Type")}
              </dt>
              <dd class="text-sm">{String.capitalize(to_string(@task_type))}</dd>
            </div>
          <% end %>
          <%= if @model_id do %>
            <div class="flex items-center gap-3">
              <dt class="text-xs text-base-content/60 w-28 shrink-0">
                <%!-- zh_CN: LLM 模型配置 id --%>
                {gettext("Model")}
              </dt>
              <dd class="text-sm font-mono" title={@model_id}>{@model_id}</dd>
            </div>
          <% end %>
          <%= if @agent_count do %>
            <div class="flex items-center gap-3">
              <dt class="text-xs text-base-content/60 w-28 shrink-0">
                <%!-- zh_CN: 智能体数量 --%>
                {gettext("Agents")}
              </dt>
              <dd class="text-sm">{format_number(@agent_count)}</dd>
            </div>
          <% end %>
          <%= if @started_at do %>
            <div class="flex items-center gap-3">
              <dt class="text-xs text-base-content/60 w-28 shrink-0">{gettext("Started")}</dt>
              <dd class="text-sm">{relative_time(@started_at)}</dd>
            </div>
          <% end %>
          <%= if @finished_at do %>
            <div class="flex items-center gap-3">
              <dt class="text-xs text-base-content/60 w-28 shrink-0">{gettext("Finished")}</dt>
              <dd class="text-sm">{relative_time(@finished_at)}</dd>
            </div>
          <% end %>
        </dl>

        <%= if @usage do %>
          <div class="bg-base-200/30 rounded-lg border border-base-200/80 p-4 space-y-3">
            <h4 class="text-xs font-semibold uppercase tracking-wide text-base-content/60">
              <%!-- zh_CN: Token → "词元"；词元与费用用量明细 --%>
              {gettext("Token & Cost Usage")}
            </h4>

            <dl class="space-y-2">
              <div class="flex items-center gap-3">
                <dt class="text-xs text-base-content/60 w-28 shrink-0">
                  <%!-- zh_CN: Token → "词元" --%>
                  {gettext("Input Tokens")}
                </dt>
                <dd class="text-sm font-medium">
                  {format_number(Map.get(@usage, :input_tokens, 0))}
                </dd>
              </div>
              <div class="flex items-center gap-3">
                <dt class="text-xs text-base-content/60 w-28 shrink-0">
                  <%!-- zh_CN: Token → "词元" --%>
                  {gettext("Output Tokens")}
                </dt>
                <dd class="text-sm font-medium">
                  {format_number(Map.get(@usage, :output_tokens, 0))}
                </dd>
              </div>
              <div class="flex items-center gap-3">
                <dt class="text-xs text-base-content/60 w-28 shrink-0">
                  <%!-- zh_CN: Token → "词元" --%>
                  {gettext("Total Tokens")}
                </dt>
                <dd class="text-sm font-medium">
                  {format_number(Map.get(@usage, :total_tokens, 0))}
                </dd>
              </div>
            </dl>

            <%= if Map.get(@usage, :cached_tokens, 0) > 0 or Map.get(@usage, :cache_creation_tokens, 0) > 0 do %>
              <dl class="space-y-2 border-t border-base-200 pt-3">
                <div class="flex items-center gap-3">
                  <dt class="text-xs text-base-content/60 w-28 shrink-0">
                    <%!-- zh_CN: Token → "词元"；命中缓存的输入词元 --%>
                    {gettext("Cached Tokens")}
                  </dt>
                  <dd class="text-sm font-medium">
                    {format_number(Map.get(@usage, :cached_tokens, 0))}
                  </dd>
                </div>
                <div class="flex items-center gap-3">
                  <dt class="text-xs text-base-content/60 w-28 shrink-0">
                    <%!-- zh_CN: 写入缓存的词元（缓存构建） --%>
                    {gettext("Cache Creation")}
                  </dt>
                  <dd class="text-sm font-medium">
                    {format_number(Map.get(@usage, :cache_creation_tokens, 0))}
                  </dd>
                </div>
                <div class="flex items-center gap-3">
                  <dt class="text-xs text-base-content/60 w-28 shrink-0">
                    <%!-- zh_CN: 缓存命中率 --%>
                    {gettext("Cache Hit Rate")}
                  </dt>
                  <dd class="flex items-center gap-2 flex-1 min-w-0">
                    <span class="text-sm font-medium text-success">
                      {format_cache_hit_rate(@usage)}
                    </span>
                    <progress
                      class="progress progress-success w-24"
                      value={EvoDashWeb.Components.UsageFormat.cache_hit_percent(@usage)}
                      max="100"
                    ></progress>
                  </dd>
                </div>
              </dl>
            <% end %>

            <dl class="space-y-2 border-t border-base-200 pt-3">
              <div class="flex items-center gap-3">
                <dt class="text-xs text-base-content/60 w-28 shrink-0">
                  <%!-- zh_CN: 输入费用（美元） --%>
                  {gettext("Input Cost")}
                </dt>
                <dd class="text-sm font-medium">
                  ${format_cost(Map.get(@usage, :input_cost, 0))}
                </dd>
              </div>
              <div class="flex items-center gap-3">
                <dt class="text-xs text-base-content/60 w-28 shrink-0">
                  <%!-- zh_CN: 输出费用（美元） --%>
                  {gettext("Output Cost")}
                </dt>
                <dd class="text-sm font-medium">
                  ${format_cost(Map.get(@usage, :output_cost, 0))}
                </dd>
              </div>
              <div class="flex items-center gap-3">
                <dt class="text-xs text-base-content/60 w-28 shrink-0">
                  <%!-- zh_CN: 总费用（美元） --%>
                  {gettext("Total Cost")}
                </dt>
                <dd class="text-sm font-medium text-primary-standalone">
                  ${format_cost(Map.get(@usage, :total_cost, 0))}
                </dd>
              </div>
            </dl>
            <.cost_estimate_notice />
          </div>
        <% end %>
      </div>
    </details>
    """
  end
end
