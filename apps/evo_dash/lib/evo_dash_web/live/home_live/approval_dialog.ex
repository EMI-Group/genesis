defmodule EvoDashWeb.HomeLive.ApprovalDialog do
  @moduledoc """
  Approval presentation for the Genesis Assistant page.

  Two surfaces, both purely presentational — every decision still travels
  through `EvoDashWeb.HomeLive.ApprovalWorkflow` as the request id plus a
  whitelisted `"approve"`/`"deny"` decision, so no client-supplied code, tier
  or command can ever reach the backend:

    * `approval_bar/1` — a FIXED-HEIGHT strip directly above the composer. Its
      height is reserved whether or not anything is pending, so an approval
      arriving or being resolved NEVER reflows the transcript column (the
      historical cause of the chat "shaking" at the end of a turn).
    * `approval_dialog/1` — a single DaisyUI `<dialog class="modal">` driven by
      the existing `phx-hook="DialogModal"` JS hook, showing ONE pending
      request at a time with "1 of N" stepping.

  The module also owns the total presentation helpers shared by the two
  surfaces: evaluator vs legacy-command semantics, danger styling, titles,
  plain-language summaries, target text and the sudo warning.
  """

  use EvoDashWeb, :html

  use Gettext, backend: EvoDashWeb.Gettext

  @doc """
  Fixed-height approval strip above the composer.

  Renders only its reserved height when nothing is pending and no error is
  present. Recovery/response errors keep their historical ids and the
  "Retry approvals" action, compressed into the same single line.
  """
  attr(:pending_approvals, :list, default: [])
  attr(:approval_error, :any, default: nil)
  attr(:approval_recovering, :boolean, default: false)

  def approval_bar(assigns) do
    assigns =
      assigns
      |> assign(:recovery_text, recovery_text(assigns[:approval_error]))
      |> assign(
        :response_text,
        response_text(assigns[:approval_error], assigns[:pending_approvals])
      )

    ~H"""
    <div
      id="approval-status-bar"
      class="flex h-10 shrink-0 items-center gap-2 overflow-hidden px-3 sm:px-4"
    >
      <%= if @pending_approvals != [] do %>
        <span class="flex size-5 shrink-0 items-center justify-center rounded-full bg-warning/15">
          <.icon name="hero-shield-exclamation" class="size-3.5 text-warning" />
        </span>
        <p class="min-w-0 shrink truncate text-xs font-medium text-base-content">
          {gettext("Genesis is waiting for your approval")}
        </p>
        <span
          class="badge badge-warning badge-sm shrink-0 font-medium tabular-nums"
          aria-label={gettext("%{count} pending approvals", count: length(@pending_approvals))}
        >
          {length(@pending_approvals)}
        </span>
        <button
          type="button"
          phx-click="open_approval_dialog"
          class="btn btn-warning btn-xs shrink-0"
        >
          {gettext("Review")}
        </button>
      <% end %>

      <%= if @recovery_text do %>
        <p
          id="approval-recovery-error"
          role="alert"
          title={@recovery_text}
          class="min-w-0 flex-1 truncate text-xs text-warning"
        >
          {@recovery_text}
        </p>
        <button
          type="button"
          phx-click="retry_approvals"
          disabled={@approval_recovering}
          class="btn btn-warning btn-xs shrink-0"
        >
          {gettext("Retry approvals")}
        </button>
      <% end %>

      <%= if @response_text && is_nil(@recovery_text) do %>
        <p
          id="approval-response-error"
          role="alert"
          title={@response_text}
          class="min-w-0 flex-1 truncate text-xs text-error"
        >
          {@response_text}
        </p>
      <% end %>
    </div>
    """
  end

  @doc """
  One pending request at a time, as a native `<dialog>` modal.

  The page mounts this component only while `:approval_dialog_open` is true and
  requests are pending; `phx-hook="DialogModal"` calls `showModal()` on mount and
  pushes `dialog_closed` on ESC / backdrop, which the page turns back into
  `approval_dialog_open: false`.
  """
  attr(:pending_approvals, :list, default: [])
  attr(:approval_dialog_index, :integer, default: 0)
  attr(:approval_responses, :map, default: %{})

  def approval_dialog(assigns) do
    {request, position, count} =
      view(assigns[:pending_approvals], assigns[:approval_dialog_index])

    assigns =
      assigns
      |> assign(:request, request)
      |> assign(:position, position)
      |> assign(:count, count)
      |> assign(:busy, busy?(request, assigns[:approval_responses]))

    ~H"""
    <%= if @request do %>
      <dialog id="approval-dialog" class="modal" phx-hook="DialogModal">
        <div class="modal-box w-11/12 max-w-2xl overflow-hidden p-0">
          <header class="flex items-start gap-3 border-b border-base-300 px-5 py-3.5">
            <span class={"mt-0.5 flex size-8 shrink-0 items-center justify-center rounded-full " <> badge_class(@request)}>
              <.icon name={icon_name(@request)} class={"size-4 " <> icon_class(@request)} />
            </span>
            <div class="min-w-0 flex-1">
              <p class="text-[11px] font-semibold uppercase tracking-wide text-base-content/50">
                {gettext("Approval required")}
              </p>
              <h2 class="mt-0.5 text-base font-semibold leading-snug">{title_text(@request)}</h2>
            </div>
            <%= if @count > 1 do %>
              <span class="badge badge-ghost badge-sm mt-1 shrink-0 tabular-nums">
                {gettext("%{position} of %{count}", position: @position, count: @count)}
              </span>
            <% end %>
            <button
              type="button"
              phx-click="dialog_closed"
              aria-label={gettext("Close")}
              title={gettext("Close")}
              class="btn btn-ghost btn-sm btn-square shrink-0"
            >
              <.icon name="hero-x-mark" class="size-4" />
            </button>
          </header>

          <div class="max-h-[min(60vh,32rem)] overflow-y-auto overscroll-contain px-5 py-4 scrollbar-thin">
            <p class="text-sm font-medium leading-snug text-base-content">{summary_text(@request)}</p>

            <%= if sudo?(@request) do %>
              <div
                id="approval-sudo-warning"
                class="mt-3 flex items-start gap-2.5 rounded-md border border-error/40 bg-error/10 p-3"
              >
                <.icon name="hero-exclamation-triangle" class="mt-0.5 size-4 shrink-0 text-error" />
                <div class="min-w-0">
                  <p class="text-sm font-semibold text-error">
                    {gettext("Unrestricted Elixir — no rollback")}
                  </p>
                  <p class="mt-1 text-sm leading-relaxed text-error">{body_text(@request)}</p>
                </div>
              </div>
            <% else %>
              <p class="mt-2 text-sm leading-relaxed text-base-content/70">{body_text(@request)}</p>
            <% end %>

            <%!-- The request's OWN warning (any tier), exactly as the core wrote it.
                 Identical text is never rendered twice (the sudo body copy is the
                 only fixed string a request warning can repeat). --%>
            <% warning = request_warning(@request) %>
            <%= if warning != "" do %>
              <div
                id="approval-request-warning"
                class="mt-3 flex items-start gap-2.5 rounded-md border border-error/40 bg-error/10 p-3"
              >
                <.icon name="hero-exclamation-triangle" class="mt-0.5 size-4 shrink-0 text-error" />
                <p class="min-w-0 whitespace-pre-wrap break-words text-sm font-semibold leading-normal text-error">
                  {warning}
                </p>
              </div>
            <% end %>

            <%= if evaluator?(@request) do %>
              <p class="mt-3 break-all text-xs font-semibold text-base-content/80">
                {gettext("Target runtime: %{node}", node: target_text(@request))}
              </p>
              <pre class="mt-2 max-h-72 overflow-auto whitespace-pre-wrap break-words rounded-md border border-base-300 bg-base-100 p-3 text-xs font-mono leading-relaxed text-base-content"><code>{code_text(@request)}</code></pre>
            <% else %>
              <div class="mt-2 rounded-md border border-base-300/80 bg-base-100 px-2.5 py-1.5">
                <code class="block break-all text-xs font-mono font-semibold text-base-content">{command_text(
                  @request
                )}</code>
              </div>
              <%= if args_text(@request) != "" do %>
                <p class="mt-1.5 whitespace-pre-wrap break-words text-xs leading-relaxed text-base-content/60">
                  {args_text(@request)}
                </p>
              <% end %>
            <% end %>
          </div>

          <footer class="flex flex-wrap items-center gap-2 border-t border-base-300 px-5 py-3">
            <%= if @count > 1 do %>
              <div class="flex items-center gap-1">
                <button
                  type="button"
                  phx-click="prev_approval"
                  disabled={@position <= 1}
                  aria-label={gettext("Previous request")}
                  title={gettext("Previous request")}
                  class="btn btn-ghost btn-sm btn-square"
                >
                  <.icon name="hero-chevron-left" class="size-4" />
                </button>
                <button
                  type="button"
                  phx-click="next_approval"
                  disabled={@position >= @count}
                  aria-label={gettext("Next request")}
                  title={gettext("Next request")}
                  class="btn btn-ghost btn-sm btn-square"
                >
                  <.icon name="hero-chevron-right" class="size-4" />
                </button>
              </div>
            <% end %>

            <div class="ml-auto flex items-center gap-2">
              <button
                type="button"
                phx-click="approval_response"
                phx-value-request_id={request_id(@request)}
                phx-value-decision="deny"
                disabled={@busy}
                class="btn btn-ghost btn-sm"
              >
                {gettext("Deny")}
              </button>
              <button
                type="button"
                phx-click="approval_response"
                phx-value-request_id={request_id(@request)}
                phx-value-decision="approve"
                disabled={@busy}
                class={
                  if danger?(@request), do: "btn btn-error btn-sm", else: "btn btn-primary btn-sm"
                }
              >
                {confirm_text(@request)}
              </button>
            </div>
          </footer>
        </div>
        <form method="dialog" class="modal-backdrop">
          <button>{gettext("Close")}</button>
        </form>
      </dialog>
    <% end %>
    """
  end

  ## Position / selection

  @doc """
  The request at `index` plus 1-based `position` and total `count`.

  Total: an out-of-range index, a non-integer index or a non-list collection
  falls back to the first request, so a shrinking queue never blanks the modal.
  """
  def view(requests, index) do
    list = if is_list(requests), do: requests, else: []
    count = length(list)
    position = clamp_index(index, count)

    case Enum.at(list, position) do
      nil -> {nil, 0, count}
      request -> {request, position + 1, count}
    end
  end

  @doc "Clamps a dialog cursor into `0..(count - 1)` (0 when empty)."
  def clamp_index(index, count) when is_integer(count) and count > 0 do
    cond do
      not is_integer(index) -> 0
      index < 0 -> 0
      index > count - 1 -> count - 1
      true -> index
    end
  end

  def clamp_index(_index, _count), do: 0

  @doc "True while a response for this request is in flight."
  def busy?(nil, _responses), do: false

  def busy?(request, responses) when is_map(responses) do
    Map.has_key?(responses, request_id(request))
  end

  def busy?(_request, _responses), do: false

  @doc "Chat request id (never nil, so `phx-value-request_id` is always a string)."
  def request_id(request), do: text(request, :request_id)

  ## Kind / tier classification

  @doc "True for the tiered `elixir_eval` evaluator requests."
  def evaluator?(request), do: field(request, :kind) == :elixir_eval

  @doc "True for the unrestricted (sudo) evaluator tier."
  def sudo?(request), do: evaluator?(request) and field(request, :tier) == :sudo

  @doc "Danger styling applies to sudo and to legacy level-3 commands."
  def danger?(request) do
    if evaluator?(request), do: sudo?(request), else: level_value(request) == 3
  end

  @doc "Legacy command-approval level (1-3) or nil for evaluator requests."
  def level_value(request) do
    case field(request, :level) do
      level when level in [1, 2, 3] -> level
      _ -> nil
    end
  end

  ## Labels

  @doc "Dialog heading: what kind of decision this is."
  def title_text(request) do
    cond do
      sudo?(request) -> gettext("Danger — unrestricted Elixir execution")
      evaluator?(request) -> gettext("Allow this Elixir code once?")
      danger?(request) -> gettext("Action required — real side effects")
      true -> gettext("The assistant wants your attention")
    end
  end

  @doc "One-line plain-language summary of what the agent wants to do."
  def summary_text(request) do
    cond do
      sudo?(request) ->
        # 审批横幅/对话框的一行摘要：sudo 层会在实时运行时里执行任意 Elixir。
        gettext("Run unrestricted Elixir in the live Genesis runtime.")

      evaluator?(request) ->
        gettext("Run one piece of Elixir in the Genesis runtime.")

      danger?(request) ->
        gettext("Perform a destructive task action.")

      true ->
        gettext("Confirm an action before the assistant continues.")
    end
  end

  @doc "Body copy: scope of the permission, or the legacy action's weight."
  def body_text(request) do
    cond do
      sudo?(request) ->
        # sudo 层不是操作系统 root，但可以改动运行中的进程、文件与配置，且无法回滚。
        gettext(
          "This runs unrestricted ordinary Elixir in the target's live runtime. " <>
            "It can change running processes, files and configuration. " <>
            "There is no rollback. This is not OS root access. " <>
            "Approve only if you trust this exact code."
        )

      evaluator?(request) ->
        gettext(
          "Allow one execution of exactly the code below on this target runtime. " <>
            "This is not permission for future evaluations."
        )

      danger?(request) ->
        gettext(
          "This action has real side effects — the assistant is starting, cancelling, " <>
            "force-killing, or deleting a task."
        )

      true ->
        gettext("It is asking you to confirm an action before it continues.")
    end
  end

  @doc "Primary (allow) button label."
  def confirm_text(request) do
    cond do
      sudo?(request) -> gettext("Allow unrestricted execution once")
      evaluator?(request) -> gettext("Allow once")
      true -> gettext("Confirm")
    end
  end

  @doc "Evaluator target runtime, rendered honestly when the request has none."
  def target_text(request) do
    case field(request, :target_node) do
      target when is_atom(target) and not is_nil(target) -> Atom.to_string(target)
      target when is_binary(target) and target != "" -> target
      _ -> gettext("Unknown target")
    end
  end

  @doc """
  The request's own optional `:warning`, or `""` (total).

  The core may stamp request-specific text here (e.g. the sudo evaluator
  warning), so it is rendered verbatim for any tier.
  """
  def warning_text(request) do
    case field(request, :warning) do
      value when is_binary(value) -> String.trim(value)
      _ -> ""
    end
  end

  # The warning block to render: the request's own text, unless the fixed copy
  # already shows exactly the same text (never duplicate it twice).
  defp request_warning(request) do
    warning = warning_text(request)
    if warning != "" and warning != body_text(request), do: warning, else: ""
  end

  @doc "Exact original code for an evaluator request (never truncated)."
  def code_text(request), do: text(request, :code)

  @doc "Legacy command string."
  def command_text(request), do: text(request, :command)

  @doc "Legacy command arguments."
  def args_text(request), do: text(request, :args)

  @doc "A binary field of the request, or `\"\"` for anything else (total)."
  def text(request, key) do
    case field(request, key) do
      value when is_binary(value) -> value
      _ -> ""
    end
  end

  @doc "Map read that tolerates non-map requests (total)."
  def field(request, key) when is_map(request), do: Map.get(request, key)
  def field(_request, _key), do: nil

  ## Styling helpers

  defp badge_class(request) do
    if danger?(request), do: "bg-error/10", else: "bg-info/10"
  end

  defp icon_name(request) do
    if danger?(request), do: "hero-exclamation-triangle", else: "hero-information-circle"
  end

  defp icon_class(request) do
    if danger?(request), do: "text-error", else: "text-info"
  end

  ## Strip error text

  defp recovery_text({:recovery, reason}) do
    # 保留原因，并把“已有请求仍然有效、可重试”的指引压进同一行。
    gettext(
      "Could not load pending approvals (%{reason}) — existing requests are kept; retry to check again.",
      reason: inspect(reason)
    )
  end

  defp recovery_text(_error), do: nil

  defp response_text({:response, request_id, reason}, requests) when is_list(requests) do
    if Enum.any?(requests, &(field(&1, :request_id) == request_id)) do
      gettext(
        "Failed to respond (%{reason}) — the request is still pending; try again.",
        reason: inspect(reason)
      )
    end
  end

  defp response_text(_error, _requests), do: nil
end
