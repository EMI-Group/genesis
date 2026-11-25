defmodule EvoDashWeb.AgentsLive.TreePanel do
  @moduledoc """
  The Agents page LEFT column: the tree panel card (left-view switch, loading /
  empty states, the spatial agent tree, the temporal commit-history view) plus
  the status / commit-graph legend chips under it.

  A pure function component over explicit attrs — it holds no state and calls
  no state transition. `EvoDashWeb.AgentsLive.Inspector` keeps selection and
  stream state; the page owns `:left_view` and the commit-graph data.

  DOM contract owned here: `#agents-load-error` / `#agents-load-retry` (the
  page-load failure banner), `#left-view-tree` / `#left-view-commits` (the
  segmented view switch), the VIEW-KEYED card body
  (`#agents-tree-body-tree` / `#agents-tree-body-commits`) — whose
  `.agents-tree-body-commits` class is the mode hook of the commit-graph
  fill-the-panel CSS flex chain — and the legend chip ids
  (`#agents-legend-*`) that the `LegendTooltip` hook targets.
  """
  use EvoDashWeb, :html

  attr(:agents_error, :any, default: nil)
  attr(:agents_loading, :boolean, required: true)
  attr(:left_view, :atom, required: true)
  attr(:agents, :list, required: true)
  attr(:repo_trees, :list, required: true)
  attr(:selected_agent_id, :any, default: nil)
  attr(:new_agent_ids, :any, default: nil)
  attr(:changed_status_ids, :any, default: nil)
  attr(:commit_graph, :list, required: true)
  attr(:commit_graph_loading, :boolean, required: true)
  attr(:commit_graph_error, :any, default: nil)
  attr(:current_node_id, :any, default: nil)
  attr(:scoped_task_state, :atom, default: nil)

  def tree_panel(assigns) do
    ~H"""
    <!-- Left Column: Tree + Legend -->
    <div class="agents-left-col">
      <%!-- Page-load failure: the last good tree stays rendered, plus this
      retry-able inline banner (no polling, no auto-retry timer). --%>
      <%= if @agents_error do %>
        <div
          id="agents-load-error"
          class="flex shrink-0 flex-wrap items-center gap-3 rounded-lg border border-error/30 bg-error/5 px-4 py-3"
        >
          <.icon name="hero-exclamation-triangle" class="size-5 shrink-0 text-error" />
          <div class="min-w-0 flex-1">
            <p class="text-sm font-medium text-error">
              {gettext("Failed to load agents from this node.")}
            </p>
            <p class="text-xs text-base-content/70 font-mono break-all">
              {inspect(@agents_error)}
            </p>
          </div>
          <button
            id="agents-load-retry"
            type="button"
            class="btn btn-sm btn-outline shrink-0"
            phx-click="retry_agents_load"
            disabled={@agents_loading}
          >
            {gettext("Retry")}
          </button>
        </div>
      <% end %>
      <!-- Agent Tree View -->
      <div class="agents-tree-panel card bg-base-100 border border-base-300 rounded-lg">
        <%!-- Mode hook for the CSS flex chain: in commits mode the card body must
        fill the panel so the commit list is the ONE bounded scroller
        (`#cg-scroll`, whose `position: sticky` lane header resolves against
        it). The tree view keeps the plain body class. --%>
        <%!-- The body id is VIEW-KEYED (`agents-tree-body-tree` / `-commits`)
        so switching views inserts a fresh element and the shared
        reduced-motion-safe `wizard-step-enter` entrance replays — the
        switch animates without JS and without a new keyframe. --%>
        <div
          id={"agents-tree-body-#{@left_view}"}
          class={[
            "card-body p-4 wizard-step-enter",
            @left_view == :commits && "agents-tree-body-commits"
          ]}
        >
          <div class="flex flex-wrap items-center gap-2 mb-3">
            <.icon name="hero-squares-2x2" class="size-5 shrink-0" />
            <div class="inline-flex items-center gap-0.5 p-0.5 rounded-lg bg-base-200/60 border border-base-300">
              <button
                id="left-view-tree"
                type="button"
                class={[
                  "inline-flex min-h-[var(--control-h-sm)] items-center px-3 py-1 text-xs font-medium rounded-md transition-colors",
                  "pointer-coarse:min-h-[var(--touch-target)]",
                  @left_view == :tree && "bg-base-100 text-base-content shadow-sm",
                  @left_view != :tree && "text-base-content/70 hover:text-base-content"
                ]}
                phx-click="switch_left_view"
                phx-value-view="tree"
              >
                {gettext("Agent Tree")}
              </button>
              <button
                id="left-view-commits"
                type="button"
                class={[
                  "inline-flex min-h-[var(--control-h-sm)] items-center px-3 py-1 text-xs font-medium rounded-md transition-colors",
                  "pointer-coarse:min-h-[var(--touch-target)]",
                  @left_view == :commits && "bg-base-100 text-base-content shadow-sm",
                  @left_view != :commits && "text-base-content/70 hover:text-base-content"
                ]}
                phx-click="switch_left_view"
                phx-value-view="commits"
              >
                <%!-- zh_CN: 提交历史 —— 时间维度（git 提交图）视图 --%>
                {gettext("Commit History")}
              </button>
            </div>
          </div>

          <p
            :if={@scoped_task_state == :ready and @agents_loading}
            class="text-sm text-base-content/70"
            role="status"
          >
            {gettext("Refreshing task agents…")}
          </p>
          <%= cond do %>
            <% @scoped_task_state == :loading -> %>
              <p id="scoped-agents-loading" class="text-sm text-base-content/70" role="status">
                {gettext("Loading task agents…")}
              </p>
            <% @scoped_task_state == :missing -> %>
              <p id="scoped-agents-missing" class="text-sm text-base-content/70">
                {gettext("Task not found on this node.")}
              </p>
            <% @scoped_task_state == :unavailable -> %>
              <p class="text-sm text-base-content/70">
                {gettext("The selected node is unavailable.")}
              </p>
            <% @scoped_task_state == :error -> %>
              <%!-- The retryable error above owns the first-load failure. --%>
            <% true -> %>
              <%= if @left_view == :tree do %>
                <%= if @agents_loading and is_nil(@scoped_task_state) do %>
                  <div class="text-center py-16 bg-base-200/40 rounded-xl">
                    <.icon
                      name="hero-arrow-path"
                      class="size-8 mx-auto mb-4 text-base-content/60 animate-spin"
                    />
                    <%!-- 加载中提示：智能体列表从当前节点异步拉取时的占位加载态 --%>
                    <p class="text-sm text-base-content/70">{gettext("Loading agents…")}</p>
                  </div>
                <% else %>
                  <%= if @agents == [] do %>
                    <div class="text-center py-16">
                      <.icon
                        name="hero-server"
                        class="size-10 mx-auto mb-4 text-base-content/40"
                      />
                      <p
                        :if={@scoped_task_state == :ready}
                        id="scoped-agents-empty"
                        class="text-base text-base-content"
                      >
                        {gettext("No live agents for this task.")}
                      </p>
                      <p :if={is_nil(@scoped_task_state)} class="text-lg text-base-content">
                        {gettext("No agents currently registered")}
                      </p>
                      <p :if={is_nil(@scoped_task_state)} class="text-sm mt-2 text-base-content/60">
                        {gettext("Start a task from the dashboard to see agents here.")}
                      </p>
                    </div>
                  <% else %>
                    <div class="space-y-4">
                      <%= for {repo_name, tree_nodes} <- @repo_trees do %>
                        <div>
                          <!-- Repo Header -->
                          <div class="flex items-center gap-2 mb-2 pb-1 border-b border-base-300">
                            <.icon
                              name="hero-server-stack"
                              class="size-5 text-primary-content p-1.5 rounded-lg bg-primary"
                            />
                            <span class="min-w-0 break-all font-semibold text-sm text-base-content">{repo_name}</span>
                            <span class="text-xs text-base-content/70">({length(tree_nodes)} {gettext(
                              "directories"
                            )})</span>
                          </div>
                          <div class="space-y-4 font-mono text-sm">
                            <EvoDashWeb.AgentsComponents.path_tree
                              nodes={tree_nodes}
                              depth={0}
                              selected_id={@selected_agent_id}
                              new_agent_ids={@new_agent_ids}
                              changed_status_ids={@changed_status_ids}
                            />
                          </div>
                        </div>
                      <% end %>
                    </div>
                  <% end %>
                <% end %>
              <% else %>
                <EvoDashWeb.AgentsComponents.CommitGraphView.commit_graph_view
                  repos={@commit_graph}
                  selected_id={@selected_agent_id}
                  loading={@commit_graph_loading}
                  error={@commit_graph_error}
                  node_key={@current_node_id || "local"}
                />
              <% end %>
          <% end %>
        </div>

        <!-- Legend — compact chip cluster, bottom-right of the tree box -->
        <div class="agents-legend">
          <%= if @left_view == :tree do %>
            <span class="agents-legend-title">{gettext("Status Legend")}</span>
            <div
              id="agents-legend-pending"
              class="flex items-center gap-2"
              data-tip={
                gettext(
                  "Agent is queued, waiting to be scheduled. May be limited by LLM or tool concurrency. Consider increasing concurrency in Settings."
                )
              }
              phx-hook="LegendTooltip"
            >
              <span class="w-2.5 h-2.5 rounded-full bg-base-content/40"></span>
              <span>{gettext("Pending")}</span>
            </div>
            <div
              id="agents-legend-running"
              class="flex items-center gap-2"
              data-tip={gettext("Agent is actively executing its assigned task.")}
              phx-hook="LegendTooltip"
            >
              <span class="w-2.5 h-2.5 rounded-full bg-success shadow-sm shadow-success/50"></span>
              <span>{gettext("Running")}</span>
            </div>
            <div
              id="agents-legend-waiting"
              class="flex items-center gap-2"
              data-tip={gettext("Agent is waiting for subagents to finish. Nothing to do but wait.")}
              phx-hook="LegendTooltip"
            >
              <span class="w-2.5 h-2.5 rounded-full bg-warning shadow-sm shadow-warning/50"></span>
              <span>{gettext("Waiting")}</span>
            </div>
          <% else %>
            <%!-- zh_CN: 提交图例 —— 时间维度视图（以提交为中心的纵向泳道图）的图例 --%>
            <span class="agents-legend-title">{gettext("Commit Graph Legend")}</span>
            <%!-- zh_CN: 提交 —— 每个提交画一个圆点；被多个智能体共享的同一提交只是图上「一个」圆点 --%>
            <div
              id="agents-legend-commit"
              class="flex items-center gap-2"
              data-tip={
                gettext(
                  "One circular dot per commit. Commits shared by several agents remain a single dot. Hover a row to see its message."
                )
              }
              phx-hook="LegendTooltip"
            >
              <span class="w-2.5 h-2.5 rounded-full bg-base-content/40"></span>
              <span>{gettext("Commit")}</span>
            </div>
            <%!-- zh_CN: 智能体泳道 —— 每个智能体占「一条」纵向泳道（一列）；父智能体在左、子智能体在右，顶部标签标明每条泳道的主人，泳道颜色按递归深度取色 --%>
            <div
              id="agents-legend-path"
              class="flex items-center gap-2"
              data-tip={
                gettext(
                  "Each agent owns exactly one vertical lane. Parent lanes sit left, subagent lanes right; the sticky header chips name each lane, and the lane is colored by the agent's recursion depth."
                )
              }
              phx-hook="LegendTooltip"
            >
              <%!-- Legend swatch mirrors the depth→hue formula in
                   AgentsLive.CommitGraph (depth 0 lands on this blue-violet);
                   the literal is acceptable in a static legend chip. --%>
              <span class="w-4 h-0.5 rounded-full" style="background-color: #7c38dc"></span>
              <span>{gettext("Agent lane")}</span>
            </div>
            <%!-- zh_CN: 智能体状态 —— 智能体泳道末端的最新提交圆点按该智能体的状态着色（与左侧智能体树同一色系：绿＝运行、琥珀＝等待、灰＝排队） --%>
            <div
              id="agents-legend-ring"
              class="flex items-center gap-2"
              data-tip={
                gettext(
                  "An agent's tip dot is colored by its status — same palette as the agent tree."
                )
              }
              phx-hook="LegendTooltip"
            >
              <span class="w-2.5 h-2.5 rounded-full bg-success"></span>
              <span>{gettext("Agent status")}</span>
            </div>
            <%!-- zh_CN: 派生边 —— 子智能体从父泳道的分叉点出发，虚线画到子泳道自己的首个提交 --%>
            <div
              id="agents-legend-spawn"
              class="flex items-center gap-2"
              data-tip={
                gettext(
                  "A dashed branch-out from the fork commit on the parent's lane into the child's own lane, where the child's first commit sits."
                )
              }
              phx-hook="LegendTooltip"
            >
              <span class="w-4 h-0 border-t-2 border-dashed border-base-content/60"></span>
              <span>{gettext("Spawn edge")}</span>
            </div>
            <%!-- zh_CN: 合回边 —— 虚线从子泳道的最新提交回到父泳道：真实合并、快进（父分支被直接推进到子提交）与零提交的子智能体都画成这类边 --%>
            <div
              id="agents-legend-merge"
              class="flex items-center gap-2"
              data-tip={
                gettext(
                  "A dashed return from the child's last commit into the parent's lane — drawn for real merges, fast-forwards (the parent silently advanced to the child's tip) and children that committed nothing."
                )
              }
              phx-hook="LegendTooltip"
            >
              <span class="w-4 h-0 border-t-2 border-dashed border-base-content/60"></span>
              <span>{gettext("Merge-back edge")}</span>
            </div>
            <%!-- zh_CN: 任务前泳道 —— 最左侧的中性泳道，放置任务开始前不属于任何智能体的提交 --%>
            <div
              id="agents-legend-pretask"
              class="flex items-center gap-2"
              data-tip={
                gettext(
                  "The neutral leftmost lane holding commits no agent owns — they predate the task's agents."
                )
              }
              phx-hook="LegendTooltip"
            >
              <span class="w-2.5 h-2.5 rounded-full bg-base-content/30 border border-base-content/40"></span>
              <span>{gettext("Pre-task lane")}</span>
            </div>
          <% end %>
        </div>
      </div>
    </div>
    """
  end
end
