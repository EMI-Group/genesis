defmodule EvoDashWeb.TaskOptionsComponents do
  @moduledoc false

  use EvoDashWeb, :html

  def options(assigns) do
    ~H"""
    <section
      id="task-options"
      aria-labelledby="task-options-title"
      class={[
        "workbench-task-options",
        @class,
        @disabled && "opacity-40 pointer-events-none select-none"
      ]}
    >
      <h2 id="task-options-title" class="mb-4 text-lg font-semibold">
        {gettext("Task Options")}
      </h2>
      <%!-- zh_CN: “Project Settings” 是配置项目级选项的折叠区名称。 --%>
      <p class="workbench-task-options-description text-sm text-base-content/70">
        {gettext(
          "These options apply to this run. Use Project Settings for shared configuration and repositories."
        )}
      </p>
      <div class="workbench-task-options-fields grid grid-cols-1 items-start gap-3 sm:grid-cols-2 lg:grid-cols-3">
        <label
          :if={String.starts_with?(@mode, "genesis")}
          class="workbench-task-option-field grid gap-1 text-sm font-medium"
        >
          {gettext("Build System")}
          <select name="build_system" form="task-form" class="select select-bordered select-sm w-full">
            <option value="">{gettext("No build system")}</option>
            <option
              :for={bs <- @build_systems}
              value={to_string(bs.id)}
              selected={@selected_build_system == to_string(bs.id)}
            >
              {bs.name}
            </option>
          </select>
        </label>
        <label class="workbench-task-option-toggle flex min-h-[var(--row-h-tall)] cursor-pointer items-center gap-3">
          <input
            type="checkbox"
            name="archive"
            value="true"
            form="task-form"
            class="toggle toggle-sm toggle-primary"
            checked={@archive}
          />
          <span>
            <span class="block text-sm font-medium">{gettext("Archive agent detail")}</span>
            <span class="block text-xs text-base-content/70">
              {gettext("Collect per-agent metadata for review")}
            </span>
          </span>
        </label>
        {persist_agent_state_toggle(assigns)}
      </div>

      <details
        :if={@advanced?}
        id="task-advanced-options"
        class="workbench-task-options-advanced group motion-disclosure"
        open={prefilled?([@node_path, @starting_commit, @resume_from])}
        phx-hook="DisclosureMotion"
        phx-mounted={JS.ignore_attributes("open")}
      >
        <%!-- zh_CN: Advanced options → "高级选项"（任务的起始节点、提交和续作设置） --%>
        <summary class="workbench-task-options-advanced-summary workbench-row cursor-pointer font-medium focus-visible:outline-2 focus-visible:outline-primary-standalone">
          <.icon name="hero-chevron-right" class="size-4 shrink-0 group-open:rotate-90" />
          {gettext("Advanced options")}
        </summary>
        <div class="workbench-task-options-advanced-fields grid grid-cols-1 gap-3 sm:grid-cols-2 lg:grid-cols-3">
          <div class="workbench-task-option-field grid content-start gap-1">
            <label for="task-node-path" class="text-sm font-medium">{gettext("Starting Node")}</label>
            <input
              type="text"
              id="task-node-path"
              name="node_path"
              form="task-form"
              value={@node_path}
              class="input input-bordered input-sm w-full font-mono"
              placeholder={gettext("e.g., ./src/components")}
              aria-describedby="task-node-path-help"
            />
            <p id="task-node-path-help" class="text-xs text-base-content/70">
              <%!-- zh_CN: 起始节点是相对于项目根目录的子目录；留空即从根目录开始。 --%>
              {gettext("Use a path relative to the project root. Leave blank to start at the root.")}
            </p>
          </div>
          <div class="workbench-task-option-field grid content-start gap-1">
            <div class="flex items-center gap-1 text-sm font-medium">
              <label for="task-starting-commit">{gettext("Starting Commit")}</label>
              <.tip text={
                gettext("A Git commit SHA, branch name, or tag to use as the base. Defaults to HEAD.")
              } />
            </div>
            <input
              type="text"
              id="task-starting-commit"
              name="starting_commit"
              form="task-form"
              value={@starting_commit}
              class="input input-bordered input-sm w-full font-mono"
              placeholder={gettext("e.g., abc1234 or HEAD")}
            />
          </div>
          <div class="workbench-task-option-field grid content-start gap-1">
            <div class="flex items-center gap-1 text-sm font-medium">
              <label for="task-resume-from">{gettext("Resume from")}</label>
              <.tip text={
                gettext(
                  "The ID of a previous task to continue from. Injects the previous task's context (commits, objective, and result) into this task's objective."
                )
              } />
            </div>
            <input
              type="text"
              id="task-resume-from"
              name="resume_from"
              form="task-form"
              value={@resume_from}
              class="input input-bordered input-sm w-full font-mono"
              placeholder="a1b2c3d4"
            />
          </div>
        </div>
      </details>
    </section>
    """
  end

  def persist_agent_state_toggle(assigns) do
    ~H"""
    <label
      class="workbench-task-option-toggle flex min-h-[var(--row-h-tall)] cursor-pointer items-center gap-3"
      title={gettext("Save agent state so work survives a restart")}
    >
      <input
        id="persist-agent-state-toggle"
        type="checkbox"
        class="toggle toggle-sm toggle-primary"
        checked={@persist_agent_state?}
        phx-click="toggle_persist_agent_state"
      />
      <span>
        <%!-- zh_CN: agent → "代理", persist → "持久化", state → "状态" --%>
        <span class="block text-sm font-medium">{gettext("Persist agent state")}</span>
        <span class="block text-xs text-base-content/70">
          {gettext(
            "Save agent checkpoints so work survives a restart; turn off to skip persistence writes"
          )}
        </span>
      </span>
    </label>
    """
  end

  defp prefilled?(values), do: Enum.any?(values, &EvoGit.Util.Strings.present?/1)
end
