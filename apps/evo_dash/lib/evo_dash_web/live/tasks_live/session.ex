defmodule EvoDashWeb.TasksLive.Session do
  @moduledoc """
  Interactive-session UI support for the Tasks page (`EvoDashWeb.TasksLive`).

  A task can be an INTERACTIVE agent session parked at the non-terminal
  `:awaiting_input` status (violet status family): its agent is idle and waits
  for the user's next message. `EvoDashWeb.TaskCardComponents.task_card/1`
  renders that card's reply box and its "Close session" control; closing a
  session is the ONLY non-cancellation way out of `:awaiting_input` (the agent
  finishes its current work, commits and ends the session, so the task becomes
  reviewable).

  This module hosts ONLY the close-session confirmation modal, keeping the
  single-page LiveView lean (the `tasks_live/task_detail.ex` support-module
  pattern). It is stateless: the open/closed state lives in the LiveView's
  `:confirm_close_session_task_id` assign and its buttons post that LiveView's
  events (`close_close_session_modal` / `confirm_close_session`).
  """
  use Phoenix.Component
  use Gettext, backend: EvoDashWeb.Gettext

  import EvoDashWeb.CoreComponents, only: [icon: 1]

  attr(:task_id, :any, required: true)
  attr(:session_agent_id, :any, default: nil)

  def confirm_close_session_modal(assigns) do
    ~H"""
    <div class="fixed inset-0 z-50 flex items-center justify-center p-4">
      <div
        class="fixed inset-0 bg-black/50 backdrop-blur-sm"
        phx-click="close_close_session_modal"
      >
      </div>
      <div class="relative bg-base-100 rounded-lg shadow-2xl border border-base-300 max-w-lg w-full p-6 md:p-8">
        <div class="flex items-center gap-3 mb-4">
          <.icon
            name="hero-chat-bubble-left-right"
            class="size-5 text-violet-600 dark:text-violet-400"
          />
          <%!-- zh_CN: 关闭交互式会话 --%>
          <h3 class="text-lg font-bold">{gettext("Close this session?")}</h3>
        </div>

        <p class="text-sm text-base-content/70 mb-2 leading-relaxed">
          <%!-- zh_CN: 智能体完成当前工作并提交后结束会话 --%>
          {gettext(
            "The agent will finish its current work, commit, and end the session. The task then becomes reviewable."
          )}
        </p>
        <p :if={@session_agent_id} class="text-xs text-base-content/70 mb-1">
          {gettext("Agent: %{agent_id}", agent_id: @session_agent_id)}
        </p>
        <p class="text-xs text-base-content/70 mb-5">
          {gettext("Task: %{task_id}", task_id: @task_id)}
        </p>

        <div class="flex justify-end gap-3 pt-2">
          <button
            type="button"
            class="btn btn-ghost rounded-md px-6"
            phx-click="close_close_session_modal"
          >
            {gettext("Keep Session Open")}
          </button>
          <button
            type="button"
            class="btn rounded-md px-6 gap-2 bg-violet-600 text-white hover:bg-violet-700"
            phx-click="confirm_close_session"
          >
            <.icon name="hero-check" class="size-4.5" />
            {gettext("Close Session")}
          </button>
        </div>
      </div>
    </div>
    """
  end
end
