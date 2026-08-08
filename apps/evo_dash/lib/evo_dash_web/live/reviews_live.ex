defmodule EvoDashWeb.ReviewsLive do
  @moduledoc """
  The dedicated review page (`/reviews`) — v3 design, see
  `docs/launchpad-frontend-spec.md`.

  Review information lives HERE, not on the home page. Two groups:

    * "Waiting for you" — `completed` + non-empty branch + `review_status`
      nil (the same set the home top-bar count reports), newest finished
      first. Row: prompt, FULL project path (mono), branch, finish time.
      Clicking a row navigates to `/review/:id`.
    * "Decided" — the 20 most recent tasks whose `review_status` is
      merged/rejected/continued/ignored. Status text only, all L3.

  Same two-pole visual language as the home page (no sidebar; the shared
  minimal top bar with the current Review tab at L1). Reloads on `"tasks"`
  PubSub broadcasts coalesce through the NodeAware 300ms trailing debounce.
  """

  use EvoDashWeb, :live_view

  alias EvoDashWeb.LiveHooks.NodeAware
  alias EvoDashWeb.PadComponents
  alias EvoGit.TaskRegistry

  @decided_limit 20

  @impl true
  def mount(_params, _session, socket) do
    if connected?(socket) do
      Phoenix.PubSub.subscribe(EvoGit.PubSub, "tasks")
    end

    {:ok, socket |> assign(page_title: gettext("Review")) |> load_reviews()}
  end

  @impl true
  def handle_params(_params, _uri, socket) do
    {:noreply, assign(socket, :current_path, ~p"/reviews")}
  end

  # ---------------------------------------------------------------------------
  # PubSub
  # ---------------------------------------------------------------------------

  @impl true
  def handle_info({:tasks_updated}, socket) do
    {:noreply, NodeAware.debounce_task_reload(socket)}
  end

  def handle_info({:task_status, _task_id, _status}, socket) do
    {:noreply, NodeAware.debounce_task_reload(socket)}
  end

  def handle_info(:node_aware_reload_tasks, socket) do
    {:noreply, socket |> load_reviews() |> NodeAware.reload_tasks()}
  end

  def handle_info({:remote_connection_status, _, _} = message, socket) do
    NodeAware.handle_connection_status(socket, message)
  end

  def handle_info({:node_selected, node_id}, socket) do
    NodeAware.handle_node_selected(socket, node_id)
  end

  # ---------------------------------------------------------------------------
  # Loading
  # ---------------------------------------------------------------------------

  defp load_reviews(socket) do
    tasks = TaskRegistry.list_tasks_summary([:completed])

    waiting =
      tasks
      |> Enum.filter(&PadComponents.awaiting_review?/1)
      |> Enum.sort_by(&finished_or_started/1, {:desc, DateTime})

    decided =
      tasks
      |> Enum.filter(&PadComponents.decided_review?/1)
      |> Enum.sort_by(&finished_or_started/1, {:desc, DateTime})
      |> Enum.take(@decided_limit)

    assign(socket,
      waiting: waiting,
      decided: decided,
      review_count: length(waiting)
    )
  end

  defp finished_or_started(task) do
    case Map.get(task, :finished_at) || Map.get(task, :started_at) do
      nil -> ~U[1970-01-01 00:00:00Z]
      datetime -> datetime
    end
  end

  # ---------------------------------------------------------------------------
  # Render helpers
  # ---------------------------------------------------------------------------

  defp row_time(task) do
    case Map.get(task, :finished_at) || Map.get(task, :started_at) do
      nil -> ""
      datetime -> relative_time(datetime)
    end
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div id="reviews-root" class="min-h-screen bg-base-100 text-base-content">
      <PadComponents.pad_top_bar current={:reviews} review_count={@review_count} />

      <main class="mx-auto w-full max-w-[760px] px-6 pt-12 pb-24">
        <%!-- Waiting for you — every row navigates to /review/:id --%>
        <section id="reviews-waiting">
          <h2 class="text-xs text-base-content/40 font-normal pb-2 border-b border-base-300">
            {gettext("Waiting for you")}
          </h2>

          <p :if={@waiting == []} class="py-6 text-xs text-base-content/30">
            {gettext("Nothing waiting.")}
          </p>

          <.link
            :for={task <- @waiting}
            navigate={~p"/review/#{Map.get(task, :id)}"}
            id={"review-row-#{Map.get(task, :id)}"}
            class="block -mx-1 px-1 py-2.5 border-b border-base-300/60 hover:bg-base-200/50 transition-colors"
          >
            <div class="flex items-baseline gap-3">
              <span class="flex-1 min-w-0 truncate text-[13px] text-base-content/40">
                {PadComponents.task_prompt(task)}
              </span>
              <span class="shrink-0 text-[11px] text-base-content/30">{row_time(task)}</span>
            </div>
            <div class="mt-0.5 flex items-baseline gap-3 font-mono text-[11px] text-base-content/30">
              <span class="min-w-0 break-all">{Map.get(task, :project_path)}</span>
              <span class="shrink-0">{PadComponents.task_branch(task)}</span>
            </div>
          </.link>
        </section>

        <%!-- Decided — the last 20 taken decisions, status text only --%>
        <section id="reviews-decided" class="mt-10">
          <h2 class="text-xs text-base-content/40 font-normal pb-2 border-b border-base-300">
            {gettext("Decided")}
          </h2>

          <p :if={@decided == []} class="py-6 text-xs text-base-content/30">
            {gettext("No decisions yet.")}
          </p>

          <div
            :for={task <- @decided}
            id={"decided-row-#{Map.get(task, :id)}"}
            class="flex items-baseline gap-3 py-2.5 border-b border-base-300/60"
          >
            <span class="flex-1 min-w-0 truncate text-[13px] text-base-content/40">
              {PadComponents.task_prompt(task)}
            </span>
            <span class="shrink-0 text-[11px] text-base-content/30">
              {to_string(Map.get(task, :review_status))}
            </span>
            <span class="shrink-0 text-[11px] text-base-content/30">{row_time(task)}</span>
          </div>
        </section>
      </main>

      <Layouts.flash_group flash={@flash} />
    </div>
    """
  end
end
