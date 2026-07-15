defmodule EvoDashWeb.TaskFormComponents do
  @moduledoc """
  Task form component for the dashboard — mode selector, model dropdown,
  advanced options, prompt textarea, archive checkbox, and execute button.
  """

  # zh_CN: Evolution → "演进", Prompt → "提示词", Commit → "提交", Branch → "分支"

  use EvoDashWeb, :html

  # ---------------------------------------------------------------------------
  # task_form/1 — Modern card with gradient hero, tooltips, and better UX
  # ---------------------------------------------------------------------------

  attr(:prompt, :string, default: "")
  attr(:mode, :string, default: "genesis_new")
  attr(:mode_info, :string, default: "")
  attr(:node_path, :string, default: "")
  attr(:seeds, :string, default: "")
  attr(:starting_commit, :string, default: "")
  attr(:resume_from, :string, default: "")
  attr(:show_advanced, :boolean, default: false)
  attr(:disabled, :boolean, default: false)
  attr(:archive, :boolean, default: false)
  attr(:model_profiles, :list, default: [])
  attr(:selected_model_id, :string, default: nil)
  attr(:build_systems, :list, default: [])
  attr(:selected_build_system, :string, default: nil)

  def task_form(assigns) do
    ~H"""
    <.form
      for={%{}}
      phx-submit="task_submit"
      class="bg-base-100 rounded-2xl shadow-sm border border-base-200"
    >
      <!-- Body -->
      <div class={["p-4 sm:p-5 space-y-4", @disabled && "opacity-50 pointer-events-none select-none"]}>
        <!-- Task mode & model selectors in one card -->
        <div class="bg-base-200/50 rounded-xl p-4 border border-base-300">
          <div class="grid grid-cols-1 md:grid-cols-2 gap-4">
            <!-- Task Mode -->
            <div class="flex flex-col sm:flex-row sm:items-center gap-3">
              <label class="text-base font-bold text-base-content whitespace-nowrap flex items-center gap-2">
                <.icon name="hero-cpu-chip" class="size-5 text-base-content/60" />
                {gettext("Task Mode")}
              </label>
              <select
                name="mode"
                phx-change="task_change"
                class="select select-bordered select-md w-full sm:w-auto flex-1 focus:outline-none focus:ring-2 focus:ring-base-content/20 font-semibold bg-base-100 shadow-sm"
              >
                <option value="genesis_existing" selected={@mode == "genesis_existing"}>
                  {gettext("Initialize Existing Codebase")}
                </option>
                <option value="genesis_new" selected={@mode == "genesis_new"}>
                  {gettext("Create New Codebase")}
                </option>
                <option value="evolve_simple" selected={@mode == "evolve_simple"}>
                  <%!-- zh_CN: Evolution → "演进" --%>{gettext("Evolution")}
                </option>
              </select>
              <div class="hidden sm:block">
                <.tip text={mode_description(@mode)} />
              </div>
              <p class="text-sm text-base-content/60 mt-1 sm:hidden">{mode_description(@mode)}</p>
            </div>

            <!-- Model -->
            <%= if @model_profiles != [] do %>
              <div class="flex flex-col sm:flex-row sm:items-center gap-3">
                <label class="text-base font-bold text-base-content whitespace-nowrap flex items-center gap-2">
                  <.icon name="hero-cpu-chip" class="size-5 text-base-content/60" />
                  {gettext("Model")}
                </label>
                <select
                  name="model_id"
                  phx-change="select_model"
                  class="select select-bordered select-md w-full sm:w-auto flex-1 focus:outline-none focus:ring-2 focus:ring-base-content/20 font-semibold bg-base-100 shadow-sm"
                >
                  <%= for profile <- @model_profiles do %>
                    <option value={profile.id} selected={@selected_model_id == profile.id}>
                      {profile.id <> " (" <> profile_model_label(profile) <> ")"}
                    </option>
                  <% end %>
                </select>
                <div class="hidden sm:block">
                  <.tip text={gettext("Select which model profile to use for this task")} />
                </div>
              </div>
            <% end %>
          </div>

          <%= if String.starts_with?(@mode, "genesis") do %>
            <div class="flex flex-col sm:flex-row sm:items-center gap-3 mt-4">
              <label class="text-base font-bold text-base-content whitespace-nowrap flex items-center gap-2">
                <.icon name="hero-cog-6-tooth" class="size-5 text-base-content/60" />
                {gettext("Build System")}
                <.tip text={gettext("Pre-configured worktree init scripts for your tech stack")} />
              </label>
              <select
                name="build_system"
                class="select select-bordered select-md w-full sm:w-auto flex-1 focus:outline-none focus:ring-2 focus:ring-base-content/20 font-semibold bg-base-100 shadow-sm"
              >
                <option value="">{gettext("None (no build system)")}</option>
                <%= for bs <- @build_systems do %>
                  <option value={to_string(bs.id)} selected={@selected_build_system == to_string(bs.id)}>
                    {bs.name}
                  </option>
                <% end %>
              </select>
              <div class="hidden sm:block">
                <.tip text={gettext("Pre-configured worktree init scripts for your tech stack")} />
              </div>
            </div>
          <% end %>
        </div>

        <%= if String.starts_with?(@mode, "evolve") do %>
          <div class="rounded-xl border border-base-200 bg-base-200/30">
            <button
              type="button"
              class={"w-full px-4 py-3 cursor-pointer hover:bg-base-200/50 transition-colors flex items-center gap-2 rounded-t-xl #{if @show_advanced, do: "", else: "rounded-b-xl"}"}
              phx-click="toggle_advanced"
            >
              <.icon name="hero-adjustments-horizontal" class="size-4 text-base-content/60" />
              <span class="text-sm font-semibold text-base-content">{gettext("Advanced Options")}</span>
              <.icon
                name="hero-chevron-down"
                class={"size-4 text-base-content/40 ml-auto transition-transform #{if @show_advanced, do: "rotate-180", else: ""}"}
              />
            </button>
            <%= if @show_advanced do %>
              <div class="px-4 pb-4 pt-2 space-y-4 border-t border-base-200 rounded-b-xl">
                <div class="flex flex-col md:flex-row gap-4">
                  <div class="form-control flex-1">
                    <label class="label">
                      <span class="label-text font-semibold text-base-content">{gettext(
                        "Starting Node"
                      )}
                      <%!-- zh_CN: evolution → "演进" --%>
                      <.tip text={
                        gettext(
                          "The subdirectory within the project to start evolution from. Use './' for root."
                        )
                      } /></span>
                    </label>
                    <input
                      type="text"
                      name="node_path"
                      value={@node_path}
                      class="input input-bordered w-full font-mono text-sm focus:outline-none focus:ring-2 focus:ring-base-content/20 bg-base-200/30"
                      placeholder={gettext("e.g., ./src/components")}
                    />
                    <label class="label">
                      <span class="label-text-alt text-base-content/50"><%!-- zh_CN: evolution → "演进" --%>{gettext(
                        "Subdirectory to start evolution from (optional)"
                      )}</span>
                    </label>
                  </div>
                  <div class="form-control flex-1">
                    <label class="label">
                      <span class="label-text font-semibold text-base-content"><%!-- zh_CN: Commit → "提交" --%>{gettext(
                        "Starting Commit"
                      )}
                      <%!-- zh_CN: commit → "提交", branch → "分支" --%>
                      <.tip text={
                        gettext(
                          "A Git commit SHA, branch name, or tag to use as the base. Defaults to HEAD."
                        )
                      } /></span>
                    </label>
                    <input
                      type="text"
                      name="starting_commit"
                      value={@starting_commit}
                      class="input input-bordered w-full font-mono text-sm focus:outline-none focus:ring-2 focus:ring-base-content/20 bg-base-200/30"
                      placeholder={gettext("e.g., abc1234 or HEAD")}
                    />
                    <label class="label">
                      <span class="label-text-alt text-base-content/50"><%!-- zh_CN: Commit → "提交" --%>{gettext(
                        "Commit SHA or ref to start from (defaults to HEAD)"
                      )}</span>
                    </label>
                  </div>
                </div>
                <div class="form-control">
                  <label class="label">
                    <span class="label-text font-semibold text-base-content">{gettext("Resume from")}
                    <.tip text={
                      gettext(
                        "The ID of a previous task to continue from. Injects the previous task's context (commits, objective, and result) into this task's objective."
                      )
                    } /></span>
                  </label>
                  <input
                    type="text"
                    name="resume_from"
                    value={@resume_from}
                    class="input input-bordered w-full font-mono text-sm focus:outline-none focus:ring-2 focus:ring-base-content/20 bg-base-200/30"
                    placeholder="a1b2c3d4"
                  />
                  <label class="label">
                    <span class="label-text-alt text-base-content/50">{gettext(
                      "Previous task ID to continue from (optional)"
                    )}</span>
                  </label>
                </div>
              </div>
            <% end %>
          </div>
        <% end %>

        <div class="form-control">
          <label class="label">
            <span class="label-text font-semibold text-base-content">
              <%= if String.starts_with?(@mode, "evolve") do %>
                {gettext("Objective")}
              <% else %>
                <%!-- zh_CN: Prompt → "提示词" --%>{gettext("Prompt")}
              <% end %>
            </span>
          </label>
          <textarea
            name="prompt"
            id="prompt"
            phx-update="ignore"
            class="textarea textarea-bordered w-full min-h-[160px] sm:min-h-[240px] text-base leading-relaxed focus:outline-none focus:ring-2 focus:ring-base-content/20 resize-y bg-base-200/30"
            placeholder={
              cond do
                @mode == "genesis_existing" ->
                  gettext("Optional — leave empty and click Execute to initialize an existing codebase")
                String.starts_with?(@mode, "evolve") ->
                  gettext("Describe what you want to change or improve...")
                true ->
                  gettext("Describe the codebase you want to create...")
              end
            }
          ><%= @prompt %></textarea>
        </div>

        <!-- Inline execute button -->
        <div class="flex items-center justify-between gap-4">
          <label class="label cursor-pointer flex items-center gap-3 justify-start">
            <input
              type="checkbox"
              name="archive"
              value="true"
              class="checkbox checkbox-sm checkbox-primary"
            />
            <span class="label-text text-sm font-medium text-base-content/70">{gettext(
              "Archive agent details"
            )}</span>
          </label>
          <button
            type="submit"
            class="btn btn-primary w-full sm:w-auto"
            disabled={@disabled}
          >
            <.icon name="hero-rocket-launch" class="size-4" /> {gettext("Execute Task")}
          </button>
        </div>
      </div>
    </.form>
    """
  end

  # Renders a compact label for a profile's model spec, handling both the new
  # map format (%{provider: atom, id: string, base_url: ...}) or tuple format
  # ({:provider, [id: "id", base_url: "..."]) and the legacy
  # "provider:id" string format. The `<>` binary operator crashes on maps, so we
  # normalize to a string here.
  defp profile_model_label(%{model: model} = _profile) when is_map(model) do
    provider = model[:provider] || model["provider"]
    id = model[:id] || model["id"]

    cond do
      provider != nil and id != nil -> "#{provider}:#{id}"
      id != nil -> to_string(id)
      true -> ""
    end
  end

  defp profile_model_label(%{model: {provider, opts}}) when is_atom(provider) and is_list(opts) do
    id = Keyword.get(opts, :id)
    if id && id != "", do: "#{provider}:#{id}"
  end

  defp profile_model_label(%{model: model}) when is_binary(model), do: model
  defp profile_model_label(_profile), do: ""
end
