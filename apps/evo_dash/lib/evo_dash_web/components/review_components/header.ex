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

  def page_header(assigns) do
    ~H"""
    <div class="rounded-xl border border-base-300 bg-base-100 p-4 sm:p-5 space-y-2">
      <%!-- Row 1: back link + one-line truncated title + status badges --%>
      <div class="flex items-center gap-2 min-w-0">
        <.link
          navigate={@back_url}
          class="btn btn-ghost btn-sm btn-square shrink-0"
          title={gettext("Back to projects")}
          aria-label={gettext("Back to projects")}
        >
          <.icon name="hero-arrow-left" class="size-4" />
        </.link>
        <h1 class="text-lg font-semibold truncate min-w-0 flex-1" title={@title}>
          {short_title(@title)}
        </h1>
        <span class={["badge badge-sm gap-1 shrink-0 font-medium", review_status_badge(@status)]}>
          <.icon name={review_status_icon(@status)} class="size-3.5" />
          {review_status_label(@status)}
        </span>
        <%= if @task_status do %>
          <span class={[
            "badge badge-sm shrink-0 font-medium border-0 px-2 py-1 rounded-md",
            task_status_badge(@task_status)
          ]}>
            {String.capitalize(to_string(@task_status))}
          </span>
        <% end %>
      </div>

      <%!-- Row 2: meta line (repo path, branch → merge target, task facts).
           Vertical rhythm: every text span shares `leading-none` so the boxed
           chips (symmetric py-0.5) and the bare mono/sans spans all center on
           the same optical line. Machine-ish values are `font-mono`; only the
           human words (task type label, relative times) stay sans. --%>
      <div class="flex flex-wrap items-center gap-x-3 gap-y-1.5 text-sm text-base-content/70">
        <%= if @repo_path do %>
          <span class="flex items-center gap-1.5 min-w-0" title={@repo_path}>
            <.icon name="hero-folder" class="size-4 shrink-0" />
            <span class="font-mono truncate leading-none">{@repo_path}</span>
          </span>
        <% end %>
        <%= if @branch_name do %>
          <span class="flex items-center gap-1.5 min-w-0">
            <.icon name="hero-code-bracket-square" class="size-4 shrink-0" />
            <span
              class="font-mono bg-base-200 rounded-md px-1.5 py-0.5 leading-none truncate max-w-[16rem]"
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
              class="font-mono bg-base-200 rounded-md px-1.5 py-0.5 leading-none truncate max-w-[16rem]"
              title={@merge_target}
            >
              {@merge_target}
            </span>
          </span>
        <% end %>
        <%= if @commit_sha do %>
          <span class="flex items-center gap-1.5 min-w-0" title={@commit_sha}>
            <.icon name="hero-code-bracket" class="size-4 shrink-0" />
            <span class="font-mono bg-base-200 rounded-md px-1.5 py-0.5 leading-none">{String.slice(
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
          <span class="font-mono leading-none" title={@task_id}>{@task_id}</span>
        <% end %>
        <%= if @model_id do %>
          <%!-- zh_CN: LLM 模型配置 id --%>
          <span class="font-mono leading-none" title={@model_id}>{@model_id}</span>
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
          <span class="flex items-center gap-1.5 text-base-content/80">
            <.icon name="hero-clock" class="size-4" />
            <%!-- zh_CN: commit → "提交" --%>
            {ngettext("%{count} commit", "%{count} commits", commits_count, count: commits_count)}
          </span>
          <span class="flex items-center gap-1.5 text-base-content/80">
            <.icon name="hero-document-text" class="size-4" />
            {gettext("%{count} files changed", count: files_count)}
          </span>
          <span class="text-success font-semibold flex items-center gap-1">
            <%!-- zh_CN: +新增行数 --%>
            <.icon name="hero-arrow-up" class="size-3.5" />
            {additions}
          </span>
          <span class="text-error font-semibold flex items-center gap-1">
            <%!-- zh_CN: −删除行数 --%>
            <.icon name="hero-arrow-down" class="size-3.5" />
            {deletions}
          </span>
        </div>
      <% end %>
    </div>
    """
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

  attr(:summary, :string, required: true)
  attr(:summary_raw, :boolean, default: false)
  attr(:model_id, :string, default: nil)
  attr(:finished_at, :any, default: nil)

  def agent_summary(assigns) do
    ~H"""
    <div class="rounded-xl border border-base-300 bg-base-100 overflow-hidden">
      <%!-- header strip --%>
      <div class="flex items-center gap-3 px-4 py-3 border-b border-base-300 bg-base-200/40 min-w-0">
        <div class="size-8 rounded-lg bg-primary/10 text-primary flex items-center justify-center shrink-0">
          <.icon name="hero-sparkles" class="size-4" />
        </div>
        <span class="font-semibold text-base-content/85 shrink-0">
          <%!-- zh_CN: 智能体报告 — the agent's final message --%>
          {gettext("Agent Report")}
        </span>
        <div class="ml-auto flex items-center gap-2 shrink-0 min-w-0">
          <%= if @model_id || @finished_at do %>
            <%!-- Meta strip: model id and relative time share font-mono +
                 leading-none so they sit on one optical line (no baseline
                 drift between mono metrics and sans text). --%>
            <div class="hidden sm:flex items-center gap-2 text-xs text-base-content/60 min-w-0">
              <%= if @model_id do %>
                <span class="font-mono truncate leading-none" title={@model_id}>{@model_id}</span>
              <% end %>
              <%= if @finished_at do %>
                <span class="font-mono leading-none">{relative_time(@finished_at)}</span>
              <% end %>
            </div>
          <% end %>
          <div class="flex items-center gap-1 shrink-0">
            <div class="join">
              <button
                class={["join-item btn btn-xs", !@summary_raw && "btn-active btn-primary"]}
                phx-click="toggle_summary_view"
                phx-value-mode="markdown"
                title={gettext("Rendered Markdown")}
              >
                <.icon name="hero-document-text" class="size-3.5" />
                {gettext("Markdown")}
              </button>
              <button
                class={["join-item btn btn-xs", @summary_raw && "btn-active btn-primary"]}
                phx-click="toggle_summary_view"
                phx-value-mode="raw"
                title={gettext("Raw Text")}
              >
                <.icon name="hero-code-bracket" class="size-3.5" />
                {gettext("Raw")}
              </button>
            </div>
            <button
              id="summary-copy-btn"
              class="btn btn-ghost btn-xs btn-square"
              phx-hook="ClipboardCopy"
              data-content={@summary}
              title={gettext("Copy agent summary")}
            >
              <.icon name="hero-clipboard" class="size-3.5" />
            </button>
          </div>
        </div>
      </div>
      <%!-- body --%>
      <div class="px-4 py-4 sm:px-5">
        <%= if @summary_raw do %>
          <%!-- The <pre> must stay single-line: whitespace-pre-wrap renders any
               leading indentation from a formatter-wrapped line as visible text. --%>
          <pre class="text-xs sm:text-sm whitespace-pre-wrap break-words font-mono bg-base-200/30 p-4 rounded-lg border border-base-200">{@summary}</pre>
        <% else %>
          <div class="md-content text-sm leading-relaxed">
            {raw(EvoDash.MarkdownRender.render(@summary))}
          </div>
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
    ~H"""
    <div class="rounded-xl border border-base-300 bg-base-100 overflow-hidden">
      <%!-- header strip --%>
      <div class="flex items-center gap-3 px-4 py-3 border-b border-base-300 bg-base-200/40 min-w-0">
        <div class="size-8 rounded-lg bg-base-content/5 text-base-content/60 flex items-center justify-center shrink-0">
          <.icon name="hero-chat-bubble-bottom-center-text" class="size-4" />
        </div>
        <span class="font-semibold text-base-content/85 shrink-0">
          <%!-- zh_CN: 目标 — 提交给智能体的任务目标 --%>
          {gettext("Objective")}
        </span>
        <div class="ml-auto flex items-center gap-1 shrink-0">
          <%!-- Controls render only when there is something to show/copy. --%>
          <%= if @objective not in [nil, ""] do %>
            <div class="join">
              <button
                class={["join-item btn btn-xs", !@objective_raw && "btn-active btn-primary"]}
                phx-click="toggle_objective_view"
                phx-value-mode="markdown"
                title={gettext("Rendered Markdown")}
              >
                <.icon name="hero-document-text" class="size-3.5" />
                {gettext("Markdown")}
              </button>
              <button
                class={["join-item btn btn-xs", @objective_raw && "btn-active btn-primary"]}
                phx-click="toggle_objective_view"
                phx-value-mode="raw"
                title={gettext("Raw Text")}
              >
                <.icon name="hero-code-bracket" class="size-3.5" />
                {gettext("Raw")}
              </button>
            </div>
            <%!-- zh_CN: 复制目标文本 --%>
            <button
              id="objective-copy-btn"
              class="btn btn-ghost btn-xs btn-square"
              phx-hook="ClipboardCopy"
              data-content={@objective}
              title={gettext("Copy objective")}
            >
              <.icon name="hero-clipboard" class="size-3.5" />
            </button>
          <% end %>
        </div>
      </div>
      <%!-- body --%>
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
            <pre class="text-xs sm:text-sm whitespace-pre-wrap break-words font-mono bg-base-200/30 p-4 rounded-lg border border-base-200">{@objective}</pre>
          <% else %>
            <div class="max-h-[32rem] overflow-y-auto">
              <div class="md-content text-sm leading-relaxed">
                {raw(EvoDash.MarkdownRender.render(@objective))}
              </div>
            </div>
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
                      value={
                        input_tokens = Map.get(@usage, :input_tokens, 0)
                        cached = Map.get(@usage, :cached_tokens, 0)

                        if input_tokens > 0,
                          do: min(round(cached / input_tokens * 100), 100),
                          else: 0
                      }
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
                <dd class="text-sm font-medium text-primary">
                  ${format_cost(Map.get(@usage, :total_cost, 0))}
                </dd>
              </div>
            </dl>
          </div>
        <% end %>
      </div>
    </details>
    """
  end
end
