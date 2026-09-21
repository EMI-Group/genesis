defmodule EvoDashWeb.AgentsComponents.CommitGraphView do
  @moduledoc """
  TEMPORAL (git commit history) view for the Agents page left panel.

  `commit_graph_view/1` renders fully-prepared display data (built by the pure
  `EvoDashWeb.AgentsLive.CommitGraph` module) grouped by repository, with ONE
  LANE PER AGENT. Because lanes are ordered depth-first with each child's lane
  indented under its parent and connected by an edge, the recursive
  agent-spawns-agent structure is visible at a glance.

  The component does NO data assembly, NO I/O and never touches the socket: it
  is purely presentational and fires the EXISTING `select_agent` event. The
  frozen DOM markers (`#commit-graph`, `#commit-graph-body-<node_key>`,
  `#commit-graph-repo-*`, `#commit-lane-*`, `#commit-lane-commits-*`,
  `#commit-node-*`, `#commit-agent-chip-*` and
  `data-commit-graph-anim="lane|node|edge"`) are the contract consumed by the
  client-side `CommitGraph` hook / CSS animation, which live in the assets
  subtree. Every element carries a stable, unique DOM id, so LiveView's
  patcher (morphdom) reuses existing nodes by id and inserts only genuinely
  new ones — incremental patching without any `phx-update` mode.
  """

  # zh_CN glossary used in this module:
  #   Commit history → "提交历史", Repository → "仓库",
  #   Loading → "加载中", No commit history yet → "暂无提交历史"

  use EvoDashWeb, :html
  use Gettext, backend: EvoDashWeb.Gettext

  # ---------------------------------------------------------------------------
  # commit_graph_view/1
  # ---------------------------------------------------------------------------

  attr(:repos, :list, required: true)
  attr(:selected_id, :any, default: nil)
  attr(:loading, :boolean, default: false)
  attr(:error, :any, default: nil)
  attr(:node_key, :string, default: "local")

  def commit_graph_view(assigns) do
    ~H"""
    <div id="commit-graph" phx-hook="CommitGraph">
      <%!-- Node-scoped wrapper: a node switch changes this id, so LiveView
           replaces the previous node's graph subtree entirely. --%>
      <div id={"commit-graph-body-" <> @node_key} class="space-y-4">
        <%= case view_state(@repos, @loading, @error) do %>
          <% :loading -> %>
            <.loading_state />
          <% :empty -> %>
            <.empty_state />
          <% :error -> %>
            <.error_state />
          <% :repos -> %>
            <%= if @error != nil do %>
              <.stale_warning />
            <% end %>
            <.repo_section :for={repo <- @repos} repo={repo} selected_id={@selected_id} />
        <% end %>
      </div>
    </div>
    """
  end

  defp view_state([], true, _error), do: :loading
  defp view_state([], false, nil), do: :empty
  defp view_state([], false, _error), do: :error
  defp view_state(_repos, _loading, _error), do: :repos

  # ---------------------------------------------------------------------------
  # States — loading / empty / error mirror the agent tree's states.
  # ---------------------------------------------------------------------------

  defp loading_state(assigns) do
    ~H"""
    <div class="text-center py-16 bg-base-200/40 rounded-xl">
      <.icon name="hero-arrow-path" class="size-20 mx-auto mb-4 text-base-content/40 animate-spin" />
      <%!-- 加载中提示：提交历史从当前节点异步拉取时的占位加载态 --%>
      <p class="text-lg text-base-content">{gettext("Loading commit history…")}</p>
    </div>
    """
  end

  defp empty_state(assigns) do
    ~H"""
    <div class="text-center py-16">
      <.icon name="hero-server" class="size-20 mx-auto mb-4 text-base-content/40 animate-float" />
      <%!-- 空态：当前节点还没有任何可展示的智能体提交记录 --%>
      <p class="text-lg text-base-content">{gettext("No commit history yet.")}</p>
      <p class="text-sm mt-2 text-base-content/60">
        {gettext("Start a task from the dashboard to see the commit graph here.")}
      </p>
    </div>
    """
  end

  defp error_state(assigns) do
    ~H"""
    <div
      id="commit-graph-error"
      class="flex items-center gap-2 rounded-lg border border-error/20 bg-error/10 px-3 py-2 text-sm text-error"
    >
      <.icon name="hero-exclamation-triangle" class="size-4 shrink-0" />
      <%!-- 错误提示：拉取提交历史失败，且没有任何已缓存的数据可展示 --%>
      <span class="min-w-0">{gettext("Could not load commit history.")}</span>
    </div>
    """
  end

  defp stale_warning(assigns) do
    ~H"""
    <div
      id="commit-graph-stale-warning"
      class="flex items-center gap-2 rounded-lg border border-warning/20 bg-warning/10 px-3 py-1.5 text-xs text-warning"
    >
      <.icon name="hero-exclamation-triangle" class="size-3.5 shrink-0" />
      <%!-- 数据可能已过期：刷新失败，展示上一次成功获取的提交图 --%>
      <span class="min-w-0">{gettext("Showing the last loaded commit graph — refresh failed.")}</span>
    </div>
    """
  end

  # ---------------------------------------------------------------------------
  # repo_section/1 — one repository block (header + its ordered lanes).
  # ---------------------------------------------------------------------------

  attr(:repo, :map, required: true)
  attr(:selected_id, :any, default: nil)

  defp repo_section(assigns) do
    ~H"""
    <div id={"commit-graph-repo-" <> @repo.repo_dom_id} class="space-y-1">
      <div class="flex items-center gap-2 mb-2 pb-1 border-b border-base-300">
        <.icon
          name="hero-server-stack"
          class="size-5 text-primary-content p-1.5 rounded-lg bg-primary"
        />
        <span class="font-bold text-base text-base-content truncate min-w-0" title={@repo.repo_name}>
          {@repo.repo_name}
        </span>
      </div>
      <.lane :for={lane <- @repo.lanes} repo={@repo} lane={lane} selected_id={@selected_id} />
    </div>
    """
  end

  # ---------------------------------------------------------------------------
  # lane/1 — one agent's commit lane: rail, parent connector, commits, chip.
  # ---------------------------------------------------------------------------

  attr(:repo, :map, required: true)
  attr(:lane, :map, required: true)
  attr(:selected_id, :any, default: nil)

  defp lane(assigns) do
    ~H"""
    <div
      id={"commit-lane-" <> @repo.repo_dom_id <> "-" <> to_string(@lane.agent_id)}
      data-commit-graph-anim="lane"
      class="relative"
      style={"margin-left: #{lane_indent(@lane)}"}
    >
      <%!-- Vertical lane rail. Each segment between consecutive commits is also
           covered by an explicit edge element below (frozen animation marker). --%>
      <div
        data-commit-graph-anim="edge"
        aria-hidden="true"
        class="pointer-events-none absolute left-1.5 top-1 bottom-1 -translate-x-1/2 w-px bg-base-content/20"
      >
      </div>

      <%!-- Parent → child connector: an elbow from the parent lane's rail into
           this lane's start, making the recursive spawn structure obvious. --%>
      <%= if @lane.connects? do %>
        <div
          data-commit-graph-anim="edge"
          aria-hidden="true"
          class="pointer-events-none absolute -left-3 top-1.5 h-3 w-[18px] rounded-bl-md border-l-2 border-b-2 border-primary/40"
        >
        </div>
      <% end %>

      <%!-- Keyed commits container: every child carries a stable, unique id
           (`commit-node-*` / `commit-edge-*`), so morphdom matches and REUSES
           existing elements by id and only inserts genuinely new ones.
           Incremental patching therefore relies on the unique ids, not on any
           `phx-update` mode — existing nodes are never recreated, so the
           `CommitGraph` hook only animates the newly inserted ones. --%>
      <div id={"commit-lane-commits-" <> @repo.repo_dom_id <> "-" <> to_string(@lane.agent_id)}>
        <%= for {commit, index} <- Enum.with_index(@lane.commits) do %>
          <%= if index > 0 do %>
            <div
              id={"commit-edge-" <> @repo.repo_dom_id <> "-" <> commit.sha}
              data-commit-graph-anim="edge"
              aria-hidden="true"
              class="pointer-events-none relative h-3"
            >
              <span class="absolute left-1.5 top-0 bottom-0 -translate-x-1/2 w-px bg-base-content/20"></span>
            </div>
          <% end %>
          <.commit_row repo={@repo} lane={@lane} commit={commit} />
        <% end %>
      </div>

      <.agent_chip lane={@lane} selected_id={@selected_id} />
    </div>
    """
  end

  # ---------------------------------------------------------------------------
  # commit_row/1 — one commit node on the lane rail.
  # ---------------------------------------------------------------------------

  attr(:repo, :map, required: true)
  attr(:lane, :map, required: true)
  attr(:commit, :map, required: true)

  defp commit_row(assigns) do
    ~H"""
    <div
      id={"commit-node-" <> @repo.repo_dom_id <> "-" <> @commit.sha}
      data-commit-graph-anim="node"
      class="group relative pl-6 pr-1 py-1 rounded-lg cursor-pointer transition-colors hover:bg-base-200/50"
      phx-click="select_agent"
      phx-value-id={@lane.agent_id}
    >
      <span
        aria-hidden="true"
        class="pointer-events-none absolute left-1.5 top-2 -translate-x-1/2 size-2.5 rounded-full border-2 border-primary bg-base-100"
      ></span>

      <div class="flex items-center gap-2 min-w-0">
        <code class="shrink-0 font-mono text-xs text-base-content/80">{@commit.short_sha}</code>
        <span class="truncate text-sm text-base-content" title={@commit.message}>
          {first_line(@commit.message)}
        </span>
        <span
          :for={ref <- ref_list(@commit.refs)}
          class="badge badge-outline badge-xs shrink-0 font-mono border-base-content/25 text-base-content/80"
        >
          {ref}
        </span>
      </div>

      <%= if meta_line(@commit) != "" do %>
        <div class="mt-0.5 truncate text-xs text-base-content/60">{meta_line(@commit)}</div>
      <% end %>
    </div>
    """
  end

  # ---------------------------------------------------------------------------
  # agent_chip/1 — the lane tip; reuses the tree's agent-card status styling
  # helpers (never re-implement the mappings).
  # ---------------------------------------------------------------------------

  attr(:lane, :map, required: true)
  attr(:selected_id, :any, default: nil)

  defp agent_chip(assigns) do
    ~H"""
    <div
      id={"commit-agent-chip-" <> to_string(@lane.agent_id)}
      data-commit-graph-anim="node"
      class={[
        "relative ml-6 mt-1 flex flex-col gap-1 p-2 rounded-xl border shadow-sm transition-[background-color,border-color,color,box-shadow] duration-300 motion-reduce:transition-none cursor-pointer hover:shadow-lg hover:shadow-primary/20",
        agent_status_bg(@lane.status),
        agent_status_border(@lane.status),
        @selected_id == @lane.agent_id &&
          "ring-2 ring-primary-standalone ring-offset-1 ring-offset-base-100",
        @selected_id != @lane.agent_id && "hover:ring-1 hover:ring-primary-standalone/40"
      ]}
      phx-click="select_agent"
      phx-value-id={@lane.agent_id}
    >
      <div class="flex items-center gap-2 justify-between min-w-0">
        <div class="flex items-center gap-1.5 min-w-0">
          <.icon
            name={agent_status_icon(@lane.status)}
            class={"size-4 shrink-0 #{agent_status_color(@lane.status)}"}
          />
          <span class="shrink-0 font-bold text-sm">{chip_label(@lane)}</span>
          <span class="truncate text-xs text-base-content/80">
            {format_module_name(@lane.agent_module)}
          </span>
        </div>
        <span class={[
          "shrink-0 text-[10px] px-1.5 py-0.5 rounded uppercase font-bold",
          agent_status_color(@lane.status),
          agent_status_bg(@lane.status)
        ]}>
          {agent_status_label(@lane.status)}
        </span>
      </div>

      <%= if model_id(@lane) do %>
        <div
          class="truncate font-mono text-[10px] text-base-content/70"
          title={model_id(@lane)}
        >
          {model_id(@lane)}
        </div>
      <% end %>
    </div>
    """
  end

  # ---------------------------------------------------------------------------
  # Pure helpers — all TOTAL against missing / malformed data.
  # ---------------------------------------------------------------------------

  defp lane_indent(lane) do
    depth = Map.get(lane, :depth)

    if is_integer(depth) and depth > 0 do
      "#{depth * 0.75}rem"
    else
      "0rem"
    end
  end

  defp chip_label(lane) do
    id = Map.get(lane, :task_local_id) || Map.get(lane, :agent_id)
    "T" <> to_string(id)
  end

  defp model_id(lane) do
    case Map.get(lane, :model_id) do
      model when is_binary(model) and model != "" -> model
      _ -> nil
    end
  end

  defp first_line(message) when is_binary(message) do
    message |> String.split("\n", parts: 2) |> hd()
  end

  defp first_line(_message), do: ""

  defp ref_list(refs) when is_list(refs), do: refs |> Enum.flat_map(&ref_name/1) |> Enum.uniq()
  defp ref_list(_refs), do: []

  defp ref_name(ref) when is_binary(ref) and ref != "", do: [ref]

  defp ref_name(%{} = ref) do
    case Map.get(ref, :name) || Map.get(ref, "name") do
      name when is_binary(name) and name != "" -> [name]
      _ -> []
    end
  end

  defp ref_name(ref) when is_atom(ref) and not is_nil(ref), do: [Atom.to_string(ref)]
  defp ref_name(_ref), do: []

  defp meta_line(commit) do
    [commit_author(commit), commit_date(commit)]
    |> Enum.reject(&(&1 in [nil, ""]))
    |> Enum.join(" · ")
  end

  defp commit_author(commit) do
    case Map.get(commit, :author_name) do
      name when is_binary(name) and name != "" -> name
      _ -> nil
    end
  end

  defp commit_date(commit) do
    case Map.get(commit, :date) do
      date when is_binary(date) -> format_datetime(date)
      %DateTime{} = date -> format_datetime(date)
      %NaiveDateTime{} = date -> format_datetime(date)
      _ -> nil
    end
  end
end
