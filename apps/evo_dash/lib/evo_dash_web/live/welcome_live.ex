defmodule EvoDashWeb.WelcomeLive do
  @moduledoc """
  Onboarding tutorial with step-by-step guidance for new users.

  Covers LLM configuration, project setup, and getting started.
  Redirects to the dashboard if the user has already completed onboarding.
  """

  use EvoDashWeb, :live_view

  @total_steps 4

  @impl true
  def render(assigns) do
    ~H"""
    <EvoDashWeb.Layouts.app
      flash={@flash}
      current_page={:welcome}
      simple_nav={true}
      current_node_id={@current_node_id}
      current_node_name={@current_node_name}
    >
      <div class="flex flex-col items-center justify-center min-h-[80vh] px-4">
        <!-- Skip link -->
        <div class="w-full max-w-lg flex justify-end mb-4">
          <button
            phx-click="skip"
            class="text-sm text-base-content/50 hover:text-base-content/70 transition-colors"
          >
            {gettext("Skip")}
          </button>
        </div>

        <!-- Card -->
        <div class="w-full max-w-lg bg-base-100 rounded-xl border border-base-200 shadow-sm p-8">
          <!-- Step content -->
          <div class="flex flex-col items-center text-center mb-8">
            <!-- Emoji circle -->
            <div class="w-20 h-20 rounded-full bg-primary/10 flex items-center justify-center mb-6 text-4xl">
              {step_emoji(@step)}
            </div>

            <h2 class="text-2xl font-bold mb-3">
              {step_title(@step)}
            </h2>

            <p class="text-base text-base-content/60 leading-relaxed max-w-md">
              {step_description(@step)}
            </p>
          </div>

          <!-- Progress dots -->
          <div class="flex items-center justify-center gap-2 mb-8">
            <%= for i <- 1..@total_steps do %>
              <div class={[
                "w-2.5 h-2.5 rounded-full transition-all duration-300",
                if(i <= @step, do: "bg-primary", else: "bg-base-300")
              ]}>
              </div>
            <% end %>
          </div>

          <!-- Navigation buttons -->
          <div class="flex items-center justify-between">
            <button
              :if={@step > 1}
              phx-click="prev_step"
              class="btn btn-ghost rounded-md"
            >
              {gettext("Back")}
            </button>
            <div :if={@step == 1}></div>

            <button
              :if={@step < @total_steps}
              phx-click="next_step"
              class="btn btn-primary rounded-md"
            >
              {gettext("Next")}
            </button>

            <button
              :if={@step == @total_steps}
              phx-click="get_started"
              class="btn btn-primary rounded-md"
            >
              {gettext("Get Started")}
            </button>
          </div>
        </div>
      </div>
    </EvoDashWeb.Layouts.app>
    """
  end

  @impl true
  def mount(_params, session, socket) do
    if session["onboarding_completed"] == true do
      {:halt, push_navigate(socket, to: "/")}
    else
      {:ok, assign(socket, step: 1, total_steps: @total_steps)}
    end
  end

  @impl true
  def handle_event("next_step", _, socket) do
    {:noreply, update(socket, :step, &min(&1 + 1, @total_steps))}
  end

  @impl true
  def handle_event("prev_step", _, socket) do
    {:noreply, update(socket, :step, &max(&1 - 1, 1))}
  end

  @impl true
  def handle_event("skip", _, socket) do
    {:noreply, redirect(socket, to: "/welcome/complete")}
  end

  @impl true
  def handle_event("get_started", _, socket) do
    {:noreply, redirect(socket, to: "/welcome/complete")}
  end

  defp step_emoji(1), do: "🚀"
  defp step_emoji(2), do: "🤖"
  defp step_emoji(3), do: "📁"
  defp step_emoji(4), do: "✨"

  defp step_title(1), do: gettext("Welcome to Genesis")
  defp step_title(2), do: gettext("Configure Your LLM")
  defp step_title(3), do: gettext("Create a Project")
  defp step_title(4), do: gettext("Start Building")

  defp step_description(1) do
    gettext(
      "Genesis is an AI-powered software development framework. It helps you build and evolve codebases using intelligent agents."
    )
  end

  defp step_description(2) do
    gettext(
      "Before you start, connect an LLM provider (OpenAI, Anthropic, Google, etc.) in Settings. Your API keys are stored locally, never sent anywhere."
    )
  end

  defp step_description(3) do
    gettext(
      "Open a Git repository as a project. Genesis will auto-detect the project structure and help you build or modify code."
    )
  end

  defp step_description(4) do
    gettext(
      "Use Genesis to create new codebases from scratch or evolve existing ones. Watch as AI agents work together to build your software."
    )
  end
end
