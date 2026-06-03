defmodule EvoDashWeb.ReviewLive do
  use EvoDashWeb, :live_view

  @impl true
  def mount(%{"task_id" => task_id}, _session, socket) do
    task = EvoDash.TaskRegistry.get_task(task_id)

    socket =
      socket
      |> assign(:task_id, task_id)
      |> assign(:task, task)
      |> assign(:page_title, gettext("Review Task"))

    {:ok, socket}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div class="container mx-auto p-4">
      <h1 class="text-2xl font-bold">{@page_title}</h1>
      <p class="mt-4 text-base-content/70">Review page for task: {@task_id}</p>
    </div>
    """
  end
end
