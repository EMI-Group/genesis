defmodule EvoDashWeb.WelcomeCompleteLive do
  @moduledoc """
  Onboarding completion page rendered at `/welcome/complete` after the user
  skips or finishes the Welcome page (`/welcome`).

  The page's sole focus is the example task: it explains Genesis' high-level
  prompt model, shows the demo objective (with a copy button), and offers a
  "Go to Dashboard" button that completes onboarding and navigates home.
  """

  use EvoDashWeb, :live_view

  @impl true
  def render(assigns) do
    ~H"""
    <EvoDashWeb.Layouts.app
      flash={@flash}
      current_page={:welcome}
      simple_nav={false}
      current_node_id={@current_node_id}
      current_node_name={@current_node_name}
      running_tasks={@running_tasks}
      pending_tasks={@pending_tasks}
      desktop_quit_confirm={@desktop_quit_confirm}
      update_status={@update_status}
      guide={@guide}
    >
      <div class="min-h-screen lg:h-screen lg:overflow-hidden max-w-3xl mx-auto px-4 lg:px-6 py-3 lg:py-6 flex flex-col">
        <!-- Header (non-scrolling) -->
        <div class="flex items-center gap-3 mb-4 shrink-0">
          <div class="text-3xl shrink-0">✨</div>
          <div class="min-w-0">
            <h2 class="text-xl font-bold leading-tight">
              {gettext("Write high-level prompts, not code")}
            </h2>
            <p class="text-sm text-base-content/60 leading-snug">
              {gettext(
                "In Genesis you only write high-level prompts: describe the end goal, the features you want, and the framework to use. Genesis figures out the architecture, delegates agents, and writes the code."
              )}
            </p>
          </div>
        </div>

        <!-- Example task — the page's sole focus -->
        <div class="flex-1 lg:overflow-y-auto lg:min-h-0 flex flex-col justify-center">
          <div class="rounded-xl border border-base-200 bg-base-100 p-6">
            <div class="flex items-center justify-between gap-2 mb-2">
              <h3 class="text-base font-bold">
                {gettext("Try an example task")}
              </h3>
              <button
                id="welcome-example-copy"
                phx-hook="ClipboardCopy"
                data-content={EvoDashWeb.ExampleTask.example_objective()}
                class="btn btn-ghost btn-sm btn-square"
                title={gettext("Copy")}
              >
                <.icon name="hero-clipboard" class="size-4" />
              </button>
            </div>
            <p class="text-sm text-base-content/60 leading-snug mb-4">
              {gettext(
                "You only need to describe the end goal like this — Genesis figures out the architecture, delegates agents, and writes the code."
              )}
            </p>
            <pre class="font-mono text-xs leading-relaxed whitespace-pre-wrap bg-base-200/50 rounded-lg p-4"><%= EvoDashWeb.ExampleTask.example_objective() %></pre>
          </div>
        </div>

        <!-- CTA -->
        <div class="flex justify-center mt-6 shrink-0">
          <button phx-click="go_to_dashboard" class="btn btn-primary rounded-xl px-8">
            {gettext("Go to Dashboard")}
          </button>
        </div>
      </div>
    </EvoDashWeb.Layouts.app>
    """
  end

  @impl true
  def mount(_params, _session, socket) do
    {:ok, socket}
  end

  # Fired by the global ClipboardCopy JS hook after a successful copy.
  @impl true
  def handle_event("copied", _params, socket) do
    {:noreply, put_flash(socket, :info, gettext("Copied to clipboard"))}
  end

  @impl true
  def handle_event("go_to_dashboard", _params, socket) do
    # Graceful degradation (same pattern as the former WelcomeController):
    # `EvoGit.Config.VersionState` may not be compiled in every deployment, so
    # gate the call with `Code.ensure_loaded?/1` — no try/rescue needed.
    if Code.ensure_loaded?(EvoGit.Config.VersionState) do
      EvoGit.Config.VersionState.complete_onboarding()
    end

    {:noreply, push_navigate(socket, to: "/")}
  end

  @impl true
  def handle_info({:task_updated, _task_id, _status, _node} = msg, socket) do
    # Node-identity task broadcast — node-filtered (foreign-node events are
    # dropped BEFORE the debounce is scheduled) and debounced (300ms trailing
    # edge) inside NodeAware.handle_task_info/2, which already returns
    # {:noreply, socket}.
    EvoDashWeb.LiveHooks.NodeAware.handle_task_info(socket, msg)
  end

  @impl true
  def handle_info({:task_deleted, _task_id, _node} = msg, socket) do
    EvoDashWeb.LiveHooks.NodeAware.handle_task_info(socket, msg)
  end

  @impl true
  def handle_info(:node_aware_reload_tasks, socket) do
    # Debounce timer fired — reload the sidebar's running/pending tasks.
    {:noreply, EvoDashWeb.LiveHooks.NodeAware.reload_tasks(socket)}
  end
end
