defmodule EvoDashWeb.SimpleLive.Reviews do
  @moduledoc """
  Simple-mode pending-review list (`/tree/review`).

  The simple review flow is standalone: the home page "审阅 →" button lands
  here, and the user picks any pending review — not just the most recent one.
  Each entry links to the minimal review page (`/tree/review/:task_id`).
  """

  use EvoDashWeb, :live_view

  alias EvoGit.TaskRegistry

  @doc """
  Completed, branch-backed tasks still awaiting review, most recent first.
  """
  def pending do
    TaskRegistry.list_tasks()
    |> Enum.filter(fn t ->
      t.status == :completed and t.branch_name not in [nil, ""] and
        t.review_status in [nil, :open]
    end)
    |> Enum.sort_by(& &1.finished_at, {:desc, DateTime})
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.simple flash={@flash}>
      <div class="flex-1 flex flex-col w-full max-w-2xl mx-auto px-4 py-10">
        <div class="flex items-center gap-3 mb-6">
          <.link
            id="reviews-back"
            navigate={~p"/"}
            class="flex items-center gap-1 text-xs text-slate-500 hover:text-slate-800 transition-colors shrink-0"
          >
            <.icon name="hero-arrow-left" class="size-4" />
            {gettext("Home")}
          </.link>
          <h2 class="text-lg font-bold text-slate-900">{gettext("Pending Reviews")}</h2>
          <span class="text-xs text-slate-400">{@reviews |> length()}</span>
        </div>

        <%= if @reviews == [] do %>
          <div class="rounded-2xl border border-slate-200 bg-white p-10 text-center">
            <.icon name="hero-inbox" class="size-10 text-slate-300 mx-auto mb-3" />
            <p class="text-sm text-slate-500">{gettext("No pending reviews.")}</p>
            <.link navigate={~p"/"} class="text-sm text-slate-500 underline mt-2 inline-block">
              {gettext("Start a task")}
            </.link>
          </div>
        <% else %>
          <div id="review-list" class="flex flex-col gap-2">
            <.link
              :for={task <- @reviews}
              id={"review-item-#{task.id}"}
              navigate={~p"/tree/review/#{task.id}"}
              class="rounded-2xl border border-slate-200 bg-white px-4 py-3 hover:border-slate-400 transition-colors"
            >
              <div class="flex items-center gap-2 min-w-0">
                <span class="text-sm font-medium text-slate-900 truncate">
                  {task_title(task)}
                </span>
                <span class="text-[11px] text-slate-400 shrink-0 ml-auto">
                  {relative_time(task.finished_at)}
                </span>
              </div>
              <div class="flex items-center gap-2 mt-1 text-[11px] text-slate-400">
                <.icon name="hero-folder" class="size-3.5 shrink-0" />
                <span class="truncate">{project_name(task)}</span>
                <span :if={task.agent_count} class="shrink-0">
                  · {ngettext("%{count} agent", "%{count} agents", task.agent_count, count: task.agent_count)}
                </span>
              </div>
            </.link>
          </div>
        <% end %>
      </div>

      <Layouts.simple_corner />
    </Layouts.simple>
    """
  end

  @impl true
  def mount(_params, _session, socket) do
    {:ok, assign(socket, :reviews, pending())}
  end

  defp task_title(task) do
    label = task.opts[:prompt] || task.opts[:objective] || task.id
    if String.length(label) > 60, do: String.slice(label, 0, 60) <> "…", else: label
  end

  defp project_name(task) do
    case task.opts[:path] do
      nil -> gettext("Unknown project")
      path -> Path.basename(path)
    end
  end
end
