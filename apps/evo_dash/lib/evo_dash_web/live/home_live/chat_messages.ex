defmodule EvoDashWeb.HomeLive.ChatMessages do
  @moduledoc """
  Renders the Home chat page's message surface (`EvoDashWeb.HomeLive`): the
  empty state (brand logo mark, greeting, suggestion chips) and the transcript
  message list (user bubbles via `EvoDashWeb.HomeLive.UserMessage`, assistant
  answer columns via `EvoDashWeb.HomeLive.AssistantMessage`, error rows).

  Pure presentation — extracted from `home_live.ex` to keep the LiveView under
  the ~1000-line concern threshold. All interactivity bubbles up to the
  LiveView: the suggestion chips send `phx-click="send_message"` with
  `phx-value-message`; the assistant card's raw toggle and copy button use
  `phx-click="toggle_assistant_raw"` and the global `ClipboardCopy` hook
  (`phx-hook="ClipboardCopy"` + `data-content`, pushing the `"copied"` event).

  Total: every payload access is `Map.get`-guarded; transcript entries arrive
  normalized from `EvoDashWeb.HomeLive.Transcript` (always atom-keyed with
  binary ids/text).
  """

  use EvoDashWeb, :html
  use Gettext, backend: EvoDashWeb.Gettext

  import EvoDashWeb.HomeLive.AssistantMessage

  alias EvoDashWeb.HomeLive.UserMessage

  attr(:source_gate?, :boolean,
    default: false,
    doc:
      "true when the Genesis-source gate blocks chatting — swaps the suggestion " <>
        "chips for a short note pointing at the Download button"
  )

  # Renders the empty state (no transcript entries yet): brand logo mark
  # (light/dark variants), greeting, and the four suggestion chips —
  # OR, when the Genesis-source gate blocks chatting, a short note instead of
  # the chips (chips would only start a doomed `:reflect` task).
  def empty_state(assigns) do
    ~H"""
    <div class="min-h-full flex flex-col items-center justify-center gap-4 text-center px-4 py-8 sm:px-6">
      <div class="flex size-12 items-center justify-center rounded-full bg-base-200">
        <.icon name="hero-sparkles" class="size-6 text-primary-standalone" />
      </div>
      <%!-- zh_CN: "你想让 Genesis 做什么？" --%>
      <h2 class="text-2xl sm:text-3xl font-semibold tracking-tight text-base-content">
        {gettext("What would you like Genesis to do?")}
      </h2>
      <p class="max-w-md text-sm leading-relaxed text-base-content/70">
        <%!-- zh_CN: "开始对话" --%>{gettext("Start a conversation")}
      </p>
      <%= if @source_gate? do %>
        <p class="mt-4 max-w-md text-sm text-base-content/70">
          <%!-- zh_CN: "请先下载 Genesis 源码后再开始对话" --%>{gettext(
            "Download the Genesis source to start chatting."
          )}
        </p>
      <% else %>
        <div class="mt-4 grid grid-cols-1 sm:grid-cols-2 gap-3 w-full max-w-2xl">
          <%!-- zh_CN: "显示我的运行中任务" --%>
          <.suggestion_chip message={gettext("Show my running tasks")}>
            <.icon
              name="hero-light-bulb"
              class="size-4 shrink-0 text-base-content/60 group-hover:text-base-content"
            />
          </.suggestion_chip>
          <%!-- zh_CN: "检查系统状态与容量" --%>
          <.suggestion_chip message={gettext("Check system status and capacity")}>
            <.icon
              name="hero-magnifying-glass"
              class="size-4 shrink-0 text-base-content/60 group-hover:text-base-content"
            />
          </.suggestion_chip>
          <%!-- zh_CN: "帮我启动一个任务" --%>
          <.suggestion_chip message={gettext("Start a task for me")}>
            <.icon
              name="hero-puzzle-piece"
              class="size-4 shrink-0 text-base-content/60 group-hover:text-base-content"
            />
          </.suggestion_chip>
          <%!-- zh_CN: "解释任务是如何被调度的" --%>
          <.suggestion_chip message={gettext("Explain how tasks are scheduled")}>
            <.icon
              name="hero-map"
              class="size-4 shrink-0 text-base-content/60 group-hover:text-base-content"
            />
          </.suggestion_chip>
        </div>
      <% end %>
    </div>
    """
  end

  attr(:transcript, :list, required: true)
  attr(:chat_task_status, :any, required: true)
  attr(:thought_process, :list, required: true)
  attr(:raw_entry_ids, :any, required: true)

  # The transcript message list, oldest first. User entries are right-aligned
  # content-fit bubbles; assistant entries are answer-first columns; error
  # entries use a soft red tint. Only the LAST assistant entry receives the
  # task badge + thought process.
  def message_list(assigns) do
    ~H"""
    <div class="px-3 py-6 pb-8 space-y-8 sm:px-4 sm:space-y-10">
      <%= for {entry, index} <- Enum.with_index(@transcript) do %>
        <div id={"chat-entry-" <> entry_id(entry)} class={bubble_wrapper_class(entry)}>
          <%= case Map.get(entry, :role) do %>
            <% :user -> %>
              <UserMessage.user_message entry={entry} />
            <% :assistant -> %>
              <% is_last = index == last_assistant_index(@transcript) %>
              <.assistant_message
                entry={entry}
                raw={MapSet.member?(@raw_entry_ids, Map.get(entry, :id))}
                task_status={if is_last, do: @chat_task_status, else: nil}
                thought_process={if is_last, do: @thought_process, else: []}
              />
            <% :error -> %>
              <div class="flex items-start gap-2 rounded-xl border border-error/25 bg-error/10 px-3.5 py-2.5 text-sm leading-relaxed text-error whitespace-pre-wrap break-words">
                <.icon name="hero-exclamation-circle" class="mt-0.5 size-4 shrink-0" />
                {Map.get(entry, :text, "")}
              </div>
          <% end %>
        </div>
      <% end %>
    </div>
    """
  end

  # Bubble wrapper alignment: user entries right-aligned, assistant/error left.
  defp bubble_wrapper_class(entry) do
    case Map.get(entry, :role) do
      :user -> "flex justify-end"
      _ -> "flex justify-start"
    end
  end

  # Total id accessor (mirrors AssistantMessage.entry_id/1): real entries carry
  # normalized binary ids; malformed ones fall back to "" so the wrapper id
  # interpolation never raises.
  defp entry_id(entry) do
    case Map.get(entry, :id) do
      id when is_binary(id) -> id
      _ -> ""
    end
  end

  # Index of the LAST assistant entry in the transcript (the one tied to the
  # current/last chat task — only it gets the task badge + thought process).
  defp last_assistant_index(transcript) do
    transcript
    |> Enum.with_index()
    |> Enum.reduce(nil, fn
      {%{role: :assistant}, index}, _acc -> index
      _, acc -> acc
    end)
  end

  attr(:message, :string,
    required: true,
    doc: "Translated suggestion text — used as both the visible label and phx-value-message"
  )

  slot(:inner_block, required: true, doc: "The suggestion chip's icon")

  # Empty-state suggestion chip: a button that sends the message as a chat
  # prompt. The root button keeps the `group` class so the slot icon's
  # `group-hover:` styles keep working.
  defp suggestion_chip(assigns) do
    ~H"""
    <button
      type="button"
      phx-click="send_message"
      phx-value-message={@message}
      class="group flex flex-col items-start gap-2.5 rounded-xl border border-base-300 bg-base-100 px-4 py-3.5 text-left text-sm leading-relaxed text-base-content/70 hover:-translate-y-0.5 hover:border-base-300 hover:bg-base-200 hover:text-base-content transition-all focus-visible:outline-2 focus-visible:outline-offset-2 focus-visible:outline-primary-standalone"
    >
      {render_slot(@inner_block)}
      {@message}
    </button>
    """
  end
end
