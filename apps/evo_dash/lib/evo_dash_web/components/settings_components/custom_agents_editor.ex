defmodule EvoDashWeb.SettingsComponents.CustomAgentsEditor do
  @moduledoc """
  `custom_agents_editor/1` — List editor for custom agent definitions
  (stored in `agents.toml`, managed by `EvoGit.CustomAgents`).
  """

  # zh_CN: Agent → "智能体", Model → "模型", Subagent → "子智能体",
  # Tool → "工具", Prompt → "提示词", Delegation → "委派",
  # Turn → "回合", None (auto) → "无（自动）"

  use EvoDashWeb, :html

  import EvoDashWeb.SettingsComponents.CardShell, only: [card_shell: 1]

  import EvoDashWeb.SettingsComponents.FormFooter, only: [form_footer: 1]

  # Built-in agent type names the custom agent may spawn (mirrors the
  # @subagent_type_modules map in EvoGit.Agents.Custom).
  defp subagent_names, do: ~w(executor investigator manager architect task_scheduler)

  # ───────────────────────────────────────────────────────────────────────────
  # custom_agents_editor/1 — List editor for custom agent definitions
  # ───────────────────────────────────────────────────────────────────────────

  attr(:agents, :list, default: [])
  attr(:editing_agent_id, :any, default: nil)
  attr(:model_profiles, :list, default: [])

  def custom_agents_editor(assigns) do
    ~H"""
    <%!-- zh_CN: Custom Agents → "自定义智能体", Add Agent → "添加智能体";
         the description mentions subagents → "子智能体" and tools → "工具" --%>
    <.card_shell
      title={gettext("Custom Agents")}
      description={
        gettext("Define custom agents with their own prompts, tools, and spawnable subagents.")
      }
    >
      <:actions>
        <button
          type="button"
          phx-click="add_custom_agent"
          class="btn btn-primary btn-sm gap-2 shrink-0"
        >
          <.icon name="hero-plus" class="size-4" />
          {gettext("Add Agent")}
        </button>
      </:actions>

      <%= if @agents == [] and @editing_agent_id != "new" do %>
        <div class="flex flex-col items-center justify-center py-10 text-center border-2 border-dashed border-base-300 rounded-lg">
          <div class="text-base-content/30 mb-3">
            <.icon name="hero-user-group" class="size-8" />
          </div>
          <p class="text-sm text-base-content/70 font-medium mb-1">
            {gettext("No custom agents defined")}
          </p>
          <p class="text-xs text-base-content/60">
            {gettext("Add an agent to get started.")}
          </p>
        </div>
      <% end %>

      <div class="space-y-3">
        <%= for agent <- @agents do %>
          <% id = agent_id_string(agent) %>
          <%= if @editing_agent_id == id do %>
            <.agent_edit_form agent={agent} model_profiles={@model_profiles} />
          <% else %>
            <.agent_row agent={agent} />
          <% end %>
        <% end %>

        <%= if @editing_agent_id == "new" do %>
          <.agent_edit_form agent={%{}} model_profiles={@model_profiles} />
        <% end %>
      </div>
    </.card_shell>
    """
  end

  # ── Read-only summary row for a single agent ──

  attr(:agent, :map, required: true)

  defp agent_row(assigns) do
    ~H"""
    <div class="flex items-start gap-4 p-4 rounded-lg border border-base-200 bg-base-100 hover:bg-base-200/30 transition-colors">
      <div class="flex-1 min-w-0">
        <div class="flex items-center gap-2 mb-1.5">
          <.icon name="hero-user-circle" class="size-4 text-primary shrink-0" />
          <span class="text-sm font-bold text-base-content">{agent_name(@agent)}</span>
          <code class="font-mono text-xs text-base-content/60 badge badge-ghost badge-sm">
            {agent_id_string(@agent)}
          </code>
        </div>
        <div class="flex items-center gap-2 mb-1.5 flex-wrap">
          <span class="badge badge-ghost badge-sm gap-1 font-mono text-xs">
            <.icon name="hero-pencil-square" class="size-3" />
            {agent_type_label(@agent)}
          </span>
          <span class="badge badge-ghost badge-sm gap-1 font-mono text-xs">
            <.icon name="hero-arrows-right-left" class="size-3" />
            {if agent_delegation_level(@agent) == :high,
              do: gettext("high delegation"),
              else: gettext("low delegation")}
          </span>
          <%= if agent_model_id(@agent) do %>
            <span class="badge badge-primary badge-sm gap-1 font-mono text-xs">
              <.icon name="hero-sparkles" class="size-3" />
              {agent_model_id(@agent)}
            </span>
          <% end %>
        </div>
        <p class="text-xs text-base-content/60 font-mono mt-1 whitespace-nowrap truncate">
          {agent_prompt(@agent)}
        </p>
      </div>
      <div class="flex items-center gap-1 shrink-0">
        <button
          type="button"
          phx-click="edit_custom_agent"
          phx-value-id={agent_id_string(@agent)}
          class="btn btn-ghost btn-sm gap-1"
        >
          <.icon name="hero-pencil-square" class="size-4" />
          {gettext("Edit")}
        </button>
        <button
          type="button"
          phx-click="delete_custom_agent"
          phx-value-id={agent_id_string(@agent)}
          class="btn btn-ghost btn-sm text-error gap-1"
          data-confirm={gettext("Delete this custom agent?")}
        >
          <.icon name="hero-trash" class="size-4" />
          {gettext("Delete")}
        </button>
      </div>
    </div>
    """
  end

  # ── Editable form for a single agent (empty map = new draft) ──

  attr(:agent, :map, required: true)
  attr(:model_profiles, :list, default: [])

  defp agent_edit_form(assigns) do
    ~H"""
    <form
      phx-submit="save_custom_agent"
      class="p-4 rounded-lg border-2 border-primary/40 bg-base-100 space-y-4"
    >
      <input type="hidden" name="agent_id" value={agent_id_string(@agent)} />

      <div class="flex items-center gap-2 mb-1">
        <.icon name="hero-pencil-square" class="size-5 text-primary" />
        <h4 class="font-bold text-sm text-base-content">
          {if agent_id_string(@agent) == "",
            do: gettext("New Agent"),
            else: gettext("Edit Agent")}
        </h4>
      </div>

      <div class="grid grid-cols-1 sm:grid-cols-2 gap-4">
        <div class="form-control">
          <label class="label pb-1">
            <span class="label-text font-semibold text-xs">{gettext("Name")}
            <span class="text-error">*</span></span>
          </label>
          <input
            type="text"
            name="name"
            value={agent_name(@agent)}
            placeholder={gettext("e.g. Code Reviewer")}
            class="input input-bordered input-sm rounded-md w-full font-mono text-sm"
            required
          />
          <p class="text-xs text-base-content/70 mt-1">
            {gettext("A unique identifier is generated from the name")}
          </p>
        </div>
        <div class="form-control">
          <label class="label pb-1">
            <span class="label-text font-semibold text-xs">{gettext("Description")}</span>
          </label>
          <input
            type="text"
            name="description"
            value={agent_description(@agent)}
            placeholder={gettext("optional")}
            class="input input-bordered input-sm rounded-md w-full font-mono text-sm"
          />
          <p class="text-xs text-base-content/70 mt-1">
            {gettext("Free-form description")}
          </p>
        </div>
      </div>

      <div class="form-control">
        <label class="label pb-1">
          <span class="label-text font-semibold text-xs"><%!-- zh_CN: Prompt → "提示词" --%>{gettext(
            "Prompt"
          )}
          <span class="text-error">*</span></span>
        </label>
        <textarea
          name="prompt"
          rows="4"
          required
          placeholder={gettext("You are...")}
          class="textarea textarea-bordered textarea-sm rounded-md w-full font-mono text-sm resize-y"
        ><%= agent_prompt(@agent) %></textarea>
        <p class="text-xs text-base-content/70 mt-1">
          {gettext("The system prompt that defines this agent's role")}
        </p>
      </div>

      <div class="grid grid-cols-1 sm:grid-cols-2 lg:grid-cols-3 gap-4">
        <div class="form-control">
          <label class="label pb-1">
            <span class="label-text font-semibold text-xs"><%!-- zh_CN: Agent Type → "智能体类型" --%>{gettext(
              "Agent Type"
            )}</span>
          </label>
          <select
            name="agent_type"
            class="select select-bordered select-sm rounded-md w-full font-mono text-sm"
          >
            <option value="read_write" selected={agent_type(@agent) == :read_write}>
              read_write
            </option>
            <option value="read" selected={agent_type(@agent) == :read}>read</option>
          </select>
          <p class="text-xs text-base-content/70 mt-1">
            <%!-- zh_CN: read → "只读", read_write → "可读可写" --%>{gettext(
              "\"read\" agents cannot modify files"
            )}
          </p>
        </div>
        <div class="form-control">
          <label class="label pb-1">
            <span class="label-text font-semibold text-xs"><%!-- zh_CN: Delegation → "委派" --%>{gettext(
              "Delegation Level"
            )}</span>
          </label>
          <select
            name="delegation_level"
            class="select select-bordered select-sm rounded-md w-full font-mono text-sm"
          >
            <option value="low" selected={agent_delegation_level(@agent) == :low}>low</option>
            <option value="high" selected={agent_delegation_level(@agent) == :high}>high</option>
          </select>
          <p class="text-xs text-base-content/70 mt-1">
            <%!-- zh_CN: Subagent → "子智能体" --%>{gettext("Subagent delegation level")}
          </p>
        </div>
        <div class="form-control">
          <label class="label pb-1">
            <span class="label-text font-semibold text-xs"><%!-- zh_CN: Model → "模型" --%>{gettext(
              "Model"
            )}</span>
          </label>
          <select
            name="model_id"
            class="select select-bordered select-sm rounded-md w-full font-mono text-sm"
          >
            <option value="" selected={is_nil(agent_model_id(@agent))}>
              {gettext("None (auto)")} <%!-- zh_CN: 无（自动选择） --%>
            </option>
            <%= for profile <- @model_profiles do %>
              <% pid = model_profile_id(profile) %>
              <%= if pid != "" do %>
                <option value={pid} selected={agent_model_id(@agent) == pid}>{pid}</option>
              <% end %>
            <% end %>
          </select>
          <p class="text-xs text-base-content/70 mt-1">
            {gettext("The model profile to use; none = auto-selected")}
          </p>
        </div>
      </div>

      <div class="form-control">
        <label class="label pb-1">
          <span class="label-text font-semibold text-xs"><%!-- zh_CN: Turn → "回合" --%>{gettext(
            "Max Turns"
          )}</span>
        </label>
        <input
          type="number"
          name="max_turns"
          value={agent_max_turns(@agent)}
          min="1"
          placeholder={gettext("empty")}
          class="input input-bordered input-sm rounded-md w-full sm:w-44 font-mono text-sm"
        />
        <p class="text-xs text-base-content/70 mt-1">
          {gettext("Per-agent turn cap override; empty = default")}
        </p>
      </div>

      <%!-- Tools ── --%>
      <div class="form-control">
        <label class="label pb-1">
          <span class="label-text font-semibold text-xs"><%!-- zh_CN: Tool → "工具" --%>{gettext(
            "Tools"
          )}</span>
        </label>
        <% tools = agent_tools(@agent) %>
        <div class="flex flex-wrap gap-2">
          <%= for tool <- tool_names() do %>
            <label class="flex items-center gap-1.5 px-2.5 py-1.5 rounded-md border border-base-300 bg-base-200/50 cursor-pointer text-xs font-mono hover:bg-base-200">
              <input
                type="checkbox"
                name="tools[]"
                value={tool}
                checked={tool in tools}
                class="checkbox checkbox-xs"
              />
              {tool}
            </label>
          <% end %>
        </div>
        <p class="text-xs text-base-content/70 mt-1">
          {gettext("None selected = all tools")}
        </p>
      </div>

      <%!-- Subagents ── --%>
      <div class="form-control">
        <label class="label pb-1">
          <span class="label-text font-semibold text-xs"><%!-- zh_CN: Subagent → "子智能体" --%>{gettext(
            "Subagents"
          )}</span>
        </label>
        <% subagents = agent_subagents(@agent) %>
        <div class="flex flex-wrap gap-2">
          <%= for sub <- subagent_names() do %>
            <label class="flex items-center gap-1.5 px-2.5 py-1.5 rounded-md border border-base-300 bg-base-200/50 cursor-pointer text-xs font-mono hover:bg-base-200">
              <input
                type="checkbox"
                name="subagents[]"
                value={sub}
                checked={sub in subagents}
                class="checkbox checkbox-xs"
              />
              {sub}
            </label>
          <% end %>
        </div>
        <p class="text-xs text-base-content/70 mt-1">
          <%!-- zh_CN: built-in agent types → "内置智能体类型" --%>{gettext(
            "Built-in agent types this agent may spawn; none selected = no subagents"
          )}
        </p>
      </div>

      <.form_footer
        cancel_event="cancel_edit_custom_agent"
        save_label={gettext("Save Agent")}
      />
    </form>
    """
  end

  # ── Agent definition helpers ──
  # These safely read from agent maps that may have atom OR string keys
  # (TOML-parsed definitions can arrive with string keys before normalization).

  defp agent_id_string(agent) when is_map(agent) do
    case Map.get(agent, :id) || Map.get(agent, "id") do
      nil -> ""
      id -> to_string(id)
    end
  end

  defp agent_id_string(_), do: ""

  defp agent_name(agent) when is_map(agent) do
    Map.get(agent, :name) || Map.get(agent, "name") || ""
  end

  defp agent_name(_), do: ""

  defp agent_description(agent) when is_map(agent) do
    Map.get(agent, :description) || Map.get(agent, "description") || ""
  end

  defp agent_description(_), do: ""

  defp agent_prompt(agent) when is_map(agent) do
    Map.get(agent, :prompt) || Map.get(agent, "prompt") || ""
  end

  defp agent_prompt(_), do: ""

  defp agent_type(agent) when is_map(agent) do
    Map.get(agent, :agent_type) || Map.get(agent, "agent_type") || :read_write
  end

  defp agent_type(_), do: :read_write

  defp agent_delegation_level(agent) when is_map(agent) do
    Map.get(agent, :delegation_level) || Map.get(agent, "delegation_level") || :low
  end

  defp agent_delegation_level(_), do: :low

  defp agent_model_id(agent) when is_map(agent) do
    Map.get(agent, :model_id) || Map.get(agent, "model_id")
  end

  defp agent_model_id(_), do: nil

  defp agent_max_turns(agent) when is_map(agent) do
    Map.get(agent, :max_turns) || Map.get(agent, "max_turns")
  end

  defp agent_max_turns(_), do: nil

  # nil = all tools; [] and lists are membership sets for the checkbox state.
  defp agent_tools(agent) when is_map(agent) do
    case Map.get(agent, :tools) || Map.get(agent, "tools") do
      tools when is_list(tools) -> tools
      _ -> []
    end
  end

  defp agent_tools(_), do: []

  defp agent_subagents(agent) when is_map(agent) do
    case Map.get(agent, :subagents) || Map.get(agent, "subagents") do
      subs when is_list(subs) -> Enum.map(subs, &to_string/1)
      _ -> []
    end
  end

  defp agent_subagents(_), do: []

  defp agent_type_label(agent) do
    if agent_type(agent) == :read, do: "read", else: "read_write"
  end

  defp tool_names do
    EvoGit.Agent.Tools.schemas()
    |> Enum.map(&EvoGit.Agent.tool_name/1)
    |> Enum.reject(&is_nil/1)
  end

  defp model_profile_id(profile) when is_map(profile) do
    case Map.get(profile, :id) || Map.get(profile, "id") do
      nil -> ""
      id -> to_string(id)
    end
  end

  defp model_profile_id(_), do: ""
end
