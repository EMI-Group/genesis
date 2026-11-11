defmodule EvoDashWeb.TaskCardComponents.Session do
  @moduledoc """
  Reply panel for an interactive agent SESSION that is idle in the
  `:awaiting_input` task status.

  `:awaiting_input` is a non-terminal status: the task's root agent is a live
  interactive session that finished a turn and is waiting for the user's next
  message, so the task card offers the two things the user can do:

    * POST a message back into the running session — the
      `<form phx-submit="session_send_message" phx-value-task_id={@task.id}>`
      submits `%{"task_id" => id, "message" => text}` with a `name="message"`
      textarea;
    * CLOSE the session — `phx-click="open_close_session_modal"` with
      `phx-value-task_id` opens the owner's confirmation modal (the card does
      NOT implement that modal itself).

  Every user-facing string is gettext-wrapped, and the whole panel is plain
  server-side form/button behaviour: no client hook, no optimistic echo, no
  message history and no client-side enable/disable logic.

  The owning LiveView gates rendering — `task_card/1` renders this panel only
  when the task status is `:awaiting_input` AND it was handed a
  `session_agent_id`.
  """

  use EvoDashWeb, :html

  attr(:task, :map, required: true)

  def session_panel(assigns) do
    ~H"""
    <div
      id={"task-#{@task.id}-session"}
      class="rounded-lg border border-violet-500/30 bg-violet-500/5 p-3"
    >
      <div class="flex flex-wrap items-start justify-between gap-2">
        <div class="min-w-0">
          <p class="flex items-center gap-1.5 text-sm font-medium text-violet-600 dark:text-violet-400">
            <.icon name="hero-chat-bubble-left-right" class="size-4 shrink-0" />
            <%!-- zh_CN: 会话 — 交互式智能体会话（session） --%>{gettext(
              "Interactive session"
            )}
          </p>
          <p class="text-xs text-base-content/70 mt-0.5">
            {gettext("Waiting for your next message.")}
          </p>
        </div>

        <button
          type="button"
          class="btn btn-ghost btn-sm rounded-md shrink-0"
          phx-click="open_close_session_modal"
          phx-value-task_id={@task.id}
          title={
            gettext(
              "Close this session — it ends the interactive conversation and finalizes the task."
            )
          }
        >
          <.icon name="hero-x-circle" class="size-4 mr-1.5" /> {gettext("Close session")}
        </button>
      </div>

      <form
        phx-submit="session_send_message"
        phx-value-task_id={@task.id}
        class="mt-2 space-y-2"
      >
        <label
          for={"task-#{@task.id}-session-message"}
          class="block text-xs font-medium text-base-content/70"
        >
          <%!-- zh_CN: 会话消息（发送给交互式智能体的回复） --%>{gettext("Message")}
        </label>
        <textarea
          id={"task-#{@task.id}-session-message"}
          name="message"
          rows="3"
          class="textarea textarea-bordered w-full rounded-md bg-base-100 text-sm"
          placeholder={gettext("Reply to this session…")}
        ></textarea>

        <div class="flex justify-end">
          <button type="submit" class="btn btn-primary btn-sm rounded-md px-4">
            <.icon name="hero-paper-airplane" class="size-4 mr-1.5" /> {gettext("Send")}
          </button>
        </div>
      </form>
    </div>
    """
  end
end
