defmodule EvoDashWeb.WelcomeLive do
  @moduledoc """
  Onboarding tutorial with step-by-step guidance for new users.

  Covers LLM configuration, a dashboard interface tour, and getting started.
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
        <div class={["w-full flex justify-end mb-4", @step == 3 && "max-w-2xl", @step != 3 && "max-w-lg"]}>
          <button
            phx-click="skip"
            class="text-sm text-base-content/50 hover:text-base-content/70 transition-colors"
          >
            {gettext("Skip")}
          </button>
        </div>

        <!-- Card -->
        <div class={["w-full bg-base-100 rounded-xl border border-base-200 shadow-sm p-8", @step == 3 && "max-w-2xl", @step != 3 && "max-w-lg"]}>
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

          <!-- Step 3: Disabled task form + annotation callouts -->
          <%= if @step == 3 do %>
            <div class="mb-6">
              <EvoDashWeb.TaskFormComponents.task_form
                prompt={@prompt}
                mode={@mode}
                mode_info={@mode_info}
                node_path={@node_path}
                starting_commit={@starting_commit}
                resume_from={@resume_from}
                show_advanced={@show_advanced}
                disabled={true}
                archive={@archive}
                model_profiles={@model_profiles}
                selected_model_id={@selected_model_id}
                build_systems={@build_systems}
                selected_build_system={@selected_build_system}
              />
            </div>

            <div class="grid grid-cols-1 md:grid-cols-3 gap-3 mb-8">
              <div class="bg-info/10 border border-info/20 rounded-lg p-3 text-sm text-left">
                <h4 class="font-bold text-info mb-1">① {gettext("Task Mode")}</h4>
                <p class="text-base-content/60">
                  {gettext(
                    "Choose what Genesis should do: create a codebase from scratch, initialize an existing project, or evolve code with AI agents."
                  )}
                </p>
              </div>
              <div class="bg-info/10 border border-info/20 rounded-lg p-3 text-sm text-left">
                <h4 class="font-bold text-info mb-1">② {gettext("Prompt / Objective")}</h4>
                <p class="text-base-content/60">
                  {gettext(
                    "Describe what you want. For new codebases: describe the project. For evolution: describe what to change."
                  )}
                </p>
              </div>
              <div class="bg-info/10 border border-info/20 rounded-lg p-3 text-sm text-left">
                <h4 class="font-bold text-info mb-1">③ {gettext("Execute Task")}</h4>
                <p class="text-base-content/60">
                  {gettext(
                    "Click to start. Genesis agents work in isolated worktrees and show progress in real-time on the dashboard."
                  )}
                </p>
              </div>
            </div>
          <% end %>

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
      {:ok, push_navigate(socket, to: "/")}
    else
      {:ok,
       assign(socket,
         step: 1,
         total_steps: @total_steps,
         prompt: "",
         mode: "genesis_new",
         mode_info: "",
         node_path: "",
         starting_commit: "",
         resume_from: "",
         show_advanced: false,
         archive: false,
         model_profiles: [],
         selected_model_id: nil,
         build_systems: [],
         selected_build_system: nil
       )}
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
  defp step_emoji(3), do: "🖥️"
  defp step_emoji(4), do: "✨"

  defp step_title(1), do: gettext("Welcome to Genesis")
  defp step_title(2), do: gettext("Configure Your LLM")
  defp step_title(3), do: gettext("Tour the Dashboard")
  defp step_title(4), do: gettext("You're Ready!")

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
      "This is the main dashboard interface you'll use to create and evolve codebases. Here's a quick tour of the key controls."
    )
  end

  defp step_description(4) do
    gettext(
      "You now know the basics! Configure your LLM in Settings, open a project, and start building with Genesis."
    )
  end
end
