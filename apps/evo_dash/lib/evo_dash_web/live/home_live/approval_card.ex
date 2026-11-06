defmodule EvoDashWeb.HomeLive.ApprovalCard do
  @moduledoc """
  Pending approval presentation for evaluator and legacy command requests.

  Evaluator cards show the exact original code and target runtime. Write grants
  are single-use; sudo authorizes unrestricted ordinary Elixir in the live BEAM,
  not OS root. Legacy command/args/level requests keep their existing wording.
  Decisions carry only the request id, never client-supplied code or a tier.
  """

  use EvoDashWeb, :html
  use Gettext, backend: EvoDashWeb.Gettext

  attr(:request, :map, required: true)
  attr(:busy, :boolean, default: false)

  def approval_card(assigns) do
    ~H"""
    <div class="shrink-0 px-4 py-1.5">
      <div class={frame_class(@request)}>
        <div class="flex items-start gap-3">
          <.icon
            name={
              if danger?(@request), do: "hero-exclamation-triangle", else: "hero-information-circle"
            }
            class={"mt-0.5 size-5 shrink-0 " <> if(danger?(@request), do: "text-error", else: "text-info")}
          />
          <div class="min-w-0 flex-1">
            <div class="flex items-start justify-between gap-2">
              <h3 class={"text-sm font-semibold leading-snug " <> if(danger?(@request), do: "text-error", else: "text-info")}>
                {title_text(@request)}
              </h3>
              <%= if level_value(@request) != nil and not evaluator?(@request) do %>
                <span class={"badge badge-sm " <> if(danger?(@request), do: "badge-error", else: "badge-info") <> " font-medium"}>
                  {gettext("Level %{level}", level: level_value(@request))}
                </span>
              <% end %>
            </div>
            <p class="mt-1 text-sm leading-relaxed text-base-content/80">
              {body_text(@request)}
            </p>
            <%= if evaluator?(@request) do %>
              <p class="mt-2 break-all text-xs font-semibold text-base-content/80">
                {gettext("Target runtime: %{node}", node: target_text(@request))}
              </p>
              <%= if sudo?(@request) and text(@request, :warning) != "" do %>
                <p class="mt-2 whitespace-pre-wrap break-words text-sm font-semibold text-error">
                  {text(@request, :warning)}
                </p>
              <% end %>
              <%!-- zh_CN: 原样显示本次授权的代码，不裁剪、不重新格式化；sudo 不是操作系统 root。 --%>
              <pre class="mt-2 max-h-64 overflow-auto whitespace-pre-wrap break-words rounded-md border border-base-300 bg-base-100 p-3 text-xs font-mono text-base-content"><code>{text(@request, :code)}</code></pre>
            <% else %>
              <div class="mt-2 rounded-md border border-base-300/80 bg-base-100 px-2.5 py-1.5">
                <code class="block break-all text-xs font-mono font-semibold text-base-content">
                  {text(@request, :command)}
                </code>
              </div>
              <%= if text(@request, :args) != "" do %>
                <p class="mt-1.5 whitespace-pre-wrap break-words text-xs leading-relaxed text-base-content/60">
                  {text(@request, :args)}
                </p>
              <% end %>
            <% end %>
            <div class="mt-2.5 flex flex-wrap justify-end gap-2">
              <button
                type="button"
                phx-click="approval_response"
                phx-value-request_id={text(@request, :request_id)}
                phx-value-decision="approve"
                disabled={@busy}
                class={
                  if danger?(@request), do: "btn btn-error btn-sm", else: "btn btn-primary btn-sm"
                }
              >
                {confirm_text(@request)}
              </button>
              <button
                type="button"
                phx-click="approval_response"
                phx-value-request_id={text(@request, :request_id)}
                phx-value-decision="deny"
                disabled={@busy}
                class="btn btn-ghost btn-sm"
              >
                {gettext("Deny")}
              </button>
            </div>
          </div>
        </div>
      </div>
    </div>
    """
  end

  defp evaluator?(request), do: field(request, :kind) == :elixir_eval
  defp sudo?(request), do: evaluator?(request) and field(request, :tier) == :sudo

  defp danger?(request) do
    if evaluator?(request), do: sudo?(request), else: level_value(request) == 3
  end

  defp level_value(request) do
    case field(request, :level) do
      level when level in [1, 2, 3] -> level
      _ -> nil
    end
  end

  defp frame_class(request) do
    if danger?(request),
      do: "rounded-lg border border-error/40 bg-error/10 p-4",
      else: "rounded-lg border border-info/30 bg-info/10 p-4"
  end

  defp title_text(request) do
    cond do
      sudo?(request) -> gettext("Danger — unrestricted Elixir execution")
      evaluator?(request) -> gettext("Allow this Elixir code once?")
      danger?(request) -> gettext("Action required — real side effects")
      true -> gettext("The assistant wants your attention")
    end
  end

  defp body_text(request) do
    cond do
      sudo?(request) ->
        # zh_CN: sudo 是绕过求值器限制的普通 Elixir，不是操作系统 root，也没有回滚。
        gettext(
          "This runs unrestricted ordinary Elixir in the target's live runtime. It can change running processes, files and configuration. There is no rollback. This is not OS root access. Approve only if you trust this exact code."
        )

      evaluator?(request) ->
        gettext(
          "Allow one execution of exactly the code below on this target runtime. This is not permission for future evaluations."
        )

      danger?(request) ->
        gettext(
          "This action has real side effects — the assistant is starting, cancelling, force-killing, or deleting a task."
        )

      true ->
        gettext("It is asking you to confirm an action before it continues.")
    end
  end

  defp confirm_text(request) do
    cond do
      sudo?(request) -> gettext("Allow unrestricted execution once")
      evaluator?(request) -> gettext("Allow once")
      true -> gettext("Confirm")
    end
  end

  defp target_text(request) do
    case field(request, :target_node) do
      target when is_atom(target) and not is_nil(target) -> Atom.to_string(target)
      _ -> gettext("Unknown target")
    end
  end

  defp text(request, key) do
    case field(request, key) do
      value when is_binary(value) -> value
      _ -> ""
    end
  end

  defp field(request, key) when is_map(request), do: Map.get(request, key)
  defp field(_request, _key), do: nil
end
