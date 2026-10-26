defmodule EvoDashWeb.ArchiveComponents do
  @moduledoc """
  Archive components for the dashboard — per-agent archive records, nested agent
  hierarchy tree, and recursive node renderer.

  The archive arrives as bounded PAGES (`EvoDash.NodeContext.list_task_archives/3`)
  and each entry's heavy `"result"` is fetched separately
  (`NodeContext.get_agent_archive/3`), so the render attributes reflect exactly
  that: `total` (the effective total driving paging), `server_total` (the label's
  true archive size), `dropped`/`exhausted?` (the retention window and the
  exhausted archive), `loading_more?`/`more_error` (the page append), and
  `agent_results` (the per-agent lazy result cache).
  `archive_count_line/1` is the ONE count/exhaustion line shared with the review
  page's archive section, so both render sites speak the same numbers.
  """

  # zh_CN: Agent → "智能体", Commit → "提交", Branch → "分支", Token → "词元"

  use EvoDashWeb, :html
  alias EvoDashWeb.ArchiveHelpers

  # PAGING is the real bound on how much archive data reaches the browser (100
  # entries per append), so the render cap is a second safety net rather than
  # the primary one: it stops a fully-loaded huge archive (7 149 real agents)
  # from rendering every node on one rerender. Each record's own text stays
  # capped independently by `blob_preview` (8 KiB result / 4 KiB objective).
  @max_agent_records 300
  @result_preview_bytes 8_192
  @objective_preview_bytes 4_096

  # ---------------------------------------------------------------------------
  # archive_count_line/1 — THE shared count/exhaustion line for both render sites
  # ---------------------------------------------------------------------------

  # Both archive render sites (the task card's `archive_details/1` and the
  # review tab's `archive_review_section/1`) show the SAME count semantics, so
  # the text lives here instead of being duplicated per site. This component
  # renders ONLY paragraphs — the parents own the layout/spacing.
  attr(:total, :integer, required: true)
  attr(:first, :integer, default: 0)
  attr(:last, :integer, default: 0)
  # Records evicted by the retention window (their leading rows are gone).
  attr(:dropped, :integer, default: 0)
  # A pager is rendered (more pages can still be fetched).
  attr(:more?, :boolean, default: false)
  attr(:exhausted?, :boolean, default: false)

  def archive_count_line(assigns) do
    ~H"""
    <%= if @more? or @dropped > 0 do %>
      <p class="text-xs text-base-content/60">
        <%= if @dropped > 0 do %>
          <%!--
            zh_CN: Agent → “智能体”；“earlier entries omitted” → 较早的记录已省略；
            export JSON → 导出 JSON 获取完整归档
          --%>
          {gettext(
            "%{total} agents — showing %{first}–%{last} (earlier entries omitted; export JSON for the full archive)",
            total: format_number(@total),
            first: format_number(@first),
            last: format_number(@last)
          )}
        <% else %>
          <%!--
            zh_CN: Agent → “智能体”；范围写成本次已载入的起止条数，例如
            “7,149 个智能体 — 显示 1–100”；全部载入后只显示 “7,149 个智能体”
          --%>
          {gettext("%{total} agents — showing %{first}–%{last}",
            total: format_number(@total),
            first: format_number(@first),
            last: format_number(@last)
          )}
        <% end %>
      </p>
    <% else %>
      <p class="text-xs text-base-content/60">
        <%!-- zh_CN: Agent → “智能体” --%>
        {gettext("%{total} agents", total: format_number(@total))}
      </p>
    <% end %>
    <%= if @exhausted? do %>
      <p class="text-xs text-base-content/60">
        <%!-- zh_CN: “No more archive entries.” → 没有更多归档记录。 --%>
        {gettext("No more archive entries.")}
      </p>
    <% end %>
    """
  end

  # ---------------------------------------------------------------------------
  # archive_details/1 — Per-agent archive records section (opt-in)
  # ---------------------------------------------------------------------------

  attr(:archive_metadata, :list, default: nil)
  # The EFFECTIVE total (paging decisions), falling back to the loaded count.
  attr(:total, :integer, default: nil)
  # The archive's TRUE size for the label, independent of clamping.
  attr(:server_total, :integer, default: nil)
  # Records evicted by the retention window (older rows are no longer loaded).
  attr(:dropped, :integer, default: 0)
  # The archive is exhausted (a short/empty page arrived), so no pager renders.
  attr(:exhausted?, :boolean, default: false)
  attr(:agent_results, :map, default: %{})
  attr(:loading_more?, :boolean, default: false)
  attr(:more_error, :any, default: nil)
  attr(:task_id, :string, default: nil)

  # Optional node-aware export href (carries `?node=<target_id>` when a remote
  # node is viewed); nil falls back to the plain task export path.
  attr(:export_url, :string, default: nil)

  def archive_details(assigns) do
    entries = List.wrap(assigns.archive_metadata)
    loaded = length(entries)

    # `total` drives the PAGING decision and falls back to the loaded count;
    # `server_total` (when known) is what the LABEL reports, so a clamped page
    # still shows the archive's true size.
    effective_total = total_count(assigns.total, loaded)
    label_total = server_total_count(assigns.server_total, effective_total)
    {first, last} = ArchiveHelpers.retained_page_bounds(loaded, assigns.dropped, label_total)

    archive_more? =
      not assigns.exhausted? and
        ArchiveHelpers.more_pages?(loaded, assigns.dropped, effective_total)

    assigns =
      assign(assigns,
        entries: entries,
        label_total: label_total,
        archive_first: first,
        archive_last: last,
        archive_more?: archive_more?
      )

    ~H"""
    <%= if @entries != [] do %>
      <div class="bg-base-200/30 p-5 rounded-lg border border-base-200/80 hover:border-base-300 transition-colors">
        <div class="flex items-center justify-between mb-4">
          <h4 class="text-sm font-bold flex items-center gap-2">
            <.icon name="hero-archive-box" class="size-4.5 text-primary-standalone" />
            <%!-- zh_CN: Agent → "智能体" --%>{gettext("Archived Agent Details")}
          </h4>
          <%= if @task_id do %>
            <.link
              href={@export_url || "/tasks/#{@task_id}/export"}
              class="btn btn-sm btn-outline btn-primary rounded-md"
              download
            >
              <.icon name="hero-arrow-down-tray" class="size-4 mr-1" /> {gettext("Export JSON")}
            </.link>
          <% end %>
        </div>
        <div class="mb-3">
          <.archive_count_line
            total={@label_total}
            first={@archive_first}
            last={@archive_last}
            dropped={@dropped}
            more?={@archive_more?}
            exhausted?={@exhausted?}
          />
        </div>
        <.archive_tree
          agents={@entries}
          agent_results={@agent_results}
          task_id={@task_id}
        />
        <%= if @archive_more? do %>
          <div class="flex items-center gap-2 mt-3">
            <button
              class="btn btn-sm btn-outline rounded-md"
              phx-click="load_more_task_archive"
              phx-value-task-id={@task_id}
              disabled={@loading_more?}
            >
              <%= if @loading_more? do %>
                <span class="loading loading-spinner loading-xs shrink-0"></span>
                {gettext("Loading…")}
              <% else %>
                <.icon name="hero-arrow-down-circle" class="size-4 mr-1" />
                {gettext("Load more")}
              <% end %>
            </button>
            <%= if @more_error do %>
              <span class="text-xs font-medium text-error truncate min-w-0">
                {gettext("Could not load more archive pages.")}
              </span>
              <button
                class="btn btn-xs btn-ghost rounded-md shrink-0"
                phx-click="load_more_task_archive"
                phx-value-task-id={@task_id}
              >
                <.icon name="hero-arrow-path" class="size-3.5 mr-1" /> {gettext("Retry")}
              </button>
            <% end %>
          </div>
        <% end %>
      </div>
    <% end %>
    """
  end

  # `total` falls back to the loaded count when the caller passes no (or an
  # unusable) total, so a caller that only has records still renders a label.
  defp total_count(total, _loaded) when is_integer(total) and total >= 0, do: total
  defp total_count(_total, loaded), do: loaded

  # The LABEL total: `server_total` when it is a usable count (the archive's true
  # size), else the effective total.
  defp server_total_count(server_total, _fallback)
       when is_integer(server_total) and server_total >= 0,
       do: server_total

  defp server_total_count(_server_total, fallback), do: fallback

  # ---------------------------------------------------------------------------
  # archive_tree/1 — Renders the nested parent-child agent hierarchy
  # ---------------------------------------------------------------------------

  attr(:agents, :list, required: true)
  attr(:agent_results, :map, default: %{})
  attr(:task_id, :string, default: nil)

  def archive_tree(assigns) do
    # Capped BEFORE normalization/grouping, so the per-render cost is bounded by
    # the cap instead of the loaded page count. Computed exactly once per render.
    %{tree: nodes, total: total, shown: shown, truncated?: truncated?} =
      ArchiveHelpers.build_tree_capped(assigns.agents, @max_agent_records)

    assigns =
      assign(assigns, nodes: nodes, total: total, shown: shown, truncated?: truncated?)

    ~H"""
    <div class="space-y-3">
      <%= if @truncated? do %>
        <p class="text-xs text-base-content/60">
          <%!-- zh_CN: “records” → “条智能体记录”；export JSON → 导出 JSON 以查看完整归档 --%>
          {gettext("Showing %{shown} of %{total} agent records — export JSON for the full archive",
            shown: format_number(@shown),
            total: format_number(@total)
          )}
        </p>
      <% end %>
      <%= for node <- @nodes do %>
        <.archive_tree_node
          agent={node.agent}
          children={node.children}
          agent_results={@agent_results}
          task_id={@task_id}
        />
      <% end %>
    </div>
    """
  end

  # ---------------------------------------------------------------------------
  # archive_tree_node/1 — Recursive node renderer for a single archived agent
  # ---------------------------------------------------------------------------

  attr(:agent, :map, required: true)
  attr(:children, :list, default: [])
  attr(:agent_results, :map, default: %{})
  attr(:task_id, :string, default: nil)

  def archive_tree_node(assigns) do
    agent_id = ArchiveHelpers.agent_key(assigns.agent, :agent_id)

    assigns =
      assigns
      |> assign(:agent_id, agent_id)
      |> assign(:result_view, result_view(assigns.agent, assigns.agent_results, agent_id))
      |> assign(
        :objective_preview,
        blob_preview(
          ArchiveHelpers.agent_key(assigns.agent, :objective),
          @objective_preview_bytes
        )
      )

    ~H"""
    <div class="border border-base-200 rounded-xl bg-base-100/60 overflow-hidden">
      <div class="p-4 space-y-3">
        <!-- Agent ID + depth badge -->
        <div class="flex items-center gap-2 flex-wrap">
          <span class="font-bold font-mono text-sm text-base-content">{@agent_id}</span>
          <%= if ArchiveHelpers.agent_key(@agent, :depth) do %>
            <span class="badge badge-ghost badge-sm font-mono">{gettext("Depth")}: {ArchiveHelpers.agent_key(
              @agent,
              :depth
            )}</span>
          <% end %>
        </div>

        <!-- Objective -->
        <%= if @objective_preview.text != "" do %>
          <div>
            <div class="text-xs text-base-content/60 mb-0.5">{gettext("Objective")}</div>
            <div class="text-sm text-base-content/90 whitespace-pre-wrap break-words">
              {@objective_preview.text}
            </div>
            <%= if @objective_preview.truncated? do %>
              <p class="text-xs text-base-content/60 mt-1">
                <%!-- zh_CN: 字节数预览提示（bytes → “字节”） --%>
                {gettext("Showing %{shown} of %{total} bytes",
                  shown: format_number(byte_size(@objective_preview.text)),
                  total: format_number(@objective_preview.total_bytes)
                )}
              </p>
            <% end %>
          </div>
        <% end %>

        <!-- Result — paged entries omit it until the agent is asked for it -->
        <%= case @result_view do %>
          <% {:loaded, preview} -> %>
            <%= if preview.text != "" do %>
              <div>
                <div class="text-xs text-base-content/60 mb-0.5">{gettext("Result")}</div>
                <div class="text-sm text-base-content/90 whitespace-pre-wrap break-words">
                  {preview.text}
                </div>
                <%= if preview.truncated? do %>
                  <p class="text-xs text-base-content/60 mt-1">
                    <%!-- zh_CN: 字节数预览提示（bytes → “字节”） --%>
                    {gettext("Showing %{shown} of %{total} bytes",
                      shown: format_number(byte_size(preview.text)),
                      total: format_number(preview.total_bytes)
                    )}
                  </p>
                <% end %>
              </div>
            <% end %>
          <% :loading -> %>
            <div class="flex items-center gap-2">
              <span class="loading loading-spinner loading-xs text-base-content/60 shrink-0"></span>
              <span class="text-xs font-medium text-base-content/70">
                {gettext("Loading result…")}
              </span>
            </div>
          <% {:error, _reason} -> %>
            <div class="flex items-center gap-2 min-w-0">
              <span class="text-xs font-medium text-error truncate min-w-0">
                {gettext("Could not load this agent's result.")}
              </span>
              <button
                class="btn btn-xs btn-ghost rounded-md shrink-0"
                phx-click="load_task_archive_agent_result"
                phx-value-task-id={@task_id}
                phx-value-agent-id={@agent_id}
              >
                <.icon name="hero-arrow-path" class="size-3.5 mr-1" /> {gettext("Retry")}
              </button>
            </div>
          <% :not_loaded -> %>
            <div>
              <button
                class="btn btn-xs btn-ghost rounded-md"
                phx-click="load_task_archive_agent_result"
                phx-value-task-id={@task_id}
                phx-value-agent-id={@agent_id}
              >
                <.icon name="hero-document-magnifying-glass" class="size-3.5 mr-1" />
                {gettext("Show result")}
              </button>
            </div>
        <% end %>

        <!-- Commits -->
        <div class="flex flex-wrap gap-x-6 gap-y-1">
          <%= if ArchiveHelpers.agent_key(@agent, :base_commit) not in [nil, ""] do %>
            <div>
              <%!-- zh_CN: Commit → "提交" --%><span class="text-xs text-base-content/60">{gettext(
                "Start Commit"
              )}: </span>
              <span class="text-xs font-mono">{ArchiveHelpers.agent_key(@agent, :base_commit)}</span>
            </div>
          <% end %>
          <%= if ArchiveHelpers.agent_key(@agent, :final_commit) not in [nil, ""] do %>
            <div>
              <%!-- zh_CN: Commit → "提交" --%><span class="text-xs text-base-content/60">{gettext(
                "End Commit"
              )}: </span>
              <span class="text-xs font-mono">{ArchiveHelpers.agent_key(@agent, :final_commit)}</span>
            </div>
          <% end %>
        </div>

        <!-- Archive refs -->
        <div class="flex flex-wrap gap-x-6 gap-y-1">
          <%= if ArchiveHelpers.agent_key(@agent, :archive_ref_start) not in [nil, ""] do %>
            <div>
              <span class="text-xs text-base-content/60">{gettext("Archive Start Ref")}: </span>
              <span class="text-xs font-mono">{ArchiveHelpers.agent_key(
                @agent,
                :archive_ref_start
              )}</span>
            </div>
          <% end %>
          <%= if ArchiveHelpers.agent_key(@agent, :archive_ref_final) not in [nil, ""] do %>
            <div>
              <span class="text-xs text-base-content/60">{gettext("Archive Final Ref")}: </span>
              <span class="text-xs font-mono">{ArchiveHelpers.agent_key(
                @agent,
                :archive_ref_final
              )}</span>
            </div>
          <% end %>
        </div>

        <%= if ArchiveHelpers.agent_key(@agent, :branch_name) not in [nil, ""] do %>
          <div>
            <%!-- zh_CN: Branch → "分支" --%><span class="text-xs text-base-content/60">{gettext(
              "Branch"
            )}: </span>
            <span class="text-xs font-mono">{ArchiveHelpers.agent_key(@agent, :branch_name)}</span>
          </div>
        <% end %>

        <!-- Token usage -->
        <%= if usage = usage_map(ArchiveHelpers.agent_key(@agent, :usage)) do %>
          <div class="grid grid-cols-2 sm:grid-cols-4 gap-2 pt-2 border-t border-base-200">
            <div>
              <%!-- zh_CN: Token → "词元" --%>
              <div class="text-xs text-base-content/60">{gettext("Input Tokens")}</div>
              <div class="text-sm font-semibold">
                {format_number(usage[:input_tokens] || 0)}
              </div>
            </div>
            <div>
              <%!-- zh_CN: Token → "词元" --%>
              <div class="text-xs text-base-content/60">{gettext("Output Tokens")}</div>
              <div class="text-sm font-semibold">
                {format_number(usage[:output_tokens] || 0)}
              </div>
            </div>
            <div>
              <%!-- zh_CN: Token → "词元" --%>
              <div class="text-xs text-base-content/60">{gettext("Total Tokens")}</div>
              <div class="text-sm font-semibold">
                {format_number(usage[:total_tokens] || 0)}
              </div>
            </div>
            <div>
              <div class="text-xs text-base-content/60">{gettext("Cost")}</div>
              <div class="text-sm font-semibold">
                ${format_cost(usage[:total_cost] || 0)}
              </div>
            </div>
          </div>
          <.cost_estimate_notice />
        <% end %>

        <!-- Timestamps -->
        <%= if ArchiveHelpers.agent_key(@agent, :started_at) ||
              ArchiveHelpers.agent_key(@agent, :completed_at) do %>
          <div class="flex flex-wrap gap-x-6 gap-y-1 pt-2 border-t border-base-200">
            <%= if ArchiveHelpers.agent_key(@agent, :started_at) do %>
              <div>
                <span class="text-xs text-base-content/60">{gettext("Started")}: </span>
                <span class="text-xs">{format_datetime(ArchiveHelpers.agent_key(@agent, :started_at))}</span>
              </div>
            <% end %>
            <%= if ArchiveHelpers.agent_key(@agent, :completed_at) do %>
              <div>
                <span class="text-xs text-base-content/60">{gettext("Completed")}: </span>
                <span class="text-xs">{format_datetime(
                  ArchiveHelpers.agent_key(@agent, :completed_at)
                )}</span>
              </div>
            <% end %>
          </div>
        <% end %>
      </div>

      <%= if @children != [] do %>
        <div class="pl-5 border-l-2 border-base-200 ml-4 space-y-3 mb-3">
          <%= for child <- @children do %>
            <.archive_tree_node
              agent={child.agent}
              children={child.children}
              agent_results={@agent_results}
              task_id={@task_id}
            />
          <% end %>
        </div>
      <% end %>
    </div>
    """
  end

  # Usage tiles read a MAP only: a legacy/garbage non-map `usage` renders no
  # tiles instead of raising on `usage[:input_tokens]`.
  defp usage_map(%{} = usage), do: usage
  defp usage_map(_usage), do: nil

  # What the Result slot of one archived agent renders:
  #
  #   * `{:loaded, preview}` — the entry CARRIES a `"result"` key (present, even
  #     when nil/""), so the value is previewed exactly as before;
  #   * `:loading` / `{:error, reason}` — a per-agent fetch is in flight or
  #     failed (the retry fires the same event);
  #   * `:not_loaded` — a paged entry with no result yet: render the explicit
  #     "Show result" button. NEVER auto-fetch on render.
  defp result_view(agent, agent_results, agent_id) do
    cond do
      ArchiveHelpers.result_loaded?(agent) ->
        {:loaded, blob_preview(ArchiveHelpers.agent_key(agent, :result), @result_preview_bytes)}

      true ->
        cached_result_view(agent_results, agent_id)
    end
  end

  defp cached_result_view(agent_results, agent_id) do
    with true <- is_map(agent_results) and is_binary(agent_id),
         %{state: state} = cached <- Map.get(agent_results, agent_id) do
      case {state, cached} do
        {:ok, %{entry: entry}} when is_map(entry) ->
          {:loaded, blob_preview(ArchiveHelpers.agent_key(entry, :result), @result_preview_bytes)}

        # Fetched, but the store had no entry for this agent: an empty Result
        # block would be misleading, so surface it as the retry-able error.
        {:ok, _other} ->
          {:error, :not_found}

        {:loading, _other} ->
          :loading

        {:error, _other} ->
          {:error, Map.get(cached, :error)}
      end
    else
      _ -> :not_loaded
    end
  end
end
