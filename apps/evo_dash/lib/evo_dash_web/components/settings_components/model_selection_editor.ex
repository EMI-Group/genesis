defmodule EvoDashWeb.SettingsComponents.ModelSelectionEditor do
  @moduledoc """
  `model_selection_editor/1` — Editor for the per-agent model-selection script
  (the `[model_selection]` section of `agents.toml`, compiled by
  `EvoGit.CustomAgents.ModelSelector`).
  """

  # zh_CN: Model → "模型", Script → "脚本", Agent → "智能体",
  # Default model → "默认模型", Compile error → "编译错误"

  use EvoDashWeb, :html

  # Example script shown in the UI (used via example_script/0 — a helper
  # function, because `@example_script` inside a ~H template would resolve to
  # an assign, not the module attribute).
  defp example_script do
    """
    cond do
      agent.custom_agent_id == "architect" -> "opus-profile"
      agent.agent_type == EvoGit.Agents.Architect -> "architect-profile"
      agent.depth == 0 -> "default-profile"
      agent.depth <= 2 -> "fast-profile"
      true -> nil
    end
    """
  end

  # ───────────────────────────────────────────────────────────────────────────
  # model_selection_editor/1 — Editor for the model-selection script
  # ───────────────────────────────────────────────────────────────────────────

  attr(:script, :string, default: "")
  attr(:script_status, :any, default: :ok)
  attr(:script_save_error, :any, default: nil)
  attr(:test_results, :list, default: [])

  def model_selection_editor(assigns) do
    ~H"""
    <div class="rounded-lg border border-base-200 bg-base-100 p-5">
      <div class="flex items-center justify-between mb-4">
        <div>
          <h3 class="text-lg font-bold text-base-content mb-0.5">
            {gettext("Model Selection Script")}
          </h3>
          <p class="text-sm text-base-content/80">
            <%!-- zh_CN: Elixir expression → "Elixir 表达式", spawn → "生成" --%>{gettext(
              "An Elixir expression evaluated for each agent spawn to pick the model."
            )}
          </p>
        </div>
      </div>

      <%= if compile_error = script_compile_error(@script_status) do %>
        <div class="mb-4 rounded-lg border border-error/30 bg-error/5 p-3 flex items-start gap-3">
          <.icon name="hero-exclamation-triangle" class="size-5 text-error shrink-0 mt-0.5" />
          <div class="min-w-0">
            <h4 class="font-bold text-sm text-error mb-1">{gettext("Script error")}</h4>
            <pre class="text-xs text-error/80 font-mono whitespace-pre-wrap break-all"><%= compile_error %></pre>
          </div>
        </div>
      <% end %>

      <%= if @script_save_error do %>
        <div class="mb-4 rounded-lg border border-error/30 bg-error/5 p-3 flex items-start gap-3">
          <.icon name="hero-exclamation-triangle" class="size-5 text-error shrink-0 mt-0.5" />
          <div class="min-w-0">
            <h4 class="font-bold text-sm text-error mb-1">{gettext("Script error")}</h4>
            <pre class="text-xs text-error/80 font-mono whitespace-pre-wrap break-all"><%= @script_save_error %></pre>
          </div>
        </div>
      <% end %>

      <form phx-submit="save_model_selection_script" class="space-y-4">
        <div class="form-control">
          <textarea
            name="script"
            rows="12"
            placeholder={"if agent.depth == 0, do: \"default\", else: \"fast\""}
            class="textarea textarea-bordered rounded-md w-full font-mono text-sm resize-y"
          ><%= @script %></textarea>
          <p class="text-[11px] text-base-content/60 mt-1">
            {gettext("Leave empty to disable model selection (the default model is used)")}
          </p>
        </div>

        <div class="flex items-center gap-2">
          <button type="submit" class="btn btn-primary btn-sm gap-2">
            <.icon name="hero-check" class="size-4" />
            {gettext("Save Script")}
          </button>
          <button
            type="button"
            phx-click="test_model_selection_script"
            class="btn btn-ghost btn-sm gap-2"
          >
            <.icon name="hero-beaker" class="size-4" />
            {gettext("Test script")}
          </button>
        </div>
      </form>

      <%!-- Collapsible contract help --%>
      <details class="mt-4">
        <summary class="cursor-pointer text-xs font-semibold text-base-content/70 hover:text-base-content">
          {gettext("Script contract")} <%!-- zh_CN: 脚本契约（帮助说明的折叠标题） --%>
        </summary>
        <pre class="mt-2 text-xs font-mono text-base-content/70 bg-base-200 rounded-md p-3 overflow-x-auto whitespace-pre-wrap"><%= EvoGit.CustomAgents.ModelSelector.describe_contract() %></pre>
      </details>

      <%!-- Example box --%>
      <div class="mt-4 rounded-lg border border-base-200 bg-base-200/50 p-3">
        <div class="flex items-center justify-between mb-2">
          <span class="text-xs font-bold uppercase tracking-wider text-base-content/60">
            {gettext("Example")}
          </span>
          <button
            id="model-script-example-copy"
            phx-hook="ClipboardCopy"
            data-content={example_script()}
            class="btn btn-ghost btn-xs gap-1"
          >
            <.icon name="hero-clipboard-document" class="size-3.5" />
            {gettext("Copy")}
          </button>
        </div>
        <pre class="text-xs font-mono text-base-content/70 overflow-x-auto whitespace-pre"><%= example_script() %></pre>
      </div>

      <%!-- Test results --%>
      <%= if @test_results != [] do %>
        <div class="mt-4">
          <h4 class="text-xs font-bold uppercase tracking-wider text-base-content/60 mb-2">
            {gettext("Test Results")}
          </h4>
          <div class="space-y-2">
            <%= for %{label: label, result: result} <- @test_results do %>
              <div class="flex items-center justify-between gap-3 rounded-md border border-base-200 bg-base-100 px-3 py-2">
                <span class="text-xs text-base-content/70">{label}</span>
                <%= case result do %>
                  <% {:ok, nil} -> %>
                    <span class="badge badge-ghost badge-sm font-mono">
                      {gettext("default model")} <%!-- zh_CN: 默认模型 --%>
                    </span>
                  <% {:ok, model_id} -> %>
                    <span class="badge badge-primary badge-sm font-mono">{model_id}</span>
                  <% {:error, reason} -> %>
                    <span class="text-xs text-error font-mono break-all">{format_error(reason)}</span>
                  <% other -> %>
                    <span class="text-xs text-base-content/60 font-mono break-all">{inspect(other)}</span>
                <% end %>
              </div>
            <% end %>
          </div>
        </div>
      <% end %>
    </div>
    """
  end

  # ── Helpers ──

  defp script_compile_error({:error, {:compile_error, msg}}), do: msg
  defp script_compile_error(_), do: nil

  # Formats the nested error reason inside a `{:error, reason}` test result.
  defp format_error({:compile_error, msg}), do: msg
  defp format_error({:script_raised, msg}), do: msg
  defp format_error({:invalid_result, msg}), do: msg
  defp format_error(reason), do: inspect(reason)
end
