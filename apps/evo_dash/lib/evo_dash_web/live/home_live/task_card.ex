defmodule EvoDashWeb.HomeLive.TaskCard do
  @moduledoc "Task facts and explicit task actions linked to the current conversation."
  use EvoDashWeb, :html

  def cards(assigns) do
    assigns =
      assign(
        assigns,
        :action_busy,
        MapSet.member?(
          assigns[:task_action_pending] || MapSet.new(),
          EvoDashWeb.HomeLive.TaskTracking.scope(assigns)
        )
      )

    ~H"""
    <section
      :if={@tracked_tasks != [] or @task_tracking_error}
      id="assistant-task-tracking"
      class="assistant-tracked-tasks"
      aria-label={gettext("Followed tasks")}
    >
      <details id="assistant-tracked-panel" phx-hook="AssistantDisclosure">
        <summary class="assistant-tasks-summary">
          <.icon name="hero-queue-list" class="size-4" />{gettext("Followed tasks")}
          <span>{length(@tracked_tasks)}</span><.icon name="hero-chevron-down" class="size-3" />
        </summary>
        <div class="assistant-task-list">
          <p :if={@task_tracking_error} role="status" class="text-sm text-warning">
            {gettext("Task updates are temporarily unavailable. Last known state is retained.")}
          </p>
          <article
            :for={task <- @tracked_tasks}
            id={"assistant-task-" <> task.id}
            class="rounded-lg border border-base-300 p-3 text-sm space-y-2"
          >
            <div class="flex flex-wrap items-center gap-2">
              <strong class="break-all">{if task.title == "", do: task.id, else: task.title}</strong><span class="badge badge-sm">{task.status}</span>
              <.link navigate={task_url(task.id, @current_node_id)} class="link ml-auto">{gettext(
                "Task details"
              )}</.link>
            </div>
            <p :if={is_integer(task.agent_count)}>{gettext("Observed agents")}: {task.agent_count}</p>
            <p class="text-base-content/70 break-all">{task.path}</p>
            <p :if={task.updated_at} class="text-xs text-base-content/60">
              {gettext("Updated")}: {task.updated_at}
            </p>
            <p :if={task.error} role="status" class="text-warning">
              {gettext("Unable to refresh this task.")}
            </p>
            <p :if={task.has_result}>{gettext("A saved result is available in task details.")}</p>
            <.form
              :if={task.status in ["pending", "running", "finalizing", "cancelling"]}
              for={to_form(%{})}
              id={"assistant-task-message-" <> task.id}
              phx-submit="assistant_task_message"
              class="flex gap-2"
            >
              <input type="hidden" name="task_id" value={task.id} />
              <.input
                name="message"
                value=""
                aria-label={gettext("Additional task requirements")}
                placeholder={gettext("Additional task requirements")}
                required
                class="input input-sm min-w-0 flex-1"
              />
              <button disabled={@action_busy} type="submit" class="btn btn-sm">{gettext(
                "Send requirements"
              )}</button>
            </.form>
            <button
              :if={task.status in ["pending", "running"]}
              type="button"
              phx-click="assistant_task_cancel"
              phx-value-task_id={task.id}
              disabled={@action_busy}
              class="btn btn-sm btn-outline"
            >{gettext("Request task cancellation")}</button>
          </article>
        </div>
      </details>
    </section>
    """
  end

  def follow_control(assigns) do
    assigns =
      assign(assigns,
        task_choices: EvoDashWeb.HomeLive.TaskPicker.view(assigns),
        followed_ids: MapSet.new(Enum.map(assigns[:tracked_tasks] || [], & &1.id))
      )

    assigns =
      assign(
        assigns,
        :action_busy,
        MapSet.member?(
          assigns[:task_action_pending] || MapSet.new(),
          EvoDashWeb.HomeLive.TaskTracking.scope(assigns)
        )
      )

    ~H"""
    <details
      id="assistant-task-menu"
      phx-hook="AssistantDisclosure"
      class="assistant-task-control"
      phx-click-away={JS.remove_attribute("open", to: "#assistant-task-menu")}
      phx-window-keydown={
        JS.remove_attribute("open", to: "#assistant-task-menu")
        |> JS.focus(to: "#assistant-task-menu > summary")
      }
      phx-key="Escape"
    >
      <summary
        id="assistant-task-menu-trigger"
        class="assistant-context-button"
        phx-click="assistant_task_picker_open"
      >
        <.icon name="hero-queue-list" class="size-4" /><span>{gettext("Tasks")}</span>
      </summary>
      <div class="assistant-menu-panel assistant-follow-panel">
        <div class="assistant-task-picker-header">
          <p class="text-sm font-medium">{gettext("Choose a task to follow")}</p>
          <button
            type="button"
            phx-click="assistant_task_picker_open"
            disabled={@task_choices.loading}
            class="assistant-icon-button"
            aria-label={gettext("Refresh tasks")}
            title={gettext("Refresh tasks")}
          >
            <.icon name="hero-arrow-path" class="size-4" />
          </button>
        </div>
        <.form
          for={to_form(%{"query" => @task_choices.query})}
          id="assistant-task-search"
          phx-change="assistant_task_picker_search"
          phx-submit="assistant_task_picker_search"
        >
          <.input
            type="search"
            name="query"
            value={@task_choices.query}
            phx-debounce="250"
            aria-label={gettext("Search task names or projects")}
            placeholder={gettext("Search task names or projects")}
            class="assistant-path-input"
          />
        </.form>
        <div
          id="assistant-task-choices"
          class="assistant-task-choices"
          aria-busy={to_string(@task_choices.loading)}
        >
          <p
            :if={@task_choices.loading && @task_choices.rows == []}
            role="status"
            class="assistant-task-picker-notice"
          >
            {gettext("Loading tasks…")}
          </p>
          <div :if={@task_choices.error} role="status" class="assistant-task-picker-notice">
            <p>{gettext("Could not load tasks. Check the selected node and retry.")}</p>
            <button type="button" phx-click="assistant_task_picker_open" class="link mt-2">{gettext(
              "Retry"
            )}</button>
          </div>
          <p
            :if={!@task_choices.loading && !@task_choices.error && @task_choices.rows == []}
            role="status"
            class="assistant-task-picker-notice"
          >
            {if @task_choices.query == "",
              do: gettext("No tasks yet. Tasks you create will appear here."),
              else: gettext("No matching tasks. Try another name or project.")}
          </p>
          <ul :if={@task_choices.rows != []} class="assistant-task-choice-list">
            <li :for={task <- @task_choices.rows}>
              <button
                id={"assistant-task-choice-" <> task.id}
                type="button"
                phx-click="assistant_follow_task"
                phx-value-task_id={task.id}
                disabled={MapSet.member?(@followed_ids, task.id)}
                class="assistant-task-choice"
              >
                <span class="assistant-task-choice-main">
                  <span class="assistant-task-choice-title">{task.title}</span>
                  <span class="assistant-task-choice-meta">
                    <span>{status_label(task.status)}</span>
                    <span :if={task.path != ""} class="truncate" title={task.path}>{Path.basename(
                      task.path
                    )}</span>
                  </span>
                </span>
                <span
                  :if={MapSet.member?(@followed_ids, task.id)}
                  class="assistant-task-choice-followed"
                >
                  <.icon name="hero-check" class="size-4" />{gettext("Following")}
                </span>
                <.icon
                  :if={!MapSet.member?(@followed_ids, task.id)}
                  name="hero-plus"
                  class="size-4 shrink-0"
                />
              </button>
            </li>
          </ul>
        </div>
        <button
          :if={@task_choices.next_offset}
          type="button"
          id="assistant-task-more"
          phx-click="assistant_task_picker_more"
          disabled={@task_choices.loading}
          class="assistant-menu-item justify-center"
        >
          {if @task_choices.loading, do: gettext("Loading tasks…"), else: gettext("Load more tasks")}
        </button>
        <details id="assistant-task-by-id" class="assistant-task-by-id">
          <summary>{gettext("Enter a task ID instead")}</summary>
          <.form
            for={to_form(%{})}
            id="assistant-follow-task"
            phx-submit="assistant_follow_task"
            class="flex gap-2"
          >
            <.input
              name="task_id"
              value=""
              aria-label={gettext("Task ID")}
              placeholder={gettext("Follow an existing task ID")}
              class="input input-sm min-w-0 flex-1"
              required
            />
            <button disabled={@action_busy} class="btn btn-sm" type="submit">{gettext("Follow task")}</button>
          </.form>
        </details>
      </div>
    </details>
    """
  end

  defp status_label(:pending), do: gettext("Pending")
  defp status_label(:running), do: gettext("Running")
  defp status_label(:finalizing), do: gettext("Finalizing")
  defp status_label(:cancelling), do: gettext("Cancelling")
  defp status_label(:cancelled), do: gettext("Cancelled")
  defp status_label(:completed), do: gettext("Completed")
  defp status_label(:failed), do: gettext("Failed")
  defp status_label(:awaiting_input), do: gettext("Awaiting input")
  defp status_label(_), do: gettext("Unknown")

  defp task_url(task, nil), do: "/review/" <> URI.encode(task, &URI.char_unreserved?/1)
  defp task_url(task, id), do: task_url(task, nil) <> "?" <> URI.encode_query(%{"node" => id})
end
