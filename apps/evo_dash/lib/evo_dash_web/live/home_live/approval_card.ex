defmodule EvoDashWeb.HomeLive.ApprovalCard do
  @moduledoc """
  Command-approval card for the Home chat page (`EvoDashWeb.HomeLive`).

  Renders ONE pending run-command approval requested by the repo-less
  self-reflective agent (security levels 2 & 3 of the core's `run_command`
  tool — level 1 executes immediately and never reaches the UI). The card is
  level-distinct:

    * `level == 3` (REAL side effects — the assistant is starting, cancelling,
      force-killing, or deleting a task) renders in DANGER styling: an error
      tint frame, exclamation-triangle icon and an alarming title/body;
      Confirm is the danger `btn btn-error btn-sm`.
    * every other level (`2` or unknown/absent → INFORMATIONAL fallback)
      renders an info tint frame with an information-circle icon and gentle
      "the assistant wants your attention" wording; Confirm is
      `btn btn-primary btn-sm`.

  Both presentations show the command name in a `<code>` block, the
  human-readable `args` below it (plain escaped text), a small "Level N"
  badge, and BOTH buttons — Confirm (`phx-value-decision="approve"`) and Deny
  (`phx-value-decision="deny"`) — each carrying
  `phx-click="approval_response"` + `phx-value-request_id`, handled by the
  LiveView.

  Pure presentation — extracted from `home_live.ex` to keep the LiveView at
  its ~1000-line concern threshold. Interactivity bubbles up to the
  LiveView's `"approval_response"` event handler, which routes the decision
  through the `:approval_responder` call-time seam (see
  `home_live/CONTEXT.md`). DaisyUI theme tokens only — no hardcoded hex.

  Total: every payload access is `Map.get`-guarded — a malformed request
  (nil/missing keys) degrades per key (unknown/absent level →
  informational; missing request_id/command/args render empty), never raises.
  """

  use EvoDashWeb, :html
  use Gettext, backend: EvoDashWeb.Gettext

  attr(:request, :map, required: true)

  def approval_card(assigns) do
    ~H"""
    <div class="shrink-0 px-4 py-1.5">
      <div class={frame_class(@request)}>
        <div class="flex items-start gap-3">
          <.icon
            name={icon_name(@request)}
            class={"mt-0.5 size-5 shrink-0 " <> icon_color(@request)}
          />
          <div class="min-w-0 flex-1">
            <div class="flex items-start justify-between gap-2">
              <h3 class={title_class(@request)}>{title_text(@request)}</h3>
              <%= if level_value(@request) != nil do %>
                <span class={badge_class(@request)}>
                  <% # zh_CN: 安全级别徽标（1-3），数值来自请求的 level 字段 --%>
                  {gettext("Level %{level}", level: level_value(@request))}
                </span>
              <% end %>
            </div>
            <p class="mt-1 text-[13px] leading-relaxed text-base-content/80">
              {body_text(@request)}
            </p>
            <div class="mt-2 rounded-md border border-base-300/80 bg-base-100 px-2.5 py-1.5">
              <code class="block break-all text-xs font-mono font-semibold text-base-content">
                {command_text(@request)}
              </code>
            </div>
            <%= if args_text(@request) != "" do %>
              <p class="mt-1.5 whitespace-pre-wrap break-words text-xs leading-relaxed text-base-content/60">
                {args_text(@request)}
              </p>
            <% end %>
            <div class="mt-2.5 flex justify-end gap-2">
              <button
                type="button"
                phx-click="approval_response"
                phx-value-request_id={request_id_text(@request)}
                phx-value-decision="approve"
                class={confirm_class(@request)}
              >
                <% # zh_CN: 批准/确认 — 允许助手执行该命令；级别3为红色危险确认 --%>
                {gettext("Confirm")}
              </button>
              <button
                type="button"
                phx-click="approval_response"
                phx-value-request_id={request_id_text(@request)}
                phx-value-decision="deny"
                class="btn btn-ghost btn-sm"
              >
                <% # zh_CN: 拒绝 — 不允许助手执行该命令 --%>
                {gettext("Deny")}
              </button>
            </div>
          </div>
        </div>
      </div>
    </div>
    """
  end

  # --- level-driven presentation -------------------------------------------

  # True for level-3 requests (real side effects → DANGER styling). Any other
  # level (2, or unknown/absent) renders INFORMATIONAL.
  defp danger?(request), do: level_value(request) == 3

  # The request's security level, when present and sane; nil otherwise (the
  # informational fallback + no badge).
  defp level_value(request) do
    case Map.get(request, :level) do
      level when level in [1, 2, 3] -> level
      _ -> nil
    end
  end

  defp frame_class(request) do
    if danger?(request) do
      "rounded-lg border border-error/40 bg-error/10 p-4"
    else
      "rounded-lg border border-info/30 bg-info/10 p-4"
    end
  end

  defp icon_name(request) do
    if danger?(request), do: "hero-exclamation-triangle", else: "hero-information-circle"
  end

  defp icon_color(request) do
    if danger?(request), do: "text-error", else: "text-info"
  end

  defp title_class(request) do
    if danger?(request) do
      "text-sm font-semibold leading-snug text-error"
    else
      "text-sm font-semibold leading-snug text-info"
    end
  end

  defp badge_class(request) do
    if danger?(request) do
      "badge badge-sm badge-error font-medium"
    else
      "badge badge-sm badge-info font-medium"
    end
  end

  defp confirm_class(request) do
    if danger?(request) do
      "btn btn-error btn-sm"
    else
      "btn btn-primary btn-sm"
    end
  end

  defp title_text(request) do
    if danger?(request) do
      # zh_CN: 级别3标题 — 该操作有真实副作用（启动/取消/强制终止/删除任务），需要更强烈的警示措辞
      gettext("Action required — real side effects")
    else
      # zh_CN: 级别2标题 — 助手需要用户注意并确认一个操作
      gettext("The assistant wants your attention")
    end
  end

  defp body_text(request) do
    if danger?(request) do
      # zh_CN: 级别3说明 — 明确告知该操作会真实启动/取消/强制终止/删除任务，影响无法撤销
      gettext(
        "This action has real side effects — the assistant is starting, cancelling, force-killing, or deleting a task."
      )
    else
      # zh_CN: 级别2说明 — 助手在继续之前请求用户确认
      gettext("It is asking you to confirm an action before it continues.")
    end
  end

  # --- total payload accessors ---------------------------------------------

  defp request_id_text(request) do
    case Map.get(request, :request_id) do
      id when is_binary(id) -> id
      _ -> ""
    end
  end

  defp command_text(request) do
    case Map.get(request, :command) do
      command when is_binary(command) -> command
      _ -> ""
    end
  end

  defp args_text(request) do
    case Map.get(request, :args) do
      args when is_binary(args) -> args
      _ -> ""
    end
  end
end
